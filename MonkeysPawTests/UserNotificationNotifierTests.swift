import UserNotifications
import MonkeysPawCore
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

    func testUnavailableNotificationUsesSharedCopyWithoutSoundActionsOrTrigger() throws {
        let center = UNUserNotificationCenter.current()
        let previousDelegate = center.delegate
        defer { center.delegate = previousDelegate }
        var requests: [UNNotificationRequest] = []
        let notifier = UserNotificationNotifier(requestAuthorization: { _, done in done(true) },
            submit: { resolved, request in
                XCTAssertTrue(resolved === center)
                requests.append(request)
            })

        notifier.libraryUnavailable()

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.content.title, OnboardingStrings.libraryUnavailableNotificationTitle)
        XCTAssertEqual(request.content.body, OnboardingStrings.libraryUnavailableNotificationBody)
        XCTAssertNil(request.content.sound)
        XCTAssertEqual(request.content.categoryIdentifier, "")
        XCTAssertNil(request.trigger)
    }

    func testDeniedUnavailableNotificationDoesNotSubmitAndDeliveryCopyIsUnchanged() {
        let center = UNUserNotificationCenter.current()
        let previousDelegate = center.delegate
        defer { center.delegate = previousDelegate }
        var requests: [UNNotificationRequest] = []
        let denied = UserNotificationNotifier(requestAuthorization: { _, done in done(false) },
            submit: { _, _ in XCTFail("Denied notifications must not be submitted") })
        denied.libraryUnavailable()
        let allowed = UserNotificationNotifier(requestAuthorization: { _, done in done(true) },
            submit: { _, request in requests.append(request) })
        allowed.copied()
        allowed.pressPaste(chord: .standard, reason: .backendsFailed([
            BackendFailure(backend: .cgEvent, reason: .permissionDenied)
        ]))
        XCTAssertEqual(requests.map { $0.content.title }, [AppIdentity.displayName, AppIdentity.displayName])
        XCTAssertEqual(requests.map { $0.content.body }, [DeliveryStrings.copied, DeliveryStrings.pressCommandV])
    }
}
