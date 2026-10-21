#if os(Linux)
import CGtk
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxLibraryImportTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var files: RootedFileStore!
    private var chooser: ImportTestChooser!
    private var work: ImportTestWork!

    override func setUpWithError() throws {
        _ = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        tools.environment["XDG_CURRENT_DESKTOP"] = "sway"
        files = try RootedFileStore(root: LinuxPaths(environment: tools.environment).documentsDirectory
            .appendingPathComponent("MonkeysPaw", isDirectory: true))
        chooser = ImportTestChooser()
        work = ImportTestWork()
        compose()
    }

    override func tearDown() {
        work?.runAll()
        drain()
        if let environment {
            environment.shutdown()
            let drained = DispatchGroup()
            drained.enter()
            Task.detached { await environment.drainSync(); drained.leave() }
            XCTAssertTrue(GTKTestSupport.spin {
                self.work.runAll()
                return drained.wait(timeout: .now()) == .success
            })
        }
        environment = nil
        drain()
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        files = nil
        chooser = nil
        work = nil
        tools = nil
    }

    func testReportlessTerminalStepsReleaseBatchAndAcceptAnotherImport() throws {
        let file = try source("a.md", "First")
        let folderFile = try source("Folder/b.md", "Second")
        let state = environment.libraryImportState
        let model = environment.importModel
        let idle = model.state
        let observed = try XCTUnwrap(model.onChange)
        model.onChange = { value in observed(value.isImporting ? value : idle) }
        XCTAssertTrue(state.importURLs([file, folderFile.deletingLastPathComponent()]))
        finishImport()
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.progress)
        XCTAssertTrue(state.canImport)
        XCTAssertEqual(state.requestNumber, 2)
        XCTAssertTrue(state.reports.isEmpty)
        XCTAssertEqual(state.message, LinuxImportStrings.missingReport)
        XCTAssertEqual(try files.read(at: "Imported/a.md"), Data("First".utf8))
        XCTAssertEqual(try files.read(at: "Imported/b.md"), Data("Second".utf8))
        model.onChange = observed
        XCTAssertTrue(state.importURLs([file]))
        finishImport()
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.createdCount, 1)
    }

    func testEmptyPreparationClearsBusyWithoutStartingCoreImport() throws {
        let state = LinuxLibraryImportState(model: environment.importModel, available: true,
            main: environment.mainThread, prepare: { _, done in done([]) }, openImported: { _ in false })
        defer { state.deactivate() }
        XCTAssertTrue(state.importURLs([try source("empty.md", "Unused")]))
        drainWork()
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.progress)
        XCTAssertTrue(state.canImport)
        XCTAssertFalse(environment.importModel.state.isImporting)
        XCTAssertNil(try files.stamp(at: "Imported/empty.md"))
    }

    func testShutdownRetiresPreparationAndClearsBusyAndObservers() throws {
        let state = environment.libraryImportState
        let model = environment.importModel
        XCTAssertTrue(state.importURLs([try source("queued.md", "Unused")]))
        environment.shutdown()
        drainWork()
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.progress)
        XCTAssertNil(state.onChange)
        XCTAssertNil(state.onChoose)
        XCTAssertNil(model.onChange)
        XCTAssertFalse(state.canImport)
        XCTAssertNil(try files.stamp(at: "Imported/queued.md"))
    }

    func testHeldWorkerAcceptsConcurrentTeardownSubmissionsWhileDraining() {
        let queued = ImportTestWork()
        let producer = DispatchGroup()
        let completions = DispatchGroup()
        for _ in 0..<1_000 { completions.enter() }
        producer.enter()
        DispatchQueue.global().async {
            for _ in 0..<1_000 { queued.run { completions.leave() } }
            producer.leave()
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while producer.wait(timeout: .now()) != .success, ContinuousClock().now < deadline {
            queued.runAll()
        }
        XCTAssertEqual(producer.wait(timeout: .now()), .success)
        queued.runAll()
        XCTAssertEqual(completions.wait(timeout: .now()), .success)
    }

    func testImportBindingAttachesActionsAndReport() throws {
        let view = LinuxLibraryWindow(application: application,
            browser: environment.libraryBrowserModel, editor: environment.editorModel,
            imports: .init(state: environment.libraryImportState, chooser: chooser), openFolder: {})
        defer { view.tearDown() }
        let window = try XCTUnwrap(libraryWindow)
        _ = try settingsWidget("library-import", in: window)
        _ = try settingsWidget("library-import-folder", in: window)
        _ = try settingsWidget("library-import-report", in: window)
    }

    func testRebindImportsAndDestinationsBelongToReplacementGraph() throws {
        let old = environment.libraryImportState
        let view = LinuxLibraryWindow(application: application,
            browser: environment.libraryBrowserModel, editor: environment.editorModel,
            imports: .init(state: old, chooser: chooser), openFolder: {})
        defer { view.tearDown() }
        view.show()
        let window = try XCTUnwrap(libraryWindow)
        let second = tools.directory.appendingPathComponent("Second")
        let replacement = try RootedFileStore(root: second)
        try replacement.write(Data("Seed".utf8), at: "Chosen/seed.md")
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        view.rebind(browser: environment.libraryBrowserModel, editor: environment.editorModel,
                    imports: environment.libraryImportState)
        drainWork()
        let state = environment.libraryImportState
        XCTAssertNil(old.onChange)
        XCTAssertNil(old.onChoose)
        XCTAssertNotNil(state.onChange)
        XCTAssertNotNil(state.onChoose)
        XCTAssertTrue(state.destinations.contains(RelativePath("Chosen")))
        let destination = try settingsWidget("library-import-destination", in: window)
        let position = try XCTUnwrap(state.destinations.firstIndex(of: RelativePath("Chosen")))
        gtk_combo_box_set_active(mp_combo_box(destination), Int32(position))
        XCTAssertEqual(state.destination, RelativePath("Chosen"))
        try click("library-import", in: window)
        chooser.requests.last?.done([try source("new.md", "New graph")])
        finishImport()
        XCTAssertEqual(try replacement.read(at: "Chosen/new.md"), Data("New graph".utf8))
        XCTAssertNil(try files.stamp(at: "Chosen/new.md"))
    }

    func testReportOpenButtonsTrackLibraryAvailabilityWithoutRebuildingReport() throws {
        let window = try openLibrary()
        let state = environment.libraryImportState
        XCTAssertTrue(state.importURLs([try source("available.md", "Imported")]))
        finishImport()
        let open = try settingsWidget("library-import-open", in: window)
        XCTAssertNotEqual(gtk_widget_get_sensitive(open), 0)
        state.setLibraryAvailable(false)
        XCTAssertTrue(state.hasReport)
        XCTAssertEqual(gtk_widget_get_sensitive(open), 0)
        state.setLibraryAvailable(true)
        XCTAssertNotEqual(gtk_widget_get_sensitive(open), 0)
        XCTAssertEqual(try settingsWidget("library-import-open", in: window), open)
    }

    func testChooserImportsMixedSourcesAndRendersTypedSkipsMetadataAndWarningsWithoutOverwrite() throws {
        try files.write(Data("Existing".utf8), at: "Imported/plain.md")
        let plain = try source("plain.md", "Native {{name}}")
        let dot = try source("dot.prompt", "---\nmodel: keep\ninput:\n  schema:\n    name: string\n---\nHello {{name}} {{#if name}}")
        let prompty = try source("foreign.prompty", "---\ninputs:\n  count: {type: integer}\n---\nBody")
        let text = try source("other.txt", "Unsupported")
        let invalid = try source("encoding.md", "")
        try Data([0xff]).write(to: invalid)
        let large = try source("large.md", "")
        try Data(repeating: 65, count: Limits.importFileCapBytes + 1).write(to: large)
        let nested = try source("Folder/nested/a.md", "Nested")
        let folder = nested.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.md"), withDestinationURL: plain)
        let window = try openLibrary()
        try click("library-import", in: window)
        XCTAssertEqual(chooser.requests.last?.mode, .files)
        chooser.requests.last?.done([folder, large, plain, prompty, invalid, dot, text])
        finishImport()
        let state = environment.libraryImportState
        XCTAssertEqual(state.createdCount, 4)
        XCTAssertEqual(state.skippedCount, 4)
        XCTAssertEqual(state.files.map(\.sourcePath), state.files.map(\.sourcePath).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        XCTAssertEqual(try files.read(at: "Imported/plain.md"), Data("Existing".utf8))
        XCTAssertEqual(try files.read(at: "Imported/plain 2.md"), Data("Native {{name}}".utf8))
        XCTAssertEqual(try files.read(at: "Imported/nested/a.md"), Data("Nested".utf8))
        let skips = state.files.compactMap { file -> ImportSkipReason? in
            if case .skipped(let reason) = file.outcome { return reason }; return nil
        }
        XCTAssertTrue(skips.contains(.symbolicLink))
        XCTAssertTrue(skips.contains(.unsupportedExtension))
        XCTAssertTrue(skips.contains(.fileTooLarge))
        XCTAssertTrue(skips.contains(.invalidUTF8))
        let report = try settingsWidget("library-import-report", in: window)
        XCTAssertNotEqual(gtk_widget_get_visible(report), 0)
        let rendered = labels(report).joined(separator: "\n")
        XCTAssertTrue(rendered.contains(LinuxImportStrings.summary(created: 4, skipped: 4)))
        XCTAssertTrue(rendered.contains("Preserved metadata:"))
        XCTAssertTrue(rendered.contains("Mapped input.schema.name"))
        XCTAssertTrue(rendered.contains(LinuxImportStrings.loss(.frontMatterPresentation)))
        XCTAssertTrue(rendered.contains(LinuxImportStrings.warning(.unsupportedInput("inputs.count"))))
        for reason in skips { XCTAssertTrue(rendered.contains(LinuxImportStrings.skipped(reason))) }
        try click("library-import-dismiss", in: window)
        drain()
        XCTAssertFalse(state.hasReport)
        XCTAssertEqual(gtk_widget_get_visible(report), 0)
    }

    func testFolderChooserDestinationAndRealGTKDropShareIntent() throws {
        try files.write(Data("Existing folder".utf8), at: "Chosen/seed.md")
        let url = try source("Folder/deeper/prompt.md", "Folder source")
        let folder = url.deletingLastPathComponent().deletingLastPathComponent()
        let window = try openLibrary()
        let state = environment.libraryImportState
        let destination = try settingsWidget("library-import-destination", in: window)
        let position = try XCTUnwrap(state.destinations.firstIndex(of: RelativePath("Chosen")))
        gtk_combo_box_set_active(mp_combo_box(destination), Int32(position))
        XCTAssertEqual(state.destination, RelativePath("Chosen"))
        try click("library-import-folder", in: window)
        XCTAssertEqual(chooser.requests.last?.mode, .folder)
        chooser.requests.last?.done([folder])
        finishImport()
        XCTAssertEqual(try files.read(at: "Chosen/deeper/prompt.md"), Data("Folder source".utf8))
        XCTAssertEqual(state.files.first?.outcome, .created(path: "Chosen/deeper/prompt.md"))
        let dropped = try source("dropped.prompt", "---\ninput:\n  schema:\n    topic: string\n---\n{{topic}}")
        XCTAssertTrue(try drop([dropped, folder], onto: window))
        XCTAssertFalse(try drop([dropped], onto: window), "A busy import must reject a second drop")
        finishImport()
        XCTAssertEqual(state.createdCount, 2)
        XCTAssertEqual(try files.read(at: "Chosen/deeper/prompt 2.md"), Data("Folder source".utf8))
        XCTAssertTrue(state.files.contains { $0.outcome == .created(path: "Chosen/dropped.md") })
    }

    func testProgressAndBusyRefusalFreezeDestinationAcrossWholeBatch() throws {
        try files.write(Data("Existing".utf8), at: "Chosen/seed.md")
        let first = try source("a.md", "First")
        let nested = try source("Folder/b.md", "Second")
        let folder = nested.deletingLastPathComponent()
        let window = try openLibrary()
        let state = environment.libraryImportState
        let model = environment.importModel
        var progress: [ImportProgress] = []
        let observed = model.onChange
        model.onChange = { value in
            if let value = value.progress { progress.append(value) }
            observed?(value)
        }
        try click("library-import", in: window)
        XCTAssertFalse(state.canImport)
        chooser.requests.last?.done([first, folder])
        XCTAssertTrue(GTKTestSupport.spin { state.isBusy })
        XCTAssertEqual(state.progress, .enumerating)
        XCTAssertEqual(gtk_widget_get_sensitive(try settingsWidget("library-import", in: window)), 0)
        XCTAssertEqual(gtk_widget_get_sensitive(try settingsWidget("library-import-folder", in: window)), 0)
        XCTAssertEqual(gtk_widget_get_sensitive(try settingsWidget("library-import-destination", in: window)), 0)
        XCTAssertNotEqual(gtk_widget_get_visible(try settingsWidget("library-import-progress", in: window)), 0)
        state.choose(.files)
        XCTAssertEqual(chooser.requests.count, 1)
        XCTAssertFalse(state.importURLs([first]))
        state.selectDestination(RelativePath("Chosen"))
        finishImport()
        XCTAssertTrue(progress.contains(.enumerating))
        XCTAssertTrue(progress.contains(.importing(completed: 0, total: 1)))
        XCTAssertTrue(progress.contains(.importing(completed: 1, total: 1)))
        XCTAssertEqual(state.requestCount, 2)
        XCTAssertEqual(state.destination, RelativePath("Imported"))
        let paths = state.files.compactMap { file -> String? in
            if case .created(let path) = file.outcome { return path }; return nil
        }
        XCTAssertEqual(Set(paths), ["Imported/a.md", "Imported/b.md"])
    }

    func testMixedURLHintDisappearsWhenImportFinishes() throws {
        let window = try openLibrary()
        let state = environment.libraryImportState
        let local = try source("local.md", "Local")
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/prompt.md"))
        XCTAssertTrue(try drop([local, remote], onto: window))
        XCTAssertEqual(state.message, LinuxImportStrings.fileURLsOnly)
        finishImport()
        XCTAssertEqual(state.createdCount, 1)
        XCTAssertNil(state.message)
        XCTAssertEqual(gtk_widget_get_visible(try settingsWidget("library-import-message", in: window)), 0)
    }

    func testBusyDropExplainsRefusalAndClearsHintAtCompletion() throws {
        let window = try openLibrary()
        let state = environment.libraryImportState
        let local = try source("busy.md", "Local")
        XCTAssertTrue(try drop([local], onto: window))
        XCTAssertFalse(try drop([local], onto: window))
        XCTAssertEqual(state.message, LinuxImportStrings.importInProgress)
        XCTAssertNotEqual(gtk_widget_get_visible(try settingsWidget("library-import-message", in: window)), 0)
        finishImport()
        XCTAssertEqual(state.createdCount, 1)
        XCTAssertNil(state.message)
        XCTAssertEqual(gtk_widget_get_visible(try settingsWidget("library-import-message", in: window)), 0)
    }

    func testBusyRefusalAndBatchCompletionPreserveMissingReportDiagnostic() throws {
        let first = try source("first.md", "First")
        let second = try source("Folder/second.md", "Second")
        let state = environment.libraryImportState
        let model = environment.importModel
        let idle = model.state
        let observed = try XCTUnwrap(model.onChange)
        var checkedBusyRefusal = false
        model.onChange = { [weak state] value in
            observed(value.isImporting ? value : idle)
            if state?.message == LinuxImportStrings.missingReport, state?.isBusy == true {
                checkedBusyRefusal = true
                XCTAssertFalse(state?.importURLs([first]) ?? true)
                XCTAssertEqual(state?.message, LinuxImportStrings.missingReport)
            }
        }
        XCTAssertTrue(state.importURLs([first, second.deletingLastPathComponent()]))
        finishImport()
        XCTAssertTrue(checkedBusyRefusal)
        XCTAssertEqual(state.requestNumber, 2)
        XCTAssertEqual(state.message, LinuxImportStrings.missingReport)
    }

    func testRebindCancelsNativeImportChooserAndRetiresItsResponse() throws {
        let state = environment.libraryImportState
        let local = try source("late-native.md", "Late")
        var native: OpaquePointer?
        let nativeChooser = GTKImportChooser(showDialog: {
            g_object_ref(UnsafeMutableRawPointer($0))
            native = $0
        })
        defer { if let native { g_object_unref(UnsafeMutableRawPointer(native)) } }
        let view = LinuxLibraryWindow(application: application,
            browser: environment.libraryBrowserModel, editor: environment.editorModel,
            imports: .init(state: state, chooser: nativeChooser), openFolder: {})
        defer { view.tearDown() }
        view.show()
        state.choose(.files)
        let dialog = try XCTUnwrap(native)
        let file = try XCTUnwrap(g_file_new_for_path(local.path))
        defer { g_object_unref(UnsafeMutableRawPointer(file)) }
        XCTAssertNotEqual(gtk_file_chooser_set_file(mp_file_chooser(dialog), file, nil), 0)
        XCTAssertTrue(GTKTestSupport.spin {
            guard let selected = gtk_file_chooser_get_file(mp_file_chooser(dialog)) else { return false }
            defer { g_object_unref(UnsafeMutableRawPointer(selected)) }
            return g_file_equal(file, selected) != 0
        })
        XCTAssertTrue(state.isChoosing)
        view.rebind(browser: environment.libraryBrowserModel, editor: environment.editorModel, imports: state)
        XCTAssertFalse(state.isChoosing)
        XCTAssertTrue(state.canImport)
        mp_test_emit_native_response(dialog, GTK_RESPONSE_ACCEPT.rawValue)
        drainWork()
        XCTAssertFalse(state.isBusy)
        XCTAssertFalse(state.hasReport)
        XCTAssertNil(try files.stamp(at: "Imported/late-native.md"))
    }

    func testCloseDuringImportKeepsReportOnReopenAndReportOpenUsesEditorGuard() throws {
        try files.write(Data("Old prompt".utf8), at: "old.md")
        let url = try source("new.md", "Imported prompt")
        let window = try openLibrary()
        let state = environment.libraryImportState
        XCTAssertTrue(state.importURLs([url]))
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(window) == 0 })
        finishImport()
        XCTAssertTrue(state.hasReport)
        XCTAssertEqual(try openLibrary(), window)
        XCTAssertNotEqual(gtk_widget_get_visible(try settingsWidget("library-import-report", in: window)), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryBrowserModel.rows.contains { $0.relativePath.string == "Imported/new.md" } })
        let old = try XCTUnwrap(environment.libraryBrowserModel.rows.first { $0.relativePath.string == "old.md" })
        environment.editorModel.request(.open(old.selection)) { _ in }
        drainWork()
        XCTAssertEqual(environment.editorModel.state.prompt?.relativePath.string, "old.md")
        environment.editorModel.edit("Unsaved")
        try click("library-import-open", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.pendingDecision != nil })
        let decision = try XCTUnwrap(environment.editorModel.state.pendingDecision)
        XCTAssertEqual(decision.action, .open(LibraryPromptSelection(identity: try XCTUnwrap(environment.libraryBrowserModel.rows.first { $0.relativePath.string == "Imported/new.md" }).identity,
            relativePath: RelativePath("Imported/new.md"))))
        environment.editorModel.resolveDecision(.discard, id: decision.id)
        drainWork()
        XCTAssertEqual(environment.editorModel.state.prompt?.relativePath.string, "Imported/new.md")
        XCTAssertEqual(environment.editorModel.state.source, "Imported prompt")
        XCTAssertEqual(try files.read(at: "old.md"), Data("Old prompt".utf8))
    }

    func testLibrarySwitchRetiresQueuedImportAndLateChooserResults() throws {
        let source = try source("a.md", "Queued")
        let window = try openLibrary()
        let old = environment.libraryImportState
        let oldModel = environment.importModel
        XCTAssertTrue(old.importURLs([source]))
        // Prepare on BackgroundWork, then queue the actual Core import.
        work.runAll()
        drain()
        XCTAssertTrue(oldModel.state.isImporting)
        let second = tools.directory.appendingPathComponent("Second")
        let replacement = try RootedFileStore(root: second)
        try replacement.write(Data("Seed".utf8), at: "seed.md")
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        drainWork()
        XCTAssertNil(oldModel.onChange)
        XCTAssertFalse(old.canImport)
        XCTAssertFalse(old.hasReport)
        XCTAssertNil(try files.stamp(at: "Imported/a.md"))
        XCTAssertNil(try replacement.stamp(at: "Imported/a.md"))
        XCTAssertTrue(environment.importModel !== oldModel)
        try click("library-import", in: window)
        let reply = try XCTUnwrap(chooser.requests.last?.done)
        let choosingState = environment.libraryImportState
        XCTAssertEqual(environment.switchLibrary(to: nil), .switched)
        XCTAssertGreaterThan(chooser.cancelCount, 0)
        reply([source])
        drainWork()
        XCTAssertFalse(choosingState.canImport)
        XCTAssertFalse(environment.libraryImportState.hasReport)
        XCTAssertNil(try files.stamp(at: "Imported/a.md"))
        XCTAssertTrue(environment.libraryImportState.canImport)
    }

    func testVanishedEntryIsTypedSkipAndEnumerationFailureHasReport() throws {
        let gone = try source("Folder/gone.md", "Gone")
        let kept = try source("Folder/kept.md", "Kept")
        compose(sourceFactory: { LinuxImportSourceReader(inspectEntry: {
            if $0 == "gone.md" { try? FileManager.default.removeItem(at: gone) }
        }) })
        let window = try openLibrary()
        XCTAssertTrue(environment.libraryImportState.importURLs([kept.deletingLastPathComponent()]))
        finishImport()
        let state = environment.libraryImportState
        XCTAssertEqual(state.createdCount, 1)
        XCTAssertEqual(state.files.first { $0.sourcePath == gone.path }?.outcome, .skipped(.source(.notFound)))
        XCTAssertEqual(try files.read(at: "Imported/kept.md"), Data("Kept".utf8))
        // Classify a real folder, remove it, then execute Core enumeration.
        let folder = kept.deletingLastPathComponent()
        XCTAssertTrue(state.importURLs([folder]))
        work.runAll()
        drain()
        try FileManager.default.removeItem(at: folder)
        finishImport()
        XCTAssertEqual(state.reports.first?.report.failure, .source(.notFound))
        XCTAssertTrue(labels(try settingsWidget("library-import-report", in: window)).contains { $0.contains("Import failed:") })
    }

    func testUnreadableSubdirectoryIsTypedSkipWhileValidSiblingImports() throws {
        let sibling = try source("Folder/kept.md", "Kept")
        _ = try source("Folder/blocked/nested.md", "Blocked")
        compose(sourceFactory: {
            LinuxImportSourceReader(openDirectory: { parent, name in
                if name == "blocked" { errno = EACCES; return -1 }
                return Glibc.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            })
        })
        let window = try openLibrary()
        let state = environment.libraryImportState
        XCTAssertTrue(state.importURLs([sibling.deletingLastPathComponent()]))
        finishImport()
        XCTAssertNil(state.reports.first?.report.failure)
        XCTAssertEqual(state.createdCount, 1)
        XCTAssertEqual(state.skippedCount, 1)
        XCTAssertEqual(state.files.first { $0.sourcePath.hasSuffix("/blocked") }?.outcome, .skipped(.notRegularFile))
        XCTAssertEqual(try files.read(at: "Imported/kept.md"), Data("Kept".utf8))
        XCTAssertTrue(labels(try settingsWidget("library-import-report", in: window)).contains(LinuxImportStrings.skipped(.notRegularFile)))
    }

    func testCloseCancelsChooserAndRemoteSelectionsCannotCreateFiles() throws {
        let window = try openLibrary()
        try click("library-import", in: window)
        let reply = try XCTUnwrap(chooser.requests.last?.done)
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(window) == 0 })
        XCTAssertGreaterThan(chooser.cancelCount, 0)
        reply([try source("late.md", "Late")])
        drainWork()
        XCTAssertFalse(environment.libraryImportState.hasReport)
        XCTAssertEqual(try openLibrary(), window)
        XCTAssertFalse(try drop([try XCTUnwrap(URL(string: "https://example.invalid/prompt.md"))], onto: window))
        XCTAssertEqual(environment.libraryImportState.message, LinuxImportStrings.fileURLsOnly)
        // GIO canonicalizes file URIs before a GdkFileList reaches GTK. Check
        // an uncanonicalized chooser/seam URL at the common selection intent.
        XCTAssertFalse(environment.libraryImportState.importURLs([try XCTUnwrap(URL(string: "file://remote.invalid/etc/remote.md"))]))
        XCTAssertNil(try files.stamp(at: "Imported/late.md"))
    }

    func testOverlongSubtreeIsTypedSkipWhileValidSiblingImports() throws {
        let sibling = try source("Folder/valid.md", "Sibling")
        let folder = sibling.deletingLastPathComponent()
        var deep = folder
        for segment in Array(repeating: String(repeating: "x", count: 200), count: 4)
            + [String(repeating: "y", count: 220)] {
            deep.appendPathComponent(segment)
        }
        XCTAssertEqual(deep.path.utf8.count - folder.path.utf8.count - 1, Limits.maxPathBytes)
        // The reader reports the pruned subtree; give that node an eligible
        // suffix so Core checks its Imported/ destination against the local cap.
        deep.appendPathComponent(String(repeating: "z", count: 252) + ".md")
        XCTAssertGreaterThan("Imported/".utf8.count + deep.path.utf8.count - folder.path.utf8.count - 1,
                             Limits.maxRootedPathBytes)
        try XCTSkipIf(deep.appendingPathComponent("deep.md").path.utf8.count >= Int(PATH_MAX),
                      "The overlong Core path fixture exceeds this host's absolute path limit")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("Unimportable path".utf8).write(to: deep.appendingPathComponent("deep.md"))
        _ = try openLibrary()
        XCTAssertTrue(environment.libraryImportState.importURLs([folder]))
        finishImport()
        let state = environment.libraryImportState
        XCTAssertNil(state.reports.first?.report.failure)
        XCTAssertEqual(state.createdCount, 1)
        XCTAssertEqual(state.skippedCount, 1)
        XCTAssertTrue(state.files.contains { $0.outcome == .skipped(.invalidPath) })
        XCTAssertEqual(try files.read(at: "Imported/valid.md"), Data("Sibling".utf8))
    }

    private func compose(sourceFactory: @escaping () -> LinuxImportSourceReader = { LinuxImportSourceReader() }) {
        environment?.shutdown()
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            importChooser: chooser, importSourceFactory: sourceFactory, backgroundWork: work)
    }

    private func source(_ path: String, _ text: String) throws -> URL {
        let root = tools.directory.appendingPathComponent("Sources")
        let sources = try RootedFileStore(root: root)
        try sources.write(Data(text.utf8), at: path)
        return root.appendingPathComponent(path)
    }

    private func openLibrary() throws -> GTK.Widget {
        environment.showLibrary()
        XCTAssertTrue(GTKTestSupport.spin { self.libraryWindow.map { gtk_widget_get_visible($0) != 0 } == true })
        drain()
        return try XCTUnwrap(libraryWindow)
    }

    private var libraryWindow: GTK.Widget? {
        var node = gtk_application_get_windows(application)
        while let current = node {
            if let data = current.pointee.data {
                let window = data.assumingMemoryBound(to: GtkWindow.self)
                if gtk_window_get_title(window).map({ String(cString: $0) }) == LinuxStrings.library { return mp_window_widget(window) }
            }
            node = current.pointee.next
        }
        return nil
    }

    private func click(_ name: String, in window: GTK.Widget) throws {
        let requests = chooser.requests.count
        if name == "library-import" || name == "library-import-folder" {
            g_action_group_activate_action(mp_window_action_group(window),
                name == "library-import" ? "import-files" : "import-folder", nil)
        }
        XCTAssertNotEqual(gtk_widget_activate(try settingsWidget(name, in: window)), 0)
        if name == "library-import" || name == "library-import-folder" {
            XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count > requests })
        } else if name == "library-import-dismiss" {
            XCTAssertTrue(GTKTestSupport.spin { !self.environment.libraryImportState.hasReport })
        }
        drain()
    }

    private func finishImport() {
        XCTAssertTrue(GTKTestSupport.spin {
            self.work.runAll()
            return !self.environment.libraryImportState.isBusy && !self.environment.libraryImportState.isChoosing
        })
        drain()
    }

    private func drainWork() {
        for _ in 0..<10 { work.runAll(); drain() }
    }

    private func drain() { for _ in 0..<20 { _ = g_main_context_iteration(nil, 0) } }

    private func labels(_ widget: GTK.Widget) -> [String] {
        var values: [String] = []
        if g_type_check_instance_is_a(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self), gtk_label_get_type()) != 0 {
            values.append(String(cString: gtk_label_get_text(mp_label(widget))))
        }
        var child = gtk_widget_get_first_child(widget)
        while let current = child { values += labels(current); child = gtk_widget_get_next_sibling(current) }
        return values
    }

    private func drop(_ urls: [URL], onto window: GTK.Widget) throws -> Bool {
        let list = try settingsWidget("library-list", in: window)
        let controllers = try XCTUnwrap(gtk_widget_observe_controllers(list))
        defer { g_object_unref(UnsafeMutableRawPointer(controllers)) }
        var target: UnsafeMutableRawPointer?
        for index in 0..<g_list_model_get_n_items(controllers) {
            guard let item = g_list_model_get_item(controllers, index) else { continue }
            if g_type_check_instance_is_a(item.assumingMemoryBound(to: GTypeInstance.self), gtk_drop_target_get_type()) != 0 {
                var count: gsize = 0
                if let types = gtk_drop_target_get_gtypes(OpaquePointer(item), &count),
                   UnsafeBufferPointer(start: types, count: Int(count)).contains(gdk_file_list_get_type()) {
                    target = item
                    break
                }
            }
            g_object_unref(item)
        }
        let object = try XCTUnwrap(target)
        defer { g_object_unref(object) }
        var files = urls.map { g_file_new_for_uri($0.absoluteString) }
        defer { files.compactMap { $0 }.forEach { g_object_unref(UnsafeMutableRawPointer($0)) } }
        let fileList = try XCTUnwrap(gdk_file_list_new_from_array(&files, gsize(files.count)))
        var value = GValue()
        g_value_init(&value, gdk_file_list_get_type())
        g_value_take_boxed(&value, UnsafeMutableRawPointer(fileList))
        defer { g_value_unset(&value) }
        var arguments = [GValue](repeating: GValue(), count: 4)
        g_value_init(&arguments[0], gtk_drop_target_get_type())
        g_value_set_object(&arguments[0], object)
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
}

private final class ImportTestChooser: LinuxImportChoosing {
    struct Request {
        let mode: LinuxImportSelectionMode
        let done: ([URL]) -> Void
    }
    private(set) var requests: [Request] = []
    private(set) var cancelCount = 0
    func choose(parent: GTK.Widget, mode: LinuxImportSelectionMode, done: @escaping ([URL]) -> Void) {
        requests.append(Request(mode: mode, done: done))
    }
    func cancel() { cancelCount += 1 }
}

private final class ImportTestWork: BackgroundWork {
    private let lock = NSLock()
    private var work: [() -> Void] = []
    func run(_ work: @escaping () -> Void) {
        lock.lock(); self.work.append(work); lock.unlock()
    }
    func runAll(file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<10_000 {
            guard let next = take() else { return }
            next()
        }
        lock.lock()
        let isEmpty = work.isEmpty
        work.removeAll()
        lock.unlock()
        XCTAssertTrue(isEmpty, "Import work exceeded 10,000 tasks; check for a re-enqueue loop", file: file, line: line)
    }

    private func take() -> (() -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return work.isEmpty ? nil : work.removeFirst()
    }
}
#endif
