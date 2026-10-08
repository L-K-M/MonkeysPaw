#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// The Linux composition root: only this type assembles platform drivers.
final class LinuxEnvironment {
    let log: LogSink
    let mainThread: MainThread
    private let session: LinuxSessionProbe
    private let runner: LinuxToolRunner
    private let scheduler: Scheduler
    private let hotkey: LinuxHotkeyBackend
    private let firstRun: LinuxFirstRunState

    // GApplication can dispatch a cold action without "activate". A stored lazy
    // panel covers both paths and keeps the Swift wrapper alive while hidden.
    private(set) lazy var panel = LinuxPanel(application: application)
    private(set) lazy var panelModel: PanelModel = {
        let model = PanelModel(delivery: delivery)
        panel.bind(model: model) { [weak self] in self?.showSetup() }
        return model
    }()

    private lazy var delivery = DeliveryService(
        panel: panel, focus: LinuxFocusTracker(session: session, runner: runner),
        clipboard: GTKClipboard(owner: panel.clipboardOwner),
        injectors: [XdotoolPasteInjector(runner: runner), YdotoolPasteInjector(runner: runner)],
        notifier: GTKNotifier(application: application, session: session), session: session,
        scheduler: scheduler, mainThread: mainThread, failureCache: SessionPasteFailureCache())
    private lazy var selfTest = SelfTest(
        target: GTKSelfTestTarget(application: application), delivery: delivery,
        session: session, scheduler: scheduler, mainThread: mainThread)
    private lazy var shortcuts = ShortcutService(backend: hotkey, scheduler: scheduler, mainThread: mainThread)
    private(set) lazy var setupModel = SetupModel(setup: SetupService(
        probe: LinuxSetupProbe(application: application, runner: runner, hotkey: hotkey,
                               session: session, mainThread: mainThread),
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
        firstRun = LinuxFirstRunState(paths: LinuxPaths(environment: environment))
        switch session.currentSession() {
        case .gnomeWayland, .gnomeX11:
            hotkey = GnomeKeybindingBackend(runner: runner, mainThread: mainThread)
        default:
            hotkey = ManualHotkeyBackend()
        }
    }

    /// Start only in the registered primary, not remote invocations or unit tests.
    func start() {
        hotkey.onChange = { [weak self] in self?.setupModel.refresh() }
        let bindings = HotkeyAction.allCases.reduce(into: [HotkeyAction: Accelerator]()) { result, action in
            result[action] = Accelerator.defaultBinding(for: action)
        }
        shortcuts.configure(bindings) { [weak self] action in
            guard action == .togglePicker else { return }
            self?.togglePicker()
        }
    }

    func activateToggle() {
        // A cold action can race the queued registration. It must still show the
        // picker once, then later actions go through verification and debounce.
        if !hotkey.fire(.togglePicker) { togglePicker() }
    }

    func presentFromLauncher() {
        if firstRun.needsSetup { showSetup() } else { panelModel.show() }
    }

    private func showSetup() {
        setupWindow.show()
        do {
            try firstRun.recordPresentation()
        } catch {
            log.write(.warning, "Could not save first-run Setup state; Setup will reopen next launch")
        }
    }

    func togglePicker() {
        // A buried picker needs presenting, matching M0b's toggle semantics.
        if panel.isActiveAndVisible { panelModel.cancel() } else { panelModel.show() }
    }

    func runSelfTest(done: @escaping (SelfTestReport) -> Void) {
        selfTest.run(done: done)
    }
}
#endif
