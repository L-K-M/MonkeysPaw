import AppKit
import MonkeysPawCore
import SwiftUI

/// The macOS composition root owns the drivers and the resident status item.
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum LibrarySwitchResult: Equatable {
        case switched
        case deliveryInFlight
        case invalidTarget(FileStoreError)
        case libraryUnavailable(FileStoreError)
        case settingsNotSaved(SettingsError)

        var outcome: LibrarySwitchOutcome {
            switch self {
            case .switched: return .switched
            case .deliveryInFlight: return .deliveryInFlight
            case .invalidTarget(let error): return .invalidTarget(.rejectedByStore(error))
            case .libraryUnavailable(let error): return .libraryUnavailable(error)
            case .settingsNotSaved(let error): return .settingsNotSaved(error)
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
    private let revealLibraryURI: (URL) -> Void
    private let folderChooser: SettingsWindowController.FolderChooser
    private let windowActivation: WindowActivationCoordinator
    private var panelController: PanelController?
    private(set) var pickerPresentation: PickerViewState?
    private var setupWindow: SetupWindowController?
    private(set) var settingsWindow: SettingsWindowController?
    private var focusTracker: WorkspaceFocusTracker?
    private var shortcuts: ShortcutService?
    private var statusItem: NSStatusItem?
    private(set) var pickerModel: PickerModel?
    private(set) var setupModel: SetupModel?
    private(set) var settingsModel: SettingsModel?
    private(set) var generalSettingsModel: GeneralSettingsModel?
    private(set) var shortcutsSettingsModel: ShortcutsSettingsModel?
    private var dataFiles: FileStore?
    private var values: ValuesStore?
    private var usage: UsageStore?
    private var fill: FillService?
    private var delivery: DeliveryService?
    private var libraryFiles: FileStore?
    private var library: LibraryService?
    private var index: PromptIndex?
    private var watcher: LibraryWatcher?
    private var libraryGeneration: UInt64 = 0
    private var libraryStarted = false
    private var libraryWarningLogged = false
    private var log: LogSink?
    private let clock = SystemClock()

    /// Hosted tests replace workspace/AX access while exercising the real UI wiring.
    init(libraryRoot: URL? = nil, dataRoot: URL? = nil,
         legacyFirstRun: LegacyFirstRun? = nil, recordLegacySetup: (() -> Void)? = nil,
         launchURI: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
         revealLibrary: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
         folderChooser: @escaping SettingsWindowController.FolderChooser = SettingsWindowController.chooseFolder,
         setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { _ = NSApp.setActivationPolicy($0) },
         activateApplication: @escaping () -> Void = { NSApp.activate() },
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
        revealLibraryURI = revealLibrary
        self.folderChooser = folderChooser
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

    deinit { watcher?.stop() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The hosted application's default delegate has production roots.
        // Only explicitly injected test graphs may access the filesystem.
        guard !Self.isRunningTests || rootsAreInjected else { return }
        let log = CompositeLogSink(
            sinks: [OSLogSink(), FileLogSink(dataDirectory: dataDirectory)],
            policy: LogLevelPolicy(environmentValue: ProcessInfo.processInfo.environment["MONKEYSPAW_LOG"]))
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
        if settingsModel?.needsSetupPresentation == true { showSetup() }
    }

    func applicationWillTerminate(_ notification: Notification) { watcher?.stop() }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Returning from System Settings refreshes grants and registration state.
        setupModel?.refresh()
        shortcutsSettingsModel?.refresh()
    }

    private func compose(log: LogSink) {
        let mainThread = self.mainThread
        let scheduler = self.scheduler
        let focus = makeFocusTracker(mainThread, scheduler)
        let panel = makePanelController(mainThread, scheduler, log)
        let hotkeys = CarbonHotkeyBackend()
        let session = MacSessionProbe()
        let clipboard = PasteboardClipboard()
        let notifier: UserNotificationNotifier
        if Self.isRunningTests {
            notifier = UserNotificationNotifier(requestAuthorization: { _, completion in completion(false) })
        } else {
            notifier = UserNotificationNotifier()
        }
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
        let data: FileStore
        do { data = try RootedFileStore(root: dataDirectory) }
        catch {
            data = UnavailableFileStore()
            log.write(.warning, "App data unavailable; settings, remembered values and usage cannot be saved")
        }
        let values = ValuesStore(files: data)
        let usage = UsageStore(files: data, clock: clock)
        let settings = SettingsService(store: SettingsStore(files: data, legacyFirstRun: legacyFirstRun))
        let settingsModel = SettingsModel(settings: settings)
        self.settingsModel = settingsModel
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
        panel.onHide = { reason in
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
            files = try prepareLibrary(at: libraryDirectory, location: choice == nil ? .platformDefault : .chosen)
        } catch {
            files = UnavailableFileStore()
            libraryAvailable = false
            warnAboutLibrary(error as? FileStoreError)
        }
        installLibrary(files: files, availability: libraryAvailable)
        let general = GeneralSettingsModel(settings: settingsModel,
            library: SettingsLibraryLocation(owner: self), mainThread: mainThread)
        let shortcutSettings = ShortcutsSettingsModel(shortcuts: shortcuts, setup: setup)
        generalSettingsModel = general
        shortcutsSettingsModel = shortcutSettings
        settingsWindow = SettingsWindowController(general: general, shortcuts: shortcutSettings,
            mainThread: mainThread, activation: windowActivation, folderChooser: folderChooser,
            openSetup: { [weak self] in self?.showSetup() })
    }

    /// UI-thread composition intent for the later General/onboarding views.
    /// A failed settings write keeps the new graph for this session (§5.1).
    /// libraryUnavailable leaves the new graph installed but degraded, as at
    /// launch, without saving the choice; another switch or a relaunch recovers.
    func switchLibrary(to url: URL?) -> LibrarySwitchResult {
        assert(Thread.isMainThread, "Library replacement is main-thread-confined")
        guard let pickerModel, let settingsModel else { return .libraryUnavailable(.ioFailure) }
        guard pickerModel.state != .delivering else { return .deliveryInFlight }
        pickerModel.dismiss()

        let directory = url ?? defaultLibraryDirectory
        let files: FileStore
        do { files = try prepareLibrary(at: directory, location: url == nil ? .platformDefault : .chosen) }
        catch { return .invalidTarget(error as? FileStoreError ?? .ioFailure) }

        // Delivery's queue can still be finishing a guarded dismissal or Setup
        // self-test. Hide the old view now, before replacing its native root.
        panelController?.hide()
        delivery?.invalidatePendingPresentation()
        libraryGeneration &+= 1
        // Stop before releasing: FSEvents marshals teardown via its serial queue.
        watcher?.stop()
        watcher = nil
        pickerModel.onChange = nil
        index?.setOnChange(nil)
        pickerPresentation = nil
        self.pickerModel = nil
        libraryDirectory = directory
        libraryStarted = false
        libraryWarningLogged = false
        installLibrary(files: files, availability: true)
        if case .failure(let error) = startLibrary() { return .libraryUnavailable(error) }

        // SettingsModel forwards to the shared SettingsService and retains its
        // typed error. Never persist a choice whose watcher/rebuild failed.
        if let url { settingsModel.setLibraryFolder(url.path) }
        else { settingsModel.clearLibraryFolder() }
        if let error = settingsModel.error { return .settingsNotSaved(error) }
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
            _ = try files.listFiles()
            return files
        } catch let error as FileStoreError { throw error }
        catch { throw FileStoreError.ioFailure }
    }

    private func installLibrary(files: FileStore, availability: Bool) {
        guard let data = dataFiles, let values, let usage, let fill, let delivery,
              let panel = panelController, let focus = focusTracker, let log else { return }
        let generation = libraryGeneration
        let isCurrent: () -> Bool = { [weak self] in self?.libraryGeneration == generation }
        // Check inside the UI hop, not before queueing: an old index, snapshot
        // or view publish may already be waiting on DispatchQueue.main.
        let libraryMain = LibraryMainThread(main: mainThread, isCurrent: isCurrent)
        let library = LibraryService(library: files, data: data, clock: clock,
            entropy: SystemEntropy(), keyedStores: [values, usage])
        let index = PromptIndex(service: library, usage: usage, clock: clock)
        let model = PickerModel(index: index, fill: fill, delivery: delivery, main: libraryMain)
        model.libraryAvailable = availability
        let presentation = PickerViewState(model: model, mainThread: libraryMain, isCurrent: isCurrent,
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
        if let raw = try? makeFileWatcher(libraryDirectory, log) {
            watcher = LibraryWatcher(watcher: raw, scheduler: scheduler)
        }
    }

    @discardableResult
    private func startLibrary() -> Result<Void, FileStoreError> {
        guard !libraryStarted, let index, let pickerModel else { return .failure(.ioFailure) }
        libraryStarted = true
        guard pickerModel.libraryAvailable else { degradeLibrary(); return .failure(.ioFailure) }
        let generation = libraryGeneration
        do {
            // The picker/index hook is installed before this first publish.
            try Self.startLibrary(index: index, watcher: watcher) { [weak self] update in
                self?.mainThread.run { [weak self] in
                    guard let self, self.libraryGeneration == generation,
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
        let generation = libraryGeneration
        mainThread.run { [weak self] in
            guard let self, self.libraryGeneration == generation else { return }
            self.launchURI(url)
        }
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

    func installMainMenu() {
        // AppKit routes editing key equivalents through the main menu even
        // while the accessory policy hides it.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        addSettingsItem(to: appMenu)
        appMenu.addItem(.separator())
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

        item.menu = makeStatusMenu()
        statusItem = item
    }

    /// Pure menu construction lets hosted tests exercise the real equivalents
    /// without creating a status item or installing native hotkeys.
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let show = menu.addItem(withTitle: Strings.showPanel, action: #selector(showPanel),
                                keyEquivalent: "")
        show.target = self
        addSettingsItem(to: menu)
        let setup = menu.addItem(withTitle: Strings.setup, action: #selector(showSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        return menu
    }

    private func addSettingsItem(to menu: NSMenu) {
        let settings = menu.addItem(withTitle: Strings.settings, action: #selector(showSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
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
        settingsModel?.markSetupPresented()
        recordLegacySetup()
    }

    @objc func showSettings() {
        mainThread.run { [weak self] in
            guard let self else { return }
            self.focusTracker?.cancelPendingRestoration()
            self.panelController?.cancelForOwnedWindow()
            // A summon or dismissal may be queued behind an older restore.
            // Close model state even if its native panel has not appeared yet.
            self.pickerModel?.dismiss()
            self.panelController?.hide()
            self.delivery?.invalidatePendingPresentation()
            self.settingsWindow?.show()
        }
    }

    fileprivate var defaultLibraryPath: String { defaultLibraryDirectory.path }

    fileprivate func revealLibrary() { revealLibraryURI(libraryDirectory) }

    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
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
