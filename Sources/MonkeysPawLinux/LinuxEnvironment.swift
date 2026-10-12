#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// The Linux composition root: only this type assembles platform drivers.
final class LinuxEnvironment {
    enum LibrarySwitchResult: Equatable {
        case switched
        case deliveryInFlight
        case invalidTarget(FileStoreError)
        case libraryUnavailable(FileStoreError)
        case persistenceFailed(SettingsError)
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
        let directory: URL
        let files: FileStore
        let library: LibraryService
        let index: PromptIndex
        let watcher: LibraryWatcher?
        let picker: PickerModel
        let callbacks: LibraryCallbacks
        let initializationError: FileStoreError?
        var started = false
        var warningLogged = false

        init(directory: URL, files: FileStore, library: LibraryService,
             index: PromptIndex, watcher: LibraryWatcher?, picker: PickerModel,
             callbacks: LibraryCallbacks, initializationError: FileStoreError?) {
            self.directory = directory
            self.files = files
            self.library = library
            self.index = index
            self.watcher = watcher
            self.picker = picker
            self.callbacks = callbacks
            self.initializationError = initializationError
        }

        func stop() {
            callbacks.deactivate()
            watcher?.stop()
            picker.onChange = nil
            index.setOnChange(nil)
        }
    }

    private enum ToggleOrigin { case shortcut, manual }
    let log: LogSink
    let mainThread: MainThread
    private let session: LinuxSessionProbe
    private let runner: LinuxToolRunner
    private let scheduler: Scheduler
    private let hotkey: LinuxHotkeyBackend
    private let portal: LinuxPortalTransport
    private let remoteDesktop: RemoteDesktopPasteInjector
    private let firstRun: LinuxFirstRunState
    private let paths: LinuxPaths
    private let launchURI: (URL) -> Void
    private let libraryWatcherFactory: ((URL) throws -> FileStoreWatcher)?

    // GApplication can dispatch a cold action without "activate". A stored lazy
    // panel covers both paths and keeps the Swift wrapper alive while hidden.
    private(set) lazy var panel = LinuxPanel(application: application)
    var pickerModel: PickerModel { libraryGraph.picker }

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
    private(set) lazy var settingsModel = SettingsModel(settings: settings)
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
    private lazy var clipboard = GTKClipboard(owner: panel.clipboardOwner)
    private lazy var fill = FillService(values: values, clipboard: clipboard, clock: clock,
        timeZone: { TimeZone.current })
    private lazy var delivery = DeliveryService(
        panel: panel, focus: LinuxFocusTracker(session: session, runner: runner),
        clipboard: clipboard,
        injectors: [remoteDesktop, XdotoolPasteInjector(runner: runner), YdotoolPasteInjector(runner: runner)],
        notifier: GTKNotifier(application: application, session: session), session: session,
        scheduler: scheduler, mainThread: mainThread, failureCache: SessionPasteFailureCache())
    private lazy var selfTest = SelfTest(
        target: GTKSelfTestTarget(application: application), delivery: delivery,
        session: session, scheduler: scheduler, mainThread: mainThread)
    private lazy var shortcuts = ShortcutService(backend: hotkey, scheduler: scheduler, mainThread: mainThread)
    private(set) lazy var setupModel = SetupModel(setup: SetupService(
        probe: LinuxSetupProbe(application: application, runner: runner, hotkey: hotkey,
                               session: session, mainThread: mainThread, remoteDesktop: remoteDesktop),
        session: session, shortcuts: shortcuts, selfTest: selfTest, mainThread: mainThread))
    private lazy var setupWindow = LinuxSetupWindow(application: application, model: setupModel)

    private let application: UnsafeMutablePointer<GtkApplication>

    init(application: UnsafeMutablePointer<GtkApplication>,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         scheduler: Scheduler? = nil,
         libraryWatcherFactory: ((URL) throws -> FileStoreWatcher)? = nil,
         launchURI: @escaping (URL) -> Void = { url in
             // A dismissed panel may be unrealized before asynchronous handle export completes.
             gtk_show_uri(nil, url.absoluteString, UInt32(GDK_CURRENT_TIME))
         }) {
        self.application = application
        self.launchURI = launchURI
        self.libraryWatcherFactory = libraryWatcherFactory
        log = CompositeLogSink(
            sinks: [StandardErrorLog(), FileLogSink(dataDirectory: LinuxPaths(environment: environment).dataDirectory)],
            policy: LogLevelPolicy(environmentValue: environment["MONKEYSPAW_LOG"]))
        mainThread = GLibMainThread()
        runner = LinuxToolRunner(environment: environment)
        session = LinuxSessionProbe(environment: environment)
        self.scheduler = scheduler ?? GLibScheduler()
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
        startLibrary()
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

    func activateToggle() {
        // A cold action can race the queued registration. It must still show the
        // picker once, then later actions go through verification and debounce.
        if !hotkey.fire(.togglePicker) { togglePicker() }
    }

    func presentFromLauncher() {
        if settingsModel.needsSetupPresentation { showSetup() } else { startLibrary(); pickerModel.open() }
    }

    private func showSetup() {
        setupWindow.show()
        settingsModel.markSetupPresented()
        do {
            try firstRun.recordPresentation()
        } catch {
            log.write(.warning, "Could not save legacy first-run Setup state")
        }
    }

    private func togglePicker(origin: ToggleOrigin = .manual) {
        startLibrary()
        // Only a focused panel toggles off. A buried or never-focused panel
        // must be raised, including when Wayland denied its initial activation.
        if panel.isActiveAndVisible {
            pickerModel.dismiss()
        } else {
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
        let files = try RootedFileStore(libraryRoot: directory)
        if directory.standardizedFileURL.path.utf8.elementsEqual(defaultLibraryDirectory.standardizedFileURL.path.utf8) {
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
        picker.libraryAvailable = initializationError == nil
        let watcher: LibraryWatcher?
        do {
            let raw = try libraryWatcherFactory?(directory) ?? RootedFileWatcher(root: directory, log: log)
            watcher = LibraryWatcher(watcher: raw, scheduler: scheduler)
        } catch { watcher = nil }
        let graph = LibraryGraph(directory: directory, files: files, library: library,
            index: index, watcher: watcher, picker: picker, callbacks: callbacks,
            initializationError: initializationError)
        panel.rebind(picker: picker, session: session.currentSession(),
            openSetup: { [weak self, weak callbacks] in
                guard callbacks?.isActive == true else { return }
                self?.showSetup()
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
        let old = libraryGraph
        guard old.picker.state != .delivering else { return .deliveryInFlight }
        old.picker.dismiss()
        panel.hide()

        let target = directory ?? defaultLibraryDirectory
        let files: RootedFileStore
        do { files = try prepareLibraryFiles(at: target) }
        catch { return .invalidTarget(error as? FileStoreError ?? .ioFailure) }

        old.stop()
        libraryGraph = makeLibraryGraph(directory: target, files: files)
        if let error = startLibrary(libraryGraph) { return .libraryUnavailable(error) }

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
        warnAboutLibrary(graph, error)
    }

    private func handle(_ intent: PickerModel.Intent, in graph: LibraryGraph) {
        guard graph.picker.libraryAvailable else {
            panel.showStatus(LinuxStrings.libraryUnavailable)
            return
        }

        let url: URL
        switch intent {
        case .openLibrary: url = graph.directory
        case .edit(_, let path):
            guard (try? FileStorePath.validate(path)) != nil else {
                panel.showStatus(LinuxStrings.promptFileUnavailable)
                return
            }
            url = graph.directory.appendingPathComponent(path)
        }
        graph.picker.dismiss()
        graph.callbacks.run { [weak self] in
            self?.launchURI(url)
        }
    }

    private func createPrompt(titled title: String, in graph: LibraryGraph) {
        guard graph.picker.libraryAvailable else { return }
        do {
            let path = try graph.library.availablePath(for: PromptCreation.relativePath(title: title, now: clock.now()))
            let document = try PromptCodec.newDocument(title: title, body: LinuxStrings.newPromptBody)
            let entry = try graph.library.save(document, at: path)
            do { try graph.index.apply(LibraryChangeSet(created: [RelativePath(path)])) }
            catch { log.write(.warning, "Prompt saved; immediate index refresh failed") }
            handle(.edit(identity: entry.identity, relativePath: path), in: graph)
        } catch {
            panel.showStatus(LinuxStrings.createPromptFailed)
            log.write(.warning, "Could not create a prompt; check library and app-data permissions")
        }
    }

    func shutdown() {
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
