import Foundation
import XCTest
import MonkeysPawCore

/// The corpus is enumerated, not a hand-picked list. Each JSON and source
/// must be dispatched exactly once so future language consumers share a gate.
final class PromptConformanceTests: XCTestCase {
    private let categories: Set<String> = ["format", "grammar", "render", "validation"]

    func testEveryFixture() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("spec/fixtures")
        let manager = FileManager.default
        let directories = try manager.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(Set(directories), categories)
        var consumed = Set<String>()
        var allFiles = Set<String>()
        var cases = 0

        for category in directories {
            guard categories.contains(category) else { throw CorpusError.unknownCategory }
            let directory = root.appendingPathComponent(category)
            let files = try manager.contentsOfDirectory(atPath: directory.path).sorted()
            guard !files.isEmpty else { throw CorpusError.emptyCategory }

            for file in files {
                guard file.hasSuffix(".md") || file.hasSuffix(".json") else {
                    throw CorpusError.unrecognizedFile
                }
                allFiles.insert(category + "/" + file)
            }

            for file in files where file.hasSuffix(".json") {
                let sourceFile = String(file.dropLast(5)) + ".md"
                guard files.contains(sourceFile) else { throw CorpusError.missingSource }
                let data = try Data(contentsOf: directory.appendingPathComponent(file))
                let fixture = try object(JSONSerialization.jsonObject(with: data))
                let optional: Set<String> = category == "render" ? ["repeat", "values", "builtins"] : ["repeat"]
                try keys(fixture, required: ["schema", "category", "filename", "expected"],
                         optional: optional)
                guard try integer(fixture["schema"]) == 1,
                      fixture["category"] as? String == category,
                      let filename = fixture["filename"] as? String else {
                    throw CorpusError.unrecognizedCase
                }
                let sourceData = try Data(contentsOf: directory.appendingPathComponent(sourceFile))
                guard let unit = String(data: sourceData, encoding: .utf8) else {
                    throw CorpusError.invalidUTF8
                }
                let count = try fixture["repeat"].map { try integer($0) } ?? 1
                guard count > 0 else { throw CorpusError.unrecognizedCase }
                let source = String(repeating: unit, count: count)
                let document = PromptCodec.parse(source, filename: filename)
                XCTAssertEqual(Array(document.source.utf8), Array(source.utf8), file)
                XCTAssertEqual(document.issues, PromptValidator.validate(document), file)
                let expected = try object(fixture["expected"])
                let actual: [String: Any]

                switch category {
                case "format":
                    try keys(expected, required: ["metadata", "body", "issues", "canonical"])
                    let canonical: Any = (try? PromptCodec.write(document)) ?? NSNull()
                    guard let expectedBody = expected["body"] as? String else { throw CorpusError.unrecognizedCase }
                    XCTAssertEqual(Array(document.body.utf8), Array(expectedBody.utf8), file)
                    if let text = canonical as? String, let expectedText = expected["canonical"] as? String {
                        XCTAssertEqual(Array(text.utf8), Array(expectedText.utf8), file)
                    }
                    actual = ["metadata": metadata(document.frontMatter), "body": document.body,
                              "issues": issues(document), "canonical": canonical]
                    if let written = canonical as? String {
                        let reparsed = PromptCodec.parse(written, filename: filename)
                        XCTAssertEqual(Array(reparsed.body.utf8), Array(document.body.utf8), file)
                        XCTAssertEqual(try PromptCodec.write(reparsed), written, file)
                        XCTAssertEqual(NSDictionary(dictionary: metadata(reparsed.frontMatter)),
                                       NSDictionary(dictionary: metadata(document.frontMatter)), file)
                    }
                case "grammar":
                    try keys(expected, required: ["tokens", "names", "fields", "issues"])
                    actual = ["tokens": document.template.tokens.map(token),
                              "names": document.template.names,
                              "fields": document.effectiveFields.map(field), "issues": issues(document)]
                case "render":
                    try keys(expected, required: ["fields", "builtins", "issues", "result"])
                    let values = try strings(fixture["values"] ?? [:])
                    let context = try strings(fixture["builtins"] ?? [:])
                    guard Set(context.keys).isSubset(of: ["clipboard", "date", "time"]) else {
                        throw CorpusError.unrecognizedCase
                    }
                    let builtins = PromptBuiltinValues(clipboard: context["clipboard"],
                                                       date: context["date"], time: context["time"])
                    var result: [String: Any]
                    do {
                        result = ["text": try PromptRenderer.render(document, values: values,
                                                                     builtins: builtins)]
                    } catch let error as PromptRenderError {
                        result = renderFailure(error)
                    }
                    if let text = result["text"] as? String,
                       let expectedResult = expected["result"] as? [String: Any],
                       let expectedText = expectedResult["text"] as? String {
                        XCTAssertEqual(Array(text.utf8), Array(expectedText.utf8), file)
                    }
                    actual = ["fields": document.effectiveFields.map(field),
                              "builtins": document.template.builtins.map(\.rawValue),
                              "issues": issues(document), "result": result]
                case "validation":
                    try keys(expected, required: ["issues", "private", "fields", "canRender",
                                                  "readOnly", "canWrite"])
                    actual = ["issues": issues(document), "private": document.frontMatter.isPrivate,
                              "fields": document.effectiveFields.map(field),
                              "canRender": document.canRender, "readOnly": document.isReadOnly,
                              "canWrite": (try? PromptCodec.write(document)) != nil]
                default:
                    throw CorpusError.unknownCategory
                }

                XCTAssertEqual(NSDictionary(dictionary: actual), NSDictionary(dictionary: expected),
                               category + "/" + file)
                guard consumed.insert(category + "/" + file).inserted,
                      consumed.insert(category + "/" + sourceFile).inserted else {
                    throw CorpusError.duplicateConsumption
                }
                cases += 1
            }
        }

        XCTAssertGreaterThan(cases, 0)
        XCTAssertEqual(consumed, allFiles, "Every source and expected JSON must be consumed.")
        print("Consumed \(cases) prompt fixtures (\(consumed.count) files).")
    }

    private func metadata(_ value: FrontMatter) -> [String: Any] {
        ["id": value.id?.rawValue as Any? ?? NSNull(), "title": value.title,
         "description": value.description as Any? ?? NSNull(), "tags": value.tags,
         "favorite": value.favorite, "private": value.isPrivate, "format": value.format.decimalValue,
         "declarations": value.fields.map(field)]
    }

    private func field(_ value: PromptField) -> [String: Any] {
        ["name": value.name, "type": value.kind.rawValue, "label": value.label,
         "description": value.description as Any? ?? NSNull(), "default": value.defaultValue,
         "options": value.options.map { ["label": $0.label, "value": $0.value] },
         "optional": value.optional, "remember": value.remember, "implicit": value.isImplicit]
    }

    private func token(_ value: TemplateToken) -> [String: Any] {
        switch value {
        case .literal(let text): return ["kind": "literal", "text": text]
        case .escapedOpener: return ["kind": "escape"]
        case .placeholder(let name): return ["kind": "placeholder", "name": name]
        }
    }

    private func issues(_ value: PromptDocument) -> [[String: String]] {
        value.issues.map { ["code": $0.code.rawValue, "severity": $0.severity.rawValue] }
    }

    private func renderFailure(_ error: PromptRenderError) -> [String: Any] {
        switch error {
        case .invalidPrompt: return ["error": "invalid_prompt"]
        case .unsupportedFormat(let version): return ["error": "unsupported_format", "version": version.decimalValue]
        case .missingRequiredValue(let name): return ["error": "required_value_missing", "field": name]
        case .invalidChoiceValue(let name): return ["error": "choice_value_invalid", "field": name]
        case .missingBuiltin(let name): return ["error": "builtin_missing", "name": name.rawValue]
        }
    }

    private func object(_ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw CorpusError.unrecognizedCase }
        return object
    }

    private func strings(_ value: Any) throws -> [String: String] {
        guard let values = value as? [String: String] else { throw CorpusError.unrecognizedCase }
        return values
    }

    private func integer(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c",
              let integer = value as? Int, number.doubleValue == Double(integer) else {
            throw CorpusError.unrecognizedCase
        }
        return integer
    }

    private func keys(_ object: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        let actual = Set(object.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
            throw CorpusError.unrecognizedCase
        }
    }

    private enum CorpusError: Error {
        case unknownCategory, emptyCategory, unrecognizedFile, missingSource
        case invalidUTF8, unrecognizedCase, duplicateConsumption
    }
}
