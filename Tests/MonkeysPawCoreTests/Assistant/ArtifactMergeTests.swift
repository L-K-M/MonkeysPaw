import Foundation
import XCTest
import Yams
@testable import MonkeysPawCore

final class ArtifactMergeTests: XCTestCase {
    private let id = ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PD")!

    func testImproveReplacesOnlyArtifactOwnedContent() throws {
        let source = """
        ---
        id: 01k6z4v9kqwzx7mpq4t8znb2pd
        title: Old
        description: Old description
        tags: [old]
        favorite: true
        private: true
        fields: {old: {type: text}}
        format: 1
        model:
          settings: {enabled: true, count: 2, ratio: 1.5, absent: null}
          strings: ["on", "010", "true"]
          nested: [{second: [false, {deep: value}], first: 1}]
        extension: {"1": string key, 1: integer key}
        notes: User metadata
        ---
        Old {{old}}
        """
        let original = PromptCodec.parse(source, filename: "Original.md")
        let artifact = try decode()
        let candidate = try ready(ArtifactMerge.improve(artifact, original: original))
        let merged = candidate.document
        XCTAssertEqual(merged.frontMatter.id, original.frontMatter.id)
        XCTAssertTrue(merged.frontMatter.favorite)
        XCTAssertTrue(merged.frontMatter.isPrivate)
        XCTAssertEqual(merged.frontMatter.format, original.frontMatter.format)
        XCTAssertEqual(merged.frontMatter.title, artifact.title)
        XCTAssertEqual(merged.frontMatter.description, artifact.description)
        XCTAssertEqual(merged.frontMatter.tags, artifact.tags)
        XCTAssertEqual(merged.frontMatter.fields.map(\.name), artifact.fields.map(\.name))
        XCTAssertEqual(Data(merged.body.utf8), Data(artifact.body.utf8))
        for key in ["favorite", "private", "format", "model", "extension", "notes"] {
            XCTAssertEqual(node(key, in: merged), node(key, in: original), key)
        }
        XCTAssertEqual(PortableYAML.string(node("notes", in: merged)), "User metadata")
        XCTAssertFalse(merged.source.contains(artifact.notes))
        XCTAssertEqual(candidate.canonicalBytes, Data(try PromptCodec.write(merged).utf8))
        XCTAssertEqual(candidate.canonicalBytes, Data(merged.source.utf8))
        XCTAssertTrue(merged.issues.isEmpty)
        XCTAssertEqual(original.source, source)
    }

    func testPreservedKeyPresenceAndBooleanValuesMatrix() throws {
        let artifact = try decode()
        for idLine in ["", "id: \(id.rawValue)\n"] {
            for favorite in ["", "favorite: false\n", "favorite: true\n"] {
                for privacy in ["", "private: false\n", "private: true\n"] {
                    for format in ["", "format: 1\n"] {
                        let source = "---\n" + idLine + favorite + privacy + format + "title: Old\n---\nOld"
                        let original = PromptCodec.parse(source, filename: "Old.md")
                        let merged = try ready(ArtifactMerge.improve(artifact, original: original)).document
                        XCTAssertEqual(merged.frontMatter.id, original.frontMatter.id)
                        XCTAssertEqual(merged.frontMatter.favorite, original.frontMatter.favorite)
                        XCTAssertEqual(merged.frontMatter.isPrivate, original.frontMatter.isPrivate)
                        XCTAssertEqual(merged.frontMatter.format, original.frontMatter.format)
                        for key in ["id", "favorite", "private", "format"] {
                            XCTAssertEqual(node(key, in: merged), node(key, in: original), key)
                        }
                    }
                }
            }
        }
    }

    func testWriteHasSuppliedIdentityAndNoInheritedMetadata() throws {
        let artifact = try decode()
        let written = try ready(ArtifactMerge.write(artifact, id: id)).document
        XCTAssertEqual(written.frontMatter.id, id)
        XCTAssertEqual(written.frontMatter.title, artifact.title)
        for key in ["favorite", "private", "format", "notes", "model"] { XCTAssertNil(node(key, in: written)) }
        XCTAssertFalse(written.frontMatter.favorite)
        XCTAssertFalse(written.frontMatter.isPrivate)
        XCTAssertEqual(written.frontMatter.format, .current)

        let plain = PromptCodec.parse("Old {{old}}", filename: "Old.md")
        let improved = try ready(ArtifactMerge.improve(artifact, original: plain)).document
        XCTAssertNil(improved.frontMatter.id)
        XCTAssertNil(node("id", in: improved))
        XCTAssertEqual(improved.frontMatter.title, written.frontMatter.title)
    }

    func testChoiceOptionsCollapseIndividuallyAndEmptyDefaultIsAbsent() throws {
        var field = AssistantOutputFixtures.field
        field["options"] = [["label": "Rust", "value": "Rust"], ["label": "Swift 6", "value": "Swift"],
                            ["label": "true", "value": "true"]]
        field["default"] = ""
        var root = AssistantOutputFixtures.artifactReplacing(field, layer: 1)
        root["body"] = "{{tone}} {{context}}"
        let candidate = try ready(ArtifactMerge.write(try decode(root), id: id))
        let fields = try XCTUnwrap(node("fields", in: candidate.document)?.mapping)
        let tone = try XCTUnwrap(fields.first { PortableYAML.string($0.key) == "tone" }?.value.mapping)
        XCTAssertFalse(tone.contains { PortableYAML.string($0.key) == "default" })
        let options = try XCTUnwrap(tone.first { PortableYAML.string($0.key) == "options" }?.value.sequence)
        XCTAssertEqual(PortableYAML.string(options[0]), "Rust")
        XCTAssertNotNil(options[1].mapping)
        XCTAssertEqual(PortableYAML.string(options[2]), "true")
        XCTAssertEqual(candidate.document.frontMatter.fields[0].defaultValue, "")
        XCTAssertEqual(candidate.document.frontMatter.fields[0].options,
                       [FieldOption(label: "Rust", value: "Rust"), FieldOption(label: "Swift 6", value: "Swift"),
                        FieldOption(label: "true", value: "true")])
        XCTAssertTrue(candidate.document.issues.isEmpty)
    }

    func testFieldPropertiesAndBodyBytesRoundTrip() throws {
        var field = AssistantOutputFixtures.field
        field["optional"] = true
        field["remember"] = false
        field["label"] = "on"
        field["description"] = "line one\n---\nline two"
        var root = AssistantOutputFixtures.artifactReplacing(field, layer: 1)
        root["title"] = "true"
        root["tags"] = ["on", "010", "true"]
        root["body"] = "  文書 {{tone}}\r\ne\u{301} {{context}}\n\n"
        let artifact = try decode(root)
        let candidate = try ready(ArtifactMerge.write(artifact, id: id))
        let merged = candidate.document
        XCTAssertEqual(merged.frontMatter.title, artifact.title)
        XCTAssertEqual(merged.frontMatter.tags, artifact.tags)
        let converted = merged.frontMatter.fields[0]
        XCTAssertEqual(converted.name, artifact.fields[0].name)
        XCTAssertEqual(converted.kind, artifact.fields[0].type)
        XCTAssertEqual(converted.label, artifact.fields[0].label)
        XCTAssertEqual(converted.description, artifact.fields[0].description)
        XCTAssertEqual(converted.defaultValue, artifact.fields[0].defaultValue)
        XCTAssertEqual(converted.options, artifact.fields[0].options)
        XCTAssertTrue(converted.optional)
        XCTAssertFalse(converted.remember)
        XCTAssertEqual(Data(merged.body.utf8), Data(artifact.body.utf8))
    }

    func testChoiceCollapseRequiresByteIdenticalLabelAndValue() throws {
        var field = AssistantOutputFixtures.field
        field["options"] = [["label": "é", "value": "e\u{301}"]]
        field["default"] = "e\u{301}"
        let candidate = try ready(ArtifactMerge.write(try decode(AssistantOutputFixtures.artifactReplacing(field, layer: 1)), id: id))
        let converted = candidate.document.frontMatter.fields[0].options[0]
        XCTAssertEqual(Data(converted.label.utf8), Data("é".utf8))
        XCTAssertEqual(Data(converted.value.utf8), Data("e\u{301}".utf8))
    }

    func testValidationErrorsNeverProduceReadyCandidate() throws {
        for body in ["{{unfinished", "{{uuid}}"] {
            var root = AssistantOutputFixtures.artifact
            root["body"] = body
            try assertInvalid(ArtifactMerge.write(try decode(root), id: id))
        }
        for property in ["name", "options", "default"] {
            var field = AssistantOutputFixtures.field
            field[property] = property == "options" ? [] : "not valid"
            try assertInvalid(ArtifactMerge.write(try decode(AssistantOutputFixtures.artifactReplacing(field, layer: 1)), id: id))
        }
        let artifact = try decode()
        for source in ["---\nprivate: on\n---\nOld", "---\nformat: 2\n---\nOld",
                       "---\nid: bad\n---\nOld", "---\nmodel: {duplicate: 1, duplicate: 2}\n---\nOld",
                       "---\nmodel: [\n---\nOld", "Old {{unfinished"] {
            try assertInvalid(ArtifactMerge.improve(artifact, original: PromptCodec.parse(source, filename: "Old.md")))
        }
    }

    func testWarningsPermitReadyAndCanonicalSizeIsChecked() throws {
        var root = AssistantOutputFixtures.artifact
        root["body"] = "{{#if x}}"
        let candidate = try ready(ArtifactMerge.write(try decode(root), id: id))
        XCTAssertFalse(candidate.document.issues.isEmpty)
        XCTAssertTrue(candidate.document.issues.allSatisfy { $0.severity == .warning })

        root["fields"] = []
        root["body"] = String(repeating: "x", count: Limits.maxPromptBytes)
        guard case .failed(.sourceTooLarge) = ArtifactMerge.write(try decode(root), id: id) else {
            return XCTFail("Header plus body must obey the canonical source bound")
        }
        root["body"] = String(repeating: "x", count: Limits.maxPromptBytes + 1)
        try assertInvalid(ArtifactMerge.write(try decode(root), id: id))
    }

    func testFinalValidationAlsoRejectsDirectlyConstructedDuplicateFields() throws {
        let decoded = try decode()
        let artifact = LlmArtifact(title: decoded.title, description: decoded.description, tags: decoded.tags,
                                   fields: [decoded.fields[0], decoded.fields[0]], body: decoded.body, notes: decoded.notes)
        XCTAssertFalse(artifact.issues.contains { $0.severity == .error })
        guard case .invalid(let issues) = ArtifactMerge.write(artifact, id: id) else { return XCTFail("Final bytes must be validated") }
        XCTAssertTrue(issues.contains { $0.code == .duplicateKey })
    }

    private func node(_ key: String, in document: PromptDocument) -> Node? {
        document.preservedHeader?.mapping?.first { PortableYAML.string($0.key) == key }?.value
    }

    private func decode(_ root: [String: Any] = AssistantOutputFixtures.artifact) throws -> LlmArtifact {
        try LlmOutputDecoder.artifact(from: AssistantOutputFixtures.json(root))
    }

    private func ready(_ result: ArtifactMergeResult, file: StaticString = #filePath, line: UInt = #line) throws -> ArtifactMergeCandidate {
        guard case .ready(let candidate) = result else {
            XCTFail("Expected a validated candidate", file: file, line: line)
            throw PromptWriteError.invalidPrompt
        }
        return candidate
    }

    private func assertInvalid(_ result: ArtifactMergeResult, file: StaticString = #filePath, line: UInt = #line) throws {
        guard case .invalid(let issues) = result else { return XCTFail("Expected invalid outcome", file: file, line: line) }
        XCTAssertTrue(issues.contains { $0.severity == .error }, file: file, line: line)
    }
}
