import XCTest
import Yams
@testable import MonkeysPawCore

final class PromptIdentityRemovalTests: XCTestCase {
    func testRemovingIdentityKeepsAnAbsentHeaderAbsent() throws {
        let body = "Body\r\n"
        let document = PromptDocument(source: body, body: body,
                                      frontMatter: FrontMatter(id: ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!, title: "Title"),
                                      template: Template.parse(body))
        let copy = try PromptCodec.removingIdentity(from: document)
        XCTAssertNil(copy.frontMatter.id)
        XCTAssertNil(copy.preservedHeader)
        XCTAssertEqual(try PromptCodec.write(copy), body)
    }

    func testRemovingIdentityDropsOnlyIDFromAnExistingHeader() throws {
        let document = PromptCodec.parse("---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\ntitle: Title\nunknown: {nested: [a, b]}\n---\nBody\r\n",
                                         filename: "a.md")
        let copy = try PromptCodec.removingIdentity(from: document)
        XCTAssertNil(copy.frontMatter.id)
        XCTAssertNotNil(copy.preservedHeader)
        XCTAssertEqual(copy.body, document.body)
        XCTAssertEqual(copy.frontMatter.title, "Title")
        XCTAssertEqual(try PromptCodec.write(copy), "---\ntitle: Title\nunknown:\n  nested:\n  - a\n  - b\n---\nBody\r\n")
    }

    func testEmptyPreservedMappingWritesAnExplicitYAMLHeader() throws {
        let document = PromptDocument(source: "Body", body: "Body", frontMatter: FrontMatter(title: "Title"),
                                      template: Template.parse("Body"), preservedHeader: Node([(Node, Node)](), Tag(.map), .block))
        XCTAssertEqual(try PromptCodec.write(document), "---\n{}\n---\nBody")
    }

    func testCopyStillRejectsInvalidDocumentsWithAndWithoutIdentity() throws {
        let h = PromptEditingHarness()
        let invalid = PromptCodec.parse("---\ntitle: [broken\n---\nBody", filename: "a.md")
        for id in [nil, ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")] {
            let document = PromptDocument(source: invalid.source, body: invalid.body,
                                          frontMatter: FrontMatter(id: id, title: "Title"),
                                          template: invalid.template, decodingIssues: invalid.decodingIssues)
            XCTAssertThrowsError(try h.library.createCopyForEditing(document, near: "copy.md")) {
                XCTAssertEqual($0 as? PromptWriteError, .invalidPrompt)
            }
        }
        XCTAssertEqual(h.files.accessCount, 0)
        XCTAssertTrue(h.entropy.requests.isEmpty)
    }
}
