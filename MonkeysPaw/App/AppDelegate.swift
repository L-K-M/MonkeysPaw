import AppKit
import MonkeysPawCore
import SwiftUI

/// The macOS composition root owns the drivers and the resident status item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let makeFocusTracker: (MainThread, Scheduler) -> WorkspaceFocusTracker
    private let scheduler: Scheduler
    private let makePanelController: (MainThread, Scheduler, LogSink) -> PanelController
    private let mainThread: MainThread = DispatchMainThread()
    private let libraryDirectory: URL
    private let dataDirectory: URL
    private let rootsAreInjected: Bool
    private let launchURI: (URL) -> Void
    private var panelController: PanelController?
    private(set) var pickerPresentation: PickerViewState?
    private var setupWindow: SetupWindowController?
    private var focusTracker: WorkspaceFocusTracker?
    private var shortcuts: ShortcutService?
    private var statusItem: NSStatusItem?
    private(set) var pickerModel: PickerModel?
    private(set) var setupModel: SetupModel?
    private var libraryFiles: FileStore?
    private var library: LibraryService?
    private var index: PromptIndex?
    private var watcher: LibraryWatcher?
    private var libraryStarted = false
    private var libraryWarningLogged = false
    private var log: LogSink?
    private let clock = SystemClock()

    /// Hosted tests replace workspace/AX access while exercising the real UI wiring.
    init(libraryRoot: URL? = nil, dataRoot: URL? = nil,
         launchURI: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
         makeFocusTracker: @escaping (MainThread, Scheduler) -> WorkspaceFocusTracker = {
        WorkspaceFocusTracker(mainThread: $0, scheduler: $1)
    }, scheduler: Scheduler = DispatchScheduler(),
         makePanelController: @escaping (MainThread, Scheduler, LogSink) -> PanelController = {
             PanelController(mainThread: $0, scheduler: $1, log: $2)
         }) {
        precondition((libraryRoot == nil) == (dataRoot == nil), "Inject libraryRoot and dataRoot together")
        self.makeFocusTracker = makeFocusTracker
        self.scheduler = scheduler
        self.makePanelController = makePanelController
        rootsAreInjected = libraryRoot != nil && dataRoot != nil
        let home = FileManager.default.homeDirectoryForCurrentUser
        libraryDirectory = libraryRoot ?? home.appendingPathComponent("Documents/MonkeysPaw", isDirectory: true)
        dataDirectory = dataRoot ?? home.appendingPathComponent(
            "Library/Application Support/" + AppIdentity.macOSBundleID, isDirectory: true)
        self.launchURI = launchURI
        super.init()
    }

    deinit { watcher?.stop() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The hosted application's default delegate has production roots.
        // Only explicitly injected test graphs may access the filesystem.
        guard !Self.isRunningTests || rootsAreInjected else { return }
        let log = CompositeLogSink(sinks: [OSLogSink(), FileLogSink(dataDirectory: dataDirectory)], policy: LogLevelPolicy(environmentValue: ProcessInfo.processInfo.environment["MONKEYSPAW_LOG"]))
        self.log = log
        compose(log: log)
        startLibrary()
        // Graph construction is safe under hosted XCTest. Native registrations,
        // status items, first-run UI and prompts belong beyond this gate.
        guard !Self.isRunningTests else { return }

        focusTracker?.startTrackingActivations()
        if let accelerator = Accelerator.defaultBinding(for: .togglePicker) {
            shortcuts?.configure([.togglePicker: accelerator]) { [weak self] action in
                guard action == .togglePicker else { return }
                self?.togglePicker()
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

    func applicationWillTerminate(_ notification: Notification) { watcher?.stop() }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Returning from System Settings refreshes grants and registration state.
        setupModel?.refresh()
    }

    private func compose(log: LogSink) {
        let mainThread = self.mainThread
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
        let files: FileStore
        var libraryAvailable = true
        do {
            let rooted = try RootedFileStore(root: libraryDirectory)
            try rooted.createRoot()
            files = rooted
        } catch {
            files = UnavailableFileStore()
            libraryAvailable = false
            warnAboutLibrary()
        }
        let data: FileStore
        do { data = try RootedFileStore(root: dataDirectory) }
        catch {
            data = UnavailableFileStore()
            log.write(.warning, "App data unavailable; remembered values and usage cannot be saved")
        }
        let values = ValuesStore(files: data)
        let usage = UsageStore(files: data, clock: clock)
        let library = LibraryService(library: files, data: data, clock: clock,
            entropy: SystemEntropy(), keyedStores: [values, usage])
        let index = PromptIndex(service: library, usage: usage, clock: clock)
        let fill = FillService(values: values, clipboard: clipboard, clock: clock, timeZone: { TimeZone.current })
        let model = PickerModel(index: index, fill: fill, delivery: delivery, main: mainThread)
        model.libraryAvailable = libraryAvailable
        let presentation = PickerViewState(model: model, mainThread: mainThread,
            requestedIntent: { [weak self] in self?.handle($0) },
            createPrompt: { [weak self] in self?.createPrompt(titled: $0) })
        panel.rootView = { [weak presentation] in
            guard let presentation else { return AnyView(EmptyView()) }
            return AnyView(PickerView(presentation: presentation))
        }
        panel.onCancel = { [weak model] in model?.dismiss() }
        panel.onEscape = { [weak model] in model?.escape() }
        panel.onShow = { [weak presentation] in presentation?.didShow() }
        panel.onKey = { [weak presentation, weak panel] event, kind in
            if presentation?.route(event, fieldKind: kind) == true { return true }
            guard presentation?.model.state == .picker else { return false }
            return panel?.forwardTypingToSearch(event) ?? false
        }
        focus.onCapture = { [weak presentation] in
            presentation?.pasteTarget = Self.pasteTargetName(for: $0)
        }
        panel.onHide = { reason in
            switch reason {
            case .delivery: focus.prepareForRestore(.delivery)
            case .dismissal: focus.prepareForRestore(.dismissal)
            case .blur: focus.prepareForRestore(.blur)
            }
        }

        panelController = panel
        pickerPresentation = presentation
        pickerModel = model
        libraryFiles = files
        self.library = library
        self.index = index
        if let raw = try? RootedFileWatcher(root: libraryDirectory, log: log) {
            watcher = LibraryWatcher(watcher: raw, scheduler: scheduler)
        }
        focusTracker = focus
        self.shortcuts = shortcuts
        let setupModel = SetupModel(setup: setup)
        self.setupModel = setupModel
        setupWindow = SetupWindowController(model: setupModel)
    }

    private func startLibrary() {
        guard !libraryStarted, let index, let pickerModel else { return }
        libraryStarted = true
        guard pickerModel.libraryAvailable else { degradeLibrary(); return }
        do {
            // compose installed the picker/index hook before this first publish.
            try Self.startLibrary(index: index, watcher: watcher) { [weak self] update in
                self?.mainThread.run { [weak self] in
                    guard let self, self.pickerModel?.libraryAvailable == true else { return }
                    switch update {
                    case .changes(let changes): self.apply(changes, to: index)
                    case .rootUnavailable(let error): self.degradeLibrary(error)
                    }
                }
            }
        } catch { degradeLibrary(error as? FileStoreError) }
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
        watcher?.stop()
        pickerModel?.libraryAvailable = false
        warnAboutLibrary(error)
    }

    private func handle(_ intent: PickerModel.Intent) {
        guard pickerModel?.libraryAvailable == true else {
            pickerPresentation?.showStatus(Strings.libraryUnavailable)
            return
        }

        let url: URL
        switch intent {
        case .openLibrary: url = libraryDirectory
        case .edit(_, let path):
            guard (try? FileStorePath.validate(path)) != nil else {
                pickerPresentation?.showStatus(Strings.promptFileUnavailable)
                return
            }
            url = libraryDirectory.appendingPathComponent(path)
        }
        pickerModel?.dismiss()
        mainThread.run { [weak self] in self?.launchURI(url) }
    }

    private func createPrompt(titled title: String) {
        guard pickerModel?.libraryAvailable == true, let library, let index else { return }
        do {
            let path = try library.availablePath(for: PromptCreation.relativePath(title: title, now: clock.now()))
            let document = try PromptCodec.newDocument(title: title, body: Strings.newPromptBody)
            let entry = try library.save(document, at: path)
            do { try index.apply(LibraryChangeSet(created: [RelativePath(path)])) }
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
        pickerModel?.open()
    }

    func togglePicker() {
        if panelController?.isActiveAndVisible == true {
            pickerModel?.dismiss()
        } else {
            pickerModel?.open()
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
