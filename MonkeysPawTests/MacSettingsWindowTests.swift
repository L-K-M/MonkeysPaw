import AppKit
import Carbon.HIToolbox
import MonkeysPawCore
import SwiftUI
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

    private func start(backgroundWork: BackgroundWork = DispatchBackgroundWork(),
                       httpTransport: HTTPTransporting = URLSessionHTTPTransport(),
                       secrets: SecretStore? = nil) throws {
        delegate = AppDelegate(libraryRoot: root, dataRoot: data,
            recordLegacySetup: { [weak self] in self?.legacySetupWrites += 1 }, launchURI: { _ in
                XCTFail("Settings must use its folder reveal seam")
            }, backgroundWork: backgroundWork, httpTransport: httpTransport, secrets: secrets,
            revealLibrary: { [weak self] in self?.revealed.append($0) }, folderChooser: { [weak self] _, done in
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
        XCTAssertEqual(NSApp.windows.filter {
            !originalWindows.contains(ObjectIdentifier($0)) && $0 === window
        }.count, 1)

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

    func testProductionSettingsCompositionCreatesAssistantTabWithoutNetwork() throws {
        let files = try RootedFileStore(root: data)
        let id = ProviderProfileID()
        let profile = try ProviderProfile(id: id, displayName: "Local Ollama", kind: .openaiCompatible,
            baseURL: "http://localhost:11434/v1", modelID: "manual-model")
        let object: [String: Any] = ["version": ProviderSettings.currentVersion, "selectedProfileID": id.rawValue,
            "profiles": [["id": id.rawValue, "displayName": profile.displayName, "kind": profile.kind.rawValue,
                          "baseURL": profile.baseURL.absoluteString, "modelID": profile.modelID,
                          "secretReference": NSNull()]]]
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try files.write(bytes, at: "provider-settings.json")
        let work = SettingsAssistantWork()
        try start(backgroundWork: work, httpTransport: SettingsUnexpectedHTTPTransport())
        let controller = try settings()
        XCTAssertNotNil(delegate.providerSettingsService)
        XCTAssertNil(controller.presentation.assistant, "The Assistant model is created only when Settings opens")

        delegate.showSettings()
        let tabs = try XCTUnwrap(controller.window?.contentViewController as? NSTabViewController)
        let hosting = try XCTUnwrap(tabs.tabViewItems[SettingsViewState.Tab.assistant.rawValue].viewController
            as? NSHostingController<SettingsView>)
        XCTAssertTrue(hosting.rootView.presentation === controller.presentation)
        let assistant = try XCTUnwrap(hosting.rootView.presentation.assistant,
            "Production Settings must supply the model that renders its Assistant tab")
        work.drain()
        XCTAssertEqual(assistant.state.profiles, [profile])
        XCTAssertEqual(assistant.state.draft?.id, id)
        XCTAssertEqual(assistant.state.keyStorage, .none)
        XCTAssertNil(assistant.state.operation)
        XCTAssertFalse(assistant.state.isTesting)
        XCTAssertNil(assistant.state.testResult)
        XCTAssertEqual(try files.read(at: "provider-settings.json"), bytes)

        assistant.renameProfile("Unsaved edit")
        delegate.showSettings()
        work.drain()
        XCTAssertTrue(controller.presentation.assistant === assistant)
        XCTAssertEqual(assistant.state.draft?.displayName, "Unsaved edit")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertNil(controller.presentation.assistant)
        XCTAssertFalse(assistant.canChangeProfiles)
    }

    func testSettingsUsesToolbarPanesWithSymbolsAndFixedWindow() throws {
        try start()
        delegate.showSettings()
        let controller = try settings()
        let window = try XCTUnwrap(controller.window)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        XCTAssertEqual(tabs.tabStyle, .toolbar)
        XCTAssertTrue(tabs.canPropagateSelectedChildViewControllerTitle)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["General", "Shortcuts", "Delivery", "Assistant", "Account"])
        let symbols = ["gearshape", "command", "paperplane", "sparkles", "person.crop.circle"]
        for (index, item) in tabs.tabViewItems.enumerated() {
            XCTAssertNotNil(item.image)
            XCTAssertEqual(item.image?.accessibilityDescription, item.label)
            XCTAssertEqual(item.viewController?.title, item.label)
            let hosting = try XCTUnwrap(item.viewController as? NSHostingController<SettingsView>)
            XCTAssertTrue(hosting.rootView.presentation === controller.presentation)
            XCTAssertEqual(hosting.rootView.pane.rawValue, index)
            XCTAssertEqual(hosting.rootView.pane.symbol, symbols[index])
            XCTAssertTrue(hosting.sizingOptions.isEmpty)
        }
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenNone))
        XCTAssertEqual(window.toolbarStyle, .preference)
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertEqual(window.frameAutosaveName, "Settings")
        XCTAssertEqual(window.title, Strings.generalTab)
    }

    func testSettingsSelectionSynchronizesBothWaysAndReopeningKeepsPane() throws {
        try start()
        delegate.showSettings()
        let controller = try settings()
        let window = try XCTUnwrap(controller.window)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        XCTAssertEqual(controller.presentation.selectedTab, .general)
        XCTAssertEqual(tabs.selectedTabViewItemIndex, 0)

        controller.presentation.selectedTab = .delivery
        XCTAssertEqual(tabs.selectedTabViewItemIndex, SettingsViewState.Tab.delivery.rawValue)
        XCTAssertEqual(window.title, DeliverySettingsStrings.title)
        tabs.tabView.selectTabViewItem(at: SettingsViewState.Tab.shortcuts.rawValue)
        XCTAssertEqual(controller.presentation.selectedTab, .shortcuts)
        XCTAssertEqual(window.title, Strings.shortcutsTab)
        window.close()
        delegate.showSettings()
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(controller.presentation.selectedTab, .shortcuts)
        XCTAssertEqual(tabs.selectedTabViewItemIndex, SettingsViewState.Tab.shortcuts.rawValue)

        controller.showAccount()
        XCTAssertEqual(controller.presentation.selectedTab, .account)
        XCTAssertEqual(tabs.selectedTabViewItemIndex, SettingsViewState.Tab.account.rawValue)
        XCTAssertEqual(window.title, SettingsAccountStrings.tab)
    }

    func testSettingsPaneResizePreservesTopLeftAndCapsTallPanes() throws {
        try start()
        delegate.showSettings()
        let controller = try settings()
        let window = try XCTUnwrap(controller.window)
        // Hidden selection uses the same geometry without depending on the CI
        // runner's Reduce Motion preference or animation timing.
        window.close()
        let frame = window.frame
        controller.presentation.selectedTab = .delivery
        let shortFrame = window.frame
        XCTAssertNotEqual(shortFrame.height, frame.height)
        XCTAssertEqual(shortFrame.minX, frame.minX, accuracy: 0.5)
        XCTAssertEqual(shortFrame.maxY, frame.maxY, accuracy: 0.5)
        XCTAssertEqual(shortFrame.width, frame.width, accuracy: 0.5)
        XCTAssertEqual(window.contentRect(forFrameRect: shortFrame).height,
            SettingsViewState.Tab.delivery.contentSize.height, accuracy: 0.5)

        controller.presentation.selectedTab = .assistant
        XCTAssertGreaterThan(window.frame.height, shortFrame.height)
        XCTAssertEqual(window.frame.minX, frame.minX, accuracy: 0.5)
        XCTAssertEqual(window.frame.maxY, frame.maxY, accuracy: 0.5)
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let available = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame.height - chrome
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height,
            min(SettingsViewState.Tab.assistant.contentSize.height, available), accuracy: 0.5)
    }

    func testSettingsPanesStayInsideTheVisibleScreen() throws {
        try start()
        delegate.showSettings()
        let controller = try settings()
        let window = try XCTUnwrap(controller.window)
        let visibleFrame = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame
        window.close()

        for pane in SettingsViewState.Tab.allCases {
            controller.presentation.selectedTab = pane == .general ? .delivery : .general
            window.setFrameOrigin(NSPoint(x: visibleFrame.maxX - window.frame.width / 2,
                y: visibleFrame.minY))
            controller.presentation.selectedTab = pane
            XCTAssertGreaterThanOrEqual(window.frame.minX, visibleFrame.minX - 0.5, pane.title)
            XCTAssertGreaterThanOrEqual(window.frame.minY, visibleFrame.minY - 0.5, pane.title)
            XCTAssertLessThanOrEqual(window.frame.maxX, visibleFrame.maxX + 0.5, pane.title)
            XCTAssertLessThanOrEqual(window.frame.maxY, visibleFrame.maxY + 0.5, pane.title)
        }
    }

    func testHostedCompositionReadsSavedTierOnlyThroughInjectedSecrets() throws {
        let secrets = SettingsAssistantSecrets()
        let profile = try installSavedSecretProfile(secrets: secrets)
        let reads = secrets.reads
        let work = SettingsAssistantWork()
        try start(backgroundWork: work, httpTransport: SettingsUnexpectedHTTPTransport(), secrets: secrets)
        delegate.showSettings()
        let assistant = try XCTUnwrap(settings().presentation.assistant)
        work.drain()
        XCTAssertEqual(assistant.state.draft?.id, profile.id)
        XCTAssertEqual(assistant.state.keyStorage, .saved(.keychain))
        XCTAssertGreaterThan(secrets.reads, reads, "Saved-tier reads must use the injected store")
        XCTAssertFalse(assistant.state.isTesting)
        XCTAssertNil(assistant.state.testResult)
    }

    func testHostedCompositionWithoutInjectedSecretsReportsUnavailable() throws {
        let secrets = SettingsAssistantSecrets()
        let profile = try installSavedSecretProfile(secrets: secrets)
        let reads = secrets.reads
        let work = SettingsAssistantWork()
        try start(backgroundWork: work, httpTransport: SettingsUnexpectedHTTPTransport())
        delegate.showSettings()
        let assistant = try XCTUnwrap(settings().presentation.assistant)
        work.drain()
        XCTAssertEqual(assistant.state.draft?.id, profile.id)
        XCTAssertEqual(assistant.state.keyStorage, .failed(.secret(.unavailable)))
        XCTAssertEqual(secrets.reads, reads)
        XCTAssertFalse(assistant.errorMessages.isEmpty)
    }

    private func installSavedSecretProfile(secrets: SecretStore) throws -> ProviderDraft {
        let files = try RootedFileStore(root: data)
        let settings = ProviderSettingsService(store: ProviderSettingsStore(files: files), secrets: secrets)
        let profile = ProviderDraft(displayName: "Isolated", key: .replace(SecretValue("test-only-key")))
        try settings.save(profile)
        return profile
    }

    func testAssistantFactoryIsLazyAndReopenPreservesModelUntilWindowTeardown() throws {
        try start()
        let existing = try settings().presentation
        let main = DispatchMainThread()
        let work = SettingsAssistantWork()
        var creations = 0
        weak var liveModel: AssistantSettingsModel?
        var controller: SettingsWindowController? = SettingsWindowController(general: existing.generalModel,
            shortcuts: existing.shortcutsModel, rememberedValues: existing.rememberedValuesModel,
            delivery: existing.delivery.model, updates: existing.updates.model,
            forgetAllConfirmation: { _, _ in {} }, mainThread: main,
            activation: WindowActivationCoordinator(mainThread: main, setPolicy: { _ in }, activate: {}),
            folderChooser: { _, _ in {} }, openSetup: {}, makeAssistant: {
                creations += 1
                let model = MacAssistantSettingsTests.makeModel(work: work)
                liveModel = model
                return model
            })
        XCTAssertEqual(creations, 0)
        let presentation = try XCTUnwrap(controller?.presentation)
        XCTAssertNil(presentation.assistant)
        weak var liveController = controller
        // AppKit autoreleases the window delegate while showing and closing.
        // Drain that pool so releasing `controller` drops the last reference.
        let wrapper = try autoreleasepool { () throws -> AssistantSettingsViewState in
            controller?.show()
            let window = try XCTUnwrap(controller?.window)
            defer { window.close() }
            work.drain()
            let assistant = try XCTUnwrap(presentation.assistant)
            XCTAssertNotNil(liveModel, "The factory's Core model must be alive before checking retirement")
            assistant.addProfile()
            assistant.renameProfile("Staged")
            controller?.show()
            XCTAssertEqual(creations, 1)
            XCTAssertTrue(presentation.assistant === assistant)
            XCTAssertEqual(assistant.state.draft?.displayName, "Staged")
            assistant.testConnection()
            XCTAssertTrue(assistant.state.isTesting)
            window.close()
            XCTAssertTrue(presentation.assistant === assistant)
            XCTAssertNotNil(liveModel, "A retained Settings window owns one model across reopenings")
            XCTAssertFalse(assistant.state.isTesting, "Closing cancels its queued Test")
            work.drain()
            controller?.show()
            work.drain()
            XCTAssertEqual(creations, 1)
            XCTAssertTrue(controller?.window === window)
            XCTAssertTrue(presentation.assistant === assistant)
            XCTAssertEqual(assistant.state.draft?.displayName, "Staged")
            XCTAssertFalse(assistant.state.isTesting)

            window.close()
            assistant.testConnection()
            XCTAssertTrue(assistant.state.isTesting)
            return assistant
        }
        // The view wrapper deliberately outlives its released Core model.
        controller = nil
        XCTAssertNil(liveController, "Nothing outside the test may retain the Settings controller")
        XCTAssertNil(liveModel, "Window teardown releases the model and cancels queued Test work")
        work.drain()
        XCTAssertFalse(wrapper.canChangeProfiles)
    }

    func testSetupFromSettingsReusesSetupAndClosingSettingsWithSetupVisibleReturnsToAccessory() throws {
        try start()
        let model = try XCTUnwrap(delegate.setupModel)
        delegate.showSettings()
        let settings = try settings()
        settings.presentation.showSetup()
        let setup = try setupWindow()
        XCTAssertTrue(setup.isVisible)
        XCTAssertEqual(applicationActivations, 1)
        XCTAssertTrue(delegate.setupModel === model)
        XCTAssertEqual(policies.last, .regular)
        XCTAssertEqual(legacySetupWrites, 1)
        XCTAssertTrue(try XCTUnwrap(delegate.settingsModel).firstRun.setupPresented)
        try XCTUnwrap(settings.window).close()
        XCTAssertTrue(setup.isVisible)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        XCTAssertEqual(policies.last, .accessory)
        settings.presentation.showSetup()
        XCTAssertEqual(NSApp.windows.filter {
            !originalWindows.contains(ObjectIdentifier($0)) && $0.title == Strings.setupTitle
        }.count, 1)
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

    func testBothMenusRouteCommandCommaForSettingsAndSetupWindows() throws {
        try start()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = delegate
        defer { NSApp.delegate = originalDelegate }
        delegate.installMainMenu()
        let main = try XCTUnwrap(NSApp.mainMenu)
        let status = delegate.makeStatusMenu()
        let item = try XCTUnwrap(status.items.first { $0.title == Strings.settings })
        let appItem = try XCTUnwrap(main.items.first?.submenu?.items.first { $0.title == Strings.settings })
        for settingsItem in [item, appItem] {
            if settingsItem === appItem { XCTAssertNil(settingsItem.target) }
            else { XCTAssertTrue(settingsItem.target === delegate) }
            XCTAssertEqual(settingsItem.action, #selector(AppDelegate.showSettings))
            XCTAssertEqual(settingsItem.keyEquivalent, ",")
            XCTAssertEqual(settingsItem.keyEquivalentModifierMask, .command)
        }
        XCTAssertTrue(status.performKeyEquivalent(with: try commandComma()))
        let settings = try settings()
        let window = try XCTUnwrap(settings.window)
        XCTAssertTrue(window.isVisible)
        // Menu routing and activation requests do not require the hosted app
        // to win a cooperative activation request on the CI runner.
        XCTAssertTrue(main.performKeyEquivalent(with: try commandComma(window: window)))
        XCTAssertEqual(applicationActivations, 2)

        settings.presentation.showSetup()
        let setup = try setupWindow()
        XCTAssertTrue(setup.isVisible)
        window.close()
        XCTAssertEqual(policies.last, .accessory)
        XCTAssertTrue(main.performKeyEquivalent(with: try commandComma(window: setup)))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(applicationActivations, 3)
        XCTAssertEqual(NSApp.activationPolicy(), .regular)
    }

    func testApplicationActivationRefreshesGeneralSettings() throws {
        try start()
        delegate.showSettings()
        let presentation = try settings().presentation
        let model = try XCTUnwrap(delegate.settingsModel)
        model.setLibraryFolder("relative")
        XCTAssertEqual(presentation.general.settingsError, .invalidLibraryFolder)

        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertNil(presentation.general.settingsError, "Refresh clears transient settings intent errors")
        XCTAssertTrue(presentation.generalMessages.isEmpty)
        XCTAssertEqual(presentation.general.activeLibraryPath, root.path)
    }

    func testGeneralMessageMappingPreservesSettingsErrorsAndShowsOnlyFailures() {
        let error = SettingsError.writeFailed(.ioFailure)
        let settingsMessage = GeneralSettingsStrings.settingsError(error)
        XCTAssertEqual(SettingsViewState.generalMessages(for: .settingsNotSaved(error),
            switchMessage: nil, settingsError: error), [settingsMessage])
        XCTAssertEqual(SettingsViewState.generalMessages(for: .settingsNotSaved(error),
            switchMessage: "Choice could not be saved", settingsError: error), ["Choice could not be saved"])
        XCTAssertEqual(SettingsViewState.generalMessages(for: .switched,
            switchMessage: "Folder changed", settingsError: error), [settingsMessage])
        XCTAssertTrue(SettingsViewState.generalMessages(for: .switched,
            switchMessage: "Folder changed", settingsError: nil).isEmpty)
        XCTAssertEqual(SettingsViewState.generalMessages(for: .deliveryInFlight,
            switchMessage: "Wait for delivery", settingsError: error), ["Wait for delivery", settingsMessage])
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
            (.repeatInvalidationFailed, .repeatInvalidationFailed),
        ]
        for (platform, core) in cases { XCTAssertEqual(platform.outcome, core) }
    }

    private func commandComma(window: NSWindow? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil, characters: ",",
            charactersIgnoringModifiers: ",", isARepeat: false, keyCode: UInt16(kVK_ANSI_Comma)))
    }

    private func setupWindow() throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first {
            !originalWindows.contains(ObjectIdentifier($0)) && $0.title == Strings.setupTitle
        })
    }
}

private final class SettingsWindowScheduler: MonkeysPawCore.Scheduler {
    private var pending: [() -> Void] = []
    func after(_ delay: Duration, _ work: @escaping () -> Void) { pending.append(work) }
    func drain() { while !pending.isEmpty { pending.removeFirst()() } }
}

private final class SettingsAssistantWork: BackgroundWork {
    private var pending: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { pending.append(work) }
    func drain(file: StaticString = #filePath, line: UInt = #line) {
        var processed = 0
        while !pending.isEmpty {
            guard processed < 10_000 else {
                pending.removeAll()
                XCTFail("Settings Assistant work did not settle after 10,000 items", file: file, line: line)
                return
            }
            processed += 1
            pending.removeFirst()()
        }
    }
}

private final class SettingsAssistantSecrets: SecretStore {
    private var values: [SecretAccount: SecretValue] = [:]
    private(set) var reads = 0

    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        reads += 1
        return values[account].map { StoredSecret(value: $0, tier: .keychain) }
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        values[account] = value
        return .keychain
    }
    func delete(account: SecretAccount) throws { values[account] = nil }
}

private struct SettingsUnexpectedHTTPTransport: HTTPTransporting {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        XCTFail("Opening Settings and editing a draft must not send HTTP requests")
        throw HTTPTransportError.networkFailure
    }
}

private final class SettingsWindowWatcher: FileStoreWatcher {
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {}
    func stop() {}
}
