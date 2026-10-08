import AppKit
import MonkeysPawCore
import SwiftUI

/// The macOS composition root owns the drivers and the resident status item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let makeFocusTracker: (MainThread, Scheduler) -> WorkspaceFocusTracker
    private let scheduler: Scheduler
    private let makePanelController: (MainThread, Scheduler, LogSink) -> PanelController
    private var panelController: PanelController?
    private var panelPresentation: PanelViewState?
    private var setupWindow: SetupWindowController?
    private var focusTracker: WorkspaceFocusTracker?
    private var shortcuts: ShortcutService?
    private var statusItem: NSStatusItem?
    private(set) var panelModel: PanelModel?
    private(set) var setupModel: SetupModel?

    /// Hosted tests replace workspace/AX access while exercising the real UI wiring.
    init(makeFocusTracker: @escaping (MainThread, Scheduler) -> WorkspaceFocusTracker = {
        WorkspaceFocusTracker(mainThread: $0, scheduler: $1)
    }, scheduler: Scheduler = DispatchScheduler(),
         makePanelController: @escaping (MainThread, Scheduler, LogSink) -> PanelController = {
             PanelController(mainThread: $0, scheduler: $1, log: $2)
         }) {
        self.makeFocusTracker = makeFocusTracker
        self.scheduler = scheduler
        self.makePanelController = makePanelController
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let log = OSLogSink()
        compose(log: log)
        // Graph construction is safe under hosted XCTest. Native registrations,
        // status items, first-run UI and prompts belong beyond this gate.
        guard !Self.isRunningTests else { return }

        focusTracker?.startTrackingActivations()
        if let accelerator = Accelerator.defaultBinding(for: .togglePicker) {
            shortcuts?.configure([.togglePicker: accelerator]) { [weak self] action in
                guard action == .togglePicker else { return }
                self?.togglePanel()
            }
        }

        installMainMenu()
        installStatusItem()
        log.write(.info, "Application started")

        // M1's first-run step is Setup (§6.4); library onboarding arrives in M2.
        let setupKey = "hasShownDeliverySetup"
        if !UserDefaults.standard.bool(forKey: setupKey) {
            showSetup()
            UserDefaults.standard.set(true, forKey: setupKey)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Returning from System Settings refreshes grants and registration state.
        setupModel?.refresh()
    }

    private func compose(log: LogSink) {
        let mainThread = DispatchMainThread()
        let scheduler = self.scheduler
        let focus = makeFocusTracker(mainThread, scheduler)
        let panel = makePanelController(mainThread, scheduler, log)
        let hotkeys = CarbonHotkeyBackend()
        let session = MacSessionProbe()
        let clipboard = PasteboardClipboard()
        let notifier = UserNotificationNotifier()
        let cgEvent = CGEventPasteInjector()
        let appleScript = AppleScriptPasteInjector()
        let failureCache = SessionPasteFailureCache()
        let delivery = DeliveryService(panel: panel, focus: focus, clipboard: clipboard,
                                       injectors: [cgEvent, appleScript], notifier: notifier,
                                       session: session, scheduler: scheduler,
                                       mainThread: mainThread, failureCache: failureCache)
        let shortcuts = ShortcutService(backend: hotkeys, scheduler: scheduler, mainThread: mainThread)
        let target = TextFieldSelfTestTarget()
        let selfTest = SelfTest(target: target, delivery: delivery, session: session,
                                scheduler: scheduler, mainThread: mainThread)
        let probe = MacSetupProbe(hotkeys: hotkeys, mainThread: mainThread)
        let setup = SetupService(probe: probe, session: session, shortcuts: shortcuts,
                                 selfTest: selfTest, mainThread: mainThread)
        let model = PanelModel(delivery: delivery)
        let presentation = PanelViewState(model: model)
        panel.rootView = { [weak presentation] in
            guard let presentation else { return AnyView(EmptyView()) }
            return AnyView(PanelView(presentation: presentation))
        }
        panel.onCancel = { [weak model] in model?.cancel() }
        panel.onHide = { reason in
            switch reason {
            case .delivery: focus.prepareForRestore(.delivery)
            case .dismissal: focus.prepareForRestore(.dismissal)
            case .blur: focus.prepareForRestore(.blur)
            }
        }

        panelController = panel
        panelPresentation = presentation
        panelModel = model
        focusTracker = focus
        self.shortcuts = shortcuts
        let setupModel = SetupModel(setup: setup)
        self.setupModel = setupModel
        setupWindow = SetupWindowController(model: setupModel)
    }

    private func installMainMenu() {
        // LSUIElement hides the menu bar, but AppKit still routes editing key
        // equivalents through its items to the first responder.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit \(AppIdentity.displayName)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Leave targets unset so the responder chain finds the focused text view.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSStandardKeyBindingResponding.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "text.quote",
                                     accessibilityDescription: AppIdentity.displayName)
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let show = menu.addItem(withTitle: Strings.showPanel, action: #selector(showPanel),
                                keyEquivalent: "")
        show.target = self
        let setup = menu.addItem(withTitle: Strings.setup, action: #selector(showSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func showPanel() {
        guard panelController?.isVisible != true else { return }
        panelModel?.show()
    }

    private func togglePanel() {
        if panelController?.isVisible == true {
            panelModel?.cancel()
        } else {
            panelModel?.show()
        }
    }

    @objc private func showSetup() {
        // Revoke older retries and suppress this cancellation's restore before
        // presenting Setup. Native key-window transitions may still be pending.
        focusTracker?.cancelPendingRestoration()
        panelController?.cancelForOwnedWindow()
        setupWindow?.show()
    }

    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
