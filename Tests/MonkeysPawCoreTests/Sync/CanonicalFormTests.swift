import Foundation
import XCTest
@testable import MonkeysPawCore

final class CanonicalFormTests: XCTestCase {
    private let id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    private let otherID = "01ARZ3NDEKTSV4RRFFQ69G5FAW"

    func testPersonalKeyPresenceAndValuesAreExtractedWithoutDefaults() throws {
        for favorite in [nil, false, true] as [Bool?] {
            for privacy in [nil, false, true] as [Bool?] {
                var lines = ["id: " + id, "title: Shared"]
                if let favorite { lines.append("favorite: \(favorite)") }
                if let privacy { lines.append("private: \(privacy)") }
                let input = Data(("---\n" + lines.joined(separator: "\n") + "\n---\nBody\r\n").utf8)
                let result = try CanonicalForm.group(input, filename: "source.md")
                let expected = Data(("---\nid: " + id + "\ntitle: Shared\n---\nBody\r\n").utf8)
                XCTAssertEqual(result.bytes, expected)
                XCTAssertEqual(result.favorite, favorite)
                XCTAssertEqual(result.warnings.map(\.code), privacy == nil ? [] : [.groupPrivateRemoved])
                XCTAssertTrue(result.warnings.allSatisfy { $0.severity == .warning })
                XCTAssertEqual(result.canonicalHash, SHA256.hexDigest(expected))
                let repeated = try CanonicalForm.group(result.bytes, filename: "source.md")
                XCTAssertEqual(repeated.bytes, result.bytes)
                XCTAssertEqual(repeated.canonicalHash, result.canonicalHash)
                XCTAssertNil(repeated.favorite)
                XCTAssertTrue(repeated.warnings.isEmpty)
            }
        }
    }

    func testPreservesUnknownTypedMetadataNestedPersonalKeysAndOptionalPresence() throws {
        let source = "---\n# comment\nprivate: true\nfavorite: false\nformat: 1\nid: " + id.lowercased()
            + "\nfields:\n  name: {type: text, optional: false, remember: true, extra: null}\n"
            + "tags: []\ndescription: ''\ntitle: 'Shared'\n"
            + "z: {private: true, favorite: false, empty: null, text: 'on', items: [1, 2.5, '010']}\na: []\n---\n{{name}}"
        let result = try CanonicalForm.group(Data(source.utf8), filename: "source.md")
        let expected = "---\nid: " + id + "\ntitle: Shared\ndescription: \"\"\ntags: []\nfields:\n"
            + "  name:\n    type: text\n    optional: false\n    remember: true\n    extra: null\nformat: 1\nz:\n"
            + "  private: true\n  favorite: false\n  empty: null\n  text: \"on\"\n  items:\n  - 1\n  - 2.5\n  - \"010\"\na: []\n---\n{{name}}"
        XCTAssertEqual(result.bytes, Data(expected.utf8))
        XCTAssertEqual(try CanonicalForm.group(result.bytes, filename: "source.md").bytes, result.bytes)
        let document = PromptCodec.parse(String(decoding: result.bytes, as: UTF8.self), filename: "source.md")
        XCTAssertEqual(document.frontMatter.fields.map(\.name), ["name"])
        XCTAssertFalse(document.frontMatter.favorite)
        XCTAssertFalse(document.frontMatter.isPrivate)
        XCTAssertEqual(document.frontMatter.description, "")
        XCTAssertEqual(document.frontMatter.id?.rawValue, id)
    }

    func testExactBodyBytesAcrossLineEndingsUnicodeBOMAndEmptyFiles() throws {
        let bodies = ["", "No final newline", "\r\n\n  indentation\t \r\n\n", "é / e\u{301} / 界 / 🐾\n",
                      "\u{feff}body\n", "\0body\r\n", "---\nBody\n", "literal {{not valid}}\n"]
        for body in bodies {
            let source = Data(("---\r\nfavorite: true\r\nprivate: false\r\n---\r\n" + body).utf8)
            let result = try CanonicalForm.group(source, filename: "source.md")
            XCTAssertEqual(result.bytes, Data(("---\n{}\n---\n" + body).utf8))
            XCTAssertEqual(try CanonicalForm.group(result.bytes, filename: "source.md").bytes, result.bytes)
        }
        for body in ["", "Plain\r\n", "\u{feff}---\nBody\r\n", "\u{feff}body\n", "é", "e\u{301}",
                     "\u{feff}---\nprivate: true\n---\nBody\r\n"] {
            let data = Data(body.utf8)
            let result = try CanonicalForm.group(data, filename: "source.md")
            XCTAssertEqual(result.bytes, data)
            XCTAssertNil(result.favorite)
        }
    }

    func testPrivateStorageStaysVerbatimIncludingBOMCommentsAndPersonalKeys() throws {
        let sources = ["", "\u{feff}body\r\n", "\u{feff}---\nprivate: true\n---\nBody\r\n",
                       "---\r\n# retain this\r\nprivate: true\r\nfavorite: false\r\n"
                       + "id: " + id.lowercased() + "\r\ntitle: 'Shared'\r\nunknown: {nested: [a, b]}\r\n---\r\nBody\r\n"]
        for source in sources {
            let bytes = Data(source.utf8)
            let result = try CanonicalForm.user(bytes, filename: "source.md")
            XCTAssertEqual(result.bytes, bytes)
            XCTAssertEqual(result.canonicalHash, SHA256.hexDigest(bytes))
            XCTAssertNil(result.favorite)
            XCTAssertTrue(result.warnings.isEmpty)
        }
    }

    func testExistingValidationWarningsRemainNonblockingAndPrivateWarningHasALocation() throws {
        let data = Data("---\nprivate: false\nfields:\n  unused: {}\n---\n{{not valid}}".utf8)
        let result = try CanonicalForm.group(data, filename: "source.md")
        XCTAssertEqual(result.warnings.map(\.code), [.invalidPlaceholder, .unusedField, .groupPrivateRemoved])
        XCTAssertEqual(result.warnings.last?.location, .frontMatter(line: 2, column: 10))
        XCTAssertEqual(try CanonicalForm.user(data, filename: "source.md").warnings.map(\.code),
                       [.invalidPlaceholder, .unusedField])
    }

    func testInvalidPersonalKeysCannotBeHiddenByStrippingAndInvalidContentFailsClosed() {
        let sources = ["---\nfavorite: 'true'\n---\nBody", "---\nprivate: 'false'\n---\nBody",
                       "---\nprivate: on\n---\nBody", "---\nprivate: true\nprivate: false\n---\nBody",
                       "---\nid: invalid\n---\nBody", "---\nunknown: &anchor [a]\n---\nBody",
                       "---\nunknown: {nested: on}\n---\nBody", "---\n[broken\n---\nBody",
                       "---\nprivate: true\nBody", "Body {{unclosed"]
        let inputs = sources.map { Data($0.utf8) } + [Data([0xff]), Data([0xc0, 0xaf])]
        for input in inputs {
            XCTAssertThrowsError(try CanonicalForm.group(input, filename: "source.md")) {
                XCTAssertEqual($0 as? PromptWriteError, .invalidPrompt)
            }
            XCTAssertThrowsError(try CanonicalForm.user(input, filename: "source.md")) {
                XCTAssertEqual($0 as? PromptWriteError, .invalidPrompt)
            }
            for scope in [CanonicalForm.Scope.user, .group] {
                XCTAssertThrowsError(try CanonicalForm.equivalentForAdoption(input, input, scope: scope, filename: "source.md"))
                XCTAssertThrowsError(try CanonicalForm.equivalentForAdoption(Data("Body".utf8), input,
                                                                            scope: scope, filename: "source.md"))
            }
        }
    }

    func testFutureFormatsRemainUnsupportedBeforeStripping() {
        for version in ["2", "999999999999999999999999999999999999"] {
            let input = Data(("---\nformat: " + version + "\nprivate: true\nfavorite: true\n---\nBody").utf8)
            let error = PromptWriteError.unsupportedFormat(PromptFormatVersion(decimalValue: version)!)
            XCTAssertThrowsError(try CanonicalForm.group(input, filename: "source.md")) {
                XCTAssertEqual($0 as? PromptWriteError, error)
            }
            XCTAssertThrowsError(try CanonicalForm.user(input, filename: "source.md")) {
                XCTAssertEqual($0 as? PromptWriteError, error)
            }
            XCTAssertThrowsError(try CanonicalForm.equivalentForAdoption(input, input, scope: .group, filename: "source.md")) {
                XCTAssertEqual($0 as? PromptWriteError, error)
            }
        }
    }

    func testSourceLimitAndCanonicalExpansionAreCheckedAtTheResponsibleBoundary() throws {
        let exact = Data(repeating: 0x61, count: Limits.maxPromptBytes)
        XCTAssertEqual(try CanonicalForm.group(exact, filename: "source.md").bytes, exact)
        XCTAssertEqual(try CanonicalForm.user(exact, filename: "source.md").bytes, exact)
        let oversized = exact + Data([0x61])
        XCTAssertThrowsError(try CanonicalForm.group(oversized, filename: "source.md")) {
            XCTAssertEqual($0 as? PromptWriteError, .invalidPrompt)
        }
        XCTAssertThrowsError(try CanonicalForm.user(oversized, filename: "source.md"))

        let header = "---\nx: [a, b, c]\n---\n"
        let expansion = Data((header + String(repeating: "a", count: Limits.maxPromptBytes - header.utf8.count)).utf8)
        XCTAssertEqual(try CanonicalForm.user(expansion, filename: "source.md").bytes, expansion)
        XCTAssertThrowsError(try CanonicalForm.group(expansion, filename: "source.md")) {
            XCTAssertEqual($0 as? PromptWriteError, .sourceTooLarge)
        }
        let personal = "---\nfavorite: true\nprivate: true\nx: [a, b, c]\n---\n"
        let shrinks = Data((personal + String(repeating: "a", count: Limits.maxPromptBytes - personal.utf8.count)).utf8)
        XCTAssertThrowsError(try PromptCodec.write(PromptCodec.parseFile(shrinks, filename: "source.md")))
        XCTAssertLessThan(try CanonicalForm.group(shrinks, filename: "source.md").bytes.count, Limits.maxPromptBytes)
    }

    func testAdoptionIgnoresIDAndCanonicalPresentationButStoredHashesIncludeID() throws {
        let local = Data("---\n# comment\ntitle: 'Shared'\nfavorite: true\nprivate: true\n---\nBody\r\n".utf8)
        let server = Data(("---\nid: " + id + "\ntitle: Shared\n---\nBody\r\n").utf8)
        let other = Data(("---\nid: " + otherID + "\ntitle: Shared\n---\nBody\r\n").utf8)
        XCTAssertTrue(try CanonicalForm.equivalentForAdoption(local, server, scope: .group, filename: "source.md"))
        XCTAssertTrue(try CanonicalForm.equivalentForAdoption(server, local, scope: .group, filename: "source.md"))
        XCTAssertTrue(try CanonicalForm.equivalentForAdoption(server, other, scope: .group, filename: "source.md"))
        XCTAssertFalse(try CanonicalForm.equivalentForAdoption(local, server, scope: .user, filename: "source.md"))
        XCTAssertNotEqual(try CanonicalForm.group(server, filename: "source.md").canonicalHash,
                          try CanonicalForm.group(other, filename: "source.md").canonicalHash)
        let privateServer = Data(("---\nid: " + id + "\nfavorite: true\nprivate: true\ntitle: Shared\n---\nBody\r\n").utf8)
        XCTAssertTrue(try CanonicalForm.equivalentForAdoption(local, privateServer, scope: .user, filename: "source.md"))
        XCTAssertNotEqual(try CanonicalForm.user(local, filename: "source.md").canonicalHash,
                          try CanonicalForm.user(privateServer, filename: "source.md").canonicalHash)
    }

    func testAdoptionMatchesPlainIdlessFilesWithIDOnlyOrEmptyHeaders() throws {
        let plain = Data("Body\r\n".utf8)
        for header in ["id: " + id, "{}", "# empty", "id: " + id + "\nfavorite: false\nprivate: false"] {
            let input = Data(("---\n" + header + "\n---\nBody\r\n").utf8)
            XCTAssertTrue(try CanonicalForm.equivalentForAdoption(plain, input, scope: .group, filename: "source.md"))
        }
        let idOnly = Data(("---\nid: " + id + "\n---\nBody\r\n").utf8)
        XCTAssertTrue(try CanonicalForm.equivalentForAdoption(plain, idOnly, scope: .user, filename: "different.md"))
    }

    func testAdoptionRetainsBodyBytesMetadataValuesAndKeyPresence() throws {
        let base = Data(("---\nid: " + id + "\ntitle: Shared\nunknown: {value: a}\n---\né\r\n").utf8)
        for source in ["---\ntitle: Changed\nunknown: {value: a}\n---\né\r\n",
                       "---\ntitle: Shared\nunknown: {value: b}\n---\né\r\n",
                       "---\ntitle: Shared\ndescription: ''\nunknown: {value: a}\n---\né\r\n",
                       "---\ntitle: Shared\nunknown: {value: a}\n---\ne\u{301}\r\n",
                       "---\ntitle: Shared\nunknown: {value: a}\n---\né\n"] {
            for scope in [CanonicalForm.Scope.user, .group] {
                XCTAssertFalse(try CanonicalForm.equivalentForAdoption(base, Data(source.utf8), scope: scope, filename: "source.md"))
            }
        }
        let composed = try CanonicalForm.group(Data("é".utf8), filename: "source.md")
        let decomposed = try CanonicalForm.group(Data("e\u{301}".utf8), filename: "source.md")
        XCTAssertNotEqual(composed.canonicalHash, decomposed.canonicalHash)
    }

    func testAdoptionCannotConfuseBodyFrontMatterWithMetadataAfterRemovingID() throws {
        let local = Data("---\ntitle: Shared\n---\nBody\n".utf8)
        let server = Data(("---\nid: " + id + "\n---\n---\ntitle: Shared\n---\nBody\n").utf8)
        for scope in [CanonicalForm.Scope.user, .group] {
            XCTAssertFalse(try CanonicalForm.equivalentForAdoption(local, server, scope: scope, filename: "source.md"))
            XCTAssertFalse(try CanonicalForm.equivalentForAdoption(server, local, scope: scope, filename: "source.md"))
        }
    }
}
