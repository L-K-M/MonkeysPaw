import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacRepeatCompositionTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var delegate: AppDelegate!
    private var panel: PanelController!
    private var clipboard: MacRepeatClipboard!
    private var injector: MacRepeatInjector!
    private var work: MacRepeatWork!
    private var scheduler: MacRepeatScheduler!
    private var originalWindows: Set<ObjectIdentifier> = []
    private var target: DeliveryTarget?
    private var restored: [DeliveryTarget] = []
    private var captures = 0
    private var ownPID: Int32 { NSRunningApplication.current.processIdentifier }

    override func setUpWithError() throws {
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library")
        data = directory.appendingPathComponent("data")
        clipboard = MacRepeatClipboard()
        injector = MacRepeatInjector()
        work = MacRepeatWork()
        scheduler = MacRepeatScheduler()
        target = .macOS(processID: ownPID + 1, bundleID: "test.original")
        compose()
    }

    override func tearDown() {
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate = nil
        hideWindows()
        settle()
        panel = nil
        if clipboard.pending != nil { clipboard.release("discarded") }
        try? FileManager.default.removeItem(at: directory)
    }

    private func compose() {
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate = AppDelegate(libraryRoot: root, dataRoot: data, launchURI: { _ in XCTFail("Unexpected launch") },
            backgroundWork: work, httpTransport: MacRepeatNoHTTP(), clipboard: clipboard,
            pasteInjectors: [injector], setActivationPolicy: { _ in }, activateApplication: {},
            makeFocusTracker: { [weak self] main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { [weak self] in
                    self?.captures += 1
                    return self?.target
                }, activate: { [weak self] target in self?.restored.append(target); return true }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, scheduler: scheduler, makePanelController: { [weak self] main, scheduler, log in
                let panel = PanelController(mainThread: main, scheduler: scheduler, log: log)
                self?.panel = panel
                return panel
            }, makeFileWatcher: { _, _ in MacRepeatWatcher() })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    private func settle() {
        for _ in 0..<8 {
            work?.drain()
            scheduler?.drain()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
    }

    private func hideWindows() {
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
    }

    private func put(_ source: String) throws {
        try RootedFileStore(root: root).write(Data(source.utf8), at: "prompt.md")
        // Restart installs/rebuilds the real graph without relying on FSEvents.
        compose()
    }

    private func deliver(_ mode: DeliveryMode = .copyOnly, values: [String: String] = [:]) throws {
        let picker = try XCTUnwrap(delegate.pickerModel)
        picker.open()
        picker.use(mode: mode)
        if let form = picker.fillModel {
            for (name, value) in values { form.setValue(value, name: name) }
            form.deliver(mode: mode)
        }
        settle()
        guard case .done = picker.state else { return XCTFail("Expected a completed delivery") }
        XCTAssertEqual(delegate.repeatModel?.availability, .ready)
        hideWindows()
    }

    private func repeatNow() throws -> RepeatResult {
        delegate.repeatLast()
        settle()
        return try XCTUnwrap(delegate.repeatModel?.result)
    }

    func testHostedLaunchHasNoWindowsNetworkOrNativeHotkeys() throws {
        XCTAssertTrue(AppDelegate.isRunningTests)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), originalWindows)
        XCTAssertNotNil(delegate.repeatModel)
        XCTAssertNil(delegate.repeatWindow)
        delegate.startShortcuts() // The default production backend stays gated.
        delegate.shortcutsSettingsModel?.refresh()
        XCTAssertEqual(delegate.shortcutsSettingsModel?.togglePicker.registrationStatus, .unbound)
        XCTAssertEqual(delegate.shortcutsSettingsModel?.repeatLast.registrationStatus, .unbound)
    }

    func testExactSessionValuesFreshClipboardAndCurrentTargetUseMacChord() throws {
        try put("---\nfields:\n  empty: {optional: true, default: fallback}\n  secret: {type: multiline, remember: false}\n---\n{{empty}}|{{secret}}|{{clipboard}}")
        try deliver(.paste(.standard), values: ["empty": "", "secret": "{{literal}} \n"])
        let originalTarget = target
        target = .macOS(processID: ownPID + 2, bundleID: "test.current")
        clipboard.text = "fresh clipboard"
        let reads = clipboard.reads
        XCTAssertEqual(try repeatNow(), .delivered(.pasted(.cgEvent), []))
        XCTAssertEqual(clipboard.writes.last, "|{{literal}} \n|fresh clipboard")
        XCTAssertEqual(clipboard.reads, reads + 1)
        XCTAssertEqual(restored.last, target)
        XCTAssertNotEqual(restored.last, originalTarget)
        XCTAssertEqual(injector.chords, [.standard, .standard])
        let record = try RootedFileStore(root: data).read(at: "last-delivery.json")
        let text = try XCTUnwrap(String(data: record, encoding: .utf8))
        XCTAssertFalse(text.contains("literal"))
        XCTAssertFalse(text.contains("fresh clipboard"))
        let identity = try XCTUnwrap(delegate.pickerModel?.results.first?.identity)
        XCTAssertEqual(try UsageStore(files: RootedFileStore(root: data), clock: SystemClock()).useEvents(for: identity).count, 2)
    }

    func testTargetIsCapturedBeforeHeldClipboardReadAndOverlapIsDropped() throws {
        try put("{{clipboard}}")
        try deliver(.paste(.standard))
        let captured = DeliveryTarget.macOS(processID: ownPID + 3, bundleID: "test.captured")
        target = captured
        clipboard.hold = true
        delegate.repeatLast()
        XCTAssertNotNil(clipboard.pending)
        let captures = self.captures
        let writes = clipboard.writes.count
        delegate.repeatLast()
        XCTAssertEqual(self.captures, captures)
        target = .macOS(processID: ownPID + 4, bundleID: "test.later")
        clipboard.release("current text")
        settle()
        XCTAssertEqual(delegate.repeatModel?.result, .delivered(.pasted(.cgEvent), []))
        XCTAssertEqual(restored.last, captured)
        XCTAssertEqual(clipboard.writes.count, writes + 1)
    }

    func testRestartKeepsExactEmptyCopyIntentAndRefusesSessionOnlyValues() throws {
        try put("---\nfields:\n  value: {optional: true, default: fallback}\n---\n[{{value}}]")
        try deliver(values: ["value": ""])
        compose()
        XCTAssertEqual(try repeatNow(), .delivered(.copiedOnly(.requested), []))
        XCTAssertEqual(clipboard.writes.last, "[]")
        XCTAssertTrue(injector.chords.isEmpty)

        try put("---\nfields:\n  value: {remember: false, default: unsafe}\n---\n{{value}}")
        try deliver(values: ["value": "session value"])
        compose()
        let writes = clipboard.writes.count
        guard case .reviewRequired(_, .sessionOnlyValues) = try repeatNow() else { return XCTFail("Expected review") }
        XCTAssertEqual(clipboard.writes.count, writes)
        let notice = try XCTUnwrap(delegate.repeatWindow)
        XCTAssertTrue(notice.presentation.message.contains("only for that session"))
        XCTAssertNotNil(notice.presentation.reference)
        notice.presentation.reopen()
        settle()
        XCTAssertNotNil(delegate.editorModel?.state.prompt)
        XCTAssertFalse(panel.isVisible)
    }

    func testNothingToRepeatAndSourceChangeAreVisibleAndReuseNotice() throws {
        XCTAssertEqual(try repeatNow(), .nothingToRepeat)
        let notice = try XCTUnwrap(delegate.repeatWindow)
        XCTAssertEqual(notice.presentation.message, "Nothing to repeat")
        let window = try XCTUnwrap(notice.window)
        window.close()
        try put("before")
        try deliver()
        try RootedFileStore(root: root).write(Data("after".utf8), at: "prompt.md")
        let writes = clipboard.writes.count
        guard case .reviewRequired(_, .sourceChanged) = try repeatNow() else { return XCTFail("Expected review") }
        XCTAssertEqual(clipboard.writes.count, writes)
        let currentNotice = try XCTUnwrap(delegate.repeatWindow)
        let currentWindow = try XCTUnwrap(currentNotice.window)
        currentWindow.close()
        _ = try repeatNow()
        XCTAssertTrue(currentNotice.window === currentWindow)
        XCTAssertTrue(currentNotice.presentation.message.contains("changed"))
    }

    func testLibraryRetirementRejectsLateClipboardAndCannotResurrectRecord() throws {
        try put("{{clipboard}}")
        try deliver()
        clipboard.hold = true
        let old = try XCTUnwrap(delegate.repeatModel)
        delegate.repeatLast()
        XCTAssertNotNil(clipboard.pending)
        let writes = clipboard.writes.count
        let other = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        XCTAssertEqual(old.state, .inactive)
        let tombstone = try RootedFileStore(root: data).read(at: "last-delivery.json")
        clipboard.release("late")
        settle()
        XCTAssertEqual(clipboard.writes.count, writes)
        XCTAssertEqual(try RootedFileStore(root: data).read(at: "last-delivery.json"), tombstone)
        XCTAssertEqual(delegate.switchLibrary(to: root), .switched)
        XCTAssertEqual(try repeatNow(), .nothingToRepeat)
    }

    func testFailedRetirementPreservesGraphAndRequiresDurableRetry() throws {
        try put("body")
        try deliver()
        let old = delegate.pickerModel
        let record = data.appendingPathComponent("last-delivery.json")
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        let other = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(delegate.switchLibrary(to: other), .repeatInvalidationFailed)
        XCTAssertTrue(delegate.pickerModel === old)
        XCTAssertEqual(delegate.libraryDirectory, root)
        XCTAssertTrue(try XCTUnwrap(delegate.repeatWindow).presentation.message.contains("could not be cleared"))
        hideWindows()
        XCTAssertEqual(try repeatNow(), .unavailable(.invalidationFailed))
        try FileManager.default.removeItem(at: record)
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        hideWindows()
        XCTAssertEqual(try repeatNow(), .nothingToRepeat)
    }

    func testSavedRestorePreferenceUsesSharedClipboardAndLiveDisable() throws {
        try put("body")
        try deliver(.paste(.standard))
        XCTAssertEqual(clipboard.snapshots, 0)
        delegate.settingsModel?.setClipboardRestore(.previousText)
        _ = try repeatNow()
        XCTAssertEqual(clipboard.snapshots, 1)
        delegate.settingsModel?.setClipboardRestore(.off)
        _ = try repeatNow()
        XCTAssertEqual(clipboard.snapshots, 1)
        let files = try RootedFileStore(root: data)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: files.read(at: "settings.json")) as? [String: Any])
        object["delivery"] = ["clipboardRestore": "previousText"]
        object["carbonShortcuts"] = [] as [String]
        try files.write(JSONSerialization.data(withJSONObject: object), at: "settings.json")
        compose()
        XCTAssertTrue(try XCTUnwrap(delegate.settingsModel).isReadOnly)
        _ = try repeatNow()
        XCTAssertEqual(clipboard.snapshots, 1, "Read-only settings must force restore off")
    }

    func testOwnSettingsLibraryAndPickerWindowsRefuseBeforeCapture() throws {
        try put("{{field}}")
        try deliver(values: ["field": "delivered"])
        let actions: [() -> Void] = [
            { self.delegate.showSettings() },
            { self.delegate.showLibrary() },
            { self.delegate.pickerModel?.open() },
            {
                self.delegate.pickerModel?.open()
                self.delegate.pickerModel?.use(mode: .copyOnly)
                self.delegate.pickerModel?.fillModel?.setValue("draft", name: "field")
            },
        ]
        for action in actions {
            action()
            let deadline = Date().addingTimeInterval(2)
            while NSApp.keyWindow == nil, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            XCTAssertNotNil(NSApp.keyWindow)
            let captures = self.captures
            let writes = clipboard.writes.count
            XCTAssertEqual(try repeatNow(), .unavailable(.ownWindow))
            XCTAssertEqual(self.captures, captures)
            XCTAssertEqual(clipboard.writes.count, writes)
            if let form = delegate.pickerModel?.fillModel { XCTAssertEqual(form.values["field"], "draft") }
            delegate.pickerModel?.dismiss()
            hideWindows()
            settle()
        }
    }

    func testPendingPickerBuiltinReadBlocksRepeatAndHiddenDraftSurvives() throws {
        try put("{{field}}|{{clipboard}}")
        try deliver(values: ["field": "delivered"])
        let picker = try XCTUnwrap(delegate.pickerModel)
        picker.open()
        clipboard.hold = true
        picker.use(mode: .copyOnly)
        let writes = clipboard.writes.count
        delegate.repeatLast()
        XCTAssertEqual(delegate.repeatModel?.state, .idle)
        XCTAssertNil(delegate.repeatModel?.result)
        clipboard.release("preview")
        let form = try XCTUnwrap(picker.fillModel)
        form.setValue("draft", name: "field")
        picker.dismiss()
        settle()
        hideWindows()
        clipboard.text = "fresh"
        XCTAssertEqual(try repeatNow(), .delivered(.copiedOnly(.requested), []))
        XCTAssertEqual(clipboard.writes.count, writes + 1)
        XCTAssertEqual(clipboard.writes.last, "delivered|fresh")
        picker.open()
        picker.use(mode: .copyOnly)
        XCTAssertEqual(picker.fillModel?.values["field"], "draft")
    }

    func testInvalidInitialBindingRecoveryClearsAnOlderRecord() throws {
        try put("body")
        try deliver()
        delegate.settingsModel?.setLibraryFolder(directory.appendingPathComponent("Unavailable\\Root").path)
        compose()
        XCTAssertNil(delegate.repeatModel)
        XCTAssertEqual(delegate.switchLibrary(to: root), .switched)
        XCTAssertEqual(try repeatNow(), .nothingToRepeat)
    }

    func testRepeatSaveFailureReportsWarningWithoutUndoingDelivery() throws {
        try put("body")
        try deliver()
        let record = data.appendingPathComponent("last-delivery.json")
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        let writes = clipboard.writes.count
        XCTAssertEqual(try repeatNow(), .delivered(.copiedOnly(.requested), [.lastDeliveryNotSaved]))
        XCTAssertEqual(clipboard.writes.count, writes + 1)
        XCTAssertEqual(delegate.repeatWindow?.presentation.message, Strings.persistenceWarning(.lastDeliveryNotSaved))
    }
}
