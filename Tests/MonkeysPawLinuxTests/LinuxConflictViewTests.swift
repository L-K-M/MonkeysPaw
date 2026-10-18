#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawLinux

final class LinuxConflictViewTests: XCTestCase {
    private static let syncIOTimeout: Duration = .seconds(15)

    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var files: RootedFileStore!
    private var transport: ConflictViewTransport!
    private var window: GTK.Widget!
    private var outcomes: [ConflictResolutionAction] = []

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        tools.environment["XDG_CURRENT_DESKTOP"] = "sway"
        tools.environment["DBUS_SESSION_BUS_ADDRESS"] = address
        transport = ConflictViewTransport()
        files = try RootedFileStore(root: LinuxPaths(environment: tools.environment).documentsDirectory
            .appendingPathComponent("MonkeysPaw", isDirectory: true))
        try files.createRoot()
    }

    override func tearDown() {
        transport?.releaseHeld()
        if let environment {
            environment.shutdown()
            let done = ConflictViewFlag()
            Task.detached { await environment.drainSync(); done.set() }
            XCTAssertTrue(GTKTestSupport.spin(until: { done.value }, timeout: Self.syncIOTimeout))
        }
        environment = nil
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        window = nil
        drain()
        files = nil
        transport = nil
        tools = nil
    }

    func testKeepMineShowsExactCandidateAndSendsItOnlyOnExplicitChoice() throws {
        try open()
        let preview = try XCTUnwrap(environment.conflictModel?.state.preview)
        let candidate = try XCTUnwrap(preview.candidateBytes)
        XCTAssertTrue(try text("conflict-diff-body-before").hasPrefix("Server Café\n{{old}}\n"))
        XCTAssertTrue(try text("conflict-diff-body-after").contains("Mine Cafe\u{301}\n{{new}}"))
        XCTAssertFalse(try text("conflict-diff-header-after").contains("x-monkeyspaw-conflict-of"))
        XCTAssertTrue(try text("conflict-diff-header-after").contains(ConflictViewTransport.original))
        XCTAssertTrue(labels(try widget("library-conflict")).contains(LinuxConflictStrings.serverVersion))
        XCTAssertTrue(labels(try widget("library-conflict")).contains(LinuxConflictStrings.myVersion))
        XCTAssertEqual(transport.originalPuts.count, 0)
        let before = try files.read(at: ConflictViewTransport.copyPath)
        XCTAssertEqual(before, transport.copyBytes)
        try click("conflict-keep-mine")
        try resolved(.keepMine)
        let sent = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self,
            from: XCTUnwrap(transport.originalPuts.first?.body))
        XCTAssertEqual(Data(sent.content.utf8), candidate)
        XCTAssertEqual(sent.baseRev, 1)
        XCTAssertNil(try files.stamp(at: ConflictViewTransport.copyPath))
        XCTAssertFalse(transport.sentOnMain)
    }

    func testKeepServerTrashesOnlyPrivateCopyWithoutPUT() throws {
        try open()
        let original = try files.read(at: "original.md")
        try click("conflict-keep-server")
        try resolved(.keepServer)
        XCTAssertNil(try files.stamp(at: ConflictViewTransport.copyPath))
        XCTAssertEqual(try files.read(at: "original.md"), original)
        XCTAssertTrue(transport.originalPuts.isEmpty)
    }

    func testKeepBothRetainsIdentityAndBodyAndClearsOrigin() throws {
        try open()
        let before = PromptCodec.parseFile(try files.read(at: ConflictViewTransport.copyPath), filename: "copy.md")
        try click("conflict-keep-both")
        try resolved(.keepBoth)
        let after = PromptCodec.parseFile(try files.read(at: ConflictViewTransport.copyPath), filename: "copy.md")
        XCTAssertEqual(after.frontMatter.id, before.frontMatter.id)
        XCTAssertEqual(Data(after.body.utf8), Data(before.body.utf8))
        XCTAssertNil(try SyncConflictMetadata.origin(in: after))
        XCTAssertTrue(transport.originalPuts.isEmpty)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.rows.allSatisfy { $0.conflictOrigin == nil } })
    }

    func testStaleHeadRefreshRequiresANewExplicitChoiceForMineAndServer() throws {
        try open()
        for button in ["conflict-keep-mine", "conflict-keep-server"] {
            transport.advanceHead()
            let revision = transport.revision
            try click(button)
            XCTAssertTrue(GTKTestSupport.spin { self.environment.conflictModel?.state.error == .headChanged
                && self.environment.conflictModel?.state.preview?.head?.rev == revision })
            drain()
            XCTAssertTrue(try label("conflict-status").contains("choose again"))
            XCTAssertTrue(try text("conflict-diff-body-before").contains("Updated server"))
            XCTAssertEqual(try files.read(at: ConflictViewTransport.copyPath), transport.copyBytes)
            XCTAssertTrue(transport.originalPuts.isEmpty)
        }
        try click("conflict-keep-mine")
        try resolved(.keepMine)
        XCTAssertEqual(transport.originalPuts.count, 1)
    }

    func testViewerCannotKeepMineButCanKeepBoth() throws {
        transport.groupRole = .viewer
        try open()
        XCTAssertEqual(environment.conflictModel?.state.preview?.mineRefusal, .accessDenied)
        XCTAssertFalse(try sensitive("conflict-keep-mine"))
        XCTAssertTrue(try label("conflict-status").contains("cannot replace"))
        // Even a synthetic signal on an insensitive widget must not send.
        emitClick(try widget("conflict-keep-mine"))
        drain()
        XCTAssertTrue(transport.originalPuts.isEmpty)
        XCTAssertEqual(try files.read(at: ConflictViewTransport.copyPath), transport.copyBytes)
        try click("conflict-keep-both")
        try resolved(.keepBoth)
    }

    func testDeniedAndOfflineWritesKeepCopyAndOfferSafeChoices() throws {
        try open()
        for failure in [SyncAPI.FailureCode.forbidden, .internalError] {
            transport.putFailure = failure
            try click("conflict-keep-mine")
            let expected: ConflictResolutionFailure = failure == .forbidden ? .accessDenied : .offline
            XCTAssertTrue(GTKTestSupport.spin { self.environment.conflictModel?.state.error == expected })
            drain()
            XCTAssertEqual(try files.read(at: ConflictViewTransport.copyPath), transport.copyBytes)
            XCTAssertTrue(try sensitive("conflict-keep-both"))
            if failure == .forbidden {
                XCTAssertFalse(try sensitive("conflict-keep-mine"))
                try click("conflict-refresh")
                try ready()
            }
        }
        transport.putFailure = nil
        try click("conflict-keep-both")
        try resolved(.keepBoth)
    }

    func testUnavailableOriginalAndRescuedOriginOfferOnlyKeepBoth() throws {
        transport.getFailure = .notFound
        try open()
        XCTAssertFalse(try sensitive("conflict-keep-mine"))
        XCTAssertFalse(try sensitive("conflict-keep-server"))
        XCTAssertTrue(try sensitive("conflict-keep-both"))
        XCTAssertTrue(try label("conflict-status").contains("unavailable"))
        let rescued = try SyncConflictMetadata.settingOrigin(.rescued, in: transport.copyBytes, filename: "copy.md")
        try files.write(rescued, at: ConflictViewTransport.copyPath)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.state.selectedPrompt?.conflictOrigin == .rescued
            && self.environment.conflictModel?.state.preview?.originalID == nil
            && self.environment.conflictModel?.state.isBusy == false })
        try ready()
        XCTAssertFalse(try sensitive("conflict-keep-mine"))
        XCTAssertFalse(try sensitive("conflict-keep-server"))
        try click("conflict-keep-both")
        try resolved(.keepBoth)
    }

    func testOriginFilteringIgnoresFilenamesAndSurvivesSelectedCopyRename() throws {
        try open()
        let ordinary = "Conflicts/Personal/example (conflict Linux 2026-10-15 1200).md"
        try files.write(Data("Ordinary prompt\n".utf8), at: ordinary)
        try files.write(Data("---\nx-monkeyspaw-rescued: false\n---\nFalse marker\n".utf8), at: "false.md")
        try files.write(Data("---\nx-monkeyspaw-conflict-of: invalid\n---\nInvalid marker\n".utf8), at: "invalid.md")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.sections.first { $0.id == .all }?.count == 5 })
        try selectSection(.conflicts)
        XCTAssertEqual(environment.libraryBrowserModel.rows.map(\.relativePath.string), [ConflictViewTransport.copyPath])
        environment.editorModel.rename(to: "renamed.md")
        let renamed = "Elsewhere/renamed.md"
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.selection?.relativePath.string == renamed
            && self.environment.conflictModel?.state.preview?.copy.relativePath.string == renamed
            && self.environment.conflictModel?.state.isBusy == false })
        try ready()
        XCTAssertTrue(try sensitive("conflict-keep-both"))
        XCTAssertNil(try files.stamp(at: ConflictViewTransport.copyPath))
        try click("conflict-keep-both")
        try resolved(.keepBoth)
        XCTAssertNotNil(try files.stamp(at: renamed))
        XCTAssertNotNil(try files.stamp(at: ordinary))
    }

    func testUnsavedDraftRequiresGuardAndFreshExplicitChoiceAfterSave() throws {
        try open()
        let editor = environment.editorModel
        let draft = try XCTUnwrap(editor.state.source) + "\nNew unsaved edit\n"
        let buffer = gtk_text_view_get_buffer(mp_text_view(try widget("library-source")))!
        gtk_text_buffer_set_text(buffer, draft, Int32(draft.utf8.count))
        XCTAssertTrue(GTKTestSupport.spin { editor.state.isDirty })
        let resolve = try widget("conflict-keep-mine")
        emitClick(resolve)
        emitClick(resolve)
        XCTAssertTrue(GTKTestSupport.spin { editor.state.pendingDecision != nil })
        drain()
        XCTAssertEqual(try label("conflict-status"), "Waiting for the Library to be ready before resolving this copy.")
        XCTAssertFalse(try sensitive("conflict-keep-mine"))
        XCTAssertFalse(try sensitive("conflict-refresh"))
        XCTAssertTrue(transport.originalPuts.isEmpty)
        try respondToDraft(2) // Cancel preserves the draft and the old comparison.
        XCTAssertTrue(GTKTestSupport.spin { editor.state.pendingDecision == nil })
        XCTAssertTrue(editor.state.isDirty)
        XCTAssertEqual(editor.state.source, draft)
        XCTAssertEqual(try label("conflict-status"), LinuxConflictStrings.choose)
        XCTAssertTrue(try sensitive("conflict-keep-mine"))
        XCTAssertNotEqual(gtk_text_view_get_editable(mp_text_view(try widget("library-source"))), 0)
        try click("conflict-keep-mine")
        XCTAssertTrue(GTKTestSupport.spin { editor.state.pendingDecision != nil })
        try respondToDraft(0) // Save, then compare the newly committed bytes.
        XCTAssertTrue(GTKTestSupport.spin { !editor.state.isDirty && editor.state.status != .loading
            && self.environment.conflictModel?.state.isBusy == false
            && self.environment.conflictModel?.state.preview?.candidateBytes.map { String(decoding: $0, as: UTF8.self).contains("New unsaved edit") } == true })
        try ready()
        XCTAssertTrue(transport.originalPuts.isEmpty)
        // The compared draft can publish before Keep mine becomes actionable.
        XCTAssertTrue(GTKTestSupport.spin { (try? self.sensitive("conflict-keep-mine")) == true },
            "Keep mine did not become ready after comparing the saved draft")
        try click("conflict-keep-mine")
        try resolved(.keepMine)
        XCTAssertEqual(transport.originalPuts.count, 1)
    }

    func testRepeatedResolutionSignalsSendOnlyOneWrite() throws {
        try open()
        transport.holdNext = .put
        let button = try widget("conflict-keep-mine")
        emitClick(button)
        emitClick(button) // Both activations precede the model's queued busy transition.
        XCTAssertTrue(GTKTestSupport.spin { self.transport.hasHeld })
        emitClick(button)
        drain()
        XCTAssertEqual(transport.originalPuts.count, 1)
        transport.releaseHeld()
        try resolved(.keepMine)
        XCTAssertEqual(transport.originalPuts.count, 1)
    }

    func testChangedStampReloadsTheSameSelectionAndEnablesFreshChoice() throws {
        try open()
        let selection = environment.editorModel.state.prompt
        let changed = transport.copyBytes + Data("\nChanged on disk\n".utf8)
        try files.write(changed, at: ConflictViewTransport.copyPath)
        XCTAssertTrue(GTKTestSupport.spin {
            self.environment.conflictModel?.state.preview?.candidateBytes.map {
                String(decoding: $0, as: UTF8.self).contains("Changed on disk")
            } == true && self.environment.conflictModel?.state.isBusy == false
        })
        try ready()
        XCTAssertEqual(environment.editorModel.state.prompt, selection)
        XCTAssertTrue(try text("conflict-diff-body-after").contains("Changed on disk"))
        XCTAssertEqual(try label("conflict-status"), LinuxConflictStrings.choose)
        XCTAssertTrue(try sensitive("conflict-keep-mine"))
        XCTAssertTrue(transport.originalPuts.isEmpty)
    }

    func testWorkerCompletionUpdatesGTKOnlyOnMainLoopAndDisablesEditingDuringWrite() throws {
        try open()
        var writes = 0
        for name in ["conflict-diff-body-before", "conflict-diff-body-after"] {
            let buffer = gtk_text_view_get_buffer(mp_text_view(try widget(name)))!
            GTK.onSignal(UnsafeMutableRawPointer(buffer), "changed") { XCTAssertTrue(Thread.isMainThread); writes += 1 }
        }
        transport.advanceHead()
        try click("conflict-refresh")
        try ready()
        XCTAssertGreaterThan(writes, 0)
        transport.holdNext = .put
        try click("conflict-keep-mine")
        XCTAssertTrue(GTKTestSupport.spin { self.transport.hasHeld })
        XCTAssertEqual(gtk_text_view_get_editable(mp_text_view(try widget("library-source"))), 0)
        XCTAssertFalse(try sensitive("library-save"))
        XCTAssertFalse(try sensitive("conflict-keep-both"))
        let heartbeat = ConflictViewFlag()
        GTK.onMainLoop { heartbeat.set() }
        XCTAssertTrue(GTKTestSupport.spin { heartbeat.value })
        transport.releaseHeld()
        try resolved(.keepMine)
        XCTAssertFalse(transport.sentOnMain)
    }

    func testHideRevokesLateAcknowledgementAndReopeningLoadsFreshComparison() throws {
        try open()
        transport.holdNext = .put
        try click("conflict-keep-mine")
        XCTAssertTrue(GTKTestSupport.spin { self.transport.hasHeld })
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(self.window) == 0
            && self.environment.conflictModel?.state.preview == nil })
        transport.releaseHeld()
        waitForModelDrain()
        XCTAssertEqual(try files.read(at: ConflictViewTransport.copyPath), transport.copyBytes)
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(self.window) != 0 })
        try ready()
        XCTAssertTrue(try sensitive("conflict-keep-both"))
    }

    func testNativeDestroyAndGraphReplacementRejectStalePreviewCallbacks() throws {
        try open()
        transport.holdNext = .get
        try click("conflict-refresh")
        XCTAssertTrue(GTKTestSupport.spin { self.transport.hasHeld })
        let old = try XCTUnwrap(environment.conflictModel)
        gtk_window_destroy(mp_window(window))
        window = nil
        transport.releaseHeld()
        waitForModelDrain(old)
        XCTAssertNil(old.state.preview)
        XCTAssertNotNil(try files.stamp(at: ConflictViewTransport.copyPath))
        let replacement = tools.directory.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let result = environment.switchLibrary(to: replacement)
        XCTAssertEqual(result, .syncDraining)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.settingsModel.libraryFolderPath == replacement.path })
        XCTAssertFalse(environment.conflictModel === old)
        old.open(.init(identity: .assigned(try XCTUnwrap(ULID(ConflictViewTransport.copyID))),
                       relativePath: RelativePath(ConflictViewTransport.copyPath)))
        drain()
        XCTAssertNil(old.state.preview)
    }

    func testLocalLibraryReplacementDoesNotStartSyncModelWorkBeforeQuit() throws {
        compose()
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { self.nativeWindow(LinuxStrings.library) != nil })
        let replacement = tools.directory.appendingPathComponent("local-replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        XCTAssertEqual(environment.switchLibrary(to: replacement), .switched)
        var approved = false
        environment.requestQuit { approved = true }
        XCTAssertTrue(approved, "A local-only Library rebind must not construct a loading AccountModel")
        XCTAssertFalse(environment.syncService?.report.enabled == true)
    }

    func testLibraryOpenedBeforeSignInBindsTheLaterConflictModel() throws {
        compose()
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { self.nativeWindow(LinuxStrings.library) != nil })
        let localWindow = try XCTUnwrap(nativeWindow(LinuxStrings.library))
        try signInAndSelectCopy()
        XCTAssertEqual(window, localWindow)
        XCTAssertTrue(try sensitive("conflict-keep-both"))
        try click("conflict-keep-both")
        try resolved(.keepBoth)
    }

    func testReindexDuringResolutionKeepsOutcomeUntilCompletion() throws {
        try open()
        let preview = try XCTUnwrap(environment.conflictModel?.state.preview)
        let gate = ConflictViewResolutionGate(preview: preview)
        let model = ConflictModel(service: gate, mainThread: GLibMainThread())
        let view = LinuxConflictView()
        _ = g_object_ref_sink(view.widget)
        defer {
            view.unbind()
            model.retire()
            g_object_unref(view.widget)
        }
        var outcome: ConflictResolutionAction?
        _ = model.addObserver { if let action = $0.resolved { outcome = action } }
        view.bind(model: model, selection: preview.copy, stamp: environment.editorModel.state.stamp, available: true)
        let button = try settingsWidget("conflict-keep-both", in: view.widget)
        XCTAssertTrue(GTKTestSupport.spin { model.state.preview != nil && gtk_widget_get_sensitive(button) != 0 })
        view.resolve(.keepBoth)
        XCTAssertTrue(GTKTestSupport.spin { gate.entered.value })

        // The index removes the conflict marker before the worker's reply.
        view.bind(model: model, selection: nil, stamp: nil, available: true)
        drain()
        XCTAssertEqual(model.state.operation, .resolving)
        Task.detached { await gate.finish() }
        XCTAssertTrue(GTKTestSupport.spin { outcome == .keepBoth })
        view.bind(model: model, selection: nil, stamp: nil, available: true)
        XCTAssertEqual(gtk_widget_get_visible(view.widget), 0)
    }

    private func open() throws {
        compose()
        try signInAndSelectCopy()
    }

    private func compose() {
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            scheduler: ConflictViewIdleTimer(), syncTransport: transport)
        _ = environment.libraryStatusModel
    }

    private func signInAndSelectCopy() throws {
        let account = try XCTUnwrap(environment.accountModel)
        XCTAssertTrue(GTKTestSupport.spin { !account.state.isBusy })
        var password = "test-password"
        account.login(server: "https://sync.example.test", username: "person", password: &password, deviceName: "Linux")
        XCTAssertTrue(GTKTestSupport.spin(until: {
            account.state.enabled && self.environment.syncService?.report.lastSuccess != nil
        }, timeout: Self.syncIOTimeout))
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { self.nativeWindow(LinuxStrings.library) != nil })
        window = try XCTUnwrap(nativeWindow(LinuxStrings.library))
        _ = environment.conflictModel?.addObserver { [weak self] state in
            XCTAssertTrue(Thread.isMainThread)
            if let action = state.resolved { self?.outcomes.append(action) }
        }
        let browser = environment.libraryBrowserModel
        XCTAssertTrue(GTKTestSupport.spin { browser.rows.contains { $0.relativePath.string == ConflictViewTransport.copyPath } })
        let index = try XCTUnwrap(browser.rows.firstIndex { $0.relativePath.string == ConflictViewTransport.copyPath })
        let list = try widget("library-list")
        // Model rows can precede the existing window's native list render.
        XCTAssertTrue(GTKTestSupport.spin {
            guard let row = gtk_list_box_get_row_at_index(mp_list_box(list), Int32(index)),
                  let content = gtk_list_box_row_get_child(row) else { return false }
            return self.labels(content).contains(ConflictViewTransport.copyPath)
        }, "Conflict copy did not appear in the native Library list")
        gtk_list_box_select_row(mp_list_box(list), gtk_list_box_get_row_at_index(mp_list_box(list), Int32(index)))
        try ready()
    }

    private func ready() throws {
        XCTAssertTrue(GTKTestSupport.spin { self.environment.conflictModel?.state.preview != nil
            && self.environment.conflictModel?.state.isBusy == false
            && (try? self.sensitive("conflict-keep-both")) == true })
        drain()
    }
    private func resolved(_ action: ConflictResolutionAction) throws {
        XCTAssertTrue(GTKTestSupport.spin { self.outcomes.contains(action) })
        waitForModelDrain()
    }
    private func waitForModelDrain(_ model: ConflictModel? = nil) {
        guard let model = model ?? environment?.conflictModel else { return }
        let done = ConflictViewFlag()
        Task.detached { await model.drain(); done.set() }
        XCTAssertTrue(GTKTestSupport.spin { done.value })
        drain()
    }
    private func widget(_ name: String) throws -> GTK.Widget { try settingsWidget(name, in: XCTUnwrap(window)) }
    private func click(_ name: String) throws {
        let button = try widget(name)
        XCTAssertNotEqual(gtk_widget_get_sensitive(button), 0, name)
        emitClick(button)
        drain()
    }
    private func emitClick(_ button: GTK.Widget) {
        var instance = GValue()
        g_value_init(&instance, gtk_button_get_type())
        g_value_set_object(&instance, button)
        g_signal_emitv(&instance, g_signal_lookup("clicked", gtk_button_get_type()), 0, nil)
        g_value_unset(&instance)
    }
    private func sensitive(_ name: String) throws -> Bool { gtk_widget_get_sensitive(try widget(name)) != 0 }
    private func label(_ name: String) throws -> String { String(cString: gtk_label_get_text(mp_label(try widget(name)))) }
    private func text(_ name: String) throws -> String {
        let buffer = gtk_text_view_get_buffer(mp_text_view(try widget(name)))!
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let value = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(value) }
        return String(cString: value)
    }
    private func labels(_ widget: GTK.Widget) -> [String] {
        var result: [String] = []
        if g_type_check_instance_is_a(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self), gtk_label_get_type()) != 0 {
            result.append(String(cString: gtk_label_get_text(mp_label(widget))))
        }
        var child = gtk_widget_get_first_child(widget)
        while let current = child { result += labels(current); child = gtk_widget_get_next_sibling(current) }
        return result
    }
    private func nativeWindow(_ title: String) -> GTK.Widget? {
        let windows = gtk_window_get_toplevels()
        for index in 0..<g_list_model_get_n_items(windows) {
            guard let object = g_list_model_get_item(windows, index) else { continue }
            let widget = object.assumingMemoryBound(to: GtkWidget.self)
            g_object_unref(object)
            if gtk_window_get_title(mp_window(widget)).map({ String(cString: $0) }) == title { return widget }
        }
        return nil
    }
    private func respondToDraft(_ response: Int) throws {
        XCTAssertTrue(GTKTestSupport.spin { self.nativeWindow("Save your edits?") != nil })
        let dialog = try XCTUnwrap(nativeWindow("Save your edits?"))
        emitClick(try settingsWidget("library-dialog-response-\(response)", in: dialog))
        drain()
    }
    private func selectSection(_ section: LibrarySectionID) throws {
        let browser = environment.libraryBrowserModel
        let index = try XCTUnwrap(browser.sections.firstIndex { $0.id == section })
        let sidebar = try widget("library-sidebar")
        gtk_list_box_select_row(mp_list_box(sidebar), gtk_list_box_get_row_at_index(mp_list_box(sidebar), Int32(index)))
        XCTAssertTrue(GTKTestSupport.spin { browser.selectedSection == section })
        drain()
    }
    private func drain() { for _ in 0..<40 { _ = g_main_context_iteration(nil, 0) } }
}

private final class ConflictViewFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}

private actor ConflictViewResolutionGate: ConflictResolving {
    nonisolated let entered = ConflictViewFlag()
    private let value: ConflictPreview
    private var completion: CheckedContinuation<ConflictResolutionResult, Never>?

    init(preview: ConflictPreview) { value = preview }
    func preview(_ copy: LibraryPromptSelection) async throws -> ConflictPreview { value }
    func resolve(_ action: ConflictResolutionAction, preview: ConflictPreview) async throws -> ConflictResolutionResult {
        await withCheckedContinuation { completion = $0; entered.set() }
    }
    func finish() { completion?.resume(returning: .resolved(.keepBoth)); completion = nil }
}

private final class ConflictViewIdleTimer: Scheduler {
    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        // Keep native watcher batching, but leave automatic sync to explicit tests.
        if delay < Limits.syncDebounce { GTK.after(delay.timeInterval, work) }
    }
}

/// Real account/sync/resolution models and native files; only HTTP is stubbed.
private final class ConflictViewTransport: HTTPTransporting, @unchecked Sendable {
    static let user = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    static let device = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
    static let group = "01ARZ3NDEKTSV4RRFFQ69G5FAX"
    static let original = "01ARZ3NDEKTSV4RRFFQ69G5FAY"
    static let copyID = "01ARZ3NDEKTSV4RRFFQ69G5FAZ"
    static let copyPath = "Elsewhere/copy.md"
    let copyBytes = Data(("---\nid: " + copyID + "\nx-monkeyspaw-conflict-of: " + original
        + "\n---\nMine Cafe\u{301}\n{{new}}").utf8)
    private let lock = NSRecursiveLock()
    private var requests: [HTTPRequest] = []
    private var held: (HTTPRequest, CheckedContinuation<HTTPResponse, Error>)?
    private var storedHold: HTTPMethod?
    private var storedGetFailure: SyncAPI.FailureCode?
    private var storedPutFailure: SyncAPI.FailureCode?
    private var storedRole: SyncAPI.Role?
    private var server = "---\nid: " + original + "\n---\nServer Café\n{{old}}\n"
    private var rev: Int64 = 1
    private var mainRequest = false
    var groupRole: SyncAPI.Role? { get { locked { storedRole } } set { locked { storedRole = newValue } } }
    var getFailure: SyncAPI.FailureCode? { get { locked { storedGetFailure } } set { locked { storedGetFailure = newValue } } }
    var putFailure: SyncAPI.FailureCode? { get { locked { storedPutFailure } } set { locked { storedPutFailure = newValue } } }
    var holdNext: HTTPMethod? { get { locked { storedHold } } set { locked { storedHold = newValue } } }
    var hasHeld: Bool { locked { held != nil } }
    var sentOnMain: Bool { locked { mainRequest } }
    var revision: Int64 { locked { rev } }
    var originalPuts: [HTTPRequest] { locked { requests.filter { $0.method == .put && $0.url.lastPathComponent == Self.original } } }

    func advanceHead() { locked { rev += 1; server = "---\nid: " + Self.original + "\n---\nUpdated server \(rev)\n" } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let hold = locked {
            requests.append(request)
            mainRequest = mainRequest || Thread.isMainThread
            guard storedHold == request.method, request.url.lastPathComponent == Self.original else { return false }
            storedHold = nil
            return true
        }
        if hold {
            return try await withCheckedThrowingContinuation { continuation in locked { held = (request, continuation) } }
        }
        return try response(to: request)
    }

    func releaseHeld() {
        let pending = locked { let value = held; held = nil; return value }
        guard let (request, continuation) = pending else { return }
        do { continuation.resume(returning: try response(to: request)) }
        catch { continuation.resume(throwing: HTTPTransportError.invalidResponse) }
    }

    private func response(to request: HTTPRequest) throws -> HTTPResponse {
        try locked {
            if request.url.path.hasSuffix("/login") {
                return try http(SyncAPI.AuthResponse(deviceToken: String(repeating: "a", count: 42) + "A", user: user))
            }
            if request.url.path.hasSuffix("/me") {
                return try http(SyncAPI.MeResponse(user: user,
                    groups: storedRole.map { [.init(groupID: Self.group, name: "Team", role: $0)] } ?? [],
                    devices: [.init(id: Self.device, name: "Linux", createdAt: timestamp, lastSeenAt: nil, revokedAt: nil, isCurrent: true)]))
            }
            if request.url.lastPathComponent == Self.original {
                if request.method == .get {
                    if let failure = storedGetFailure { return try failed(failure) }
                    return try http(SyncAPI.Prompt(id: Self.original, rev: rev, scope: scope, path: "original.md", content: server))
                }
                if request.method == .put {
                    if let failure = storedPutFailure { return try failed(failure) }
                    let put = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self, from: request.body ?? Data())
                    guard put.baseRev == rev else {
                        let conflict = SyncAPI.ErrorResponse.conflict(head: .init(rev: rev, scope: scope, path: "original.md", content: server))
                        return HTTPResponse(statusCode: 409, body: try JSONEncoder().encode(conflict))
                    }
                    rev += 1
                    server = put.content
                    return try http(SyncAPI.WriteResponse(rev: rev, seq: rev))
                }
            }
            if request.url.path.hasSuffix("/sync/pull") {
                let original = SyncAPI.FeedItem.upsert(seq: rev, prompt: .init(id: Self.original, rev: rev, path: "original.md", content: server))
                let copy = SyncAPI.FeedItem.upsert(seq: 1, prompt: .init(id: Self.copyID, rev: 1, path: Self.copyPath,
                    content: String(decoding: copyBytes, as: UTF8.self)))
                var scopes: [SyncAPI.SyncScope] = [.init(identity: .user(userID: Self.user), mode: .snapshot, head: rev,
                    cursor: "private-\(rev)", hasMore: false, items: storedRole == nil ? [original, copy] : [copy])]
                if let role = storedRole {
                    scopes.append(.init(identity: .group(groupID: Self.group, name: "Team", role: role), mode: .snapshot,
                        head: rev, cursor: "team-\(rev)", hasMore: false, items: [original]))
                }
                return try http(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: scopes, removed: []))
            }
            throw HTTPTransportError.invalidRequest
        }
    }

    private var scope: SyncAPI.PromptScope { storedRole == nil ? .user : .group(groupID: Self.group) }
    private let timestamp = "2026-10-15T00:00:00.000Z"
    private var user: SyncAPI.User {
        .init(id: Self.user, username: "person", displayName: nil, accountKind: .member, createdAt: timestamp, disabledAt: nil)
    }
    private func failed(_ code: SyncAPI.FailureCode) throws -> HTTPResponse {
        let error = SyncAPI.ErrorResponse.failure(code)
        return HTTPResponse(statusCode: error.httpStatus, body: try JSONEncoder().encode(error))
    }
    private func http<T: APIObjectDTO>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value))
    }
    private func locked<T>(_ work: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try work() }
}
#endif
