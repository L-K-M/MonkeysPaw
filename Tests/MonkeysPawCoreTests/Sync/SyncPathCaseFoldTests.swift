import XCTest
@testable import MonkeysPawCore

final class SyncPathCaseFoldTests: XCTestCase {
    func testTableHasSortedRangesAndDisjointValidIdempotentMappings() throws {
        let ranges = SyncPathCaseFold.ranges
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertEqual(ranges.map(\.first), ranges.map(\.first).sorted())
        var inputs = Set<UInt32>()

        for range in ranges {
            guard range.first <= range.last, range.step > 0 else {
                XCTFail("Invalid case-fold range.")
                continue
            }
            XCTAssertEqual((range.last - range.first) % range.step, 0)
            for value in stride(from: range.first, through: range.last, by: Int(range.step)) {
                XCTAssertTrue(inputs.insert(value).inserted, "Duplicate case-fold input.")
                XCTAssertNotNil(Unicode.Scalar(value))
                let mappedValue = try XCTUnwrap(UInt32(exactly: Int64(value) + range.delta))
                let mapped = String(try XCTUnwrap(Unicode.Scalar(mappedValue)))
                XCTAssertTrue(SyncPathCaseFold.fold(mapped).utf8.elementsEqual(mapped.utf8))
            }
        }

        for (value, replacement) in SyncPathCaseFold.exceptions {
            XCTAssertTrue(inputs.insert(value).inserted, "Duplicate case-fold input.")
            XCTAssertNotNil(Unicode.Scalar(value))
            XCTAssertFalse(replacement.isEmpty)
            XCTAssertTrue(SyncPathCaseFold.fold(replacement).utf8.elementsEqual(replacement.utf8))
        }
    }

    func testFullDefaultFoldingExcludesSimpleAndTurkicAlternatives() {
        // S would map capital sharp-s to ß; T would map I/İ to ı/i.
        XCTAssertTrue(SyncPathCaseFold.fold("Iİẞ").utf8.elementsEqual("ii\u{307}ss".utf8))
    }
}
