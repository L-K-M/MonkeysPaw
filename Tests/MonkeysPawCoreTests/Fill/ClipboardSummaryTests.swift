import XCTest
@testable import MonkeysPawCore

final class ClipboardSummaryTests: XCTestCase {
    private func kind(_ text: String) -> ClipboardSummary.Kind { ClipboardSummary(text).kind }

    func testEmptyCoversEmptyAndWhitespaceOnlyText() {
        XCTAssertEqual(kind(""), .empty)
        XCTAssertEqual(kind("   \n\t \n"), .empty)
        let summary = ClipboardSummary("")
        XCTAssertEqual(summary.lineCount, 0)
        XCTAssertEqual(summary.characterCount, 0)
    }

    func testDiffFromGitOrHunkHeaderStart() {
        XCTAssertEqual(kind("diff --git a/f b/f\nindex 1..2\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b"), .diff)
        XCTAssertEqual(kind("@@ -1,2 +1,2 @@ optional context"), .diff)
    }

    func testDiffFromPlusMinusThresholdWithMarker() {
        // Three +/- lines plus a +++/---/@@ marker, without a header line.
        XCTAssertEqual(kind("--- a/f\n+++ b/f\n-old\n+new"), .diff)
        XCTAssertEqual(kind("@@\n-a\n+b\n-c"), .diff)
        // Below the +/- count or without any marker stays text.
        XCTAssertEqual(kind("plain\n+a\n-b"), .text)
        XCTAssertEqual(kind("+a\n-b\n+c\nplain"), .text)
    }

    func testErrorMatchesListedMarkersCaseSensitively() {
        XCTAssertEqual(kind("Traceback (most recent call last):\n  File \"x.py\""), .error)
        XCTAssertEqual(kind("java.lang.Exception: boom"), .error)
        XCTAssertEqual(kind("panic: runtime error"), .error)
        XCTAssertEqual(kind("error: cannot find symbol"), .error)
        XCTAssertEqual(kind("Error: ENOENT"), .error)
        XCTAssertEqual(kind("fatal: not a git repository"), .error)
        // Only the listed spellings match; unlisted casing is plain text.
        XCTAssertEqual(kind("Fatal: everything is fine"), .text)
    }

    func testLinkRequiresASingleLineStartingWithScheme() {
        XCTAssertEqual(kind("https://example.com"), .link)
        XCTAssertEqual(kind("http://x"), .link)
        // A trailing newline terminates the single line; it is still a link.
        XCTAssertEqual(kind("https://example.com\n"), .link)
        XCTAssertEqual(kind("https://x\nextra"), .text)
        XCTAssertEqual(kind("  https://x"), .text)
        XCTAssertEqual(kind("not https://x"), .text)
    }

    func testCodeThresholdAndLineShapes() {
        XCTAssertEqual(kind("func f() {\n    x := 1\n}"), .code)
        XCTAssertEqual(kind("    indented"), .code)
        XCTAssertEqual(kind("\titem"), .code)
        // Exactly one third of nonempty lines is enough.
        XCTAssertEqual(kind("key:\nplain\nplain"), .code)
        XCTAssertEqual(kind("x;\ny\nz"), .code)
        XCTAssertEqual(kind("a}\nb\nc"), .code)
        // Just under one third is not.
        XCTAssertEqual(kind("key:\na\nb\nc"), .text)
        // Whitespace-only lines count neither as nonempty nor as code.
        XCTAssertEqual(kind("x\n    \ny"), .text)
    }

    func testFirstMatchingKindWins() {
        // Diff beats error, error beats link.
        XCTAssertEqual(kind("diff --git a b\nerror: inside hunk"), .diff)
        XCTAssertEqual(kind("Traceback\nhttps://example.com"), .error)
    }

    func testLineAndCharacterCounts() {
        let multi = ClipboardSummary("a\nb\nc")
        XCTAssertEqual(multi.lineCount, 3)
        XCTAssertEqual(multi.characterCount, 5)
        // One trailing newline is a terminator, not another line.
        XCTAssertEqual(ClipboardSummary("a\n").lineCount, 1)
        XCTAssertEqual(ClipboardSummary("a\n\n").lineCount, 2)
        let unicode = ClipboardSummary("héllo\nwörld")
        XCTAssertEqual(unicode.lineCount, 2)
        XCTAssertEqual(unicode.characterCount, 11)
    }
}
