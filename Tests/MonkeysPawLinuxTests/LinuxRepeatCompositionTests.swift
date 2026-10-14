#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxRepeatCompositionTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var portal: FakePortal!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var clipboard: RepeatClipboard!
    private var focus: RepeatFocus!
    private var paths: LinuxPaths!

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        portal = try FakePortal(address: address)
        portal.behavior = .sessions
        portal.boundShortcuts = "[('toggle', {'trigger_description': <'Alt+P'>}), ('repeat', {'trigger_description': <'Alt+R'>})]"
        try portal.ownName()
        try portal.ownNotifications()
        tools = try PortalSessionTestSupport.tools()
        tools.environment["XDG_CURRENT_DESKTOP"] = "GNOME"
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        paths = LinuxPaths(environment: tools.environment)
        clipboard = RepeatClipboard()
        focus = RepeatFocus()
        compose()
    }

    override func tearDown() {
        environment?.shutdown()
        drain()
        environment = nil
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        drain()
        portal?.shutdown()
        portal = nil
        tools = nil
        clipboard = nil
        focus = nil
    }

    func testRepeatUsesExactFieldsFreshClipboardCurrentTargetAndSharedDefaultChord() throws {
        try put("""
        ---
        fields:
          empty: {optional: true, default: fallback}
          secret: {type: multiline, remember: false}
        ---
        {{empty}}|{{secret}}|{{clipboard}}
        """)
        clipboard.text = "first clipboard"
        try deliver(mode: .paste(.standard), values: ["empty": "", "secret": "{{literal}} \n"])
        let oldTarget = focus.target
        focus.target = .linux(session: .gnomeWayland, x11WindowClass: "Current")
        environment.settingsModel.setLinuxDefaultPasteChord(.terminal)
        clipboard.text = "current clipboard"
        let reads = clipboard.reads
        let captures = focus.captures
        let calls = portal.ordinaryCalls.count
        let result = try repeatNow()
        XCTAssertEqual(result, .delivered(.pasted(.remoteDesktopPortal), []))
        XCTAssertEqual(clipboard.writes.last, "|{{literal}} \n|current clipboard")
        XCTAssertEqual(clipboard.reads, reads + 1)
        XCTAssertEqual(focus.captures, captures + 1)
        XCTAssertEqual(focus.restored.last, focus.target)
        XCTAssertNotEqual(focus.restored.last, oldTarget)
        XCTAssertEqual(portal.ordinaryCalls.dropFirst(calls).map { portal.keys($0).0 },
            [0xffe3, 0xffe1, 0x76, 0x76, 0xffe1, 0xffe3])
        let record = try String(data: dataFiles.read(at: "last-delivery.json"), encoding: .utf8)
        XCTAssertFalse(try XCTUnwrap(record).contains("literal"))
        XCTAssertFalse(try XCTUnwrap(record).contains("current clipboard"))
        let identity = try XCTUnwrap(environment.pickerModel.results.first?.identity)
        XCTAssertEqual(try UsageStore(files: dataFiles, clock: SystemClock()).useEvents(for: identity).count, 2)
        XCTAssertFalse(environment.panel.isVisible)
    }

    func testRepeatKeepsCapturedTargetWhileClipboardReadIsPending() throws {
        try put("{{clipboard}}")
        try deliver(mode: .paste(.standard))
        let target = DeliveryTarget.linux(session: .gnomeWayland, x11WindowClass: "Captured")
        focus.target = target
        clipboard.hold = true
        environment.activateRepeat()
        XCTAssertTrue(GTKTestSupport.spin { self.clipboard.pending != nil })
        focus.target = .linux(session: .gnomeWayland, x11WindowClass: "Later")
        clipboard.release("new clipboard")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.repeatModel?.result != nil })
        XCTAssertEqual(environment.repeatModel?.result, .delivered(.pasted(.remoteDesktopPortal), []))
        XCTAssertEqual(focus.restored.last, target)
        XCTAssertEqual(clipboard.writes.last, "new clipboard")
    }

    func testRepeatUsesSharedRestorePreferenceAndReadOnlySettingsDisableIt() throws {
        try put("body")
        try deliver(mode: .paste(.standard))
        XCTAssertEqual(clipboard.snapshots, 0)
        environment.settingsModel.setClipboardRestore(.previousText)
        XCTAssertEqual(try repeatNow(), .delivered(.pasted(.remoteDesktopPortal), []))
        XCTAssertEqual(clipboard.snapshots, 1)
        environment.settingsModel.setClipboardRestore(.off)
        XCTAssertEqual(try repeatNow(), .delivered(.pasted(.remoteDesktopPortal), []))
        XCTAssertEqual(clipboard.snapshots, 1)
        let config = try RootedFileStore(root: paths.configDirectory)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: config.read(at: "settings.json")) as? [String: Any])
        object["delivery"] = ["clipboardRestore": "previousText"]
        object["carbonShortcuts"] = [] as [String]
        try config.write(JSONSerialization.data(withJSONObject: object), at: "settings.json")
        compose()
        XCTAssertTrue(environment.settingsModel.isReadOnly)
        XCTAssertEqual(environment.settingsModel.deliveryPreferences.clipboardRestore, .previousText)
        XCTAssertEqual(try repeatNow(), .delivered(.pasted(.remoteDesktopPortal), []))
        XCTAssertEqual(clipboard.snapshots, 1)
    }

    func testChangedSourceRequiresVisibleReviewWithoutWritingClipboard() throws {
        try put("before")
        try deliver()
        try put("after")
        let writes = clipboard.writes.count
        guard case .reviewRequired(_, .sourceChanged) = try repeatNow() else { return XCTFail("Expected source review") }
        XCTAssertEqual(clipboard.writes.count, writes)
        let notice = try repeatNotice()
        XCTAssertTrue(try message(in: notice).contains("changed"))
        XCTAssertNotEqual(gtk_widget_get_visible(try settingsWidget("repeat-open-prompt", in: notice)), 0)
    }

    func testRepeatSaveFailureKeepsDeliveryAndShowsWarning() throws {
        try put("body")
        try deliver()
        let record = paths.dataDirectory.appendingPathComponent("last-delivery.json")
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        let writes = clipboard.writes.count
        XCTAssertEqual(try repeatNow(), .delivered(.copiedOnly(.requested), [.lastDeliveryNotSaved]))
        XCTAssertEqual(clipboard.writes.count, writes + 1)
        XCTAssertEqual(try message(in: repeatNotice()), LinuxStrings.persistenceWarning(.lastDeliveryNotSaved))
    }

    func testNoRecordAndSessionOnlyRestartShowRefusalAndOfferReopening() throws {
        XCTAssertEqual(try repeatNow(), .nothingToRepeat)
        var notice = try repeatNotice()
        XCTAssertEqual(try message(in: notice), "Nothing to repeat")
        gtk_window_close(mp_window(notice))
        try put("---\nfields:\n  value: {remember: false, default: unsafe-default}\n---\n{{value}}")
        try deliver(values: ["value": "session-only"])
        compose()
        let writes = clipboard.writes.count
        let result = try repeatNow()
        guard case .reviewRequired(_, .sessionOnlyValues) = result else { return XCTFail("Expected restart refusal") }
        XCTAssertEqual(clipboard.writes.count, writes)
        notice = try repeatNotice()
        XCTAssertTrue(try message(in: notice).contains("only for that session"))
        let reopen = try settingsWidget("repeat-open-prompt", in: notice)
        XCTAssertNotEqual(gtk_widget_get_visible(reopen), 0)
        XCTAssertNotEqual(gtk_widget_activate(reopen), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.prompt != nil })
        XCTAssertFalse(environment.panel.isVisible)
    }

    func testRememberedRestartRetainsExactEmptyAndCopyIntent() throws {
        try put("---\nfields:\n  value: {optional: true, default: fallback}\n---\n[{{value}}]")
        try deliver(values: ["value": ""])
        let identity = try XCTUnwrap(environment.pickerModel.results.first?.identity)
        try ValuesStore(files: dataFiles).record(identity: identity, values: ["value": "different"])
        compose()
        XCTAssertEqual(try repeatNow(), .delivered(.copiedOnly(.requested), []))
        XCTAssertEqual(clipboard.writes.last, "[]")
        XCTAssertFalse(portal.ordinaryCalls.contains { $0.method == "NotifyKeyboardKeysym" })
    }

    func testOwnSettingsAndLibraryTargetsRefuseRepeatWithoutClipboardWrites() throws {
        try put("body")
        try deliver()
        for show in [{ self.environment.showSettings() }, { self.environment.showLibrary() }] {
            show()
            XCTAssertTrue(GTKTestSupport.spin {
                guard let window = gtk_application_get_active_window(self.application) else { return false }
                return gtk_window_is_active(window) != 0
            })
            let writes = clipboard.writes.count
            XCTAssertEqual(try repeatNow(), .unavailable(.ownWindow))
            XCTAssertEqual(clipboard.writes.count, writes)
            let notice = try repeatNotice()
            XCTAssertTrue(try message(in: notice).contains("Focus the app"))
            hideWindows()
        }
    }

    func testFocusedPickerAndFillFormRefuseRepeatWithoutChangingValues() throws {
        try put("{{field}}")
        try deliver(values: ["field": "delivered"])
        for filling in [false, true] {
            environment.pickerModel.open()
            XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
            if filling {
                environment.pickerModel.use(mode: .copyOnly)
                XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.fillModel?.builtinsResolved == true })
                environment.pickerModel.fillModel?.setValue("draft", name: "field")
            }
            gtk_window_present(mp_window(environment.panel.clipboardOwner))
            XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
            let writes = clipboard.writes.count
            let captures = focus.captures
            XCTAssertEqual(try repeatNow(), .unavailable(.ownWindow))
            XCTAssertEqual(clipboard.writes.count, writes)
            XCTAssertEqual(focus.captures, captures)
            if filling { XCTAssertEqual(environment.pickerModel.fillModel?.values["field"], "draft") }
            hideWindows()
        }
    }

    func testBusyRepeatDropsOverlapAndKeepsHiddenFillDraft() throws {
        try put("{{field}}|{{clipboard}}")
        clipboard.text = "old"
        try deliver(values: ["field": "delivered"])
        environment.pickerModel.open()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        environment.pickerModel.use(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.fillModel?.state == .editing })
        let form = try XCTUnwrap(environment.pickerModel.fillModel)
        XCTAssertTrue(GTKTestSupport.spin { form.builtinsResolved })
        form.setValue("draft", name: "field")
        environment.pickerModel.dismiss()
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })
        clipboard.hold = true
        let captures = focus.captures
        let writes = clipboard.writes.count
        environment.activateRepeat()
        XCTAssertTrue(GTKTestSupport.spin { self.clipboard.pending != nil })
        environment.activateRepeat()
        XCTAssertEqual(focus.captures, captures + 1)
        clipboard.release("fresh")
        let model = try XCTUnwrap(environment.repeatModel)
        XCTAssertTrue(GTKTestSupport.spin { model.result != nil })
        XCTAssertEqual(clipboard.writes.count, writes + 1)
        XCTAssertEqual(clipboard.writes.last, "delivered|fresh")
        environment.pickerModel.open()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        environment.pickerModel.use(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.fillModel?.state == .editing })
        XCTAssertEqual(environment.pickerModel.fillModel?.values["field"], "draft")
    }

    func testLibrarySwitchRetiresPendingRepeatBeforeLateClipboardOrRecordWrites() throws {
        try put("{{clipboard}}")
        try deliver()
        clipboard.hold = true
        let oldModel = try XCTUnwrap(environment.repeatModel)
        environment.activateRepeat()
        XCTAssertTrue(GTKTestSupport.spin { self.clipboard.pending != nil })
        let writes = clipboard.writes.count
        let second = tools.directory.appendingPathComponent("Second")
        try RootedFileStore(root: second).write(Data("second".utf8), at: "prompt.md")
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        XCTAssertEqual(oldModel.state, .inactive)
        let tombstone = try dataFiles.read(at: "last-delivery.json")
        clipboard.release("late")
        drain()
        XCTAssertEqual(clipboard.writes.count, writes)
        XCTAssertEqual(try dataFiles.read(at: "last-delivery.json"), tombstone)
        XCTAssertEqual(try repeatNow(), .nothingToRepeat)
    }

    func testRecoveryFromInvalidInitialRootCannotResurrectOlderRepeat() throws {
        try put("body")
        try deliver()
        environment.settingsModel.setLibraryFolder(tools.directory.appendingPathComponent("Unavailable\\Root").path)
        compose()
        XCTAssertFalse(environment.pickerModel.libraryAvailable)
        XCTAssertNil(environment.repeatModel)
        let original = paths.documentsDirectory.appendingPathComponent("MonkeysPaw")
        XCTAssertEqual(environment.switchLibrary(to: original), .switched)
        XCTAssertEqual(try repeatNow(), .nothingToRepeat)
    }

    func testFailedRepeatRetirementKeepsGraphAndVisibleErrorUntilDurableRetry() throws {
        try put("body")
        try deliver()
        let old = environment.pickerModel
        let record = paths.dataDirectory.appendingPathComponent("last-delivery.json")
        let saved = paths.dataDirectory.appendingPathComponent("saved-record")
        try FileManager.default.moveItem(at: record, to: saved)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        let second = tools.directory.appendingPathComponent("Second")
        try RootedFileStore(root: second).write(Data("second".utf8), at: "prompt.md")
        XCTAssertEqual(environment.switchLibrary(to: second), .repeatInvalidationFailed)
        XCTAssertTrue(environment.pickerModel === old)
        XCTAssertEqual(try repeatNow(), .unavailable(.invalidationFailed))
        XCTAssertTrue(try message(in: repeatNotice()).contains("could not be cleared"))
        try FileManager.default.removeItem(at: record)
        try FileManager.default.moveItem(at: saved, to: record)
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        XCTAssertEqual(try repeatNow(), .nothingToRepeat)
    }

    func testPickerDeliveryBusyGuardAndForgetAllUseCurrentRepeatService() throws {
        try put("{{clipboard}}")
        try deliver()
        clipboard.hold = true
        environment.pickerModel.open()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        environment.pickerModel.use(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin { self.clipboard.pending != nil })
        let captures = focus.captures
        environment.activateRepeat()
        drain()
        XCTAssertEqual(environment.repeatModel?.state, .idle)
        XCTAssertNil(environment.repeatModel?.result)
        XCTAssertEqual(focus.captures, captures)
        clipboard.release("new")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.copiedOnly(.requested)) })
        environment.rememberedValuesSettingsModel.requestForgetAll()
        environment.rememberedValuesSettingsModel.confirmForgetAll()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.rememberedValuesSettingsModel.state.lastOutcome == .forgotten })
        XCTAssertEqual(try repeatNow(), .nothingToRepeat)
    }

    private var dataFiles: RootedFileStore { get throws { try RootedFileStore(root: paths.dataDirectory) } }

    private func compose() {
        environment?.shutdown()
        drain()
        if let application {
            while let windows = gtk_application_get_windows(application), let raw = windows.pointee.data {
                gtk_window_destroy(raw.assumingMemoryBound(to: GtkWindow.self))
            }
        }
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            focusTracker: focus, clipboard: clipboard)
        MonkeysPawLinuxApp.installRepeatAction(application: application, environment: environment)
    }

    private func put(_ source: String) throws {
        let root = paths.documentsDirectory.appendingPathComponent("MonkeysPaw")
        try RootedFileStore(root: root).write(Data(source.utf8), at: "prompt.md")
    }

    private func deliver(mode: DeliveryMode = .copyOnly, values: [String: String] = [:]) throws {
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible
            && self.environment.pickerModel.results.contains { $0.relativePath == "prompt.md" } })
        environment.pickerModel.use(mode: mode)
        if !values.isEmpty {
            XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.fillModel != nil })
            let form = try XCTUnwrap(environment.pickerModel.fillModel)
            for (name, value) in values { form.setValue(value, name: name) }
            XCTAssertTrue(GTKTestSupport.spin { form.builtinsResolved })
            XCTAssertTrue(form.deliverEnabled)
            form.deliver(mode: mode)
        }
        XCTAssertTrue(GTKTestSupport.spin {
            if let form = self.environment.pickerModel.fillModel {
                if case .done = form.state { return true }
            }
            if case .done = self.environment.pickerModel.state { return true }
            return false
        })
        XCTAssertTrue(GTKTestSupport.spin { self.environment.repeatModel?.availability == .ready })
    }

    private func repeatNow() throws -> RepeatResult {
        let model = try XCTUnwrap(environment.repeatModel)
        g_action_group_activate_action(mp_action_group(application), ActionName.repeat.rawValue, nil)
        XCTAssertTrue(GTKTestSupport.spin { model.state == .idle && model.result != nil })
        return try XCTUnwrap(model.result)
    }

    private func repeatNotice() throws -> GTK.Widget {
        var windows = gtk_application_get_windows(application)
        while let node = windows {
            if let raw = node.pointee.data {
                let window = raw.assumingMemoryBound(to: GtkWindow.self)
                if gtk_widget_get_visible(mp_window_widget(window)) != 0,
                   gtk_window_get_title(window).map(String.init(cString:)) == LinuxStrings.repeatLast {
                    return mp_window_widget(window)
                }
            }
            windows = node.pointee.next
        }
        XCTFail("Repeat notice was not shown")
        throw NSError(domain: "LinuxRepeatCompositionTests", code: 1)
    }

    private func message(in window: GTK.Widget) throws -> String {
        String(cString: gtk_label_get_text(mp_label(try settingsWidget("repeat-message", in: window))))
    }

    private func hideWindows() {
        var windows = gtk_application_get_windows(application)
        while let node = windows {
            if let raw = node.pointee.data { gtk_widget_set_visible(mp_window_widget(raw.assumingMemoryBound(to: GtkWindow.self)), 0) }
            windows = node.pointee.next
        }
        drain()
    }

    private func drain() {
        var done = false
        GTK.onMainLoop { done = true }
        XCTAssertTrue(GTKTestSupport.spin { done })
    }
}

private final class RepeatClipboard: ClipboardRestoring {
    private final class Read: ClipboardSnapshotRead { func cancel() {} }
    var text: String? = ""
    var writes: [String] = []
    var reads = 0
    var hold = false
    var pending: (@Sendable (String?) -> Void)?
    var snapshots = 0
    func writeText(_ text: String) { writes.append(text); self.text = text }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) {
        reads += 1
        if hold { XCTAssertNil(pending); pending = completion }
        else { completion(text) }
    }
    func release(_ text: String?) {
        let completion = pending
        pending = nil
        hold = false
        completion?(text)
    }
    func snapshotText(budget: Duration, byteLimit: Int,
                      completion: @escaping (ClipboardTextSnapshot?) -> Void) -> ClipboardSnapshotRead {
        snapshots += 1
        completion(nil)
        return Read()
    }
    func writeTextOwning(_ text: String, after revision: ClipboardRevision) -> ClipboardWriteOwnership? {
        XCTFail("A nil snapshot cannot establish ownership")
        return nil
    }
    func restore(_ snapshot: ClipboardTextSnapshot, ifOwnedBy ownership: ClipboardWriteOwnership) {
        XCTFail("A nil snapshot cannot be restored")
    }
}

private final class RepeatFocus: FocusTracker {
    var target = DeliveryTarget.linux(session: .gnomeWayland, x11WindowClass: "Original")
    var captures = 0
    var restored: [DeliveryTarget] = []
    func captureTarget() -> DeliveryTarget? { captures += 1; return target }
    func restore(_ target: DeliveryTarget, completion: @escaping (FocusConfirmation) -> Void) {
        restored.append(target)
        completion(.confirmed)
    }
}

#endif
