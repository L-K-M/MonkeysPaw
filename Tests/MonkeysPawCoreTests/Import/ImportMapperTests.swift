import Foundation
import XCTest
import Yams
@testable import MonkeysPawCore

final class ImportMapperTests: XCTestCase {
    func testMarkdownPreservesAllSourceBytesAndCommentsWithoutAssigningIdentity() throws {
        let sources = ["é\r\n\t{{name}}\n\n", "---\r\n# keep\r\ncustom: {a: [1, true]}\r\n---\r\n  {{name}}\r\n"]
        for source in sources {
            let mapped = try map(source, as: "Example.md")
            XCTAssertEqual(Data(mapped.document.source.utf8), Data(source.utf8))
            XCTAssertNil(mapped.document.frontMatter.id)
            XCTAssertTrue(mapped.report.mappings.isEmpty)
            XCTAssertTrue(mapped.report.dropped.isEmpty)
            XCTAssertEqual(mapped.report.preservedKeys, source.hasPrefix("---") ? ["custom"] : [])
        }
    }

    func testUTF8BOMIsPreservedByImportAndSubsequentFileParsing() throws {
        for filename in ["Example.md", "Example.prompt", "Example.prompty"] {
            let source = "\u{feff}body {{name}}\r\n"
            let bytes = Data(source.utf8)
            let mapped = try ImportMapper.map(bytes, filename: filename)
            XCTAssertEqual(Data(mapped.document.source.utf8), bytes)
            XCTAssertEqual(Data(mapped.document.body.utf8), bytes)
            let loaded = PromptCodec.parseFile(bytes, filename: filename)
            XCTAssertEqual(Data(loaded.source.utf8), bytes)
            XCTAssertEqual(Data(loaded.body.utf8), bytes)
        }
    }

    func testDotpromptPicoschemaMapsStringsEnumsDescriptionsAndDefaults() throws {
        let body = "é\r\n{{name}} / {{tone}} / {{hint}}\r\n\n"
        let source = """
        ---
        input:
          schema:
            name: string, Your name, including initials
            tone(enum, Voice): [formal, casual]
            hint?: string
          default:
            name: Ada
            tone: casual
        model: googleai/example
        output: {format: json}
        config: {temperature: 0.5}
        tools: [lookup]
        vendor: {nested: [true, 7, null]}
        ---

        """ + body
        let mapped = try map(source)
        let fields = mapped.document.frontMatter.fields
        XCTAssertEqual(fields.map(\.name), ["name", "tone", "hint"])
        XCTAssertEqual(fields.map(\.kind), [.text, .choice, .text])
        XCTAssertEqual(fields.map(\.defaultValue), ["Ada", "casual", ""])
        XCTAssertEqual(fields[0].description, "Your name, including initials")
        XCTAssertEqual(fields[1].description, "Voice")
        XCTAssertEqual(fields[1].options.map(\.value), ["formal", "casual"])
        XCTAssertTrue(fields[2].optional)
        XCTAssertEqual(Data(mapped.document.body.utf8), Data(body.utf8))
        XCTAssertEqual(mapped.report.preservedKeys, ["input", "model", "output", "config", "tools", "vendor"])
        XCTAssertEqual(mapped.report.mappings.map(\.defaultSource), ["input.default.name", "input.default.tone", nil])
        try assertPreservedMetadata(source, result: mapped.document)
        XCTAssertEqual(mapped.report.dropped, [.frontMatterPresentation])
    }

    func testDotpromptJSONSchemaAndDeclarationForms() throws {
        for (schema, optional) in [
            ("""
              type: object
              required: [name]
              properties:
                name: {type: string, default: Ada, description: Person}
                tone: {type: string, enum: [formal, casual]}
            """, true),
            ("""
              name: {type: string, default: Ada, description: Person}
              tone: {type: string, enum: [formal, casual]}
            """, false)
        ] {
            let indented = schema.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
            let source = "---\ninput:\n  schema:\n" + indented + "\n  default: {name: Other, tone: formal}\n---\n{{name}} {{tone}}"
            let mapped = try map(source)
            XCTAssertEqual(mapped.document.frontMatter.fields.map(\.name), ["name", "tone"])
            XCTAssertEqual(mapped.document.frontMatter.fields.map(\.defaultValue), ["Ada", "formal"])
            XCTAssertEqual(mapped.document.frontMatter.fields[1].optional, optional)
            try assertPreservedMetadata(source, result: mapped.document)
        }
    }

    func testPromptyKeyedAndListInputsUseSampleOnlyForAbsentDefaults() throws {
        for inputs in [
            """
            inputs:
              name: {type: string, default: Ada, description: Person}
              tone: {type: string, enum: [formal, casual]}
              hint: {type: string, sample: local, required: false}
            """,
            """
            inputs:
              - {name: name, type: string, default: Ada, description: Person}
              - {name: tone, type: string, enum: [formal, casual]}
              - {name: hint, type: string, sample: local, required: false}
            """
        ] {
            let source = "---\n" + inputs + "\nsample: {name: Other, tone: casual, hint: root}\nauthors: [Author]\nmodel: {api: chat}\n---\nsystem:\r\n{{name}} {{tone}} {{hint}}\n"
            let mapped = try map(source, as: "Example.prompty")
            let fields = mapped.document.frontMatter.fields
            XCTAssertEqual(fields.map(\.defaultValue), ["Ada", "casual", "local"])
            XCTAssertEqual(fields.map(\.kind), [.text, .choice, .text])
            XCTAssertEqual(fields[0].description, "Person")
            XCTAssertTrue(fields[2].optional)
            XCTAssertTrue(mapped.report.mappings[0].defaultSource?.hasSuffix(".default") == true)
            XCTAssertEqual(mapped.report.mappings[1].defaultSource, "sample.tone")
            XCTAssertTrue(mapped.report.mappings[2].defaultSource?.hasSuffix(".sample") == true)
            try assertPreservedMetadata(source, result: mapped.document)
        }
    }

    func testLossyInputsAndReservedNamesRemainMetadataAndAreReported() throws {
        for filename in ["Example.prompt", "Example.prompty"] {
            let declarations = """
                okay: {type: string}
                count: {type: integer}
                list: {type: array, items: {type: string}}
                object: {type: object}
                date: {type: string}
                time: {type: string}
                clipboard: {type: string}
                selection: {type: string}
                uuid: {type: string}
                bad.name: {type: string}
                badEnum: {type: string, enum: [a, 3]}
                emptyEnum: {type: string, enum: []}
                badDefault: {type: string, default: false}
                badChoice: {type: string, enum: [a, b], default: c}
                badDescription: {type: string, description: 7}
            """
            let heading = filename.hasSuffix(".prompt") ? "input:\n  schema:\n" : "inputs:\n"
            let lines = declarations.split(separator: "\n").map { heading.hasPrefix("input:") ? "    " + $0 : "  " + $0 }
            let source = "---\n" + heading + lines.joined(separator: "\n") + "\n---\n{{okay}} {{date}} {{clipboard}}"
            let mapped = try map(source, as: filename)
            XCTAssertEqual(mapped.document.frontMatter.fields.map(\.name), ["okay"])
            XCTAssertTrue(mapped.report.warnings.contains(.reservedName("date")))
            XCTAssertTrue(mapped.report.warnings.contains(.reservedName("time")))
            XCTAssertTrue(mapped.report.warnings.contains(.reservedName("clipboard")))
            XCTAssertTrue(mapped.report.warnings.contains(.reservedName("selection")))
            XCTAssertTrue(mapped.report.warnings.contains(.reservedName("uuid")))
            XCTAssertEqual(mapped.report.warnings.filter { if case .unsupportedInput = $0 { return true }; return false }.count, 3)
            XCTAssertEqual(mapped.report.warnings.filter { if case .invalidOptions = $0 { return true }; return false }.count, 2)
            XCTAssertEqual(mapped.report.warnings.filter { if case .invalidDefault = $0 { return true }; return false }.count, 2)
            try assertPreservedMetadata(source, result: mapped.document)
        }
    }

    func testPromptySamplesSupplyImplicitDefaultsWithoutOverridingUnsupportedInputs() throws {
        let source = "---\ninputs:\n  count: {type: integer}\nsample: {name: Ada, count: '3', clipboard: value, unused: retained}\n---\n{{name}} {{count}} {{clipboard}}"
        let mapped = try map(source, as: "Example.prompty")
        XCTAssertEqual(mapped.document.frontMatter.fields.map(\.name), ["name"])
        XCTAssertEqual(mapped.document.frontMatter.fields.first?.defaultValue, "Ada")
        XCTAssertEqual(mapped.report.mappings.map(\.sourceKey), ["sample.name"])
        XCTAssertEqual(mapped.report.mappings.map(\.defaultSource), ["sample.name"])
        XCTAssertTrue(mapped.report.warnings.contains(.reservedName("clipboard")))
        try assertPreservedMetadata(source, result: mapped.document)
        let onlySample = try map("---\nsample: {name: Ada}\n---\n{{name}}", as: "Example.prompty")
        XCTAssertEqual(onlySample.document.frontMatter.fields.first?.defaultValue, "Ada")
    }

    func testPicoschemaArraysNeverBecomeTextAndNormalizedNamesCannotOverwrite() throws {
        let source = "---\ninput:\n  schema:\n    tags(array): string\n    name: string\n    name?: string\n    date?: string\n---\n{{name}}"
        let mapped = try map(source)
        XCTAssertEqual(mapped.document.frontMatter.fields.map(\.name), ["name"])
        XCTAssertTrue(mapped.report.warnings.contains(.unsupportedInput("input.schema.tags(array)")))
        XCTAssertTrue(mapped.report.warnings.contains(.fieldCollision("name")))
        XCTAssertTrue(mapped.report.warnings.contains(.reservedName("date")))
    }

    func testExistingNativeDeclarationsArePreserved() throws {
        let source = "---\nfields:\n  name: {type: multiline, default: Original, custom: retained}\ninput:\n  schema:\n    name: string\n    extra: string\n---\n{{name}} {{extra}}"
        let mapped = try map(source)
        XCTAssertEqual(mapped.document.frontMatter.fields.map(\.kind), [.multiline, .text])
        XCTAssertEqual(mapped.document.frontMatter.fields[0].defaultValue, "Original")
        XCTAssertTrue(mapped.report.warnings.contains(.fieldCollision("name")))
        XCTAssertTrue(mapped.document.source.contains("custom: retained"))
    }

    func testForeignTemplateConstructsStayLiteralAndBodyBytesAreExact() throws {
        let cases: [(String, String)] = [
            ("Example.prompt", "é {{#if name}}x{{/if}} {{user.name}} {{{raw}}}"),
            ("Example.prompty", "é {% if x %}{{x | upper}}{# comment #}{% endif %}")
        ]
        for (filename, body) in cases {
            let mapped = try map("---\nmodel: example\n---\n" + body, as: filename)
            XCTAssertEqual(Data(mapped.document.body.utf8), Data(body.utf8))
            XCTAssertTrue(mapped.document.template.names.isEmpty)
            XCTAssertEqual(try PromptRenderer.render(mapped.document), body)
            let offsets = mapped.report.warnings.compactMap { warning -> Int? in
                if case .unsupportedTemplate(_, let offset) = warning { return offset }
                return nil
            }
            XCTAssertEqual(offsets.count, 4)
            XCTAssertTrue(offsets.contains(3))
        }
    }

    func testSizesEncodingUnsupportedExtensionsAndInvalidDocumentsAreTyped() throws {
        XCTAssertThrowsError(try ImportMapper.map(Data(repeating: 65, count: Limits.importFileCapBytes + 1), filename: "x.md")) {
            XCTAssertEqual($0 as? ImportSkipReason, .fileTooLarge)
        }
        XCTAssertThrowsError(try ImportMapper.map(Data([0xff, 0xfe]), filename: "x.md")) {
            XCTAssertEqual($0 as? ImportSkipReason, .invalidUTF8)
        }
        XCTAssertNoThrow(try ImportMapper.map(Data(repeating: 65, count: Limits.importFileCapBytes), filename: "x.md"))
        XCTAssertThrowsError(try map("text", as: "x.MD")) { XCTAssertEqual($0 as? ImportSkipReason, .unsupportedExtension) }
        for source in ["---\nx: [\n---\nbody", "---\nx: &a foo\ncopy: *a\n---\nbody", "---\nx: yes\n---\nbody", "{{unclosed"] {
            XCTAssertThrowsError(try map(source)) { XCTAssertNotNil($0 as? ImportSkipReason) }
        }
        XCTAssertThrowsError(try map("---\nformat: 2\n---\nbody", as: "x.md")) {
            XCTAssertEqual($0 as? ImportSkipReason, .unsupportedFormat(PromptFormatVersion(decimalValue: "2")!))
        }
    }

    func testConversionExpansionCannotExceedThePromptCap() throws {
        let head = "---\ninput:\n  schema:\n    name: string\n---\n"
        let source = head + String(repeating: "a", count: Limits.importFileCapBytes - head.utf8.count)
        XCTAssertThrowsError(try map(source)) { XCTAssertEqual($0 as? ImportSkipReason, .convertedTooLarge) }
    }

    func testIdentityReplacementTargetsOnlyTheMarkedScalarIncludingUnicodeColumns() throws {
        let old = "01K6Z4V9KQWZX7MPQ4T8ZNB2PD"
        let replacement = try XCTUnwrap(ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PE"))
        for header in ["id: " + old, "id: '" + old + "' # keep", "id: \"" + old + "\"", "{é: value, id: '" + old + "'}"] {
            let source = "---\n" + header + "\n---\n" + old
            let original = try map(source, as: "Example.md")
            let result = try ImportMapper.replacingIdentity(replacement, in: original.document, filename: "Example.md")
            let head = header.replacingOccurrences(of: old, with: replacement.rawValue)
            XCTAssertEqual(Data(result.document.source.utf8), Data(("---\n" + head + "\n---\n" + old).utf8))
            XCTAssertFalse(result.presentationLost)
        }
        let source = "---\n# keep values\nid: |-\n  " + old + "\ncustom: retained\n---\nbody\r\n"
        let original = try map(source, as: "Example.md")
        let result = try ImportMapper.replacingIdentity(replacement, in: original.document, filename: "Example.md")
        XCTAssertEqual(result.document.frontMatter.id, replacement)
        XCTAssertEqual(result.document.body, "body\r\n")
        XCTAssertTrue(result.presentationLost)
        XCTAssertTrue(result.document.source.contains("custom: retained"))
    }

    private func map(_ source: String, as filename: String = "Example.prompt") throws -> ImportMappingResult {
        try ImportMapper.map(Data(source.utf8), filename: filename)
    }

    private func assertPreservedMetadata(_ source: String, result: PromptDocument) throws {
        let original = try XCTUnwrap(PromptCodec.parse(source, filename: "Example.prompt").preservedHeader?.mapping)
        let imported = try XCTUnwrap(result.preservedHeader?.mapping)
        for pair in original where PortableYAML.string(pair.key) != "fields" {
            let value = try XCTUnwrap(imported.first { $0.key == pair.key }?.value)
            XCTAssertEqual(value, pair.value)
        }
    }
}
