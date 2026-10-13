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
            context: AssistantContext(libraryID: UUID(), profile: provider.service.snapshot.settings.profiles.first,
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
                    e.model.acceptAssistant(acceptance, destination: hasSource ? .improve : .newPrompt,
                        permit: permit!, validate: { nil }) {
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
                retainedPermit = nil
            }
        }
    }

    func testStaleQueuedStartCannotReleaseNewAcceptancePermitAfterSessionChange() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        let acceptance = try acceptance(e)
        var first: [AssistantAcceptanceOutcome] = []
        e.ui {
            e.model.close()
            e.model.acceptAssistant(acceptance, destination: .newPrompt, permit: AssistantSavePermit(),
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
        XCTAssertEqual(second.count, 1)
        XCTAssertNotNil(second.first?.committed, "The new generation must retain its own acceptance.")
        XCTAssertEqual(third.count, 1)
        guard case .failed(.editorBusy) = third.first else {
            return XCTFail("An old preflight must not release the newer acceptance's permit.")
        }
    }
}
