import XCTest
@testable import MonkeysPawCore

final class ReleaseVersionTests: XCTestCase {
    func testStrictVersionsAndPrefixEquality() throws {
        for value in ["0.0.0", "1.2.3", "v1.2.3", "1.2.3-beta.12", "1.2.3-a-b.0"] {
            XCTAssertNotNil(ReleaseVersion(value), value)
        }
        XCTAssertEqual(ReleaseVersion("v1.2.3"), ReleaseVersion("1.2.3"))
        XCTAssertEqual(ReleaseVersion("v1.2.3-beta.2")?.description, "1.2.3-beta.2")
        XCTAssertTrue(try XCTUnwrap(ReleaseVersion("1.2.3-beta.2")).isPrerelease)
    }

    func testMalformedVersionsNeverBecomeZero() {
        for value in ["", "v", "V1.2.3", " 1.2.3", "1.2.3\n", "1", "1.2", "1.2.3.4",
                      "01.2.3", "1.02.3", "1.2.03", "-1.2.3", "+1.2.3", "1.2.3+build",
                      "1.2.3-", "1.2.3-beta..1", "1.2.3-.a", "1.2.3-beta.01",
                      "1.2.3-β", "1.2.3-😀", "1.2.3-a/b", "1.2.3-a?x", "1.2.3-０"] {
            XCTAssertNil(ReleaseVersion(value), value)
        }
        XCTAssertNil(ReleaseVersion("1.2.3-" + String(repeating: "a", count: Limits.releaseVersionMaxBytes)))
    }

    func testCoreNumbersCompareNumericallyWithoutIntegerOverflow() throws {
        let versions = ["0.99.99", "1.2.3", "1.2.10", "1.10.0", "2.0.0", "10.0.0",
                        "999999999999999999999999999999.0.0", "1000000000000000000000000000000.0.0"]
        try assertOrdered(versions)
    }

    func testSemanticPrereleaseOrdering() throws {
        try assertOrdered(["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
            "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1-alpha"])
        try assertOrdered(["1.0.0-1", "1.0.0-2", "1.0.0-10", "1.0.0-99999999999999999999",
                           "1.0.0-100000000000000000000", "1.0.0-A", "1.0.0-a"])
    }

    private func assertOrdered(_ values: [String]) throws {
        let versions = try values.map { try XCTUnwrap(ReleaseVersion($0)) }
        for (index, older) in versions.enumerated() {
            XCTAssertFalse(older < older)
            for newer in versions.dropFirst(index + 1) {
                XCTAssertLessThan(older, newer)
                XCTAssertFalse(newer < older)
                XCTAssertNotEqual(older, newer)
            }
        }
    }
}
