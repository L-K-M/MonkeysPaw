import Foundation
import XCTest
@testable import MonkeysPawCore

final class EditorAssistantPermitTests: XCTestCase {
    private func acceptance(_ e: EditorHarness) throws -> AssistantAcceptance {
        let provider = ProviderHarness()
        try provider.service.save(ProviderDraft(kind: .openaiCompatible, modelID: "model",
            key: .replace(SecretValue("test-key"))))
        let artifact = LlmArtifact(title: "Candidate", description: "", tags: [], fields: [], body: "Generated", notes: "")
        let id = try XCTUnwrap(ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PD"))
        guard case .ready(let content) = ArtifactMerge.write(artifact, id: id) else {
            throw EditingTestError.unexpectedOutcome
        }
        let snapshot = e.model.assistantSnapshot
        let candidate = AssistantCandidate(content: content,
            diff: try ArtifactDiff.compare(original: snapshot?.document, candidate: content),
            context: AssistantContext(libraryID: UUID(), profile: try XCTUnwrap(provider.service.snapshot.settings.profiles.first),
                editor: snapshot), mutationAccess: .currentScope)
        return AssistantAcceptance(id: UUID(), candidate: candidate, usage: nil)
    }

    func testRetiringEditorReleasesPermitAndReportsQueuedOrCommittedSaveExactlyOnce() throws {
        for hasSource in [false, true] {
            for published in [false, true] {
                let e = EditorHarness(heldWork: true, queuedMain: true)
                if hasSource { try e.open("Original") }
                let acceptance = try acceptance(e)
                var permit: AssistantSavePermit? = AssistantSavePermit()
                weak var retainedPermit = permit
                var replies: [AssistantAcceptanceOutcome] = []
                e.ui {
                    guard let issuedPermit = permit else { return XCTFail("The test must retain its issued permit.") }
                    e.model.acceptAssistant(acceptance, destination: hasSource ? .improve : .newPrompt,
                        permit: issuedPermit, validate: { nil }) {
                        XCTAssertTrue(e.h.marker.isUI)
                        replies.append($0)
                    }
                }
                e.h.main.releaseAll()
                XCTAssertEqual(e.model.state.status, .saving)
                if published { e.h.held.releaseNext() }
                permit = nil
                e.ui { e.model.deactivate() }
                e.settle()

                XCTAssertEqual(replies.count, 1)
                if published {
                    XCTAssertNotNil(replies.first?.committed)
                } else {
                    guard case .failed(.inactive) = replies.first else {
                        return XCTFail("Retirement must refuse a queued save.")
                    }
                    XCTAssertTrue(try e.h.data.listFiles().isEmpty)
                }
                XCTAssertNil(retainedPermit, "A retired editor must release the completed save's permit.")
            }
        }
    }

    func testStaleQueuedStartCannotReleaseNewAcceptancePermitAfterSessionChange() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        let acceptance = try acceptance(e)
        let firstPermit = AssistantSavePermit()
        var first: [AssistantAcceptanceOutcome] = []
        e.ui {
            e.model.close()
            e.model.acceptAssistant(acceptance, destination: .newPrompt, permit: firstPermit,
                validate: { nil }) { first.append($0) }
        }
        // Close retires the old generation before its queued preflight starts.
        e.h.main.releaseNext()
        e.h.main.releaseNext()
        var second: [AssistantAcceptanceOutcome] = []
        e.ui {
            e.model.acceptAssistant(acceptance, destination: .newPrompt, permit: AssistantSavePermit(),
                validate: { nil }) { second.append($0) }
        }
        e.h.main.releaseNext()
        var third: [AssistantAcceptanceOutcome] = []
        e.ui {
            e.model.acceptAssistant(acceptance, destination: .newPrompt, permit: AssistantSavePermit(),
                validate: { nil }) { third.append($0) }
        }
        e.settle()

        XCTAssertEqual(first.count, 1)
        guard case .failed(.staleContext) = first.first else { return XCTFail("Expected the retired preflight.") }
        XCTAssertThrowsError(try firstPermit.check()) {
            guard case .failed(.inactive) = $0 as? AssistantSaveRefusal else {
                return XCTFail("The earlier retirement refusal must remain authoritative.")
            }
        }
        XCTAssertEqual(second.count, 1)
        XCTAssertNotNil(second.first?.committed, "The new generation must retain its own acceptance.")
        XCTAssertEqual(third.count, 1)
        guard case .failed(.editorBusy) = third.first else {
            return XCTFail("An old preflight must not release the newer acceptance's permit.")
        }
    }

    func testAssistantAcceptanceRefusesAnExistingOrDeferredConflict() throws {
        for queuedStart in [false, true] {
            let destinations: [AssistantSaveDestination] = queuedStart ? [.improve] : [.newPrompt, .improve, .privateCopy]
            for destination in destinations {
                let e = EditorHarness(heldWork: true, queuedMain: true)
                try e.open("Original")
                e.ui { e.model.edit("Unsaved") }
                e.h.main.releaseAll()
                let acceptance = try acceptance(e)
                let permit = AssistantSavePermit()
                var validations = 0
                var outcomes: [AssistantAcceptanceOutcome] = []
                let start = {
                    e.model.acceptAssistant(acceptance, destination: destination, permit: permit,
                        validate: { validations += 1; return nil }) { outcomes.append($0) }
                }
                try e.change("External")
                if queuedStart {
                    // Deliver the index observation; its editor hop precedes start.
                    e.h.main.releaseNext()
                    e.ui(start)
                }
                e.h.main.releaseAll()
                e.h.held.releaseAll()
                e.h.main.releaseAll()
                XCTAssertNotNil(e.model.state.conflict)
                if !queuedStart { e.ui(start) }
                e.settle()

                XCTAssertEqual(outcomes.count, 1)
                guard case .failed(.editorBusy) = outcomes.first else { XCTFail("An unresolved conflict must refuse acceptance."); continue }
                XCTAssertEqual(validations, queuedStart ? 1 : 0)
                XCTAssertEqual(e.model.state.source, "Unsaved")
                XCTAssertNotNil(e.model.state.conflict)
                XCTAssertEqual(try e.h.files.text(at: "a.md"), "External")
                XCTAssertNil(try e.h.files.stamp(at: "Candidate.md"))
            }
        }
    }

    func testMatchingAssistantOperationLeavesLaterRequestQueuedUntilWriteCompletes() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        try e.open("Original")
        let acceptance = try acceptance(e)
        var outcomes: [AssistantAcceptanceOutcome] = []
        var later: [EditorGuardResult] = []
        e.ui {
            e.model.request(.quit)
            e.model.acceptAssistant(acceptance, destination: .improve, permit: AssistantSavePermit(),
                validate: { nil }) { outcomes.append($0) }
            e.model.request(.close) {
                XCTAssertNotNil(outcomes.first?.committed, "The later action must follow the actual write result.")
                later.append($0)
            }
        }
        e.h.main.releaseAll()

        XCTAssertEqual(e.model.state.status, .saving)
        XCTAssertEqual(e.model.state.queuedActions, [.close])
        XCTAssertEqual(e.h.held.pending.count, 1)
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(later.isEmpty)
        XCTAssertEqual(e.model.state.source, "Original")
        e.settle()

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNotNil(outcomes.first?.committed)
        XCTAssertEqual(later, [.allowed])
        XCTAssertTrue(e.model.state.queuedActions.isEmpty)
        XCTAssertNil(e.model.state.prompt)
    }
}
