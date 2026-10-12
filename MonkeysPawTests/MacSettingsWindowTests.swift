import AppKit
import Carbon.HIToolbox
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacSettingsWindowTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var delegate: AppDelegate!
    private var panel: PanelController!
    private var focus: WorkspaceFocusTracker!
    private var scheduler = SettingsWindowScheduler()
    private var originalWindows: Set<ObjectIdentifier> = []
    private var originalMenu: NSMenu?
    private var originalPolicy: NSApplication.ActivationPolicy = .accessory
    private var policies: [NSApplication.ActivationPolicy] = []
    private var applicationActivations = 0
    private var targetActivations: [DeliveryTarget] = []
    private var frontmost: DeliveryTarget?
    private var chooserCompletions: [(URL?) -> Void] = []
    private var chooserCancellations = 0
    private var revealed: [URL] = []
    private var legacySetupWrites = 0
    private var ownPID: Int32 { NSRunningApplication.current.processIdentifier }
    private var externalTarget: DeliveryTarget { .macOS(processID: ownPID + 1, bundleID: "test.external") }
    private var ownTarget: DeliveryTarget { .macOS(processID: ownPID, bundleID: "test.own") }

    override func setUpWithError() throws {
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        originalMenu = NSApp.mainMenu
        originalPolicy = NSApp.activationPolicy()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("default", isDirectory: true)
        data = directory.appendingPathComponent("data", isDirectory: true)
    }

    override func tearDown() {
        delegate?.pickerModel?.dismiss()
        panel?.hide()
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        scheduler.drain()
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate = nil
        panel = nil
        focus = nil
        chooserCompletions = []
        NSApp.mainMenu = originalMenu
        _ = NSApp.setActivationPolicy(originalPolicy)
        try? FileManager.default.removeItem(at: directory)
    }

    private func start() throws {
        delegate = AppDelegate(libraryRoot: root, dataRoot: data,
            recordLegacySetup: { [weak self] in self?.legacySetupWrites += 1 }, launchURI: { _ in
                XCTFail("Settings must use its folder reveal seam")
            }, revealLibrary: { [weak self] in self?.revealed.append($0) }, folderChooser: { [weak self] _, done in
                self?.chooserCompletions.append(done)
                return { [weak self] in self?.chooserCancellations += 1 }
            }, setActivationPolicy: { [weak self] policy in
                self?.policies.append(policy)
                _ = NSApp.setActivationPolicy(policy)
            }, activateApplication: { [weak self] in
                self?.applicationActivations += 1
                NSApp.activate()
            }, makeFocusTracker: { [weak self] main, scheduler in
                let focus = WorkspaceFocusTracker(source: .init(frontmost: { [weak self] in self?.frontmost },
                    activate: { [weak self] in self?.targetActivations.append($0); return true }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
                self?.focus = focus
                return focus
            }, scheduler: scheduler, makePanelController: { [weak self] main, scheduler, log in
                // Exercise cancellation before native key-window state settles.
                let panel = PanelController(mainThread: main, scheduler: scheduler, log: log, keyWindow: { nil })
                self?.panel = panel
                return panel
            }, makeFileWatcher: { _, _ in SettingsWindowWatcher() })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertNotNil(delegate.generalSettingsModel)
        XCTAssertNotNil(delegate.shortcutsSettingsModel)
    }

    private func settings() throws -> SettingsWindowController { try XCTUnwrap(delegate.settingsWindow) }

    private func otherLibrary() throws -> URL {
        let url = directory.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testOpeningTwiceAndReopeningReusesWindowAndPickerStillWorks() throws {
        try start()
        XCTAssertNil(try settings().window, "Hosted launch must not create a Settings window")
        delegate.showSettings()
        let window = try XCTUnwrap(settings().window)
        delegate.showSettings()
        XCTAssertTrue(try settings().window === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(policies, [.regular])
        XCTAssertEqual(applicationActivations, 2)
        XCTAssertEqual(NSApp.windows.filter { $0.title == Strings.settingsTitle }.count, 1)

        window.close()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(policies, [.regular, .accessory])
        delegate.showSettings()
        XCTAssertTrue(try settings().window === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(policies, [.regular, .accessory, .regular])
        window.close()
        let picker = try XCTUnwrap(delegate.pickerModel)
        picker.open()
        XCTAssertEqual(picker.state, .picker)
        XCTAssertTrue(panel.isVisible)
        picker.dismiss()
        XCTAssertFalse(panel.isVisible)
    }

    func testSetupFromSettingsReusesSetupAndClosingSettingsWhileSetupIsKeyReturnsToAccessory() throws {
        try start()
        let model = try XCTUnwrap(delegate.setupModel)
        delegate.showSettings()
        let settings = try settings()
        settings.presentation.showSetup()
        let setup = try XCTUnwrap(NSApp.windows.first { $0.title == Strings.setupTitle })
        setup.makeKeyAndOrderFront(nil)
        XCTAssertTrue(spin { setup.isKeyWindow })
        XCTAssertTrue(delegate.setupModel === model)
        XCTAssertEqual(policies.last, .regular)
        XCTAssertEqual(legacySetupWrites, 1)
        XCTAssertTrue(try XCTUnwrap(delegate.settingsModel).firstRun.setupPresented)
        try XCTUnwrap(settings.window).close()
        XCTAssertTrue(setup.isVisible)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        XCTAssertEqual(policies.last, .accessory)
        settings.presentation.showSetup()
        XCTAssertEqual(NSApp.windows.filter { $0.title == Strings.setupTitle }.count, 1)
        XCTAssertEqual(policies.last, .accessory, "Setup never requests regular policy")
    }

    func testChooserUpdatesPathRejectsInvalidFolderUsesDefaultAndRevealsActiveFolder() throws {
        try start()
        delegate.showSettings()
        let presentation = try settings().presentation
        let other = try otherLibrary()
        XCTAssertEqual(presentation.general.activeLibraryPath, root.path)
        XCTAssertFalse(presentation.canUseDefault)
        presentation.chooseFolder()
        XCTAssertTrue(presentation.isChoosingFolder)
        chooserCompletions[0](other)
        XCTAssertFalse(presentation.isChoosingFolder)
        XCTAssertEqual(presentation.general.activeLibraryPath, other.path)
        XCTAssertFalse(presentation.general.isDefaultLibrary)
        XCTAssertTrue(presentation.canUseDefault)
        XCTAssertTrue(presentation.generalMessages.isEmpty)
        presentation.revealFolder()
        XCTAssertEqual(revealed, [other])

        presentation.chooseFolder()
        chooserCompletions[1](directory.appendingPathComponent("missing"))
        XCTAssertEqual(presentation.general.activeLibraryPath, other.path)
        XCTAssertEqual(presentation.general.lastSwitchMessage, .invalidTarget(.rejectedByStore(.notFound)))
        XCTAssertEqual(presentation.generalMessages,
                       [try XCTUnwrap(GeneralSettingsStrings.message(for: .invalidTarget(.rejectedByStore(.notFound))))])
        presentation.useDefaultFolder()
        XCTAssertEqual(presentation.general.activeLibraryPath, root.path)
        XCTAssertTrue(presentation.general.isDefaultLibrary)
        XCTAssertFalse(presentation.canUseDefault)
        XCTAssertTrue(presentation.generalMessages.isEmpty)
        XCTAssertNil(try XCTUnwrap(delegate.settingsModel).libraryFolderPath)
        presentation.revealFolder()
        XCTAssertEqual(revealed, [other, root])
    }

    func testChooserCancelAndLateCompletionAfterCloseAndReopenCannotSwitchLibrary() throws {
        try start()
        let other = try otherLibrary()
        delegate.showSettings()
        let settings = try settings()
        let presentation = settings.presentation
        presentation.chooseFolder()
        presentation.chooseFolder()
        XCTAssertEqual(chooserCompletions.count, 1, "Only one chooser can be pending")
        chooserCompletions[0](nil)
        XCTAssertFalse(presentation.isChoosingFolder)
        XCTAssertEqual(presentation.general.activeLibraryPath, root.path)
        XCTAssertTrue(presentation.generalMessages.isEmpty)

        presentation.chooseFolder()
        let late = chooserCompletions[1]
        try XCTUnwrap(settings.window).close()
        XCTAssertEqual(chooserCancellations, 1)
        XCTAssertFalse(presentation.isChoosingFolder)
        late(other)
        XCTAssertEqual(delegate.libraryDirectory, root)
        delegate.showSettings()
        presentation.chooseFolder()
        late(other)
        XCTAssertTrue(presentation.isChoosingFolder, "An old callback cannot finish the reopened chooser")
        XCTAssertEqual(delegate.libraryDirectory, root)
        chooserCompletions[2](other)
        XCTAssertEqual(presentation.general.activeLibraryPath, other.path)
        late(nil)
        XCTAssertEqual(presentation.general.activeLibraryPath, other.path)
    }

    func testReadOnlySettingsKeepFolderControlsUsableWithTypedError() throws {
        let files = try RootedFileStore(root: data)
        try files.createRoot()
        let bytes = Data("{\"version\":999}".utf8)
        try files.write(bytes, at: "settings.json")
        try start()
        delegate.showSettings()
        let presentation = try settings().presentation
        XCTAssertTrue(presentation.general.isReadOnly)
        XCTAssertEqual(presentation.general.settingsError, .futureVersion(999))
        XCTAssertTrue(presentation.canUseDefault)
        XCTAssertEqual(presentation.generalMessages, [GeneralSettingsStrings.settingsError(.futureVersion(999))])
        let other = try otherLibrary()
        presentation.chooseFolder()
        chooserCompletions[0](other)
        XCTAssertEqual(presentation.general.activeLibraryPath, other.path)
        XCTAssertEqual(presentation.general.lastSwitchMessage, .settingsNotSaved(.futureVersion(999)))
        XCTAssertEqual(presentation.generalMessages,
                       [try XCTUnwrap(GeneralSettingsStrings.message(for: .settingsNotSaved(.futureVersion(999))))])
        presentation.revealFolder()
        XCTAssertEqual(revealed, [other])
        presentation.useDefaultFolder()
        XCTAssertEqual(presentation.general.activeLibraryPath, root.path)
        XCTAssertTrue(presentation.canUseDefault, "Use Default remains available to retry saving")
        XCTAssertEqual(try files.read(at: "settings.json"), bytes)
    }

    func testChooserCompletionFromWorkerReturnsToTheUIThread() throws {
        try start()
        delegate.showSettings()
        let presentation = try settings().presentation
        let other = try otherLibrary()
        presentation.chooseFolder()
        let done = chooserCompletions[0]
        let completed = expectation(description: "Folder change is published on the UI thread")
        let general = try XCTUnwrap(delegate.generalSettingsModel)
        let publish = general.onChange
        general.onChange = {
            XCTAssertTrue(Thread.isMainThread)
            publish?()
            completed.fulfill()
        }
        DispatchQueue.global().async { done(other) }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(presentation.general.activeLibraryPath, other.path)
        XCTAssertFalse(presentation.isChoosingFolder)
    }

    func testBothMenusRouteCommandCommaWhileSettingsOrSetupIsKey() throws {
        try start()
        delegate.installMainMenu()
        let main = try XCTUnwrap(NSApp.mainMenu)
        let status = delegate.makeStatusMenu()
        let item = try XCTUnwrap(status.items.first { $0.title == Strings.settings })
        let appItem = try XCTUnwrap(main.items.first?.submenu?.items.first { $0.title == Strings.settings })
        for settingsItem in [item, appItem] {
            XCTAssertTrue(settingsItem.target === delegate)
            XCTAssertEqual(settingsItem.action, #selector(AppDelegate.showSettings))
            XCTAssertEqual(settingsItem.keyEquivalent, ",")
            XCTAssertEqual(settingsItem.keyEquivalentModifierMask, .command)
        }
        XCTAssertTrue(status.performKeyEquivalent(with: try commandComma()))
        let settings = try settings()
        let window = try XCTUnwrap(settings.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(spin { window.isKeyWindow })
        XCTAssertTrue(main.performKeyEquivalent(with: try commandComma(window: window)))
        XCTAssertEqual(applicationActivations, 2)

        settings.presentation.showSetup()
        let setup = try XCTUnwrap(NSApp.windows.first { $0.title == Strings.setupTitle })
        XCTAssertTrue(spin { setup.isKeyWindow })
        window.close()
        XCTAssertTrue(main.performKeyEquivalent(with: try commandComma(window: setup)))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(applicationActivations, 3)
        XCTAssertEqual(NSApp.activationPolicy(), .regular)
    }

    func testSettingsCancelsArmedTargetAndDeferredBlurThenNormalPickerDismissalStillWorks() throws {
        try start()
        frontmost = externalTarget
        let picker = try XCTUnwrap(delegate.pickerModel)
        picker.open()
        let native = try XCTUnwrap(NSApp.windows.compactMap { $0 as? PromptPanel }.first {
            !originalWindows.contains(ObjectIdentifier($0))
        })
        frontmost = ownTarget
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: native)
        delegate.showSettings()
        XCTAssertEqual(picker.state, .closed)
        XCTAssertFalse(panel.isVisible)
        try XCTUnwrap(settings().window).close()
        scheduler.drain()
        picker.dismiss()
        XCTAssertTrue(targetActivations.isEmpty)

        frontmost = externalTarget
        picker.open()
        frontmost = ownTarget
        native.cancelOperation(nil)
        scheduler.drain()
        XCTAssertEqual(targetActivations, [externalTarget])
    }

    func testSettingsCancelsPendingRestoreAndQueuedSummonEvenWhenPanelIsHidden() throws {
        try start()
        let picker = try XCTUnwrap(delegate.pickerModel)
        frontmost = externalTarget
        picker.open()
        frontmost = ownTarget
        picker.dismiss()
        XCTAssertEqual(targetActivations, [externalTarget], "The first dismissal starts a held restore")
        XCTAssertFalse(panel.isVisible)
        frontmost = externalTarget
        picker.open()
        XCTAssertEqual(picker.state, .picker)
        XCTAssertFalse(panel.isVisible, "The summon is queued behind that restore")
        frontmost = ownTarget
        delegate.showSettings()
        XCTAssertEqual(picker.state, .closed)
        try XCTUnwrap(settings().window).close()
        scheduler.drain()
        XCTAssertFalse(panel.isVisible, "A superseded summon must not reappear after Settings closes")
        XCTAssertEqual(targetActivations, [externalTarget], "Settings must revoke activation retries and queued targets")
    }

    func testGeneralPortDoesNotRetainCompositionRoot() throws {
        try start()
        let general = try XCTUnwrap(delegate.generalSettingsModel)
        weak var rootReference = delegate
        delegate = nil
        XCTAssertNil(rootReference)
        general.useDefaultFolder()
        XCTAssertEqual(general.state.lastSwitchMessage, .libraryUnavailable(.ioFailure))
    }

    func testEveryPlatformSwitchResultMapsLosslesslyToCore() {
        let cases: [(AppDelegate.LibrarySwitchResult, LibrarySwitchOutcome)] = [
            (.switched, .switched), (.deliveryInFlight, .deliveryInFlight),
            (.invalidTarget(.outsideRoot), .invalidTarget(.rejectedByStore(.outsideRoot))),
            (.libraryUnavailable(.notFound), .libraryUnavailable(.notFound)),
            (.settingsNotSaved(.writeFailed(.ioFailure)), .settingsNotSaved(.writeFailed(.ioFailure))),
        ]
        for (platform, core) in cases { XCTAssertEqual(platform.outcome, core) }
    }

    private func commandComma(window: NSWindow? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil, characters: ",",
            charactersIgnoringModifiers: ",", isARepeat: false, keyCode: UInt16(kVK_ANSI_Comma)))
    }

    private func spin(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return condition()
    }
}

private final class SettingsWindowScheduler: MonkeysPawCore.Scheduler {
    private var pending: [() -> Void] = []
    func after(_ delay: Duration, _ work: @escaping () -> Void) { pending.append(work) }
    func drain() { while !pending.isEmpty { pending.removeFirst()() } }
}

private final class SettingsWindowWatcher: FileStoreWatcher {
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {}
    func stop() {}
}
