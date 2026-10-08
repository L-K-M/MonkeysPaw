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
}
