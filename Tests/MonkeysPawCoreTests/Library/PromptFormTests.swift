import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptFormTests: XCTestCase {
    func testBodyOnlyEditPreservesExactHeaderAndBodyBytes() throws {
        let header = "---\r\n# Keep this comment\r\ntitle: 'A title'\r\nname: custom-name\r\n---\r\n"
        let document = PromptCodec.parse(header + "Original", filename: "a.md")
        let body = "  {{topic}}\r\n👋 e\u{301}\n\n"
        let updated = try PromptCodec.editing(.body(body), in: document, filename: "a.md")
        XCTAssertEqual(Data(updated.source.utf8), Data((header + body).utf8))
        XCTAssertEqual(Data(updated.body.utf8), Data(body.utf8))
        XCTAssertNotNil(PromptForm(updated))
    }

    func testPropertiesPreserveIdentityDeclarationsAndUnknownMetadata() throws {
        let original = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\ntitle: Old\nfavorite: true\nfields:\n  topic:\n    type: choice\n    options:\n    - {label: Earth, value: earth, custom: keep}\n    default: earth\n    hint: retained\nname: custom-name\nmodel: {family: custom, enabled: true}\n---\n  Hi {{topic}}\r\n\n"
        var document = PromptCodec.parse(original, filename: "a.md")
        let identity = document.frontMatter.id
        let fields = document.frontMatter.fields
        for edit: PromptEdit in [.title("Title: {{literal}}"), .description("A \"quoted\" summary"),
                                  .tags(["code, review", "é", "e\u{301}"]), .isPrivate(true)] {
            document = try PromptCodec.editing(edit, in: document, filename: "a.md")
        }
        XCTAssertEqual(document.frontMatter.id, identity)
        XCTAssertEqual(document.frontMatter.fields, fields)
        XCTAssertTrue(document.frontMatter.favorite)
        XCTAssertTrue(document.frontMatter.isPrivate)
        XCTAssertEqual(document.frontMatter.title, "Title: {{literal}}")
        XCTAssertEqual(document.frontMatter.description, "A \"quoted\" summary")
        XCTAssertEqual(document.frontMatter.tags.map { Data($0.utf8) },
            ["code, review", "é", "e\u{301}"].map { Data($0.utf8) })
        XCTAssertEqual(Data(document.body.utf8), Data("  Hi {{topic}}\r\n\n".utf8))
        for retained in ["name: custom-name", "custom: keep", "hint: retained", "family: custom", "enabled: true"] {
            XCTAssertTrue(document.source.contains(retained), retained)
        }
        XCTAssertFalse(document.source.contains("format:"), "Absent optional keys stay absent")
    }

    func testUnbalancedBodyRemainsEditableWithoutWeakeningSaveValidation() throws {
        var document = PromptCodec.parse("Original", filename: "a.md")
        document = try PromptCodec.editing(.body("{{topic"), in: document, filename: "a.md")
        XCTAssertNotNil(PromptForm(document))
        document = try PromptCodec.editing(.title("Draft"), in: document, filename: "a.md")
        XCTAssertEqual(document.body, "{{topic")
        XCTAssertEqual(document.issues.map(\.code), [.unbalancedOpener])
        XCTAssertThrowsError(try PromptCodec.write(document))
        document = try PromptCodec.editing(.body("Hello {{topic}}"), in: document, filename: "a.md")
        XCTAssertTrue(document.canRender)
        XCTAssertEqual(document.frontMatter.title, "Draft")
    }

    func testDelimiterBodiesAndHeaderEndingAtEOFAreNotReinterpreted() throws {
        for body in ["---", "---\nbody: literal\n---\nText", "---\r\nLiteral"] {
            let plain = PromptCodec.parse("Original", filename: "a.md")
            let updated = try PromptCodec.editing(.body(body), in: plain, filename: "a.md")
            XCTAssertEqual(Data(updated.body.utf8), Data(body.utf8))
            XCTAssertTrue(updated.canRender)
            let roundTrip = PromptCodec.parse(try PromptCodec.write(updated), filename: "a.md")
            XCTAssertEqual(Data(roundTrip.body.utf8), Data(body.utf8))
        }
        let noTerminator = PromptCodec.parse("---\ntitle: Title\n---", filename: "a.md")
        let updated = try PromptCodec.editing(.body("Text"), in: noTerminator, filename: "a.md")
        XCTAssertEqual(updated.body, "Text")
        XCTAssertEqual(updated.frontMatter.title, "Title")
    }

    func testNoOpEditsNeverNormalizeSourceOrMaterializeMissingKeys() throws {
        for source in ["Plain\r\n", "---\n# comment\ntitle: 'a'\n---\nPlain\r\n"] {
            let document = PromptCodec.parse(source, filename: "a.md")
            let form = try XCTUnwrap(PromptForm(document))
            for edit: PromptEdit in [.title(form.title), .description(form.description), .tags(form.tags),
                                      .isPrivate(form.isPrivate), .body(form.body)] {
                let updated = try PromptCodec.editing(edit, in: document, filename: "a.md")
                XCTAssertEqual(Data(updated.source.utf8), Data(source.utf8))
            }
        }
    }

    func testMalformedAndFutureHeadersNeverBecomeEditableForms() {
        for source in ["---\ntitle: [broken\n---\nBody", "---\ntitle: Missing closure", "---\nformat: 2\n---\nBody",
                       "---\nprivate: yes\n---\nBody", "---\nmodel: &shared {a: x}\ncopy: *shared\n---\nBody"] {
            let document = PromptCodec.parse(source, filename: "a.md")
            XCTAssertNil(PromptForm(document))
            XCTAssertThrowsError(try PromptCodec.editing(.title("Changed"), in: document, filename: "a.md"))
        }
    }

    func testFormAndSourceShareDirtyGuardSaveAndHistory() throws {
        let e = EditorHarness()
        let source = "---\ntitle: Old\ncustom: keep\n---\nOriginal"
        try e.open(source)
        XCTAssertEqual(e.model.state.form?.title, "Old")
        e.ui { e.model.edit(.title("New")); e.model.edit(.body("Draft")) }
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertEqual(try e.h.files.text(at: "a.md"), source)
        e.ui { e.model.request(.close) }
        XCTAssertNotNil(e.model.state.pendingDecision)
        try e.decide(.cancel)
        XCTAssertEqual(e.model.state.form?.body, "Draft")
        e.ui { e.model.save() }
        e.settle()
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertEqual(e.model.state.status, .saved)
        XCTAssertEqual(e.model.state.form?.title, "New")
        XCTAssertEqual(e.model.state.form?.body, "Draft")
        XCTAssertTrue(try XCTUnwrap(e.model.state.source).contains("custom: keep"))
        let identity = try XCTUnwrap(e.model.state.prompt?.identity)
        XCTAssertEqual(try e.h.library.history(for: identity).count, 1)
        e.ui { e.model.edit("---\ntitle: Source title\n---\nSource body") }
        XCTAssertEqual(e.model.state.form?.title, "Source title")
        XCTAssertEqual(e.model.state.form?.body, "Source body")
        e.ui { e.model.edit("---\ntitle: [broken\n---\nDraft") }
        XCTAssertNil(e.model.state.form)
        let before = e.model.state
        e.ui { e.model.edit(.body("Do not overwrite invalid source")) }
        XCTAssertEqual(e.model.state, before)
    }
}
