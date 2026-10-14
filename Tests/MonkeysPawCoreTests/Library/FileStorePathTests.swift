import XCTest
@testable import MonkeysPawCore

final class FileStorePathTests: XCTestCase {
    func testWireAndRootedBoundariesAreIndependent() throws {
        let scope = Array(repeating: String(repeating: "a", count: 200), count: 4).joined(separator: "/")
            + "/" + String(repeating: "b", count: 217) + ".md"
        XCTAssertEqual(scope.utf8.count, 1_024)
        XCTAssertEqual(Limits.maxPathBytes, 1_024)
        XCTAssertEqual(Limits.maxRootedPathBytes, 1_287)
        XCTAssertNoThrow(try SyncPathValidator.validate(scope, scope: .group))
        XCTAssertThrowsError(try SyncPathValidator.validate("x" + scope, scope: .group)) {
            XCTAssertEqual(($0 as? SyncPathIssue)?.code, .pathTooLong)
        }
        let rooted = "Groups/" + String(repeating: "g", count: 255) + "/" + scope
        XCTAssertEqual(rooted.utf8.count, 1_287)
        XCTAssertNoThrow(try FileStorePath.validate(rooted))
        XCTAssertNoThrow(try LibraryPath.validate(rooted))
        XCTAssertThrowsError(try FileStorePath.validate("x" + rooted)) {
            XCTAssertEqual($0 as? FileStoreError, .invalidPath)
        }
    }
}
