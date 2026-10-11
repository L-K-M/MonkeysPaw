import Foundation
import MonkeysPawCore
import XCTest

final class LibraryAvailablePathTests: XCTestCase {
    private var library: MemoryFileStore!
    private var service: LibraryService!

    override func setUp() {
        library = MemoryFileStore()
        service = LibraryService(library: library, data: MemoryFileStore(),
                                 clock: LibraryClock(), entropy: LibraryEntropy())
    }

    func testFullASCIIFilenameCollisionFitsBudgetAndKeepsExactTitle() throws {
        let title = String(repeating: "a", count: Limits.promptFilenameMaxBytes - 3)
        let path = PromptCreation.relativePath(title: title, now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(path.utf8.count, Limits.promptFilenameMaxBytes)
        try library.put("Existing", at: path)

        let candidate = try service.availablePath(for: path)
        XCTAssertEqual(candidate, String(repeating: "a", count: 250) + " 2.md")
        XCTAssertLessThanOrEqual(candidate.utf8.count, Limits.promptFilenameMaxBytes)

        let document = try PromptCodec.newDocument(title: title, body: "New")
        let saved = try service.save(document, at: candidate)
        XCTAssertEqual(saved.document.frontMatter.title, title)
        XCTAssertEqual(try library.text(at: path), "Existing")
    }

    func testMultibyteStemsKeepWholeScalars() throws {
        for (scalar, count, retained) in [("界", 84, 83), ("😀", 63, 62)] {
            let path = String(repeating: scalar, count: count) + ".md"
            XCTAssertEqual(path.utf8.count, Limits.promptFilenameMaxBytes)
            try library.put("Existing", at: path)

            let candidate = try service.availablePath(for: path)
            XCTAssertEqual(candidate, String(repeating: scalar, count: retained) + " 2.md")
            XCTAssertLessThanOrEqual(candidate.utf8.count, Limits.promptFilenameMaxBytes)
        }
    }

    func testTruncationKeepsWholeGraphemeClusters() throws {
        let grapheme = "e\u{301}"
        let path = String(repeating: grapheme, count: 84) + ".md"
        try library.put("Existing", at: path)

        let candidate = try service.availablePath(for: path)
        let expected = String(repeating: grapheme, count: 83) + " 2.md"
        XCTAssertTrue(candidate.utf8.elementsEqual(expected.utf8))
        XCTAssertLessThanOrEqual(candidate.utf8.count, Limits.promptFilenameMaxBytes)
    }

    func testSuffixWidthsFitThroughCandidateCap() throws {
        let path = String(repeating: "a", count: Limits.promptFilenameMaxBytes - 3) + ".md"
        try library.put("Existing", at: path)
        let lastSuffix = Limits.libraryCopyCandidateCap + 1

        for suffix in 2...lastSuffix {
            let ending = " \(suffix).md"
            let expected = String(repeating: "a", count: Limits.promptFilenameMaxBytes - ending.utf8.count) + ending
            if [10, 100, lastSuffix].contains(suffix) {
                let candidate = try service.availablePath(for: path)
                XCTAssertEqual(candidate, expected)
                XCTAssertLessThanOrEqual(candidate.utf8.count, Limits.promptFilenameMaxBytes)
            }
            try library.put("Existing", at: expected)
        }

        XCTAssertThrowsError(try service.availablePath(for: path)) {
            XCTAssertEqual($0 as? LibraryError, .copyLimitReached)
        }
    }

    func testNestedCollisionPreservesDirectoryComponents() throws {
        let folder = String(repeating: "d", count: Limits.promptFilenameMaxBytes) + "/nested/"
        let path = folder + String(repeating: "a", count: Limits.promptFilenameMaxBytes - 3) + ".md"
        try library.put("Existing", at: path)

        let candidate = try service.availablePath(for: path)
        XCTAssertEqual(candidate, folder + String(repeating: "a", count: 250) + " 2.md")
        let filename = try XCTUnwrap(candidate.split(separator: "/").last)
        XCTAssertLessThanOrEqual(filename.utf8.count, Limits.promptFilenameMaxBytes)
    }

    func testNestedCollisionRecognizesSlashBeforeCombiningScalar() throws {
        let folder = "parent/" + String(repeating: "d", count: Limits.promptFilenameMaxBytes) + "/"
        let path = folder + "\u{301}" + String(repeating: "a", count: 250) + ".md"
        try library.put("Existing", at: path)

        let candidate = try service.availablePath(for: path)
        let expected = folder + "\u{301}" + String(repeating: "a", count: 248) + " 2.md"
        XCTAssertTrue(candidate.utf8.elementsEqual(expected.utf8))
    }

    func testNoncollidingPathsStayByteExact() throws {
        for path in ["Name.md", String(repeating: "a", count: 252) + ".md",
                     String(repeating: "界", count: 84) + ".md",
                     "folder/" + String(repeating: "😀", count: 63) + ".md"] {
            XCTAssertTrue(try service.availablePath(for: path).utf8.elementsEqual(path.utf8))
        }
    }
}
