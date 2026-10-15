#if os(Linux)
import CGtk
import Foundation
import Glibc
import MonkeysPawCore

/// The Linux composition root: only this type assembles platform drivers.
final class LinuxEnvironment {
    enum LibrarySwitchResult: Equatable {
        case switched
        case deliveryInFlight
        case editorBusy
        case syncDraining
        case syncRecoveryRequired
        case outsideSandboxHome
        case invalidTarget(FileStoreError)
        case libraryUnavailable(FileStoreError)
        case persistenceFailed(SettingsError)
        case repeatInvalidationFailed

        var settingsOutcome: LibrarySwitchOutcome {
            switch self {
            case .switched: return .switched
            case .deliveryInFlight: return .deliveryInFlight
            // Core has one busy outcome. Settings overrides this refusal's
            // copy locally without widening the shared folder port.
            case .editorBusy, .syncDraining: return .deliveryInFlight
            case .syncRecoveryRequired: return .libraryUnavailable(.ioFailure)
            case .outsideSandboxHome: return .invalidTarget(.outsideSandboxHome)
            case .invalidTarget(let error): return .invalidTarget(.rejectedByStore(error))
            case .libraryUnavailable(let error): return .libraryUnavailable(error)
            case .persistenceFailed(let error): return .settingsNotSaved(error)
            case .repeatInvalidationFailed: return .repeatInvalidationFailed
            }
        }
    }

    /// General retains its port; a weak adapter avoids retaining the entire
    /// composition root through the model that the root itself owns.
    private final class LibraryLocation: LibraryLocationControl {
        private weak var environment: LinuxEnvironment?
        let defaultLibraryPath: String
        var activeLibraryPath: String { environment?.libraryGraph.directory.path ?? defaultLibraryPath }

        init(environment: LinuxEnvironment, defaultLibraryPath: String) {
            self.environment = environment
            self.defaultLibraryPath = defaultLibraryPath
        }

        func switchLibrary(to path: String?) -> LibrarySwitchOutcome {
            guard let environment else { return .libraryUnavailable(.ioFailure) }
            // Validate before URL(fileURLWithPath:) can turn a relative spelling
            // into an absolute path. The rooted store owns filesystem checks.
            if let path, (try? SettingsDocument(libraryFolderPath: path)) == nil {
                return .invalidTarget(.rejectedByStore(.invalidRoot))
            }
            return environment.switchLibrary(to: path.map { URL(fileURLWithPath: $0, isDirectory: true) }).settingsOutcome
        }

        func revealLibrary() {
            guard let environment else { return }
            environment.launchURI(environment.libraryGraph.directory)
        }
    }

    /// Resolve the current picker for each reset, including with Settings open
    /// across a library switch. The model must not retain the composition root.
    private final class RememberedValues: RememberedValuesControl {
        private weak var environment: LinuxEnvironment?

        init(environment: LinuxEnvironment) { self.environment = environment }

        func forgetAllValues() -> RememberedValuesOutcome {
            guard let environment else { return .fileStoreFailure(.ioFailure) }
            return environment.pickerModel.forgetAllValues()
        }
    }

    /// Every library callback checks its generation on the GLib thread, even
    /// if an index, clipboard read or scheduler queued it before replacement.
    private final class LibraryCallbacks: MainThread {
        private let main: MainThread
        private(set) var isActive = true

        init(main: MainThread) { self.main = main }
        func deactivate() { isActive = false }

        func run(_ work: @escaping () -> Void) {
            main.run { [weak self] in
                guard self?.isActive == true else { return }
                work()
            }
        }
    }

    private final class LibraryGraph {
        let id = UUID()
        let directory: URL
        let files: FileStore
        let library: LibraryService
        let index: PromptIndex
        let watcher: LibraryWatcher?
        let picker: PickerModel
        let browser: LibraryBrowserModel
        let editing: PromptEditingService
        let editor: EditorModel
        let importModel: ImportModel
        let imports: LinuxLibraryImportState
        let callbacks: LibraryCallbacks
        let repeatService: RepeatService?
        let repeatModel: RepeatModel?
        var repeatWindow: LinuxRepeatWindow?
        var presentedRepeatResult: RepeatResult?
        let initializationError: FileStoreError?
        var started = false
        var warningLogged = false
        var rootUnavailable = false
        var assistant: AssistantModel?
        var makeAssistant: (() -> AssistantModel)?
        var assistantObserver: UUID?
        private var assistantSession: PromptEditingSession?
        var sync: SyncGraph?

        init(directory: URL, files: FileStore, library: LibraryService,
             index: PromptIndex, watcher: LibraryWatcher?, picker: PickerModel, browser: LibraryBrowserModel,
             editing: PromptEditingService, editor: EditorModel,
             importModel: ImportModel, imports: LinuxLibraryImportState,
             callbacks: LibraryCallbacks, repeatService: RepeatService?, repeatModel: RepeatModel?,
             initializationError: FileStoreError?) {
            self.directory = directory
            self.files = files
            self.library = library
            self.index = index
            self.watcher = watcher
            self.picker = picker
            self.browser = browser
            self.editing = editing
            self.editor = editor
            self.importModel = importModel
            self.imports = imports
            self.callbacks = callbacks
            self.repeatService = repeatService
            self.repeatModel = repeatModel
            self.initializationError = initializationError
        }

        func stop() {
            repeatModel?.deactivate()
            repeatService?.cancel()
            repeatWindow?.tearDown()
            repeatWindow = nil
            imports.deactivate()
            assistant?.deactivate()
            assistant = nil
            makeAssistant = nil
            if let assistantObserver { editor.removeObserver(assistantObserver) }
            assistantObserver = nil
            callbacks.deactivate()
            browser.deactivate()
            editor.deactivate()
            editing.deactivate()
            watcher?.stop()
            picker.onChange = nil
        }

        func refreshAssistant() {
            guard callbacks.isActive else { return }
            let session = editor.assistantSession
            if assistant == nil || assistantSession != session {
                assistant?.deactivate()
                assistantSession = session
                assistant = makeAssistant?()
            } else { assistant?.contextChanged() }
        }
    }

    // M6 sync lifetime is separate from window bindings and delivery settings.
    private final class SyncGraph {
        let service: SyncService
        let accounts: SyncAccountStore
        let accountService: SyncAccountService
        let access: GroupAccessService
        let scheduler: LinuxSyncScheduler
        var account: AccountModel?
        var status: SyncStatusModel?
        var invite: InviteModel?
        var groups: GroupManagementModel?
        var conflict: ConflictModel?
        var observer: UUID?
        var startupRequested = false
        var started = false
        var retired = false
        var drained = false

        var needsDrain: Bool {
            account?.state.isBusy == true || invite?.state.isBusy == true
                || groups?.state.isBusy == true || conflict?.state.isBusy == true
                || accounts.hasConfiguredServer || service.report.enabled
        }

        init(service: SyncService, accounts: SyncAccountStore, accountService: SyncAccountService,
             access: GroupAccessService, scheduler: LinuxSyncScheduler) {
            self.service = service
            self.accounts = accounts
            self.accountService = accountService
            self.access = access
            self.scheduler = scheduler
        }

        func retireModels() {
            retired = true
            scheduler.retire()
            account?.retire()
            status?.retire()
            invite?.retire()
            groups?.retire()
            conflict?.retire()
            if let observer { service.removeObserver(observer); self.observer = nil }
        }

        func drain() async -> Bool {
            _ = service.stop()
            await account?.drain()
            await invite?.drain()
            await groups?.drain()
            await conflict?.drain()
            // An admitted login/join may have restarted sync during its drain.
            _ = service.stop()
            await service.drain()
            if service.retire() == .recoveryRequired {
                do { try await service.recoverJournal() }
                catch { return false }
            }
            await service.drain()
            return service.retire() == .stopped
        }
    }

    private enum ActionOrigin { case shortcut, manual }
    private enum TrayEntry: Int32 {
        case picker = 1, library, settings, setup, quit
    }

    let log: LogSink
    let mainThread: MainThread
    private let session: LinuxSessionProbe
    private let runner: LinuxToolRunner
    private let scheduler: Scheduler
    private let focusTracker: FocusTracker?
    private let hotkey: LinuxHotkeyBackend
    private let portal: LinuxPortalTransport
    private let remoteDesktop: RemoteDesktopPasteInjector
    private let firstRun: LinuxFirstRunState
    private let paths: LinuxPaths
    private let launchURI: (URL) -> Void
    private let libraryWatcherFactory: ((URL) throws -> FileStoreWatcher)?
    private let folderChooser: LinuxFolderChoosing
    private let importChooser: LinuxImportChoosing
    private let importSourceFactory: () -> LinuxImportSourceReader
    private let backgroundWork: BackgroundWork
    private let suppliedAssistantTransport: HTTPTransporting?
    private let suppliedClipboard: Clipboard?
    private let updateVersion: String?
    private let suppliedReleasePage: ReleasePageOpening?
    private let isRunningTests: Bool
    private let updateScheduler = GLibUpdateScheduler()
    private let libraryAvailabilityNotifier: LibraryAvailabilityNotifier?
    private let statusNotifierBusAddress: String?
    private var statusNotifierItem: LinuxStatusNotifierItem?
    private var libraryStatusObserver: UUID?

    // GApplication can dispatch a cold action without "activate". A stored lazy
    // panel covers both paths and keeps the Swift wrapper alive while hidden.
    private(set) lazy var panel = LinuxPanel(application: application)
    var pickerModel: PickerModel { libraryGraph.picker }
    var repeatModel: RepeatModel? { libraryGraph.repeatModel }
    var libraryBrowserModel: LibraryBrowserModel { libraryGraph.browser }
    var editorModel: EditorModel { libraryGraph.editor }
    var importModel: ImportModel { libraryGraph.importModel }
    var libraryImportState: LinuxLibraryImportState { libraryGraph.imports }
    var assistantModel: AssistantModel? { libraryGraph.assistant }
    // Native Y21/Y24/Y26/Y28/Y33 views consume these shared models.
    var accountModel: AccountModel? { prepareSyncModels(in: libraryGraph); return libraryGraph.sync?.account }
    var syncStatusModel: SyncStatusModel? { libraryGraph.sync?.status }
    var inviteModel: InviteModel? { prepareSyncModels(in: libraryGraph); return libraryGraph.sync?.invite }
    var groupManagementModel: GroupManagementModel? { prepareSyncModels(in: libraryGraph); return libraryGraph.sync?.groups }
    var conflictModel: ConflictModel? { prepareSyncModels(in: libraryGraph); return libraryGraph.sync?.conflict }
    var syncService: SyncService? { libraryGraph.sync?.service }
    var syncCompositionIssue: SyncBlockingIssue? {
        guard let sync = libraryGraph.sync else { return .recoveryRequired }
        return sync.access.snapshot.isBlocked ? .invalidState : nil
    }
    private(set) var syncReplacementIssue: LibrarySwitchResult?
    private var syncReplacementTask: Task<Void, Never>?
    private let suppliedSyncTransport: HTTPTransporting?
    private let suppliedSyncTimer: Scheduler?
    private let syncDataFlush: (Int32) -> Int32

    private lazy var defaultLibraryDirectory = paths.documentsDirectory
        .appendingPathComponent("MonkeysPaw", isDirectory: true)
    private var currentLibraryGraph: LibraryGraph?
    private var libraryGraph: LibraryGraph {
        get {
            if let currentLibraryGraph { return currentLibraryGraph }
            let graph = makeInitialLibraryGraph()
            currentLibraryGraph = graph
            return graph
        }
        set { currentLibraryGraph = newValue }
    }
    private lazy var configFiles: FileStore = {
        do { return try RootedFileStore(root: paths.configDirectory) }
        catch {
            log.write(.warning, "Settings unavailable; using defaults without saving changes")
            return UnavailableFileStore()
        }
    }()
    private lazy var settingsStore = SettingsStore(files: configFiles,
        legacyFirstRun: firstRun.needsSetup ? .setupNotPresented : .setupPresented)
    private lazy var settings = SettingsService(store: settingsStore)
    private lazy var secretStore = LinuxSecretStore(paths: paths, runner: runner)
    private(set) lazy var providerSettingsService = ProviderSettingsService(
        store: ProviderSettingsStore(files: configFiles, log: log), secrets: secretStore, log: log)
    private lazy var assistantTransport: HTTPTransporting = suppliedAssistantTransport ?? URLSessionHTTPTransport()
    private var currentUpdateService: UpdateService?
    private var updateSettingsObserver: UUID?
    private(set) lazy var updateService: UpdateService = {
        if !settingsModel.allowsAutomaticUpdateChecks { updateScheduler.suspend() }
        let service = UpdateService(transport: assistantTransport, currentVersion: updateVersion,
            settings: settings, stateStore: UpdateStateStore(files: dataFiles), clock: clock,
            scheduler: updateScheduler, mainThread: mainThread,
            releasePage: suppliedReleasePage ?? GTKReleasePageOpener())
        currentUpdateService = service
        updateSettingsObserver = settingsModel.addObserver { [weak self, weak service] snapshot, _ in
            if snapshot.allowsAutomaticUpdateChecks { self?.updateScheduler.resume() }
            else { self?.updateScheduler.suspend() }
            service?.refreshAutomaticPolicy()
        }
        return service
    }()
    private var currentUpdateSettingsModel: UpdateSettingsModel?
    var updateSettingsModel: UpdateSettingsModel {
        if let currentUpdateSettingsModel { return currentUpdateSettingsModel }
        let model = UpdateSettingsModel(settings: settingsModel, updates: updateService, mainThread: mainThread)
        currentUpdateSettingsModel = model
        return model
    }
    private lazy var assistantService = AssistantService(providerSettings: providerSettingsService,
        anthropic: AnthropicClient(transport: assistantTransport),
        openAICompatible: OpenAIClient(transport: assistantTransport, providerState: ProviderStateStore(files: configFiles)),
        work: backgroundWork, main: mainThread)
    private(set) lazy var settingsModel = SettingsModel(settings: settings)
    private lazy var libraryLocation = LibraryLocation(environment: self,
        defaultLibraryPath: defaultLibraryDirectory.path)
    private(set) lazy var generalSettingsModel = GeneralSettingsModel(settings: settingsModel,
        library: libraryLocation, mainThread: mainThread)
    private(set) lazy var rememberedValuesSettingsModel = RememberedValuesSettingsModel(
        control: RememberedValues(environment: self), mainThread: mainThread)
    private var currentLibraryStatusModel: LibraryStatusModel?
    var libraryStatusModel: LibraryStatusModel {
        if let currentLibraryStatusModel { return currentLibraryStatusModel }
        // Startup includes the watcher's initial enumeration and the index
        // rebuild, not just whether the root could be constructed.
        startLibrary()
        let status = LibraryStatusModel(initialState: libraryGraph.picker.libraryAvailable
            ? .available : .unavailableAtStartup, mainThread: mainThread,
            notifyStartupUnavailable: { [weak self] in
                guard let self, !self.isShutDown else { return }
                (self.libraryAvailabilityNotifier ?? self.notifier).libraryUnavailable()
            })
        currentLibraryStatusModel = status
        return status
    }
    private(set) lazy var onboardingModel = OnboardingModel(settings: settingsModel,
        library: libraryLocation, status: libraryStatusModel, mainThread: mainThread,
        isLibraryEmpty: { [weak self] in
            guard let self, !self.isShutDown else { throw FileStoreError.ioFailure }
            return try self.libraryGraph.library.entries().isEmpty
        }, hasConfiguredSyncServer: { [weak self] in
            self?.currentLibraryGraph?.sync?.accounts.hasConfiguredServer == true
        }, seedIfEmpty: { [weak self] in
            guard let self, !self.isShutDown else { throw FileStoreError.ioFailure }
            return try SeedService(library: self.libraryGraph.library).seedIfEmpty()
        })
    private lazy var dataFiles: FileStore = {
        do { return try RootedFileStore(root: paths.dataDirectory, syncDescriptor: syncDataFlush) }
        catch {
            log.write(.warning, "App data unavailable; remembered values and usage cannot be saved")
            return UnavailableFileStore()
        }
    }()
    private lazy var clock = SystemClock()
    private lazy var values = ValuesStore(files: dataFiles)
    private lazy var usage = UsageStore(files: dataFiles, clock: clock)
    private lazy var lastDelivery = LastDeliveryStore(files: dataFiles)
    private lazy var clipboard: Clipboard = suppliedClipboard ?? GTKClipboard(owner: panel.clipboardOwner)
    private lazy var fill = FillService(values: values, clipboard: clipboard, clock: clock,
        timeZone: { TimeZone.current })
    private lazy var notifier = GTKNotifier(application: application, session: session)
    private var currentDelivery: DeliveryService?
    private var deliverySettingsObserver: UUID?
    private lazy var delivery: DeliveryService = {
        let preferences = settingsModel.state
        let service = DeliveryService(
            panel: panel, focus: focusTracker ?? LinuxFocusTracker(session: session, runner: runner),
            clipboard: clipboard,
            injectors: [remoteDesktop, XdotoolPasteInjector(runner: runner), YdotoolPasteInjector(runner: runner)],
            notifier: notifier, session: session,
            scheduler: scheduler, mainThread: mainThread, failureCache: SessionPasteFailureCache(),
            clipboardRestore: preferences.isReadOnly ? .off : preferences.document.delivery.clipboardRestore,
            linuxDefaultPasteChord: { [weak self] in
                self?.settingsModel.deliveryPreferences.linuxDefaultPasteChord ?? .standard
            })
        currentDelivery = service
        deliverySettingsObserver = settingsModel.addObserver { [weak service] snapshot, _ in
            service?.setClipboardRestore(snapshot.isReadOnly ? .off : snapshot.document.delivery.clipboardRestore)
        }
        return service
    }()
    private lazy var selfTest = SelfTest(
        target: GTKSelfTestTarget(application: application), delivery: delivery,
        session: session, scheduler: scheduler, mainThread: mainThread)
    private lazy var shortcuts = ShortcutService(backend: hotkey, scheduler: scheduler, mainThread: mainThread)
    private lazy var setup = SetupService(
        probe: LinuxSetupProbe(application: application, runner: runner, hotkey: hotkey,
                               session: session, mainThread: mainThread, remoteDesktop: remoteDesktop),
        session: session, shortcuts: shortcuts, selfTest: selfTest, mainThread: mainThread)
    private(set) lazy var setupModel = SetupModel(setup: setup)
    private var currentDeliverySettingsModel: DeliverySettingsModel?
    var deliverySettingsModel: DeliverySettingsModel {
        if let currentDeliverySettingsModel { return currentDeliverySettingsModel }
        let model = DeliverySettingsModel(settings: settingsModel, delivery: delivery, setup: setup, mainThread: mainThread)
        model.onOpenSetup = { [weak self] in self?.showSetup() }
        currentDeliverySettingsModel = model
        return model
    }
    private(set) lazy var shortcutsSettingsModel = ShortcutsSettingsModel(shortcuts: shortcuts, setup: setup)
    private var currentSetupWindow: LinuxSetupWindow?
    private var currentSettingsWindow: LinuxSettingsWindow?
    private var currentLibraryWindow: LinuxLibraryWindow?
    private var currentOnboardingWindow: LinuxOnboardingWindow?
    private var onboardingRequestRevision = 0
    private var isShutDown = false
    private var quitPending = false

    private let application: UnsafeMutablePointer<GtkApplication>

    static var packagedVersion: String? {
        #if MONKEYSPAW_PACKAGED_VERSION
        return PackagedBuildVersion.value
        #else
        return nil
        #endif
    }

    init(application: UnsafeMutablePointer<GtkApplication>,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         scheduler: Scheduler? = nil,
         focusTracker: FocusTracker? = nil,
         libraryWatcherFactory: ((URL) throws -> FileStoreWatcher)? = nil,
         folderChooser: LinuxFolderChoosing? = nil,
         importChooser: LinuxImportChoosing? = nil,
         importSourceFactory: @escaping () -> LinuxImportSourceReader = { LinuxImportSourceReader() },
         backgroundWork: BackgroundWork? = nil,
         assistantTransport: HTTPTransporting? = nil,
         syncTransport: HTTPTransporting? = nil,
         syncDataFlush: @escaping (Int32) -> Int32 = Glibc.fsync,
         clipboard: Clipboard? = nil,
         updateVersion: String? = LinuxEnvironment.packagedVersion,
         releasePage: ReleasePageOpening? = nil,
         libraryAvailabilityNotifier: LibraryAvailabilityNotifier? = nil,
         launchURI: @escaping (URL) -> Void = { url in
             // A dismissed panel may be unrealized before asynchronous handle export completes.
             gtk_show_uri(nil, url.absoluteString, UInt32(GDK_CURRENT_TIME))
         }) {
        self.application = application
        self.launchURI = launchURI
        self.libraryWatcherFactory = libraryWatcherFactory
        self.folderChooser = folderChooser ?? GTKFolderChooser()
        self.importChooser = importChooser ?? GTKImportChooser()
        self.importSourceFactory = importSourceFactory
        self.backgroundWork = backgroundWork ?? LinuxBackgroundWork()
        suppliedAssistantTransport = assistantTransport
        suppliedSyncTransport = syncTransport
        suppliedSyncTimer = scheduler
        self.syncDataFlush = syncDataFlush
        suppliedClipboard = clipboard
        self.updateVersion = updateVersion
        suppliedReleasePage = releasePage
        // Swift Build test executables do not carry the legacy .xctest suffix.
        isRunningTests = NSClassFromString("XCTest.XCTestCase") != nil
            || ProcessInfo.processInfo.arguments.first?.hasSuffix(".xctest") == true
            || environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.libraryAvailabilityNotifier = libraryAvailabilityNotifier
        statusNotifierBusAddress = environment["DBUS_SESSION_BUS_ADDRESS"]
        log = CompositeLogSink(
            sinks: [StandardErrorLog(), FileLogSink(dataDirectory: LinuxPaths(environment: environment).dataDirectory)],
            policy: LogLevelPolicy(environmentValue: environment["MONKEYSPAW_LOG"]))
        mainThread = GLibMainThread()
        runner = LinuxToolRunner(environment: environment)
        session = LinuxSessionProbe(environment: environment)
        self.scheduler = scheduler ?? GLibScheduler()
        self.focusTracker = focusTracker
        paths = LinuxPaths(environment: environment)
        firstRun = LinuxFirstRunState(paths: paths)
        portal = LinuxPortalTransport(busAddress: environment["DBUS_SESSION_BUS_ADDRESS"])
        let portalWindow = PortalWindow(application: application)
        let desktop = session.currentSession()
        remoteDesktop = RemoteDesktopPasteInjector(transport: portal,
            tokens: PortalTokenStore(paths: paths),
            session: desktop, mainThread: mainThread, parent: portalWindow.parent)
        switch desktop {
        case .kdeWayland, .kdeX11:
            let native = KGlobalAccelHotkeyBackend(busAddress: environment["DBUS_SESSION_BUS_ADDRESS"])
            let shortcutPortal = PortalHotkeyBackend(transport: portal, fallback: ManualHotkeyBackend(),
                runner: runner, migration: .none, mainThread: mainThread, parent: portalWindow.parent)
            hotkey = KDEPortalHotkeyBackend(native: native, portal: shortcutPortal, transport: portal,
                choices: KDEHotkeyChoiceStore(paths: paths))
        default:
            let fallback: LinuxHotkeyBackend
            let migration: PortalHotkeyBackend.Migration
            switch desktop {
            case .gnomeWayland, .gnomeX11:
                fallback = GnomeKeybindingBackend(runner: runner, mainThread: mainThread)
                migration = .gnomeHost
            default:
                fallback = ManualHotkeyBackend()
                migration = .none
            }
            hotkey = PortalHotkeyBackend(transport: portal, fallback: fallback,
                runner: runner, migration: migration, mainThread: mainThread, parent: portalWindow.parent)
        }
    }

    /// Start only in the registered primary, not remote invocations or unit tests.
    func start() {
        LinuxPickerTrace.record("environment.start", "shutdown=\(isShutDown)")
        guard !isShutDown else { return }
        if !isRunningTests, updateVersion != nil { updateService.startAutomaticChecks() }
        startLibrary()
        startSync(in: libraryGraph)
        _ = onboardingModel
        startStatusNotifierItem()
        traceFirstRun("startup.gate")
        if libraryStatusModel.needsLibraryFolderStep { presentFromLauncher(source: "startup-library-recovery") }
        hotkey.onChange = { [weak self] in self?.setupModel.refresh() }
        remoteDesktop.onChange = { [weak self] in self?.setupModel.refresh() }
        switch session.currentSession() {
        case .gnomeWayland, .gnomeX11, .kdeWayland, .kdeX11, .flatpak: remoteDesktop.probe()
        default: break
        }
        let bindings = HotkeyAction.allCases.reduce(into: [HotkeyAction: Accelerator]()) { result, action in
            result[action] = Accelerator.defaultBinding(for: action)
        }
        shortcuts.configure(bindings) { [weak self] action in
            switch action {
            case .togglePicker: self?.togglePicker(origin: .shortcut)
            case .repeatLast: self?.repeatLast(origin: .shortcut)
            }
        }
    }

    private func startStatusNotifierItem() {
        guard statusNotifierItem == nil else { return }
        statusNotifierItem = LinuxStatusNotifierItem(busAddress: statusNotifierBusAddress) { [weak self] in
            self?.togglePicker()
        }
        updateStatusNotifierEntries()
        libraryStatusObserver = libraryStatusModel.addObserver { [weak self] _ in
            guard let self, !self.isShutDown else { return }
            self.updateStatusNotifierEntries()
        }
        statusNotifierItem?.start()
    }

    private func updateStatusNotifierEntries() {
        let status = libraryStatusModel
        statusNotifierItem?.setEntries([
            StatusNotifierEntry(id: TrayEntry.picker.rawValue, label: LinuxStrings.showPicker) { [weak self] in
                self?.togglePicker()
            },
            StatusNotifierEntry(id: TrayEntry.library.rawValue, label: status.menuLabel,
                enabled: status.libraryAvailable) { [weak self] in
                guard let self, !self.isShutDown, self.libraryStatusModel.libraryAvailable,
                      self.pickerModel.state != .delivering else { return }
                self.handle(.openLibrary, in: self.libraryGraph)
            },
            StatusNotifierEntry(id: TrayEntry.settings.rawValue, label: LinuxStrings.openSettings) { [weak self] in
                self?.showSettings()
            },
            StatusNotifierEntry(id: TrayEntry.setup.rawValue, label: LinuxStrings.traySetup) { [weak self] in
                self?.showSetupFromTray()
            },
            StatusNotifierEntry(id: TrayEntry.quit.rawValue, label: LinuxStrings.quit) { [weak self] in
                guard let self, !self.isShutDown else { return }
                // Use the same quit path as the application action. runPanel's
                // defers release its hold and shut down the exported item.
                g_action_group_activate_action(mp_action_group(self.application), ActionName.quit.rawValue, nil)
            },
        ])
    }

    private func showSetupFromTray() {
        LinuxPickerTrace.record("activation", "source=tray.setup")
        guard !isShutDown, pickerModel.state != .delivering else { return }
        onboardingRequestRevision += 1
        pickerModel.dismiss()
        panel.hide(reason: "tray.setup")
        delivery.invalidatePendingPresentation()
        mainThread.run { [weak self] in self?.showSetup() }
    }

    func activateToggle() {
        LinuxPickerTrace.record("toggle.request", "source=action")
        // A cold action can race the queued registration. It must still show the
        // picker once, then later actions go through verification and debounce.
        if !hotkey.fire(.togglePicker) {
            LinuxPickerTrace.record("toggle.fallback", "reason=backend-not-ready")
            togglePicker()
        } else {
            LinuxPickerTrace.record("toggle.dispatched", "reason=backend-handled")
        }
    }

    func activateRepeat() {
        guard !isShutDown else { return }
        // GNOME/manual may route their own compositor command. Portal/KDE
        // decline fire(), so a direct action never supplies activation proof.
        if !hotkey.fire(.repeatLast) { repeatLast(origin: .manual) }
    }

    private func repeatLast(origin: ActionOrigin) {
        guard !isShutDown else { return }
        startLibrary()
        let graph = libraryGraph
        guard graph.picker.state != .delivering, !graph.picker.isResolvingBuiltins,
              graph.picker.fillModel?.state != .delivering else { return }
        guard let model = graph.repeatModel else {
            mp_notify(application, LinuxStrings.repeatLast, LinuxStrings.repeatMessage(.unavailable(.invalidBinding)))
            return
        }
        guard model.state == .idle else { return }
        // Consume only this action's token without raising a window before
        // RepeatService captures the current external target.
        var token = origin == .shortcut ? hotkey.consumeActivationToken(for: .repeatLast) : nil
        graph.repeatModel?.onChange = { [weak self, weak graph] in
            guard let self, let graph, !self.isShutDown,
                  self.currentLibraryGraph === graph, let model = graph.repeatModel else { return }
            if model.state == .repeating { graph.presentedRepeatResult = nil }
            guard model.state == .idle, let result = model.result,
                  graph.presentedRepeatResult != result else { return }
            graph.presentedRepeatResult = result
            let activationToken = token
            token = nil
            guard LinuxStrings.repeatMessage(result) != nil else { return }
            if graph.repeatWindow == nil {
                graph.repeatWindow = LinuxRepeatWindow(application: self.application, model: model,
                    openPrompt: { [weak self, weak graph] reference in
                        guard let self, let graph, self.currentLibraryGraph === graph,
                              graph.callbacks.isActive else { return }
                        self.handle(.edit(identity: reference.identity, relativePath: reference.relativePath), in: graph)
                    })
            }
            graph.repeatWindow?.showResult(activationToken: activationToken)
        }
        model.repeatLast()
    }

    private var isOwnWindowActive: Bool {
        var windows = gtk_application_get_windows(application)
        while let node = windows {
            if let raw = node.pointee.data {
                let window = raw.assumingMemoryBound(to: GtkWindow.self)
                if gtk_widget_get_visible(mp_window_widget(window)) != 0,
                   gtk_window_is_active(window) != 0 { return true }
            }
            windows = node.pointee.next
        }
        return false
    }

    func presentFromLauncher(source: StaticString = "direct") {
        LinuxPickerTrace.record("launcher.request", "source=\(source) shutdown=\(isShutDown)")
        guard !isShutDown else { return }
        onboardingRequestRevision += 1
        let revision = onboardingRequestRevision
        onboardingModel.refresh()
        LinuxPickerTrace.record("launcher.queued", "source=\(source) revision=\(revision)")
        mainThread.run { [weak self] in
            guard let self else { return }
            LinuxPickerTrace.record("launcher.dispatch", "source=\(source) revision=\(revision)"
                + " current=\(self.onboardingRequestRevision) shutdown=\(self.isShutDown)")
            guard !self.isShutDown, self.onboardingRequestRevision == revision else {
                LinuxPickerTrace.record("launcher.skipped", "reason=superseded-or-shutdown")
                return
            }
            self.traceFirstRun("launcher.gate")
            if self.currentSetupWindow?.isVisible == true {
                LinuxPickerTrace.record("launcher.route", "destination=existing-setup")
                self.showSetup()
                return
            }
            switch self.onboardingModel.state.step {
            case .setup:
                LinuxPickerTrace.record("launcher.route", "destination=setup")
                self.showSetup()
            case .libraryFolder, .seedOffer, .tour:
                LinuxPickerTrace.record("launcher.route", "destination=onboarding")
                self.showOnboarding()
            case .complete:
                LinuxPickerTrace.record("launcher.route", "destination=picker state=\(LinuxPickerTrace.pickerState(self.pickerModel.state))")
                self.panel.cancelPendingBlur()
                self.pickerModel.open()
                LinuxPickerTrace.record("picker.open.returned", "state=\(LinuxPickerTrace.pickerState(self.pickerModel.state))")
            }
        }
    }

    private func traceFirstRun(_ event: StaticString) {
        LinuxPickerTrace.record(event, "step=\(onboardingModel.state.step) readOnly=\(settingsModel.isReadOnly)"
            + " setup=\(settingsModel.firstRun.setupPresented) folder=\(settingsModel.firstRun.libraryFolderCompleted)"
            + " seeds=\(settingsModel.firstRun.seedsOffered) tour=\(settingsModel.firstRun.tourCompleted)"
            + " recovery=\(libraryStatusModel.needsLibraryFolderStep)")
    }

    func showSettings(page: LinuxSettingsWindow.Page = .current) {
        LinuxPickerTrace.record("settings.request", "state=\(LinuxPickerTrace.pickerState(currentLibraryGraph?.picker.state))")
        guard pickerModel.state != .delivering else { return }
        onboardingRequestRevision += 1
        currentOnboardingWindow?.hide()
        pickerModel.dismiss()
        panel.hide(reason: "settings")
        delivery.invalidatePendingPresentation()
        // Dismissal and invalidation enter DeliveryService through GLib idles.
        // Present only after those requests, including desktop-action entry.
        mainThread.run { [weak self] in
            // An open request queued before shutdown must not build a window.
            guard let self, !self.isShutDown else { return }
            if self.currentSettingsWindow?.isDestroyed == true {
                // Release the old view before wiring callbacks on the next one.
                self.currentSettingsWindow = nil
                self.currentDeliverySettingsModel = nil
                self.currentUpdateSettingsModel = nil
            }
            if self.currentSettingsWindow == nil {
                self.currentSettingsWindow = LinuxSettingsWindow(application: self.application,
                    general: self.generalSettingsModel, shortcuts: self.shortcutsSettingsModel,
                    rememberedValues: self.rememberedValuesSettingsModel,
                    delivery: self.deliverySettingsModel, updates: self.updateSettingsModel,
                    session: self.session.currentSession(),
                    makeAssistant: { [weak self] in
                        guard let self, !self.isShutDown else { return nil }
                        let model = AssistantSettingsModel(settings: self.providerSettingsService,
                            assistant: self.assistantService, work: self.backgroundWork, mainThread: self.mainThread)
                        model.onProfilesChanged = { [weak self] in
                            self?.currentLibraryGraph?.assistant?.profileChanged()
                        }
                        return model
                    },
                    chooser: self.folderChooser, openSetup: { [weak self] in self?.showSetup() },
                    librarySwitchMessage: { [weak self] in self?.librarySwitchMessage },
                    makeAccount: { [weak self] in
                        guard let self, !self.isShutDown,
                              self.libraryGraph.sync?.retired == false else { return nil }
                        return self.accountModel
                    })
            }
            self.currentSettingsWindow?.show(page: page)
        }
    }

    func showLibrary() {
        LinuxPickerTrace.record("library.request", "shutdown=\(isShutDown)")
        guard !isShutDown, pickerModel.state != .delivering else { return }
        startLibrary()
        guard pickerModel.libraryAvailable else {
            // Desktop actions may arrive without a picker to render feedback.
            if panel.isVisible { panel.showStatus(LinuxStrings.libraryUnavailable) }
            return
        }
        onboardingRequestRevision += 1
        currentOnboardingWindow?.hide()
        pickerModel.dismiss()
        panel.hide(reason: "library")
        delivery.invalidatePendingPresentation()
        // Match Settings: queued dismissal/focus work finishes before present.
        // Resolve the current graph here if a folder switch ran in the meantime.
        mainThread.run { [weak self] in
            guard let self, !self.isShutDown, self.pickerModel.libraryAvailable else { return }
            self.presentLibraryWindow()
        }
    }

    private func presentLibraryWindow() {
        if currentLibraryWindow == nil {
            let graph = libraryGraph
            // Browsing alone must not start account-model loading work.
            currentLibraryWindow = LinuxLibraryWindow(application: application,
                browser: libraryBrowserModel, editor: editorModel,
                imports: .init(state: libraryImportState, chooser: importChooser),
                assistant: { [weak graph] in graph?.assistant },
                conflict: { [weak graph] in graph?.sync?.conflict },
                syncStatus: graph.sync?.status,
                syncNavigation: { [weak self, weak graph] action in
                    guard let graph else { return }
                    self?.navigateSyncStatus(action, in: graph)
                }, openFolder: { [weak self] in
                    guard let self, !self.isShutDown else { return }
                    self.libraryLocation.revealLibrary()
                })
        }
        currentLibraryWindow?.setLibraryAvailable(libraryGraph.picker.libraryAvailable)
        libraryImportState.setLibraryAvailable(libraryGraph.picker.libraryAvailable)
        currentLibraryWindow?.show()
    }

    private func navigateSyncStatus(_ action: SyncStatusAction, in graph: LibraryGraph) {
        guard !isShutDown, graph.callbacks.isActive, currentLibraryGraph === graph,
              graph.sync?.retired == false else { return }
        switch action {
        case .account: showSettings(page: .account)
        case .conflicts, .errors:
            showLibrary()
            graph.callbacks.run { [weak self, weak graph] in
                guard let self, let graph, !self.isShutDown, self.currentLibraryGraph === graph else { return }
                if action == .conflicts { self.currentLibraryWindow?.showSyncConflicts() }
            }
        case .syncNow, .none: break // The status view forwards Sync now to its model.
        }
    }

    /// The tray and GApplication action share this guarded quit path. A queued
    /// save or selection must finish before the quit decision can be approved.
    func requestQuit(_ approved: @escaping () -> Void) {
        guard !isShutDown, !quitPending else { return }
        guard syncReplacementTask == nil else {
            mp_notify(application, LinuxStrings.quit, LinuxStrings.syncFinishingBeforeQuit)
            return
        }
        guard let graph = currentLibraryGraph else { approved(); return }
        let state = graph.editor.state
        guard editorHasUnsavedWork(state) else {
            approveQuit(afterDraining: graph, approved: approved)
            return
        }
        quitPending = true
        presentLibraryWindow()
        graph.editor.request(.quit) { [weak self, weak graph] result in
            guard let self, let graph, self.currentLibraryGraph === graph else { return }
            self.quitPending = false
            guard !self.isShutDown else { return }
            if result == .allowed { self.approveQuit(afterDraining: graph, approved: approved) }
        }
    }

    private func approveQuit(afterDraining graph: LibraryGraph, approved: @escaping () -> Void) {
        guard let sync = graph.sync else { approved(); return }
        currentSettingsWindow?.suspendAccount()
        if !sync.needsDrain, sync.service.retire() == .stopped {
            sync.retireModels()
            sync.drained = true
            approved()
            return
        }
        quitPending = true
        sync.retireModels()
        graph.stop()
        syncReplacementTask = Task.detached { [self, sync] in
            await withCheckedContinuation { completion in backgroundWork.run { completion.resume() } }
            let drained = await sync.drain()
            mainThread.run { [weak self] in
                guard let self, !self.isShutDown else { return }
                self.quitPending = false
                self.syncReplacementTask = nil
                if drained { approved() }
                else {
                    self.syncReplacementIssue = .syncRecoveryRequired
                    self.panel.showStatus("Local sync recovery must finish before quitting.")
                }
            }
        }
    }

    private func editorHasUnsavedWork(_ state: EditorState) -> Bool {
        // Match Core's discard guard: a clean conflict has no unsaved draft.
        state.isDirty || state.status == .saving || state.status == .commandRunning
            || state.pendingDecision != nil || !state.queuedActions.isEmpty
    }

    private var librarySwitchMessage: String? {
        if syncReplacementTask != nil { return "Finishing sync work before changing the library." }
        if syncReplacementIssue == .syncRecoveryRequired { return "Local sync recovery must finish before changing the library." }
        guard let graph = currentLibraryGraph else { return nil }
        if editorHasUnsavedWork(graph.editor.state) { return LinuxEditorStrings.librarySwitchRefused }
        // An empty override hides a past busy refusal once the work resolves.
        return graph.picker.state == .delivering ? nil : ""
    }

    private func showSetup() {
        LinuxPickerTrace.record("setup.request", "shutdown=\(isShutDown)")
        guard !isShutDown else { return }
        onboardingRequestRevision += 1
        currentOnboardingWindow?.hide()
        if currentSetupWindow == nil {
            currentSetupWindow = LinuxSetupWindow(application: application, model: setupModel,
                onHide: { [weak self] in self?.continueOnboarding() })
        }
        currentSetupWindow?.show()
        onboardingModel.markSetupPresented()
        do {
            try firstRun.recordPresentation()
        } catch {
            log.write(.warning, "Could not save legacy first-run Setup state")
        }
    }

    private func continueOnboarding() {
        LinuxPickerTrace.record("onboarding.continue", "shutdown=\(isShutDown) revision=\(onboardingRequestRevision)")
        guard !isShutDown else { return }
        let revision = onboardingRequestRevision
        onboardingModel.refresh()
        mainThread.run { [weak self] in
            // An explicit launcher/Settings request supersedes a queued close
            // continuation; it must not be obscured by a later onboarding show.
            // Closing Setup must not replace a Settings window you opened;
            // onboarding stays pending for the next launcher request.
            guard let self, !self.isShutDown, self.onboardingRequestRevision == revision,
                  self.currentSetupWindow?.isVisible != true,
                  self.currentSettingsWindow?.isVisible != true,
                  self.currentLibraryWindow?.isVisible != true else { return }
            switch self.onboardingModel.state.step {
            case .libraryFolder, .seedOffer, .tour: self.showOnboarding()
            case .setup, .complete: break
            }
        }
    }

    private func showOnboarding() {
        LinuxPickerTrace.record("onboarding.request", "shutdown=\(isShutDown)")
        guard !isShutDown, pickerModel.state != .delivering else { return }
        currentSettingsWindow?.hide()
        if currentOnboardingWindow == nil {
            // Each native view owns its General onChange hook. Both instances
            // share settings and the same current-graph composition adapter.
            currentOnboardingWindow = LinuxOnboardingWindow(application: application,
                model: onboardingModel, general: GeneralSettingsModel(settings: settingsModel,
                    library: libraryLocation, mainThread: mainThread), chooser: folderChooser,
                librarySwitchMessage: { [weak self] in self?.librarySwitchMessage })
        }
        currentOnboardingWindow?.show()
    }

    private func togglePicker(origin: ActionOrigin = .manual) {
        LinuxPickerTrace.record("toggle.dispatch", "origin=\(origin) shutdown=\(isShutDown)")
        guard !isShutDown else { return }
        startLibrary()
        _ = onboardingModel
        // Only a focused panel toggles off. A buried or never-focused panel
        // must be raised, including when Wayland denied its initial activation.
        if panel.isActiveAndVisible {
            LinuxPickerTrace.record("dismiss.request", "reason=toggle-active")
            pickerModel.dismiss()
        } else {
            LinuxPickerTrace.record("picker.open.request", "reason=toggle")
            panel.cancelPendingBlur()
            panel.useActivationToken(origin == .shortcut ? hotkey.consumeActivationToken(for: .togglePicker) : nil)
            pickerModel.open()
        }
    }

    private func makeInitialLibraryGraph() -> LibraryGraph {
        let directory = settings.snapshot.document.libraryFolderPath
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultLibraryDirectory
        do {
            return makeLibraryGraph(directory: directory, files: try prepareLibraryFiles(at: directory))
        } catch {
            return makeLibraryGraph(directory: directory, files: UnavailableFileStore(),
                initializationError: error as? FileStoreError ?? .ioFailure)
        }
    }

    private func prepareLibraryFiles(at directory: URL) throws -> RootedFileStore {
        guard directory.isFileURL, directory.baseURL == nil,
              (try? SettingsDocument(libraryFolderPath: directory.path)) != nil else {
            throw FileStoreError.invalidRoot
        }
        guard paths.supportsLibrary(at: directory) else { throw FileStoreError.outsideRoot }
        // The default keeps the canonicalizing root rule, so a default folder
        // linked into a synced directory still loads; a chosen root must not be a symlink.
        let isDefault = directory.standardizedFileURL.path.utf8
            .elementsEqual(defaultLibraryDirectory.standardizedFileURL.path.utf8)
        let trash = paths.dataDirectory.deletingLastPathComponent().appendingPathComponent("Trash")
        let files = isDefault ? try RootedFileStore(root: directory, trashRoot: trash)
            : try RootedFileStore(libraryRoot: directory, trashRoot: trash)
        if isDefault {
            try files.createRoot()
        } else {
            try files.requireRoot()
        }
        // requireRoot checks shape, while enumeration also catches unreadable
        // roots/descendants before we retire the working library.
        _ = try files.listFiles()
        return files
    }

    private func makeLibraryGraph(directory: URL, files: FileStore,
                                  initializationError: FileStoreError? = nil) -> LibraryGraph {
        let library = LibraryService(library: files, data: dataFiles,
            clock: clock, entropy: SystemEntropy(), keyedStores: [values, usage])
        // Install the journal and committed group policy before ordinary reads.
        let sync = makeSyncGraph(directory: directory, files: files, library: library)
        let index = PromptIndex(service: library, usage: usage, clock: clock)
        let callbacks = LibraryCallbacks(main: mainThread)
        let repeatService = (try? RepeatBinding(root: directory.path)).map { binding in
            RepeatService(binding: binding, store: lastDelivery, library: library, index: index,
                fill: fill, delivery: delivery, work: backgroundWork, main: mainThread,
                canAccess: { [weak self, weak callbacks] _ in
                    guard let graph = self?.currentLibraryGraph, graph.callbacks === callbacks else { return false }
                    return graph.callbacks.isActive && graph.picker.libraryAvailable
                }, isOwnWindowActive: { [weak self] in self?.isOwnWindowActive ?? true })
        }
        let repeatModel = repeatService.map { RepeatModel(service: $0, main: mainThread) }
        let picker = PickerModel(index: index, fill: fill, delivery: delivery, main: callbacks, repeatService: repeatService)
        let editing = PromptEditingService(library: library, index: index, work: backgroundWork, main: callbacks)
        // EditorModel guards retired publications itself; its .inactive guard
        // completions must still reach callers after the graph stops.
        let editor = EditorModel(editing: editing, clock: clock, timeZone: { TimeZone.current }, main: mainThread)
        let browser = LibraryBrowserModel(index: index, usage: usage, favorites: library, main: callbacks, editor: editor)
        let sources = importSourceFactory()
        let importModel = ImportModel(service: ImportService(library: library, sources: sources,
            work: backgroundWork, main: callbacks))
        let imports = LinuxLibraryImportState(model: importModel, available: initializationError == nil,
            main: callbacks, prepare: { [weak callbacks, weak self] urls, done in
                self?.backgroundWork.run {
                    let requests = sources.requests(for: urls)
                    callbacks?.run { done(requests) }
                }
            }, openImported: { [weak self, weak index, weak callbacks] path in
                guard let self, callbacks?.isActive == true,
                      let entry = index?.search("").first(where: { $0.relativePath.utf8.elementsEqual(path.utf8) }) else { return false }
                self.currentLibraryWindow?.openPrompt(LibraryPromptSelection(identity: entry.identity, relativePath: RelativePath(path)))
                return true
            })
        picker.libraryAvailable = initializationError == nil
        let watcher: LibraryWatcher?
        do {
            let raw = try libraryWatcherFactory?(directory) ?? RootedFileWatcher(root: directory, log: log)
            watcher = LibraryWatcher(watcher: raw, scheduler: scheduler)
        } catch { watcher = nil }
        let graph = LibraryGraph(directory: directory, files: files, library: library,
            index: index, watcher: watcher, picker: picker, browser: browser, editing: editing, editor: editor,
            importModel: importModel, imports: imports, callbacks: callbacks,
            repeatService: repeatService, repeatModel: repeatModel,
            initializationError: initializationError)
        graph.sync = sync
        observeSync(in: graph)
        let service = assistantService
        let main = mainThread
        graph.makeAssistant = { [weak graph] in
            AssistantModel(service: service, main: main, context: { [weak graph] in
                AssistantContext(libraryID: graph?.id ?? UUID(), profile: service.selectedProfile,
                    editor: graph?.editor.assistantSnapshot,
                    access: graph?.callbacks.isActive == true && graph?.picker.libraryAvailable == true
                        ? graph?.editor.assistantAccess ?? .unavailable : .unavailable)
            })
        }
        graph.refreshAssistant()
        graph.assistantObserver = editor.addObserver { [weak graph] _ in graph?.refreshAssistant() }
        panel.rebind(picker: picker, session: session.currentSession(),
            openSetup: { [weak self, weak callbacks] in
                guard callbacks?.isActive == true else { return }
                self?.showSetup()
            }, openSettings: { [weak self, weak callbacks] in
                guard callbacks?.isActive == true else { return }
                self?.showSettings()
            }, syncStatus: sync?.status, syncNavigation: { [weak self, weak graph] action in
                guard let graph else { return }
                self?.navigateSyncStatus(action, in: graph)
            }, requestedIntent: { [weak self, weak graph] intent in
                guard let graph, graph.callbacks.isActive else { return }
                self?.handle(intent, in: graph)
            }, createPrompt: { [weak self, weak graph] title in
                guard let graph, graph.callbacks.isActive else { return }
                self?.createPrompt(titled: title, in: graph)
            })
        return graph
    }

    private func makeSyncGraph(directory: URL, files: FileStore, library: LibraryService) -> SyncGraph? {
        guard let libraryOperations = files as? SyncFileOperations,
              let dataOperations = dataFiles as? SyncFileOperations else { return nil }
        (files as? RootedFileStore)?.bindSyncRoot()
        (dataFiles as? RootedFileStore)?.bindSyncRoot()
        let states = SyncStateStore(files: dataFiles, operations: dataOperations)
        let accounts = SyncAccountStore(files: dataFiles, operations: dataOperations)
        let timer = LinuxSyncScheduler(worker: backgroundWork, timer: suppliedSyncTimer)
        do {
            let access = try GroupAccessService(library: library, states: states, accounts: accounts,
                libraryRoot: directory.path)
            let service = try SyncService(library: library, libraryOperations: libraryOperations,
                dataFiles: dataFiles, dataOperations: dataOperations, states: states, accounts: accounts,
                scheduler: timer, mainThread: mainThread, clock: clock, entropy: SystemEntropy())
            let account = try SyncAccountService(sync: service, accounts: accounts, secrets: secretStore,
                transport: suppliedSyncTransport ?? assistantTransport, libraryRoot: directory.path)
            let graph = SyncGraph(service: service, accounts: accounts, accountService: account, access: access, scheduler: timer)
            // Status observes reports without starting Account's asynchronous load.
            graph.status = SyncStatusModel(sync: service, mainThread: mainThread)
            return graph
        } catch {
            timer.retire()
            log.write(.warning, "Sync unavailable; local recovery is required")
            return nil
        }
    }

    private func prepareSyncModels(in graph: LibraryGraph) {
        guard let sync = graph.sync, !sync.retired, sync.account == nil else { return }
        sync.account = AccountModel(account: sync.accountService, mainThread: mainThread)
        sync.invite = InviteModel(service: SyncInviteService(account: sync.accountService, clipboard: clipboard), mainThread: mainThread)
        sync.groups = GroupManagementModel(service: SyncGroupService(account: sync.accountService, clipboard: clipboard), mainThread: mainThread)
        sync.conflict = ConflictModel(service: ConflictResolutionService(sync: sync.service), mainThread: mainThread)
        _ = sync.account?.addObserver { [weak self, weak graph, weak sync] state in
            guard let self, let graph, let sync, !sync.retired, self.currentLibraryGraph === graph else { return }
            if sync.startupRequested, !state.isBusy {
                sync.startupRequested = false
                sync.account?.startup()
            }
            self.onboardingModel.refresh()
        }
    }

    private func startSync(in graph: LibraryGraph) {
        guard let sync = graph.sync, !sync.started, !sync.retired else { return }
        sync.started = true
        // A healthy local-only primary has no account work to start. Opening
        // Account still loads its models, and explicit login starts this engine.
        guard sync.accounts.hasConfiguredServer || sync.access.snapshot.isBlocked else { return }
        prepareSyncModels(in: graph)
        // Account's initial loading publication must complete before startup.
        if sync.account?.state.isBusy == true { sync.startupRequested = true }
        else { sync.account?.startup() }
    }

    private func observeSync(in graph: LibraryGraph) {
        guard let sync = graph.sync else { return }
        sync.observer = sync.service.observe { [weak self, weak graph] report in
            guard let self, let graph, graph.callbacks.isActive, self.currentLibraryGraph === graph else { return }
            if graph.index.lastSyncRefreshFailure != nil || report.blockingIssue != nil {
                self.checkSyncRoot(in: graph)
            }
            self.restoreLibraryAvailability(in: graph)
            if report.phase == .idle, graph.sync?.conflict?.state.isBusy == false { graph.sync?.conflict?.refresh() }
        }
    }

    private func restoreLibraryAvailability(in graph: LibraryGraph) {
        guard graph.sync?.service.report.blockingIssue == nil, graph.index.lastSyncRefreshFailure == nil,
              graph.sync?.access.snapshot.isBlocked == false,
              graph.initializationError == nil, !graph.rootUnavailable else { return }
        graph.picker.libraryAvailable = true
        graph.imports.setLibraryAvailable(true)
        currentLibraryWindow?.setLibraryAvailable(true)
        // Finish a replacement whose initial reads were blocked by sync.
        currentLibraryStatusModel?.libraryReplaced(available: true)
    }

    private func checkSyncRoot(in graph: LibraryGraph) {
        backgroundWork.run { [weak self, weak graph] in
            guard let graph else { return }
            do { try (graph.files as? RootedFileStore)?.requireRoot() }
            catch {
                _ = graph.sync?.service.rootHealthChanged(.unavailable)
                graph.callbacks.run { [weak self, weak graph] in
                    guard let graph else { return }
                    self?.degradeLibrary(graph, error as? FileStoreError)
                }
                return
            }
            guard graph.index.lastSyncRefreshFailure != nil else { return }
            do {
                try graph.index.rebuild(origin: .sync)
                graph.callbacks.run { [weak self, weak graph] in
                    guard let graph else { return }
                    self?.restoreLibraryAvailability(in: graph)
                }
            } catch {
                graph.callbacks.run { [weak self, weak graph] in
                    guard let graph else { return }
                    self?.warnAboutLibrary(graph)
                }
            }
        }
    }

    /// UI-thread composition intent for later General/onboarding controls.
    /// Nil selects the default. Drafts belong to the retired picker.
    func switchLibrary(to directory: URL?) -> LibrarySwitchResult {
        guard !isShutDown else { return .libraryUnavailable(.ioFailure) }
        guard syncReplacementTask == nil else { return .syncDraining }
        let target = directory ?? defaultLibraryDirectory
        // Refuse unsupported chooser/portal paths before touching the active graph.
        guard paths.supportsLibrary(at: target) else { return .outsideSandboxHome }
        let old = libraryGraph
        let resumeSync = old.sync?.started == true || old.sync?.account?.state.enabled == true
        if editorHasUnsavedWork(old.editor.state) { return .editorBusy }
        guard old.picker.state != .delivering, old.picker.fillModel?.state != .delivering else { return .deliveryInFlight }
        old.picker.dismiss()
        panel.hide(reason: "switch-library")

        let files: RootedFileStore
        do { files = try prepareLibraryFiles(at: target) }
        catch { return .invalidTarget(error as? FileStoreError ?? .ioFailure) }

        // Preserve the synchronous General port for idle, unstarted graphs.
        // An active account graph drains off UI, then repeats this same intent.
        if let sync = old.sync, !sync.drained {
            if sync.needsDrain || sync.service.retire() != .stopped {
                beginSyncReplacement(old, directory: directory)
                return .syncDraining
            }
            sync.retireModels()
            sync.drained = true
        }

        // A failed tombstone keeps the binding and graph, with repeat disabled
        // until a durable retry. No late record may write into the replacement.
        do {
            if let repeatService = old.repeatService { try repeatService.retire() }
            else {
                // An invalid initial root has no repeat binding. Recovery still
                // tombstones the shared store before an older valid root returns.
                let retirement = RepeatService(binding: try RepeatBinding(root: target.path), store: lastDelivery,
                    library: old.library, index: old.index, fill: fill, delivery: delivery,
                    work: backgroundWork, main: mainThread, isOwnWindowActive: { true })
                try retirement.retire()
            }
        }
        catch {
            mp_notify(application, LinuxStrings.repeatLast, LinuxStrings.repeatMessage(.unavailable(.invalidationFailed)))
            return .repeatInvalidationFailed
        }

        // The reused panel was hidden directly above. Revoke old requests held
        // by Setup or focus restoration before retiring their graph.
        delivery.invalidatePendingPresentation()
        currentSettingsWindow?.suspendAccount()
        old.stop()
        quitPending = false
        libraryGraph = makeLibraryGraph(directory: target, files: files)
        let startupError = startLibrary(libraryGraph)
        let graph = libraryGraph
        if resumeSync { startSync(in: graph) }
        currentSettingsWindow?.rebindAccount()
        currentLibraryWindow?.rebind(browser: graph.browser, editor: graph.editor, imports: graph.imports,
            assistant: { [weak graph] in graph?.assistant }, conflict: { [weak graph] in graph?.sync?.conflict },
            syncStatus: graph.sync?.status, syncNavigation: { [weak self, weak graph] action in
                guard let graph else { return }
                self?.navigateSyncStatus(action, in: graph)
            })
        currentLibraryWindow?.setLibraryAvailable(libraryGraph.picker.libraryAvailable)
        // Never create the status here: its first read starts the current
        // graph. A later first read derives health from the replacement.
        currentLibraryStatusModel?.libraryReplaced(available: libraryGraph.picker.libraryAvailable)
        if let startupError { return .libraryUnavailable(startupError) }

        // Keep the usable graph for this session if saving fails. SettingsModel
        // calls the shared service and retains its typed error for the controls.
        if let directory { settingsModel.setLibraryFolder(directory.path) }
        else { settingsModel.clearLibraryFolder() }
        if let error = settingsModel.error { return .persistenceFailed(error) }
        return .switched
    }

    private func beginSyncReplacement(_ graph: LibraryGraph, directory: URL?) {
        guard let sync = graph.sync else { return }
        syncReplacementIssue = nil
        currentSettingsWindow?.suspendAccount()
        sync.retireModels()
        graph.stop()
        graph.picker.libraryAvailable = false
        currentLibraryWindow?.setLibraryAvailable(false)
        syncReplacementTask = Task.detached { [self, graph, sync] in
            await withCheckedContinuation { completion in
                backgroundWork.run { completion.resume() }
            }
            let drained = await sync.drain()
            mainThread.run { [weak self, graph] in
                guard let self else { return }
                self.syncReplacementTask = nil
                guard !self.isShutDown, self.currentLibraryGraph === graph else { return }
                guard drained else {
                    self.syncReplacementIssue = .syncRecoveryRequired
                    self.warnAboutLibrary(graph)
                    self.generalSettingsModel.refresh()
                    return
                }
                sync.drained = true
                // Target health and editor/delivery admission are checked again.
                let result = self.switchLibrary(to: directory)
                self.syncReplacementIssue = result == .switched ? nil : result
                guard result == .switched else { self.generalSettingsModel.refresh(); return }
                if self.onboardingModel.state.step == .libraryFolder, result == .switched {
                    self.onboardingModel.chooseFolder(self.libraryGraph.directory.path)
                } else if let directory { self.generalSettingsModel.chooseFolder(directory.path) }
                else { self.generalSettingsModel.chooseFolder(self.defaultLibraryDirectory.path) }
            }
        }
    }

    @discardableResult
    private func startLibrary() -> FileStoreError? { startLibrary(libraryGraph) }

    @discardableResult
    private func startLibrary(_ graph: LibraryGraph) -> FileStoreError? {
        guard !graph.started else { return nil }
        graph.started = true
        // makeLibraryGraph installs the picker hook/view before monitoring.
        do {
            if let error = graph.initializationError { throw error }
            try Self.startLibrary(index: graph.index, watcher: graph.watcher) { [weak self, weak graph] update in
                guard let graph else { return }
                graph.callbacks.run { [weak self, weak graph] in
                    guard let self, let graph else { return }
                    switch update {
                    case .changes(let changes): self.apply(changes, in: graph)
                    case .rootUnavailable(let error): self.degradeLibrary(graph, error)
                    }
                }
            }
            return nil
        } catch {
            if let error = error as? LibraryError, error == .recoveryRequired || error == .syncUnavailable {
                // A different root's state is blocked until account startup
                // resets its binding. This is not missing-root evidence.
                graph.picker.libraryAvailable = false
                graph.imports.setLibraryAvailable(false)
                warnAboutLibrary(graph)
                return nil
            }
            let failure = error as? FileStoreError ?? .ioFailure
            degradeLibrary(graph, failure)
            return failure
        }
    }

    static func startLibrary(index: PromptIndex, watcher: LibraryWatcher?,
                             onChange: @escaping @Sendable (LibraryWatchUpdate) -> Void) throws {
        guard let watcher else { throw FileStoreError.ioFailure }
        // Arm before rebuilding so saves cannot fall between the index scan
        // and the watcher's silent baseline. GLib batches cannot interleave
        // with this synchronous rebuild; reloading an indexed path is idempotent.
        try watcher.start(onChange)
        try index.rebuild()
    }

    private func apply(_ changes: LibraryChangeSet, in graph: LibraryGraph) {
        do {
            // Health flushes earlier pending events first. The root can already
            // be gone when those paths reload; avoid dropping cached modified
            // entries before the following health update stops this graph.
            try (graph.files as? RootedFileStore)?.requireRoot()
        } catch {
            degradeLibrary(graph, error as? FileStoreError)
            return
        }
        do {
            try graph.index.apply(changes)
            scheduleSync(changes, in: graph)
        } catch let error as LibraryError where error == .recoveryRequired || error == .syncUnavailable {
            // Journal completion refreshes the index after releasing its gate.
            // A blocked ordinary read is not evidence that the root was lost.
            return
        } catch {
            // Warn after the outcome is known: the warning latches once, and a
            // failed rebuild must log its typed reason rather than a generic one.
            do {
                try graph.index.rebuild()
                scheduleSync(changes, in: graph)
                warnAboutLibrary(graph)
            } catch let error as LibraryError where error == .recoveryRequired || error == .syncUnavailable {
                return
            } catch {
                degradeLibrary(graph, error as? FileStoreError)
            }
        }
    }

    private func scheduleSync(_ changes: LibraryChangeSet, in graph: LibraryGraph) {
        guard let sync = graph.sync, !sync.retired else { return }
        let paths = changes.created.union(changes.modified).union(changes.deleted)
        backgroundWork.run { [weak self, weak graph, weak sync] in
            guard let graph, let sync else { return }
            do {
                try (graph.files as? RootedFileStore)?.requireRoot()
                let checked = try paths.compactMap { path -> SyncFileChange? in
                    let stamp: FileStamp?
                    do { stamp = try graph.files.stamp(at: path.string) }
                    catch {
                        // A path can change type without losing the pinned root.
                        try (graph.files as? RootedFileStore)?.requireRoot()
                        return nil
                    }
                    guard let stamp else {
                        return SyncFileChange(path: path, stamp: nil, hash: nil)
                    }
                    guard let bytes = try? graph.files.read(at: path.string) else {
                        return SyncFileChange(path: path, stamp: stamp, hash: nil)
                    }
                    let hash = bytes.withUnsafeBytes { buffer -> String? in
                        guard let value = g_compute_checksum_for_data(G_CHECKSUM_SHA256,
                            buffer.bindMemory(to: UInt8.self).baseAddress, UInt(buffer.count)) else { return nil }
                        defer { g_free(value) }
                        return String(cString: value)
                    }
                    return SyncFileChange(path: path, stamp: stamp, hash: hash)
                }
                sync.service.filesChanged(checked)
            } catch {
                _ = sync.service.rootHealthChanged(.unavailable)
                graph.callbacks.run { [weak self, weak graph] in
                    guard let graph else { return }
                    self?.degradeLibrary(graph, error as? FileStoreError)
                }
            }
        }
    }

    private func warnAboutLibrary(_ graph: LibraryGraph, _ error: FileStoreError? = nil) {
        guard !graph.warningLogged else { return }
        graph.warningLogged = true
        if let error {
            log.write(.warning, "Library unavailable (\(error.rawValue)); keeping cached prompts")
            return
        }
        log.write(.warning, "Library unavailable or refresh failed; keeping cached prompts")
    }

    private func degradeLibrary(_ graph: LibraryGraph, _ error: FileStoreError? = nil) {
        graph.rootUnavailable = true
        if let sync = graph.sync {
            backgroundWork.run { _ = sync.service.rootHealthChanged(.unavailable) }
        }
        graph.watcher?.stop()
        graph.picker.libraryAvailable = false
        graph.imports.setLibraryAvailable(false)
        graph.assistant?.contextChanged()
        currentLibraryWindow?.setLibraryAvailable(false)
        currentLibraryStatusModel?.update(.lostWhileRunning)
        warnAboutLibrary(graph, error)
    }

    private func handle(_ intent: PickerModel.Intent, in graph: LibraryGraph) {
        guard graph.picker.libraryAvailable else {
            panel.showStatus(LinuxStrings.libraryUnavailable)
            return
        }

        switch intent {
        case .openLibrary:
            showLibrary()
            return
        case .edit(let identity, let path):
            guard (try? FileStorePath.validate(path)) != nil else {
                panel.showStatus(LinuxStrings.promptFileUnavailable)
                return
            }
            graph.picker.dismiss()
            panel.hide(reason: "edit-intent")
            delivery.invalidatePendingPresentation()
            graph.callbacks.run { [weak self, weak graph] in
                guard let self, let graph, !self.isShutDown, self.currentLibraryGraph === graph else { return }
                self.presentLibraryWindow()
                self.currentLibraryWindow?.openPrompt(LibraryPromptSelection(identity: identity, relativePath: RelativePath(path)))
            }
        }
    }

    private func createPrompt(titled title: String, in graph: LibraryGraph) {
        guard graph.picker.libraryAvailable else { return }
        do {
            let entry = try graph.library.createPrompt(titled: title, body: LinuxStrings.newPromptBody)
            let path = entry.relativePath
            do { try graph.index.apply(LibraryChangeSet(created: [RelativePath(path)])) }
            catch { log.write(.warning, "Prompt saved; immediate index refresh failed") }
            handle(.edit(identity: entry.identity, relativePath: path), in: graph)
        } catch {
            panel.showStatus(LinuxStrings.createPromptFailed)
            log.write(.warning, "Could not create a prompt; check library and app-data permissions")
        }
    }

    func shutdown() {
        LinuxPickerTrace.record("environment.shutdown", "alreadyShutdown=\(isShutDown)")
        guard !isShutDown else { return }
        isShutDown = true
        quitPending = false
        if let libraryStatusObserver {
            currentLibraryStatusModel?.removeObserver(libraryStatusObserver)
            self.libraryStatusObserver = nil
        }
        statusNotifierItem?.stop()
        statusNotifierItem = nil
        currentSetupWindow?.hide()
        currentOnboardingWindow?.hide()
        currentSettingsWindow?.hide()
        currentDeliverySettingsModel?.retire()
        currentUpdateSettingsModel?.retire()
        currentUpdateService?.stop()
        updateScheduler.shutdown()
        if let updateSettingsObserver { settingsModel.removeObserver(updateSettingsObserver) }
        updateSettingsObserver = nil
        currentLibraryWindow?.tearDown()
        currentLibraryGraph?.stop()
        currentDelivery?.invalidatePendingPresentation()
        currentDelivery?.shutdown()
        if let deliverySettingsObserver { settingsModel.removeObserver(deliverySettingsObserver) }
        deliverySettingsObserver = nil
        if let graph = currentLibraryGraph, let sync = graph.sync {
            sync.retireModels()
            if syncReplacementTask == nil {
                syncReplacementTask = Task.detached { [backgroundWork] in
                    await withCheckedContinuation { completion in backgroundWork.run { completion.resume() } }
                    _ = await sync.drain()
                }
            }
        }
        hotkey.shutdown()
        remoteDesktop.shutdown()
        portal.shutdown()
    }

    /// Tests and the quit path can await native/account teardown off UI.
    func drainSync() async { await syncReplacementTask?.value }

    func runSelfTest(done: @escaping (SelfTestReport) -> Void) {
        selfTest.run(done: done)
    }
}
#endif
