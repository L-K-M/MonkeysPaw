import UserNotifications
import XCTest
@testable import MonkeysPaw

final class UserNotificationNotifierTests: XCTestCase {
    func testInstallsForegroundDelegateBeforeRequestingPermission() {
        let center = UNUserNotificationCenter.current()
        let previousDelegate = center.delegate
        defer { center.delegate = previousDelegate }
        center.delegate = nil
        var authorizations = 0
        let notifier = UserNotificationNotifier(requestAuthorization: { resolved, completion in
            authorizations += 1
            XCTAssertTrue(resolved === center)
            XCTAssertNotNil(resolved.delegate)
            let selector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))
            XCTAssertTrue(resolved.delegate?.responds(to: selector) == true)
            // No TCC request or actual notification is made in the hosted test.
            completion(false)
        })
        notifier.copied()
        XCTAssertEqual(authorizations, 1)
    }
}
