import AppKit
import Combine
import Darwin
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

/// Composition tests use temporary config/data/default roots and fake watcher
/// events. Explicit UI tests reuse the real panel without external activation.
final class MacLibrarySwitchTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var delegate: AppDelegate!
    private var panel: PanelController!
    private var watchers: [SwitchWatcher] = []
    private var launched: [URL] = []
    private var originalWindows: Set<ObjectIdentifier> = []

    override func setUpWithError() throws {
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("default", isDirectory: true)
        data = directory.appendingPathComponent("data", isDirectory: true)
    }

    override func tearDown() {
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate?.pickerModel?.dismiss()
        panel?.hide()
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        delegate = nil
        panel = nil
        watchers = []
        launched = []
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func start(legacyFirstRun: LegacyFirstRun = .setupNotPresented,
                       recordLegacySetup: @escaping () -> Void = {},
                       scheduler: MonkeysPawCore.Scheduler = SwitchScheduler(),
                       focusSource: WorkspaceFocusTracker.Source? = nil,
                       editorDialog: @escaping LibraryWindowController.DialogPresenter = LibraryWindowController.presentEditorDialog,
                       onWatcherStart: @escaping (URL) throws -> Void = { _ in }) throws -> PickerModel {
        delegate = AppDelegate(libraryRoot: root, dataRoot: data, legacyFirstRun: legacyFirstRun,
            recordLegacySetup: recordLegacySetup, launchURI: { [weak self] in self?.launched.append($0) },
            editorDialog: editorDialog,
            makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: focusSource ?? .init(frontmost: { nil }, activate: { _ in
                    XCTFail("Library switch tests must not activate an external app")
                    return false
                }), mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, scheduler: scheduler, makePanelController: { [weak self] main, scheduler, log in
                let panel = PanelController(mainThread: main, scheduler: scheduler, log: log)
                self?.panel = panel
                return panel
            }, makeFileWatcher: { [weak self] root, _ in
                let raw = SwitchWatcher { try onWatcherStart(root) }
                self?.watchers.append(raw)
                return raw
            })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        return try XCTUnwrap(delegate.pickerModel)
    }

    private func files(at root: URL) throws -> RootedFileStore {
        let files = try RootedFileStore(root: root)
        try files.createRoot()
        return files
    }

    private func otherLibrary(_ body: String = "Beta") throws -> URL {
        let other = directory.appendingPathComponent("chosen", isDirectory: true)
        try files(at: other).write(Data(body.utf8), at: "beta.md")
        return other
    }

    func testSwitchReplacesResultsAndArmsWatcherBeforeRebuild() throws {
        try files(at: root).write(Data("Alpha".utf8), at: "alpha.md")
        let other = try otherLibrary()
        let old = try start(onWatcherStart: { watched in
            if watched == other {
                try RootedFileStore(root: other).write(Data("During start".utf8), at: "during-start.md")
            }
        })
        XCTAssertEqual(old.results.map(\.relativePath), ["alpha.md"])
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        let current = try XCTUnwrap(delegate.pickerModel)
        XCTAssertFalse(current === old)
        XCTAssertEqual(current.results.map(\.relativePath), ["beta.md", "during-start.md"])
        XCTAssertEqual(delegate.libraryDirectory, other)
        XCTAssertTrue(watchers[0].stopped)
        XCTAssertNil(old.onChange)
        XCTAssertEqual(delegate.settingsModel?.libraryFolderPath, other.path)
    }

    func testSymlinkedDefaultLibraryStillLoadsAndCanBeReselected() throws {
        // Users may link the default folder into a synced directory; only a
        // chosen folder must not be a symlink itself.
        let synced = directory.appendingPathComponent("synced", isDirectory: true)
        try files(at: synced).write(Data("Synced".utf8), at: "synced.md")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: synced)
        let picker = try start()
        XCTAssertTrue(picker.libraryAvailable)
        XCTAssertEqual(picker.results.map(\.relativePath), ["synced.md"])

        XCTAssertEqual(delegate.switchLibrary(to: nil), .switched)
        let current = try XCTUnwrap(delegate.pickerModel)
        XCTAssertTrue(current.libraryAvailable)
        XCTAssertEqual(current.results.map(\.relativePath), ["synced.md"])
    }

    func testInvalidTargetsKeepGraphAndSettings() throws {
        try files(at: root).write(Data("Alpha".utf8), at: "alpha.md")
        let old = try start()
        let settings = try XCTUnwrap(delegate.settingsModel).state
        let missing = directory.appendingPathComponent("missing")
        let regular = directory.appendingPathComponent("regular")
        try Data("Not a directory".utf8).write(to: regular)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let cases: [(URL, FileStoreError)] = [
            (missing, .notFound), (regular, .invalidRoot), (link, .outsideRoot),
            (try XCTUnwrap(URL(string: "https://example.invalid/library")), .invalidRoot),
            (URL(fileURLWithPath: "/"), .invalidRoot)
        ]
        for (target, error) in cases {
            XCTAssertEqual(delegate.switchLibrary(to: target), .invalidTarget(error))
            XCTAssertTrue(delegate.pickerModel === old)
            XCTAssertEqual(delegate.libraryDirectory, root)
            XCTAssertEqual(try XCTUnwrap(delegate.settingsModel).state, settings)
            XCTAssertFalse(watchers[0].stopped)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(watchers.count, 1)
    }

    func testUnreadableTargetKeepsGraphAndSettings() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        let other = try otherLibrary()
        let old = try start()
        let settings = try XCTUnwrap(delegate.settingsModel).state
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: other.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: other.path) }
        XCTAssertEqual(delegate.switchLibrary(to: other), .invalidTarget(.ioFailure))
        XCTAssertTrue(delegate.pickerModel === old)
        XCTAssertEqual(try XCTUnwrap(delegate.settingsModel).state, settings)
        XCTAssertFalse(watchers[0].stopped)
    }

    func testDeliveryInFlightRefusesSwitchWithoutDismissing() throws {
        try files(at: root).write(Data("Alpha".utf8), at: "alpha.md")
        let other = try otherLibrary()
        let scheduler = SwitchScheduler()
        scheduler.hold = true
        let picker = try start(scheduler: scheduler)
        picker.open()
        picker.use(mode: .copyOnly)
        XCTAssertEqual(picker.state, .delivering)
        XCTAssertEqual(delegate.switchLibrary(to: other), .deliveryInFlight)
        XCTAssertTrue(delegate.pickerModel === picker)
        XCTAssertEqual(delegate.libraryDirectory, root)
        XCTAssertNil(try XCTUnwrap(delegate.settingsModel).libraryFolderPath)
        XCTAssertFalse(watchers[0].stopped)
        scheduler.drain()
    }

    func testQueuedOldWorkAndLateWatcherEventsAreInert() throws {
        let oldFiles = try files(at: root)
        try oldFiles.write(Data("Alpha".utf8), at: "alpha.md")
        let other = try otherLibrary()
        let old = try start()
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        let onChange = old.onChange
        let onShow = panel.onShow
        let onCancel = panel.onCancel
        let onEscape = panel.onEscape
        let oldWatcher = watchers[0]
        var publications = 0
        let subscription = presentation.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        // DispatchMainThread queues these callbacks while the main thread is
        // still in this test. Switching must invalidate them before it drains.
        DispatchQueue.global().sync {
            oldWatcher.emit(.rootUnavailable(.notFound))
            onChange?()
            self.panel.show()
        }
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        let current = try XCTUnwrap(delegate.pickerModel)
        let afterSwitch = publications
        try oldFiles.write(Data("Late Alpha".utf8), at: "late.md")
        oldWatcher.emit(.file(FileStoreEvent(relativePath: "late.md", kind: .created)))
        onShow?()
        onCancel?()
        onEscape?()
        presentation.setQuery("Should not create a prompt")
        presentation.createNoMatch()
        let drained = expectation(description: "Old main-queue callbacks drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        XCTAssertEqual(publications, afterSwitch)
        XCTAssertEqual(current.results.map(\.relativePath), ["beta.md"])
        XCTAssertTrue(current.libraryAvailable)
        XCTAssertEqual(current.state, .closed)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(launched.isEmpty)
        XCTAssertFalse(try RootedFileStore(root: other).listFiles().contains { $0.relativePath == "Should not create a prompt.md" })
    }

    func testLibraryNewPromptRetiredTitleResponseWritesToNeitherLibrary() throws {
        var titleReply: ((LibraryEditorResponse) -> Void)?
        try start(editorDialog: { _, dialog, reply in
            if case .newPrompt = dialog { titleReply = reply }
            return {}
        })
        delegate.showLibrary()
        let presentation = try XCTUnwrap(delegate.libraryWindow?.presentation)
        presentation.requestNewPrompt()
        let request = try XCTUnwrap(presentation.newPromptRequest)
        let stale = try XCTUnwrap(titleReply)
        let other = try otherLibrary()
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        stale(.createPrompt("Retired title"))
        presentation.resolveNewPrompt(.createPrompt("Retired title"), id: request.id)
        XCTAssertNil(try files(at: root).stamp(at: "Retired title.md"))
        XCTAssertNil(try files(at: other).stamp(at: "Retired title.md"))
        XCTAssertNil(presentation.newPromptRequest)
    }

    func testLibraryNewPromptRetiresQueuedGuardApprovalOnRebind() throws {
        let main = NewPromptSwitchMainThread()
        let dataFiles = try files(at: data)
        let clock = SystemClock()
        func graph(at root: URL) throws -> (browser: LibraryBrowserModel, editor: EditorModel) {
            let library = LibraryService(library: try files(at: root), data: dataFiles, clock: clock, entropy: SystemEntropy())
            let usage = UsageStore(files: dataFiles, clock: clock)
            let index = PromptIndex(service: library, usage: usage, clock: clock)
            try index.rebuild()
            let editing = PromptEditingService(library: library, index: index, work: NewPromptSwitchWork(), main: main)
            let editor = EditorModel(editing: editing, clock: clock, timeZone: { TimeZone.current }, main: main)
            return (LibraryBrowserModel(index: index, usage: usage, favorites: library, main: main, editor: editor), editor)
        }
        try files(at: root).write(Data("Original".utf8), at: "one.md")
        let old = try graph(at: root)
        let otherRoot = try otherLibrary()
        let replacement = try graph(at: otherRoot)
        var creations = 0
        let presentation = LibraryViewState(model: old.browser, editor: old.editor, libraryPath: root.path,
            available: true, mainThread: main, createPrompt: { _, _ in creations += 1; return nil }, revealLibrary: {})
        defer {
            presentation.deactivate()
            old.browser.deactivate(); old.editor.deactivate()
            replacement.browser.deactivate(); replacement.editor.deactivate()
        }
        presentation.didShow()
        presentation.selectPath("one.md")
        presentation.edit("Draft")
        presentation.requestNewPrompt()
        let request = try XCTUnwrap(presentation.newPromptRequest)
        presentation.resolveNewPrompt(.createPrompt("Stale guard"), id: request.id)
        let decision = try XCTUnwrap(old.editor.state.pendingDecision)
        XCTAssertEqual(decision.action, .create)
        main.queuesWork = true
        old.editor.resolveDecision(.discard, id: decision.id)
        presentation.rebind(to: replacement.browser, editor: replacement.editor, libraryPath: otherRoot.path, available: true)
        main.drain()
        XCTAssertEqual(creations, 0)
        XCTAssertNil(try files(at: root).stamp(at: "Stale guard.md"))
        XCTAssertNil(try files(at: otherRoot).stamp(at: "Stale guard.md"))
    }

    func testSwitchDiscardsShowHeldBehindFocusRestoration() throws {
        let own = NSRunningApplication.current.processIdentifier
        var frontmost: DeliveryTarget? = .macOS(processID: own + 1, bundleID: "test.external")
        let scheduler = SwitchScheduler()
        scheduler.hold = true
        let old = try start(scheduler: scheduler, focusSource: .init(frontmost: { frontmost }, activate: { _ in false }))
        old.open()
        frontmost = .macOS(processID: own, bundleID: "test.own")
        old.dismiss() // Holds DeliveryService's queue during focus restoration.
        old.open() // Its show request cannot run yet.
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(delegate.switchLibrary(to: try otherLibrary()), .switched)
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        let revision = presentation.focusRevision
        scheduler.drain()
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(presentation.focusRevision, revision)
        XCTAssertEqual(delegate.pickerModel?.state, .closed)
        delegate.pickerModel?.open()
        XCTAssertTrue(panel.isVisible)
    }

    func testSwitchDropsDraftsButKeepsRememberedValuesAndUsage() throws {
        let source = "---\nfields:\n  topic: {default: Default, remember: true}\n---\n{{topic}}"
        try files(at: root).write(Data(source.utf8), at: "shared.md")
        let other = try otherLibrary()
        try RootedFileStore(root: other).write(Data(source.utf8), at: "shared.md")
        let old = try start()
        let identity = try XCTUnwrap(old.results.first?.identity)
        let dataFiles = try RootedFileStore(root: data)
        try ValuesStore(files: dataFiles).record(identity: identity, values: ["topic": "Remembered"])
        try UsageStore(files: dataFiles, clock: SystemClock()).recordUse(identity: identity)
        old.open()
        old.use(mode: .copyOnly)
        let fill = try XCTUnwrap(old.fillModel)
        XCTAssertEqual(fill.values["topic"], "Remembered")
        fill.setValue("Session draft", name: "topic")

        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        XCTAssertEqual(fill.state, .closed)
        fill.setValue("Late edit", name: "topic")
        XCTAssertEqual(fill.values["topic"], "Session draft")
        let current = try XCTUnwrap(delegate.pickerModel)
        XCTAssertEqual(current.results.first?.relativePath, "shared.md", "Usage ranking must survive switching")
        XCTAssertEqual(current.results.first?.identity, identity)
        current.open()
        current.use(mode: .copyOnly)
        XCTAssertEqual(current.fillModel?.values["topic"], "Remembered")
    }

    func testPersistedRootIsUsedOnNextCompositionAndDefaultCanBeRestored() throws {
        let other = try otherLibrary()
        try start()
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try start()
        XCTAssertEqual(delegate.libraryDirectory, other)
        XCTAssertEqual(delegate.pickerModel?.results.map(\.relativePath), ["beta.md"])
        try FileManager.default.removeItem(at: root)
        XCTAssertEqual(delegate.switchLibrary(to: nil), .switched)
        XCTAssertEqual(delegate.libraryDirectory, root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertNil(try XCTUnwrap(delegate.settingsModel).libraryFolderPath)
    }

    func testLegacySetupImportKeepsLibraryAndSeedStepsPending() throws {
        try start(legacyFirstRun: .setupPresented)
        let settings = try XCTUnwrap(delegate.settingsModel)
        XCTAssertFalse(settings.needsSetupPresentation)
        XCTAssertTrue(settings.needsLibraryFolderStep)
        XCTAssertTrue(settings.needsSeedOffer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("settings.json").path))
        XCTAssertEqual(delegate.switchLibrary(to: try otherLibrary()), .switched)
        XCTAssertEqual(settings.firstRun, FirstRunProgress(setupPresented: true, tourCompleted: true))
    }

    func testSetupPresentationRecordsSettingsAndDowngradeFlag() throws {
        var legacyWrites = 0
        try start(recordLegacySetup: { legacyWrites += 1 })
        _ = delegate.perform(Selector(("showSetup")))
        XCTAssertEqual(legacyWrites, 1)
        XCTAssertEqual(delegate.settingsModel?.firstRun, FirstRunProgress(setupPresented: true))
        let settings = SettingsService(store: SettingsStore(files: try RootedFileStore(root: data)))
        XCTAssertEqual(settings.snapshot.document.firstRun, FirstRunProgress(setupPresented: true))
    }

    func testReadOnlySettingsUseDefaultAndKeepSwitchForSession() throws {
        let config = try files(at: data)
        let bytes = Data("{\"version\":999}".utf8)
        try config.write(bytes, at: "settings.json")
        try start()
        XCTAssertEqual(delegate.libraryDirectory, root)
        XCTAssertTrue(try XCTUnwrap(delegate.pickerModel).libraryAvailable)
        XCTAssertEqual(delegate.settingsModel?.error, .futureVersion(999))
        let other = try otherLibrary()
        XCTAssertEqual(delegate.switchLibrary(to: other), .settingsNotSaved(.futureVersion(999)))
        XCTAssertEqual(delegate.libraryDirectory, other)
        XCTAssertEqual(delegate.pickerModel?.results.map(\.relativePath), ["beta.md"])
        XCTAssertNil(try XCTUnwrap(delegate.settingsModel).libraryFolderPath)
        XCTAssertEqual(delegate.settingsModel?.error, .futureVersion(999))
        XCTAssertEqual(try config.read(at: "settings.json"), bytes)
    }

    func testAppDataWriteFailureKeepsOldGraphUntilRepeatCanRetire() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        let other = try otherLibrary()
        try start()
        let settings = try XCTUnwrap(delegate.settingsModel)
        settings.markSetupPresented()
        let config = try RootedFileStore(root: data)
        let bytes = try config.read(at: "settings.json")
        let old = delegate.pickerModel
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: data.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path) }
        // App data also holds repeat. Its tombstone must succeed before the
        // graph can move, even when no delivery has been recorded yet.
        XCTAssertEqual(delegate.switchLibrary(to: other), .repeatInvalidationFailed)
        XCTAssertEqual(delegate.libraryDirectory, root)
        XCTAssertTrue(delegate.pickerModel === old)
        XCTAssertEqual(delegate.repeatModel?.availability, .unavailable(.invalidationFailed))
        XCTAssertNil(settings.libraryFolderPath)
        XCTAssertNil(settings.error)
        XCTAssertEqual(try config.read(at: "settings.json"), bytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        XCTAssertEqual(delegate.libraryDirectory, other)
    }

    func testStartupFailureDegradesNewGraphWithoutPersistingChoice() throws {
        let other = try otherLibrary()
        try start(onWatcherStart: { watched in
            if watched == other { throw FileStoreError.ioFailure }
        })
        XCTAssertEqual(delegate.switchLibrary(to: other), .libraryUnavailable(.ioFailure))
        XCTAssertFalse(try XCTUnwrap(delegate.pickerModel).libraryAvailable)
        XCTAssertNil(try XCTUnwrap(delegate.settingsModel).libraryFolderPath)
        XCTAssertTrue(watchers[0].stopped)
        XCTAssertTrue(watchers[1].stopped)
        XCTAssertEqual(delegate.switchLibrary(to: nil), .switched)
        XCTAssertTrue(try XCTUnwrap(delegate.pickerModel).libraryAvailable)
        XCTAssertEqual(watchers.count, 3)
    }

    func testRootVanishingDuringWatcherStartDoesNotPersistChoice() throws {
        let other = try otherLibrary()
        try start(onWatcherStart: { watched in
            if watched == other { try FileManager.default.removeItem(at: other) }
        })
        XCTAssertEqual(delegate.switchLibrary(to: other), .libraryUnavailable(.notFound))
        XCTAssertFalse(try XCTUnwrap(delegate.pickerModel).libraryAvailable)
        XCTAssertNil(try XCTUnwrap(delegate.settingsModel).libraryFolderPath)
        XCTAssertTrue(watchers[1].stopped)
    }
}

private final class SwitchWatcher: FileStoreWatcher {
    private let onStart: () throws -> Void
    private var onEvent: (@Sendable (FileStoreWatchEvent) -> Void)?
    private(set) var stopped = false

    init(onStart: @escaping () throws -> Void) { self.onStart = onStart }
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {
        self.onEvent = onEvent
        try onStart()
    }
    func stop() { stopped = true }
    // Deliberately retains the callback to exercise a late native event.
    func emit(_ event: FileStoreWatchEvent) { onEvent?(event) }
}

private struct NewPromptSwitchWork: BackgroundWork {
    func run(_ work: @escaping () -> Void) { work() }
}

private final class NewPromptSwitchMainThread: MainThread {
    var queuesWork = false
    private var pending: [() -> Void] = []
    func run(_ work: @escaping () -> Void) {
        if queuesWork { pending.append(work) }
        else { work() }
    }
    func drain() { while !pending.isEmpty { pending.removeFirst()() } }
}

private final class SwitchScheduler: MonkeysPawCore.Scheduler {
    var hold = false
    private var pending: [() -> Void] = []
    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        if hold { pending.append(work) }
        else { work() }
    }
    func drain() {
        hold = false
        while !pending.isEmpty { pending.removeFirst()() }
    }
}
