#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawLinux

final class LinuxScopeDragTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var rig: ScopeDragRig!

    override func setUpWithError() throws {
        _ = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        rig = try ScopeDragRig(application: application)
    }

    override func tearDown() {
        rig?.close()
        rig = nil
        if let application { GTKTestSupport.destroy(application) }
        application = nil
    }

    func testEveryScopeDirectionAndFolderRetainsIdentityBytesAndHistory() throws {
        let identity = rig.selection.identity
        let history = try rig.library.history(for: identity)
        XCTAssertFalse(history.isEmpty)
        for (section, path) in [(LibrarySectionID.group(ScopeDragRig.team), "Groups/Team/a.md"),
                                (.group(ScopeDragRig.other), "Groups/Other/a.md"),
                                (.all, "a.md"), (.folder("Folder"), "Folder/a.md")] {
            let oldPath = rig.selection.relativePath.string
            let bytes = try rig.files.read(at: oldPath)
            let payload = try dragPayload()
            XCTAssertTrue(try drop(payload, onto: section))
            try rig.waitForPath(path)
            XCTAssertNil(try rig.files.stamp(at: oldPath))
            XCTAssertEqual(try rig.files.read(at: path), bytes)
            XCTAssertEqual(rig.selection.identity, identity)
            XCTAssertEqual(try rig.library.history(for: identity), history)
            XCTAssertEqual(rig.browser.selection, rig.selection)
        }
    }

    func testDirtyMoveCancelThenDiscardAndSaveUseEditorGuard() throws {
        let baseline = try rig.files.read(at: "a.md")
        rig.editor.edit(rig.editor.state.source! + "\nDraft")
        XCTAssertTrue(try drop(dragPayload(), onto: .group(ScopeDragRig.team)))
        try decide(.cancel)
        XCTAssertTrue(rig.editor.state.isDirty)
        XCTAssertTrue(rig.editor.state.source!.contains("Draft"))
        XCTAssertEqual(try rig.files.read(at: "a.md"), baseline)
        XCTAssertNil(try rig.files.stamp(at: "Groups/Team/a.md"))
        XCTAssertTrue(try drop(dragPayload(), onto: .group(ScopeDragRig.team)))
        try decide(.discard)
        try rig.waitForPath("Groups/Team/a.md")
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), baseline)
        rig.editor.edit(rig.editor.state.source! + "\nSaved draft")
        XCTAssertTrue(try drop(dragPayload(), onto: .all))
        try decide(.save)
        try rig.waitForPath("a.md")
        XCTAssertTrue(String(decoding: try rig.files.read(at: "a.md"), as: UTF8.self).contains("Saved draft"))
        XCTAssertFalse(rig.editor.state.isDirty)
    }

    func testOccupiedDestinationNeverOverwritesEitherPrompt() throws {
        try rig.files.write(Data("Occupant".utf8), at: "Groups/Team/a.md")
        let before = try rig.files.read(at: "a.md")
        XCTAssertTrue(try drop(dragPayload(), onto: .group(ScopeDragRig.team)))
        XCTAssertTrue(GTKTestSupport.spin { if case .failed = self.rig.editor.state.status { return true }; return false })
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), Data("Occupant".utf8))
        XCTAssertEqual(try rig.files.read(at: "a.md"), before)
        XCTAssertEqual(rig.selection.relativePath, "a.md")
    }

    func testViewerSourceAndDestinationAreDeniedAndDowngradeKeepsDraft() throws {
        let payload = try dragPayload()
        try rig.role(.viewer, group: ScopeDragRig.team)
        XCTAssertNil(rig.browser.moveDestination(for: .group(ScopeDragRig.team)))
        XCTAssertFalse(try drop(payload, onto: .group(ScopeDragRig.team), requiresTarget: false))
        try rig.role(.editor, group: ScopeDragRig.team)
        XCTAssertTrue(try drop(dragPayload(), onto: .group(ScopeDragRig.team)))
        try rig.waitForPath("Groups/Team/a.md")
        let groupPayload = try dragPayload()
        rig.editor.edit(rig.editor.state.source! + "\nPrivate draft")
        try rig.role(.viewer, group: ScopeDragRig.team)
        XCTAssertTrue(GTKTestSupport.spin { !self.rig.editor.state.canEdit })
        XCTAssertNil(try preparedPayload(on: promptWidget()))
        XCTAssertFalse(try drop(groupPayload, onto: .all))
        XCTAssertTrue(rig.editor.state.source!.contains("Private draft"))
        XCTAssertTrue(rig.editor.state.canSaveAsCopy)
        XCTAssertNotNil(try rig.files.stamp(at: "Groups/Team/a.md"))
    }

    func testForgedPayloadsAndNonDestinationSectionsCannotMoveFiles() throws {
        let payload = try dragPayload()
        for invalid in ["", "a.md", "/tmp/a.md", "file:///tmp/a.md", "../a.md", payload + "/../b.md",
                        payload.replacingOccurrences(of: "a.md", with: "../a.md"), String(repeating: "x", count: 4_096)] {
            XCTAssertFalse(try drop(invalid, onto: .group(ScopeDragRig.team)))
        }
        XCTAssertNil(rig.browser.moveDestination(for: .favourites))
        XCTAssertNil(rig.browser.moveDestination(for: .folder("../outside")))
        let target = try destinationWidget(.all)
        var wrong = GValue()
        g_value_init(&wrong, g_type_from_name("gint"))
        g_value_set_int(&wrong, 42)
        defer { g_value_unset(&wrong) }
        XCTAssertFalse(try emitDrop(&wrong, on: target))
        var malformed = GValue()
        g_value_init(&malformed, mp_library_row_type())
        let invalidUTF8: [CChar] = [-1, 0]
        invalidUTF8.withUnsafeBufferPointer { g_value_set_boxed(&malformed, $0.baseAddress) }
        defer { g_value_unset(&malformed) }
        XCTAssertFalse(try emitDrop(&malformed, on: target))
        XCTAssertNotNil(try rig.files.stamp(at: "a.md"))
        XCTAssertNil(try rig.files.stamp(at: "Groups/Team/a.md"))
    }

    func testRebindAndDestroyedWidgetsRejectOldEpochAndReleaseWindow() throws {
        let oldPayload = try dragPayload()
        let oldSource = try promptWidget()
        let oldTarget = try destinationWidget(.all)
        g_object_ref(oldSource)
        g_object_ref(oldTarget)
        defer { g_object_unref(oldSource); g_object_unref(oldTarget) }
        rig.view.rebind(browser: rig.browser, editor: rig.editor)
        drain()
        XCTAssertNil(try preparedPayload(on: oldSource))
        XCTAssertFalse(try drop(oldPayload, onto: .group(ScopeDragRig.team)))
        let fresh = try dragPayload()
        XCTAssertNotEqual(oldPayload, fresh)
        XCTAssertFalse(try emitRowDrop(fresh, on: oldTarget))
        let source = try promptWidget()
        let target = try destinationWidget(.all)
        g_object_ref(source)
        g_object_ref(target)
        defer { g_object_unref(source); g_object_unref(target) }
        weak var view = rig.view
        gtk_window_destroy(mp_window(rig.window))
        rig.view = nil
        XCTAssertNil(view)
        XCTAssertNil(try preparedPayload(on: source))
        XCTAssertFalse(try emitRowDrop(fresh, on: target))
        XCTAssertNotNil(try rig.files.stamp(at: "a.md"))
    }

    func testHiddenAndUnavailableWindowRejectPayloads() throws {
        let payload = try dragPayload()
        rig.view.setLibraryAvailable(false)
        XCTAssertFalse(try drop(payload, onto: .all))
        rig.view.setLibraryAvailable(true)
        gtk_widget_set_visible(rig.window, 0)
        XCTAssertNil(try preparedPayload(on: promptWidget()))
        XCTAssertFalse(try drop(payload, onto: .all))
    }

    func testRebindToEmptyGraphRemovesRetiredRows() throws {
        let root = rig.root.appendingPathComponent("empty-library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = try RootedFileStore(root: root)
        let data = try RootedFileStore(root: rig.root.appendingPathComponent("empty-data"))
        let usage = UsageStore(files: data, clock: SystemClock())
        let library = LibraryService(library: files, data: data, clock: SystemClock(), entropy: SystemEntropy())
        let index = PromptIndex(service: library, usage: usage, clock: SystemClock())
        try index.rebuild()
        let main = GLibMainThread()
        let editing = PromptEditingService(library: library, index: index, work: LinuxBackgroundWork(), main: main)
        let editor = EditorModel(editing: editing, clock: SystemClock(), timeZone: { .current }, main: main)
        let browser = LibraryBrowserModel(index: index, usage: usage, favorites: library, main: main, editor: editor)
        defer { browser.deactivate(); editor.deactivate() }
        let list = try settingsWidget("library-list", in: rig.window)
        XCTAssertNotNil(gtk_widget_get_first_child(list))
        rig.view.rebind(browser: browser, editor: editor)
        XCTAssertTrue(browser.rows.isEmpty)
        XCTAssertNil(gtk_widget_get_first_child(list), "A replacement empty graph must remove every retired row")
    }

    func testQueuedNavigationRejectsDrop() throws {
        let payload = try dragPayload()
        let target = try destinationWidget(.group(ScopeDragRig.team))
        let other = try XCTUnwrap(rig.browser.rows.first { $0.relativePath == "Folder/seed.md" }?.selection)
        rig.editor.request(.open(other))
        XCTAssertFalse(rig.editor.state.queuedActions.isEmpty)
        XCTAssertFalse(try emitRowDrop(payload, on: target))
        XCTAssertFalse(rig.editor.state.queuedActions.contains(.move))
    }

    func testNavigationQueuedWhileOpeningDraggedRowCancelsDeferredMove() throws {
        try rig.files.write(Data("---\nid: '00000000000000000000000009'\n---\nOther".utf8), at: "b.md")
        try rig.index.rebuild()
        let payload = try dragPayload(path: "b.md")
        let original = rig.selection
        var queuedNavigation = false
        var queuedMove = false
        rig.editor.onChange = {
            let state = self.rig.editor.state
            if state.queuedActions.contains(.move) { queuedMove = true }
            guard !queuedNavigation, state.prompt?.relativePath == "b.md",
                  state.source != nil, state.status != .loading else { return }
            queuedNavigation = true
            self.rig.editor.request(.open(original))
        }
        defer { rig.editor.onChange = nil }
        XCTAssertTrue(try drop(payload, onto: .group(ScopeDragRig.team)))
        XCTAssertTrue(GTKTestSupport.spin {
            queuedNavigation && self.rig.editor.state.prompt == original
                && self.rig.editor.state.status != .loading && self.rig.editor.state.queuedActions.isEmpty
        })
        XCTAssertFalse(queuedMove, "A deferred drop must not enqueue a move behind newer navigation")
        XCTAssertNotNil(try rig.files.stamp(at: "b.md"))
        XCTAssertNil(try rig.files.stamp(at: "Groups/Team/b.md"))
    }

    func testInternalRowPayloadCannotBeExportedAsTextOrReplayedAsStringDrop() throws {
        let payload = try dragPayload()
        XCTAssertFalse(try emitStringDrop(payload, on: destinationWidget(.group(ScopeDragRig.team))))
        XCTAssertNotNil(try rig.files.stamp(at: "a.md"))
        XCTAssertNil(try rig.files.stamp(at: "Groups/Team/a.md"))
        XCTAssertTrue(try drop(payload, onto: .group(ScopeDragRig.team)))
        try rig.waitForPath("Groups/Team/a.md")
    }

    func testAcceptedPayloadCannotReplayAfterCancellation() throws {
        let payload = try dragPayload()
        rig.editor.edit(rig.editor.state.source! + "\nDraft")
        XCTAssertTrue(try drop(payload, onto: .group(ScopeDragRig.team)))
        try decide(.cancel)
        XCTAssertFalse(try drop(payload, onto: .group(ScopeDragRig.team)))
        XCTAssertEqual(rig.selection.relativePath, "a.md")
        XCTAssertTrue(rig.editor.state.isDirty)
    }

    func testDraggingAnotherRowGuardsCurrentDraftBeforeOpeningAndMoving() throws {
        try rig.files.write(Data("---\nid: '00000000000000000000000009'\n---\nOther".utf8), at: "b.md")
        try rig.index.rebuild()
        drain()
        let otherPayload = try dragPayload(path: "b.md")
        rig.editor.edit(rig.editor.state.source! + "\nKeep current")
        let newPrompt = try settingsWidget("library-new-prompt", in: rig.window)
        XCTAssertTrue(try drop(otherPayload, onto: .group(ScopeDragRig.team)))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_sensitive(newPrompt) == 0
            && self.rig.editor.state.pendingDecision != nil })
        try decide(.cancel, action: nil)
        XCTAssertNotEqual(gtk_widget_get_sensitive(newPrompt), 0,
            "Cancelling the pending drop must refresh the shared New prompt gate")
        XCTAssertEqual(rig.selection.relativePath, "a.md")
        XCTAssertTrue(rig.editor.state.source!.contains("Keep current"))
        XCTAssertTrue(try drop(dragPayload(path: "b.md"), onto: .group(ScopeDragRig.team)))
        try decide(.discard, action: nil)
        try rig.waitForPath("Groups/Team/b.md")
        XCTAssertEqual(rig.browser.selection, rig.selection)
        XCTAssertNotNil(try rig.files.stamp(at: "a.md"))
    }

    func testPayloadForRenamedOrReplacedIdentityIsRejected() throws {
        let payload = try dragPayload()
        try rig.files.move(from: "a.md", to: "renamed.md")
        try rig.index.rebuild()
        drain()
        XCTAssertFalse(try drop(payload, onto: .group(ScopeDragRig.team)))
        try rig.files.write(Data("Replacement".utf8), at: "a.md")
        try rig.index.rebuild()
        drain()
        XCTAssertFalse(try drop(payload, onto: .group(ScopeDragRig.team)))
        XCTAssertEqual(try rig.files.read(at: "a.md"), Data("Replacement".utf8))
    }

    func testCommittedScopeMoveWithFailedPUTRetainsSavedEditsAndNewRevision() throws {
        rig.editor.edit(rig.editor.state.source! + "\nSaved edit")
        XCTAssertTrue(try drop(dragPayload(), onto: .group(ScopeDragRig.team)))
        try decide(.save)
        try rig.waitForPath("Groups/Team/a.md")
        let edited = try rig.files.read(at: "Groups/Team/a.md")
        let transport = ScopeDragTransport { request in
            if request.method == .post { return try ScopeDragTransport.response(SyncAPI.WriteResponse(rev: 2, seq: 2)) }
            XCTAssertEqual(request.method, .put)
            let put = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self, from: XCTUnwrap(request.body))
            XCTAssertEqual(put.baseRev, 2)
            XCTAssertTrue(put.content.contains("Saved edit"))
            return try ScopeDragTransport.response(SyncAPI.ErrorResponse.failure(.internalError), status: 500)
        }
        let result = runPush(transport)
        XCTAssertNotNil(result.failure as? SyncHTTPClientError)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[rig.selection.identity]?.scope, .group(ScopeDragRig.team))
        XCTAssertEqual(rig.states.snapshot.value?.prompts[rig.selection.identity]?.rev, 2)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), edited)
        XCTAssertTrue(rig.editor.state.source!.contains("Saved edit"))
        XCTAssertEqual(transport.requests.map(\.method), [.post, .put])
    }

    func testCreatorDeniedMoveRestoresGroupAndPreservesPrivateCopy() throws {
        XCTAssertTrue(try drop(dragPayload(), onto: .group(ScopeDragRig.team)))
        try rig.waitForPath("Groups/Team/a.md")
        try rig.record(scope: .group(ScopeDragRig.team))
        let baseline = try rig.files.read(at: "Groups/Team/a.md")
        rig.editor.edit(rig.editor.state.source! + "\nNoncreator private edit")
        XCTAssertTrue(try drop(dragPayload(), onto: .all))
        try decide(.save)
        try rig.waitForPath("a.md")
        let transport = ScopeDragTransport { request in
            if request.method == .post { return try ScopeDragTransport.response(SyncAPI.ErrorResponse.failure(.forbidden), status: 403) }
            return try ScopeDragTransport.response(SyncAPI.Prompt(id: ScopeDragRig.id.rawValue, rev: 1,
                scope: .group(groupID: ScopeDragRig.team.rawValue), path: "a.md", content: String(decoding: baseline, as: UTF8.self)))
        }
        let result = runPush(transport)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.result, .refreshMemberships)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), baseline)
        XCTAssertNil(try rig.files.stamp(at: "a.md"))
        let copy = try XCTUnwrap(try rig.files.listFiles().first { $0.relativePath.hasPrefix("Conflicts/") })
        let document = PromptCodec.parseFile(try rig.files.read(at: copy.relativePath), filename: "copy.md")
        XCTAssertNotEqual(document.frontMatter.id, ScopeDragRig.id)
        XCTAssertTrue(document.body.contains("Noncreator private edit"))
        XCTAssertEqual(rig.states.snapshot.value?.groups[ScopeDragRig.team]?.role, .editor)
    }

    func testFileManagerMoveReachesScannerAndPushEngineWithoutDragPayload() throws {
        try rig.files.move(from: "a.md", to: "Groups/Other/a.md")
        let transport = ScopeDragTransport { request in
            XCTAssertTrue(request.url.path.hasSuffix("/move"))
            let move = try JSONDecoder().decode(SyncAPI.MovePromptRequest.self, from: XCTUnwrap(request.body))
            XCTAssertEqual(move.scope, .group(groupID: ScopeDragRig.other.rawValue))
            return try ScopeDragTransport.response(SyncAPI.WriteResponse(rev: 2, seq: 2))
        }
        let result = runPush(transport)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.result, .acknowledged)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(ScopeDragRig.id)]?.scope, .group(ScopeDragRig.other))
    }

    func testExternalFileDropCopiesSourceAndReassignsDuplicateIdentity() throws {
        let tools = try environmentTools()
        let url = tools.directory.appendingPathComponent("external.md")
        let bytes = Data(("---\nid: '" + ScopeDragRig.id.rawValue + "'\n---\nExternal").utf8)
        try bytes.write(to: url)
        let root = LinuxPaths(environment: tools.environment).documentsDirectory.appendingPathComponent("MonkeysPaw")
        let libraryFiles = try RootedFileStore(root: root)
        try libraryFiles.write(bytes, at: "existing.md")
        let environment = LinuxEnvironment(application: application, environment: tools.environment)
        defer { environment.shutdown() }
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { self.otherLibraryWindow() != nil })
        let window = try XCTUnwrap(otherLibraryWindow())
        let list = try settingsWidget("library-list", in: window)
        var files = [g_file_new_for_uri(url.absoluteString)]
        defer { files.compactMap { $0 }.forEach { g_object_unref(UnsafeMutableRawPointer($0)) } }
        let fileList = try XCTUnwrap(gdk_file_list_new_from_array(&files, gsize(files.count)))
        var value = GValue()
        g_value_init(&value, gdk_file_list_get_type())
        g_value_take_boxed(&value, UnsafeMutableRawPointer(fileList))
        defer { g_value_unset(&value) }
        XCTAssertTrue(try emitDrop(&value, on: list))
        XCTAssertTrue(GTKTestSupport.spin { !environment.libraryImportState.isBusy && environment.libraryImportState.createdCount == 1 })
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let imported = try libraryFiles.read(at: "Imported/external.md")
        XCTAssertNotEqual(PromptCodec.parseFile(imported, filename: "external.md").frontMatter.id, ScopeDragRig.id)
        XCTAssertEqual(try libraryFiles.read(at: "existing.md"), bytes)
        drain()
    }

    private func otherLibraryWindow() -> GTK.Widget? {
        var node = gtk_application_get_windows(application)
        while let current = node {
            if let data = current.pointee.data {
                let window = data.assumingMemoryBound(to: GtkWidget.self)
                if window != rig.window, gtk_window_get_title(mp_window(window)).map({ String(cString: $0) }) == LinuxStrings.library {
                    return window
                }
            }
            node = current.pointee.next
        }
        return nil
    }

    func testFileManagerMoveThroughNativeWatcherSchedulesScopeTransfer() throws {
        let tools = try environmentTools()
        let paths = LinuxPaths(environment: tools.environment)
        let data = try RootedFileStore(root: paths.dataDirectory)
        let connection = try SyncAccount(identity: SyncAccountIdentity(serverURL: "https://example.test", userID: ScopeDragRig.user),
            username: "person", deviceID: ULID("00000000000000000000000006")!, deviceName: "Linux", connectionID: UUID())
        try SyncAccountStore(files: data, operations: data).setAccount(connection)
        tools.environment["MONKEYSPAW_DEVICE_" + connection.connectionID.uuidString.replacingOccurrences(of: "-", with: "") + "_TOKEN"] = String(repeating: "a", count: 42) + "A"
        let server = ScopeWatcherServer(bytes: rig.baseline)
        let environment = LinuxEnvironment(application: application, environment: tools.environment, syncTransport: server)
        defer {
            environment.shutdown()
            let finished = ScopePushResult()
            Task.detached { await environment.drainSync(); finished.finish() }
            XCTAssertTrue(GTKTestSupport.spin { finished.done })
        }
        _ = environment.libraryStatusModel
        let account = try XCTUnwrap(environment.accountModel)
        XCTAssertTrue(GTKTestSupport.spin { !account.state.isBusy })
        account.startup()
        XCTAssertTrue(GTKTestSupport.spin(until: { environment.syncService?.report.lastSuccess != nil }, timeout: .seconds(10)))
        let files = try RootedFileStore(root: paths.documentsDirectory.appendingPathComponent("MonkeysPaw"))
        try files.move(from: "a.md", to: "Groups/Team/a.md")
        // No manual index refresh or syncNow: GIO and the shared worker must
        // carry this file-manager operation through scheduling to the engine.
        XCTAssertTrue(GTKTestSupport.spin(until: { server.moveCount == 1 }, timeout: .seconds(8)))
        XCTAssertTrue(GTKTestSupport.spin { environment.libraryBrowserModel.rows.contains { $0.relativePath == "Groups/Team/a.md" } })
        XCTAssertEqual(server.lastMove?.scope, .group(groupID: ScopeDragRig.team.rawValue))
        XCTAssertEqual(server.lastMove?.path, "a.md")
        XCTAssertNil(try files.stamp(at: "a.md"))
    }

    private func environmentTools() throws -> FakeLinuxTools {
        let tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        tools.environment["XDG_CURRENT_DESKTOP"] = "sway"
        return tools
    }

    private func runPush(_ transport: ScopeDragTransport) -> ScopePushResult {
        let result = ScopePushResult()
        let rig = self.rig!
        Task.detached {
            do { result.result = try await rig.push(transport) }
            catch { result.failure = error }
            result.finish()
        }
        XCTAssertTrue(GTKTestSupport.spin(until: { result.done }, timeout: .seconds(8)))
        return result
    }

    private func decide(_ choice: EditorDecision, action: EditorDiscardAction? = .move) throws {
        XCTAssertTrue(GTKTestSupport.spin { self.rig.editor.state.pendingDecision != nil })
        let pending = try XCTUnwrap(rig.editor.state.pendingDecision)
        if let action { XCTAssertEqual(pending.action, action) }
        rig.editor.resolveDecision(choice, id: pending.id)
        XCTAssertTrue(GTKTestSupport.spin { self.rig.editor.state.pendingDecision == nil })
        drain()
    }

    private func promptWidget(path: String? = nil) throws -> GTK.Widget {
        let list = try settingsWidget("library-list", in: rig.window)
        let position = try XCTUnwrap(rig.browser.rows.firstIndex { $0.relativePath.string == (path ?? rig.selection.relativePath.string) })
        let row = try XCTUnwrap(gtk_list_box_get_row_at_index(mp_list_box(list), Int32(position)))
        return try XCTUnwrap(gtk_widget_get_first_child(UnsafeMutableRawPointer(row).assumingMemoryBound(to: GtkWidget.self)))
    }

    private func destinationWidget(_ section: LibrarySectionID) throws -> GTK.Widget {
        let sidebar = try settingsWidget("library-sidebar", in: rig.window)
        let position = try XCTUnwrap(rig.browser.sections.firstIndex { $0.id == section })
        let row = try XCTUnwrap(gtk_list_box_get_row_at_index(mp_list_box(sidebar), Int32(position)))
        return try XCTUnwrap(gtk_widget_get_first_child(UnsafeMutableRawPointer(row).assumingMemoryBound(to: GtkWidget.self)))
    }

    private func dragPayload(path: String? = nil) throws -> String {
        drain()
        return try XCTUnwrap(preparedPayload(on: promptWidget(path: path)))
    }

    private func controller(on widget: GTK.Widget, type: GType) -> UnsafeMutableRawPointer? {
        let controllers = gtk_widget_observe_controllers(widget)!
        defer { g_object_unref(UnsafeMutableRawPointer(controllers)) }
        for index in 0..<g_list_model_get_n_items(controllers) {
            guard let item = g_list_model_get_item(controllers, index) else { continue }
            if g_type_check_instance_is_a(item.assumingMemoryBound(to: GTypeInstance.self), type) != 0 { return item }
            g_object_unref(item)
        }
        return nil
    }

    private func preparedPayload(on widget: GTK.Widget) throws -> String? {
        let source = try XCTUnwrap(controller(on: widget, type: gtk_drag_source_get_type()))
        defer { g_object_unref(source) }
        var arguments = [GValue](repeating: GValue(), count: 3)
        g_value_init(&arguments[0], gtk_drag_source_get_type())
        g_value_set_object(&arguments[0], source)
        for index in [1, 2] { g_value_init(&arguments[index], g_type_from_name("gdouble")); g_value_set_double(&arguments[index], 0) }
        defer { for index in arguments.indices { g_value_unset(&arguments[index]) } }
        var result = GValue()
        g_value_init(&result, gdk_content_provider_get_type())
        defer { g_value_unset(&result) }
        arguments.withUnsafeMutableBufferPointer {
            g_signal_emitv($0.baseAddress, g_signal_lookup("prepare", gtk_drag_source_get_type()), 0, &result)
        }
        guard let provider = g_value_get_object(&result) else { return nil }
        let formats = gdk_content_provider_ref_formats(provider.assumingMemoryBound(to: GdkContentProvider.self))!
        defer { gdk_content_formats_unref(formats) }
        XCTAssertEqual(gdk_content_formats_contain_gtype(formats, mp_string_type()), 0,
                       "Internal row payloads must not be offered as plain text")
        let serialized = gdk_content_formats_union_serialize_mime_types(gdk_content_formats_ref(formats))!
        defer { gdk_content_formats_unref(serialized) }
        var mimeCount: gsize = 0
        _ = gdk_content_formats_get_mime_types(serialized, &mimeCount)
        XCTAssertEqual(mimeCount, 0, "Internal row payloads must not be serialized for another process")
        var value = GValue()
        g_value_init(&value, mp_library_row_type())
        defer { g_value_unset(&value) }
        XCTAssertNotEqual(gdk_content_provider_get_value(provider.assumingMemoryBound(to: GdkContentProvider.self), &value, nil), 0)
        return mp_library_row_string(&value).map(String.init(cString:))
    }

    private func drop(_ payload: String, onto section: LibrarySectionID, requiresTarget: Bool = true) throws -> Bool {
        drain()
        let widget = try destinationWidget(section)
        if !requiresTarget {
            guard let target = controller(on: widget, type: gtk_drop_target_get_type()) else { return false }
            g_object_unref(target)
        }
        return try emitRowDrop(payload, on: widget)
    }

    private func emitRowDrop(_ payload: String, on widget: GTK.Widget) throws -> Bool {
        var value = GValue()
        g_value_init(&value, mp_library_row_type())
        payload.withCString { g_value_set_boxed(&value, $0) }
        defer { g_value_unset(&value) }
        return try emitDrop(&value, on: widget)
    }

    private func emitStringDrop(_ payload: String, on widget: GTK.Widget) throws -> Bool {
        var value = GValue()
        g_value_init(&value, mp_string_type())
        g_value_set_string(&value, payload)
        defer { g_value_unset(&value) }
        return try emitDrop(&value, on: widget)
    }

    private func emitDrop(_ value: inout GValue, on widget: GTK.Widget) throws -> Bool {
        let target = try XCTUnwrap(controller(on: widget, type: gtk_drop_target_get_type()))
        defer { g_object_unref(target) }
        var arguments = [GValue](repeating: GValue(), count: 4)
        g_value_init(&arguments[0], gtk_drop_target_get_type())
        g_value_set_object(&arguments[0], target)
        g_value_init(&arguments[1], g_value_get_type())
        g_value_set_boxed(&arguments[1], &value)
        for index in [2, 3] { g_value_init(&arguments[index], g_type_from_name("gdouble")); g_value_set_double(&arguments[index], 0) }
        defer { for index in arguments.indices { g_value_unset(&arguments[index]) } }
        var result = GValue()
        g_value_init(&result, g_type_from_name("gboolean"))
        defer { g_value_unset(&result) }
        arguments.withUnsafeMutableBufferPointer {
            g_signal_emitv($0.baseAddress, g_signal_lookup("drop", gtk_drop_target_get_type()), 0, &result)
        }
        return g_value_get_boolean(&result) != 0
    }

    private func drain() { for _ in 0..<30 { _ = g_main_context_iteration(nil, 0) } }
}

private final class ScopeDragRig {
    static let id = ULID("00000000000000000000000004")!
    static let user = ULID("00000000000000000000000001")!
    static let team = ULID("00000000000000000000000003")!
    static let other = ULID("00000000000000000000000007")!
    let root: URL
    let files: RootedFileStore
    let data: RootedFileStore
    let library: LibraryService
    let index: PromptIndex
    let editor: EditorModel
    let browser: LibraryBrowserModel
    let states: SyncStateStore
    let binding: SyncLibraryIdentity
    let baseline: Data
    var view: LinuxLibraryWindow!
    let window: GTK.Widget
    private let work = LinuxBackgroundWork()
    var selection: LibraryPromptSelection { editor.state.prompt! }

    init(application: UnsafeMutablePointer<GtkApplication>) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-y30-scope-" + UUID().uuidString)
        files = try RootedFileStore(root: root.appendingPathComponent("library"), trashRoot: root.appendingPathComponent("Trash"))
        data = try RootedFileStore(root: root.appendingPathComponent("data"))
        let clock = SystemClock()
        let usage = UsageStore(files: data, clock: clock)
        library = LibraryService(library: files, data: data, clock: clock, entropy: SystemEntropy(), keyedStores: [usage])
        try files.write(Data(("---\nid: '" + Self.id.rawValue + "'\n---\nOriginal").utf8), at: "a.md")
        let entry = try library.load(at: "a.md")
        _ = try library.save(entry.document, at: "a.md", expectedStamp: entry.stamp)
        baseline = try files.read(at: "a.md")
        try files.write(Data("---\nid: '00000000000000000000000008'\n---\nFolder seed".utf8), at: "Folder/seed.md")
        binding = try SyncLibraryIdentity(account: SyncAccountIdentity(serverURL: "https://example.test", userID: Self.user),
            root: SyncLibraryRoot(root.appendingPathComponent("library").path))
        states = SyncStateStore(files: data, operations: data)
        let savedBaseline = baseline
        try states.update(for: binding) {
            $0.groups = [Self.team: try SyncGroupState(name: "Team label", folder: "Team", role: .editor),
                         Self.other: try SyncGroupState(name: "Other label", folder: "Other", role: .owner)]
            $0.prompts = [.assigned(Self.id): try SyncPromptState(scope: .user(Self.user), path: "a.md", rev: 1,
                canonicalHash: SyncHash(bytes: savedBaseline))]
        }
        _ = try GroupAccessService(library: library, states: states,
            accounts: SyncAccountStore(files: data, operations: data), libraryRoot: binding.root.path)
        index = PromptIndex(service: library, usage: usage, clock: clock)
        try index.rebuild()
        let main = GLibMainThread()
        let editing = PromptEditingService(library: library, index: index, work: work, main: main)
        editor = EditorModel(editing: editing, clock: clock, timeZone: { TimeZone(secondsFromGMT: 0)! }, main: main)
        browser = LibraryBrowserModel(index: index, usage: usage, favorites: library, main: main, editor: editor)
        view = LinuxLibraryWindow(application: application, browser: browser, editor: editor, openFolder: {})
        view.show()
        window = try XCTUnwrap(gtk_application_get_windows(application)?.pointee.data).assumingMemoryBound(to: GtkWidget.self)
        let selection = LibraryPromptSelection(identity: .assigned(Self.id), relativePath: "a.md")
        browser.selectPrompt(selection)
        view.openPrompt(selection)
        XCTAssertTrue(GTKTestSupport.spin { self.editor.state.prompt == selection && self.editor.state.source != nil })
    }

    func waitForPath(_ path: String) throws {
        XCTAssertTrue(GTKTestSupport.spin {
            self.editor.state.prompt?.relativePath == RelativePath(path) && self.editor.state.status != .commandRunning
                && self.editor.state.status != .loading && self.browser.selection == self.editor.state.prompt
        }, String(describing: editor.state.status))
    }

    func role(_ role: SyncAPI.Role, group: ULID) throws {
        try states.update(for: binding) { state in
            let previous = try XCTUnwrap(state.groups[group])
            state.groups[group] = try SyncGroupState(name: previous.name, folder: previous.folder, role: role)
        }
        XCTAssertTrue(GTKTestSupport.spin { self.browser.sections.first { $0.id == .group(group) }?.role?.rawValue == role.rawValue })
    }

    func record(scope: SyncScopeKey) throws {
        let bytes = try files.read(at: selection.relativePath.string)
        try states.update(for: binding) {
            $0.prompts[.assigned(Self.id)] = try SyncPromptState(scope: scope, path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: bytes))
        }
    }

    func push(_ transport: ScopeDragTransport) async throws -> SyncPushResult {
        let mutations = SyncLibraryMutations(library: library, operations: files)
        let journal = try SyncApplyJournal(files: data, operations: data, mutations: mutations, states: states)
        func scanFiles() throws -> SyncLocalScan {
            try SyncLocalScanner.scan(binding: binding, state: states.snapshot.value,
                availability: .available, freshID: { try ULID.generate(at: Date(), entropy: SystemEntropy().bytes(count: 10)) }, mutations: mutations)
        }
        var scan = try scanFiles()
        if let preparation = scan.preparation {
            XCTAssertEqual(try journal.apply(preparation), .committed)
            scan = try scanFiles()
        }
        let change = try XCTUnwrap(scan.changes.first { change in
            if case .move(let local, _) = change { return local.identity == .assigned(Self.id) }
            return false
        })
        let server = try SyncServerURL("https://example.test")
        let client = SyncHTTPClient(server: server, transport: transport,
            credential: SyncCredential(server: server, token: SecretValue(String(repeating: "a", count: 42) + "A")))
        let engine = try SyncPushEngine(binding: binding, client: client, states: states,
            pending: SyncPendingOperationStore(files: data, operations: data), mutations: mutations, journal: journal,
            ownership: { nil }, device: "Linux", freshID: { try ULID.generate(at: Date(), entropy: SystemEntropy().bytes(count: 10)) })
        return try await engine.push(change, availability: .available, baseBytes: baseline)
    }

    func close() {
        view?.tearDown()
        browser.deactivate()
        editor.deactivate()
        var done = false
        work.run { GTK.onMainLoop { done = true } }
        XCTAssertTrue(GTKTestSupport.spin { done })
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ScopePushResult: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var result: SyncPushResult?
    var failure: Error?
    var done: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func finish() { lock.lock(); finished = true; lock.unlock() }
}

private final class ScopeDragTransport: HTTPTransporting, @unchecked Sendable {
    let respond: (HTTPRequest) throws -> HTTPResponse
    private(set) var requests: [HTTPRequest] = []
    init(_ respond: @escaping (HTTPRequest) throws -> HTTPResponse) { self.respond = respond }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { requests.append(request); return try respond(request) }
    static func response<T: Encodable>(_ body: T, status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(statusCode: status, body: try JSONEncoder().encode(body))
    }
}

private final class ScopeWatcherServer: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private let bytes: Data
    private var moves: [SyncAPI.MovePromptRequest] = []
    var moveCount: Int { lock.lock(); defer { lock.unlock() }; return moves.count }
    var lastMove: SyncAPI.MovePromptRequest? { lock.lock(); defer { lock.unlock() }; return moves.last }
    init(bytes: Data) { self.bytes = bytes }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let timestamp = "2026-10-15T00:00:00.000Z"
        if request.url.path.hasSuffix("/me") {
            return try ScopeDragTransport.response(SyncAPI.MeResponse(user: .init(id: ScopeDragRig.user.rawValue,
                username: "person", displayName: nil, accountKind: .member, createdAt: timestamp, disabledAt: nil),
                groups: [.init(groupID: ScopeDragRig.team.rawValue, name: "Team", role: .editor)],
                devices: [.init(id: "00000000000000000000000006", name: "Linux", createdAt: timestamp,
                    lastSeenAt: nil, revokedAt: nil, isCurrent: true)]))
        }
        if request.url.path.hasSuffix("/move") {
            let move = try JSONDecoder().decode(SyncAPI.MovePromptRequest.self, from: XCTUnwrap(request.body))
            record(move)
            return try ScopeDragTransport.response(SyncAPI.WriteResponse(rev: 2, seq: 2))
        }
        let moved = moveCount != 0
        if request.method == .get {
            return try ScopeDragTransport.response(SyncAPI.Prompt(id: ScopeDragRig.id.rawValue, rev: moved ? 2 : 1,
                scope: moved ? .group(groupID: ScopeDragRig.team.rawValue) : .user, path: "a.md", content: String(decoding: bytes, as: UTF8.self)))
        }
        XCTAssertTrue(request.url.path.hasSuffix("/sync/pull"))
        let prompt = SyncAPI.FeedItem.upsert(seq: moved ? 2 : 1, prompt: .init(id: ScopeDragRig.id.rawValue,
            rev: moved ? 2 : 1, path: "a.md", content: String(decoding: bytes, as: UTF8.self)))
        return try ScopeDragTransport.response(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: [
            .init(identity: .user(userID: ScopeDragRig.user.rawValue), mode: .snapshot, head: moved ? 2 : 1,
                cursor: moved ? "u2" : "u1", hasMore: false, items: moved ? [] : [prompt]),
            .init(identity: .group(groupID: ScopeDragRig.team.rawValue, name: "Team", role: .editor), mode: .snapshot,
                head: moved ? 2 : 0, cursor: moved ? "g2" : "g0", hasMore: false, items: moved ? [prompt] : [])], removed: []))
    }

    private func record(_ move: SyncAPI.MovePromptRequest) { lock.lock(); moves.append(move); lock.unlock() }
}
#endif
