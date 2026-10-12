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
                       scheduler: Scheduler = SwitchScheduler(),
                       focusSource: WorkspaceFocusTracker.Source? = nil,
                       onWatcherStart: @escaping (URL) throws -> Void = { _ in }) throws -> PickerModel {
        delegate = AppDelegate(libraryRoot: root, dataRoot: data, legacyFirstRun: legacyFirstRun,
            recordLegacySetup: recordLegacySetup, launchURI: { [weak self] in self?.launched.append($0) },
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
            XCTAssertEqual(delegate.settingsModel?.state, settings)
            XCTAssertFalse(watchers[0].stopped)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(watchers.count, 1)
    }

    func testUnreadableTargetKeepsGraphAndSettings() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        let other = try otherLibrary()
        let old = try start()
        let settings = delegate.settingsModel?.state
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: other.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: other.path) }
        XCTAssertEqual(delegate.switchLibrary(to: other), .invalidTarget(.ioFailure))
        XCTAssertTrue(delegate.pickerModel === old)
        XCTAssertEqual(delegate.settingsModel?.state, settings)
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
        XCTAssertNil(delegate.settingsModel?.libraryFolderPath)
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
        XCTAssertNil(delegate.settingsModel?.libraryFolderPath)
    }

    func testLegacySetupImportKeepsLibraryAndSeedStepsPending() throws {
        try start(legacyFirstRun: .setupPresented)
        let settings = try XCTUnwrap(delegate.settingsModel)
        XCTAssertFalse(settings.needsSetupPresentation)
        XCTAssertTrue(settings.needsLibraryFolderStep)
        XCTAssertTrue(settings.needsSeedOffer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("settings.json").path))
        XCTAssertEqual(delegate.switchLibrary(to: try otherLibrary()), .switched)
        XCTAssertEqual(settings.firstRun, FirstRunProgress(setupPresented: true))
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
        XCTAssertNil(delegate.settingsModel?.libraryFolderPath)
        XCTAssertEqual(delegate.settingsModel?.error, .futureVersion(999))
        XCTAssertEqual(try config.read(at: "settings.json"), bytes)
    }

    func testSettingsWriteFailureKeepsNewGraphForSession() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        let other = try otherLibrary()
        try start()
        let settings = try XCTUnwrap(delegate.settingsModel)
        settings.markSetupPresented()
        let config = try RootedFileStore(root: data)
        let bytes = try config.read(at: "settings.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: data.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path) }
        XCTAssertEqual(delegate.switchLibrary(to: other), .settingsNotSaved(.writeFailed(.ioFailure)))
        XCTAssertEqual(delegate.libraryDirectory, other)
        XCTAssertEqual(delegate.pickerModel?.results.map(\.relativePath), ["beta.md"])
        XCTAssertNil(settings.libraryFolderPath)
        XCTAssertEqual(settings.error, .writeFailed(.ioFailure))
        XCTAssertEqual(try config.read(at: "settings.json"), bytes)
    }

    func testStartupFailureDegradesNewGraphWithoutPersistingChoice() throws {
        let other = try otherLibrary()
        try start(onWatcherStart: { watched in
            if watched == other { throw FileStoreError.ioFailure }
        })
        XCTAssertEqual(delegate.switchLibrary(to: other), .libraryUnavailable(.ioFailure))
        XCTAssertFalse(try XCTUnwrap(delegate.pickerModel).libraryAvailable)
        XCTAssertNil(delegate.settingsModel?.libraryFolderPath)
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
        XCTAssertNil(delegate.settingsModel?.libraryFolderPath)
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

private final class SwitchScheduler: Scheduler {
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
