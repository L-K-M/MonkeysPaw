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

    override func setUpWithError() throws {
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

    func testChooserConfigurationSupportsFilesFoldersAndAllFormats() {
        let panel = MacImportChooser.makePanel()
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.resolvesAliases)
        XCTAssertFalse(panel.allowsOtherFileTypes)
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
        presentation.setFilter("Does not match")
        imports.open("work/deep/flat.md")
        let decision = try XCTUnwrap(presentation.editorState.pendingDecision)
        XCTAssertEqual(presentation.editorState.source, "Unsaved draft")
        presentation.editor.resolveDecision(.discard, id: decision.id)
        work.drain()
        XCTAssertEqual(presentation.editorState.prompt?.relativePath, "work/deep/flat.md")
        XCTAssertEqual(presentation.editorState.source, "Body")
        XCTAssertEqual(presentation.snapshot.filter, "")
        XCTAssertEqual(presentation.snapshot.selectedSection, .all)
    }

    func testDropLoadsFileURLsAndKeepsPartialFailuresVisible() throws {
        let flat = try source("space name.md")
        start()
        let imports = try imports()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in
            done(flat.dataRepresentation, nil)
            return nil
        }
        let broken = NSItemProvider()
        broken.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in
            done(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        let decoded = expectation(description: "Drop decoding enqueues preparation")
        work.onEnqueue = { decoded.fulfill() }
        XCTAssertTrue(imports.acceptDrop([provider, broken]))
        XCTAssertFalse(imports.acceptDrop([provider]))
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

    func testAppMenuAndUnavailableLibraryGateImport() throws {
        let flat = try source("flat.md")
        start()
        delegate.installMainMenu()
        let item = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu?.items.first { $0.title == ImportStrings.action })
        let imports = try imports()
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(choices.count, 1)
        XCTAssertFalse(item.isEnabled)
        try XCTUnwrap(choices.last).done([flat])
        XCTAssertFalse(item.isEnabled)
        work.drain()
        XCTAssertTrue(item.isEnabled)
        try XCTUnwrap(watchers.last).emit(.rootUnavailable(.notFound))
        XCTAssertFalse(imports.canImport)
        XCTAssertFalse(item.isEnabled)
        XCTAssertFalse(imports.importURLs([flat]))
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
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        work.drain()
        XCTAssertFalse(old.canImport)
        XCTAssertTrue(old.files.isEmpty)
        model.importFiles(at: [flat.path])
        work.drain()
        XCTAssertThrowsError(try files.read(at: "Imported/flat.md"))
        XCTAssertThrowsError(try otherFiles.read(at: "Imported/flat.md"))
        let current = try imports()
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
    private var pending: [() -> Void] = []
    var onEnqueue: (() -> Void)?
    func run(_ work: @escaping () -> Void) { pending.append(work); onEnqueue?() }
    func runNext() { if !pending.isEmpty { pending.removeFirst()() } }
    func drain() {
        for _ in 0..<100 {
            guard !pending.isEmpty else { return }
            runNext()
        }
        XCTFail("Import worker did not settle in 100 jobs")
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
