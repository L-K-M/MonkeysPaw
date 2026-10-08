import MonkeysPawCore
import XCTest

final class AppIdentityTests: XCTestCase {
    func testIdentifiersMatchThePlan() {
        XCTAssertEqual(AppIdentity.macOSBundleID, "ch.lkmc.MonkeysPaw")
        XCTAssertEqual(AppIdentity.linuxAppID, "ch.lkmc.monkeyspaw")
        XCTAssertEqual(AppIdentity.binaryName, "monkeyspaw")
        XCTAssertEqual(AppIdentity.displayName, "Monkey's Paw")
        XCTAssertEqual(AppIdentity.fallbackVersion, "0.0.0")
    }
}
