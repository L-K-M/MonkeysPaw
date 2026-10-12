import Foundation
import XCTest
import Yams
@testable import MonkeysPawCore

final class SeedCatalogTests: XCTestCase {
    func testCatalogMatchesEveryEligibleSourceByteForByte() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("seed")
        let manager = FileManager.default
        let enumerator = try XCTUnwrap(manager.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        var paths = [String]()
        for case let url as URL in enumerator {
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if properties.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let path = String(url.path.dropFirst(root.path.count + 1))
            if properties.isRegularFile == true, LibraryPath.isPrompt(path) { paths.append(path) }
        }
        paths.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let embedded = SeedCatalog.prompts.map(\.relativePath)
        XCTAssertEqual(paths.map { Data($0.utf8) }, embedded.map { Data($0.utf8) })
        XCTAssertEqual(Set(embedded.map { Data($0.utf8) }).count, embedded.count)
        XCTAssertFalse(LibraryPath.isPrompt("README.md"))
        XCTAssertTrue(LibraryPath.isPrompt("folder/README.md"))
        XCTAssertFalse(embedded.contains("README.md"))

        for seed in SeedCatalog.prompts {
            try LibraryPath.validate(seed.relativePath)
            XCTAssertEqual(seed.bytes, try Data(contentsOf: root.appendingPathComponent(seed.relativePath)),
                           "Regenerate the catalog after changing seed sources.")
        }
    }

    func testEverySeedParsesWithoutIssuesAndRendersWithDefaultsWherePossible() throws {
        XCTAssertEqual(SeedCatalog.prompts.count, 10)
        let builtins = PromptBuiltinValues(clipboard: "Source material", date: "2026-10-11", time: "14:30")
        var defaultsRendered = 0
        for seed in SeedCatalog.prompts {
            let document = parse(seed)
            XCTAssertTrue(document.issues.isEmpty, seed.relativePath)
            XCTAssertNil(document.frontMatter.id, seed.relativePath)
            XCTAssertFalse(document.frontMatter.title.isEmpty)
            let description = try XCTUnwrap(document.frontMatter.description)
            XCTAssertFalse(description.isEmpty)
            XCTAssertFalse(description.contains("\n"))
            XCTAssertFalse(document.frontMatter.tags.isEmpty)
            XCTAssertFalse(document.body.isEmpty)

            let missing = document.effectiveFields.filter { !$0.optional && $0.defaultValue.isEmpty }
            if missing.isEmpty {
                XCTAssertFalse(try PromptRenderer.render(document, builtins: builtins).isEmpty)
                defaultsRendered += 1
            } else {
                XCTAssertThrowsError(try PromptRenderer.render(document, builtins: builtins)) {
                    guard case .missingRequiredValue(let name)? = $0 as? PromptRenderError else {
                        return XCTFail("Unexpected render error: \($0)")
                    }
                    XCTAssertTrue(missing.contains { $0.name == name }, "Unexpected missing field: \(name)")
                }
            }
            // Exercise every template, filling only required inputs that have no default.
            let values = Dictionary(uniqueKeysWithValues: missing.map {
                ($0.name, $0.kind == .choice ? $0.options[0].value : "Example input")
            })
            XCTAssertFalse(try PromptRenderer.render(document, values: values, builtins: builtins).isEmpty)
            let canonical = try PromptCodec.write(document)
            let reparsed = PromptCodec.parse(canonical, filename: LibraryPath.filename(seed.relativePath))
            XCTAssertTrue(reparsed.issues.isEmpty)
            XCTAssertEqual(reparsed.frontMatter, document.frontMatter)
            XCTAssertEqual(Data(reparsed.body.utf8), Data(document.body.utf8))
        }
        XCTAssertGreaterThan(defaultsRendered, 0)
        XCTAssertLessThan(defaultsRendered, SeedCatalog.prompts.count)
    }

    func testParsedSeedsCoverEverySupportedFieldFeatureAndBuiltin() {
        let documents = SeedCatalog.prompts.map(parse)
        let fields = documents.flatMap(\.effectiveFields)
        XCTAssertEqual(Set(fields.map { $0.kind.rawValue }), ["text", "multiline", "choice"])
        XCTAssertEqual(Set(fields.filter { !$0.defaultValue.isEmpty }.map { $0.kind.rawValue }),
                       ["text", "multiline", "choice"])
        XCTAssertTrue(fields.contains { $0.optional && $0.defaultValue.isEmpty })
        XCTAssertTrue(fields.contains { $0.kind == .choice && $0.optional && $0.defaultValue.isEmpty })
        XCTAssertTrue(fields.contains { !$0.optional })
        XCTAssertTrue(fields.contains { !$0.remember })
        XCTAssertTrue(fields.contains { $0.remember })
        XCTAssertTrue(fields.contains { $0.description?.isEmpty == false })
        XCTAssertTrue(fields.contains { $0.label != $0.name })
        let implicit = fields.filter(\.isImplicit)
        XCTAssertFalse(implicit.isEmpty)
        XCTAssertTrue(implicit.allSatisfy {
            $0.kind == .text && $0.label == $0.name && !$0.optional && $0.remember && $0.defaultValue.isEmpty
        })
        XCTAssertEqual(Set(documents.flatMap { $0.template.builtins.map(\.rawValue) }),
                       ["clipboard", "date", "time"])

        // The public options flatten the two YAML forms. Inspect the parsed tree
        // too, so label=value maps cannot accidentally satisfy plain-option coverage.
        var plainOptions = false
        var mappedOptions = false
        var explicitChoiceDefault = false
        for document in documents {
            let declarations = value("fields", in: document.preservedHeader)
            for field in document.frontMatter.fields where field.kind == .choice {
                let declaration = value(field.name, in: declarations)
                let options = value("options", in: declaration)?.sequence ?? []
                plainOptions = plainOptions || (!options.isEmpty && options.allSatisfy { $0.scalar != nil })
                mappedOptions = mappedOptions || options.contains {
                    value("label", in: $0)?.string != nil && value("value", in: $0)?.string != nil
                }
                if value("default", in: declaration) != nil {
                    explicitChoiceDefault = true
                    XCTAssertTrue(field.options.contains { $0.value == field.defaultValue })
                }
            }
        }
        XCTAssertTrue(plainOptions)
        XCTAssertTrue(mappedOptions)
        XCTAssertTrue(fields.contains { $0.options.contains { $0.label != $0.value } })
        XCTAssertTrue(explicitChoiceDefault)
    }

    private func parse(_ seed: SeedCatalog.Seed) -> PromptDocument {
        PromptCodec.parseFile(seed.bytes, filename: LibraryPath.filename(seed.relativePath))
    }

    private func value(_ key: String, in node: Node?) -> Node? {
        node?.mapping?.first { $0.key.string == key }?.value
    }
}
