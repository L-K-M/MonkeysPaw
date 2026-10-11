import Foundation
import MonkeysPawCore
import XCTest

final class PromptCreationTests: XCTestCase {
    func testQueryCreatesOneVisibleSafeFilename() throws {
        for title in ["New prompt", " ../folder/name ", "_hidden", ".hidden", "a\\b", "a\n\u{0}b", "文書"] {
            let path = PromptCreation.relativePath(title: title, now: Date(timeIntervalSince1970: 10))
            XCTAssertNoThrow(try FileStorePath.validate(path))
            XCTAssertFalse(path.contains("/"))
            XCTAssertFalse(path.hasPrefix("_"))
            XCTAssertFalse(path.hasPrefix("."))
            XCTAssertTrue(path.hasSuffix(".md"))
        }
        XCTAssertEqual(PromptCreation.relativePath(title: "New prompt", now: Date()), "New prompt.md")
    }

    func testIgnoredEmptyAndOverlongNamesUseTimestampFallback() {
        for title in ["", "  ..__  ", "README", String(repeating: "x", count: 256), String(repeating: "界", count: 100)] {
            XCTAssertEqual(PromptCreation.relativePath(title: title, now: Date(timeIntervalSince1970: 10)), "Prompt 10.md")
        }
    }
}
