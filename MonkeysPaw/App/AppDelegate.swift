import AppKit
import MonkeysPawCore
import SwiftUI

/// The macOS composition root owns the drivers and the resident status item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum LibrarySwitchResult: Equatable {
        case switched
        case deliveryInFlight
        case editorBusy
        case syncBusy
        case invalidTarget(FileStoreError)
        case libraryUnavailable(FileStoreError)
        case settingsNotSaved(SettingsError)
        case repeatInvalidationFailed

        var outcome: LibrarySwitchOutcome {
            switch self {
            case .switched: return .switched
            case .deliveryInFlight: return .deliveryInFlight
            // Core's folder port has one busy result. Native Settings retains
            // the editor-specific message without widening Core in this slice.
            case .editorBusy, .syncBusy: return .deliveryInFlight
            case .invalidTarget(let error): return .invalidTarget(.rejectedByStore(error))
            case .libraryUnavailable(let error): return .libraryUnavailable(error)
            case .settingsNotSaved(let error): return .settingsNotSaved(error)
            case .repeatInvalidationFailed: return .repeatInvalidationFailed
            }
        }
    }

    private enum LibraryLocation { case platformDefault, chosen }

    private let makeFocusTracker: (MainThread, MonkeysPawCore.Scheduler) -> WorkspaceFocusTracker
    private let scheduler: MonkeysPawCore.Scheduler
    private let makePanelController: (MainThread, MonkeysPawCore.Scheduler, LogSink) -> PanelController
    private let makeFileWatcher: (URL, LogSink) throws -> FileStoreWatcher
    private let mainThread: MainThread
    private let defaultLibraryDirectory: URL
    private(set) var libraryDirectory: URL
    private let dataDirectory: URL
    private let rootsAreInjected: Bool
    private let legacyFirstRun: LegacyFirstRun
    private let recordLegacySetup: () -> Void
    private let launchURI: (URL) -> Void
    private let backgroundWork: BackgroundWork
    private let httpTransport: HTTPTransporting
    private let currentReleaseVersion: String?
    private let updateClock: WallClock
    private let releasePage: ReleasePageOpening
    private let updateScheduler: MacUpdateScheduler
    private let makeSelfTestTarget: () -> SelfTestTarget
    private let secrets: SecretStore
    private let clipboard: Clipboard
    private let makeHotkeyBackend: (() -> MacHotkeyBackend)?
    private let pasteInjectors: [PasteInjector]?
    private let editorDialog: LibraryWindowController.DialogPresenter
    private let importChooser: LibraryWindowController.ImportChooser?
    private let replyToTermination: (Bool) -> Void
    private let revealLibraryURI: (URL) -> Void
    private let folderChooser: SettingsWindowController.FolderChooser
    private let forgetAllConfirmation: SettingsWindowController.ForgetAllConfirmation
    private let makeNotifier: (() -> UserNotificationNotifier)?
    private let activateApplication: () -> Void
    private let ownWindowIsActive: (() -> Bool)?
    private let windowActivation: WindowActivationCoordinator
    private var panelController: PanelController?
    private(set) var pickerPresentation: PickerViewState?
    private var setupWindow: SetupWindowController?
    private(set) var settingsWindow: SettingsWindowController?
    private(set) var libraryWindow: LibraryWindowController?
    private(set) var onboardingWindow: OnboardingWindowController?
    private var focusTracker: WorkspaceFocusTracker?
    private var shortcuts: ShortcutService?
    private var deliverySettingsObserver: UUID?
    private var updateSettingsObserver: UUID?
    private var updateService: UpdateService?
    private var lastDelivery: LastDeliveryStore?
    private var repeatService: RepeatService?
    private var repeatBinding: RepeatBinding?
    private var repeatAccountGeneration: UInt64 = 0
    private var repeatAwaitingResult = false
    private(set) var repeatModel: RepeatModel?
    private(set) var repeatWindow: RepeatWindowController?
    private var statusItem: NSStatusItem?
    private(set) var pickerModel: PickerModel?
    private(set) var libraryBrowserModel: LibraryBrowserModel?
    private(set) var editorModel: EditorModel?
    private(set) var importModel: ImportModel?
    private var promptEditing: PromptEditingService?
    private var terminationPending = false
    private var terminationDrained = false
    private var libraryTransition: UUID?
    private var syncTransitionMessage: String?
    private var syncSwitchOutcome: LibrarySwitchResult?
    private var editorSwitchRefused = false
    private(set) var setupModel: SetupModel?
    private(set) var settingsModel: SettingsModel?
    private(set) var generalSettingsModel: GeneralSettingsModel?
    private(set) var shortcutsSettingsModel: ShortcutsSettingsModel?
    private(set) var rememberedValuesSettingsModel: RememberedValuesSettingsModel?
    private(set) var libraryStatusModel: LibraryStatusModel?
    private(set) var onboardingModel: OnboardingModel?
    private var libraryStatusObserver: UUID?
    private var libraryMenuItems: [NSMenuItem] = []
    private var isShutDown = false
    private var onboardingStarted = false
    private var presentedOnboardingStep: OnboardingModel.Step?
    private var notifier: UserNotificationNotifier?
    private var dataFiles: FileStore?
    private(set) var providerSettingsService: ProviderSettingsService?
    private(set) var assistantService: AssistantService?
    private var values: ValuesStore?
    private var usage: UsageStore?
    private var fill: FillService?
    private var delivery: DeliveryService?
    private var libraryFiles: FileStore?
    private var library: LibraryService?
    private var index: PromptIndex?
    private(set) var syncComposition: MacSyncComposition?
    private(set) var syncIndexRefreshFailure: PromptEditingFailure?
    private var syncIndexRetryPending = false
    private var syncRecoveryWaiting = false
    private var syncStarted = false
    private var pendingSyncLibraryChoice: (directory: URL, choice: URL?)?
    private var inviteRoutingReady = false
    private var pendingInvite: SecretValue?
    private var watcher: LibraryWatcher?
    private var libraryGeneration: UInt64 = 0
    private var libraryStarted = false
    private var libraryWarningLogged = false
    private var log: LogSink?
    private let clock = SystemClock()

    // Native UI slices bind these graph-scoped models and retire their own
    // subscriptions when the library changes. Merely opening Account sends no HTTP.
    var accountModel: AccountModel? { libraryTransition == nil ? syncComposition?.account : nil }
    var inviteModel: InviteModel? { libraryTransition == nil ? syncComposition?.invites : nil }
    var groupManagementModel: GroupManagementModel? { libraryTransition == nil ? syncComposition?.groups : nil }
    var conflictModel: ConflictModel? { libraryTransition == nil ? syncComposition?.conflicts : nil }
    var syncStatusModel: SyncStatusModel? { syncComposition?.status }

    /// Hosted tests replace workspace/AX access while exercising the real UI wiring.
    init(libraryRoot: URL? = nil, dataRoot: URL? = nil,
         legacyFirstRun: LegacyFirstRun? = nil, recordLegacySetup: (() -> Void)? = nil,
         launchURI: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
         backgroundWork: BackgroundWork = DispatchBackgroundWork(),
         httpTransport: HTTPTransporting = URLSessionHTTPTransport(),
         secrets: SecretStore? = nil,
         clipboard: Clipboard = PasteboardClipboard(),
         makeHotkeyBackend: (() -> MacHotkeyBackend)? = nil,
         pasteInjectors: [PasteInjector]? = nil,
         currentReleaseVersion: String? = MacReleaseVersion.read(from: Bundle.main.infoDictionary ?? [:]),
         updateClock: WallClock = SystemClock(), releasePage: ReleasePageOpening? = nil,
         makeUpdateScheduler: (MainThread) -> MacUpdateScheduler = { MacUpdateScheduler(mainThread: $0) },
         makeSelfTestTarget: @escaping () -> SelfTestTarget = { TextFieldSelfTestTarget() },
         editorDialog: @escaping LibraryWindowController.DialogPresenter = LibraryWindowController.presentEditorDialog,
         importChooser: LibraryWindowController.ImportChooser? = nil,
         replyToTermination: @escaping (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) },
         revealLibrary: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
         folderChooser: @escaping SettingsWindowController.FolderChooser = SettingsWindowController.chooseFolder,
         forgetAllConfirmation: @escaping SettingsWindowController.ForgetAllConfirmation = SettingsWindowController.confirmForgetAll,
         makeNotifier: (() -> UserNotificationNotifier)? = nil,
         setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { _ = NSApp.setActivationPolicy($0) },
         activateApplication: @escaping () -> Void = { NSApp.activate() },
         ownWindowIsActive: (() -> Bool)? = nil,
         makeFocusTracker: @escaping (MainThread, MonkeysPawCore.Scheduler) -> WorkspaceFocusTracker = {
        WorkspaceFocusTracker(mainThread: $0, scheduler: $1)
    }, scheduler: MonkeysPawCore.Scheduler = DispatchScheduler(),
         makePanelController: @escaping (MainThread, MonkeysPawCore.Scheduler, LogSink) -> PanelController = {
             PanelController(mainThread: $0, scheduler: $1, log: $2)
         }, makeFileWatcher: @escaping (URL, LogSink) throws -> FileStoreWatcher = {
             try RootedFileWatcher(root: $0, log: $1)
         }) {
        precondition((libraryRoot == nil) == (dataRoot == nil), "Inject libraryRoot and dataRoot together")
        self.makeFocusTracker = makeFocusTracker
        self.scheduler = scheduler
        self.makePanelController = makePanelController
        self.makeFileWatcher = makeFileWatcher
        let mainThread = DispatchMainThread()
        self.mainThread = mainThread
        let injected = libraryRoot != nil && dataRoot != nil
        rootsAreInjected = injected
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultRoot = libraryRoot ?? home.appendingPathComponent("Documents/MonkeysPaw", isDirectory: true)
        defaultLibraryDirectory = defaultRoot
        libraryDirectory = defaultRoot
        dataDirectory = dataRoot ?? home.appendingPathComponent(
            "Library/Application Support/" + AppIdentity.macOSBundleID, isDirectory: true)
        self.launchURI = launchURI
        self.backgroundWork = backgroundWork
        self.httpTransport = httpTransport
        self.currentReleaseVersion = currentReleaseVersion
        self.updateClock = updateClock
        self.releasePage = releasePage ?? WorkspaceReleasePageOpener()
        updateScheduler = makeUpdateScheduler(mainThread)
        self.makeSelfTestTarget = makeSelfTestTarget
        if let secrets { self.secrets = secrets }
        else if Self.isRunningTests { self.secrets = UnavailableSecretStore() }
        else { self.secrets = KeychainSecretStore() }
        self.clipboard = clipboard
        self.makeHotkeyBackend = makeHotkeyBackend
        self.pasteInjectors = pasteInjectors
        self.editorDialog = editorDialog
        self.importChooser = importChooser
        self.replyToTermination = replyToTermination
        revealLibraryURI = revealLibrary
        self.folderChooser = folderChooser
        self.forgetAllConfirmation = forgetAllConfirmation
        self.makeNotifier = makeNotifier
        self.activateApplication = activateApplication
        self.ownWindowIsActive = ownWindowIsActive
        windowActivation = WindowActivationCoordinator(mainThread: mainThread,
            setPolicy: setActivationPolicy, activate: activateApplication)
        // Injected graphs never read or write the user's legacy preferences.
        let isolated = injected || Self.isRunningTests
        self.legacyFirstRun = legacyFirstRun ?? (isolated ? .setupNotPresented
            : (UserDefaults.standard.bool(forKey: "hasShownDeliverySetup") ? .setupPresented : .setupNotPresented))
        if let recordLegacySetup { self.recordLegacySetup = recordLegacySetup }
        else if isolated { self.recordLegacySetup = {} }
        else { self.recordLegacySetup = { UserDefaults.standard.set(true, forKey: "hasShownDeliverySetup") } }
        super.init()
    }

    deinit {
        tearDown()
        if let libraryStatusObserver { libraryStatusModel?.removeObserver(libraryStatusObserver) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The hosted application's default delegate has production roots.
        // Only explicitly injected test graphs may access the filesystem.
        guard !isShutDown, !Self.isRunningTests || rootsAreInjected else { return }
        defer {
            inviteRoutingReady = true
            presentPendingInvite()
        }
        let log = CompositeLogSink(
            sinks: [OSLogSink(), FileLogSink(dataDirectory: dataDirectory)],
            policy: LogLevelPolicy(environmentValue: ProcessInfo.processInfo.environment["MONKEYSPAW_LOG"]))
        self.log = log
        compose(log: log)
        startLibrary()
        composeOnboarding()
        // Graph construction is safe under hosted XCTest. Native registrations,
        // status items, first-run UI and prompts belong beyond this gate.
        guard !Self.isRunningTests else { return }

        if currentReleaseVersion.flatMap(ReleaseVersion.init) != nil {
            updateService?.startAutomaticChecks()
        }
        focusTracker?.startTrackingActivations()
        startShortcuts()

        installMainMenu()
        installStatusItem()
        log.write(.info, "Application started")

        startSync()
        beginOnboarding()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // AppKit can deliver this before didFinishLaunching. Preserve the URI
        // text; Core alone decodes and validates it, without redeeming it.
        guard !Self.isRunningTests || rootsAreInjected else { return }
        let link = urls.last { $0.scheme?.lowercased() == "monkeyspaw" }.map { SecretValue($0.absoluteString) }
        guard let link else { return }
        mainThread.run { [weak self] in
            guard let self, !self.isShutDown else { return }
            self.pendingInvite = link
            self.presentPendingInvite()
        }
    }

    private func presentPendingInvite() {
        guard inviteRoutingReady, !isShutDown, let settingsWindow, let link = pendingInvite else { return }
        pendingInvite = nil
        cancelPickerForOwnedWindow()
        var input = link.withValue { $0 }
        settingsWindow.openInvite(&input)
    }

    func applicationWillTerminate(_ notification: Notification) { tearDown() }

    private var isEditorBusy: Bool {
        guard let state = editorModel?.state else { return false }
        return state.isDirty || state.status == .saving || state.status == .commandRunning || state.pendingDecision != nil
            || !state.queuedActions.isEmpty
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShutDown, !terminationDrained else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        guard libraryTransition == nil else { return .terminateCancel }
        if !isEditorBusy, importModel?.state.isImporting != true,
           (syncComposition?.retireIfIdle() ?? .stopped) == .stopped { return .terminateNow }
        terminationPending = true
        if let editor = editorModel, isEditorBusy {
            libraryWindow?.show()
            editor.request(.quit) { [weak self] result in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isShutDown, self.terminationPending else { return }
                    if result == .allowed { self.drainForTermination() }
                    else { self.terminationPending = false; self.replyToTermination(false) }
                }
            }
        } else { DispatchQueue.main.async { [weak self] in self?.drainForTermination() } }
        return .terminateLater
    }

    private func drainForTermination() {
        guard !isShutDown, terminationPending else { return }
        libraryWindow?.presentation.retireAssistant()
        if importModel?.state.isImporting != true, (syncComposition?.retireIfIdle() ?? .stopped) == .stopped {
            terminationPending = false
            terminationDrained = true
            replyToTermination(true)
            return
        }
        let wasAvailable = pickerModel?.libraryAvailable == true
        pickerModel?.libraryAvailable = false
        libraryWindow?.presentation.setLibraryAvailable(false)
        let graph = syncComposition
        graph?.retireModels()
        let main = mainThread
        let work = backgroundWork
        Task.detached { [weak self] in
            let result: SyncStopResult
            do {
                try await work.drainSubmittedWork()
                result = await graph?.drainAndRetire() ?? .stopped
            } catch { result = .busy }
            main.run { [weak self] in
                guard let self, !self.isShutDown, self.terminationPending else { return }
                self.terminationPending = false
                self.terminationDrained = result == .stopped
                if result != .stopped {
                    // A cancelled worker barrier has not drained model admissions.
                    if result == .recoveryRequired { graph?.restoreModelsAfterFailedDrain() }
                    self.syncIndexRetryPending = false
                    let available = result != .busy && wasAvailable
                        && (try? (self.libraryFiles as? RootedFileStore)?.requireRoot()) != nil
                    self.pickerModel?.libraryAvailable = available
                    self.libraryWindow?.presentation.setLibraryAvailable(available)
                    self.syncTransitionMessage = result == .busy ? "Background work could not finish before you quit."
                        : "Local sync recovery must finish before you quit."
                    self.log?.write(.warning, "Quit refused; background work or local sync recovery is unfinished")
                    if result == .recoveryRequired, self.syncStarted { graph?.startup() }
                }
                self.replyToTermination(result == .stopped)
            }
        }
    }

    private func tearDown() {
        guard !isShutDown else { return }
        isShutDown = true
        repeatModel?.deactivate()
        repeatService?.cancel()
        repeatWindow?.tearDown()
        if let deliverySettingsObserver { settingsModel?.removeObserver(deliverySettingsObserver) }
        deliverySettingsObserver = nil
        if let updateSettingsObserver { settingsModel?.removeObserver(updateSettingsObserver) }
        updateSettingsObserver = nil
        updateScheduler.stop()
        updateService?.stop()
        delivery?.invalidatePendingPresentation()
        delivery?.shutdown()
        pendingInvite = nil
        let graph = syncComposition
        graph?.retireModels()
        Task.detached { _ = await graph?.drainAndRetire() }
        watcher?.stop()
        libraryWindow?.presentation.retireAssistant()
        libraryBrowserModel?.deactivate()
        editorModel?.deactivate()
        promptEditing?.deactivate()
        importModel?.deactivate()
        libraryWindow?.tearDown()
        pickerPresentation?.syncStatus?.retire()
        pickerModel?.onChange = nil
        onboardingStarted = false
        presentedOnboardingStep = nil
        setupWindow?.tearDown()
        onboardingWindow?.tearDown()
        settingsWindow?.tearDown()
        windowActivation.tearDown()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isShutDown else { return }
        // Returning from System Settings refreshes grants and registration state.
        setupModel?.refresh()
        shortcutsSettingsModel?.refresh()
        generalSettingsModel?.refresh()
        onboardingModel?.refresh()
        libraryWindow?.refreshDialogsAfterVisibilityChange()
    }

    func applicationDidUnhide(_ notification: Notification) {
        guard !isShutDown else { return }
        libraryWindow?.refreshDialogsAfterVisibilityChange()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isShutDown, let onboardingModel else { return false }
        // This launcher request owns routing the refreshed step, even if a
        // model publication occurs inline while refreshing.
        onboardingStarted = false
        onboardingModel.refresh()
        onboardingStarted = true
        if setupWindow?.isVisible == true {
            showSetup()
            return false
        }

        let step = onboardingModel.state.step
        presentedOnboardingStep = step
        switch step {
        case .setup: showSetup()
        case .libraryFolder, .seedOffer, .tour: showOnboarding()
        case .complete: pickerModel?.open()
        }
        return false
    }

    private func compose(log: LogSink) {
        let mainThread = self.mainThread
        let scheduler = self.scheduler
        let backgroundWork = self.backgroundWork
        let focus = makeFocusTracker(mainThread, scheduler)
        let panel = makePanelController(mainThread, scheduler, log)
        let hotkeys = makeHotkeyBackend?() ?? CarbonHotkeyBackend()
        let session = MacSessionProbe()
        let clipboard = self.clipboard
        let notifier: UserNotificationNotifier
        if let makeNotifier {
            notifier = makeNotifier()
        } else if Self.isRunningTests {
            notifier = UserNotificationNotifier(requestAuthorization: { _, completion in completion(false) })
        } else {
            notifier = UserNotificationNotifier()
        }
        self.notifier = notifier
        let data: FileStore
        do { data = try RootedFileStore(root: dataDirectory) }
        catch {
            data = UnavailableFileStore()
            log.write(.warning, "App data unavailable; settings, remembered values and usage cannot be saved")
        }
        let settings = SettingsService(store: SettingsStore(files: data, legacyFirstRun: legacyFirstRun))
        let settingsModel = SettingsModel(settings: settings)
        self.settingsModel = settingsModel
        let updates = UpdateService(transport: httpTransport, currentVersion: currentReleaseVersion,
            settings: settings, stateStore: UpdateStateStore(files: data), clock: updateClock,
            scheduler: updateScheduler, mainThread: mainThread, releasePage: releasePage)
        updateService = updates
        let updateEligible = !Self.isRunningTests && currentReleaseVersion.flatMap(ReleaseVersion.init) != nil
        updateScheduler.setEnabled(updateEligible && settingsModel.allowsAutomaticUpdateChecks)
        updateSettingsObserver = settingsModel.addObserver { [weak updates, weak updateScheduler] snapshot, _ in
            updateScheduler?.setEnabled(updateEligible && snapshot.allowsAutomaticUpdateChecks)
            updates?.refreshAutomaticPolicy()
        }
        let failureCache = SessionPasteFailureCache()
        let delivery = DeliveryService(panel: panel, focus: focus, clipboard: clipboard,
                                       injectors: pasteInjectors ?? [CGEventPasteInjector(), AppleScriptPasteInjector()],
                                       notifier: notifier,
                                       session: session, scheduler: scheduler,
                                       mainThread: mainThread, failureCache: failureCache,
                                       clipboardRestore: settingsModel.isReadOnly ? .off
                                           : settingsModel.deliveryPreferences.clipboardRestore)
        deliverySettingsObserver = settingsModel.addObserver { [weak delivery] snapshot, _ in
            delivery?.setClipboardRestore(snapshot.isReadOnly ? .off : snapshot.document.delivery.clipboardRestore)
        }
        let shortcuts = ShortcutService(backend: hotkeys, scheduler: scheduler, mainThread: mainThread,
                                       settings: settings)
        let target = makeSelfTestTarget()
        let selfTest = SelfTest(target: target, delivery: delivery, session: session,
                                scheduler: scheduler, mainThread: mainThread)
        let probe = MacSetupProbe(hotkeys: hotkeys, mainThread: mainThread)
        let setup = SetupService(probe: probe, session: session, shortcuts: shortcuts,
                                 selfTest: selfTest, mainThread: mainThread)
        let values = ValuesStore(files: data)
        let usage = UsageStore(files: data, clock: clock)
        lastDelivery = LastDeliveryStore(files: data)
        let providers = ProviderSettingsService(store: ProviderSettingsStore(files: data, log: log),
            secrets: secrets, log: log)
        providerSettingsService = providers
        // Clients inherit Limits caps/deadlines; construction sends no requests.
        let assistant = AssistantService(providerSettings: providers,
            anthropic: AnthropicClient(transport: httpTransport),
            openAICompatible: OpenAIClient(transport: httpTransport, providerState: ProviderStateStore(files: data)),
            work: backgroundWork, main: mainThread)
        assistantService = assistant
        dataFiles = data
        self.values = values
        self.usage = usage
        self.delivery = delivery
        fill = FillService(values: values, clipboard: clipboard, clock: clock, timeZone: { TimeZone.current })
        panelController = panel
        focusTracker = focus
        self.shortcuts = shortcuts
        let setupModel = SetupModel(setup: setup)
        self.setupModel = setupModel
        setupWindow = SetupWindowController(model: setupModel)
        setupWindow?.onClose = { [weak self] in self?.presentPendingOnboarding() }
        panel.onHide = { [weak self] reason in
            self?.pickerPresentation?.didHide()
            switch reason {
            case .delivery: focus.prepareForRestore(.delivery)
            case .dismissal: focus.prepareForRestore(.dismissal)
            case .blur: focus.prepareForRestore(.blur)
            }
        }

        let choice = settingsModel.libraryFolderPath
        libraryDirectory = choice.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultLibraryDirectory
        let files: FileStore
        var libraryAvailable = true
        do {
            let configured = (data as? RootedFileStore).map { SyncAccountStore(files: data, operations: $0).hasConfiguredAccount } ?? false
            // A configured default that vanished is unavailable, never an
            // automatically recreated empty tree with old deletion baselines.
            if choice == nil, configured { try RootedFileStore(root: libraryDirectory).requireRoot() }
            files = try prepareLibrary(at: libraryDirectory, location: choice == nil ? .platformDefault : .chosen)
        } catch {
            if error as? FileStoreError == .notFound, let rooted = try? RootedFileStore(root: libraryDirectory) { files = rooted }
            else { files = UnavailableFileStore() }
            libraryAvailable = false
            warnAboutLibrary(error as? FileStoreError)
        }
        installLibrary(files: files, availability: libraryAvailable)
        let general = GeneralSettingsModel(settings: settingsModel,
            library: SettingsLibraryLocation(owner: self), mainThread: mainThread)
        let shortcutSettings = ShortcutsSettingsModel(shortcuts: shortcuts, setup: setup)
        let rememberedValues = RememberedValuesSettingsModel(control: SettingsRememberedValuesControl(owner: self),
                                                            mainThread: mainThread)
        let deliverySettings = DeliverySettingsModel(settings: settingsModel, delivery: delivery,
            setup: setup, mainThread: mainThread)
        deliverySettings.onOpenSetup = { [weak self] in self?.showSetup() }
        let updateSettings = UpdateSettingsModel(settings: settingsModel, updates: updates, mainThread: mainThread)
        generalSettingsModel = general
        shortcutsSettingsModel = shortcutSettings
        rememberedValuesSettingsModel = rememberedValues
        settingsWindow = SettingsWindowController(general: general, shortcuts: shortcutSettings,
            rememberedValues: rememberedValues, delivery: deliverySettings, updates: updateSettings,
            forgetAllConfirmation: forgetAllConfirmation,
            mainThread: mainThread, activation: windowActivation, folderChooser: folderChooser,
            openSetup: { [weak self] in self?.showSetup() },
            makeAssistant: {
                AssistantSettingsModel(settings: providers, assistant: assistant,
                    work: backgroundWork, mainThread: mainThread)
            }, onProviderChange: { [weak self] in self?.libraryWindow?.presentation.assistantProfileChanged() },
            makeAccount: { [weak self] in
                guard let self, !self.isShutDown else { return nil }
                return self.accountModel
            }, makeInvite: { [weak self] in
                guard let self, !self.isShutDown else { return nil }
                return self.inviteModel
            }, makeGroups: { [weak self] in
                guard let self, !self.isShutDown else { return nil }
                return self.groupManagementModel
            })
        settingsWindow?.presentation.librarySwitchMessage = { [weak self] in
            guard let self else { return nil }
            if let message = self.syncTransitionMessage { return message }
            if self.syncSwitchOutcome == .switched { return nil }
            if self.editorSwitchRefused {
                return self.isEditorBusy ? EditorStrings.librarySwitchRefused : nil
            }
            return GeneralSettingsStrings.message(for: .deliveryInFlight)
        }
    }

    private func composeOnboarding() {
        guard let settingsModel, let notifier else { return }
        // Startup includes watcher/rebuild health, not just an openable folder.
        let status = LibraryStatusModel(initialState: pickerModel?.libraryAvailable == true
            ? .available : .unavailableAtStartup, mainThread: mainThread,
            notifyStartupUnavailable: { notifier.libraryUnavailable() })
        libraryStatusModel = status
        libraryStatusObserver = status.addObserver { [weak self] _ in self?.updateLibraryMenuItems() }
        let onboarding = OnboardingModel(settings: settingsModel, library: SettingsLibraryLocation(owner: self),
            status: status, mainThread: mainThread, isLibraryEmpty: { [weak self] in
                guard let library = self?.library else { throw LibraryError.operationFailed }
                return try library.entries().isEmpty
            }, hasConfiguredSyncServer: { [weak self] in
                self?.syncComposition?.accounts.hasConfiguredAccount == true
            }, seedIfEmpty: { [weak self] in
                guard let self else { throw LibraryError.operationFailed }
                return try self.seedCurrentLibrary()
            })
        onboardingModel = onboarding
        let window = OnboardingWindowController(model: onboarding, activeLibraryPath: libraryDirectory.path,
            defaultLibraryPath: defaultLibraryDirectory.path, mainThread: mainThread,
            activateApplication: activateApplication, folderChooser: folderChooser,
            openSettings: { [weak self] in self?.showSettings() },
            openInvite: { [weak self] in self?.showAccount() })
        window.onStateChange = { [weak self] in self?.presentPendingOnboarding() }
        window.onClose = { [weak self] in
            guard let self, !self.isShutDown else { return }
            self.presentedOnboardingStep = nil
        }
        onboardingWindow = window
    }

    private func seedCurrentLibrary() throws -> SeedSummary {
        guard let library, let index, pickerModel?.libraryAvailable == true else {
            throw LibraryError.operationFailed
        }
        // Show successful and partial copies immediately; the watcher still
        // handles external changes and root loss through the current generation.
        defer {
            do { try index.rebuild() }
            catch { log?.write(.warning, "Starter prompt index refresh failed") }
            syncComposition?.sync.localSave()
        }
        return try SeedService(library: library).seedIfEmpty()
    }

    /// Hosted launch constructs models without opening windows. Tests explicitly
    /// enter this same launch flow with isolated roots and injected drivers.
    func beginOnboarding() {
        guard !isShutDown else { return }
        onboardingModel?.refresh()
        onboardingStarted = true
        presentPendingOnboarding()
    }

    private func presentPendingOnboarding() {
        guard !isShutDown, onboardingStarted, let onboardingModel else { return }
        let step = onboardingModel.state.step
        // Setup records progress when shown, but remains the first screen until
        // you close it. Its close callback runs after native window teardown.
        guard setupWindow?.isVisible != true else { return }
        guard presentedOnboardingStep != step else { return }
        presentedOnboardingStep = step
        switch step {
        case .setup: showSetup()
        case .libraryFolder, .seedOffer, .tour:
            guard onboardingWindow?.window?.isVisible != true else { return }
            showOnboarding()
        case .complete: break // Keep a seed result visible until Done.
        }
    }

    private func showOnboarding() {
        focusTracker?.cancelPendingRestoration()
        panelController?.cancelForOwnedWindow()
        pickerModel?.dismiss()
        panelController?.hide()
        delivery?.invalidatePendingPresentation()
        onboardingWindow?.show()
    }

    /// UI-thread composition intent for the later General/onboarding views.
    /// A failed settings write keeps the new graph for this session (§5.1).
    /// libraryUnavailable leaves the new graph installed but degraded, as at
    /// launch, without saving the choice; another switch or a relaunch recovers.
    func switchLibrary(to url: URL?) -> LibrarySwitchResult {
        assert(Thread.isMainThread, "Library replacement is main-thread-confined")
        guard !isShutDown, let pickerModel, let settingsModel else { return .libraryUnavailable(.ioFailure) }
        guard libraryTransition == nil, !terminationPending else { return .syncBusy }
        syncTransitionMessage = nil
        syncSwitchOutcome = nil
        editorSwitchRefused = false
        if isEditorBusy {
            editorSwitchRefused = true
            return .editorBusy
        }
        guard pickerModel.state != .delivering else { return .deliveryInFlight }
        pickerModel.dismiss()

        let directory = url ?? defaultLibraryDirectory
        let files: FileStore
        do { files = try prepareLibrary(at: directory, location: url == nil ? .platformDefault : .chosen) }
        catch { return .invalidTarget(error as? FileStoreError ?? .ioFailure) }

        do { try retireRepeat(replacementRoot: directory) }
        catch {
            showRepeatResult(.unavailable(.invalidationFailed))
            return .repeatInvalidationFailed
        }
        if let graph = syncComposition {
            let result = graph.retireIfIdle()
            if result != .stopped || importModel?.state.isImporting == true {
                drainForLibrarySwitch(to: directory, files: files, choice: url, graph: graph)
                return .syncBusy
            }
        }
        return replaceLibrary(to: directory, files: files, choice: url, settings: settingsModel)
    }

    private func drainForLibrarySwitch(to directory: URL, files: FileStore, choice: URL?, graph: MacSyncComposition) {
        let id = UUID()
        libraryTransition = id
        syncTransitionMessage = "Sync is finishing before the library changes."
        pickerModel?.libraryAvailable = false
        libraryWindow?.presentation.setLibraryAvailable(false)
        libraryWindow?.presentation.retireAssistant()
        graph.retireModels()
        let main = mainThread
        let work = backgroundWork
        Task.detached { [weak self] in
            let result: SyncStopResult
            do {
                try await work.drainSubmittedWork()
                result = await graph.drainAndRetire()
            } catch { result = .busy }
            main.run { [weak self] in
                guard let self, !self.isShutDown, self.libraryTransition == id, let settings = self.settingsModel else { return }
                self.libraryTransition = nil
                if result == .stopped {
                    self.syncTransitionMessage = nil
                    let outcome = self.replaceLibrary(to: directory, files: files, choice: choice, settings: settings)
                    self.syncSwitchOutcome = outcome
                    self.syncTransitionMessage = outcome == .syncBusy ? "Sync is preparing the selected library."
                        : GeneralSettingsStrings.message(for: outcome.outcome)
                } else {
                    if result == .recoveryRequired { graph.restoreModelsAfterFailedDrain() }
                    self.syncIndexRetryPending = false
                    self.syncTransitionMessage = result == .busy ? "Background work could not finish before you change libraries."
                        : "Local sync recovery must finish before you change libraries."
                    let available = result != .busy && (try? (self.libraryFiles as? RootedFileStore)?.requireRoot()) != nil
                    self.pickerModel?.libraryAvailable = available
                    self.libraryWindow?.presentation.setLibraryAvailable(available)
                    self.log?.write(.warning, "Library replacement refused; background work or local sync recovery is unfinished")
                    if result == .recoveryRequired, self.syncStarted { graph.startup() }
                }
                self.generalSettingsModel?.refresh()
                self.settingsWindow?.presentation.objectWillChange.send()
                self.onboardingModel?.refresh()
            }
        }
    }

    private func replaceLibrary(to directory: URL, files: FileStore, choice: URL?, settings: SettingsModel) -> LibrarySwitchResult {
        repeatModel?.deactivate()
        repeatWindow?.tearDown()
        repeatWindow = nil

        // Delivery's queue can still be finishing a guarded dismissal or Setup
        // self-test. Hide the old view now, before replacing its native root.
        panelController?.hide()
        delivery?.invalidatePendingPresentation()
        libraryGeneration &+= 1
        // Stop before releasing: FSEvents marshals teardown via its serial queue.
        watcher?.stop()
        watcher = nil
        libraryWindow?.presentation.retireAssistant()
        libraryBrowserModel?.deactivate()
        editorModel?.deactivate()
        promptEditing?.deactivate()
        importModel?.deactivate()
        pickerModel?.onChange = nil
        pickerPresentation = nil
        self.pickerModel = nil
        libraryDirectory = directory
        onboardingWindow?.updateLibraryPaths(active: directory.path, default: defaultLibraryDirectory.path)
        libraryStarted = false
        libraryWarningLogged = false
        syncIndexRefreshFailure = nil
        syncIndexRetryPending = false
        syncRecoveryWaiting = false
        pendingSyncLibraryChoice = nil
        installLibrary(files: files, availability: true)
        let startup = startLibrary()
        libraryStatusModel?.libraryReplaced(available: self.pickerModel?.libraryAvailable == true)
        if case .failure(let error) = startup {
            if syncRecoveryWaiting, syncStarted, syncComposition?.accounts.hasConfiguredAccount == true {
                pendingSyncLibraryChoice = (directory, choice)
                startSync()
                return .syncBusy
            }
            return .libraryUnavailable(error)
        }

        // SettingsModel forwards to the shared SettingsService and retains its
        // typed error. Never persist a choice whose watcher/rebuild failed.
        if let choice { settings.setLibraryFolder(choice.path) }
        else { settings.clearLibraryFolder() }
        if syncStarted { startSync() }
        if let error = settings.error { return .settingsNotSaved(error) }
        return .switched
    }

    private func prepareLibrary(at directory: URL, location: LibraryLocation) throws -> RootedFileStore {
        guard directory.isFileURL, directory.path.utf8.first == UInt8(ascii: "/"),
              !directory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw FileStoreError.invalidRoot
        }
        do {
            // RootedFileStore accepts canonical OS ancestors (such as /var).
            // Reject a chosen symlink itself. The default keeps resolving, so a
            // default folder linked into a synced directory still loads.
            if location == .chosen,
               let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw FileStoreError.outsideRoot
            }
            let files = try RootedFileStore(root: directory)
            if location == .platformDefault { try files.createRoot() }
            try files.requireRoot()
            try files.pinRoot()
            _ = try files.listFiles()
            return files
        } catch let error as FileStoreError { throw error }
        catch { throw FileStoreError.ioFailure }
    }

    private func installLibrary(files: FileStore, availability initialAvailability: Bool) {
        guard let data = dataFiles, let values, let usage, let fill, let delivery,
              let panel = panelController, let focus = focusTracker, let log else { return }
        let generation = libraryGeneration
        let isCurrent: () -> Bool = { [weak self] in
            guard let self else { return false }
            return !self.isShutDown && self.libraryGeneration == generation
        }
        // Check inside the UI hop, not before queueing: an old index, snapshot
        // or view publish may already be waiting on DispatchQueue.main.
        let libraryMain = LibraryMainThread(main: mainThread, isCurrent: isCurrent)
        let library = LibraryService(library: files, data: data, clock: clock,
            entropy: SystemEntropy(), keyedStores: [values, usage])
        syncComposition = composeSync(library: library, files: files, data: data, main: libraryMain)
        let requiresRootRecovery = syncComposition.map {
            $0.rootIssue != nil && ($0.accounts.hasConfiguredAccount || $0.states.requiresRootProof(for: libraryDirectory.path))
        } ?? false
        let availability = initialAvailability && !requiresRootRecovery
        let index = PromptIndex(service: library, usage: usage, clock: clock)
        let editing = PromptEditingService(library: library, index: index, work: backgroundWork, main: libraryMain)
        let editor = EditorModel(editing: editing, clock: clock, timeZone: { TimeZone.current }, main: libraryMain)
        let importSources = MacImportSourceReader()
        let importer = ImportModel(service: ImportService(library: library, sources: importSources,
            work: backgroundWork, main: libraryMain))
        let imports = LibraryImportViewState(model: importer, available: availability, main: libraryMain,
            prepare: { [backgroundWork] urls, done in
                backgroundWork.run { done(importSources.requests(for: urls)) }
            }, openImported: { [weak self] path in
                guard isCurrent(), let self,
                      let entry = index.search("").first(where: { $0.relativePath.utf8.elementsEqual(path.utf8) })?.entry
                else { return false }
                self.libraryWindow?.presentation.openPrompt(LibraryPromptSelection(identity: entry.identity,
                    relativePath: RelativePath(entry.relativePath)))
                return true
            })
        imports.onAvailabilityChange = { [weak self] in self?.updateLibraryMenuItems() }
        var previousEditorStatus = editor.state.status
        editor.onChange = { [weak self, weak editor] in
            guard isCurrent(), let self, let editor else { return }
            let previous = previousEditorStatus
            previousEditorStatus = editor.state.status
            if previous == .saving, editor.state.status == .saved { self.syncComposition?.sync.localSave() }
            if previous == .commandRunning, editor.state.status != .commandRunning {
                if case .failed = editor.state.status {} else { self.syncComposition?.sync.localSave() }
            }
            if self.editorSwitchRefused { self.settingsWindow?.presentation.objectWillChange.send() }
        }
        let repeatService = composeRepeat(library: library, index: index, isCurrent: isCurrent)
        let model = PickerModel(index: index, fill: fill, delivery: delivery, main: libraryMain,
                                repeatService: repeatService)
        let browser = LibraryBrowserModel(index: index, usage: usage, favorites: library, main: libraryMain, editor: editor)
        model.libraryAvailable = availability
        let makeSyncStatus: (SyncStatusViewState.Surface) -> SyncStatusViewState = { [weak self, weak index] surface in
            SyncStatusViewState(surface: surface, main: libraryMain, makeModel: { [weak self] in
                guard isCurrent() else { return nil }
                return self?.syncStatusModel
            }, navigate: { [weak self] action in
                guard isCurrent() else { return }
                self?.showSyncDestination(action)
            }, openFile: { [weak self, weak index] path in
                guard isCurrent(), let self, self.pickerModel?.libraryAvailable == true,
                      let entry = index?.search("").first(where: { $0.relativePath.utf8.elementsEqual(path.string.utf8) })?.entry else { return }
                self.libraryWindow?.presentation.openPrompt(LibraryPromptSelection(identity: entry.identity, relativePath: path))
            })
        }
        let presentation = PickerViewState(model: model, mainThread: libraryMain, isCurrent: isCurrent,
            syncStatus: makeSyncStatus(.picker),
            openSetup: { [weak self] in self?.showSetup() },
            openSettings: { [weak self] in self?.showSettings() },
            requestedIntent: { [weak self] intent in
                guard isCurrent() else { return }
                self?.handle(intent)
            }, createPrompt: { [weak self] title in
                guard isCurrent() else { return }
                self?.createPrompt(titled: title)
            })
        panel.rootView = { [weak presentation] in
            guard isCurrent(), let presentation else { return AnyView(EmptyView()) }
            return AnyView(PickerView(presentation: presentation).id(ObjectIdentifier(presentation)))
        }
        panel.onCancel = { [weak model] in
            guard isCurrent() else { return }
            model?.dismiss()
        }
        panel.onEscape = { [weak model] in
            guard isCurrent() else { return }
            model?.escape()
        }
        panel.onShow = { [weak presentation] in
            guard isCurrent() else { return }
            presentation?.didShow()
        }
        panel.onKey = { [weak presentation, weak panel] event, kind in
            guard isCurrent() else { return false }
            if presentation?.route(event, fieldKind: kind) == true { return true }
            guard presentation?.model.state == .picker else { return false }
            return panel?.forwardTypingToSearch(event) ?? false
        }
        focus.onCapture = { [weak presentation] in
            guard isCurrent() else { return }
            presentation?.pasteTarget = Self.pasteTargetName(for: $0)
        }

        pickerPresentation = presentation
        pickerModel = model
        libraryFiles = files
        self.library = library
        self.index = index
        libraryBrowserModel = browser
        editorModel = editor
        importModel = importer
        promptEditing = editing
        let graphID = UUID()
        let assistantMain = mainThread
        let makeAssistant: LibraryViewState.AssistantFactory? = assistantService.map { assistant in
            { [weak editor, weak self] in
                AssistantModel(service: assistant, main: assistantMain, context: { [weak self, weak editor] in
                    AssistantContext(libraryID: graphID, profile: assistant.selectedProfile,
                        editor: editor?.assistantSnapshot,
                        access: isCurrent() && self?.pickerModel?.libraryAvailable == true
                            ? (editor?.assistantAccess ?? .privatePrompt) : .unavailable)
                })
            }
        }
        let conflictProvider: LibraryViewState.ConflictProvider = { [weak self] in
            guard isCurrent() else { return nil }
            return self?.conflictModel
        }
        if let libraryWindow {
            libraryWindow.rebind(to: browser, editor: editor, libraryPath: libraryDirectory.path, available: availability,
                imports: imports, makeAssistant: makeAssistant, conflictProvider: conflictProvider,
                syncStatus: makeSyncStatus(.library))
        } else {
            libraryWindow = LibraryWindowController(model: browser, editor: editor, libraryPath: libraryDirectory.path,
                available: availability, mainThread: mainThread, activation: windowActivation,
                presentDialog: editorDialog, imports: imports, makeAssistant: makeAssistant, scheduler: scheduler,
                conflictProvider: conflictProvider,
                syncStatus: makeSyncStatus(.library),
                importChooser: { [weak self] window, done in
                    guard let self else { done([]); return {} }
                    if let chooser = self.importChooser { return chooser(window, done) }
                    let imports = self.libraryWindow?.presentation.imports
                    return MacImportChooser.choose(in: window,
                        destinations: imports?.destinations.map(\.string) ?? [],
                        destination: imports?.destination.string ?? ImportStrings.defaultDestination,
                        selectDestination: { [weak imports] path in imports?.selectDestination(RelativePath(path)) },
                        done: done)
                },
                revealPrompt: { [weak self] path in
                    guard let self, (try? FileStorePath.validate(path.string)) != nil else { return }
                    self.revealLibraryURI(self.libraryDirectory.appendingPathComponent(path.string))
                },
                revealLibrary: { [weak self] in self?.revealLibrary() })
        }
        updateLibraryMenuItems()
        syncComposition?.onAccountChange = { [weak self] in
            guard isCurrent() else { return }
            self?.onboardingModel?.refresh()
        }
        syncComposition?.onStatusChange = { [weak self, weak index] state in
            guard isCurrent(), let self, let index, self.libraryTransition == nil,
                  state.phase == .idle, state.blockingIssue == nil else { return }
            self.refreshSyncIndex(index, generation: generation)
        }
        index.addObserver { [weak self, weak index] in
            libraryMain.run { [weak self, weak index] in
                guard let self, let index else { return }
                self.syncIndexRefreshFailure = index.lastSyncRefreshFailure
                if index.lastSyncRefreshFailure != nil { self.warnAboutLibrary() }
                if let conflict = self.syncComposition?.conflicts, !conflict.state.isBusy,
                   conflict.state.preview != nil { conflict.refresh() }
            }
        }
        if let raw = try? makeFileWatcher(libraryDirectory, log) {
            watcher = LibraryWatcher(watcher: raw, scheduler: scheduler)
        }
    }

    private func composeSync(library: LibraryService, files: FileStore, data: FileStore, main: MainThread) -> MacSyncComposition? {
        guard let libraryOperations = files as? RootedFileStore, let dataOperations = data as? RootedFileStore else { return nil }
        let states = SyncStateStore(files: data, operations: dataOperations)
        let accounts = SyncAccountStore(files: data, operations: dataOperations)
        let scheduler = DispatchSyncScheduler()
        do {
            let access = try GroupAccessService(library: library, states: states, accounts: accounts,
                libraryRoot: libraryDirectory.path)
            let sync = try SyncService(library: library, libraryOperations: libraryOperations,
                dataFiles: data, dataOperations: dataOperations, states: states, accounts: accounts,
                scheduler: scheduler, mainThread: main, clock: clock, entropy: SystemEntropy())
            let generation = libraryGeneration
            let repeatMain = mainThread
            let account = try SyncAccountService(sync: sync, accounts: accounts, secrets: secrets,
                transport: httpTransport, libraryRoot: libraryDirectory.path, beforeAccountChange: { [weak self] in
                    await withCheckedContinuation { completion in
                        // Always resume, even when the old graph's filtered UI port retires.
                        repeatMain.run { [weak self] in
                            completion.resume(returning: self?.prepareRepeatAccountChange(
                                generation: generation, accounts: accounts) ?? false)
                        }
                    }
                })
            let rootBinding = MacSyncRootBinding(data: dataOperations)
            let rootIssue: MacSyncRootIssue?
            do {
                let hasPending = try data.stamp(at: "sync/apply.json") != nil || data.stamp(at: "sync/push.json") != nil
                let mode: MacSyncRootBinding.Preparation = states.requiresRootProof(for: libraryDirectory.path) || hasPending
                    ? .recordedLibrary : .freshLibrary
                try rootBinding.prepare(library: libraryOperations, lexicalRoot: libraryDirectory.path, mode: mode)
                rootIssue = nil
            } catch { rootIssue = error as? MacSyncRootIssue ?? .metadataUnavailable }
            if rootIssue != nil { sync.rootHealthChanged(.unavailable) }
            return MacSyncComposition(sync: sync, accounts: accounts, states: states, access: access,
                accountService: account, inviteService: SyncInviteService(account: account, clipboard: clipboard),
                groupService: SyncGroupService(account: account, clipboard: clipboard),
                conflictService: ConflictResolutionService(sync: sync), scheduler: scheduler, main: main, rootIssue: rootIssue)
        } catch {
            scheduler.tearDown()
            log?.write(.warning, "Sync unavailable; saved metadata requires recovery")
            return nil
        }
    }

    /// Explicit seam for hosted tests and the later native Account flow.
    func startSync() {
        syncStarted = true
        syncComposition?.startup()
    }

    private func refreshSyncIndex(_ index: PromptIndex, generation: UInt64) {
        guard syncRecoveryWaiting || index.lastSyncRefreshFailure != nil, !syncIndexRetryPending else { return }
        syncIndexRetryPending = true
        let files = libraryFiles as? RootedFileStore
        backgroundWork.run { [weak self] in
            let refreshed: Bool
            do { try files?.requireRoot(); try index.rebuild(origin: .sync); refreshed = true }
            catch { refreshed = false }
            self?.mainThread.run { [weak self] in
                guard let self, !self.isShutDown, self.libraryGeneration == generation else { return }
                self.syncIndexRetryPending = false
                guard self.libraryTransition == nil, !self.terminationPending else { return }
                self.syncIndexRefreshFailure = index.lastSyncRefreshFailure
                guard refreshed, self.syncRecoveryWaiting else { return }
                self.syncRecoveryWaiting = false
                self.pickerModel?.libraryAvailable = true
                self.libraryWindow?.presentation.setLibraryAvailable(true)
                self.libraryStarted = false
                _ = self.startLibrary()
                self.libraryStatusModel?.update(self.pickerModel?.libraryAvailable == true ? .available : .lostWhileRunning)
                if self.pickerModel?.libraryAvailable == true, let pending = self.pendingSyncLibraryChoice,
                   pending.directory == self.libraryDirectory {
                    self.pendingSyncLibraryChoice = nil
                    if let choice = pending.choice { self.settingsModel?.setLibraryFolder(choice.path) }
                    else { self.settingsModel?.clearLibraryFolder() }
                    let outcome: LibrarySwitchResult = self.settingsModel?.error.map { .settingsNotSaved($0) } ?? .switched
                    self.syncSwitchOutcome = outcome
                    self.syncTransitionMessage = GeneralSettingsStrings.message(for: outcome.outcome)
                    self.generalSettingsModel?.refresh()
                }
            }
        }
    }

    @discardableResult
    private func startLibrary() -> Result<Void, FileStoreError> {
        guard !libraryStarted, let index, let pickerModel else { return .failure(.ioFailure) }
        libraryStarted = true
        guard pickerModel.libraryAvailable else { degradeLibrary(); return .failure(.ioFailure) }
        let generation = libraryGeneration
        let sync = syncComposition?.sync
        do {
            // The picker/index hook is installed before this first publish.
            try Self.startLibrary(index: index, watcher: watcher) { [weak self] update in
                if case .rootUnavailable = update { sync?.rootHealthChanged(.unavailable) }
                self?.mainThread.run { [weak self] in
                    guard let self, self.libraryGeneration == generation,
                          !self.isShutDown,
                          self.pickerModel?.libraryAvailable == true else { return }
                    switch update {
                    case .changes(let changes): self.apply(changes, to: index)
                    case .rootUnavailable(let error): self.degradeLibrary(error)
                    }
                }
            }
            // The root can disappear while the watcher takes its baseline;
            // listFiles treats a missing root as empty, which cannot prove health.
            try (libraryFiles as? RootedFileStore)?.requireRoot()
            return .success(())
        } catch {
            let failure = error as? FileStoreError ?? .ioFailure
            syncRecoveryWaiting = syncComposition != nil && (try? (libraryFiles as? RootedFileStore)?.requireRoot()) != nil
            degradeLibrary(failure)
            return .failure(failure)
        }
    }

    static func startLibrary(index: PromptIndex, watcher: LibraryWatcher?,
                             onChange: @escaping @Sendable (LibraryWatchUpdate) -> Void) throws {
        guard let watcher else { throw FileStoreError.ioFailure }
        // Arm before rebuilding: an external save cannot fall into a silent
        // baseline after the scan. AppKit batches return through MainThread,
        // so they cannot interleave with this synchronous initial rebuild.
        try watcher.start(onChange)
        try index.rebuild()
    }

    private func apply(_ changes: LibraryChangeSet, to index: PromptIndex) {
        do {
            // Health flushes pending reloads before its own signal. Protect the
            // cache when the physical root has vanished ahead of that flush.
            try (libraryFiles as? RootedFileStore)?.requireRoot()
        } catch {
            degradeLibrary(error as? FileStoreError)
            return
        }
        if let files = libraryFiles as? RootedFileStore {
            syncComposition?.filesChanged(changes, files: files, work: backgroundWork)
        }
        do { try index.apply(changes) }
        catch {
            // Warn after the outcome is known: the warning latches once, and a
            // failed rebuild must log its typed reason rather than a generic one.
            do {
                try index.rebuild()
                warnAboutLibrary()
            } catch {
                degradeLibrary(error as? FileStoreError)
            }
        }
    }

    private func warnAboutLibrary(_ error: FileStoreError? = nil) {
        guard !libraryWarningLogged else { return }
        libraryWarningLogged = true
        if let error {
            log?.write(.warning, "Library unavailable (\(error.rawValue)); keeping cached prompts")
            return
        }
        log?.write(.warning, "Library unavailable or refresh failed; keeping cached prompts")
    }

    private func degradeLibrary(_ error: FileStoreError? = nil) {
        if let files = libraryFiles as? RootedFileStore, (try? files.requireRoot()) == nil {
            syncComposition?.sync.rootHealthChanged(.unavailable)
        }
        watcher?.stop()
        pickerModel?.libraryAvailable = false
        libraryWindow?.presentation.setLibraryAvailable(false)
        libraryStatusModel?.update(.lostWhileRunning)
        warnAboutLibrary(error)
    }

    private func handle(_ intent: PickerModel.Intent) {
        guard pickerModel?.libraryAvailable == true else {
            pickerPresentation?.showStatus(Strings.libraryUnavailable)
            return
        }

        switch intent {
        case .openLibrary:
            showLibrary()
        case .edit(let identity, let path):
            guard (try? FileStorePath.validate(path)) != nil else {
                pickerPresentation?.showStatus(Strings.promptFileUnavailable)
                return
            }
            let selection = LibraryPromptSelection(identity: identity, relativePath: RelativePath(path))
            let generation = libraryGeneration
            mainThread.run { [weak self] in
                guard let self, !self.isShutDown, self.libraryGeneration == generation else { return }
                self.cancelPickerForOwnedWindow()
                self.libraryWindow?.show()
                self.libraryWindow?.presentation.openPrompt(selection)
            }
        }
    }

    private func createPrompt(titled title: String) {
        guard pickerModel?.libraryAvailable == true, let library, let index else { return }
        do {
            let entry = try library.createPrompt(titled: title, body: Strings.newPromptBody)
            let path = entry.relativePath
            syncComposition?.sync.localSave()
            do { try index.apply(LibraryChangeSet(created: [RelativePath(path)]), origin: .local) }
            catch { log?.write(.warning, "Prompt saved; immediate index refresh failed") }
            handle(.edit(identity: entry.identity, relativePath: path))
        } catch {
            pickerPresentation?.showStatus(Strings.createPromptFailed)
            log?.write(.warning, "Could not create a prompt; check library and app-data permissions")
        }
    }

    static func pasteTargetName(for target: DeliveryTarget?) -> String {
        guard let target, case .macOS(let pid, let bundleID) = target,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.bundleIdentifier == bundleID, let name = app.localizedName else { return Strings.noPasteTarget }
        return name
    }

    func installMainMenu() {
        // Editing commands need the responder chain even while accessory policy
        // hides the menu bar. MainMenu also registers Services, Window and Help.
        MainMenu.install()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(importFromMenu):
            return libraryWindow?.presentation.imports?.canImport == true
                && NSApp.keyWindow?.attachedSheet == nil
                && (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
                && libraryWindow?.presentation.fileCommandRequest == nil
                && libraryWindow?.presentation.editorState.pendingDecision == nil
                && libraryWindow?.presentation.isScopeDropPending == false
        case #selector(checkForUpdates(_:)):
            return currentReleaseVersion.flatMap(ReleaseVersion.init) != nil
                && settingsWindow?.presentation.updates.state.update?.isChecking != true
        case #selector(openHelp(_:)):
            return true
        case #selector(openLibraryFromMenu), #selector(showLibrary):
            return libraryStatusModel?.libraryAvailable == true
        case #selector(showPanel), #selector(showSetup), #selector(showSettings), #selector(repeatLast):
            return true
        default: return false
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "text.quote",
                                     accessibilityDescription: AppIdentity.displayName)
        item.button?.image?.isTemplate = true

        item.menu = makeStatusMenu()
        statusItem = item
    }

    /// Pure menu construction lets hosted tests exercise the real equivalents
    /// without creating a status item or installing native hotkeys.
    func makeStatusMenu() -> NSMenu {
        let menu = StatusMenu(title: "")
        // Status owns this item's availability; AppKit must not re-enable it
        // merely because its target implements the open action.
        menu.autoenablesItems = false
        let show = StatusShortcutMenuItem(title: Strings.showPanel, action: #selector(showPanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let repeatItem = StatusShortcutMenuItem(title: Strings.repeatLast, action: #selector(repeatLast), keyEquivalent: "")
        repeatItem.target = self
        menu.addItem(repeatItem)
        menu.onUpdate = { [weak self, weak show, weak repeatItem] _ in
            self?.shortcutsSettingsModel?.refresh()
            if let show { StatusMenuShortcut.apply(self?.shortcutsSettingsModel?.togglePicker, to: show) }
            if let repeatItem { StatusMenuShortcut.apply(self?.shortcutsSettingsModel?.repeatLast, to: repeatItem) }
        }
        menu.onUpdate?(menu)
        menu.addItem(.separator())
        addLibraryItem(to: menu, keyEquivalent: "")
        menu.addItem(.separator())
        addSettingsItem(to: menu)
        let setup = menu.addItem(withTitle: Strings.setup, action: #selector(showSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(.separator())
        let about = menu.addItem(withTitle: Strings.about, action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        about.target = self
        let quit = menu.addItem(withTitle: Strings.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        return menu
    }

    private func updateLibraryMenuItems() {
        // Menus own their items; discard rows from menus that have been released.
        libraryMenuItems.removeAll { $0.menu == nil }
        for item in libraryMenuItems {
            item.title = libraryStatusModel?.menuLabel ?? OnboardingStrings.libraryUnavailableMenu
            item.isEnabled = libraryStatusModel?.libraryAvailable == true
        }
    }

    @objc private func importFromMenu() {
        guard libraryWindow?.presentation.imports?.canImport == true else { return }
        showLibrary()
        libraryWindow?.presentation.imports?.choose()
    }

    @objc private func openLibraryFromMenu() {
        guard libraryStatusModel?.libraryAvailable == true else { return }
        showLibrary()
    }

    private func addLibraryItem(to menu: NSMenu, keyEquivalent: String) {
        let item = menu.addItem(withTitle: libraryStatusModel?.menuLabel ?? OnboardingStrings.libraryUnavailableMenu,
            action: #selector(openLibraryFromMenu), keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = .command
        libraryMenuItems.append(item)
        updateLibraryMenuItems()
    }

    private func addSettingsItem(to menu: NSMenu) {
        let settings = menu.addItem(withTitle: Strings.settings, action: #selector(showSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
    }

    private func addRepeatItem(to menu: NSMenu) {
        let repeatItem = menu.addItem(withTitle: Strings.repeatLast, action: #selector(repeatLast), keyEquivalent: "")
        repeatItem.target = self
    }

    @objc private func showPanel() {
        pickerModel?.open()
    }

    /// Hosted tests can opt in only with an injected backend, never Carbon.
    func startShortcuts() {
        guard !isShutDown, !Self.isRunningTests || makeHotkeyBackend != nil else { return }
        shortcuts?.configure { [weak self] action in
            switch action {
            case .togglePicker: self?.togglePicker()
            case .repeatLast: self?.repeatLast()
            }
        }
    }

    private func currentRepeatBinding() throws -> RepeatBinding {
        if let graph = syncComposition { return try graph.accounts.repeatBinding(libraryRoot: libraryDirectory.path) }
        return try RepeatBinding(root: libraryDirectory.path)
    }

    private func composeRepeat(library: LibraryService, index: PromptIndex,
                               isCurrent: @escaping () -> Bool) -> RepeatService? {
        guard let lastDelivery, let fill, let delivery else { return nil }
        // Corrupt account metadata keeps the recorder available for explicit
        // recovery, but the live identity check below refuses every repeat.
        let binding = (try? currentRepeatBinding()) ?? (try? RepeatBinding(root: libraryDirectory.path))
        repeatBinding = binding
        let service = binding.map { binding in
            RepeatService(binding: binding, store: lastDelivery, library: library, index: index,
                fill: fill, delivery: delivery, work: backgroundWork, main: mainThread,
                canAccess: { [weak self] entry in
                    guard let self, isCurrent(), self.pickerModel?.libraryAvailable == true,
                          (try? self.currentRepeatBinding()) == self.repeatBinding else { return false }
                    if let access = self.syncComposition?.access.snapshot.access(at: entry.relativePath, identity: entry.identity),
                       case .unavailable = access { return false }
                    return true
                },
                isOwnWindowActive: { [weak self] in self?.isOwnWindowActive ?? true })
        }
        repeatService = service
        repeatAwaitingResult = false
        let model = service.map { RepeatModel(service: $0, main: mainThread) }
        repeatModel = model
        model?.onChange = { [weak self, weak model] in
            guard isCurrent(), let self, let model else { return }
            if model.state == .repeating { self.repeatAwaitingResult = true; return }
            guard self.repeatAwaitingResult, model.state == .idle else { return }
            // Availability also publishes after ordinary deliveries and Forget.
            // Consume only this invocation's completion, never its retained result.
            self.repeatAwaitingResult = false
            if let result = model.result { self.showRepeatResult(result) }
        }
        return service
    }

    private func prepareRepeatAccountChange(generation: UInt64, accounts: SyncAccountStore) -> Bool {
        guard !isShutDown, libraryGeneration == generation, libraryTransition == nil, !terminationPending,
              let graph = syncComposition, graph.accounts === accounts else { return false }
        repeatAccountGeneration &+= 1
        let transition = repeatAccountGeneration
        do { try retireRepeat(replacementRoot: libraryDirectory) }
        catch {
            showRepeatResult(.unavailable(.invalidationFailed))
            return false
        }
        let drain = graph.accountDrain()
        let main = mainThread
        Task.detached { [weak self, weak graph] in
            await drain()
            main.run { [weak self, weak graph] in
                guard let self, let graph, !self.isShutDown, self.libraryGeneration == generation,
                      self.repeatAccountGeneration == transition, self.syncComposition === graph,
                      self.libraryTransition == nil, !self.terminationPending,
                      let repeatService = self.repeatService else { return }
                do {
                    let binding = try self.currentRepeatBinding()
                    try repeatService.rebind(to: binding)
                    self.repeatBinding = binding
                } catch { self.showRepeatResult(.unavailable(.invalidationFailed)) }
            }
        }
        return true
    }

    private func retireRepeat(replacementRoot: URL) throws {
        if let repeatService { try repeatService.retire(); return }
        // An invalid initial root cannot compose repeat. Recovery must still
        // clear a record left by an older valid root before it can return.
        guard let lastDelivery, let library, let index, let fill, let delivery else {
            throw RepeatFailure.invalidationFailed
        }
        let retirement = RepeatService(binding: try RepeatBinding(root: replacementRoot.path), store: lastDelivery,
            library: library, index: index, fill: fill, delivery: delivery,
            work: backgroundWork, main: mainThread, isOwnWindowActive: { true })
        try retirement.retire()
    }

    private var isOwnWindowActive: Bool {
        if let ownWindowIsActive { return ownWindowIsActive() }
        if panelController?.isActiveAndVisible == true { return true }
        return NSApp.isActive && NSApp.windows.contains { $0.isVisible && ($0.isKeyWindow || $0.isMainWindow) }
    }

    @objc func repeatLast() {
        guard !isShutDown, pickerModel?.state != .delivering,
              pickerModel?.isResolvingBuiltins != true,
              pickerModel?.fillModel?.builtinsResolved != false,
              pickerModel?.fillModel?.state != .delivering else { return }
        guard let repeatModel else { showRepeatResult(.unavailable(.invalidBinding)); return }
        repeatModel.repeatLast()
    }

    private func showRepeatResult(_ result: RepeatResult) {
        guard !isShutDown, Strings.repeatMessage(result) != nil else { return }
        if repeatWindow == nil {
            let generation = libraryGeneration
            repeatWindow = RepeatWindowController(mainThread: mainThread, activateApplication: activateApplication,
                openPrompt: { [weak self] reference in
                    guard let self, !self.isShutDown, self.libraryGeneration == generation else { return }
                    self.handle(.edit(identity: reference.identity, relativePath: reference.relativePath))
                })
        }
        repeatWindow?.show(result)
    }

    func togglePicker() {
        guard !isShutDown else { return }
        if panelController?.isActiveAndVisible == true {
            pickerModel?.dismiss()
        } else {
            pickerModel?.open()
        }
    }

    @objc private func showSetup() {
        guard !isShutDown else { return }
        // Revoke older retries and suppress this cancellation's restore before
        // presenting Setup. Native key-window transitions may still be pending.
        focusTracker?.cancelPendingRestoration()
        panelController?.cancelForOwnedWindow()
        setupWindow?.show()
        onboardingModel?.markSetupPresented()
        recordLegacySetup()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard currentReleaseVersion.flatMap(ReleaseVersion.init) != nil else { return }
        mainThread.run { [weak self] in
            guard let self, !self.isShutDown else { return }
            self.cancelPickerForOwnedWindow()
            self.settingsWindow?.presentation.selectedTab = .general
            self.settingsWindow?.show()
            self.settingsWindow?.presentation.updates.model.checkNow()
        }
    }

    @objc func openHelp(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/L-K-M/MonkeysPaw#readme") else { return }
        launchURI(url)
    }

    @objc func showSettings() {
        mainThread.run { [weak self] in
            guard let self, !self.isShutDown else { return }
            self.cancelPickerForOwnedWindow()
            self.settingsWindow?.show()
        }
    }

    func showAccount() {
        mainThread.run { [weak self] in
            guard let self, !self.isShutDown else { return }
            self.cancelPickerForOwnedWindow()
            self.settingsWindow?.showAccount()
        }
    }

    @objc func showLibrary() {
        mainThread.run { [weak self] in
            guard let self, !self.isShutDown, self.pickerModel?.libraryAvailable == true else { return }
            self.cancelPickerForOwnedWindow()
            self.libraryWindow?.show()
        }
    }

    private func showSyncDestination(_ action: SyncStatusAction) {
        guard !isShutDown, libraryTransition == nil, !terminationPending else { return }
        cancelPickerForOwnedWindow()
        switch action {
        case .account:
            settingsWindow?.presentation.selectedTab = .account
            settingsWindow?.show()
        case .conflicts:
            libraryWindow?.presentation.setFilter("")
            libraryWindow?.presentation.selectSection(.conflicts)
            libraryWindow?.show()
        case .errors:
            libraryWindow?.show()
        case .syncNow, .none: break
        }
    }

    private func cancelPickerForOwnedWindow() {
        focusTracker?.cancelPendingRestoration()
        panelController?.cancelForOwnedWindow()
        // Close model state even when a summon is queued behind an older restore.
        pickerModel?.dismiss()
        panelController?.hide()
        delivery?.invalidatePendingPresentation()
    }

    fileprivate var defaultLibraryPath: String { defaultLibraryDirectory.path }

    fileprivate func revealLibrary() { revealLibraryURI(libraryDirectory) }

    static var isRunningTests: Bool {
        NSClassFromString("XCTest.XCTestCase") != nil
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// Hosted graphs need an injected store to exercise secrets without the login Keychain.
private struct UnavailableSecretStore: SecretStore {
    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        throw SecretStoreError.unavailable
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        throw SecretStoreError.unavailable
    }
    func delete(account: SecretAccount) throws { throw SecretStoreError.unavailable }
}

/// General retains its port; a weak root prevents a resident composition cycle.
private final class SettingsLibraryLocation: LibraryLocationControl {
    private weak var owner: AppDelegate?

    init(owner: AppDelegate) { self.owner = owner }
    var activeLibraryPath: String { owner?.libraryDirectory.path ?? "" }
    var defaultLibraryPath: String { owner?.defaultLibraryPath ?? "" }

    func switchLibrary(to path: String?) -> LibrarySwitchOutcome {
        guard let owner else { return .libraryUnavailable(.ioFailure) }
        return owner.switchLibrary(to: path.map { URL(fileURLWithPath: $0, isDirectory: true) }).outcome
    }

    func revealLibrary() { owner?.revealLibrary() }
}

/// Resolve the active picker at confirmation time, including with a closed
/// panel. Settings must not keep an old picker's drafts alive across a switch.
private final class SettingsRememberedValuesControl: RememberedValuesControl {
    private weak var owner: AppDelegate?

    init(owner: AppDelegate) { self.owner = owner }

    func forgetAllValues() -> RememberedValuesOutcome {
        guard let picker = owner?.pickerModel else { return .libraryFailure(.operationFailed) }
        return picker.forgetAllValues()
    }
}

/// Library callbacks cross the UI queue through a port tied to this generation.
/// shared delivery/focus graph keeps its ordinary MainThread for its lifetime.
private struct LibraryMainThread: MainThread {
    let main: MainThread
    let isCurrent: () -> Bool

    func run(_ work: @escaping () -> Void) {
        main.run {
            guard isCurrent() else { return }
            work()
        }
    }
}
