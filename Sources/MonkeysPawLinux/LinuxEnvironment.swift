#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// The Linux composition root: only this type assembles platform drivers.
final class LinuxEnvironment {
    enum LibrarySwitchResult: Equatable {
        case switched
        case deliveryInFlight
        case editorBusy
        case invalidTarget(FileStoreError)
        case libraryUnavailable(FileStoreError)
        case persistenceFailed(SettingsError)

        var settingsOutcome: LibrarySwitchOutcome {
            switch self {
            case .switched: return .switched
            case .deliveryInFlight: return .deliveryInFlight
            // Core has one busy outcome. Settings overrides this refusal's
            // copy locally without widening the shared folder port.
            case .editorBusy: return .deliveryInFlight
            case .invalidTarget(let error): return .invalidTarget(.rejectedByStore(error))
            case .libraryUnavailable(let error): return .libraryUnavailable(error)
            case .persistenceFailed(let error): return .settingsNotSaved(error)
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
        let initializationError: FileStoreError?
        var started = false
        var warningLogged = false
        var assistant: AssistantModel?
        var makeAssistant: (() -> AssistantModel)?
        var assistantObserver: UUID?
        private var assistantSession: PromptEditingSession?

        init(directory: URL, files: FileStore, library: LibraryService,
             index: PromptIndex, watcher: LibraryWatcher?, picker: PickerModel, browser: LibraryBrowserModel,
             editing: PromptEditingService, editor: EditorModel,
             importModel: ImportModel, imports: LinuxLibraryImportState,
             callbacks: LibraryCallbacks, initializationError: FileStoreError?) {
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
            self.initializationError = initializationError
        }

        func stop() {
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
            let session = editor.assistantSnapshot?.session
            if assistant == nil || assistantSession != session {
                assistant?.deactivate()
                assistantSession = session
                assistant = makeAssistant?()
            } else { assistant?.contextChanged() }
        }
    }

    private enum ToggleOrigin { case shortcut, manual }
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
    private let libraryAvailabilityNotifier: LibraryAvailabilityNotifier?
    private let statusNotifierBusAddress: String?
    private var statusNotifierItem: LinuxStatusNotifierItem?
    private var libraryStatusObserver: UUID?

    // GApplication can dispatch a cold action without "activate". A stored lazy
    // panel covers both paths and keeps the Swift wrapper alive while hidden.
    private(set) lazy var panel = LinuxPanel(application: application)
    var pickerModel: PickerModel { libraryGraph.picker }
    var libraryBrowserModel: LibraryBrowserModel { libraryGraph.browser }
    var editorModel: EditorModel { libraryGraph.editor }
    var importModel: ImportModel { libraryGraph.importModel }
    var libraryImportState: LinuxLibraryImportState { libraryGraph.imports }
    var assistantModel: AssistantModel? { libraryGraph.assistant }

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
        }, hasConfiguredSyncServer: { false }, seedIfEmpty: { [weak self] in
            guard let self, !self.isShutDown else { throw FileStoreError.ioFailure }
            return try SeedService(library: self.libraryGraph.library).seedIfEmpty()
        })
    private lazy var dataFiles: FileStore = {
        do { return try RootedFileStore(root: paths.dataDirectory) }
        catch {
            log.write(.warning, "App data unavailable; remembered values and usage cannot be saved")
            return UnavailableFileStore()
        }
    }()
    private lazy var clock = SystemClock()
    private lazy var values = ValuesStore(files: dataFiles)
    private lazy var usage = UsageStore(files: dataFiles, clock: clock)
    private lazy var clipboard: Clipboard = suppliedClipboard ?? GTKClipboard(owner: panel.clipboardOwner)
    private lazy var fill = FillService(values: values, clipboard: clipboard, clock: clock,
        timeZone: { TimeZone.current })
    private lazy var notifier = GTKNotifier(application: application, session: session)
    private lazy var delivery = DeliveryService(
        panel: panel, focus: focusTracker ?? LinuxFocusTracker(session: session, runner: runner),
        clipboard: clipboard,
        injectors: [remoteDesktop, XdotoolPasteInjector(runner: runner), YdotoolPasteInjector(runner: runner)],
        notifier: notifier, session: session,
        scheduler: scheduler, mainThread: mainThread, failureCache: SessionPasteFailureCache())
    private lazy var selfTest = SelfTest(
        target: GTKSelfTestTarget(application: application), delivery: delivery,
        session: session, scheduler: scheduler, mainThread: mainThread)
    private lazy var shortcuts = ShortcutService(backend: hotkey, scheduler: scheduler, mainThread: mainThread)
    private lazy var setup = SetupService(
        probe: LinuxSetupProbe(application: application, runner: runner, hotkey: hotkey,
                               session: session, mainThread: mainThread, remoteDesktop: remoteDesktop),
        session: session, shortcuts: shortcuts, selfTest: selfTest, mainThread: mainThread)
    private(set) lazy var setupModel = SetupModel(setup: setup)
    private(set) lazy var shortcutsSettingsModel = ShortcutsSettingsModel(shortcuts: shortcuts, setup: setup)
    private var currentSetupWindow: LinuxSetupWindow?
    private var currentSettingsWindow: LinuxSettingsWindow?
    private var currentLibraryWindow: LinuxLibraryWindow?
    private var currentOnboardingWindow: LinuxOnboardingWindow?
    private var onboardingRequestRevision = 0
    private var isShutDown = false
    private var quitPending = false

    private let application: UnsafeMutablePointer<GtkApplication>

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
         clipboard: Clipboard? = nil,
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
        suppliedClipboard = clipboard
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
        guard !isShutDown else { return }
        startLibrary()
        _ = onboardingModel
        startStatusNotifierItem()
        if libraryStatusModel.needsLibraryFolderStep { presentFromLauncher() }
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
            guard action == .togglePicker else { return }
            self?.togglePicker(origin: .shortcut)
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
        guard !isShutDown, pickerModel.state != .delivering else { return }
        onboardingRequestRevision += 1
        pickerModel.dismiss()
        panel.hide()
        delivery.invalidatePendingPresentation()
        mainThread.run { [weak self] in self?.showSetup() }
    }

    func activateToggle() {
        // A cold action can race the queued registration. It must still show the
        // picker once, then later actions go through verification and debounce.
        if !hotkey.fire(.togglePicker) { togglePicker() }
    }

    func presentFromLauncher() {
        guard !isShutDown else { return }
        onboardingRequestRevision += 1
        let revision = onboardingRequestRevision
        onboardingModel.refresh()
        mainThread.run { [weak self] in
            guard let self, !self.isShutDown, self.onboardingRequestRevision == revision else { return }
            if self.currentSetupWindow?.isVisible == true {
                self.showSetup()
                return
            }
            switch self.onboardingModel.state.step {
            case .setup: self.showSetup()
            case .libraryFolder, .seedOffer, .tour: self.showOnboarding()
            case .complete:
                self.panel.cancelPendingBlur()
                self.pickerModel.open()
            }
        }
    }

    func showSettings() {
        guard pickerModel.state != .delivering else { return }
        onboardingRequestRevision += 1
        currentOnboardingWindow?.hide()
        pickerModel.dismiss()
        panel.hide()
        delivery.invalidatePendingPresentation()
        // Dismissal and invalidation enter DeliveryService through GLib idles.
        // Present only after those requests, including desktop-action entry.
        mainThread.run { [weak self] in
            // An open request queued before shutdown must not build a window.
            guard let self, !self.isShutDown else { return }
            if self.currentSettingsWindow == nil {
                self.currentSettingsWindow = LinuxSettingsWindow(application: self.application,
                    general: self.generalSettingsModel, shortcuts: self.shortcutsSettingsModel,
                    rememberedValues: self.rememberedValuesSettingsModel,
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
                    librarySwitchMessage: { [weak self] in self?.librarySwitchMessage })
            }
            self.currentSettingsWindow?.show()
        }
    }

    func showLibrary() {
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
        panel.hide()
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
            currentLibraryWindow = LinuxLibraryWindow(application: application,
                browser: libraryBrowserModel, editor: editorModel,
                imports: .init(state: libraryImportState, chooser: importChooser),
                assistant: { [weak graph] in graph?.assistant }, openFolder: { [weak self] in
                    guard let self, !self.isShutDown else { return }
                    self.libraryLocation.revealLibrary()
                })
        }
        currentLibraryWindow?.setLibraryAvailable(libraryGraph.picker.libraryAvailable)
        libraryImportState.setLibraryAvailable(libraryGraph.picker.libraryAvailable)
        currentLibraryWindow?.show()
    }

    /// The tray and GApplication action share this guarded quit path. A queued
    /// save or selection must finish before the quit decision can be approved.
    func requestQuit(_ approved: @escaping () -> Void) {
        guard !isShutDown, !quitPending else { return }
        guard let graph = currentLibraryGraph else { approved(); return }
        let state = graph.editor.state
        guard editorHasUnsavedWork(state) else {
            approved()
            return
        }
        quitPending = true
        presentLibraryWindow()
        graph.editor.request(.quit) { [weak self, weak graph] result in
            guard let self, let graph, self.currentLibraryGraph === graph else { return }
            self.quitPending = false
            guard !self.isShutDown else { return }
            if result == .allowed { approved() }
        }
    }

    private func editorHasUnsavedWork(_ state: EditorState) -> Bool {
        // Match Core's discard guard: a clean conflict has no unsaved draft.
        state.isDirty || state.status == .saving || state.status == .commandRunning
            || state.pendingDecision != nil || !state.queuedActions.isEmpty
    }

    private var librarySwitchMessage: String? {
        guard let graph = currentLibraryGraph else { return nil }
        if editorHasUnsavedWork(graph.editor.state) { return LinuxEditorStrings.librarySwitchRefused }
        // An empty override hides a past busy refusal once the work resolves.
        return graph.picker.state == .delivering ? nil : ""
    }

    private func showSetup() {
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

    private func togglePicker(origin: ToggleOrigin = .manual) {
        guard !isShutDown else { return }
        startLibrary()
        _ = onboardingModel
        // Only a focused panel toggles off. A buried or never-focused panel
        // must be raised, including when Wayland denied its initial activation.
        if panel.isActiveAndVisible {
            pickerModel.dismiss()
        } else {
            panel.cancelPendingBlur()
            panel.useActivationToken(origin == .shortcut ? hotkey.consumeActivationToken() : nil)
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
        // The default keeps the canonicalizing root rule, so a default folder
        // linked into a synced directory still loads; a chosen root must not be a symlink.
        let isDefault = directory.standardizedFileURL.path.utf8
            .elementsEqual(defaultLibraryDirectory.standardizedFileURL.path.utf8)
        let files = isDefault ? try RootedFileStore(root: directory) : try RootedFileStore(libraryRoot: directory)
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
        let index = PromptIndex(service: library, usage: usage, clock: clock)
        let callbacks = LibraryCallbacks(main: mainThread)
        let picker = PickerModel(index: index, fill: fill, delivery: delivery, main: callbacks)
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
            initializationError: initializationError)
        let service = assistantService
        let main = mainThread
        graph.makeAssistant = { [weak graph] in
            AssistantModel(service: service, main: main, context: { [weak graph] in
                AssistantContext(libraryID: graph?.id ?? UUID(), profile: service.selectedProfile,
                    editor: graph?.editor.assistantSnapshot,
                    access: graph?.callbacks.isActive == true && graph?.picker.libraryAvailable == true
                        ? .privatePrompt : .unavailable)
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
            }, requestedIntent: { [weak self, weak graph] intent in
                guard let graph, graph.callbacks.isActive else { return }
                self?.handle(intent, in: graph)
            }, createPrompt: { [weak self, weak graph] title in
                guard let graph, graph.callbacks.isActive else { return }
                self?.createPrompt(titled: title, in: graph)
            })
        return graph
    }

    /// UI-thread composition intent for later General/onboarding controls.
    /// Nil selects the default. Drafts belong to the retired picker.
    func switchLibrary(to directory: URL?) -> LibrarySwitchResult {
        guard !isShutDown else { return .libraryUnavailable(.ioFailure) }
        let old = libraryGraph
        if editorHasUnsavedWork(old.editor.state) { return .editorBusy }
        guard old.picker.state != .delivering else { return .deliveryInFlight }
        old.picker.dismiss()
        panel.hide()

        let target = directory ?? defaultLibraryDirectory
        let files: RootedFileStore
        do { files = try prepareLibraryFiles(at: target) }
        catch { return .invalidTarget(error as? FileStoreError ?? .ioFailure) }

        // The reused panel was hidden directly above. Revoke old requests held
        // by Setup or focus restoration before retiring their graph.
        delivery.invalidatePendingPresentation()
        old.stop()
        quitPending = false
        libraryGraph = makeLibraryGraph(directory: target, files: files)
        let startupError = startLibrary(libraryGraph)
        let graph = libraryGraph
        currentLibraryWindow?.rebind(browser: graph.browser, editor: graph.editor, imports: graph.imports,
            assistant: { [weak graph] in graph?.assistant })
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
        } catch {
            // Warn after the outcome is known: the warning latches once, and a
            // failed rebuild must log its typed reason rather than a generic one.
            do {
                try graph.index.rebuild()
                warnAboutLibrary(graph)
            } catch {
                degradeLibrary(graph, error as? FileStoreError)
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
            panel.hide()
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
        currentLibraryWindow?.tearDown()
        currentLibraryGraph?.stop()
        hotkey.shutdown()
        remoteDesktop.shutdown()
        portal.shutdown()
    }

    func runSelfTest(done: @escaping (SelfTestReport) -> Void) {
        selfTest.run(done: done)
    }
}
#endif
