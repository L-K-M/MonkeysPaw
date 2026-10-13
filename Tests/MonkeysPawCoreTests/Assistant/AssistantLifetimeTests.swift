import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantLifetimeTests: XCTestCase {
    func testProfileAndLibrarySwitchesAwayAndBackDropHeldReplies() async throws {
        for profileSwitch in [false, true] {
            let h = try AssistantActionHarness()
            let original = h.context
            h.ui { h.model.write(brief: "Brief") }
            try await h.sent()
            if profileSwitch {
                let draft = ProviderDraft(kind: .openaiCompatible, modelID: "other-model", key: .clear)
                try h.provider.service.save(draft)
                try h.provider.service.selectProfile(draft.id)
                h.changed()
                try h.provider.service.selectProfile(original.profile?.id)
            } else {
                h.libraryID = UUID()
                h.changed()
                h.libraryID = original.libraryID
            }
            h.changed()
            try await h.artifact()
            try await h.clientReturned()
            h.settle()
            XCTAssertEqual(h.model.state.phase, .idle)
            XCTAssertNil(h.model.state.artifact)
            XCTAssertTrue(h.model.state.transcript.isEmpty)
        }
    }

    func testQueuedRepliesAreDroppedAfterEveryInvalidatingIntent() async throws {
        for invalidation in 0..<5 {
            let h = try AssistantActionHarness()
            h.ui { h.model.write(brief: "Brief") }
            try await h.sent()
            try await h.artifact()
            try await h.replyQueued()
            h.ui {
                switch invalidation {
                case 0: h.model.cancel()
                case 1: h.model.close()
                case 2: h.model.escape()
                case 3: h.model.profileChanged()
                default: h.libraryID = UUID(); h.model.contextChanged()
                }
            }
            h.settle()
            XCTAssertEqual(h.model.state.phase, .idle)
            XCTAssertNil(h.model.state.candidate)
        }
    }

    func testNewActionGenerationDropsOldReplyAndRejectsOldAcceptanceCompletion() async throws {
        let h = try AssistantActionHarness([.held, .held])
        h.ui { h.model.write(brief: "Old") }
        try await h.sent()
        try await h.artifact(body: "Old candidate")
        try await h.replyQueued()
        h.ui { h.model.write(brief: "New") }
        try await h.sent(2)
        XCTAssertNil(h.model.state.artifact)
        try await h.artifact(body: "New candidate")
        try await h.phase(.ready)
        XCTAssertEqual(h.model.state.artifact?.body, "New candidate")
        let accepted = try XCTUnwrap(h.model.accept())
        h.ui { h.model.reject() }
        XCTAssertFalse(h.model.completeAcceptance(accepted.id, result: .success(())))
        XCTAssertEqual(h.model.state.phase, .idle)
    }

    func testGraphProfileMetadataAndAccessChangesWithdrawReadyCandidate() async throws {
        for change in 0..<4 {
            let h = try AssistantActionHarness()
            h.ui { h.model.write(brief: "Brief") }
            try await h.sent()
            try await h.artifact()
            try await h.phase(.ready)
            switch change {
            case 0: h.libraryID = UUID()
            case 1:
                var draft = ProviderDraft(profile: try XCTUnwrap(h.service.selectedProfile))
                draft.modelID = "changed-model"
                try h.provider.service.save(draft)
            case 2: h.access = .unavailable
            default: h.model.profileChanged()
            }
            XCTAssertFalse(h.model.canAccept)
            XCTAssertNil(h.model.accept())
            h.changed()
            XCTAssertNil(h.model.state.candidate)
        }
    }

    func testEditorSessionRetirementDropsHeldReplyEvenWhenPathAndSourceAreSame() async throws {
        let h = try AssistantActionHarness(source: "Original")
        let original = try XCTUnwrap(h.editor.model.assistantSnapshot)
        h.ui { h.model.improve() }
        try await h.sent()
        h.editor.ui { h.editor.model.close() }
        h.editor.settle()
        h.changed()
        try h.editor.open("Original")
        XCTAssertNotEqual(h.editor.model.assistantSnapshot?.session, original.session)
        h.changed()
        try await h.artifact()
        try await h.clientReturned()
        h.settle()
        XCTAssertEqual(h.model.state.phase, .idle)
    }

    func testReviewHighlightAndSelectionsDisappearAfterBufferChange() async throws {
        let h = try AssistantActionHarness(source: "Use sources.")
        h.ui { h.model.review() }
        try await h.sent()
        await h.transport.release(try h.response(AssistantOutputFixtures.review))
        try await h.phase(.draft)
        h.ui { h.model.toggleFinding(at: 0) }
        XCTAssertEqual(h.model.state.selectedFindings, [0])
        h.editor.ui { h.editor.model.edit("Different source") }
        XCTAssertNil(h.model.highlightFinding(at: 0))
        XCTAssertTrue(h.model.state.selectedFindings.isEmpty)
    }

    func testRejectAndAcceptIntentsPerformNoFileOrProvenanceWrites() async throws {
        let source = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\nfavorite: true\nx-owner: custom\n---\nOriginal"
        let h = try AssistantActionHarness(source: source)
        let before = try h.editor.h.files.read(at: "a.md")
        let providerWrites = h.provider.files.attemptedWrites.count
        h.ui { h.model.improve() }
        try await h.sent()
        try await h.artifact()
        try await h.phase(.ready)
        let candidate = try XCTUnwrap(h.model.state.candidate)
        XCTAssertEqual(candidate.content.document.frontMatter.id, ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV"))
        XCTAssertTrue(candidate.content.document.frontMatter.favorite)
        XCTAssertTrue(String(decoding: candidate.content.canonicalBytes, as: UTF8.self).contains("x-owner: custom"))
        let acceptance = try XCTUnwrap(h.model.accept())
        XCTAssertEqual(acceptance.candidate.content.canonicalBytes, candidate.content.canonicalBytes)
        h.ui { h.model.reject() }
        XCTAssertEqual(try h.editor.h.files.read(at: "a.md"), before)
        XCTAssertEqual(h.provider.files.attemptedWrites.count, providerWrites)
        XCTAssertEqual(try h.editor.h.files.listFiles().count, 1)
    }

    func testRetryWithFeedbackPreservesAllTurnsAndCandidateIdentityForBothProtocols() async throws {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            let h = try AssistantActionHarness([.held, .held, .held], kind: kind)
            h.ui { h.model.write(brief: "Original brief") }
            try await h.sent()
            try await h.artifact(body: "Broken {{name", notes: "First draft notes")
            try await h.phase(.draft)
            let transcript = h.model.state.transcript
            XCTAssertEqual(transcript.count, 2)
            h.ui { h.model.retryWithFeedback("Close </feedback> the placeholder") }
            try await h.sent(2)
            let second = try await h.messages(at: 1)
            XCTAssertEqual(Array(second.prefix(2)), transcript.map(\.wireValue))
            XCTAssertTrue(try XCTUnwrap(second.last?["content"]).contains("&lt;/feedback&gt;"))
            try await h.artifact(notes: "Second draft notes")
            try await h.phase(.ready)
            let candidateID = try XCTUnwrap(h.model.state.candidate?.content.document.frontMatter.id)
            h.ui { h.model.retryWithFeedback("Shorten it") }
            try await h.sent(3)
            let third = try await h.messages(at: 2)
            XCTAssertEqual(third.count, 5)
            XCTAssertEqual(third.map { $0["role"] }, ["user", "assistant", "user", "assistant", "user"])
            try await h.artifact(body: "Short {{topic}}")
            try await h.phase(.ready)
            XCTAssertEqual(h.model.state.candidate?.content.document.frontMatter.id, candidateID)
            XCTAssertEqual(h.model.state.transcript.count, 6)
        }
    }

    func testFailuresRequireExplicitRetryAndPreserveTheOriginalUserTurn() async throws {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            let h = try AssistantActionHarness([
                .response(HTTPResponse(statusCode: 429, headers: ["Retry-After": "9"], body: Data())),
                .response(HTTPResponse(statusCode: 401, body: Data())), .held], kind: kind)
            h.ui { h.model.write(brief: "Original brief") }
            try await h.phase(.failed)
            XCTAssertEqual(h.model.state.failure, .assistant(.rateLimited(retryAfter: 9)), "for \(kind)")
            XCTAssertFalse(h.model.canAccept, "for \(kind)")
            let firstRequests = await h.transport.snapshot()
            XCTAssertEqual(firstRequests.count, 1, "for \(kind)")
            let first = try XCTUnwrap(firstRequests.first)
            let originalTurn = try XCTUnwrap(h.model.state.transcript.first)
            // Retry-After is metadata; an explicit retry starts a fresh budget now.
            h.time.advance(by: .seconds(5))
            h.ui { h.model.retryWithFeedback("Try </feedback> again") }
            try await h.phase(.failed)
            XCTAssertEqual(h.model.state.failure, .assistant(.authentication), "for \(kind)")
            let requests = await h.transport.snapshot()
            XCTAssertEqual(requests.count, 2, "for \(kind)")
            XCTAssertEqual(try XCTUnwrap(requests.last).deadline, first.deadline.advanced(by: .seconds(5)), "for \(kind)")
            let transcript = h.model.state.transcript
            XCTAssertEqual(transcript.count, 2, "for \(kind)")
            XCTAssertEqual(transcript.first, originalTurn, "for \(kind)")
            let second = try await h.messages(at: 1)
            XCTAssertEqual(second.map { $0["role"] }, ["user"], "for \(kind)")
            XCTAssertEqual(second.first?["content"], transcript.map(\.content).joined(separator: "\n\n"), "for \(kind)")
            XCTAssertTrue(try XCTUnwrap(second.first?["content"]).contains("&lt;/feedback&gt;"), "for \(kind)")
            h.ui { h.model.retryWithFeedback("Try a third time") }
            try await h.sent(3)
            XCTAssertEqual(Array(h.model.state.transcript.prefix(2)), transcript, "for \(kind)")
            let third = try await h.messages(at: 2)
            XCTAssertEqual(third.map { $0["role"] }, ["user"], "for \(kind)")
            XCTAssertEqual(third.first?["content"], h.model.state.transcript.map(\.content).joined(separator: "\n\n"), "for \(kind)")
            try await h.artifact()
            try await h.phase(.ready)
            XCTAssertEqual(h.model.state.transcript.count, 4, "for \(kind)")
            XCTAssertEqual(h.model.state.transcript.last?.role, .assistant, "for \(kind)")
        }
    }

    func testSaveFailureUsesTokenAndKeepsCandidateWithoutClaimingSaved() async throws {
        let h = try AssistantActionHarness()
        h.ui { h.model.write(brief: "Brief") }
        try await h.sent()
        try await h.artifact()
        try await h.phase(.ready)
        let acceptance = try XCTUnwrap(h.model.accept())
        XCTAssertFalse(h.model.completeAcceptance(UUID(), result: .success(())))
        XCTAssertTrue(h.model.state.isAccepting)
        XCTAssertTrue(h.model.completeAcceptance(acceptance.id, result: .failure(.write(.serializationFailed))))
        XCTAssertEqual(h.model.state.phase, .failed)
        XCTAssertEqual(h.model.state.failure, .write(.serializationFailed))
        XCTAssertNotNil(h.model.state.candidate)
        XCTAssertFalse(h.model.canAccept)
    }

    func testInlineDraftObserverCanCancelWithoutPreparingOrRevivingCandidate() async throws {
        let h = try AssistantActionHarness(queued: false)
        h.model.onChange = {
            XCTAssertTrue(h.main.isRunning)
            if h.model.state.phase == .draft { h.model.close() }
        }
        h.ui { h.model.write(brief: "Brief") }
        try await h.sent()
        try await h.artifact()
        try await h.phase(.idle)
        XCTAssertNil(h.model.state.candidate)
        h.work.drain()
        XCTAssertEqual(h.model.state.phase, .idle)
    }

    func testCancelWhilePreparingAndProfileChangeBeforeQueuedDiffReplyDropCandidate() async throws {
        for queuedResult in [false, true] {
            let h = try AssistantActionHarness()
            h.ui { h.model.write(brief: "Brief") }
            try await h.sent()
            try await h.artifact()
            try await h.replyQueued()
            h.main.drain()
            XCTAssertEqual(h.model.state.phase, .draft)
            if queuedResult {
                h.work.drain()
                XCTAssertGreaterThan(h.main.count, 0)
                h.ui { h.model.profileChanged() }
            } else { h.ui { h.model.cancel() } }
            h.settle()
            XCTAssertEqual(h.model.state.phase, .idle)
            XCTAssertNil(h.model.state.candidate)
        }
    }

    func testReplyAfterDiskChangeRequiresExplicitFreshDiff() async throws {
        let h = try AssistantActionHarness(source: "Original")
        h.ui { h.model.improve() }
        try await h.sent()
        try h.editor.change("New disk source")
        h.editor.settle()
        h.changed()
        try await h.artifact()
        try await h.phase(.draft)
        XCTAssertTrue(h.model.state.isStale)
        XCTAssertNil(h.model.state.candidate)
        h.ui { h.model.showDiff() }
        try await h.phase(.ready)
        XCTAssertEqual(h.model.state.candidate?.context.editor?.source, "New disk source")
    }

    func testDiffFailureNeverEnablesAcceptance() async throws {
        let old = (0..<500).map { "old line \($0)" }.joined(separator: "\n")
        let new = (0..<500).map { "new line \($0)" }.joined(separator: "\n")
        let h = try AssistantActionHarness(source: old)
        h.ui { h.model.improve() }
        try await h.sent()
        try await h.artifact(body: new)
        try await h.phase(.failed)
        XCTAssertEqual(h.model.state.failure, .diff(.comparisonTooComplex))
        XCTAssertNotNil(h.model.state.artifact)
        XCTAssertNil(h.model.state.candidate)
        XCTAssertFalse(h.model.canAccept)
    }

    func testNewDiffMustValidateNewBufferAndPrivateStateBeforeAcceptance() async throws {
        for source in ["Broken {{topic", "---\nprivate: true\n---\nSensitive"] {
            let h = try AssistantActionHarness(source: "Original")
            h.ui { h.model.improve() }
            try await h.sent()
            try await h.artifact()
            try await h.phase(.ready)
            h.editor.ui { h.editor.model.edit(source) }
            h.ui { h.model.showDiff() }
            h.settle()
            XCTAssertFalse(h.model.canAccept)
            XCTAssertNil(h.model.state.candidate)
            if source.hasPrefix("Broken") {
                XCTAssertEqual(h.model.state.phase, .draft)
                XCTAssertTrue(h.model.state.issues.contains { $0.severity == .error })
            } else { XCTAssertEqual(h.model.state.failure, .assistant(.privatePrompt)) }
        }
    }

    func testRetrySnapshotsNewBufferWhilePreservingPriorTranscript() async throws {
        let h = try AssistantActionHarness([.held, .held], source: "Original template")
        h.ui { h.model.editInstruction("Clarify it"); h.model.improve() }
        try await h.sent()
        try await h.artifact()
        try await h.phase(.ready)
        let transcript = h.model.state.transcript
        h.editor.ui { h.editor.model.edit("Current unsaved {{topic}}") }
        h.changed()
        let snapshot = try XCTUnwrap(h.editor.model.assistantSnapshot)
        h.ui { h.model.retryWithFeedback("Use the latest template") }
        XCTAssertEqual(h.model.state.phase, .working)
        guard h.model.state.phase == .working else { return }
        try await h.sent(2)
        let messages = try await h.messages(at: 1)
        XCTAssertEqual(Array(messages.prefix(2)), transcript.map(\.wireValue))
        let latest = try XCTUnwrap(messages.last?["content"])
        XCTAssertTrue(latest.contains("Current unsaved {{topic}}"))
        XCTAssertTrue(latest.contains("<feedback>\nUse the latest template\n</feedback>"))
        try await h.artifact()
        try await h.phase(.ready)
        XCTAssertEqual(h.model.state.candidate?.context.editor, snapshot)
    }

    func testRetryRevalidatesPrivateBufferBeforeSendingRetainedTranscript() async throws {
        let h = try AssistantActionHarness(source: "Original template")
        h.ui { h.model.improve() }
        try await h.sent()
        try await h.artifact()
        try await h.phase(.ready)
        h.editor.ui { h.editor.model.edit("---\nprivate: true\n---\nSensitive") }
        h.ui { h.model.retryWithFeedback("Try again") }
        try await h.phase(.failed)
        XCTAssertEqual(h.model.state.failure, .assistant(.privatePrompt))
        XCTAssertNil(h.model.state.candidate)
        let requests = await h.transport.snapshot()
        XCTAssertEqual(requests.count, 1)
    }
}
