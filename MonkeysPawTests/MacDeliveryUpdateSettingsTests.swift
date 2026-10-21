import AppKit
import ApplicationServices
import SwiftUI
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacDeliveryUpdateSettingsTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var delegate: AppDelegate!
    private var transport: MacSettingsHTTP!
    private var timers: MacSettingsTimers!
    private var updateTimers: MacSettingsUpdateTimers!
    private var updateScheduler: MacUpdateScheduler!
    private var injector: MacRepeatInjector!
    private var selfTestTarget: MacSettingsSelfTestTarget!
    private var work: MacRepeatWork!
    private var pasteboard: NSPasteboard!
    private var opened: [URL] = []
    private var opensSucceed = true
    private var setupOpens = 0
    private var originalWindows: Set<ObjectIdentifier> = []

    override func setUpWithError() throws {
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library")
        data = directory.appendingPathComponent("data")
        transport = MacSettingsHTTP()
        timers = MacSettingsTimers()
        updateTimers = MacSettingsUpdateTimers()
        injector = MacRepeatInjector()
        selfTestTarget = MacSettingsSelfTestTarget()
        work = MacRepeatWork()
        pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    }

    override func tearDown() {
        transport.release()
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate = nil
        updateScheduler?.stop()
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        timers.drain()
        pasteboard.releaseGlobally()
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func start(version: String? = "1.0.0-beta.2") {
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let target = DeliveryTarget.macOS(processID: NSRunningApplication.current.processIdentifier + 1,
            bundleID: "test.external")
        delegate = AppDelegate(libraryRoot: root, dataRoot: data,
            recordLegacySetup: { [weak self] in self?.setupOpens += 1 }, launchURI: { _ in XCTFail("Unexpected URI") },
            backgroundWork: work, httpTransport: transport, clipboard: PasteboardClipboard(pasteboard: pasteboard),
            makeHotkeyBackend: { MacRepeatHotkeys() }, pasteInjectors: [injector],
            currentReleaseVersion: version,
            releasePage: WorkspaceReleasePageOpener(open: { [weak self] url in
                XCTAssertTrue(Thread.isMainThread)
                self?.opened.append(url)
                return self?.opensSucceed ?? false
            }), makeUpdateScheduler: { [unowned self] main in
                let scheduler = MacUpdateScheduler(mainThread: main, schedule: self.updateTimers.schedule)
                self.updateScheduler = scheduler
                return scheduler
            }, makeSelfTestTarget: { [unowned self] in self.selfTestTarget },
            setActivationPolicy: { _ in }, activateApplication: {},
            makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { target }, activate: { _ in true }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, scheduler: timers, makeFileWatcher: { _, _ in MacRepeatWatcher() })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    private func show() throws -> SettingsViewState {
        delegate.showSettings()
        let page = try XCTUnwrap(delegate.settingsWindow?.presentation)
        waitFor("initial update snapshot") { page.updates.state.update != nil }
        return page
    }

    private func waitFor(_ condition: @autoclosure () -> String,
                         file: StaticString = #filePath, line: UInt = #line, until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline {
            work.drain()
            timers.drain()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
        }
        XCTAssertTrue(predicate(), "Settings work did not settle: \(condition())", file: file, line: line)
    }

    private func settle() {
        // Negative assertions must observe deferred work even when state is already idle.
        let deadline = Date().addingTimeInterval(0.1)
        repeat {
            work.drain()
            timers.drain()
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.002)))
        } while Date() < deadline
        work.drain()
        timers.drain()
    }

    private func assertRequestCount(_ count: Int = 0, _ message: String = "",
                                    file: StaticString = #filePath, line: UInt = #line) {
        settle()
        XCTAssertEqual(transport.count, count, message, file: file, line: line)
    }

    private func check(_ page: UpdateSettingsViewState, expecting result: UpdateCheckResult,
                       file: StaticString = #filePath, line: UInt = #line) {
        let count = transport.count
        page.checkNow()
        waitFor("manual check \(count + 1) finished with \(result); requests=\(transport.count), snapshot=\(String(describing: page.state.update))",
                file: file, line: line) {
            self.transport.count == count + 1 && page.state.update?.isChecking == false
                && page.state.update?.result == result
        }
    }

    func testHostedVersionedLaunchRefreshAndReopenSendNoHTTPOrUpdateTimers() throws {
        start()
        XCTAssertTrue(AppDelegate.isRunningTests)
        XCTAssertNil(delegate.settingsWindow?.window)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), originalWindows)
        let page = try show()
        XCTAssertEqual(page.updates.state.update?.currentVersion?.description, "1.0.0-beta.2")
        XCTAssertEqual(page.updates.state.update?.result, .notChecked)
        XCTAssertTrue(page.updates.canCheck)
        for _ in 0..<3 {
            delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            try XCTUnwrap(delegate.settingsWindow?.window).close()
            delegate.showSettings()
        }
        page.updates.model.refresh()
        assertRequestCount()
        XCTAssertEqual(updateTimers.jobs.count, 0)
        XCTAssertEqual(updateScheduler.pendingCount, 0)
        XCTAssertEqual(selfTestTarget.presentations, 0)
        XCTAssertTrue(opened.isEmpty)
    }

    func testPreferencesPersistAcrossRestartAndPreserveForeignAccountAndURIKeys() throws {
        let files = try RootedFileStore(root: data)
        try files.createRoot()
        let initial: [String: Any] = ["version": 1,
            "firstRun": ["setupPresented": false, "libraryFolderCompleted": false,
                         "seedsOffered": false, "tourCompleted": false],
            "account": ["opaque": "keep"], "uri": ["enabled": true], "delivery": ["foreign": 42]]
        try files.write(JSONSerialization.data(withJSONObject: initial), at: "settings.json")
        start()
        let page = try show()
        page.delivery.setRestore(true)
        page.updates.setAutomatic(false)
        XCTAssertEqual(page.delivery.state.preferences.clipboardRestore, .previousText)
        XCTAssertEqual(page.updates.state.automaticUpdateChecks, .disabled)
        start()
        let restarted = try show()
        XCTAssertEqual(restarted.delivery.state.preferences.clipboardRestore, .previousText)
        XCTAssertEqual(restarted.updates.state.automaticUpdateChecks, .disabled)
        XCTAssertEqual(restarted.updates.state.update?.result, .notChecked)
        XCTAssertTrue(restarted.updates.canCheck)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: files.read(at: "settings.json")) as? [String: Any])
        XCTAssertEqual((object["account"] as? [String: String])?["opaque"], "keep")
        XCTAssertEqual((object["uri"] as? [String: Bool])?["enabled"], true)
        XCTAssertEqual((object["delivery"] as? [String: Any])?["foreign"] as? Int, 42)
        assertRequestCount()
    }

    func testRepeatedSaveErrorsKeepCommittedChoicesAndRemainRetryable() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        start()
        let page = try show()
        // Make a readable existing file; deny atomic replacement in its parent.
        page.delivery.setRestore(false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: data.path)
        for _ in 0..<2 {
            page.delivery.setRestore(true)
            page.updates.setAutomatic(false)
            XCTAssertEqual(page.delivery.state.preferences.clipboardRestore, .off)
            XCTAssertEqual(page.updates.state.automaticUpdateChecks, .enabled)
            XCTAssertNotNil(page.delivery.state.settingsError)
            XCTAssertNotNil(page.updates.state.settingsError)
            XCTAssertTrue(page.delivery.canEdit)
            XCTAssertTrue(page.updates.canEdit)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        page.delivery.setRestore(true)
        page.updates.setAutomatic(false)
        XCTAssertEqual(page.delivery.state.preferences.clipboardRestore, .previousText)
        XCTAssertEqual(page.updates.state.automaticUpdateChecks, .disabled)
        XCTAssertNil(page.delivery.state.settingsError)
        XCTAssertNil(page.updates.state.settingsError)
    }

    func testReadOnlySettingsDisableBothControlsWithoutWritingOrChecking() throws {
        let files = try RootedFileStore(root: data)
        try files.createRoot()
        let bytes = Data("{\"version\":999}".utf8)
        try files.write(bytes, at: "settings.json")
        start()
        let page = try show()
        XCTAssertFalse(page.delivery.canEdit)
        XCTAssertFalse(page.updates.canEdit)
        page.delivery.setRestore(true)
        page.updates.setAutomatic(false)
        XCTAssertEqual(page.delivery.state.settingsError, .futureVersion(999))
        XCTAssertEqual(page.updates.state.settingsError, .futureVersion(999))
        XCTAssertEqual(try files.read(at: "settings.json"), bytes)
        assertRequestCount()
    }

    func testFixedMacChordAndSharedSetupTestForwardExactlyOnce() throws {
        start()
        let page = try show()
        delegate.settingsModel?.setLinuxDefaultPasteChord(.terminal)
        XCTAssertEqual(DeliverySettingsStrings.chordLabel(.terminal, session: .macOS), "Cmd+V")
        XCTAssertEqual(page.delivery.state.delivery?.pasteLadder, [.cgEvent, .appleScript])
        XCTAssertEqual(page.delivery.state.permissionRows.map(\.kind), [.accessibility, .portal, .ydotool])
        XCTAssertEqual(page.delivery.state.permissionRows.first { $0.kind == .portal }?.status, .notApplicable)
        XCTAssertEqual(page.delivery.state.permissionRows.first { $0.kind == .ydotool }?.status, .notApplicable)
        page.delivery.openSetup()
        XCTAssertEqual(setupOpens, 1)
        XCTAssertEqual(NSApp.windows.filter { $0.isVisible && $0.title == Strings.setupTitle }.count, 1)
        page.delivery.testPaste()
        page.delivery.testPaste()
        XCTAssertEqual(page.delivery.state.test, .testing)
        waitFor("delivery self-test report") { if case .tested = page.delivery.state.test { return true }; return false }
        XCTAssertEqual(selfTestTarget.presentations, 2, "One self-test checks both macOS backends")
        XCTAssertEqual(selfTestTarget.closes, 2)
        XCTAssertEqual(injector.chords, [.standard])
        XCTAssertTrue(SettingsDeliveryStrings.test(page.delivery.state.test)?.contains("readback verified") == true)
        XCTAssertTrue(SettingsDeliveryStrings.automation(page.delivery.state).contains("backend unavailable"))
        assertRequestCount()
    }

    func testDisablingRestoreCancelsPendingNativePasteboardRestore() throws {
        try RootedFileStore(root: root).createRoot()
        try RootedFileStore(root: root).write(Data("delivered".utf8), at: "prompt.md")
        start()
        let page = try show()
        page.delivery.setRestore(true)
        try XCTUnwrap(delegate.settingsWindow?.window).close()
        PasteboardClipboard(pasteboard: pasteboard).writeText("previous")
        let picker = try XCTUnwrap(delegate.pickerModel)
        picker.open()
        picker.usePreferred()
        waitFor("picker delivery completion") { if case .done = picker.state { return true }; return false }
        XCTAssertEqual(injector.chords, [.standard])
        XCTAssertEqual(timers.restores.count, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "delivered")
        delegate.showSettings()
        page.delivery.setRestore(false)
        timers.fireRestores()
        XCTAssertEqual(pasteboard.string(forType: .string), "delivered")
    }

    func testAppMenuCheckForUpdatesShowsGeneralAndPublishesTheResult() throws {
        start()
        delegate.settingsWindow?.presentation.selectedTab = .assistant
        transport.hold = true
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        XCTAssertTrue(delegate.validateMenuItem(item))
        delegate.checkForUpdates(item)
        let settings = try XCTUnwrap(delegate.settingsWindow)
        XCTAssertEqual(settings.presentation.selectedTab, .general)
        XCTAssertTrue(try XCTUnwrap(settings.window).isVisible)
        waitFor("menu check starts") { self.transport.count == 1 && settings.presentation.updates.state.update?.isChecking == true }
        XCTAssertFalse(delegate.validateMenuItem(item))
        transport.release()
        waitFor("menu check result") {
            settings.presentation.updates.state.update?.canOpenRelease == true
                && settings.presentation.updates.state.update?.isChecking == false
        }
        XCTAssertTrue(delegate.validateMenuItem(item))
        XCTAssertTrue(opened.isEmpty)
    }

    func testAppMenuCheckForUpdatesIsDisabledWithoutAKnownReleaseVersion() {
        start(version: nil)
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        XCTAssertFalse(delegate.validateMenuItem(item))
        delegate.checkForUpdates(item)
        XCTAssertNotEqual(delegate.settingsWindow?.window?.isVisible, true)
        assertRequestCount(0)
    }

    func testCheckNowWorksWhileOffAndOnlyExplicitViewOpensConstructedURL() throws {
        start()
        let page = try show().updates
        page.setAutomatic(false)
        XCTAssertEqual(page.state.update?.result, .notChecked)
        XCTAssertTrue(page.canCheck)
        transport.hold = true
        page.checkNow()
        waitFor("first manual request in flight") { self.transport.count == 1 && page.state.update?.isChecking == true }
        XCTAssertFalse(page.canCheck)
        XCTAssertEqual(SettingsUpdateStrings.result(page.state.update), "Checking for updates…")
        page.checkNow()
        assertRequestCount(1)
        transport.release()
        waitFor("manual check completed with a release") {
            page.state.update?.canOpenRelease == true && page.state.update?.isChecking == false
        }
        XCTAssertEqual(SettingsUpdateStrings.result(page.state.update), "Update available: 1.0.0.")
        XCTAssertNotNil(page.state.update?.lastSuccessfulCheck)
        XCTAssertTrue(opened.isEmpty)
        opensSucceed = false
        page.viewRelease()
        waitFor("release-page failure publication") { page.state.update?.releasePageOpeningFailed == true }
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/L-K-M/MonkeysPaw/releases/tag/v1.0.0"])
        opensSucceed = true
        page.viewRelease()
        waitFor("second release-page open and success publication") {
            self.opened.count == 2 && page.state.update?.releasePageOpeningFailed == false
        }
        XCTAssertEqual(transport.requests.first?.headers["User-Agent"], "MonkeysPaw/1.0.0-beta.2")
        XCTAssertEqual(updateTimers.jobs.count, 0)
    }

    func testCheckNowSeparatesUpToDateNoReleaseOfflineMalformedAndRateLimit() throws {
        start(version: "1.0.0")
        let page = try show().updates
        check(page, expecting: .upToDate)
        XCTAssertEqual(SettingsUpdateStrings.result(page.state.update), "You are up to date.")
        transport.reply = .success(HTTPResponse(statusCode: 404, body: Data()))
        check(page, expecting: .noRelease)
        XCTAssertEqual(SettingsUpdateStrings.result(page.state.update), "No stable release is available.")
        transport.reply = .failure(.networkFailure)
        check(page, expecting: .unavailable(.offline))
        transport.reply = .success(HTTPResponse(statusCode: 200, body: Data("invalid".utf8)))
        check(page, expecting: .unavailable(.malformedResponse))
        transport.reply = .success(HTTPResponse(statusCode: 429, headers: ["Retry-After": "3600"], body: Data()))
        page.checkNow()
        waitFor("HTTP 429 completion and rate-limit publication") {
            page.state.update?.rateLimit?.statusCode == 429 && page.state.update?.isChecking == false
        }
        XCTAssertTrue(SettingsUpdateStrings.result(page.state.update).contains("HTTP 429"))
        let count = transport.count
        page.checkNow()
        page.model.refresh()
        assertRequestCount(count)
        XCTAssertEqual(page.state.update?.isChecking, false)
        XCTAssertFalse(page.canViewRelease)
    }

    func testCorruptUpdateHistoryIsVisibleAndManualCheckLeavesItUntouched() throws {
        let files = try RootedFileStore(root: data)
        try files.createRoot()
        let bytes = Data("corrupt".utf8)
        try files.write(bytes, at: "update-state.json")
        start()
        let page = try show().updates
        XCTAssertEqual(page.state.update?.stateError, .corruptFile)
        XCTAssertTrue(SettingsUpdateStrings.stateError(.corruptFile).contains("Automatic checks are blocked"))
        check(page, expecting: .updateAvailable(try XCTUnwrap(ReleaseVersion("1.0.0"))))
        XCTAssertEqual(page.state.update?.stateError, .corruptFile)
        XCTAssertEqual(try files.read(at: "update-state.json"), bytes)
    }

    func testUnversionedAndInvalidVersionsDisableCheckNowWithoutTraffic() throws {
        for version: String? in [nil, "bad"] {
            start(version: version)
            let page = try show().updates
            XCTAssertFalse(page.canCheck)
            page.checkNow()
            XCTAssertEqual(page.state.update?.result, .unavailable(version == nil ? .unversionedBuild : .invalidCurrentVersion))
            assertRequestCount()
            XCTAssertEqual(updateTimers.jobs.count, 0)
        }
    }

    func testCloseReopenDetachesViewCallbacksAndRefreshesSameModels() throws {
        start()
        let page = try show()
        let window = try XCTUnwrap(delegate.settingsWindow?.window)
        window.close()
        XCTAssertNil(page.delivery.model.onChange)
        XCTAssertNil(page.updates.model.onChange)
        XCTAssertFalse(page.delivery.canTest)
        page.delivery.testPaste()
        page.updates.checkNow()
        delegate.settingsModel?.setClipboardRestore(.previousText)
        delegate.settingsModel?.setAutomaticUpdateChecks(.disabled)
        delegate.showSettings()
        XCTAssertTrue(delegate.settingsWindow?.window === window)
        XCTAssertTrue(delegate.settingsWindow?.presentation.delivery === page.delivery)
        XCTAssertEqual(page.delivery.state.preferences.clipboardRestore, .previousText)
        XCTAssertEqual(page.updates.state.automaticUpdateChecks, .disabled)
        XCTAssertNotNil(page.delivery.model.onChange)
        XCTAssertNotNil(page.updates.model.onChange)
        XCTAssertEqual(selfTestTarget.presentations, 0)
        assertRequestCount()
    }

    func testManualCheckFinishesWhileClosedAndReopenShowsSharedResult() throws {
        start()
        let page = try show()
        transport.hold = true
        page.updates.checkNow()
        waitFor("manual request in flight before closing Settings") {
            self.transport.count == 1 && page.updates.state.update?.isChecking == true
        }
        let window = try XCTUnwrap(delegate.settingsWindow?.window)
        window.close()
        XCTAssertNil(page.updates.model.onChange)
        transport.release()
        waitFor("closed Settings model receives the release") { page.updates.model.state.update?.canOpenRelease == true }
        XCTAssertEqual(page.updates.state.update?.isChecking, true, "Hidden view callbacks remain detached")
        delegate.showSettings()
        waitFor("reopened Settings presents the release") { page.updates.canViewRelease }
        XCTAssertTrue(delegate.settingsWindow?.window === window)
        assertRequestCount(1)
        XCTAssertEqual(updateScheduler.pendingCount, 0)
        XCTAssertTrue(opened.isEmpty)
    }

    func testLibraryReplacementPreservesManualCheckAndShutdownRetiresOldIntents() throws {
        start()
        let page = try show()
        transport.hold = true
        page.updates.checkNow()
        waitFor("manual request in flight before library replacement") {
            self.transport.count == 1 && page.updates.state.update?.isChecking == true
        }
        let other = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        transport.release()
        waitFor("release publication after library replacement") { page.updates.canViewRelease }
        assertRequestCount(1)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let committed = try XCTUnwrap(delegate.settingsModel).state
        page.delivery.model.setClipboardRestore(.previousText)
        page.updates.model.setAutomaticUpdateChecks(.disabled)
        page.updates.model.checkNow()
        page.updates.model.viewRelease()
        page.delivery.model.openSetup()
        delegate.settingsModel?.setLinuxDefaultPasteChord(.terminal)
        assertRequestCount(1)
        XCTAssertEqual(delegate.settingsModel?.deliveryPreferences.clipboardRestore, committed.document.delivery.clipboardRestore)
        XCTAssertEqual(delegate.settingsModel?.automaticUpdateChecks, committed.document.automaticUpdateChecks)
        XCTAssertNil(page.delivery.model.onChange)
        XCTAssertNil(page.updates.model.onChange)
        XCTAssertEqual(updateScheduler.pendingCount, 0)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(setupOpens, 0)
    }

    func testSettingsControlsHaveLabelsAndKeepNativeKeyboardFocus() throws {
        start()
        let page = try show()
        let content = NSHostingView(rootView: VStack {
            SettingsDeliveryView(presentation: page.delivery)
            SettingsUpdateView(presentation: page.updates)
        })
        // Like the shortcut tests, this host can become key while XCTest's app is inactive.
        let window = MacSettingsKeyViewPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1400),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.contentView = content
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.close() }
        waitFor("Settings test host becomes key") { window.isKeyWindow }
        content.layoutSubtreeIfNeeded()
        // A client query activates SwiftUI's otherwise lazy virtual accessibility tree.
        // Run it off-main so AppKit can answer while XCTest pumps the main run loop.
        let accessibilityReady = expectation(description: "Hosted accessibility client query completed")
        DispatchQueue.global(qos: .userInitiated).async {
            let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            var children: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(application, kAXChildrenAttribute as CFString, &children)
            XCTAssertEqual(status, .success, "Hosted accessibility initialization failed: \(status.rawValue)")
            accessibilityReady.fulfill()
        }
        wait(for: [accessibilityReady], timeout: 5)
        let expectedLabels: Set<String> = [DeliverySettingsStrings.restoreClipboard, DeliverySettingsStrings.testPaste,
            DeliverySettingsStrings.openSetup, SettingsUpdateStrings.automatic,
            SettingsUpdateStrings.checkNow, SettingsUpdateStrings.viewRelease]
        var observedLabels = Set<String>()
        waitFor("missing accessibility labels=\(expectedLabels.subtracting(observedLabels).sorted()); observed=\(observedLabels.sorted())") {
            observedLabels = self.accessibilityLabels(content)
            return expectedLabels.isSubset(of: observedLabels)
        }
        // AppKit excludes buttons and toggles from valid key views when Keyboard navigation is off.
        if NSApp.isFullKeyboardAccessEnabled {
            window.recalculateKeyViewLoop()
            let firstKeyView = try XCTUnwrap(content.nextValidKeyView, "Settings must have a valid key view")
            window.initialFirstResponder = firstKeyView
            XCTAssertTrue(window.makeFirstResponder(nil))
            window.selectNextKeyView(nil)
            XCTAssertTrue(window.firstResponder === firstKeyView, "Forward traversal must select the initial key view")
            XCTAssertTrue(firstKeyView.isDescendant(of: content), "Forward traversal must stay in Settings")
            let previousKeyView = try XCTUnwrap(firstKeyView.previousValidKeyView,
                "Settings must have a previous valid key view")
            window.selectPreviousKeyView(nil)
            XCTAssertTrue(window.firstResponder === previousKeyView, "Reverse traversal must select the previous key view")
            XCTAssertTrue(previousKeyView.isDescendant(of: content), "Reverse traversal must stay in Settings")
        } else {
            print("Skipping Settings Tab/Shift+Tab assertions because macOS Keyboard navigation is off; " +
                  "see docs/platform/macos.md (M7 D17).")
        }
        XCTAssertTrue(window.isVisible)
        assertRequestCount(0, "Key-view traversal must not activate a check or self-test")
        XCTAssertEqual(selfTestTarget.presentations, 0)
        XCTAssertEqual(updateTimers.jobs.count, 0)
        XCTAssertEqual(updateScheduler.pendingCount, 0)
        XCTAssertTrue(opened.isEmpty)
    }

    func testAccessibilityLabelsTraverseChildrenWithoutProtocolConformance() {
        let child = MacSettingsAccessibilityNode(label: "Nested control")
        let parent = MacSettingsAccessibilityNode(label: "Parent", children: [child, NSObject()])
        let root = NSView()
        root.setAccessibilityChildren([parent])
        XCTAssertFalse((child as AnyObject) is NSAccessibilityProtocol)
        XCTAssertEqual(accessibilityLabels(root), ["Parent", "Nested control"])
    }

    func testAccessibilityLabelsReadControlTitlesAndPreferExplicitLabels() {
        let titled = MacSettingsAccessibilityNode(title: "Titled control")
        let attributed = MacSettingsAccessibilityNode(title: NSAttributedString(string: "Attributed title"))
        let labelled = MacSettingsAccessibilityNode(label: "Explicit label", title: "Visible title")
        let root = MacSettingsAccessibilityNode(children: [titled, attributed, labelled])
        XCTAssertNil(titled.accessibilityLabel())
        XCTAssertEqual(accessibilityLabels(root), ["Titled control", "Attributed title", "Explicit label"])
    }

    private func accessibilityLabels(_ element: NSObject) -> Set<String> {
        var result = Set<String>()
        // SwiftUI accessibility children may expose selectors without adopting the full protocol.
        // AppKit controls may expose their accessible name as a title instead of a label.
        for selector in [#selector(NSAccessibilityProtocol.accessibilityLabel),
                         #selector(NSAccessibilityProtocol.accessibilityTitle)] {
            guard element.responds(to: selector),
                  let value = element.perform(selector)?.takeUnretainedValue() else { continue }
            let name = (value as? String) ?? (value as? NSAttributedString)?.string
            if let name, !name.isEmpty {
                result.insert(name)
                break
            }
        }
        let childrenSelector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        if element.responds(to: childrenSelector),
           let children = element.perform(childrenSelector)?.takeUnretainedValue() as? [Any] {
            for child in children {
                if let child = child as? NSObject { result.formUnion(accessibilityLabels(child)) }
            }
        }
        return result
    }
}

private final class MacSettingsKeyViewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
