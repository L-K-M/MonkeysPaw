import AppKit
import Combine
import SwiftUI
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPaw

/// Synthetic reports cover rendering without widening Core's production API.
/// Navigation and outage tests use the real public Account/Sync/native graph.
final class MacSyncStatusViewTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var delegate: AppDelegate!
    private var panel: PanelController!
    private var files: RootedFileStore!
    private var transport: MacStatusHTTP!
    private var clipboard: MacStatusClipboard!
    private var originalWindows: Set<ObjectIdentifier> = []
    private var activations = 0
    private var terminationReplies: [Bool] = []

    override func setUpWithError() throws {
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library", isDirectory: true)
        data = directory.appendingPathComponent("data", isDirectory: true)
        files = try RootedFileStore(root: root)
        try files.createRoot()
        transport = MacStatusHTTP()
        clipboard = MacStatusClipboard()
    }

    override func tearDown() {
        transport.releasePull()
        if let delegate, delegate.applicationShouldTerminate(NSApp) == .terminateLater {
            XCTAssertTrue(spin { self.terminationReplies.last == true })
        }
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        delegate = nil
        panel = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testPickerStatusMatrixPreservesTargetAndKeyHints() throws {
        start()
        let source = MacStatusSource()
        let model = SyncStatusModel(sync: source, mainThread: DispatchMainThread())
        let status = SyncStatusViewState(surface: .picker, main: DispatchMainThread(), makeModel: { model }, navigate: { _ in })
        let picker = try XCTUnwrap(delegate.pickerPresentation)
        let presentation = PickerViewState(model: picker.model, mainThread: DispatchMainThread(), syncStatus: status,
            requestedIntent: { _ in }, createPrompt: { _ in })
        presentation.pasteTarget = "Remembered editor"
        presentation.didShow()
        let focusRevision = presentation.focusRevision
        assertMatrix(source, model: model, status: status)
        XCTAssertEqual(presentation.focusRevision, focusRevision)
        XCTAssertEqual(presentation.pasteTarget, "Remembered editor")
        XCTAssertTrue(Strings.pasteTarget(presentation.pasteTarget).contains("Remembered editor"))
        XCTAssertFalse(Strings.pickerHint.isEmpty)
        let host = NSHostingView(rootView: PickerView(presentation: presentation))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        host.layoutSubtreeIfNeeded()
        presentation.didHide()
        model.retire()
    }

    func testLibraryStatusMatrixIncludesCountsAndLastSuccess() throws {
        start()
        let source = MacStatusSource()
        let model = SyncStatusModel(sync: source, mainThread: DispatchMainThread())
        let status = SyncStatusViewState(surface: .library, main: DispatchMainThread(), makeModel: { model }, navigate: { _ in })
        let presentation = try XCTUnwrap(delegate.libraryWindow?.presentation)
        presentation.rebind(to: try XCTUnwrap(delegate.libraryBrowserModel), editor: try XCTUnwrap(delegate.editorModel),
            libraryPath: root.path, available: true, syncStatus: status)
        presentation.didShow()
        let focusRevision = presentation.focusRevision
        assertMatrix(source, model: model, status: status)
        XCTAssertEqual(presentation.focusRevision, focusRevision)
        let host = NSHostingView(rootView: LibraryView(presentation: presentation))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        host.layoutSubtreeIfNeeded()
        model.retire()
    }

    func testExplicitActionsRecheckEligibilityAndRouteSignInToAccount() {
        let source = MacStatusSource()
        let model = SyncStatusModel(sync: source, mainThread: DispatchMainThread())
        var navigation: [SyncStatusAction] = []
        let view = SyncStatusViewState(surface: .picker, main: DispatchMainThread(), makeModel: { model }, navigate: { navigation.append($0) })
        view.show()
        var report = enabledReport()
        source.send(report)
        view.performPrimaryAction()
        XCTAssertEqual(source.requests, 1)
        report.phase = .resyncing
        source.send(report)
        view.perform(.syncNow)
        XCTAssertEqual(source.requests, 1)
        report.phase = .idle
        report.offline = true
        source.send(report)
        view.performPrimaryAction()
        XCTAssertEqual(source.requests, 2)
        report.needsSignIn = true
        report.enabled = false
        source.send(report)
        view.performPrimaryAction()
        view.perform(.syncNow)
        XCTAssertEqual(navigation, [.account, .account])
        XCTAssertEqual(source.requests, 2)
        view.retire()
        model.retire()
    }

    func testFileErrorsShowSortedFixedReasonsAndRouteOnlyCurrentRows() throws {
        let source = MacStatusSource()
        let model = SyncStatusModel(sync: source, mainThread: DispatchMainThread())
        var paths: [RelativePath] = []
        let view = SyncStatusViewState(surface: .library, main: DispatchMainThread(), makeModel: { model },
            navigate: { _ in XCTFail("Library error details do not navigate") }, openFile: { paths.append($0) })
        view.show()
        let sentinel = UUID().uuidString
        var report = enabledReport()
        report.counts.fileErrors = 3
        report.counts.conflicts = 2
        report.details = [.init(path: "z.md", code: sentinel), .init(path: "a.md", code: "forbidden"),
                          .init(path: "b.md", code: PromptIssueCode.invalidYAML.rawValue)]
        source.send(report)
        view.performPrimaryAction()
        XCTAssertTrue(view.state?.showsErrorDetails == true)
        XCTAssertEqual(view.state?.fileErrors.map(\.path.string), ["a.md", "b.md", "z.md"])
        XCTAssertEqual(view.state?.fileErrors.first?.reason, "The server did not allow this change. Refresh group access.")
        XCTAssertEqual(view.state?.fileErrors.last?.reason, "This file could not be synced.")
        XCTAssertFalse(view.state?.fileErrors.contains { $0.reason.contains(sentinel) || $0.code.contains(sentinel) } == true)
        XCTAssertEqual(view.additionalActions, [.syncNow, .conflicts])
        let error = try XCTUnwrap(view.state?.fileErrors.first)
        view.openError(error)
        XCTAssertEqual(paths, ["a.md"])
        view.dismissErrors()
        XCTAssertFalse(model.state.showsErrorDetails)
        report.details = []
        report.counts.fileErrors = 0
        source.send(report)
        view.openError(error)
        XCTAssertEqual(paths, ["a.md"], "A stale row cannot open another file")
        let composed = RelativePath("Caf\u{e9}.md")
        let decomposed = RelativePath("Cafe\u{301}.md")
        report.details = [.init(path: composed, code: "forbidden"), .init(path: decomposed, code: "forbidden")]
        report.counts.fileErrors = 2
        source.send(report)
        for error in model.state.fileErrors { view.openError(error) }
        XCTAssertEqual(paths.dropFirst().map { Array($0.string.utf8) },
            [Array(decomposed.string.utf8), Array(composed.string.utf8)])
        view.retire()
        model.retire()
    }

    func testBlockingErrorUsesFixedMessageAndRetainsLongErrorPaths() {
        let source = MacStatusSource()
        let model = SyncStatusModel(sync: source, mainThread: DispatchMainThread())
        let view = SyncStatusViewState(surface: .library, main: DispatchMainThread(), makeModel: { model }, navigate: { _ in })
        view.show()
        var report = enabledReport()
        report.blockingIssue = .invalidProtocol
        source.send(report)
        XCTAssertEqual(view.state?.errorMessage, "The server returned invalid sync data.")
        XCTAssertFalse(view.additionalActions.contains(.syncNow))
        view.performPrimaryAction()
        XCTAssertTrue(view.state?.fileErrors.isEmpty == true)
        XCTAssertTrue(view.state?.showsErrorDetails == true)
        view.perform(.syncNow)
        XCTAssertEqual(source.requests, 0)
        let path = (Array(repeating: String(repeating: "p", count: 100), count: 9) + ["prompt.md"]).joined(separator: "/")
        report.details = [.init(path: RelativePath(path), code: "forbidden")]
        report.counts.fileErrors = 1
        source.send(report)
        let host = NSHostingView(rootView: SyncStatusView(presentation: view))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.state?.fileErrors.first?.path.string, path)
        view.retire()
        model.retire()
    }

    func testDisabledPickerReusesSettingsAndSelectsAccount() throws {
        start()
        delegate.showSettings()
        let window = try XCTUnwrap(delegate.settingsWindow?.window)
        window.close()
        try openPicker()
        let view = try XCTUnwrap(delegate.pickerPresentation?.syncStatus)
        XCTAssertEqual(view.state?.footer, .disabled)
        view.performPrimaryAction()
        XCTAssertTrue(spin { window.isVisible && self.delegate.settingsWindow?.presentation.selectedTab == .account })
        XCTAssertTrue(delegate.settingsWindow?.window === window)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(delegate.pickerModel?.state, .closed)
        XCTAssertEqual(transport.pulls, 0)
    }

    func testSignInRequiredLibraryActionOpensAccountWithoutRetry() throws {
        start()
        transport.mode = .unauthorized
        try signIn()
        XCTAssertTrue(spin { self.delegate.syncStatusModel?.state.footer == .needsSignIn })
        delegate.showLibrary()
        let view = try XCTUnwrap(delegate.libraryWindow?.presentation.syncStatus)
        let before = transport.pulls
        view.performPrimaryAction()
        XCTAssertTrue(spin { self.delegate.settingsWindow?.window?.isVisible == true })
        XCTAssertEqual(delegate.settingsWindow?.presentation.selectedTab, .account)
        XCTAssertEqual(transport.pulls, before)
        XCTAssertTrue(delegate.pickerModel?.libraryAvailable == true)
    }

    func testPickerErrorsOpenLibraryAndFileRoutingHonorsUnsavedGuard() throws {
        try files.write(Data("Local\n".utf8), at: "local.md")
        try files.write(Data("---\nfields: broken\n---\n{{topic}}\n".utf8), at: "broken.md")
        start()
        try signIn()
        XCTAssertTrue(spin { self.delegate.syncStatusModel?.state.footer == .syncError })
        try openPicker()
        try XCTUnwrap(delegate.pickerPresentation?.syncStatus).performPrimaryAction()
        let library = try XCTUnwrap(delegate.libraryWindow?.presentation)
        let view = try XCTUnwrap(library.syncStatus)
        XCTAssertTrue(spin { self.delegate.libraryWindow?.window?.isVisible == true && view.state?.showsErrorDetails == true })
        XCTAssertFalse(panel.isVisible)
        let local = try XCTUnwrap(library.snapshot.rows.first { $0.relativePath == "local.md" })
        library.openPrompt(local.selection)
        XCTAssertTrue(spin { library.editorState.prompt == local.selection && library.editorState.status != .loading })
        library.edit("Unsaved local text")
        let error = try XCTUnwrap(view.state?.fileErrors.first { $0.path == "broken.md" })
        view.openError(error)
        let decision = try XCTUnwrap(library.editorState.pendingDecision)
        library.editor.resolveDecision(.cancel, id: decision.id)
        XCTAssertEqual(library.editorState.prompt, local.selection)
        XCTAssertTrue(library.editorState.isDirty)
        view.openError(error)
        library.editor.resolveDecision(.discard, id: try XCTUnwrap(library.editorState.pendingDecision).id)
        XCTAssertTrue(spin { library.editorState.prompt?.relativePath == "broken.md" && library.editorState.status != .loading })
    }

    func testConflictsOpenOriginFilterAndClearThePreviousTextFilter() throws {
        start()
        transport.mode = .conflicts
        try signIn()
        XCTAssertTrue(spin { self.delegate.syncStatusModel?.state.footer == .hasConflicts })
        delegate.libraryWindow?.presentation.setFilter("hidden by this filter")
        try openPicker()
        let view = try XCTUnwrap(delegate.pickerPresentation?.syncStatus)
        XCTAssertTrue(view.summary.contains("Conflicts: 1"))
        view.performPrimaryAction()
        let library = try XCTUnwrap(delegate.libraryWindow?.presentation)
        XCTAssertEqual(library.snapshot.selectedSection, .conflicts)
        XCTAssertEqual(library.snapshot.filter, "")
        XCTAssertEqual(library.snapshot.rows.map(\.relativePath.string), [MacStatusHTTP.copyPath])
        XCTAssertFalse(panel.isVisible)
    }

    func testLocalPickerFillAndCopyContinueDuringNetworkFailure() throws {
        try files.write(Data("Hello {{topic}}".utf8), at: "hello.md")
        start()
        transport.mode = .offline
        try signIn()
        XCTAssertTrue(spin { self.delegate.syncStatusModel?.state.footer == .offline })
        let before = activations
        let libraryWindow = delegate.libraryWindow?.window
        XCTAssertNil(libraryWindow)
        try openPicker()
        let picker = try XCTUnwrap(delegate.pickerModel)
        let view = try XCTUnwrap(delegate.pickerPresentation)
        view.setQuery("hello")
        XCTAssertEqual(picker.results.map(\.relativePath), ["hello.md"])
        XCTAssertEqual(view.syncStatus?.state?.footer, .offline)
        XCTAssertTrue(picker.libraryAvailable)
        picker.use(mode: .copyOnly)
        XCTAssertTrue(spin { picker.state == .fill && picker.fillModel?.builtinsResolved == true })
        let fill = try XCTUnwrap(picker.fillModel)
        fill.setValue("offline work", name: "topic")
        XCTAssertTrue(fill.canCopyOnly)
        fill.deliver(mode: .copyOnly)
        XCTAssertTrue(spin { picker.state == .done(.copiedOnly(.requested)) })
        XCTAssertEqual(clipboard.text, "Hello offline work")
        XCTAssertEqual(delegate.syncStatusModel?.state.footer, .offline)
        XCTAssertNil(delegate.libraryWindow?.window)
        XCTAssertNil(delegate.settingsWindow?.window)
        XCTAssertEqual(activations, before, "Background status reports must not activate owned windows")
        XCTAssertFalse(transport.sentOnMain)
    }

    func testLocalPasteDeliveryDispatchesWhileTheRealSyncServiceIsOffline() throws {
        try files.write(Data("Hello {{topic}}".utf8), at: "hello.md")
        start()
        transport.mode = .offline
        try signIn()
        XCTAssertTrue(spin { self.delegate.syncStatusModel?.state.footer == .offline })
        let clock = SystemClock()
        let dataFiles = try RootedFileStore(root: data)
        let values = ValuesStore(files: dataFiles)
        let usage = UsageStore(files: dataFiles, clock: clock)
        let library = LibraryService(library: files, data: dataFiles, clock: clock, entropy: SystemEntropy())
        let index = PromptIndex(service: library, usage: usage, clock: clock)
        try index.rebuild()
        let deliveryPorts = MacStatusDeliveryPorts()
        let delivery = DeliveryService(panel: deliveryPorts, focus: deliveryPorts, clipboard: clipboard,
            injectors: [deliveryPorts], notifier: deliveryPorts, session: deliveryPorts,
            scheduler: DispatchScheduler(), mainThread: DispatchMainThread(), failureCache: SessionPasteFailureCache())
        defer { delivery.shutdown() }
        let fill = FillService(values: values, clipboard: clipboard, clock: clock, timeZone: { .current })
        let picker = PickerModel(index: index, fill: fill, delivery: delivery, main: DispatchMainThread())
        let status = SyncStatusViewState(surface: .picker, main: DispatchMainThread(),
            makeModel: { [weak self] in self?.delegate.syncStatusModel }, navigate: { _ in XCTFail("No navigation during outage") })
        let presentation = PickerViewState(model: picker, mainThread: DispatchMainThread(), syncStatus: status,
            requestedIntent: { _ in }, createPrompt: { _ in })
        presentation.didShow()
        picker.open()
        picker.setQuery("hello")
        picker.use(mode: .paste(.standard))
        XCTAssertTrue(spin { picker.state == .fill && picker.fillModel?.builtinsResolved == true })
        let form = try XCTUnwrap(picker.fillModel)
        form.setValue("offline paste", name: "topic")
        XCTAssertTrue(form.deliverEnabled)
        form.deliver(mode: .paste(.standard))
        XCTAssertTrue(spin { picker.state == .done(.pasted(.cgEvent)) })
        XCTAssertEqual(clipboard.text, "Hello offline paste")
        XCTAssertEqual(deliveryPorts.events, ["show", "hide", "restore", "paste"])
        XCTAssertEqual(deliveryPorts.chords, [.standard])
        XCTAssertEqual(status.state?.footer, .offline)
        presentation.didHide()
    }

    func testLiveResyncAndExplicitRetryDoNotChangePickerFocusOrOpenWindows() throws {
        start()
        transport.mode = .held
        try signIn()
        XCTAssertTrue(spin { self.transport.hasHeldPull && self.delegate.syncStatusModel?.state.footer == .resyncing })
        XCTAssertNil(delegate.libraryWindow?.window)
        XCTAssertNil(delegate.settingsWindow?.window)
        try openPicker()
        let picker = try XCTUnwrap(delegate.pickerPresentation)
        let status = try XCTUnwrap(picker.syncStatus)
        XCTAssertEqual(status.state?.footer, .resyncing)
        picker.setQuery("keep this query")
        picker.pasteTarget = "Remembered target"
        let focusRevision = picker.focusRevision
        let activationCount = activations
        transport.mode = .normal
        transport.releasePull()
        XCTAssertTrue(spin { status.state?.footer == .offline })
        let before = transport.pulls
        status.performPrimaryAction()
        XCTAssertTrue(spin { status.state?.footer == .idle && status.state?.lastSuccess != nil })
        XCTAssertEqual(transport.pulls, before + 1)
        XCTAssertEqual(picker.model.query, "keep this query")
        XCTAssertEqual(picker.pasteTarget, "Remembered target")
        XCTAssertEqual(picker.focusRevision, focusRevision)
        XCTAssertEqual(activations, activationCount)
        XCTAssertNil(delegate.libraryWindow?.window)
        XCTAssertNil(delegate.settingsWindow?.window)
    }

    func testHiddenRetiredAndReplacedObserversDropQueuedUpdatesAndClicks() {
        let source = MacStatusSource()
        let first = SyncStatusModel(sync: source, mainThread: DispatchMainThread())
        let replacement = SyncStatusModel(sync: MacStatusSource(), mainThread: DispatchMainThread())
        var current = first
        let main = MacStatusQueuedMain()
        var navigation: [SyncStatusAction] = []
        let view = SyncStatusViewState(surface: .library, main: main, makeModel: { current }, navigate: { navigation.append($0) })
        view.show()
        var report = enabledReport()
        report.offline = true
        source.send(report)
        view.hide()
        main.flush()
        XCTAssertEqual(view.state?.footer, .disabled)
        view.show()
        XCTAssertEqual(view.state?.footer, .offline)
        report.counts.conflicts = 2
        source.send(report)
        current = replacement
        view.performPrimaryAction()
        XCTAssertEqual(view.state?.footer, .disabled)
        XCTAssertTrue(navigation.isEmpty, "A stale click cannot operate on a replacement graph")
        main.flush()
        XCTAssertEqual(view.state?.footer, .disabled)
        view.retire()
        source.send(enabledReport())
        main.flush()
        XCTAssertNil(view.state)
        first.retire()
        replacement.retire()
    }

    func testIndependentObserversSurviveHideAndViewDeinit() {
        let source = MacStatusSource()
        let model = SyncStatusModel(sync: source, mainThread: DispatchMainThread())
        var independent = 0
        var owner = 0
        model.onChange = { owner += 1 }
        let token = model.addObserver { _ in independent += 1 }
        var view: SyncStatusViewState? = SyncStatusViewState(surface: .picker, main: DispatchMainThread(), makeModel: { model }, navigate: { _ in })
        weak var released = view
        view?.show()
        view?.hide()
        view = nil
        XCTAssertNil(released)
        source.send(enabledReport())
        XCTAssertEqual(independent, 1)
        XCTAssertEqual(owner, 1)
        model.removeObserver(token)
        model.retire()
        XCTAssertEqual(source.observerCount, 0)
    }

    func testWorkerReportPublishesOnUIWithoutNavigation() {
        let source = MacStatusSource()
        let model = SyncStatusModel(sync: source, mainThread: DispatchMainThread())
        let view = SyncStatusViewState(surface: .library, main: DispatchMainThread(), makeModel: { model },
            navigate: { _ in XCTFail("A report must not navigate") })
        view.show()
        let changed = expectation(description: "UI status")
        let token = view.$state.dropFirst().sink { state in
            XCTAssertTrue(Thread.isMainThread)
            if state?.footer == .offline { changed.fulfill() }
        }
        DispatchQueue.global().async {
            var report = SyncReport()
            report.enabled = true
            report.offline = true
            source.send(report)
        }
        wait(for: [changed], timeout: 5)
        token.cancel()
        view.retire()
        model.retire()
    }

    func testStatusOnlyLibraryOpenKeepsIdleRootReplacementAndQuitSynchronous() throws {
        start()
        delegate.showLibrary()
        let window = try XCTUnwrap(delegate.libraryWindow?.window)
        let old = try XCTUnwrap(delegate.libraryWindow?.presentation.syncStatus)
        let other = directory.appendingPathComponent("other", isDirectory: true)
        try RootedFileStore(root: other).createRoot()
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        XCTAssertTrue(delegate.libraryWindow?.window === window)
        XCTAssertNil(old.state)
        old.perform(.account)
        XCTAssertNil(delegate.settingsWindow?.window)
        XCTAssertEqual(delegate.libraryWindow?.presentation.syncStatus?.state?.footer, .disabled)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
        XCTAssertEqual(transport.pulls, 0)
    }

    private func assertMatrix(_ source: MacStatusSource, model: SyncStatusModel, status: SyncStatusViewState,
                              file: StaticString = #filePath, line: UInt = #line) {
        let cases: [(SyncFooter, (inout SyncReport) -> Void)] = [
            (.disabled, { $0.enabled = false }), (.idle, { _ in }), (.syncing, { $0.phase = .collecting }),
            (.resyncing, { $0.phase = .resyncing }), (.offline, { $0.offline = true }),
            (.needsSignIn, { $0.needsSignIn = true; $0.enabled = false }),
            (.hasConflicts, { $0.counts.conflicts = 3 }), (.syncError, { $0.counts.fileErrors = 2 })]
        for (footer, edit) in cases {
            var report = enabledReport()
            report.lastSuccess = Date(timeIntervalSince1970: 42)
            edit(&report)
            source.send(report)
            XCTAssertEqual(status.state?.footer, footer, file: file, line: line)
            XCTAssertEqual(status.summary, SyncStatusStrings.summary(model.state), file: file, line: line)
            XCTAssertEqual(status.lastSuccess, SyncStatusStrings.lastSuccess(report.lastSuccess), file: file, line: line)
            XCTAssertEqual(status.primaryAction, model.state.action, file: file, line: line)
        }
        source.send(enabledReport())
        XCTAssertEqual(status.lastSuccess, "Last successful sync: never", file: file, line: line)
    }

    private func enabledReport() -> SyncReport { var report = SyncReport(); report.enabled = true; return report }

    private func start() {
        delegate = AppDelegate(libraryRoot: root, dataRoot: data, httpTransport: transport, secrets: MacStatusSecrets(),
            clipboard: clipboard, editorDialog: { _, _, _ in {} },
            replyToTermination: { [weak self] in self?.terminationReplies.append($0) },
            setActivationPolicy: { _ in }, activateApplication: { [weak self] in self?.activations += 1 },
            makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in false }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, makePanelController: { [weak self] main, scheduler, log in
                let panel = PanelController(mainThread: main, scheduler: scheduler, log: log)
                self?.panel = panel
                return panel
            }, makeFileWatcher: { _, _ in MacStatusWatcher() })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    private func signIn() throws {
        let account = try XCTUnwrap(delegate.accountModel)
        XCTAssertTrue(spin { !account.state.isBusy })
        var password = "runtime-password"
        account.login(server: "https://example.test/paw", username: "person", password: &password, deviceName: "Mac")
        XCTAssertTrue(password.isEmpty)
        XCTAssertTrue(spin { account.state.enabled && !account.state.isBusy })
    }

    private func openPicker() throws {
        delegate.pickerModel?.open()
        XCTAssertTrue(spin { self.panel.isActiveAndVisible })
        XCTAssertEqual(delegate.pickerModel?.state, .picker)
    }

    private func spin(_ predicate: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
}

private final class MacStatusSource: SyncStatusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var stored = SyncReport()
    private var observers: [UUID: (SyncReport) -> Void] = [:]
    private var syncRequests = 0
    var report: SyncReport { locked { stored } }
    var requests: Int { locked { syncRequests } }
    var observerCount: Int { locked { observers.count } }
    func observe(_ observer: @escaping (SyncReport) -> Void) -> UUID {
        locked { let id = UUID(); observers[id] = observer; return id }
    }
    func removeObserver(_ id: UUID) { locked { observers[id] = nil } }
    func syncNow() { locked { syncRequests += 1 } }
    func send(_ report: SyncReport) {
        let callbacks = locked { stored = report; return Array(observers.values) }
        for callback in callbacks { callback(report) }
    }
    private func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
}

private final class MacStatusQueuedMain: MainThread {
    private var work: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { self.work.append(work) }
    func flush() { while !work.isEmpty { work.removeFirst()() } }
}

private final class MacStatusWatcher: FileStoreWatcher {
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {}
    func stop() {}
}

private final class MacStatusClipboard: Clipboard {
    private(set) var text: String?
    func writeText(_ text: String) { self.text = text }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { completion(text) }
}

private final class MacStatusDeliveryPorts: PanelWindow, FocusTracker, PasteInjector, SessionProbe, Notifier {
    private(set) var events: [String] = []
    private(set) var chords: [PasteChord] = []
    let backend = PasteBackend.cgEvent
    func show() { events.append("show") }
    func hide() {}
    func hideForDelivery() { events.append("hide") }
    func captureTarget() -> DeliveryTarget? { .macOS(processID: 123, bundleID: "test.editor") }
    func restore(_ target: DeliveryTarget, completion: @escaping (FocusConfirmation) -> Void) {
        events.append("restore"); completion(.confirmed)
    }
    func paste(chord: PasteChord, completion: @escaping (PasteAttemptResult) -> Void) {
        events.append("paste"); chords.append(chord); completion(.sent)
    }
    func currentSession() -> DesktopSession { .macOS }
    func copied() { XCTFail("Expected paste dispatch") }
    func pressPaste(chord: PasteChord, reason: CopyReason) { XCTFail("Expected paste dispatch") }
}

private final class MacStatusSecrets: SecretStore {
    private let lock = NSLock()
    private var entries: [SecretAccount: SecretValue] = [:]
    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        lock.lock(); defer { lock.unlock() }
        return entries[account].map { StoredSecret(value: $0, tier: .keychain) }
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        lock.lock(); defer { lock.unlock() }
        entries[account] = value
        return .keychain
    }
    func delete(account: SecretAccount) throws { lock.lock(); defer { lock.unlock() }; entries[account] = nil }
}

private final class MacStatusHTTP: HTTPTransporting, @unchecked Sendable {
    enum Mode { case normal, offline, unauthorized, conflicts, held }
    static let user = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    static let device = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
    static let original = "01ARZ3NDEKTSV4RRFFQ69G5FAY"
    static let copyID = "01ARZ3NDEKTSV4RRFFQ69G5FAZ"
    static let copyPath = "Elsewhere/copy.md"
    private let lock = NSLock()
    private var storedMode: Mode = .normal
    private var pending: CheckedContinuation<HTTPResponse, Error>?
    private var pullCount = 0
    private var onMain = false
    var mode: Mode { get { locked { storedMode } } set { locked { storedMode = newValue } } }
    var pulls: Int { locked { pullCount } }
    var hasHeldPull: Bool { locked { pending != nil } }
    var sentOnMain: Bool { locked { onMain } }
    private let timestamp = "2026-10-15T00:00:00.000Z"
    private var user: SyncAPI.User { .init(id: Self.user, username: "person", displayName: nil,
        accountKind: .member, createdAt: timestamp, disabledAt: nil) }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        locked { onMain = onMain || Thread.isMainThread }
        if request.url.path.hasSuffix("/login") {
            return try response(SyncAPI.AuthResponse(deviceToken: String(repeating: "a", count: 42) + "A", user: user))
        }
        if request.url.path.hasSuffix("/me") {
            return try response(SyncAPI.MeResponse(user: user, groups: [], devices: [.init(id: Self.device,
                name: "Mac", createdAt: timestamp, lastSeenAt: nil, revokedAt: nil, isCurrent: true)]))
        }
        if request.url.path.hasSuffix("/sync/pull") {
            locked { pullCount += 1 }
            if mode == .held {
                return try await withCheckedThrowingContinuation { continuation in locked { pending = continuation } }
            }
            return try pullResponse()
        }
        if request.method == .get, request.url.lastPathComponent == Self.original {
            return try response(SyncAPI.Prompt(id: Self.original, rev: 1, scope: .user,
                path: "original.md", content: "---\nid: " + Self.original + "\n---\nOriginal\n"))
        }
        if request.method == .put {
            let put = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self, from: request.body ?? Data())
            return try response(SyncAPI.WriteResponse(rev: put.baseRev + 1, seq: 1))
        }
        return try response(SyncAPI.EmptyResponse())
    }

    func releasePull() {
        let pending = locked { let value = self.pending; self.pending = nil; return value }
        pending?.resume(throwing: HTTPTransportError.networkFailure)
    }

    private func pullResponse() throws -> HTTPResponse {
        switch mode {
        case .offline: throw HTTPTransportError.networkFailure
        case .unauthorized:
            return HTTPResponse(statusCode: 401, body: try JSONEncoder().encode(SyncAPI.ErrorResponse.failure(.unauthorized)))
        case .normal, .held, .conflicts:
            let items: [SyncAPI.FeedItem] = mode == .conflicts ? [
                .upsert(seq: 1, prompt: .init(id: Self.original, rev: 1, path: "original.md",
                    content: "---\nid: " + Self.original + "\n---\nOriginal\n")),
                .upsert(seq: 1, prompt: .init(id: Self.copyID, rev: 1, path: Self.copyPath,
                    content: "---\nid: " + Self.copyID + "\nx-monkeyspaw-conflict-of: " + Self.original + "\n---\nCopy\n"))] : []
            return try response(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: [
                .init(identity: .user(userID: Self.user), mode: .snapshot, head: items.isEmpty ? 0 : 1, cursor: "status-cursor",
                    hasMore: false, items: items)], removed: []))
        }
    }

    private func response<T: Encodable>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value))
    }
    private func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
}
