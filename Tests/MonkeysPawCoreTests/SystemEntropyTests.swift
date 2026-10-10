import XCTest
import MonkeysPawCore

final class SystemEntropyTests: XCTestCase {
    func testByteCountsAtChunkBoundaries() throws {
        let entropy = SystemEntropy()
        for count in [0, 1, 7, 8, 9, 10, 4_097] {
            XCTAssertEqual(try entropy.bytes(count: count).count, count)
        }
    }

    func testNegativeCountThrowsInvalidCount() {
        let entropy = SystemEntropy()
        for count in [-1, Int.min] {
            XCTAssertThrowsError(try entropy.bytes(count: count)) {
                XCTAssertEqual($0 as? SystemEntropyError, .invalidCount)
            }
        }
    }
}
