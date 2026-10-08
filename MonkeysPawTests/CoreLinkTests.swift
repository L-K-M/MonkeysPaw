import Foundation
import MonkeysPawCore
import XCTest

final class CoreLinkTests: XCTestCase {
    func testHostedAppUsesCoreBundleIdentity() {
        // Bundle.main is the app, not the test bundle, because TEST_HOST is set.
        XCTAssertEqual(AppIdentity.macOSBundleID, Bundle.main.bundleIdentifier)
    }
}
