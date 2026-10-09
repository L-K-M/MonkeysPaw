import Foundation
import XCTest
import MonkeysPawCore

final class PromptContentTests: XCTestCase {
    func testCoherentSourceToRenderAndCanonicalRoundTrip() throws {
        let body = "  {{language}}: {{notes}} / {{new_field}} / {{date}}\r\n👋 {{notes}}"
        let source = """
        ---
        extension:
          z: [true, "on", "010"]
          a: {second: 2, first: 1}
        fields:
          notes: {type: multiline, default: "{{language}}", optional: true}
          language:
            type: choice
            options: [{label: Swift 6, value: Swift}, Rust]
            default: Swift
        title: My prompt
        ---

        """ + body
        let document = PromptCodec.parse(source, filename: "Fallback.md")
        XCTAssertTrue(document.issues.isEmpty)
        XCTAssertNil(document.frontMatter.id)
        XCTAssertEqual(document.frontMatter.fields.map(\.name), ["notes", "language"])
        XCTAssertEqual(document.effectiveFields.map(\.name), ["language", "notes", "new_field"])
        XCTAssertEqual(document.template.builtins, [.date])
        let values = ["new_field": "<raw> {{notes}} & data"]
        let snapshots = PromptBuiltinValues(date: "2026-10-09")
        let expected = "  Swift: {{language}} / <raw> {{notes}} & data / 2026-10-09\r\n👋 {{language}}"
        XCTAssertEqual(try PromptRenderer.render(document, values: values, builtins: snapshots), expected)

        let written = try PromptCodec.write(document)
        let roundTrip = PromptCodec.parse(written, filename: "Fallback.md")
        XCTAssertNil(roundTrip.frontMatter.id, "The content writer never assigns an identity.")
        XCTAssertEqual(roundTrip.frontMatter, document.frontMatter)
        XCTAssertEqual(Array(roundTrip.body.utf8), Array(body.utf8))
        XCTAssertEqual(try PromptRenderer.render(roundTrip, values: values, builtins: snapshots), expected)
        XCTAssertEqual(try PromptCodec.write(roundTrip), written)
        XCTAssertTrue(written.contains("extension:\n  z:\n  - true\n  - \"on\"\n  - \"010\"\n  a:\n    second: 2\n    first: 1\n"))
    }

    func testDiagnosticsHaveSafeMessagesAndUsefulLocations() {
        let source = "---\r\nprivate: on\r\n---\r\n👋 {{unfinished"
        let document = PromptCodec.parse(source, filename: "secret-filename.md")
        XCTAssertTrue(document.frontMatter.isPrivate)
        XCTAssertEqual(document.issues.map(\.code), [.nonPortableScalar, .invalidMetadataType, .unbalancedOpener])
        XCTAssertEqual(document.issues[0].location, .frontMatter(line: 2, column: 10))
        XCTAssertEqual(document.issues[1].location, .frontMatter(line: 2, column: 10))
        XCTAssertEqual(document.issues[2].location, .body(byteOffset: 5))
        for issue in document.issues {
            XCTAssertFalse(issue.message.isEmpty)
            XCTAssertFalse(issue.message.contains("private: on"))
            XCTAssertFalse(issue.message.contains("unfinished"))
            XCTAssertFalse(issue.message.contains("secret-filename"))
        }
        let deferred = PromptCodec.parse("é {{uuid}}", filename: "Example.md")
        XCTAssertEqual(deferred.issues.first?.location, .body(byteOffset: 3))
    }

    func testMalformedYAMLAndRenderErrorsNeverDescribeContent() {
        let marker = "sensitive_marker_123"
        let malformed = PromptCodec.parse("---\nx: [\(marker)\n---\nBody", filename: "Example.md")
        XCTAssertEqual(malformed.issues.first?.code, .invalidYAML)
        XCTAssertFalse(String(describing: malformed.issues).contains(marker))
        XCTAssertThrowsError(try PromptCodec.write(malformed)) {
            XCTAssertEqual($0 as? PromptWriteError, .invalidPrompt)
            XCTAssertFalse(String(describing: $0).contains(marker))
        }
        let required = PromptCodec.parse("{{\(marker)}}", filename: "Example.md")
        XCTAssertThrowsError(try PromptRenderer.render(required)) {
            XCTAssertEqual($0 as? PromptRenderError, .missingRequiredValue(marker))
            XCTAssertFalse(String(describing: $0).contains(marker))
        }
        let choice = PromptCodec.parse("---\nfields: {x: {type: choice, options: [allowed]}}\n---\n{{x}}", filename: "Example.md")
        XCTAssertThrowsError(try PromptRenderer.render(choice, values: ["x": marker])) {
            XCTAssertEqual($0 as? PromptRenderError, .invalidChoiceValue("x"))
            XCTAssertFalse(String(describing: $0).contains(marker))
        }
    }

    func testFutureFormatPreservesSourceButBlocksRenderAndWrite() {
        let source = "---\nformat: 2\nextension: {future: value}\n---\n  body\r\n"
        let document = PromptCodec.parse(source, filename: "Example.md")
        XCTAssertEqual(document.source, source)
        XCTAssertEqual(document.body, "  body\r\n")
        XCTAssertTrue(document.isReadOnly)
        XCTAssertFalse(document.canRender)
        XCTAssertThrowsError(try PromptCodec.write(document)) {
            XCTAssertEqual($0 as? PromptWriteError, .unsupportedFormat(PromptFormatVersion(2)!))
        }
        XCTAssertThrowsError(try PromptRenderer.render(document)) {
            XCTAssertEqual($0 as? PromptRenderError, .unsupportedFormat(PromptFormatVersion(2)!))
        }
    }

    func testWarningsDoNotBlockAndInvalidDeclarationsRemainRepresented() throws {
        let source = "---\nfields: {unused: {}}\n---\n{{#if x}}"
        let document = PromptCodec.parse(source, filename: "Example.md")
        XCTAssertEqual(document.issues.map(\.code), [.invalidPlaceholder, .unusedField])
        XCTAssertTrue(document.issues.allSatisfy { $0.severity == .warning })
        XCTAssertTrue(document.canRender)
        XCTAssertEqual(try PromptRenderer.render(document), "{{#if x}}")
        XCTAssertFalse(try PromptCodec.write(document).isEmpty)

        let invalidSource = "---\nfields: {x: {type: future}}\n---\n{{x}}"
        let invalid = PromptCodec.parse(invalidSource, filename: "Example.md")
        XCTAssertEqual(invalid.source, invalidSource)
        XCTAssertEqual(invalid.frontMatter.fields.map(\.name), ["x"])
        XCTAssertEqual(invalid.effectiveFields.map(\.name), ["x"])
        XCTAssertFalse(invalid.canRender)
        XCTAssertThrowsError(try PromptRenderer.render(invalid, values: ["x": "present"])) {
            XCTAssertEqual($0 as? PromptRenderError, .invalidPrompt)
        }
    }

    func testStandaloneTemplateParserAlsoHonorsTheSourceBound() {
        let template = Template.parse(String(repeating: "{{x}}", count: Limits.maxPromptBytes / 5 + 1))
        XCTAssertEqual(template.issues.map(\.code), [.sourceTooLarge])
        XCTAssertTrue(template.names.isEmpty)
    }

    func testUnicodeValueBoundariesPreserveUTF8Bytes() throws {
        let document = PromptCodec.parse("e{{accent}}", filename: "Example.md")
        let output = try PromptRenderer.render(document, values: ["accent": "\u{301}"])
        XCTAssertEqual(Array(output.utf8), [0x65, 0xcc, 0x81])
    }
}
