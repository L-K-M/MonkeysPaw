import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncPathValidatorTests: XCTestCase {
    func testValidNamesRemainAvailableInBothScopes() throws {
        let paths = ["a.md", ".md", ".hidden.md", "Conflicts/Personal/a.md", "a..b/x.md",
                     " Notes/a.md", "Topic: one/a.md", "a\u{00A0}/b.md", "a／b.md",
                     "%2e%2e/a.md", "Folder/\u{301}/x.md", "Folder/.hidden.md"]
        for scope in [SyncPathValidator.Scope.user, .group] {
            for path in paths {
                let result = try SyncPathValidator.validate(path, scope: scope)
                XCTAssertEqual(Data(result.path.utf8), Data(path.precomposedStringWithCanonicalMapping.utf8))
            }
        }
    }

    func testRejectsEmptyAbsoluteAndTraversalPaths() {
        assertIssue("", .emptyPath)
        for path in ["/a.md", "//a.md", "/\u{301}a.md"] { assertIssue(path, .absolutePath) }
        for (path, index) in [("a//b.md", 1), ("a.md/", 1), ("a//\u{301}b.md", 1)] {
            assertIssue(path, .emptySegment, segment: index)
        }
        for (path, index) in [("./a.md", 0), ("../a.md", 0), ("a/./b.md", 1),
                              ("a/../b.md", 1), ("a/\u{301}/../b.md", 2)] {
            assertIssue(path, .dotSegment, segment: index)
        }
    }

    func testRejectsDotPrefixedDirectoriesInBothScopes() {
        for (path, index) in [(".hidden/a.md", 0), (".git/a.md", 0), ("a/.hidden/b.md", 1),
                              (".\u{301}/x.md", 0), ("a/.\u{301}/.hidden.md", 1)] {
            XCTAssertFalse(LibraryPath.isPrompt(path))
            for scope in [SyncPathValidator.Scope.user, .group] {
                XCTAssertThrowsError(try SyncPathValidator.validate(path, scope: scope), path) {
                    guard let issue = $0 as? SyncPathIssue else { return XCTFail("Expected a typed path issue.") }
                    XCTAssertEqual(issue.code.rawValue, "path.segment_hidden")
                    XCTAssertEqual(issue.segmentIndex, index)
                }
            }
        }
        for path in [".md", ".hidden.md", "a/.hidden.md"] {
            XCTAssertTrue(LibraryPath.isPrompt(path))
        }
    }

    func testRejectsBackslashesIncludingWindowsSpellings() {
        for path in ["a\\b.md", "C:\\a.md", "\\\\server\\a.md"] { assertIssue(path, .backslash, segment: 0) }
        assertIssue("a/b\\c.md", .backslash, segment: 1)
    }

    func testRejectsEveryC0AndC1ControlIncludingNULAndDEL() {
        for value in Array(0...31) + Array(127...159) {
            let scalar = Unicode.Scalar(value)!
            assertIssue("a/one" + String(scalar) + ".md", .controlCharacter, segment: 1)
        }
    }

    func testRejectsUnicodeFormatControls() {
        for value in [0x00AD, 0x061C, 0x200B, 0x200D, 0x200E, 0x202E, 0x2060, 0xFEFF, 0xE0001] {
            assertIssue(String(Unicode.Scalar(value)!) + "a.md", .controlCharacter, segment: 0)
        }
    }

    func testRejectsTrailingASCIIPathPunctuationInEverySegment() {
        for (path, index) in [("a./b.md", 0), ("a /b.md", 0), ("a/b./c.md", 1),
                              ("a/b /c.md", 1), ("a.md.", 0), ("a.md ", 0)] {
            assertIssue(path, .trailingDotOrSpace, segment: index)
        }
    }

    func testRequiresExactLowercaseSuffixBeforeFolding() {
        for path in ["a", "a.MD", "a.Md", "a.mD", "a.md.txt", "a.md/x", "a.md\u{301}", "a.mＤ"] {
            assertIssue(path, .invalidExtension)
        }
    }

    func testEverySegmentBoundaryCountsUTF8IncludingTheSuffix() throws {
        XCTAssertEqual(Limits.syncPathSegmentMaxBytes, 255)
        for size in [254, 255, 256] {
            let directory = String(repeating: "a", count: size) + "/x.md"
            let filename = String(repeating: "a", count: size - 3) + ".md"
            if size <= 255 {
                _ = try SyncPathValidator.validate(directory, scope: .user)
                _ = try SyncPathValidator.validate(filename, scope: .user)
            } else {
                assertIssue(directory, .segmentTooLong, segment: 0)
                assertIssue(filename, .segmentTooLong, segment: 0)
            }
        }
        let multibyte = String(repeating: "😀", count: 63)
        _ = try SyncPathValidator.validate(multibyte + ".md", scope: .user)
        assertIssue(multibyte + "a.md", .segmentTooLong, segment: 0)
        assertIssue("a/" + String(repeating: "é", count: 128) + "/x.md", .segmentTooLong, segment: 1)
    }

    func testWholePathBoundaryIncludesSlashBytes() throws {
        XCTAssertEqual(Limits.maxPathBytes, 1_024)
        // Count slash bytes while keeping every segment within its own limit.
        let prefix = String(repeating: String(repeating: "a", count: 255) + "/", count: 3)
        for size in [1_023, 1_024, 1_025] {
            let path = prefix + "b/" + String(repeating: "x", count: size - prefix.utf8.count - 5) + ".md"
            XCTAssertEqual(path.utf8.count, size)
            if size <= 1_024 {
                _ = try SyncPathValidator.validate(path, scope: .user)
            } else {
                assertIssue(path, .pathTooLong)
            }
        }
    }

    func testLimitsApplyAfterNFCCompositionAndExpansion() throws {
        let nfd = String(repeating: "e\u{301}", count: 126) + ".md"
        XCTAssertGreaterThan(nfd.utf8.count, 255)
        let result = try SyncPathValidator.validate(nfd, scope: .user)
        XCTAssertEqual(result.path.utf8.count, 255)
        // U+0344 is excluded from composition: its NFC is two marks.
        _ = try SyncPathValidator.validate(String(repeating: "\u{344}", count: 63) + ".md", scope: .user)
        assertIssue(String(repeating: "\u{344}", count: 64) + ".md", .segmentTooLong, segment: 0)

        let prefix = String(repeating: String(repeating: "e\u{301}", count: 127) + "/", count: 3)
        let path = prefix + "bbb/" + String(repeating: "e\u{301}", count: 126) + ".md"
        XCTAssertGreaterThan(path.utf8.count, 1_024)
        XCTAssertEqual(try SyncPathValidator.validate(path, scope: .user).path.utf8.count, 1_024)
    }

    func testSlashAdjacentCombiningScalarsKeepTheirSegment() throws {
        let result = try SyncPathValidator.validate("Cafe\u{301}/\u{301}A.md", scope: .user)
        XCTAssertEqual(Data(result.path.utf8), Data("Café/\u{301}A.md".utf8))
        XCTAssertEqual(Data(result.pathKey.utf8), Data("café/\u{301}a.md".utf8))
        assertIssue("a/\u{301}/bad./x.md", .trailingDotOrSpace, segment: 2)
    }

    func testFullFoldingAndCanonicalKeys() throws {
        let cases = [("Café/É.md", "café/é.md"), ("Cafe\u{301}/E\u{301}.md", "café/é.md"),
                     ("Straße/ẞ.md", "strasse/ss.md"), ("Σ/ςσ.md", "σ/σσ.md"),
                     ("İ/Iıi.md", "i\u{307}/iıi.md"), ("ﬃ/K.md", "ffi/k.md"),
                     ("\u{1F80}.md", "ἀι.md"), ("J\u{30C}.md", "ǰ.md")]
        for (path, key) in cases {
            let result = try SyncPathValidator.validate(path, scope: .user)
            XCTAssertEqual(Data(result.pathKey.utf8), Data(key.utf8), path)
            XCTAssertEqual(Data(result.path.utf8), Data(path.precomposedStringWithCanonicalMapping.utf8))
            let repeated = try SyncPathValidator.validate(result.path, scope: .user)
            XCTAssertEqual(repeated, result)
            let folded = try SyncPathValidator.validate(result.pathKey, scope: .user)
            XCTAssertEqual(Data(folded.pathKey.utf8), Data(result.pathKey.utf8))
        }
        let dotted = try SyncPathValidator.validate("İ.md", scope: .user)
        let ascii = try SyncPathValidator.validate("i.md", scope: .user)
        XCTAssertNotEqual(Data(dotted.pathKey.utf8), Data(ascii.pathKey.utf8))
        XCTAssertNotEqual(try SyncPathValidator.validate("é.md", scope: .user).pathKey,
                          try SyncPathValidator.validate("e.md", scope: .user).pathKey)
        XCTAssertNotEqual(try SyncPathValidator.validate("Ａ.md", scope: .user).pathKey,
                          try SyncPathValidator.validate("a.md", scope: .user).pathKey)
    }

    func testFoldExpansionDoesNotImposeAnExtraKeyLimit() throws {
        let segment = String(repeating: "İ", count: 127)
        let path = String(repeating: segment + "/", count: 3) + "bbb/" + String(repeating: "İ", count: 126) + ".md"
        XCTAssertEqual(path.utf8.count, 1_024)
        let result = try SyncPathValidator.validate(path, scope: .user)
        XCTAssertGreaterThan(result.pathKey.utf8.count, Limits.maxPathBytes)
        XCTAssertEqual(Data(result.pathKey.utf8),
                       Data((String(repeating: String(repeating: "i\u{307}", count: 127) + "/", count: 3)
                             + "bbb/" + String(repeating: "i\u{307}", count: 126) + ".md").utf8))
    }

    func testDefaultUnicodeFullFoldIncludesCherokeeAndRecentMappings() throws {
        for (path, key) in [("ꭰ.md", "Ꭰ.md"), ("Ꭰ.md", "Ꭰ.md"),
                            ("\u{1C80}.md", "в.md"), ("\u{A7CB}.md", "\u{264}.md"),
                            ("\u{10D50}.md", "\u{10D70}.md")] {
            XCTAssertEqual(Data(try SyncPathValidator.validate(path, scope: .user).pathKey.utf8), Data(key.utf8))
        }
    }

    func testNFCPreservesAndOrdersLongCombiningRuns() throws {
        let input = String(repeating: "\u{0F73}", count: 20) + ".md"
        let expected = String(repeating: "\u{0F71}", count: 20) + String(repeating: "\u{0F72}", count: 20) + ".md"
        let result = try SyncPathValidator.validate(input, scope: .user)
        XCTAssertEqual(Data(result.path.utf8), Data(expected.utf8))
        XCTAssertEqual(Data(result.pathKey.utf8), Data(expected.utf8))
    }

    func testGroupsPrefixUsesFoldedBytesAndOnlyPrivateScope() throws {
        for path in ["Groups/a.md", "groups/a.md", "GROUPS/a.md", "gRoUpS/a.md",
                     "Groupſ/a.md", "Groups/\u{301}a.md"] {
            assertIssue(path, .reservedGroupsPrefix)
            _ = try SyncPathValidator.validate(path, scope: .group)
        }
        for path in ["Groups.md", "GroupsExtra/a.md", "Other/Groups/a.md", "Gróups/a.md", "Gro\u{301}ups/a.md",
                     "Conflicts/a.md", "CONFLICTS/Groups/a.md", "Ｇroups/a.md"] {
            _ = try SyncPathValidator.validate(path, scope: .user)
        }
    }

    func testDiagnosticsHaveStablePrecedenceAndDoNotRetainThePath() {
        assertIssue("/a\\.MD", .absolutePath)
        assertIssue(String(repeating: "a", count: 1_025), .pathTooLong)
        assertIssue("../a\\.MD", .dotSegment, segment: 0)
        assertIssue(".hidden/a\\.MD", .hiddenDirectory, segment: 0)
        assertIssue("a\\\u{0}.MD", .backslash, segment: 0)
        assertIssue("a\u{0}.MD ", .controlCharacter, segment: 0)
        assertIssue("Groups/a.MD", .invalidExtension)
        XCTAssertThrowsError(try SyncPathValidator.validate("private-name.MD", scope: .user)) {
            guard let issue = $0 as? SyncPathIssue else { return XCTFail("Expected a typed path issue.") }
            XCTAssertEqual(issue.code.rawValue, "path.invalid_extension")
            XCTAssertNil(issue.segmentIndex)
            XCTAssertFalse(issue.message.contains("private-name"))
            XCTAssertEqual(issue.description, issue.message)
        }
    }

    func testLocalValidationAndByteIdentityStayIndependent() throws {
        let nfc = "é.md"
        let nfd = "e\u{301}.md"
        try FileStorePath.validate(nfc)
        try FileStorePath.validate(nfd)
        XCTAssertNotEqual(RelativePath(nfc), RelativePath(nfd))
        XCTAssertEqual(Set([RelativePath(nfc), RelativePath(nfd)]).count, 2)
        XCTAssertEqual(try SyncPathValidator.validate(nfc, scope: .user),
                       try SyncPathValidator.validate(nfd, scope: .user))
        for path in ["Groups/a.md", "a.MD", ".hidden/a.md", "a./b.md", "a /b.md", String(repeating: "a", count: 256) + ".md"] {
            XCTAssertNoThrow(try FileStorePath.validate(path))
            XCTAssertThrowsError(try SyncPathValidator.validate(path, scope: .user))
        }
    }

    private func assertIssue(_ path: String, _ code: SyncPathIssueCode, segment: Int? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        let scopes: [SyncPathValidator.Scope] = code == .reservedGroupsPrefix ? [.user] : [.user, .group]
        for scope in scopes {
            XCTAssertThrowsError(try SyncPathValidator.validate(path, scope: scope), file: file, line: line) {
                guard let issue = $0 as? SyncPathIssue else {
                    return XCTFail("Expected a typed path issue.", file: file, line: line)
                }
                XCTAssertEqual(issue.code, code, file: file, line: line)
                XCTAssertEqual(issue.segmentIndex, segment, file: file, line: line)
            }
        }
    }
}
