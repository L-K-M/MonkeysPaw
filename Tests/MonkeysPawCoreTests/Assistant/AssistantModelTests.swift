import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantModelTests: XCTestCase {
    func testGuardPreservingAReadyPreviewStillBlocksEveryNewAction() async throws {
        let intents: [(String, (AssistantModel) -> Void)] = [
            ("write", { $0.write(brief: "New brief") }), ("review", { $0.review() }),
            ("improve", { $0.improve() }), ("retry", { $0.retryWithFeedback("Feedback") }),
            ("diff", { $0.showDiff() })
        ]
        for queued in [false, true] {
            for (name, intent) in intents {
                let h = try AssistantActionHarness(source: "Original", queued: queued)
                h.editor.ui { h.editor.model.edit("Unsaved") }
                h.ui { h.model.write(brief: "Brief") }
                try await h.sent()
                try await h.artifact()
                try await h.phase(.ready)
                h.editor.ui { h.editor.model.request(.quit) }
                h.changed()
                XCTAssertTrue(h.model.canAccept, "for \(name)")
                let reads = h.provider.secrets.reads.count
                h.ui { intent(h.model) }
                try await h.phase(.failed)
                XCTAssertEqual(h.model.state.failure, .editorBusy, "for \(name)")
                XCTAssertEqual(h.provider.secrets.reads.count, reads, "for \(name)")
                let requests = await h.transport.snapshot()
                XCTAssertEqual(requests.count, 1, "for \(name)")
                XCTAssertNil(h.model.state.candidate, "for \(name)")
                try h.editor.decide(.cancel)
                h.editor.settle()
            }
        }
    }

    func testFailedStartClearsPriorCandidateAndResultState() async throws {
        for queued in [false, true] {
            let h = try AssistantActionHarness(queued: queued)
            h.ui { h.model.editInstruction("Keep this instruction"); h.model.write(brief: "Brief") }
            try await h.sent()
            try await h.artifact(body: "Use {{topic}} and {{bad name}}")
            try await h.phase(.ready)
            XCTAssertNotNil(h.model.state.artifact)
            XCTAssertNotNil(h.model.state.candidate)
            XCTAssertFalse(h.model.state.issues.isEmpty)
            XCTAssertNotNil(h.model.state.usage)
            XCTAssertFalse(h.model.state.transcript.isEmpty)
            h.ui { h.model.review() }
            h.settle()
            XCTAssertEqual(h.model.state.phase, .failed)
            XCTAssertEqual(h.model.state.failure, .noEditor)
            XCTAssertNil(h.model.state.artifact)
            XCTAssertNil(h.model.state.review)
            XCTAssertNil(h.model.state.candidate)
            XCTAssertTrue(h.model.state.selectedFindings.isEmpty)
            XCTAssertTrue(h.model.state.issues.isEmpty)
            XCTAssertNil(h.model.state.usage)
            XCTAssertTrue(h.model.state.transcript.isEmpty)
            XCTAssertFalse(h.model.state.isStale)
            XCTAssertEqual(h.model.state.elapsed, 0)
            XCTAssertFalse(h.model.canAccept)
            XCTAssertEqual(h.model.state.instruction, "Keep this instruction")
            XCTAssertEqual(h.model.state.providerHost, "api.openai.com")
            h.ui { h.model.showDiff(); h.model.retryWithFeedback("Retry") }
            h.settle()
            let sent = await h.transport.snapshot()
            XCTAssertEqual(sent.count, 1)
        }
    }

    func testFailedStartStopsSupersededRequestTimerAndDropsItsLateReply() async throws {
        for queued in [false, true] {
            let h = try AssistantActionHarness(queued: queued)
            h.ui { h.model.write(brief: "Brief") }
            try await h.sent()
            h.time.advance(by: .seconds(3))
            h.ui { h.model.updateElapsed() }
            XCTAssertEqual(h.model.state.elapsed, 3)
            h.ui { h.model.improve() }
            h.settle()
            XCTAssertEqual(h.model.state.phase, .failed)
            XCTAssertEqual(h.model.state.failure, .noEditor)
            XCTAssertEqual(h.model.state.elapsed, 0)
            XCTAssertTrue(h.model.state.transcript.isEmpty)
            h.time.advance(by: .seconds(7))
            h.ui { h.model.updateElapsed() }
            XCTAssertEqual(h.model.state.elapsed, 0)
            try await h.artifact()
            try await h.clientReturned()
            h.settle()
            XCTAssertEqual(h.model.state.phase, .failed)
            XCTAssertNil(h.model.state.artifact)
            XCTAssertNil(h.model.state.candidate)
        }
    }

    func testLegacySuccessfulAcceptanceReleasesPreflightedIdentityForFreshDiff() async throws {
        let h = try AssistantActionHarness()
        h.ui { h.model.write(brief: "First") }
        try await h.sent()
        try await h.artifact()
        try await h.phase(.ready)
        let first = try XCTUnwrap(h.model.state.candidate?.content.document.frontMatter.id)
        var acceptance: AssistantAcceptance?
        h.ui { acceptance = h.model.accept() }
        let token = try XCTUnwrap(acceptance).id
        h.ui { XCTAssertTrue(h.model.completeAcceptance(token, result: .success(()))) }
        try await h.phase(.saved)
        h.ui { h.model.showDiff() }
        try await h.phase(.ready)
        let second = try XCTUnwrap(h.model.state.candidate?.content.document.frontMatter.id)
        XCTAssertNotEqual(first, second)
    }

    func testWritePhasesUsageElapsedAndAcceptIntentUnderInlineAndQueuedMain() async throws {
        for queued in [false, true] {
            let h = try AssistantActionHarness(queued: queued)
            var phases: [AssistantPhase] = [.idle]
            h.model.onChange = {
                XCTAssertTrue(h.main.isRunning)
                if phases.last != h.model.state.phase { phases.append(h.model.state.phase) }
            }
            XCTAssertEqual(h.model.state.providerHost, "api.openai.com")
            XCTAssertEqual(h.model.state.modelID, "manual-model")
            h.ui { h.model.write(brief: "Write a reusable prompt") }
            try await h.sent()
            XCTAssertEqual(h.model.state.phase, .working)
            XCTAssertFalse(h.model.canAccept)
            h.time.advance(by: .seconds(3))
            h.ui { h.model.updateElapsed() }
            XCTAssertEqual(h.model.state.elapsed, 3)
            try await h.artifact()
            try await h.phase(.ready)
            XCTAssertEqual(h.model.state.usage, AssistantTokenUsage(inputTokens: 11, outputTokens: 7))
            XCTAssertEqual(h.model.state.elapsed, 3)
            h.time.advance(by: .seconds(2))
            h.ui { h.model.updateElapsed() }
            XCTAssertEqual(h.model.state.elapsed, 3)
            let candidate = try XCTUnwrap(h.model.state.candidate)
            XCTAssertNotNil(candidate.content.document.frontMatter.id)
            XCTAssertEqual(candidate.content.canonicalBytes, Data(try PromptCodec.write(candidate.content.document).utf8))
            XCTAssertFalse(String(decoding: candidate.content.canonicalBytes, as: UTF8.self).contains("Changed the prompt."))
            var intent: AssistantAcceptance?
            h.ui { intent = h.model.accept() }
            XCTAssertFalse(h.model.canAccept)
            let accepted = try XCTUnwrap(intent)
            XCTAssertEqual(accepted.candidate.content.canonicalBytes, candidate.content.canonicalBytes)
            h.ui { h.model.completeAcceptance(accepted.id, result: .success(())) }
            h.settle()
            // The main port serializes callback writes and this final read.
            h.ui { XCTAssertEqual(phases, [.idle, .working, .draft, .ready, .saved]) }
            XCTAssertTrue(try h.editor.h.files.listFiles().isEmpty)
        }
    }

    func testInvalidArtifactRemainsDraftWithErrorsAndCannotBeAccepted() async throws {
        let h = try AssistantActionHarness()
        h.ui { h.model.write(brief: "Brief") }
        try await h.sent()
        try await h.artifact(body: "Unclosed {{topic")
        try await h.phase(.draft)
        XCTAssertTrue(h.model.state.issues.contains { $0.severity == .error })
        XCTAssertNil(h.model.state.candidate)
        XCTAssertFalse(h.model.canAccept)
        XCTAssertNil(h.model.accept())
    }

    func testWarningsAllowAcceptanceAndDiffHasPlaceholderWarnings() async throws {
        let h = try AssistantActionHarness(source: "Use {{old}}.")
        h.ui { h.model.editInstruction("Use a clearer placeholder"); h.model.improve() }
        try await h.sent()
        try await h.artifact(body: "Use {{new}}. {{bad name}}")
        try await h.phase(.ready)
        XCTAssertTrue(h.model.state.issues.contains { $0.severity == .warning })
        XCTAssertFalse(h.model.state.issues.contains { $0.severity == .error })
        XCTAssertTrue(h.model.canAccept)
        XCTAssertEqual(h.model.state.diff?.placeholderWarnings, [.renamed(from: "old", to: "new")])
    }

    func testReviewMatchesExactQuotesAndOnlySelectedFindingsGoToImprove() async throws {
        let h = try AssistantActionHarness([.held, .held], source: "Use sources.\nCafe\u{301}\n{{bad name}}")
        h.ui { h.model.review() }
        try await h.sent()
        var exact = AssistantOutputFixtures.finding
        exact["quote"] = "Cafe\u{301}"
        var unmatched = AssistantOutputFixtures.finding
        unmatched["quote"] = "Café"
        await h.transport.release(try h.response(["summary": "Review", "findings": [exact, unmatched]]))
        try await h.phase(.draft)
        XCTAssertFalse(h.model.canAccept)
        XCTAssertTrue(h.model.state.issues.contains { $0.code == .invalidPlaceholder })
        let bytes = try XCTUnwrap(h.editor.model.assistantSnapshot).sourceBytes
        XCTAssertEqual(h.model.highlightFinding(at: 0), bytes.range(of: Data("Cafe\u{301}".utf8)))
        XCTAssertNil(h.model.highlightFinding(at: 1))
        h.ui {
            h.model.toggleFinding(at: 0)
            h.model.toggleFinding(at: 0)
            h.model.toggleFinding(at: 1)
            h.model.editInstruction("Be precise")
            h.model.improve()
        }
        try await h.sent(2)
        let messages = try await h.messages(at: 1)
        let content = try XCTUnwrap(messages.last?["content"])
        XCTAssertTrue(content.contains("Café"))
        XCTAssertNil(Data(content.utf8).range(of: Data("Cafe\u{301}\n</quote>".utf8)))
        XCTAssertTrue(content.contains("Be precise"))
        try await h.artifact()
        try await h.phase(.ready)
    }

    func testInstructionOnlyImproveUsesCurrentUnsavedTemplateAndPreflightsAbsentID() async throws {
        let h = try AssistantActionHarness(source: "Disk template")
        h.editor.ui { h.editor.model.edit("Unsaved {{topic}} and {{clipboard}}") }
        let snapshot = try XCTUnwrap(h.editor.model.assistantSnapshot)
        h.ui { h.model.editInstruction("Make it shorter"); h.model.improve() }
        try await h.sent()
        let messages = try await h.messages()
        let content = try XCTUnwrap(messages.last?["content"])
        XCTAssertTrue(content.contains("Unsaved {{topic}} and {{clipboard}}"))
        XCTAssertFalse(content.contains("Disk template"))
        XCTAssertTrue(content.contains("<findings>\n\n</findings>"))
        try await h.artifact()
        try await h.phase(.ready)
        let candidate = try XCTUnwrap(h.model.state.candidate)
        XCTAssertEqual(candidate.context.editor, snapshot)
        XCTAssertNotNil(candidate.content.document.frontMatter.id)
        XCTAssertEqual(try h.editor.h.files.read(at: "a.md"), Data("Disk template".utf8))
    }

    func testCancelCloseEscapeRejectAndDeactivateDropHeldLateReplies() async throws {
        for intent in 0..<5 {
            let h = try AssistantActionHarness()
            h.ui { h.model.write(brief: "Brief") }
            try await h.sent()
            h.ui {
                switch intent {
                case 0: h.model.cancel()
                case 1: h.model.close()
                case 2: h.model.escape()
                case 3: h.model.reject()
                default: h.model.deactivate()
                }
            }
            try await h.artifact()
            try await h.clientReturned()
            h.settle()
            XCTAssertEqual(h.model.state.phase, .idle)
            XCTAssertNil(h.model.state.candidate)
            XCTAssertTrue(h.model.state.transcript.isEmpty)
            XCTAssertTrue(try h.editor.h.files.listFiles().isEmpty)
        }
    }

    func testCancelBeforeWorkerStartsDoesNotReadSecretsOrSendHTTP() async throws {
        let h = try AssistantActionHarness()
        let reads = h.provider.secrets.reads.count
        h.ui { h.model.write(brief: "Brief"); h.model.cancel() }
        h.settle()
        XCTAssertEqual(h.provider.secrets.reads.count, reads)
        let sent = await h.transport.snapshot()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(h.model.state.phase, .idle)
    }

    func testBufferEditDuringRequestKeepsReplyAsStaleDraftUntilNewDiff() async throws {
        let h = try AssistantActionHarness(source: "Original {{topic}}")
        h.ui { h.model.improve() }
        try await h.sent()
        h.editor.ui { h.editor.model.edit("Newer {{topic}}") }
        h.changed()
        try await h.artifact()
        try await h.phase(.draft)
        XCTAssertNotNil(h.model.state.artifact)
        XCTAssertTrue(h.model.state.isStale)
        XCTAssertFalse(h.model.canAccept)
        h.ui { h.model.showDiff() }
        try await h.phase(.ready)
        XCTAssertTrue(h.model.canAccept)
        XCTAssertEqual(h.model.state.candidate?.context.editor?.source, "Newer {{topic}}")
        XCTAssertTrue(try XCTUnwrap(h.model.state.diff).body.contains { $0.kind == .removed && $0.text.contains("Newer") })
    }

    func testEditAwayAndBackDoesNotRestoreAcceptanceEvenWithoutNotification() async throws {
        let h = try AssistantActionHarness(source: "Original")
        h.ui { h.model.improve() }
        try await h.sent()
        try await h.artifact()
        try await h.phase(.ready)
        let before = try XCTUnwrap(h.editor.model.assistantSnapshot)
        h.editor.ui { h.editor.model.edit("Changed"); h.editor.model.edit("Original") }
        let after = try XCTUnwrap(h.editor.model.assistantSnapshot)
        XCTAssertEqual(before.sourceBytes, after.sourceBytes)
        XCTAssertNotEqual(before.revision, after.revision)
        XCTAssertFalse(h.model.canAccept)
        XCTAssertNil(h.model.accept())
        h.ui { h.model.showDiff() }
        try await h.phase(.ready)
    }

    func testDiskConflictInvalidatesAcceptanceAndRetainsArtifactForFreshDiff() async throws {
        let h = try AssistantActionHarness(source: "Original")
        h.editor.ui { h.editor.model.edit("Unsaved") }
        h.ui { h.model.improve() }
        try await h.sent()
        try await h.artifact()
        try await h.phase(.ready)
        try h.editor.change("External edit")
        h.editor.settle()
        h.changed()
        XCTAssertFalse(h.model.canAccept)
        XCTAssertNotNil(h.model.state.artifact)
        h.editor.ui { h.editor.model.resolveConflict(.takeTheirs) }
        h.editor.settle()
        h.changed()
        h.ui { h.model.showDiff() }
        try await h.phase(.ready)
        XCTAssertEqual(h.model.state.candidate?.context.editor?.stamp, h.editor.model.state.stamp)
    }

    func testNewWriteIntentGetsFreshIdentityRatherThanReusingPreviousCandidate() async throws {
        let h = try AssistantActionHarness([.held, .held])
        h.ui { h.model.write(brief: "First") }
        try await h.sent()
        try await h.artifact()
        try await h.phase(.ready)
        let first = try XCTUnwrap(h.model.state.candidate?.content.document.frontMatter.id)
        h.ui { h.model.write(brief: "Second") }
        try await h.sent(2)
        try await h.artifact()
        try await h.phase(.ready)
        XCTAssertNotEqual(first, h.model.state.candidate?.content.document.frontMatter.id)
    }
}
