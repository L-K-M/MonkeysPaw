import Foundation
import XCTest
@testable import MonkeysPawCore

final class MyersLineDiffTests: XCTestCase {
    func testClassicEmptyInsertionDeletionReplacementAndRepeatedLines() throws {
        let cases: [(String, String, Int)] = [
            ("", "", 0), ("", "a\nb\n", 2), ("a\nb\n", "", 2),
            ("a\nc\n", "a\nb\nc\n", 1), ("a\nb\nc\n", "a\nc\n", 1),
            ("a\nb\nc\n", "a\nx\nc\n", 2), ("a\nb\na\n", "a\na\nb\n", 2),
            ("A\nB\nC\nA\nB\nB\nA\n", "C\nB\nA\nB\nA\nC\n", 5),
            ("a\na\na\n", "a\na\n", 1), ("a\nb\na\n", "b\na\nb\n", 2),
            ("a\nb\nc\n", "x\ny\nz\n", 6), ("a\n", "b\nb\nb\nb\n", 5)
        ]
        for (old, new, distance) in cases { try assertDiff(old, new, distance: distance) }
    }

    func testDeletionTieBreakAndRepeatedLineAlignmentAreStable() throws {
        let replaced = try MyersLineDiff.compare("old\n", "new\n")
        XCTAssertEqual(replaced.map(\.kind), [.removed, .added])
        let repeated = try MyersLineDiff.compare("a\nb\na\n", "a\na\nb\n")
        XCTAssertEqual(repeated.map(\.kind), [.unchanged, .removed, .unchanged, .added])
        XCTAssertEqual(repeated.map(\.text), ["a\n", "b\n", "a\n", "b\n"])
        for _ in 0..<20 { XCTAssertEqual(try MyersLineDiff.compare("a\nb\na\n", "a\na\nb\n"), repeated) }
    }

    func testLineEndingsTrailingNewlinesAndUnicodeCompareExactBytes() throws {
        for (old, new, distance) in [("a\r\n", "a\n", 2), ("a\n", "a", 2), ("", "\n", 1),
                                     ("a\n", "a\n\n", 1), ("a\r\nb", "a\r\nc", 2),
                                     ("é\n", "e\u{301}\n", 2), ("\r", "\n", 2)] {
            try assertDiff(old, new, distance: distance)
        }
        XCTAssertTrue(try MyersLineDiff.compare("", "").isEmpty)
        XCTAssertEqual(try MyersLineDiff.compare("a\r\n", "a\r\n").first?.bytes, Data("a\r\n".utf8))
    }

    func testShortestScriptsAgainstIndependentSmallLCSOracle() throws {
        let sequences: [[String]] = [[]] + (1...4).flatMap { length in
            (0..<(1 << length)).map { mask in (0..<length).map { mask & (1 << $0) == 0 ? "a" : "b" } }
        }
        for old in sequences {
            for new in sequences {
                let oldSource = old.map { $0 + "\n" }.joined(), newSource = new.map { $0 + "\n" }.joined()
                let distance = old.count + new.count - 2 * lcs(old, new)
                try assertDiff(oldSource, newSource, distance: distance)
            }
        }
    }

    func testByteAndSearchWorkBoundsHaveTypedFailures() throws {
        let atCap = String(repeating: "x", count: Limits.maxPromptBytes)
        XCTAssertEqual(try MyersLineDiff.compare(atCap, atCap).count, 1)
        for (old, new) in [(atCap + "x", ""), ("", atCap + "x"),
                           (String(repeating: "é", count: Limits.maxPromptBytes / 2 + 1), "")] {
            XCTAssertThrowsError(try MyersLineDiff.compare(old, new)) { XCTAssertEqual($0 as? LineDiffError, .sourceTooLarge) }
        }
        let old = (0..<1_000).map { "old\($0)\n" }.joined(), new = (0..<1_000).map { "new\($0)\n" }.joined()
        for _ in 0..<2 {
            XCTAssertThrowsError(try MyersLineDiff.compare(old, new)) {
                XCTAssertEqual($0 as? LineDiffError, .comparisonTooComplex)
            }
        }
    }

    private func assertDiff(_ old: String, _ new: String, distance: Int,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let rows = try MyersLineDiff.compare(old, new)
        let oldRows = rows.filter { $0.kind != .added }, newRows = rows.filter { $0.kind != .removed }
        XCTAssertEqual(oldRows.reduce(into: Data()) { $0.append($1.bytes) }, Data(old.utf8), file: file, line: line)
        XCTAssertEqual(newRows.reduce(into: Data()) { $0.append($1.bytes) }, Data(new.utf8), file: file, line: line)
        XCTAssertEqual(oldRows.compactMap(\.originalLine), Array(1..<(oldRows.count + 1)), file: file, line: line)
        XCTAssertEqual(newRows.compactMap(\.mergedLine), Array(1..<(newRows.count + 1)), file: file, line: line)
        XCTAssertEqual(rows.filter { $0.kind != .unchanged }.count, distance, file: file, line: line)
        for row in rows {
            XCTAssertEqual(row.originalLine == nil, row.kind == .added, file: file, line: line)
            XCTAssertEqual(row.mergedLine == nil, row.kind == .removed, file: file, line: line)
        }
    }

    private func lcs(_ old: [String], _ new: [String]) -> Int {
        var table = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in old.indices {
            for j in new.indices {
                table[i + 1][j + 1] = old[i] == new[j] ? table[i][j] + 1 : max(table[i][j + 1], table[i + 1][j])
            }
        }
        return table[old.count][new.count]
    }
}
