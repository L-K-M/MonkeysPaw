import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class AppDelegateTests: XCTestCase {
    func testHostedLaunchBuildsGraphWithoutWindowsOrNativeHotkeys() throws {
        XCTAssertTrue(AppDelegate.isRunningTests)
        let windows = NSApp.windows.map(ObjectIdentifier.init)
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

        XCTAssertNotNil(delegate.panelModel)
        let model = try XCTUnwrap(delegate.setupModel)
        XCTAssertEqual(model.session, .macOS)
        XCTAssertEqual(model.rows.first(where: { $0.kind == .hotkey })?.registration?.status, .unbound)
        XCTAssertEqual(NSApp.windows.map(ObjectIdentifier.init), windows)
    }

    func testAutomationFallbackHasUsageDescriptionInHostedApp() {
        let description = Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String
        XCTAssertFalse(description?.isEmpty ?? true)
    }

    func testOpeningSetupDoesNotActivateTheCapturedApp() throws {
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        }
        let ownPID = NSRunningApplication.current.processIdentifier
        let target = DeliveryTarget.macOS(processID: ownPID + 1, bundleID: "test.external")
        var frontmost: DeliveryTarget? = target
        var activations: [DeliveryTarget] = []
        let delegate = AppDelegate(makeFocusTracker: { mainThread, scheduler in
            WorkspaceFocusTracker(
                source: .init(frontmost: { frontmost }, activate: { activations.append($0); return true }),
                ownPID: ownPID, mainThread: mainThread, scheduler: scheduler,
                isTrusted: { false }, deactivateIfUnused: {})
        })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let model = try XCTUnwrap(delegate.panelModel)
        model.show()
        frontmost = .macOS(processID: ownPID, bundleID: "test.own")

        // Invoke the status-menu action without a real event or external app.
        _ = delegate.perform(Selector(("showSetup")))
        XCTAssertEqual(NSApp.keyWindow?.title, Strings.setupTitle)
        XCTAssertTrue(activations.isEmpty, "Setup must become key before the panel dismisses")
    }
}
