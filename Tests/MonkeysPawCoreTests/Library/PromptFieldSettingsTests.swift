import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptFieldSettingsTests: XCTestCase {
    private func settings(_ document: PromptDocument, name: String = "topic") throws -> PromptFieldSettings {
        try XCTUnwrap(PromptForm(document)?.fieldSettings.first { $0.name == name })
    }

    func testProjectionIncludesImplicitAndUnusedFieldsButNotBuiltinsWithoutDirtyingSource() throws {
        let source = "---\n# keep\nfields:\n  unused: {}\n---\n{{topic}} {{date}} {{topic}} {{clipboard}} {{time}}\r\n"
        let document = PromptCodec.parse(source, filename: "a.md")
        XCTAssertEqual(PromptForm(document)?.fieldSettings.map(\.name), ["topic", "unused"])
        let draft = try settings(document)
        XCTAssertTrue(draft.isImplicit)
        XCTAssertNil(draft.defaultValue)
        XCTAssertEqual(Data(try PromptCodec.editing(.field(draft), in: document, filename: "a.md").source.utf8), Data(source.utf8))
    }

    func testImplicitSettingsBecomeADeclarationAndDriveRendering() throws {
        let document = PromptCodec.parse("{{topic}} / {{topic}}\r\n", filename: "a.md")
        var draft = try settings(document)
        draft.kind = .choice
        draft.label = "A topic"
        draft.description = "Pick one"
        draft.defaultValue = "earth"
        draft.options = [PromptFieldOptionSettings(label: "Earth", value: "earth"),
                         PromptFieldOptionSettings(label: "Literal", value: "{{other}}")]
        draft.optional = true
        draft.remember = false
        let changed = try PromptCodec.editing(.field(draft), in: document, filename: "a.md")
        XCTAssertTrue(changed.canRender)
        XCTAssertEqual(changed.frontMatter.fields.count, 1)
        let field = try XCTUnwrap(changed.effectiveFields.first)
        XCTAssertFalse(field.isImplicit)
        XCTAssertTrue(field.optional)
        XCTAssertFalse(field.remember)
        XCTAssertEqual(field.label, "A topic")
        XCTAssertEqual(field.description, "Pick one")
        XCTAssertEqual(Data(changed.body.utf8), Data(document.body.utf8))
        XCTAssertEqual(try PromptRenderer.render(changed, values: [:]), "earth / earth\r\n")
        XCTAssertEqual(try PromptRenderer.render(changed, values: ["topic": "{{other}}"]), "{{other}} / {{other}}\r\n")
    }

    func testChangedPropertiesKeepHeaderIdentityOtherDeclarationsAndOptionMetadata() throws {
        let source = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\nprivate: true\nfields:\n  topic:\n    type: choice\n    hint: keep-field\n    options:\n    - {label: A, value: a, custom: keep-a}\n    - {label: B, value: b, custom: keep-b}\n    default: b\n  other: {label: Other, custom: keep-other}\nmodel: {provider: custom}\n---\n  {{topic}} {{other}} 👋 e\u{301}\r\n"
        let document = PromptCodec.parse(source, filename: "a.md")
        var draft = try settings(document)
        draft.options.removeFirst()
        draft.options[0].label = "Bee"
        draft.options[0].value = "beta"
        draft.defaultValue = "beta"
        draft.remember = false
        let changed = try PromptCodec.editing(.field(draft), in: document, filename: "a.md")
        XCTAssertEqual(changed.frontMatter.id, document.frontMatter.id)
        XCTAssertTrue(changed.frontMatter.isPrivate)
        XCTAssertEqual(changed.frontMatter.fields.last, document.frontMatter.fields.last)
        XCTAssertEqual(Data(changed.body.utf8), Data(document.body.utf8))
        for text in ["hint: keep-field", "custom: keep-b", "custom: keep-other", "provider: custom"] {
            XCTAssertTrue(changed.source.contains(text), text)
        }
        XCTAssertFalse(changed.source.contains("keep-a"))
        XCTAssertFalse(changed.source.contains("optional:"))
        XCTAssertFalse(changed.source.contains("label: topic"))
        XCTAssertEqual(changed.effectiveFields.first?.options, [FieldOption(label: "Bee", value: "beta")])
    }

    func testChoiceValidationDefaultPresenceAndTypeChange() throws {
        let document = PromptCodec.parse("{{topic}}", filename: "a.md")
        var draft = try settings(document)
        draft.kind = .choice
        XCTAssertEqual(draft.validationIssue, .missingOptions)
        XCTAssertThrowsError(try PromptCodec.editing(.field(draft), in: document, filename: "a.md"))
        draft.options = [PromptFieldOptionSettings(label: "Empty", value: "")]
        draft.defaultValue = "no match"
        XCTAssertEqual(draft.validationIssue, .invalidDefault)
        XCTAssertThrowsError(try PromptCodec.editing(.field(draft), in: document, filename: "a.md"))
        draft.defaultValue = ""
        XCTAssertNil(draft.validationIssue)
        let choice = try PromptCodec.editing(.field(draft), in: document, filename: "a.md")
        XCTAssertEqual(try settings(choice).defaultValue, "")
        draft = try settings(choice)
        draft.defaultValue = nil
        let noDefault = try PromptCodec.editing(.field(draft), in: choice, filename: "a.md")
        XCTAssertFalse(noDefault.source.contains("default:"))
        draft = try settings(noDefault)
        draft.kind = .multiline
        draft.defaultValue = "First\nSecond"
        let multiline = try PromptCodec.editing(.field(draft), in: noDefault, filename: "a.md")
        XCTAssertEqual(multiline.effectiveFields.first?.kind, .multiline)
        XCTAssertEqual(multiline.effectiveFields.first?.defaultValue, "First\nSecond")
        XCTAssertFalse(multiline.source.contains("options:"))
    }

    func testIncompleteBodyStaysRepairableWhileBadHeadersAndUnknownFieldsFailClosed() throws {
        let valid = PromptCodec.parse("{{topic}}", filename: "a.md")
        var draft = try settings(valid)
        draft.label = "Topic"
        let incomplete = PromptCodec.parse("{{topic}} {{", filename: "a.md")
        let changed = try PromptCodec.editing(.field(draft), in: incomplete, filename: "a.md")
        XCTAssertNotNil(PromptForm(changed))
        XCTAssertTrue(changed.issues.contains { $0.code == .unbalancedOpener })
        XCTAssertThrowsError(try PromptCodec.write(changed))
        for source in ["No fields", "---\nformat: 2\n---\n{{topic}}", "---\nfields: [broken\n---\n{{topic}}"] {
            XCTAssertThrowsError(try PromptCodec.editing(.field(draft), in: PromptCodec.parse(source, filename: "a.md"), filename: "a.md"))
        }
    }

    func testEquivalentUnicodeEditsRetainRequestedBytes() throws {
        let document = PromptCodec.parse("---\nfields:\n  topic: {label: é}\n---\n{{topic}}", filename: "a.md")
        var draft = try settings(document)
        draft.label = "e\u{301}"
        let changed = try PromptCodec.editing(.field(draft), in: document, filename: "a.md")
        XCTAssertEqual(Data(changed.effectiveFields[0].label.utf8), Data(draft.label.utf8))
    }

    func testChoiceDefaultUsesTheExistingCanonicalEquivalenceRule() throws {
        let document = PromptCodec.parse("---\nfields:\n  topic: {type: choice, options: [é], default: e\u{301}}\n---\n{{topic}}", filename: "a.md")
        XCTAssertTrue(document.canRender)
        var draft = try settings(document)
        draft.label = "Topic"
        XCTAssertNil(draft.validationIssue)
        let changed = try PromptCodec.editing(.field(draft), in: document, filename: "a.md")
        XCTAssertEqual(Data(changed.effectiveFields[0].defaultValue.utf8), Data("e\u{301}".utf8))
    }

    func testApplySharesDraftGuardSaveAndHistory() throws {
        let editor = EditorHarness()
        let source = "{{topic}}\r\n"
        try editor.open(source)
        var draft = try XCTUnwrap(editor.model.state.form?.fieldSettings.first)
        draft.kind = .multiline
        draft.defaultValue = "Earth"
        editor.ui { editor.model.edit(.field(draft)) }
        XCTAssertTrue(editor.model.state.isDirty)
        XCTAssertEqual(try editor.h.files.text(at: "a.md"), source)
        editor.ui { editor.model.request(.close) }
        XCTAssertNotNil(editor.model.state.pendingDecision)
        try editor.decide(.cancel)
        editor.ui { editor.model.save() }
        editor.settle()
        XCTAssertEqual(editor.model.state.status, .saved)
        XCTAssertFalse(editor.model.state.isDirty)
        let stored = PromptCodec.parse(try editor.h.files.text(at: "a.md"), filename: "a.md")
        XCTAssertEqual(stored.effectiveFields.first?.kind, .multiline)
        XCTAssertEqual(stored.effectiveFields.first?.defaultValue, "Earth")
        let identity = try XCTUnwrap(editor.model.state.prompt?.identity)
        XCTAssertEqual(try editor.h.library.history(for: identity).count, 1)
    }
}
