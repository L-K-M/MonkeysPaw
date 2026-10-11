#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// The Linux composition root: only this type assembles platform drivers.
final class LinuxEnvironment {
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
    private var libraryInitializationFailed = false
    private var libraryStarted = false
    private var libraryWarningLogged = false

    // GApplication can dispatch a cold action without "activate". A stored lazy
    // panel covers both paths and keeps the Swift wrapper alive while hidden.
    private(set) lazy var panel = LinuxPanel(application: application)
    private(set) lazy var pickerModel: PickerModel = {
        let model = PickerModel(index: index, fill: fill, delivery: delivery, main: mainThread)
        model.libraryAvailable = !libraryInitializationFailed
        panel.bind(picker: model, session: session.currentSession(),
            openSetup: { [weak self] in self?.showSetup() },
            requestedIntent: { [weak self] in self?.handle($0) },
            createPrompt: { [weak self] in self?.createPrompt(titled: $0) })
        return model
    }()

    // Stores, watcher and URI intents must all retain the same selected root.
    private lazy var libraryDirectory = paths.documentsDirectory
        .appendingPathComponent("MonkeysPaw", isDirectory: true)
    private lazy var libraryFiles: FileStore = {
        do {
            let files = try RootedFileStore(root: libraryDirectory)
            try files.createRoot()
            return files
        } catch {
            libraryInitializationFailed = true
            warnAboutLibrary()
            return UnavailableFileStore()
        }
    }()
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
    private lazy var library = LibraryService(library: libraryFiles, data: dataFiles,
        clock: clock, entropy: SystemEntropy(), keyedStores: [values, usage])
    private lazy var index = PromptIndex(service: library, usage: usage, clock: clock)
    private lazy var clipboard = GTKClipboard(owner: panel.clipboardOwner)
    private lazy var fill = FillService(values: values, clipboard: clipboard, clock: clock,
        timeZone: { TimeZone.current })
    private lazy var watcher: LibraryWatcher? = {
        guard let raw = try? RootedFileWatcher(root: libraryDirectory, log: log) else { return nil }
        return LibraryWatcher(watcher: raw, scheduler: scheduler)
    }()

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
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.application = application
        log = StandardErrorLog()
        mainThread = GLibMainThread()
        runner = LinuxToolRunner(environment: environment)
        session = LinuxSessionProbe(environment: environment)
        scheduler = GLibScheduler()
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
        if firstRun.needsSetup { showSetup() } else { startLibrary(); pickerModel.open() }
    }

    private func showSetup() {
        setupWindow.show()
        do {
            try firstRun.recordPresentation()
        } catch {
            log.write(.warning, "Could not save first-run Setup state; Setup will reopen next launch")
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

    private func startLibrary() {
        guard !libraryStarted else { return }
        libraryStarted = true
        // Establish the hook/view before a rebuild publishes its first results.
        _ = pickerModel
        do {
            try Self.startLibrary(index: index, watcher: watcher) { [weak self, weak index] changes in
                guard let self, let index else { return }
                self.apply(changes, to: index)
            }
        } catch {
            degradeLibrary()
        }
    }

    static func startLibrary(index: PromptIndex, watcher: LibraryWatcher?,
                             onChange: @escaping @Sendable (LibraryChangeSet) -> Void) throws {
        guard let watcher else { throw FileStoreError.ioFailure }
        // Arm before rebuilding so saves cannot fall between the index scan
        // and the watcher's silent baseline. GLib batches cannot interleave
        // with this synchronous rebuild; reloading an indexed path is idempotent.
        try watcher.start(onChange)
        try index.rebuild()
    }

    private func apply(_ changes: LibraryChangeSet, to index: PromptIndex) {
        do {
            // Root loss keeps the index read-only in memory (§11.5).
            try (libraryFiles as? RootedFileStore)?.requireRoot()
        } catch {
            degradeLibrary()
            return
        }
        do {
            try index.apply(changes)
        } catch {
            warnAboutLibrary()
            do { try index.rebuild() }
            catch { degradeLibrary() }
        }
    }

    private func warnAboutLibrary() {
        guard !libraryWarningLogged else { return }
        libraryWarningLogged = true
        log.write(.warning, "Library unavailable or refresh failed; keeping cached prompts")
    }

    private func degradeLibrary() {
        watcher?.stop()
        pickerModel.libraryAvailable = false
        warnAboutLibrary()
    }

    private func handle(_ intent: PickerModel.Intent) {
        let url: URL
        switch intent {
        case .openLibrary: url = libraryDirectory
        case .edit(_, let path):
            guard (try? FileStorePath.validate(path)) != nil else { return }
            url = libraryDirectory.appendingPathComponent(path)
        }
        pickerModel.dismiss()
        mainThread.run { [weak self] in
            guard let self else { return }
            gtk_show_uri(mp_window(self.panel.clipboardOwner), url.absoluteString, UInt32(GDK_CURRENT_TIME))
        }
    }

    private func createPrompt(titled title: String) {
        guard pickerModel.libraryAvailable else { return }
        do {
            let path = try library.availablePath(for: LinuxPromptCreation.relativePath(title: title, now: clock.now()))
            let document = try PromptCodec.newDocument(title: title, body: LinuxStrings.newPromptBody)
            let entry = try library.save(document, at: path)
            do { try index.apply(LibraryChangeSet(created: [path])) }
            catch { log.write(.warning, "Prompt saved; immediate index refresh failed") }
            handle(.edit(identity: entry.identity, relativePath: path))
        } catch {
            panel.showStatus(LinuxStrings.createPromptFailed)
            log.write(.warning, "Could not create a prompt; check library and app-data permissions")
        }
    }

    func shutdown() {
        if libraryStarted { watcher?.stop() }
        hotkey.shutdown()
        remoteDesktop.shutdown()
        portal.shutdown()
    }

    func runSelfTest(done: @escaping (SelfTestReport) -> Void) {
        selfTest.run(done: done)
    }
}
#endif
