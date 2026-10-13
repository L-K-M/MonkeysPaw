import AppKit
import Carbon.HIToolbox
import Combine
import MonkeysPawCore
import SwiftUI
import XCTest
@testable import MonkeysPaw

/// Real composition and Core clients, held worker jobs and a stub HTTP boundary.
final class MacLibraryAssistantTests: XCTestCase {
    func testNoProfileReadOnlyPrivateAndInvalidReasonsRenderWithoutRequests() throws {
        let unconfigured = try MacLibraryAssistantHarness(configured: false)
        defer { unconfigured.close() }
        let empty = try unconfigured.assistant()
        empty.brief = "A brief"
        XCTAssertFalse(empty.canWrite)
        XCTAssertFalse(empty.canReview)
        XCTAssertEqual(empty.writeDisabledMessage, LibraryAssistantStrings.noProfile)
        XCTAssertEqual(empty.footer, "No active provider")

        for (source, expected) in [
            ("---\nprivate: true\n---\nPrivate source", LibraryAssistantStrings.privatePrompt),
            ("---\nformat: 2\n---\nFuture source", EditorStrings.readOnly(.unsupportedFormat)),
            ("---\ntitle: [broken\n---\nInvalid source", LibraryAssistantStrings.invalid)
        ] {
            let h = try MacLibraryAssistantHarness(source: source)
            defer { h.close() }
            let view = try h.assistant()
            view.brief = "An independent new prompt"
            view.editInstruction("Shorten it")
            XCTAssertTrue(view.canWrite)
            XCTAssertFalse(view.canReview)
            XCTAssertFalse(view.canImprove)
            XCTAssertEqual(view.sourceDisabledMessage, expected)
            view.review(); view.improve()
            h.work.drain()
            XCTAssertEqual(h.transport.requests.count, 0)
            XCTAssertEqual(h.clipboard.reads, 0)
            let host = NSHostingView(rootView: LibraryAssistantView(presentation: view, close: {}))
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
            host.layoutSubtreeIfNeeded()
        }
    }

    func testBusyGuardSaveAndConflictDisableNewRequests() throws {
        let h = try MacLibraryAssistantHarness()
        defer { h.close() }
        let view = try h.assistant()
        view.brief = "Brief"
        h.presentation.edit("Unsaved")
        h.presentation.editor.request(.revert)
        XCTAssertEqual(view.writeDisabledMessage, LibraryAssistantStrings.busy)
        XCTAssertFalse(view.canWrite)
        XCTAssertFalse(view.canReview)
        let decision = try XCTUnwrap(h.presentation.editorState.pendingDecision)
        h.presentation.editor.resolveDecision(.cancel, id: decision.id)
        h.presentation.save()
        XCTAssertEqual(h.presentation.editorState.status, .saving)
        XCTAssertEqual(view.sourceDisabledMessage, LibraryAssistantStrings.busy)
        h.work.drain()
        XCTAssertTrue(view.canReview)
        h.presentation.edit("Mine")
        try h.files.write(Data("Theirs".utf8), at: "one.md")
        h.presentation.save()
        h.work.drain()
        XCTAssertNotNil(h.presentation.editorState.conflict)
        XCTAssertEqual(view.writeDisabledMessage, LibraryAssistantStrings.conflicted)
        XCTAssertFalse(view.canWrite)
        XCTAssertFalse(view.canReview)
        XCTAssertEqual(h.transport.requests.count, 0)
    }

    func testWriteAcceptsExactPreviewBytesAndUsageForBothProviders() throws {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            let h = try MacLibraryAssistantHarness(source: nil, kind: kind)
            defer { h.close() }
            let view = try h.assistant()
            XCTAssertTrue(view.footer.contains("test-model"))
            XCTAssertFalse(view.canReview)
            view.brief = "Write a reusable template"
            try h.request { view.write() }
            XCTAssertTrue(view.isWorking)
            XCTAssertFalse(view.canWrite)
            try h.respond(MacLibraryAssistantHarness.artifact(body: "Use {{topic}}", notes: "session-only notes"))
            let bytes = try XCTUnwrap(view.state.candidate?.content.canonicalBytes)
            XCTAssertTrue(view.footer.contains("12 in / 5 out"))
            XCTAssertTrue(view.canAccept)
            XCTAssertNil(h.presentation.editorState.prompt)
            view.accept()
            h.work.drain()
            let path = try XCTUnwrap(h.presentation.editorState.prompt?.relativePath.string)
            XCTAssertEqual(try h.files.read(at: path), bytes)
            XCTAssertEqual(h.presentation.assistantSaveMessage, "Prompt saved.")
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("session-only notes"))
            XCTAssertFalse(h.presentation.editorState.isDirty)
            XCTAssertEqual(h.clipboard.reads, 0)
            XCTAssertEqual(h.clipboard.writes, 0)
            XCTAssertEqual(h.transport.requests.count, 1)
        }
    }

    func testPrivateWriteSendsOnlyBriefAndRejectWritesNothing() throws {
        let source = "---\nprivate: true\n---\nprivate-template-sentinel"
        let h = try MacLibraryAssistantHarness(source: source)
        defer { h.close() }
        let view = try h.assistant()
        let before = try h.files.read(at: "one.md")
        view.brief = "Independent brief"
        try h.request { view.write() }
        let payload = String(decoding: try XCTUnwrap(h.transport.requests.first?.body), as: UTF8.self)
        XCTAssertTrue(payload.contains("Independent brief"))
        XCTAssertFalse(payload.contains("private-template-sentinel"))
        try h.respond(MacLibraryAssistantHarness.artifact())
        view.reject()
        h.work.drain()
        XCTAssertEqual(view.state.phase, .idle)
        XCTAssertFalse(view.canAccept)
        XCTAssertFalse(view.canRetry)
        XCTAssertEqual(try h.files.read(at: "one.md"), before)
        XCTAssertEqual(try h.files.listFiles().count, 1)
        XCTAssertNil(h.presentation.assistantSaveMessage)
    }

    func testReviewSelectsFindingsHighlightsExactUTF8QuoteAndImproves() throws {
        let source = "Prefix 😀 e\u{301} quoted text"
        let quote = "😀 e\u{301}"
        let h = try MacLibraryAssistantHarness(source: source)
        defer { h.close() }
        let view = try h.assistant()
        try h.request { view.review() }
        try h.respond(["summary": "Two findings", "findings": [
            ["criterion": "clarity", "severity": "high", "quote": quote, "problem": "Unclear", "suggestion": "Clarify"],
            ["criterion": "context", "severity": "low", "quote": "absent", "problem": "Missing", "suggestion": "Explain"]
        ]], phase: .draft)
        XCTAssertFalse(view.canAccept)
        XCTAssertEqual(view.state.review?.findings.map(\.severity), [.high, .low])
        view.toggleFinding(0)
        view.toggleFinding(1)
        XCTAssertEqual(view.state.selectedFindings, [0, 1])
        view.highlightFinding(0)
        let highlight = try XCTUnwrap(h.presentation.quoteHighlight)
        let coordinator = LibrarySourceEditor.Coordinator(onEdit: h.presentation.edit)
        let scroll = LibrarySourceEditor.makeScrollView(coordinator: coordinator)
        let text = try XCTUnwrap(scroll.documentView as? LibrarySourceTextView)
        coordinator.update(text, source: source, path: "one.md", isEditable: true,
            onEdit: h.presentation.edit, highlight: highlight)
        XCTAssertEqual(text.selectedRange(), (source as NSString).range(of: quote))
        XCTAssertEqual(text.string, source)
        XCTAssertFalse(h.presentation.editorState.isDirty)
        view.highlightFinding(1)
        XCTAssertNil(h.presentation.quoteHighlight)
        coordinator.update(text, source: source, path: "one.md", isEditable: true,
            onEdit: h.presentation.edit, highlight: nil)
        XCTAssertNil(text.layoutManager?.temporaryAttribute(.backgroundColor,
            atCharacterIndex: text.selectedRange().location, effectiveRange: nil))
        view.editInstruction("Clarify the template")
        try h.request { view.improve() }
        let request = String(decoding: try XCTUnwrap(h.transport.requests.last?.body), as: UTF8.self)
        XCTAssertTrue(request.contains("Unclear"))
        XCTAssertTrue(request.contains("Missing"))
        XCTAssertTrue(request.contains("Clarify the template"))
        try h.respond(MacLibraryAssistantHarness.artifact(body: "Improved"))
        view.accept()
        h.work.drain()
        XCTAssertEqual(view.state.phase, .saved)
        XCTAssertEqual(PromptCodec.parseFile(try h.files.read(at: "one.md"), filename: "one.md").body, "Improved")
        XCTAssertEqual(h.presentation.assistantSaveMessage, "Prompt saved.")
        coordinator.deactivate()
    }

    func testInstructionOnlyImproveShowsMergedWarningsAndStaleDiffRequiresRefresh() throws {
        let h = try MacLibraryAssistantHarness(source: "{{old}}")
        defer { h.close() }
        let view = try h.assistant()
        view.editInstruction("Rename the placeholder")
        XCTAssertTrue(view.canImprove)
        try h.request { view.improve() }
        try h.respond(MacLibraryAssistantHarness.artifact(body: "{{new}}"))
        XCTAssertEqual(view.state.diff?.placeholderWarnings, [.renamed(from: "old", to: "new")])
        XCTAssertNotNil(view.state.diff?.frontMatter)
        h.presentation.edit("Changed {{old}}")
        XCTAssertTrue(view.state.isStale)
        XCTAssertNil(view.state.diff)
        XCTAssertFalse(view.canAccept)
        XCTAssertEqual(view.resultMessage, LibraryAssistantStrings.stale)
        view.showDiff()
        h.work.drain()
        XCTAssertTrue(view.canAccept)
        let bytes = try XCTUnwrap(view.state.candidate?.content.canonicalBytes)
        view.accept()
        h.work.drain()
        XCTAssertEqual(try h.files.read(at: "one.md"), bytes)
        XCTAssertFalse(h.presentation.editorState.isDirty)
        h.presentation.edit("A newer buffer after the commit")
        XCTAssertTrue(view.state.isStale)
        XCTAssertEqual(view.resultMessage, LibraryAssistantStrings.stale)
        XCTAssertFalse(view.canAccept)
        view.showDiff()
        h.work.drain()
        XCTAssertTrue(view.canAccept)
        XCTAssertEqual(view.resultMessage, LibraryAssistantStrings.phase(.ready))
        view.accept()
        XCTAssertEqual(view.resultMessage, "Saving the accepted candidate…")
        h.work.drain()
        XCTAssertEqual(view.resultMessage, "Prompt saved.")
    }

    func testDraftValidationErrorsDisableAcceptanceAndFeedbackRetryKeepsTranscript() throws {
        let h = try MacLibraryAssistantHarness(source: nil)
        defer { h.close() }
        let view = try h.assistant()
        view.brief = "Brief"
        try h.request { view.write() }
        try h.respond(MacLibraryAssistantHarness.artifact(body: "{{clipboard}}", field: "clipboard"), phase: .draft)
        XCTAssertTrue(view.state.issues.contains { $0.severity == .error })
        XCTAssertFalse(view.canAccept)
        view.feedback = "Remove the reserved field"
        try h.request { view.retry() }
        let payload = String(decoding: try XCTUnwrap(h.transport.requests.last?.body), as: UTF8.self)
        XCTAssertTrue(payload.contains("Remove the reserved field"))
        XCTAssertTrue(payload.contains("clipboard"))
        try h.respond(MacLibraryAssistantHarness.artifact(body: "Valid"))
        XCTAssertTrue(view.canAccept)
        view.reject()
        XCTAssertEqual(try h.files.listFiles().count, 0)
    }

    func testProviderFailureAndAllAcceptanceMessagesAreSanitized() throws {
        let h = try MacLibraryAssistantHarness()
        defer { h.close() }
        let view = try h.assistant()
        view.editInstruction("Improve")
        try h.request { view.improve() }
        try h.respond(MacLibraryAssistantHarness.artifact())
        view.accept()
        h.work.drain()
        let commit = try XCTUnwrap(view.state.acceptanceOutcome?.committed)
        XCTAssertTrue(LibraryAssistantStrings.acceptance(.committedWithProvenanceWarning(commit)).contains("Do not retry the save"))
        XCTAssertTrue(LibraryAssistantStrings.acceptance(.conflict(.changedBuffer)).contains("new diff"))
        XCTAssertTrue(LibraryAssistantStrings.acceptance(.conflict(.deleted)).contains("deleted"))
        XCTAssertTrue(LibraryAssistantStrings.acceptance(.failed(.notReady)).contains("not ready"))
        let unexpected = "provider-body-key-prompt-fill-sentinel"
        XCTAssertFalse(LibraryAssistantStrings.failure(.assistant(.unexpectedStop(unexpected))).contains(unexpected))
        try h.request { view.review() }
        try h.respond([:], phase: .failed, status: 401)
        XCTAssertTrue(view.resultMessage.contains("Authentication failed"))
        XCTAssertFalse(view.canAccept)
        XCTAssertTrue(view.canRetry)
    }

    func testDirtyWriteAcceptanceCanBeCancelledWithoutLosingDraft() throws {
        let h = try MacLibraryAssistantHarness()
        defer { h.close() }
        let view = try h.assistant()
        h.presentation.edit("Unsaved source")
        view.brief = "New prompt"
        try h.request { view.write() }
        try h.respond(MacLibraryAssistantHarness.artifact())
        view.accept()
        XCTAssertTrue(view.state.isAccepting)
        XCTAssertNotNil(h.presentation.editorState.pendingDecision)
        view.cancel()
        h.work.drain()
        XCTAssertNil(h.presentation.editorState.pendingDecision)
        XCTAssertEqual(h.presentation.editorState.source, "Unsaved source")
        XCTAssertTrue(h.presentation.editorState.isDirty)
        XCTAssertEqual(h.presentation.assistantSaveMessage, "Acceptance cancelled.")
        XCTAssertEqual(try h.files.listFiles().count, 1)
        XCTAssertEqual(try h.files.read(at: "one.md"), Data("Original".utf8))
    }

    func testAcceptanceDetectsChangedDiskWithoutOverwritingIt() throws {
        let h = try MacLibraryAssistantHarness()
        defer { h.close() }
        let view = try h.assistant()
        view.editInstruction("Improve")
        try h.request { view.improve() }
        try h.respond(MacLibraryAssistantHarness.artifact())
        try h.files.write(Data("External replacement".utf8), at: "one.md")
        view.accept()
        h.work.drain()
        XCTAssertFalse(view.canAccept)
        XCTAssertTrue(try XCTUnwrap(h.presentation.assistantSaveMessage).contains("changed on disk"))
        XCTAssertEqual(try h.files.read(at: "one.md"), Data("External replacement".utf8))
    }

    func testViewerOffersPrivateCopyAndPreservesOriginal() throws {
        let original = "---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\n---\nOriginal"
        let sourcePath = "Groups/Team/one.md"
        let h = try MacLibraryAssistantHarness(source: original, sourcePath: sourcePath)
        defer { h.close() }
        let service = try XCTUnwrap(h.delegate.assistantService)
        let browser = try XCTUnwrap(h.delegate.libraryBrowserModel)
        let editor = h.presentation.editor
        let graph = UUID()
        h.presentation.rebind(to: browser, editor: editor, libraryPath: h.presentation.activeLibraryPath,
            available: true, makeAssistant: {
                AssistantModel(service: service, main: DispatchMainThread(), context: {
                    AssistantContext(libraryID: graph, profile: service.selectedProfile,
                        editor: editor.assistantSnapshot, access: .group(.viewer))
                })
            })
        h.presentation.showAssistant()
        let view = try h.assistant()
        XCTAssertEqual(view.state.mutationAccess, .privateCopy)
        XCTAssertEqual(view.improveTitle, "Improve a private copy")
        view.editInstruction("Improve a copy")
        try h.request { view.improve() }
        try h.respond(MacLibraryAssistantHarness.artifact(body: "Private improvement"))
        view.accept()
        h.work.drain()
        let path = try XCTUnwrap(h.presentation.editorState.prompt?.relativePath.string)
        XCTAssertFalse(path.contains("/"), "The copy belongs to the personal library root")
        XCTAssertEqual(try h.files.read(at: sourcePath), Data(original.utf8))
        let copy = PromptCodec.parseFile(try h.files.read(at: path), filename: path)
        XCTAssertNotNil(copy.frontMatter.id)
        XCTAssertNotEqual(copy.frontMatter.id, ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PD"))
        // Personal ownership is separate from the flag that blocks LLM calls.
        XCTAssertFalse(copy.frontMatter.isPrivate)
        XCTAssertEqual(copy.body, "Private improvement")
    }

    func testSettingsAndLibraryShareGraphAndCredentialOnlySaveRetiresPreview() throws {
        let h = try MacLibraryAssistantHarness()
        defer { h.close() }
        let service = try XCTUnwrap(h.delegate.assistantService)
        let providers = try XCTUnwrap(h.delegate.providerSettingsService)
        h.delegate.showSettings()
        h.work.drain()
        let settings = try XCTUnwrap(h.delegate.settingsWindow?.presentation.assistant)
        settings.setKeyInput("first-stub-key")
        settings.save()
        h.work.drain()
        let profile = try XCTUnwrap(providers.snapshot.settings.profiles.first)
        let view = try h.assistant()
        view.editInstruction("Improve")
        try h.request { view.improve() }
        try h.respond(MacLibraryAssistantHarness.artifact())
        XCTAssertTrue(view.canAccept)
        settings.setKeyInput("replacement-stub-key")
        settings.save()
        XCTAssertEqual(view.state.phase, .idle, "Revoke the preview before committing a credential change")
        h.work.drain()
        XCTAssertEqual(providers.snapshot.settings.profiles.first, profile, "Non-secret metadata is unchanged")
        XCTAssertFalse(view.canAccept)
        XCTAssertTrue(h.delegate.assistantService === service)
        settings.setModelID("new-model")
        settings.save()
        h.work.drain()
        XCTAssertTrue(view.footer.contains("new-model"))
        XCTAssertEqual(h.transport.requests.count, 1)
    }

    func testEscapeCancelsBeforeFilterAndWindowCloseRetiresModel() throws {
        let h = try MacLibraryAssistantHarness()
        defer { h.close() }
        let view = try h.assistant()
        view.brief = "Brief"
        try h.request { view.write() }
        h.presentation.setFilter("Original")
        let controller = try XCTUnwrap(h.delegate.libraryWindow)
        let window = try XCTUnwrap(controller.window)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape)))
        XCTAssertTrue(controller.handleKeyEvent(escape))
        XCTAssertEqual(view.state.phase, .idle)
        XCTAssertFalse(h.presentation.isAssistantVisible)
        XCTAssertEqual(h.presentation.snapshot.filter, "Original")
        XCTAssertTrue(window.isVisible)
        h.transport.finish(try h.envelope(MacLibraryAssistantHarness.artifact()))
        h.presentation.showAssistant()
        controller.requestClose()
        XCTAssertNil(h.presentation.assistant)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(view.canWrite)
        h.delegate.showLibrary()
        h.work.drain()
        h.presentation.showAssistant()
        XCTAssertFalse(try h.assistant() === view)
        XCTAssertEqual(try h.assistant().state.phase, .idle)
    }

    func testSelectionAndLibrarySwitchDropHeldRepliesAndRetainSharedService() throws {
        let h = try MacLibraryAssistantHarness(secondSource: "Second")
        defer { h.close() }
        let original = try h.assistant()
        let service = try XCTUnwrap(h.delegate.assistantService)
        original.brief = "Brief"
        try h.request { original.write() }
        h.presentation.selectPath("two.md")
        XCTAssertFalse(original.canWrite)
        XCTAssertEqual(try h.assistant().writeDisabledMessage, LibraryAssistantStrings.busy)
        h.work.drain()
        let second = try h.assistant()
        XCTAssertFalse(second === original)
        h.transport.finish(try h.envelope(MacLibraryAssistantHarness.artifact(body: "Obsolete")))
        let otherRoot = h.directory.appendingPathComponent("other", isDirectory: true)
        let otherFiles = try RootedFileStore(root: otherRoot)
        try otherFiles.createRoot()
        try otherFiles.write(Data("Other graph".utf8), at: "one.md")
        second.brief = "Another brief"
        try h.request { second.write() }
        XCTAssertEqual(h.delegate.switchLibrary(to: otherRoot), .switched)
        XCTAssertNil(h.presentation.assistant)
        XCTAssertFalse(second.canWrite)
        XCTAssertTrue(h.delegate.assistantService === service)
        h.transport.finish(try h.envelope(MacLibraryAssistantHarness.artifact(body: "Old graph")))
        h.presentation.selectPath("one.md")
        h.work.drain()
        h.presentation.showAssistant()
        XCTAssertEqual(try h.assistant().state.phase, .idle)
        XCTAssertEqual(try otherFiles.listFiles().count, 1)
        XCTAssertEqual(h.presentation.editorState.source, "Other graph")
    }

    func testWindowCloseWhileWorkingCancelsAndDropsLateOutput() throws {
        let h = try MacLibraryAssistantHarness()
        defer { h.close() }
        let view = try h.assistant()
        view.editInstruction("Improve")
        try h.request { view.improve() }
        h.delegate.libraryWindow?.requestClose()
        XCTAssertNil(h.presentation.assistant)
        XCTAssertFalse(view.canReview)
        let unexpected = expectation(description: "Retired view must not publish a late response")
        unexpected.isInverted = true
        var skipInitial = true
        let observation = view.$state.sink { _ in
            if skipInitial { skipInitial = false } else { unexpected.fulfill() }
        }
        h.transport.finish(try h.envelope(MacLibraryAssistantHarness.artifact()))
        wait(for: [unexpected], timeout: 0.1)
        observation.cancel()
        h.work.drain()
        XCTAssertEqual(try h.files.read(at: "one.md"), Data("Original".utf8))
    }

    func testTimerUsesMainThreadAndStopsAfterCancellation() throws {
        let h = try MacLibraryAssistantHarness()
        defer { h.close() }
        let view = try h.assistant()
        var publications = 0
        let observation = view.$state.sink { _ in
            XCTAssertTrue(Thread.isMainThread)
            publications += 1
        }
        defer { observation.cancel() }
        view.brief = "Brief"
        try h.request { view.write() }
        let count = publications
        let tick = expectation(description: "Scheduled timer hops through MainThread")
        var skipInitial = true
        let tickObservation = view.$state.sink { _ in
            if skipInitial { skipInitial = false } else { tick.fulfill() }
        }
        let scheduler = h.scheduler
        DispatchQueue.global().async { scheduler.fireNext() }
        wait(for: [tick], timeout: 3)
        tickObservation.cancel()
        XCTAssertGreaterThan(publications, count)
        XCTAssertTrue(view.isWorking)
        view.cancel()
        let stopped = publications
        h.scheduler.fireNext()
        XCTAssertEqual(publications, stopped)
        XCTAssertEqual(view.state.phase, .idle)
        XCTAssertEqual(view.state.elapsed, 0)
    }

    func testShortcutAndQuoteRangesRespectWindowAndUnicodeBoundaries() throws {
        let h = try MacLibraryAssistantHarness()
        defer { h.close() }
        h.presentation.closeAssistant()
        let controller = try XCTUnwrap(h.delegate.libraryWindow)
        let window = try XCTUnwrap(controller.window)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "A",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: UInt16(kVK_ANSI_A)))
        XCTAssertTrue(controller.handleKeyEvent(key))
        XCTAssertTrue(h.presentation.isAssistantVisible)
        XCTAssertGreaterThan(window.contentMinSize.width, CGFloat(Limits.setupWindowSize.width))
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let unrelated = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: other.windowNumber, context: nil, characters: "A",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: UInt16(kVK_ANSI_A)))
        XCTAssertFalse(controller.handleKeyEvent(unrelated))
        XCTAssertEqual(LibrarySourceEditor.Coordinator.utf16Range(for: 1..<5, in: "a😀b"), NSRange(location: 1, length: 2))
        XCTAssertNil(LibrarySourceEditor.Coordinator.utf16Range(for: 2..<5, in: "a😀b"))
        XCTAssertNil(LibrarySourceEditor.Coordinator.utf16Range(for: 0..<99, in: "short"))
        let coordinator = LibrarySourceEditor.Coordinator(onEdit: { _ in })
        let scroll = LibrarySourceEditor.makeScrollView(coordinator: coordinator)
        let text = try XCTUnwrap(scroll.documentView as? LibrarySourceTextView)
        coordinator.update(text, source: "a😀b", path: "one.md", isEditable: true, onEdit: { _ in },
            highlight: LibrarySourceHighlight(byteRange: 1..<5, sourceBytes: Data("a😀b".utf8)))
        text.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 1, length: 2))
        XCTAssertTrue(text.hasMarkedText())
        XCTAssertNil(text.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 1, effectiveRange: nil))
        coordinator.deactivate()
    }
}

private final class MacLibraryAssistantHarness {
    let directory: URL
    let files: RootedFileStore
    let work = MacLibraryAssistantWork()
    let scheduler = MacLibraryAssistantScheduler()
    let transport = MacLibraryAssistantTransport()
    let clipboard = MacLibraryAssistantClipboard()
    let delegate: AppDelegate
    private let kind: ProviderKind
    private var isClosed = false
    var presentation: LibraryViewState { delegate.libraryWindow!.presentation }

    init(source: String? = "Original", sourcePath: String = "one.md", configured: Bool = true,
         kind: ProviderKind = .openaiCompatible, secondSource: String? = nil) throws {
        self.kind = kind
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("library", isDirectory: true)
        files = try RootedFileStore(root: root)
        try files.createRoot()
        if let source { try files.write(Data(source.utf8), at: sourcePath) }
        if let secondSource { try files.write(Data(secondSource.utf8), at: "two.md") }
        delegate = AppDelegate(libraryRoot: root, dataRoot: directory.appendingPathComponent("data"),
            backgroundWork: work, httpTransport: transport, secrets: MacLibraryAssistantSecrets(),
            clipboard: clipboard, editorDialog: { _, _, _ in {} }, setActivationPolicy: { _ in }, activateApplication: {},
            makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in false }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, scheduler: scheduler, makeFileWatcher: { _, _ in MacLibraryAssistantWatcher() })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        if configured {
            try XCTUnwrap(delegate.providerSettingsService).save(ProviderDraft(displayName: "Stub", kind: kind,
                baseURL: kind == .anthropic ? "https://api.anthropic.com" : "http://127.0.0.1:11434",
                modelID: "test-model", key: kind == .anthropic ? .replace(SecretValue("stub-anthropic-key")) : .clear))
        }
        delegate.showLibrary()
        if source != nil { presentation.selectPath(RelativePath(sourcePath)) }
        work.drain()
        presentation.showAssistant()
    }

    func assistant() throws -> LibraryAssistantViewState { try XCTUnwrap(presentation.assistant) }

    func request(_ start: () -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        let sent = XCTestExpectation(description: "Stub transport received an explicit request")
        transport.onSend = { sent.fulfill() }
        start()
        work.drain()
        XCTAssertEqual(XCTWaiter().wait(for: [sent], timeout: 3), .completed, file: file, line: line)
        transport.onSend = nil
    }

    func respond(_ output: [String: Any], phase: AssistantPhase = .ready, status: Int = 200,
                 file: StaticString = #filePath, line: UInt = #line) throws {
        let view = try assistant()
        let arrived = XCTestExpectation(description: "Assistant output arrived on the UI thread")
        var fulfilled = false
        let observation = view.$state.sink { state in
            XCTAssertTrue(Thread.isMainThread, file: file, line: line)
            if !fulfilled, state.phase == .draft || state.phase == .failed {
                fulfilled = true
                arrived.fulfill()
            }
        }
        transport.finish(try envelope(output, status: status))
        XCTAssertEqual(XCTWaiter().wait(for: [arrived], timeout: 3), .completed, file: file, line: line)
        observation.cancel()
        work.drain()
        XCTAssertEqual(view.state.phase, phase, file: file, line: line)
    }

    func envelope(_ output: [String: Any], status: Int = 200) throws -> HTTPResponse {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self)
        let json: [String: Any]
        switch kind {
        case .anthropic:
            json = ["content": [["type": "text", "text": text]], "stop_reason": "end_turn",
                "usage": ["input_tokens": 12, "output_tokens": 5]]
        case .openaiCompatible:
            json = ["choices": [["message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
                "usage": ["prompt_tokens": 12, "completion_tokens": 5]]
        }
        return HTTPResponse(statusCode: status, body: try JSONSerialization.data(withJSONObject: json))
    }

    static func artifact(body: String = "Generated", notes: String = "", field: String? = nil) -> [String: Any] {
        let fields: [[String: Any]] = field.map { [["name": $0, "type": "text", "label": $0,
            "description": "", "default": "", "options": [], "optional": false, "remember": false]] } ?? []
        return ["title": "Candidate", "description": "Reusable template", "tags": [], "fields": fields,
            "body": body, "notes": notes]
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate.settingsWindow?.window?.close()
        transport.cancelPending()
        work.drain()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { close() }
}

private final class MacLibraryAssistantWork: BackgroundWork {
    private var jobs: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { jobs.append(work) }
    func drain() {
        for _ in 0..<1_000 {
            guard !jobs.isEmpty else { return }
            jobs.removeFirst()()
        }
        XCTFail("Assistant worker did not settle")
    }
}

private final class MacLibraryAssistantScheduler: MonkeysPawCore.Scheduler {
    private var jobs: [() -> Void] = []
    func after(_ delay: Duration, _ work: @escaping () -> Void) { jobs.append(work) }
    func fireNext() { if !jobs.isEmpty { jobs.removeFirst()() } }
}

private final class MacLibraryAssistantTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [HTTPRequest] = []
    private var replies: [CheckedContinuation<HTTPResponse, Error>] = []
    private var callback: (() -> Void)?
    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return storedRequests }
    var onSend: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); defer { lock.unlock() }; callback = newValue }
    }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { reply in
            lock.lock()
            storedRequests.append(request)
            replies.append(reply)
            let callback = callback
            lock.unlock()
            callback?()
        }
    }
    func finish(_ response: HTTPResponse) {
        lock.lock()
        let reply = replies.isEmpty ? nil : replies.removeFirst()
        lock.unlock()
        XCTAssertNotNil(reply)
        reply?.resume(returning: response)
    }
    func cancelPending() {
        lock.lock()
        let pending = replies
        replies = []
        lock.unlock()
        pending.forEach { $0.resume(throwing: HTTPTransportError.cancelled) }
    }
}

private final class MacLibraryAssistantWatcher: FileStoreWatcher {
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {}
    func stop() {}
}

private final class MacLibraryAssistantClipboard: Clipboard {
    private(set) var reads = 0
    private(set) var writes = 0
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { reads += 1; completion(nil) }
    func writeText(_ text: String) { writes += 1 }
}

private final class MacLibraryAssistantSecrets: SecretStore {
    private var values: [SecretAccount: SecretValue] = [:]
    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        values[account].map { StoredSecret(value: $0, tier: .keychain) }
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier { values[account] = value; return .keychain }
    func delete(account: SecretAccount) throws { values[account] = nil }
}
