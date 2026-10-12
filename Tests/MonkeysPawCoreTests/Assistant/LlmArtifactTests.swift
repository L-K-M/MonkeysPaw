import Foundation
import XCTest
@testable import MonkeysPawCore

final class LlmArtifactTests: XCTestCase {
    func testArtifactPreservesAllValuesAndFieldOrder() throws {
        let artifact = try decode(AssistantOutputFixtures.artifact)
        XCTAssertEqual(artifact.title, "Research")
        XCTAssertEqual(artifact.description, "Research a topic")
        XCTAssertEqual(artifact.tags, ["research", "work"])
        XCTAssertEqual(artifact.notes, "Explain the context and preserve the tone.")
        XCTAssertEqual(artifact.fields.map(\.name), ["tone", "context"])
        let field = try XCTUnwrap(artifact.fields.first)
        XCTAssertEqual(field.type, .choice)
        XCTAssertEqual(field.label, "Tone")
        XCTAssertEqual(field.description, "Voice to use")
        XCTAssertEqual(field.defaultValue, "neutral")
        XCTAssertEqual(field.options, [FieldOption(label: "Neutral", value: "neutral")])
        XCTAssertFalse(field.optional)
        XCTAssertTrue(field.remember)
        XCTAssertEqual(artifact.body, "<context>{{ context }}</context>\nUse {{tone}}.")
        XCTAssertTrue(artifact.issues.isEmpty)
    }

    func testRejectsMissingExtraAndWrongTypesAtEveryArtifactObject() throws {
        let objects = [AssistantOutputFixtures.artifact, AssistantOutputFixtures.field, AssistantOutputFixtures.option]
        for (layer, original) in objects.enumerated() {
            for key in original.keys.sorted() {
                var missing = original
                missing.removeValue(forKey: key)
                try assertInvalid(AssistantOutputFixtures.artifactReplacing(missing, layer: layer))
                for wrong in AssistantOutputFixtures.wrongTypes(for: key) {
                    var invalid = original
                    invalid[key] = wrong
                    try assertInvalid(AssistantOutputFixtures.artifactReplacing(invalid, layer: layer))
                }
            }
            var extra = original
            extra["unexpected"] = "value"
            try assertInvalid(AssistantOutputFixtures.artifactReplacing(extra, layer: layer))
        }
    }

    func testRejectsInvalidFieldTypesAndUnorderedFieldObjects() throws {
        for type in ["Text", "checkbox", "", "choice\n"] {
            var field = AssistantOutputFixtures.field
            field["type"] = type
            try assertInvalid(AssistantOutputFixtures.artifactReplacing(field, layer: 1))
        }
        var root = AssistantOutputFixtures.artifact
        root["fields"] = ["tone": AssistantOutputFixtures.field]
        try assertInvalid(root)
        root["tags"] = ["valid", 1]
        try assertInvalid(root)
        root = AssistantOutputFixtures.artifact
        root["fields"] = [AssistantOutputFixtures.field, "field"]
        try assertInvalid(root)
        var field = AssistantOutputFixtures.field
        field["options"] = ["neutral"]
        try assertInvalid(AssistantOutputFixtures.artifactReplacing(field, layer: 1))
    }

    func testRejectsDuplicateFieldNamesButKeepsCaseSensitiveNames() throws {
        var root = AssistantOutputFixtures.artifact
        var second = AssistantOutputFixtures.field
        second["type"] = "text"
        second["options"] = []
        root["fields"] = [AssistantOutputFixtures.field, second]
        try assertInvalid(root)
        second["name"] = "Tone"
        root["fields"] = [AssistantOutputFixtures.field, second]
        XCTAssertEqual(try decode(root).fields.map(\.name), ["tone", "Tone"])
    }

    func testLocalPlaceholderChecksUseExistingGrammarAndSeverity() throws {
        for body in ["{{user_name}} {{ USER-NAME }} {{_value2}}", "\\{{literal}}", "{{clipboard}} {{date}} {{time}}"] {
            XCTAssertTrue(try withBody(body).issues.isEmpty)
        }
        for body in ["{{ a b }}", "{{#if x}}", "{{line\nbreak}}", "{{é}}", "{{outer{{inner}}"] {
            let issues = try withBody(body).issues
            XCTAssertEqual(issues.map(\.code), Template.parse(body).issues.map(\.code))
            XCTAssertEqual(issues.first?.severity, .warning)
        }
        let unbalanced = try withBody("Input {{missing").issues
        XCTAssertEqual(unbalanced.map(\.code), [.unbalancedOpener])
        XCTAssertEqual(unbalanced.first?.severity, .error)
        XCTAssertEqual(unbalanced.first?.location, .body(byteOffset: 6))
        for name in ["selection", "cursor", "datetime", "uuid"] {
            XCTAssertEqual(try withBody("{{\(name)}}").issues.map(\.code), [.reservedFieldName])
        }
    }

    func testLocalFieldNameOptionDefaultAndUnusedChecks() throws {
        for name in ["1name", "has space", "é"] {
            var field = AssistantOutputFixtures.field
            field["name"] = name
            XCTAssertTrue(try decode(AssistantOutputFixtures.artifactReplacing(field, layer: 1))
                .issues.contains { $0.code == .invalidFieldName && $0.severity == .error })
        }
        for name in ["clipboard", "date", "time", "selection", "cursor", "datetime", "uuid"] {
            var field = AssistantOutputFixtures.field
            field["name"] = name
            XCTAssertTrue(try decode(AssistantOutputFixtures.artifactReplacing(field, layer: 1))
                .issues.contains { $0.code == .reservedFieldName && $0.severity == .error })
        }
        var field = AssistantOutputFixtures.field
        field["options"] = []
        XCTAssertTrue(try decode(AssistantOutputFixtures.artifactReplacing(field, layer: 1))
            .issues.contains { $0.code == .invalidFieldOptions })
        field = AssistantOutputFixtures.field
        field["default"] = "not an option"
        XCTAssertTrue(try decode(AssistantOutputFixtures.artifactReplacing(field, layer: 1))
            .issues.contains { $0.code == .invalidFieldDefault })
        field["default"] = ""
        XCTAssertTrue(try decode(AssistantOutputFixtures.artifactReplacing(field, layer: 1)).issues.isEmpty)
        for type in ["text", "multiline"] {
            field["type"] = type
            XCTAssertTrue(try decode(AssistantOutputFixtures.artifactReplacing(field, layer: 1))
                .issues.contains { $0.code == .invalidFieldOptions })
        }
        var root = AssistantOutputFixtures.artifact
        root["body"] = "No variables."
        XCTAssertEqual(try decode(root).issues.map(\.code), [.unusedField, .unusedField])
        XCTAssertTrue(try decode(root).issues.allSatisfy { $0.severity == .warning })
    }

    func testOversizeBodyIsABlockingDraftIssue() throws {
        XCTAssertEqual(try withBody(String(repeating: "x", count: Limits.maxPromptBytes + 1))
            .issues.map(\.code), [.sourceTooLarge])
        XCTAssertTrue(try withBody(String(repeating: "x", count: Limits.maxPromptBytes)).issues.isEmpty)
    }

    private func withBody(_ body: String) throws -> LlmArtifact {
        var root = AssistantOutputFixtures.artifact
        root["body"] = body
        root["fields"] = []
        return try decode(root)
    }

    private func decode(_ object: [String: Any]) throws -> LlmArtifact {
        try LlmOutputDecoder.artifact(from: AssistantOutputFixtures.json(object))
    }

    private func assertInvalid(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let json = try AssistantOutputFixtures.json(object)
        XCTAssertThrowsError(try LlmOutputDecoder.artifact(from: json), file: file, line: line) {
            XCTAssertEqual($0 as? AssistantError, .invalidOutput, file: file, line: line)
        }
    }
}
