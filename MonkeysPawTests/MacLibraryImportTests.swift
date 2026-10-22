import AppKit
import Combine
import MonkeysPawCore
import UniformTypeIdentifiers
import XCTest
@testable import MonkeysPaw

/// Hosted tests use chooser replies, worker jobs and the real drop intent.
/// They do not inspect accessibility trees or wait for a key window.
final class MacLibraryImportTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var files: RootedFileStore!
    private var delegate: AppDelegate!
    private let work = MacImportTestWork()
    private var watchers: [MacImportTestWatcher] = []
    private var choices: [MacImportTestChoice] = []
    private var originalMainMenu: NSMenu?

    override func setUpWithError() throws {
        originalMainMenu = NSApp.mainMenu
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library")
        data = directory.appendingPathComponent("data")
        files = try RootedFileStore(root: root)
        try files.createRoot()
    }

    override func tearDown() {
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        work.onEnqueue = nil
        work.drain()
        delegate = nil
        NSApp.mainMenu = originalMainMenu
        originalMainMenu = nil
        choices = []
        watchers = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func start(inlineSelection: [URL]? = nil) {
        delegate = AppDelegate(libraryRoot: root, dataRoot: data, backgroundWork: work,
            editorDialog: { _, _, _ in {} }, importChooser: { [weak self] _, done in
                let choice = MacImportTestChoice(done: done)
                self?.choices.append(choice)
                if let inlineSelection { done(inlineSelection) }
                return { choice.cancelled = true }
            }, setActivationPolicy: { _ in }, activateApplication: {},
            makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in false }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, scheduler: MacImportInlineScheduler(), makeFileWatcher: { [weak self] _, _ in
                let watcher = MacImportTestWatcher()
                self?.watchers.append(watcher)
                return watcher
            })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.showLibrary()
    }

    private func imports() throws -> LibraryImportViewState { try XCTUnwrap(delegate.libraryWindow?.presentation.imports) }
    private func source(_ name: String, _ text: String = "Body") throws -> URL {
        try source(name, bytes: Data(text.utf8))
    }
    private func source(_ name: String, bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent("sources/" + name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }
    private func publish(_ imports: LibraryImportViewState) throws {
        let watcher = try XCTUnwrap(watchers.last)
        for file in imports.files {
            if case .created(let path) = file.outcome {
                watcher.emit(.file(FileStoreEvent(relativePath: path, kind: .created)))
            }
        }
    }

    func testNativeChooserOffersDestinationBeforeStartingTheFirstImport() throws {
        var selected: [String] = []
        let panel = MacImportChooser.makePanel(destinations: ["Imported", "work/deep"], destination: "Imported",
            selectDestination: { selected.append($0) })
        let popup = try XCTUnwrap(panel.accessoryView?.subviews.compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertTrue(panel.isAccessoryViewDisclosed)
        XCTAssertEqual(popup.itemTitles, ["Imported/", "work/deep/"])
        popup.selectItem(at: 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(popup.action), to: popup.target, from: popup))
        XCTAssertEqual(selected, ["work/deep"])
    }

    func testChooserConfigurationSupportsFilesFoldersAndAllFormats() {
        let panel = MacImportChooser.makePanel()
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.resolvesAliases)
        XCTAssertFalse(panel.allowsOtherFileTypes)
        XCTAssertTrue(panel.allowedContentTypes.contains(.folder))
        for ext in ["md", "prompt", "prompty"] {
            XCTAssertTrue(panel.allowedContentTypes.contains { $0 == UTType(filenameExtension: ext) })
        }
    }

    func testMixedChooserSelectionProgressReportsAndExclusivePublication() throws {
        try files.write(Data("Existing".utf8), at: "Imported/flat.md")
        let flat = try source("flat.md", "Exact native bytes\n")
        _ = try source("folder/nested/a.prompt", "---\n# Source styling\nmodel: {name: example}\ninput:\n  schema:\n    name: string\n    count: integer\n---\nHello {{name}} {{#if name}}yes{{/if}}")
        _ = try source("folder/nested/b.prompty", "---\ninputs:\n  name: {type: string}\nsample: {name: Ada}\n---\nHello {{name}}")
        _ = try source("folder/plain.md", "Folder body")
        _ = try source("folder/not-utf8.md", bytes: Data([0xff]))
        _ = try source("folder/large.md", bytes: Data(repeating: 65, count: Limits.importFileCapBytes + 1))
        _ = try source("folder/notes.txt")
        let folder = directory.appendingPathComponent("sources/folder")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.md"), withDestinationURL: flat)
        start()
        let imports = try imports()
        imports.choose()
        XCTAssertTrue(imports.isChoosing)
        XCTAssertFalse(imports.canImport)
        imports.choose()
        XCTAssertEqual(choices.count, 1)
        try XCTUnwrap(choices.last).done([flat, folder])
        XCTAssertTrue(imports.isBusy)
        XCTAssertEqual(imports.progress, .enumerating)
        XCTAssertFalse(imports.importURLs([flat]))
        imports.dismissReport()
        work.runNext() // Classify the mixed selection, off the UI thread.
        XCTAssertEqual(imports.requestCount, 2)
        XCTAssertEqual(imports.requestNumber, 1)
        var progress: [ImportProgress] = []
        let observation = imports.$progress.compactMap { $0 }.sink { progress.append($0) }
        work.runNext() // The file group completes; the folder still keeps the batch busy.
        XCTAssertTrue(imports.isBusy)
        XCTAssertEqual(imports.requestNumber, 2)
        XCTAssertFalse(imports.canImport)
        work.drain()
        withExtendedLifetime(observation) {}
        XCTAssertFalse(imports.isBusy)
        XCTAssertTrue(imports.hasReport)
        XCTAssertTrue(imports.canImport)
        XCTAssertTrue(progress.contains(.importing(completed: 1, total: 1)))
        XCTAssertTrue(progress.contains(.importing(completed: 7, total: 7)))
        XCTAssertEqual(imports.createdCount, 4)
        XCTAssertEqual(imports.skippedCount, 4)
        XCTAssertEqual(try files.read(at: "Imported/flat.md"), Data("Existing".utf8))
        XCTAssertEqual(try files.read(at: "Imported/flat 2.md"), Data("Exact native bytes\n".utf8))
        XCTAssertEqual(try files.read(at: "Imported/plain.md"), Data("Folder body".utf8))
        XCTAssertEqual(try Data(contentsOf: flat), Data("Exact native bytes\n".utf8))
        XCTAssertEqual(imports.files.map(\.sourcePath), imports.files.map(\.sourcePath).sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        })
        for reason: ImportSkipReason in [.invalidUTF8, .fileTooLarge, .symbolicLink, .unsupportedExtension] {
            XCTAssertTrue(imports.files.contains { $0.outcome == .skipped(reason) })
            XCTAssertFalse(ImportStrings.reason(reason).isEmpty)
        }
        let converted = try XCTUnwrap(imports.files.first { $0.sourcePath.hasSuffix("a.prompt") })
        XCTAssertEqual(converted.outcome, .created(path: "Imported/nested/a.md"))
        XCTAssertTrue(converted.mapping.preservedKeys.contains("model"))
        XCTAssertTrue(converted.mapping.dropped.contains(.frontMatterPresentation))
        XCTAssertTrue(converted.mapping.warnings.contains { if case .unsupportedInput = $0 { return true }; return false })
        XCTAssertTrue(converted.mapping.warnings.contains { if case .unsupportedTemplate = $0 { return true }; return false })
        XCTAssertEqual(converted.mapping.mappings.map(\.fieldName), ["name"])
        for warning in converted.mapping.warnings { XCTAssertFalse(ImportStrings.warning(warning).isEmpty) }
        let prompty = try XCTUnwrap(imports.files.first { $0.sourcePath.hasSuffix("b.prompty") })
        XCTAssertEqual(prompty.mapping.mappings.first?.defaultSource, "sample.name")
        imports.dismissReport()
        XCTAssertFalse(imports.hasReport)
        XCTAssertTrue(imports.files.isEmpty)
    }

    func testDestinationAndOpeningReportUseWatcherAndEditorGuard() throws {
        try files.write(Data("Existing".utf8), at: "work/deep/existing.md")
        let flat = try source("flat.md")
        start(inlineSelection: [flat])
        let imports = try imports()
        XCTAssertEqual(imports.destination, "Imported")
        XCTAssertTrue(imports.destinations.contains("work/deep"))
        imports.selectDestination("work/deep")
        imports.selectDestination("../outside")
        XCTAssertEqual(imports.destination, "work/deep")
        imports.choose()
        XCTAssertFalse(imports.isChoosing)
        XCTAssertTrue(imports.isBusy)
        imports.selectDestination("Imported")
        XCTAssertEqual(imports.destination, "work/deep")
        work.drain()
        XCTAssertEqual(imports.files.first?.outcome, .created(path: "work/deep/flat.md"))
        let presentation = try XCTUnwrap(delegate.libraryWindow?.presentation)
        XCTAssertFalse(presentation.snapshot.rows.contains { $0.relativePath == "work/deep/flat.md" })
        imports.open("work/deep/flat.md")
        XCTAssertEqual(imports.selectionMessage, ImportStrings.waitingForRefresh)
        try publish(imports)
        presentation.selectPath("work/deep/existing.md")
        work.drain()
        presentation.edit("Unsaved draft")
        let search = try LibrarySearchTestSupport.type("Does not match", in: XCTUnwrap(delegate.libraryWindow))
        imports.open("work/deep/flat.md")
        let decision = try XCTUnwrap(presentation.editorState.pendingDecision)
        XCTAssertEqual(presentation.editorState.source, "Unsaved draft")
        presentation.editor.resolveDecision(.discard, id: decision.id)
        work.drain()
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "work/deep/flat.md")
        XCTAssertEqual(presentation.editorState.source, "Body")
        XCTAssertEqual(presentation.snapshot.filter, "")
        XCTAssertEqual(presentation.snapshot.selectedSection, .all)
        XCTAssertEqual(search.field.stringValue, "")
        XCTAssertEqual(presentation.snapshot.selection, presentation.editorState.prompt)
    }

    func testUnchangedBrowserDestinationsDoNotRepublish() throws {
        try files.write(Data("Existing".utf8), at: "work/existing.md")
        start()
        let imports = try imports()
        let presentation = try XCTUnwrap(delegate.libraryWindow?.presentation)
        var changes = 0
        let observation = imports.objectWillChange.sink { changes += 1 }
        imports.updateDestinations(presentation.snapshot.sections)
        presentation.setFilter("Does not match")
        presentation.selectSection(.favourites)
        XCTAssertEqual(changes, 0)
        withExtendedLifetime(observation) {}
    }

    func testDropLoadsFileURLsAndKeepsPartialFailuresVisible() throws {
        let flat = try source("space name.md")
        start()
        let imports = try imports()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in
            DispatchQueue.global().async { done(flat.dataRepresentation, nil) }
            return nil
        }
        let broken = NSItemProvider()
        broken.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in
            DispatchQueue.global().async { done(nil, CocoaError(.fileReadUnknown)) }
            return nil
        }
        let decoded = expectation(description: "Drop decoding enqueues preparation")
        work.onEnqueue = {
            XCTAssertTrue(Thread.isMainThread)
            decoded.fulfill()
        }
        XCTAssertTrue(imports.acceptDrop([provider, broken]))
        XCTAssertFalse(imports.acceptDrop([provider]))
        // Preparation is enqueued only after every provider completion has
        // reached MainThread, including the failed representation.
        wait(for: [decoded], timeout: 5)
        work.onEnqueue = nil
        work.drain()
        XCTAssertEqual(imports.createdCount, 1)
        XCTAssertEqual(imports.selectionMessage, ImportStrings.dropReadFailed)
        XCTAssertEqual(try files.read(at: "Imported/space name.md"), Data("Body".utf8))
        imports.dismissReport()
        XCTAssertNil(imports.selectionMessage)
        XCTAssertFalse(imports.importURLs([try XCTUnwrap(URL(string: "https://example.com/prompt.md"))]))
        XCTAssertEqual(imports.selectionMessage, ImportStrings.fileURLsOnly)
    }

    func testFileMenuAndUnavailableLibraryGateImport() throws {
        let flat = try source("flat.md")
        start()
        delegate.installMainMenu()
        let menu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == LibraryCommandStrings.fileMenu }?.submenu)
        let item = try XCTUnwrap(menu.items.first { $0.title == ImportStrings.action })
        let imports = try imports()
        XCTAssertTrue(delegate.validateMenuItem(item))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: delegate, from: item))
        XCTAssertEqual(choices.count, 1)
        XCTAssertFalse(delegate.validateMenuItem(item))
        try XCTUnwrap(choices.last).done([flat])
        XCTAssertFalse(delegate.validateMenuItem(item))
        work.drain()
        XCTAssertTrue(delegate.validateMenuItem(item))
        try XCTUnwrap(watchers.last).emit(.rootUnavailable(.notFound))
        XCTAssertFalse(imports.canImport)
        XCTAssertFalse(delegate.validateMenuItem(item))
        XCTAssertFalse(imports.importURLs([flat]))
        XCTAssertTrue(imports.hasReport)
    }

    func testLibrarySwitchRetiresQueuedWorkAndLateChooserReplies() throws {
        let flat = try source("flat.md")
        let other = directory.appendingPathComponent("other-library")
        let otherFiles = try RootedFileStore(root: other)
        try otherFiles.createRoot()
        start()
        let old = try imports()
        let model = try XCTUnwrap(delegate.importModel)
        XCTAssertTrue(old.importURLs([flat]))
        work.runNext()
        XCTAssertTrue(model.state.isImporting)
        XCTAssertEqual(delegate.switchLibrary(to: other), .syncBusy)
        // Sync composition drains the retired import before replacing its graph.
        let deadline = Date().addingTimeInterval(5)
        while delegate.libraryDirectory != other, Date() < deadline {
            work.drain()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(delegate.libraryDirectory, other)
        XCTAssertTrue(delegate.pickerModel?.libraryAvailable == true)
        work.drain()
        XCTAssertFalse(old.canImport)
        XCTAssertTrue(old.files.isEmpty)
        model.importFiles(at: [flat.path])
        work.drain()
        XCTAssertThrowsError(try files.read(at: "Imported/flat.md"))
        XCTAssertThrowsError(try otherFiles.read(at: "Imported/flat.md"))
        let current = try imports()
        XCTAssertFalse(current === old)
        XCTAssertFalse(delegate.importModel === model)
        XCTAssertTrue(current.importURLs([flat]))
        work.drain()
        XCTAssertEqual(current.createdCount, 1)
        XCTAssertTrue(current.hasReport)
        XCTAssertTrue(current.canImport)
        XCTAssertEqual(try otherFiles.read(at: "Imported/flat.md"), Data("Body".utf8))
        current.choose()
        let late = try XCTUnwrap(choices.last)
        XCTAssertEqual(delegate.switchLibrary(to: nil), .switched)
        XCTAssertTrue(late.cancelled)
        late.done([flat])
        work.drain()
        XCTAssertThrowsError(try files.read(at: "Imported/flat.md"))
        let replacement = try imports()
        XCTAssertEqual(replacement.destination, "Imported")
        XCTAssertTrue(replacement.importURLs([flat]))
        work.drain()
        XCTAssertEqual(replacement.createdCount, 1)
    }

    func testLibrarySwitchAfterCompletedImportKeepsReplacementCallbacks() throws {
        try files.write(Data("Existing".utf8), at: "work/existing.md")
        let flat = try source("flat.md")
        let second = try source("second.md")
        let other = directory.appendingPathComponent("other-library")
        let otherFiles = try RootedFileStore(root: other)
        try otherFiles.createRoot()
        start()
        let old = try imports()
        let oldModel = try XCTUnwrap(delegate.importModel)
        old.selectDestination("work")
        XCTAssertTrue(old.importURLs([flat]))
        work.drain()
        XCTAssertEqual(old.createdCount, 1)
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        let current = try imports()
        XCTAssertFalse(current === old)
        XCTAssertFalse(delegate.importModel === oldModel)
        XCTAssertFalse(old.hasReport)
        XCTAssertFalse(old.canImport)
        XCTAssertEqual(current.destination, "Imported")
        XCTAssertTrue(current.files.isEmpty)
        oldModel.importFiles(at: [second.path])
        XCTAssertTrue(current.importURLs([second]))
        work.drain()
        XCTAssertEqual(current.createdCount, 1)
        XCTAssertTrue(current.hasReport)
        XCTAssertTrue(current.canImport)
        XCTAssertEqual(try files.read(at: "work/flat.md"), Data("Body".utf8))
        XCTAssertThrowsError(try files.read(at: "Imported/second.md"))
        XCTAssertEqual(try otherFiles.read(at: "Imported/second.md"), Data("Body".utf8))
    }

    func testLibraryLossRetiresPendingImportAndPreservesCompletedReport() throws {
        let flat = try source("flat.md")
        _ = try source("folder/nested.md")
        let folder = directory.appendingPathComponent("sources/folder")
        start()
        let imports = try imports()
        XCTAssertTrue(imports.importURLs([flat, folder]))
        work.runNext() // Prepare the mixed selection.
        work.runNext() // Complete the file; the folder job is still queued.
        XCTAssertTrue(imports.isBusy)
        XCTAssertEqual(imports.createdCount, 1)
        try XCTUnwrap(watchers.last).emit(.rootUnavailable(.notFound))
        work.drain()
        XCTAssertFalse(imports.isBusy)
        XCTAssertFalse(imports.canImport)
        XCTAssertTrue(imports.hasReport)
        XCTAssertEqual(imports.createdCount, 1)
        XCTAssertEqual(imports.selectionMessage, ImportStrings.libraryLost)
        XCTAssertEqual(try files.read(at: "Imported/flat.md"), Data("Body".utf8))
        XCTAssertThrowsError(try files.read(at: "Imported/nested.md"))
        imports.dismissReport()
        XCTAssertFalse(imports.hasReport)
        XCTAssertNil(imports.selectionMessage)
    }

    func testCloseDuringImportKeepsBatchAndReportForReopen() throws {
        let flat = try source("flat.md")
        _ = try source("folder/nested.md")
        let folder = directory.appendingPathComponent("sources/folder")
        start()
        let imports = try imports()
        let controller = try XCTUnwrap(delegate.libraryWindow)
        XCTAssertTrue(imports.importURLs([flat, folder]))
        work.runNext()
        work.runNext()
        XCTAssertTrue(imports.isBusy)
        XCTAssertEqual(imports.createdCount, 1)
        controller.requestClose()
        XCTAssertFalse(controller.window?.isVisible == true)
        XCTAssertTrue(imports.isBusy)
        work.drain()
        XCTAssertTrue(imports.hasReport)
        XCTAssertEqual(imports.createdCount, 2)
        XCTAssertEqual(imports.reports.count, 2)
        delegate.showLibrary()
        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertTrue(try self.imports() === imports)
        XCTAssertTrue(imports.hasReport)
        XCTAssertEqual(imports.createdCount, 2)
        XCTAssertEqual(try files.read(at: "Imported/flat.md"), Data("Body".utf8))
        XCTAssertEqual(try files.read(at: "Imported/nested.md"), Data("Body".utf8))
    }

    func testCloseCancelsChooserAndRejectsItsLateReply() throws {
        let flat = try source("flat.md")
        start()
        let imports = try imports()
        imports.choose()
        let choice = try XCTUnwrap(choices.last)
        delegate.libraryWindow?.requestClose()
        XCTAssertTrue(choice.cancelled)
        XCTAssertFalse(imports.isChoosing)
        choice.done([flat])
        work.drain()
        XCTAssertThrowsError(try files.read(at: "Imported/flat.md"))
    }
}

private final class MacImportTestChoice {
    let done: ([URL]) -> Void
    var cancelled = false
    init(done: @escaping ([URL]) -> Void) { self.done = done }
}

private final class MacImportTestWork: BackgroundWork {
    private let lock = NSLock()
    private var pending: [() -> Void] = []
    var onEnqueue: (() -> Void)?
    func run(_ work: @escaping () -> Void) {
        lock.lock()
        pending.append(work)
        lock.unlock()
        DispatchMainThread().run { [weak self] in self?.onEnqueue?() }
    }
    func runNext() {
        guard Thread.isMainThread else { XCTFail("Import test work must run on main"); return }
        takeNext()?()
    }
    func drain() {
        guard Thread.isMainThread else { XCTFail("Import test work must drain on main"); return }
        for _ in 0..<100 {
            guard let next = takeNext() else { return }
            next()
        }
        XCTFail("Import worker did not settle in 100 jobs")
    }
    private func takeNext() -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }
}

private struct MacImportInlineScheduler: MonkeysPawCore.Scheduler {
    func after(_ delay: Duration, _ work: @escaping () -> Void) { work() }
}

private final class MacImportTestWatcher: FileStoreWatcher {
    private var onEvent: (@Sendable (FileStoreWatchEvent) -> Void)?
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws { self.onEvent = onEvent }
    func stop() {} // Retain callbacks to exercise generation guards.
    func emit(_ event: FileStoreWatchEvent) { onEvent?(event) }
}
