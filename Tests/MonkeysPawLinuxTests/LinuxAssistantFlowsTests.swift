#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxAssistantFlowsTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var files: RootedFileStore!
    private var transport: LinuxAssistantFlowTransport!
    private var work: LinuxBackgroundWork!
    private var window: GTK.Widget!
    private let original = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\ntitle: Original\ncustom: keep\n---\nUse 👋 e\u{301} sources. {{topic}}"

    override func setUpWithError() throws {
        _ = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        tools.environment["XDG_CURRENT_DESKTOP"] = "sway"
        transport = LinuxAssistantFlowTransport()
        work = LinuxBackgroundWork()
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            backgroundWork: work, assistantTransport: transport)
        files = try RootedFileStore(root: LinuxPaths(environment: tools.environment).documentsDirectory
            .appendingPathComponent("MonkeysPaw", isDirectory: true))
        try files.createRoot()
        try files.write(Data(original.utf8), at: "a.md")
        try worker {
            try self.environment.providerSettingsService.save(ProviderDraft(displayName: "Local", kind: .openaiCompatible,
                baseURL: "http://localhost:11434/v1", modelID: "test-model", key: .clear))
        }
    }

    override func tearDownWithError() throws {
        transport?.releaseHeld()
        environment?.shutdown()
        environment = nil
        if work != nil { try worker {} }
        drain()
        if let application { GTKTestSupport.destroy(application) }
        drain()
        window = nil
        application = nil
        files = nil
        work = nil
        transport = nil
        tools = nil
    }

    func testWriteShowsFooterDiffAndSavesExactCandidateOnlyOnAccept() throws {
        try open()
        XCTAssertTrue(try label("footer").contains("localhost · test-model"))
        let before = try files.listFiles()
        transport.enqueue(try artifact())
        try input("brief", "Write a reusable template")
        try click("write")
        try ready()
        let model = try XCTUnwrap(environment.assistantModel)
        let bytes = try XCTUnwrap(model.state.candidate?.content.canonicalBytes)
        XCTAssertEqual(try files.listFiles(), before)
        XCTAssertTrue(try text("diff-body-after").contains("Use {{topic}} with sources."))
        XCTAssertTrue(try label("footer").contains("Input: 11 tokens · Output: 7 tokens"))
        XCTAssertTrue(try sensitive("accept"))
        try click("accept")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        drain()
        let path = try XCTUnwrap(environment.editorModel.state.prompt?.relativePath.string)
        XCTAssertNotEqual(path, "a.md")
        XCTAssertEqual(try files.read(at: path), bytes)
        XCTAssertEqual(try files.read(at: "a.md"), Data(original.utf8))
        XCTAssertEqual(try widgetLabel("library-editor-status"), LinuxAssistantStrings.saved)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.selection?.relativePath.string == path })
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testReviewHighlightsExactUnicodeQuoteAndImprovesSelectedFindings() throws {
        try open()
        transport.enqueue(try review())
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_r), GDK_CONTROL_MASK), 0)
        XCTAssertNotEqual(gtk_widget_get_visible(try widget("library-inspector")), 0)
        XCTAssertEqual(gtk_stack_get_visible_child_name(mp_stack(try widget("library-inspector-stack"))).map { String(cString: $0) }, "assistant")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.assistantModel?.state.review != nil })
        drain()
        XCTAssertFalse(try sensitive("accept"))
        XCTAssertTrue(try widgetLabel("assistant-finding-0", check: true).contains("High"))
        try click("quote-0")
        let source = try widget("library-source")
        let range = try XCTUnwrap(environment.assistantModel?.highlightFinding(at: 0))
        let prefix = String(decoding: Data(original.utf8).prefix(range.lowerBound), as: UTF8.self)
        var position = GtkTextIter()
        let buffer = gtk_text_view_get_buffer(mp_text_view(source))!
        let tag = gtk_text_tag_table_lookup(gtk_text_buffer_get_tag_table(buffer), "assistant-quote")
        gtk_text_buffer_get_iter_at_offset(buffer, &position, Int32(prefix.unicodeScalars.count))
        XCTAssertNotEqual(gtk_text_iter_has_tag(&position, tag), 0)
        gtk_text_buffer_get_iter_at_offset(buffer, &position, Int32(prefix.unicodeScalars.count - 1))
        XCTAssertEqual(gtk_text_iter_has_tag(&position, tag), 0)
        XCTAssertFalse(try sensitive("quote-1"))
        gtk_check_button_set_active(mp_check_button(try widget("assistant-finding-0")), 1)
        drain()
        XCTAssertEqual(environment.assistantModel?.state.selectedFindings, [0])
        transport.enqueue(try artifact())
        try click("improve")
        try ready()
        let request = try XCTUnwrap(transport.requests.last?.body)
        XCTAssertTrue(String(decoding: request, as: UTF8.self).contains("Use primary sources"))
        XCTAssertTrue(String(decoding: request, as: UTF8.self).contains("👋"))
        let bytes = try XCTUnwrap(environment.assistantModel?.state.candidate?.content.canonicalBytes)
        XCTAssertTrue(try text("diff-header-after").contains("custom: keep"))
        try click("accept")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.assistantModel?.state.phase == .saved })
        XCTAssertEqual(try files.read(at: "a.md"), bytes)
        XCTAssertFalse(environment.editorModel.state.isDirty)
    }

    func testInstructionOnlyImproveShortcutRejectAndRetryRetainTranscript() throws {
        try open()
        try input("instruction", "Make it shorter")
        transport.enqueue(try artifact())
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_i), GDK_CONTROL_MASK), 0)
        try ready()
        XCTAssertNil(environment.assistantModel?.state.review)
        let count = environment.assistantModel?.state.transcript.count ?? 0
        try input("feedback", "Keep the topic")
        transport.enqueue(try artifact(body: "Short {{topic}}"))
        try click("retry")
        try ready()
        XCTAssertGreaterThan(environment.assistantModel?.state.transcript.count ?? 0, count)
        XCTAssertTrue(String(decoding: try XCTUnwrap(transport.requests.last?.body), as: UTF8.self).contains("Keep the topic"))
        try click("reject")
        drain()
        XCTAssertEqual(environment.assistantModel?.state.phase, .idle)
        XCTAssertNil(environment.assistantModel?.state.candidate)
        XCTAssertEqual(try files.read(at: "a.md"), Data(original.utf8))
        XCTAssertEqual(try files.listFiles().map(\.relativePath), ["a.md"])
    }

    func testCancelEscapeAndPanelCloseDropHeldRepliesAndStopElapsed() throws {
        try open()
        for action in ["cancel", "escape", "close"] {
            try holdImprove()
            let model = try XCTUnwrap(environment.assistantModel)
            XCTAssertTrue(GTKTestSupport.spin(until: { model.state.elapsed >= 1 }, timeout: .seconds(3)))
            if action == "escape" { XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_Escape), GdkModifierType(rawValue: 0)), 0) }
            else { try click(action) }
            XCTAssertTrue(GTKTestSupport.spin { model.state.phase == .idle && self.transport.cancellations > 0 })
            transport.releaseHeld()
            drain()
            XCTAssertNil(model.state.artifact)
            XCTAssertEqual(model.state.elapsed, 0)
            XCTAssertEqual(try files.read(at: "a.md"), Data(original.utf8))
            try showAssistant()
        }
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testAssistantEntryPreeditKeepsEscapeInInputMethod() throws {
        try open()
        transport.enqueue(try artifact())
        try click("improve")
        try ready()
        let model = try XCTUnwrap(environment.assistantModel)
        let candidate = try XCTUnwrap(model.state.candidate?.content.canonicalBytes)
        let transcript = model.state.transcript

        for suffix in ["brief", "instruction", "feedback"] {
            let entry = try widget("assistant-" + suffix)
            XCTAssertNotEqual(gtk_widget_grab_focus(entry), 0)
            let delegate = try XCTUnwrap(mp_entry_text_delegate(entry))
            mp_test_emit_preedit_changed(delegate, "かな")
            XCTAssertEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_Escape), GdkModifierType(rawValue: 0)), 0, suffix)
            XCTAssertTrue(try visible("library-assistant-panel"), suffix)
            XCTAssertEqual(model.state.candidate?.content.canonicalBytes, candidate, suffix)
            XCTAssertEqual(model.state.transcript, transcript, suffix)
            mp_test_emit_preedit_changed(delegate, "")
            guard try visible("library-assistant-panel") else { return }
        }

        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_Escape), GdkModifierType(rawValue: 0)), 0)
        XCTAssertFalse(try visible("library-assistant-panel"))
        XCTAssertEqual(model.state.phase, .idle)
        XCTAssertNil(model.state.candidate)
    }

    func testWorkingRenderSkipsSnapshotChecksUntilReply() throws {
        try open()
        let main = GLibMainThread()
        let config = try RootedFileStore(root: LinuxPaths(environment: tools.environment).configDirectory)
        let service = AssistantService(providerSettings: environment.providerSettingsService,
            anthropic: AnthropicClient(transport: transport),
            openAICompatible: OpenAIClient(transport: transport, providerState: ProviderStateStore(files: config)),
            work: work, main: main)
        let graphID = UUID()
        var contextReads = 0
        let model = AssistantModel(service: service, main: main, context: {
            contextReads += 1
            return AssistantContext(libraryID: graphID, profile: service.selectedProfile,
                editor: self.environment.editorModel.assistantSnapshot, access: .privatePrompt)
        })
        let parent = gtk_application_window_new(application)!
        let panel = LinuxAssistantPanel()
        var highlighted: Range<Int>?
        panel.onHighlight = { highlighted = $0 }
        gtk_window_set_child(mp_window(parent), panel.widget)
        panel.bind(model: model, editor: environment.editorModel, available: true)
        gtk_window_present(mp_window(parent))
        defer { panel.retire(destroyed: false); model.deactivate(); gtk_window_destroy(mp_window(parent)) }

        transport.enqueue(try review())
        panel.start(.review)
        XCTAssertTrue(GTKTestSupport.spin { model.state.review != nil })
        try clickWidget("assistant-quote-0", in: parent)
        XCTAssertNotNil(highlighted)

        transport.hold(try review())
        model.retryWithFeedback("Check the sources again")
        let readsBeforeRendering = contextReads
        drain()
        XCTAssertTrue(GTKTestSupport.spin { self.transport.heldCount == 1 })
        XCTAssertEqual(contextReads, readsBeforeRendering)
        XCTAssertNil(highlighted)
        XCTAssertFalse(try sensitiveWidget("assistant-accept", in: parent))
        XCTAssertTrue(GTKTestSupport.spin(until: { model.state.elapsed >= 1 }, timeout: .seconds(3)))
        drain()
        XCTAssertEqual(contextReads, readsBeforeRendering)

        transport.releaseHeld()
        XCTAssertTrue(GTKTestSupport.spin { model.state.phase == .draft && model.state.review != nil })
        drain()
        XCTAssertGreaterThan(contextReads, readsBeforeRendering)
        XCTAssertTrue(try sensitiveWidget("assistant-quote-0", in: parent))
    }

    func testClosingLibraryMidCallCancelsAndReopensWithFreshEditorModel() throws {
        try open()
        try holdImprove()
        weak var retired = environment.assistantModel
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(self.window) == 0 && self.transport.cancellations == 1 })
        transport.releaseHeld()
        drain()
        XCTAssertNil(retired)
        XCTAssertEqual(try files.read(at: "a.md"), Data(original.utf8))
        try open()
        XCTAssertEqual(environment.assistantModel?.state.phase, .idle)
        XCTAssertNil(environment.assistantModel?.state.artifact)
    }

    func testNativeDestroyMidCallNeverTouchesBorrowedChildren() throws {
        try open()
        try holdImprove()
        gtk_window_destroy(mp_window(window))
        window = nil
        XCTAssertTrue(GTKTestSupport.spin { self.transport.cancellations == 1 })
        transport.releaseHeld()
        drain()
        environment.shutdown()
        drain()
        XCTAssertEqual(try files.read(at: "a.md"), Data(original.utf8))
    }

    func testLibrarySwitchMidCallRetiresModelAndIgnoresOldGraphReply() throws {
        try open()
        try holdImprove()
        weak var retired = environment.assistantModel
        let directory = tools.directory.appendingPathComponent("replacement")
        let replacement = try RootedFileStore(root: directory)
        try replacement.createRoot()
        try replacement.write(Data("Replacement".utf8), at: "b.md")
        XCTAssertEqual(environment.switchLibrary(to: directory), .switched)
        XCTAssertTrue(GTKTestSupport.spin { self.transport.cancellations == 1 })
        XCTAssertNil(retired)
        transport.releaseHeld()
        drain()
        XCTAssertNil(environment.assistantModel?.state.artifact)
        XCTAssertEqual(environment.assistantModel?.state.phase, .idle)
        XCTAssertEqual(try files.read(at: "a.md"), Data(original.utf8))
        XCTAssertEqual(try replacement.listFiles().map(\.relativePath), ["b.md"])
    }

    func testSelectionChangeRetiresSessionWithoutClosingReusablePanel() throws {
        try files.write(Data("Other".utf8), at: "b.md")
        try open()
        try holdImprove()
        weak var retired = environment.assistantModel
        try select("b.md")
        XCTAssertTrue(GTKTestSupport.spin { self.transport.cancellations == 1 })
        XCTAssertNil(retired)
        transport.releaseHeld()
        drain()
        XCTAssertTrue(try visible("library-assistant-panel"))
        XCTAssertEqual(environment.assistantModel?.state.phase, .idle)
        XCTAssertNil(environment.assistantModel?.state.artifact)
    }

    func testHiddenPanelRebindClearsAllSessionInputs() throws {
        try open()
        let model = try XCTUnwrap(environment.assistantModel)
        let parent = gtk_application_window_new(application)!
        let panel = LinuxAssistantPanel()
        gtk_window_set_child(mp_window(parent), panel.widget)
        defer { panel.retire(destroyed: false); gtk_window_destroy(mp_window(parent)) }
        panel.bind(model: model, editor: environment.editorModel, available: true)
        for suffix in ["brief", "instruction", "feedback"] {
            mp_entry_set_text(try widget("assistant-" + suffix, in: parent), "Previous session")
        }
        panel.bind(model: nil, editor: environment.editorModel, available: true)
        for suffix in ["brief", "instruction", "feedback"] {
            XCTAssertEqual(String(cString: mp_entry_text(try widget("assistant-" + suffix, in: parent))), "", suffix)
        }
        model.editInstruction("Current instruction")
        panel.bind(model: model, editor: environment.editorModel, available: true)
        panel.show()
        drain()
        XCTAssertEqual(String(cString: mp_entry_text(try widget("assistant-instruction", in: parent))), "Current instruction")
    }

    func testDestroyedPanelClearsQuoteInSurvivingEditor() throws {
        try open()
        let model = try XCTUnwrap(environment.assistantModel)
        let parent = gtk_application_window_new(application)!
        let panel = LinuxAssistantPanel()
        let source = try widget("library-source")
        let buffer = try XCTUnwrap(gtk_text_view_get_buffer(mp_text_view(source)))
        let tag = try XCTUnwrap(gtk_text_tag_table_lookup(gtk_text_buffer_get_tag_table(buffer), "assistant-quote"))
        var highlighted: Range<Int>?
        panel.onHighlight = { range in
            highlighted = range
            if range == nil {
                var start = GtkTextIter(), end = GtkTextIter()
                gtk_text_buffer_get_bounds(buffer, &start, &end)
                gtk_text_buffer_remove_tag(buffer, tag, &start, &end)
            }
        }
        gtk_window_set_child(mp_window(parent), panel.widget)
        panel.bind(model: model, editor: environment.editorModel, available: true)
        gtk_window_present(mp_window(parent))
        transport.enqueue(try review())
        panel.start(.review)
        XCTAssertTrue(GTKTestSupport.spin { model.state.review != nil })
        try clickWidget("assistant-quote-0", in: parent)
        let range = try XCTUnwrap(highlighted)
        let prefix = String(decoding: Data(original.utf8).prefix(range.lowerBound), as: UTF8.self)
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &start, Int32(prefix.unicodeScalars.count))
        gtk_text_buffer_get_iter_at_offset(buffer, &end, Int32(prefix.unicodeScalars.count + 1))
        gtk_text_buffer_apply_tag(buffer, tag, &start, &end)
        gtk_window_destroy(mp_window(parent))
        panel.retire(destroyed: true)
        drain()
        XCTAssertNil(highlighted)
        XCTAssertNil(panel.onHighlight)
        gtk_text_buffer_get_iter_at_offset(buffer, &start, Int32(prefix.unicodeScalars.count))
        XCTAssertEqual(gtk_text_iter_has_tag(&start, tag), 0)
    }

    func testUnavailableAssistantShortcutsLeaveKeysAndPanelAlone() throws {
        try open()
        gtk_widget_set_visible(window, 0)
        var suppliedModel = environment.assistantModel
        let library = LinuxLibraryWindow(application: application, browser: environment.libraryBrowserModel,
            editor: environment.editorModel, assistant: { suppliedModel }, openFolder: {})
        library.show()
        window = try XCTUnwrap(nativeWindow(LinuxStrings.library))
        defer { library.tearDown() }
        let model = try XCTUnwrap(suppliedModel)
        suppliedModel = nil
        for key in [GDK_KEY_r, GDK_KEY_i] {
            XCTAssertEqual(mp_test_emit_key_pressed(window, UInt32(key), GDK_CONTROL_MASK), 0)
            XCTAssertFalse(try visible("library-assistant-panel"))
        }
        suppliedModel = model
        library.setLibraryAvailable(false)
        for key in [GDK_KEY_R, GDK_KEY_I] {
            XCTAssertEqual(mp_test_emit_key_pressed(window, UInt32(key), GDK_CONTROL_MASK), 0)
            XCTAssertFalse(try visible("library-assistant-panel"))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testDisabledTemplateShortcutsDoNotConsumeKeysOrStartRequests() throws {
        try files.write(Data("---\nprivate: true\n---\nPrivate".utf8), at: "private.md")
        try files.write(Data("---\nformat: 2\n---\nFuture".utf8), at: "future.md")
        try files.write(Data("---\ntitle: [\n---\nInvalid".utf8), at: "invalid.md")
        for path in ["private.md", "future.md", "invalid.md"] {
            try open(path)
            XCTAssertFalse(try sensitive("review"), path)
            XCTAssertFalse(try sensitive("improve"), path)
            for key in [GDK_KEY_r, GDK_KEY_i] {
                XCTAssertEqual(mp_test_emit_key_pressed(window, UInt32(key), GDK_CONTROL_MASK), 0, path)
            }
            XCTAssertTrue(transport.requests.isEmpty)
        }
        try select("a.md")
        try holdImprove()
        for key in [GDK_KEY_r, GDK_KEY_i] {
            XCTAssertEqual(mp_test_emit_key_pressed(window, UInt32(key), GDK_CONTROL_MASK), 0)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testBusyAcceptanceOutcomeSurvivesBusyRenders() throws {
        try assertOutcomeDuringSave(.editorBusy)
    }

    func testMissingQuoteTagDoesNotCallGTKWithNil() throws {
        let parent = gtk_application_window_new(application)!
        let source = LinuxLibrarySourceEditor()
        gtk_window_set_child(mp_window(parent), source.widget)
        defer { gtk_window_destroy(mp_window(parent)) }
        let buffer = try XCTUnwrap(gtk_text_view_get_buffer(mp_text_view(source.widget)))
        let table = try XCTUnwrap(gtk_text_buffer_get_tag_table(buffer))
        let tag = try XCTUnwrap(gtk_text_tag_table_lookup(table, "assistant-quote"))
        gtk_text_tag_table_remove(table, tag)
        source.highlight(nil)
        source.highlight(0..<1)
    }

    func testCancelledAcceptanceOutcomeSurvivesBusyRenders() throws {
        try assertOutcomeDuringSave(.cancelled)
    }

    private func assertOutcomeDuringSave(_ failure: AssistantAcceptanceFailure) throws {
        try open()
        transport.enqueue(try artifact())
        try click("improve")
        try ready()
        let model = try XCTUnwrap(environment.assistantModel)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        var blocked = false
        work.run { GTK.onMainLoop { blocked = true }; gate.wait() }
        XCTAssertTrue(GTKTestSupport.spin { blocked })
        // The native click starts acceptance before a competing save. Its
        // queued acceptance guard must report the actual busy/cancelled result.
        GTK.onSignal(try widget("assistant-accept"), "clicked") {
            self.environment.editorModel.save()
            if failure == .cancelled { model.cancel() }
        }
        try click("accept")
        XCTAssertEqual(environment.editorModel.state.status, .saving)
        let stamp = environment.editorModel.state.stamp
        let expected = LinuxAssistantStrings.outcome(.failed(failure))
        XCTAssertEqual(try widgetLabel("library-editor-status"), expected)
        environment.libraryBrowserModel.setFilter("Original")
        drain()
        XCTAssertEqual(try widgetLabel("library-editor-status"), expected)
        gate.signal()
        try worker {}
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        drain()
        XCTAssertNotEqual(environment.editorModel.state.stamp, stamp)
        XCTAssertEqual(try widgetLabel("library-editor-status"), LinuxEditorStrings.status(environment.editorModel.state))
        environment.editorModel.revert()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .idle })
        drain()
        XCTAssertEqual(try widgetLabel("library-editor-status"), LinuxEditorStrings.status(environment.editorModel.state))
    }

    func testUndecodableEditorSessionChangeCancelsWriteWithoutSnapshot() throws {
        try files.write(Data([0xff]), at: "bytes-a.md")
        try files.write(Data([0xfe]), at: "bytes-b.md")
        try open("bytes-a.md")
        XCTAssertNil(environment.editorModel.assistantSnapshot)
        XCTAssertNotNil(environment.editorModel.assistantSession)
        let session = environment.editorModel.assistantSession
        let old = try XCTUnwrap(environment.assistantModel)
        transport.hold(try artifact())
        try input("brief", "Write a new prompt")
        try click("write")
        XCTAssertTrue(GTKTestSupport.spin { self.transport.heldCount == 1 })
        try select("bytes-b.md")
        XCTAssertNil(environment.editorModel.assistantSnapshot)
        XCTAssertNotEqual(environment.editorModel.assistantSession, session)
        XCTAssertTrue(GTKTestSupport.spin { self.transport.cancellations == 1 })
        XCTAssertFalse(environment.assistantModel === old)
        transport.releaseHeld()
        drain()
        XCTAssertEqual(environment.assistantModel?.state.phase, .idle)
        XCTAssertNil(environment.assistantModel?.state.artifact)
    }

    func testChangedBufferAwayAndBackRequiresNewDiffBeforeAccept() throws {
        try open()
        transport.enqueue(try artifact())
        try input("instruction", "Improve")
        try click("improve")
        try ready()
        let source = try widget("library-source")
        setText(source, original + " changed")
        setText(source, original)
        drain()
        XCTAssertTrue(environment.assistantModel?.state.isStale == true)
        XCTAssertFalse(try sensitive("accept"))
        XCTAssertTrue(try label("explanation").contains("Show diff again"))
        try click("show-diff")
        try ready()
        XCTAssertTrue(try sensitive("accept"))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testEditsDuringHeldRequestLeaveArtifactStaleUntilFreshDiff() throws {
        try open()
        try holdImprove()
        setText(try widget("library-source"), original + "\nNew edit")
        transport.releaseHeld()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.assistantModel?.state.artifact != nil })
        drain()
        XCTAssertTrue(environment.assistantModel?.state.isStale == true)
        XCTAssertFalse(try sensitive("accept"))
        try click("show-diff")
        try ready()
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testDiskChangeWithdrawsPreviewAndConflictBlocksActions() throws {
        try open()
        transport.enqueue(try artifact())
        try click("improve")
        try ready()
        try files.write(Data((original + "\nExternal").utf8), at: "a.md")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.source?.contains("External") == true })
        drain()
        XCTAssertFalse(try sensitive("accept"))
        try click("show-diff")
        try ready()
        setText(try widget("library-source"), original + "\nMine")
        try files.write(Data((original + "\nTheirs").utf8), at: "a.md")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.conflict != nil })
        drain()
        XCTAssertFalse(try sensitive("write"))
        XCTAssertFalse(try sensitive("improve"))
        XCTAssertTrue(try label("explanation").contains("conflict"))
        XCTAssertFalse(try sensitive("accept"))
    }

    func testPrivateReadOnlyNoProfileAndBusyStatesExplainDisabledActions() throws {
        try files.write(Data("---\nprivate: true\n---\nPrivate".utf8), at: "private.md")
        try files.write(Data("---\nformat: 2\n---\nFuture".utf8), at: "future.md")
        try open("private.md")
        XCTAssertTrue(environment.editorModel.state.isPrivate)
        XCTAssertFalse(try sensitive("review"))
        XCTAssertFalse(try sensitive("improve"))
        XCTAssertTrue(try sensitive("write"))
        XCTAssertTrue(try label("explanation").contains("private"))
        setText(try widget("library-source"), "---\nprivate: false\n---\nPrivate")
        drain()
        XCTAssertFalse(environment.editorModel.state.isPrivate)
        XCTAssertTrue(try sensitive("review"))
        environment.editorModel.request(.revert)
        drain()
        XCTAssertFalse(try sensitive("write"))
        XCTAssertTrue(try label("explanation").contains("decision"))
        let decision = try XCTUnwrap(environment.editorModel.state.pendingDecision, "Revert must request a discard decision")
        environment.editorModel.resolveDecision(.discard, id: decision.id)
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.editorModel.state.isDirty && self.environment.editorModel.state.status != .loading })
        try select("future.md")
        XCTAssertFalse(try sensitive("review"))
        XCTAssertTrue(try sensitive("write"))
        XCTAssertTrue(try label("explanation").contains("Read-only"))
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { self.nativeWindow(LinuxStrings.settings) != nil })
        let settings = try XCTUnwrap(nativeWindow(LinuxStrings.settings))
        try GTKTestSupport.selectAssistantTab(in: settings)
        XCTAssertTrue(GTKTestSupport.spin { (try? self.sensitiveWidget("settings-assistant-disable", in: settings)) == true })
        try clickWidget("settings-assistant-disable", in: settings)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.assistantModel?.state.providerHost == nil })
        drain()
        XCTAssertFalse(try sensitive("write"))
        XCTAssertTrue(try label("explanation").contains("Set up a provider"))
        for key in [GDK_KEY_r, GDK_KEY_i] {
            XCTAssertEqual(mp_test_emit_key_pressed(window, UInt32(key), GDK_CONTROL_MASK), 0)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCredentialOnlySaveAfterSettingsHideInvalidatesHeldAction() throws {
        try open()
        try holdImprove()
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { self.nativeWindow(LinuxStrings.settings) != nil })
        let settings = try XCTUnwrap(nativeWindow(LinuxStrings.settings))
        try GTKTestSupport.selectAssistantTab(in: settings)
        XCTAssertTrue(GTKTestSupport.spin { (try? self.sensitiveWidget("settings-assistant-save", in: settings)) == true })
        let profile = environment.providerSettingsService.snapshot.settings
        // A byte-identical Save still invalidates actions; credentials can have
        // changed without changing the published non-secret profile.
        try clickWidget("settings-assistant-save", in: settings)
        gtk_window_close(mp_window(settings))
        XCTAssertTrue(GTKTestSupport.spin { self.transport.cancellations == 1 })
        transport.releaseHeld()
        try worker {}
        drain()
        XCTAssertEqual(environment.providerSettingsService.snapshot.settings, profile)
        XCTAssertEqual(environment.assistantModel?.state.phase, .idle)
        XCTAssertNil(environment.assistantModel?.state.artifact)
        XCTAssertEqual(try files.read(at: "a.md"), Data(original.utf8))
    }

    func testReselectingActiveProfileKeepsConversationAndHeldRequest() throws {
        let other = ProviderDraft(displayName: "Other", kind: .openaiCompatible,
            baseURL: "http://localhost:11434/v1", modelID: "other-model", key: .clear)
        try worker { try self.environment.providerSettingsService.save(other) }
        try open()
        try holdImprove()
        let model = try XCTUnwrap(environment.assistantModel)
        let transcript = model.state.transcript
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { self.nativeWindow(LinuxStrings.settings) != nil })
        let settings = try XCTUnwrap(nativeWindow(LinuxStrings.settings))
        try GTKTestSupport.selectAssistantTab(in: settings)
        XCTAssertTrue(GTKTestSupport.spin { (try? self.sensitiveWidget("settings-assistant-save", in: settings)) == true })
        let profiles = try widget("settings-assistant-profiles", in: settings)
        let name = try widget("settings-assistant-name", in: settings)
        mp_entry_set_text(name, "Staged name")
        drain()
        gtk_list_box_unselect_all(mp_list_box(profiles))
        gtk_list_box_select_row(mp_list_box(profiles), gtk_list_box_get_row_at_index(mp_list_box(profiles), 0))
        drain()
        try worker {}
        XCTAssertTrue(GTKTestSupport.spin { String(cString: mp_entry_text(name)) == "Local" })
        XCTAssertEqual(model.state.phase, .working)
        XCTAssertEqual(model.state.transcript, transcript)
        XCTAssertEqual(transport.cancellations, 0)

        transport.releaseHeld()
        try ready()
        let candidate = try XCTUnwrap(model.state.candidate?.content.canonicalBytes)
        let completedTranscript = model.state.transcript
        gtk_list_box_unselect_all(mp_list_box(profiles))
        gtk_list_box_select_row(mp_list_box(profiles), gtk_list_box_get_row_at_index(mp_list_box(profiles), 0))
        drain()
        try worker {}
        XCTAssertEqual(model.state.phase, .ready)
        XCTAssertEqual(model.state.candidate?.content.canonicalBytes, candidate)
        XCTAssertEqual(model.state.transcript, completedTranscript)

        gtk_list_box_select_row(mp_list_box(profiles), gtk_list_box_get_row_at_index(mp_list_box(profiles), 1))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.providerSettingsService.snapshot.settings.selectedProfileID == other.id
            && model.state.phase == .idle })
        XCTAssertNil(model.state.candidate)
        XCTAssertTrue(model.state.transcript.isEmpty)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testCommittedProvenanceWarningIsVisibleAndDoesNotInviteAnotherSave() throws {
        try open()
        let data = try RootedFileStore(root: LinuxPaths(environment: tools.environment).dataDirectory)
        try data.createRoot()
        try data.write(Data("invalid-json".utf8), at: "history/01ARZ3NDEKTSV4RRFFQ69G5FAV/head.json")
        transport.enqueue(try artifact())
        try click("improve")
        try ready()
        let candidate = try XCTUnwrap(environment.assistantModel?.state.candidate?.content.canonicalBytes)
        try click("accept")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        drain()
        guard case .committedWithProvenanceWarning = environment.assistantModel?.state.acceptanceOutcome else {
            return XCTFail("Expected an explicit committed provenance warning")
        }
        XCTAssertEqual(try files.read(at: "a.md"), candidate)
        XCTAssertEqual(try widgetLabel("library-editor-status"), LinuxEditorStrings.provenanceWarning)
        XCTAssertEqual(try label("status"), LinuxEditorStrings.provenanceWarning)
        XCTAssertFalse(try sensitive("accept"))
    }

    func testAcceptanceMessageYieldsToSubsequentEditorReload() throws {
        try open()
        transport.enqueue(try artifact())
        try click("improve")
        try ready()
        try click("accept")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .saved })
        drain()
        XCTAssertEqual(try widgetLabel("library-editor-status"), LinuxAssistantStrings.saved)
        let accepted = try files.read(at: "a.md")
        try files.write(accepted + Data("\nExternal addition".utf8), at: "a.md")
        environment.editorModel.revert()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.status == .idle })
        drain()
        XCTAssertTrue(environment.editorModel.state.source?.contains("External addition") == true)
        XCTAssertEqual(try widgetLabel("library-editor-status"), LinuxEditorStrings.status(environment.editorModel.state))
    }

    func testViewerGetsPrivateCopyAndAccessChangeDropsCandidate() throws {
        try open()
        let main = GLibMainThread()
        let config = try RootedFileStore(root: LinuxPaths(environment: tools.environment).configDirectory)
        try config.createRoot()
        let service = AssistantService(providerSettings: environment.providerSettingsService,
            anthropic: AnthropicClient(transport: transport),
            openAICompatible: OpenAIClient(transport: transport, providerState: ProviderStateStore(files: config)),
            work: work, main: main)
        let graphID = UUID()
        var access = AssistantAccessState.group(.viewer)
        let model = AssistantModel(service: service, main: main, context: {
            AssistantContext(libraryID: graphID, profile: service.selectedProfile,
                editor: self.environment.editorModel.assistantSnapshot, access: access)
        })
        let parent = gtk_application_window_new(application)!
        let panel = LinuxAssistantPanel()
        gtk_window_set_child(mp_window(parent), panel.widget)
        panel.bind(model: model, editor: environment.editorModel, available: true)
        panel.show()
        gtk_window_present(mp_window(parent))
        defer { panel.retire(destroyed: false); model.deactivate(); gtk_window_destroy(mp_window(parent)) }
        XCTAssertEqual(String(cString: gtk_button_get_label(mp_button(try widget("assistant-improve", in: parent)))), "Improve a private copy")
        XCTAssertTrue(String(cString: gtk_label_get_text(mp_label(try widget("assistant-explanation", in: parent)))).contains("group prompt will be kept"))
        transport.enqueue(try artifact())
        try clickWidget("assistant-improve", in: parent)
        XCTAssertTrue(GTKTestSupport.spin { model.state.phase == .ready })
        access = .unavailable
        model.contextChanged()
        drain()
        XCTAssertFalse(model.canAccept)
        XCTAssertFalse(try sensitiveWidget("assistant-improve", in: parent))
        access = .group(.viewer)
        model.contextChanged()
        transport.enqueue(try artifact())
        try clickWidget("assistant-improve", in: parent)
        XCTAssertTrue(GTKTestSupport.spin { model.state.phase == .ready })
        let candidate = try XCTUnwrap(model.state.candidate?.content.canonicalBytes)
        try clickWidget("assistant-accept", in: parent)
        XCTAssertTrue(GTKTestSupport.spin { model.state.phase == .saved })
        let path = try XCTUnwrap(environment.editorModel.state.prompt?.relativePath.string)
        XCTAssertNotEqual(path, "a.md")
        XCTAssertEqual(try files.read(at: path), candidate)
        XCTAssertEqual(try files.read(at: "a.md"), Data(original.utf8))
        XCTAssertFalse(path.contains("/"), "A viewer's copy belongs to the private library root")
    }

    func testValidationIssuesPlaceholderWarningsAndProviderFailuresAreVisible() throws {
        try open()
        transport.enqueue(try artifact(body: "Use {{newtopic}} {{other}}"))
        try click("improve")
        try ready()
        XCTAssertTrue(try label("issues").contains("Placeholder removed: topic"))
        XCTAssertTrue(try label("issues").contains("Placeholder added: newtopic"))
        try click("reject")
        transport.enqueue(try artifact(body: "Invalid {{bad name}}", fields: [["name": "clipboard", "type": "text", "label": "", "description": "", "default": "", "options": [], "optional": false, "remember": false]]))
        try click("improve")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.assistantModel?.state.phase == .draft && self.environment.assistantModel?.state.artifact != nil })
        drain()
        XCTAssertFalse(try sensitive("accept"))
        XCTAssertTrue(try label("issues").contains("Error"))
        XCTAssertTrue(try text("draft").contains("Invalid"))
        let sentinel = "provider-body-" + UUID().uuidString
        transport.enqueue(HTTPResponse(statusCode: 401, body: Data(sentinel.utf8)))
        try click("retry")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.assistantModel?.state.phase == .failed })
        drain()
        XCTAssertTrue(try label("status").contains("Authentication failed"))
        XCTAssertFalse(try label("status").contains(sentinel))
        XCTAssertEqual(try files.read(at: "a.md"), Data(original.utf8))
    }

    private func open(_ path: String = "a.md") throws {
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { self.nativeWindow(LinuxStrings.library).map { gtk_widget_get_visible($0) != 0 } == true })
        window = try XCTUnwrap(nativeWindow(LinuxStrings.library))
        try select(path)
        try showAssistant()
        drain()
    }

    // The old assistant button is now the inspector's Assistant page, exposed
    // as the win.assistant window action on the header bar menu.
    private func showAssistant() throws {
        XCTAssertTrue(GTKTestSupport.spin {
            g_action_group_get_action_enabled(mp_window_action_group(self.window), "assistant") != 0
        }, "win.assistant stays disabled")
        g_action_group_activate_action(mp_window_action_group(window), "assistant", nil)
        drain()
    }

    private func select(_ path: String) throws {
        drain()
        let index = try XCTUnwrap(environment.libraryBrowserModel.rows.firstIndex { $0.relativePath.string == path })
        let list = try widget("library-list")
        let row = try XCTUnwrap(gtk_list_box_get_row_at_index(mp_list_box(list), Int32(index)), "No Library row at index \(index) for \(path)")
        gtk_list_box_select_row(mp_list_box(list), row)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.prompt?.relativePath.string == path
            && self.environment.editorModel.state.status != .loading })
        drain()
    }

    private func holdImprove() throws {
        transport.hold(try artifact())
        try click("improve")
        let working = GTKTestSupport.spin { self.transport.heldCount == 1 && self.environment.assistantModel?.state.phase == .working }
        let message = "Held request: \(try label("status")); \(try label("explanation")); requests=\(transport.requests.count)"
        XCTAssertTrue(working, message)
    }

    private func ready() throws {
        let ready = GTKTestSupport.spin { self.environment.assistantModel?.state.phase == .ready }
        let message = "Ready: \(try label("status")); \(try label("explanation")); requests=\(transport.requests.count)"
        XCTAssertTrue(ready, message)
        drain()
        XCTAssertNotNil(environment.assistantModel?.state.candidate)
    }

    private func artifact(body: String = "Use {{topic}} with sources.", fields: [[String: Any]] = []) throws -> HTTPResponse {
        try response(["title": "Generated", "description": "Reusable", "tags": ["research"], "fields": fields, "body": body, "notes": "Changed the wording."])
    }

    private func review() throws -> HTTPResponse {
        try response(["summary": "Make sources verifiable.", "findings": [
            ["criterion": "verifiability", "severity": "high", "quote": "👋 e\u{301} sources.", "problem": "Sources are vague", "suggestion": "Use primary sources"],
            ["criterion": "clarity", "severity": "low", "quote": "Not present", "problem": "Unmatched", "suggestion": "Check manually"]]])
    }

    private func response(_ object: [String: Any]) throws -> HTTPResponse {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["content": text]]], "usage": ["prompt_tokens": 11, "completion_tokens": 7]]))
    }

    private func widget(_ name: String, in root: GTK.Widget? = nil) throws -> GTK.Widget {
        try XCTUnwrap(find(root ?? window, name: name), "Missing \(name)")
    }
    private func find(_ widget: GTK.Widget, name: String) -> GTK.Widget? {
        if String(cString: gtk_widget_get_name(widget)) == name { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let found = find(current, name: name) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }
    private func click(_ suffix: String) throws { try clickWidget("assistant-" + suffix) }
    private func clickWidget(_ name: String, in root: GTK.Widget? = nil) throws {
        drain()
        let button = try widget(name, in: root)
        _ = try XCTUnwrap(gtk_widget_is_sensitive(button) != 0 ? button : nil, "Button \(name) is insensitive")
        var instance = GValue()
        g_value_init(&instance, gtk_button_get_type())
        g_value_set_object(&instance, button)
        g_signal_emitv(&instance, g_signal_lookup("clicked", gtk_button_get_type()), 0, nil)
        g_value_unset(&instance)
        drain()
    }
    private func input(_ suffix: String, _ text: String) throws { mp_entry_set_text(try widget("assistant-" + suffix), text); drain() }
    private func label(_ suffix: String) throws -> String { try widgetLabel("assistant-" + suffix) }
    private func widgetLabel(_ name: String, check: Bool = false) throws -> String {
        let widget = try widget(name)
        return String(cString: check ? gtk_check_button_get_label(mp_check_button(widget)) : gtk_label_get_text(mp_label(widget)))
    }
    private func sensitive(_ suffix: String) throws -> Bool { try sensitiveWidget("assistant-" + suffix) }
    private func sensitiveWidget(_ name: String, in root: GTK.Widget? = nil) throws -> Bool { gtk_widget_is_sensitive(try widget(name, in: root)) != 0 }
    private func visible(_ name: String) throws -> Bool { gtk_widget_get_visible(try widget(name)) != 0 }
    private func text(_ suffix: String) throws -> String {
        let buffer = gtk_text_view_get_buffer(mp_text_view(try widget("assistant-" + suffix)))!
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        let text = gtk_text_buffer_get_text(buffer, &start, &end, 0)!
        defer { g_free(text) }
        return String(cString: text)
    }
    private func setText(_ widget: GTK.Widget, _ text: String) {
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(widget)), text, Int32(text.utf8.count))
    }
    private func nativeWindow(_ title: String) -> GTK.Widget? {
        var node = gtk_application_get_windows(application)
        while let current = node {
            if let raw = current.pointee.data {
                let window = raw.assumingMemoryBound(to: GtkWindow.self)
                if gtk_window_get_title(window).map(String.init(cString:)) == title { return mp_window_widget(window) }
            }
            node = current.pointee.next
        }
        return nil
    }
    private func worker(_ body: @escaping () throws -> Void) throws {
        let running = try XCTUnwrap(work, "Assistant worker unavailable")
        var result: Result<Void, Error>?
        running.run { let outcome = Result(catching: body); GTK.onMainLoop { result = outcome } }
        XCTAssertTrue(GTKTestSupport.spin { result != nil })
        try XCTUnwrap(result).get()
    }
    private func drain() {
        var done = false
        GTK.onMainLoop { GTK.onMainLoop { done = true } }
        XCTAssertTrue(GTKTestSupport.spin { done })
    }
}

/// Ignore transport cancellation until released, proving generation guards
/// reject even late provider replies. Every continuation is drained in teardown.
private final class LinuxAssistantFlowTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(HTTPResponse, Bool)] = []
    private var pending: [(CheckedContinuation<HTTPResponse, Error>, HTTPResponse)] = []
    private var recorded: [HTTPRequest] = []
    private var cancelled = 0
    var requests: [HTTPRequest] { locked { recorded } }
    var heldCount: Int { locked { pending.count } }
    var cancellations: Int { locked { cancelled } }
    func enqueue(_ response: HTTPResponse) { locked { replies.append((response, false)) } }
    func hold(_ response: HTTPResponse) { locked { replies.append((response, true)) } }
    func releaseHeld() {
        let values = locked { let values = pending; pending = []; return values }
        for (continuation, response) in values { continuation.resume(returning: response) }
    }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        XCTAssertFalse(Thread.isMainThread)
        let (response, hold) = locked { () -> (HTTPResponse, Bool) in
            recorded.append(request)
            guard !replies.isEmpty else { XCTFail("Unexpected Assistant request"); return (HTTPResponse(statusCode: 500, body: Data()), false) }
            return replies.removeFirst()
        }
        guard hold else { return response }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in locked { pending.append((continuation, response)) } }
        } onCancel: { self.locked { self.cancelled += 1 } }
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}
#endif
