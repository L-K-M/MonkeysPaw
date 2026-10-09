import Foundation
import XCTest
import MonkeysPawCore

final class ULIDTests: XCTestCase {
    func testStandardAlphabetAndOverflowBound() {
        XCTAssertEqual(ULID("01arz3ndektsv4rrffq69g5fav")?.rawValue, "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        XCTAssertNotNil(ULID("00000000000000000000000000"))
        XCTAssertNotNil(ULID("7ZZZZZZZZZZZZZZZZZZZZZZZZZ"))
        for invalid in ["8ZZZZZZZZZZZZZZZZZZZZZZZZZ", "01ARZ3NDEKTSV4RRFFQ69G5FAI",
                        "01ARZ3NDEKTSV4RRFFQ69G5FAL", "01ARZ3NDEKTSV4RRFFQ69G5FAO",
                        "01ARZ3NDEKTSV4RRFFQ69G5FAU", "01ARZ3NDEKTSV4RRFFQ69G5FA",
                        "001ARZ3NDEKTSV4RRFFQ69G5FAV", "01ARZ3NDEKTSV4RRFFQ69G5FAé"] {
            XCTAssertNil(ULID(invalid), invalid)
        }
    }

    func testGenerationUsesSuppliedMillisecondsAndAllEntropyBits() throws {
        let epoch = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(try ULID.generate(at: epoch, entropy: Array(repeating: 0, count: 10)).rawValue,
                       "00000000000000000000000000")
        XCTAssertEqual(try ULID.generate(at: Date(timeIntervalSince1970: 1.0019),
                                        entropy: Array(repeating: 255, count: 10)).rawValue,
                       "00000000Z9ZZZZZZZZZZZZZZZZ")
        // Network-order 80-bit vector: 00 01 02 03 04 05 06 07 08 09.
        XCTAssertEqual(try ULID.generate(at: epoch, entropy: Array(0...9)).rawValue,
                       "0000000000000G40R40M30E209")
        let maximum = Date(timeIntervalSince1970: Double(281_474_976_710_655) / 1_000)
        XCTAssertEqual(try ULID.generate(at: maximum, entropy: Array(repeating: 255, count: 10)).rawValue,
                       "7ZZZZZZZZZZZZZZZZZZZZZZZZZ")
    }

    func testGenerationRejectsInvalidDateAndEntropy() {
        for seconds in [-1.0, .infinity, .nan, Double(281_474_976_710_656) / 1_000] {
            XCTAssertThrowsError(try ULID.generate(at: Date(timeIntervalSince1970: seconds),
                                                   entropy: Array(repeating: 0, count: 10))) {
                XCTAssertEqual($0 as? ULIDGenerationError, .invalidTimestamp)
            }
        }
        for count in [0, 9, 11] {
            XCTAssertThrowsError(try ULID.generate(at: Date(timeIntervalSince1970: 0),
                                                   entropy: Array(repeating: 0, count: count))) {
                XCTAssertEqual($0 as? ULIDGenerationError, .invalidEntropyLength)
            }
        }
    }
}
