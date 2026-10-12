import Foundation
import Yams

/// Pure, bounded import mapping. Metadata is retained in its original tree;
/// mapped declarations are added alongside it, never removed from the source.
public enum ImportMapper {
    public static func map(_ data: Data, filename: String) throws -> ImportMappingResult {
        guard data.count <= Limits.importFileCapBytes else { throw ImportSkipReason.fileTooLarge }
        guard let source = PromptUTF8.decode(data) else { throw ImportSkipReason.invalidUTF8 }
        guard let format = ImportFormat.filename(filename) else { throw ImportSkipReason.unsupportedExtension }
        let original = PromptCodec.parse(source, filename: filename)
        var report = ImportMappingReport()
        report.preservedKeys = original.preservedHeader?.mapping?.compactMap { PortableYAML.string($0.key) } ?? []

        if format == .markdown {
            try validate(original)
            report.warnings = original.issues.filter { $0.severity == .warning }.map { .validation($0.code) }
            return ImportMappingResult(document: original, report: report)
        }

        // Reuse the codec's recursive portable-YAML validation and anchor
        // defenses before traversing any imported schema.
        try validate(original)
        guard let header = original.preservedHeader?.mapping else {
            report.warnings = templateWarnings(in: original, format: format)
            return ImportMappingResult(document: original, report: report)
        }
        var mapper = FieldMapper(header: header, bodyNames: original.template.names, report: report)
        if format == .dotprompt { mapper.dotprompt() }
        else { mapper.prompty() }

        var pairs = header.map { ($0.key, $0.value) }
        if !mapper.fields.isEmpty {
            let existing = value("fields", in: header)?.mapping?.map { ($0.key, $0.value) } ?? []
            pairs.removeAll { PortableYAML.string($0.0) == "fields" }
            pairs.append((string("fields"), Node(existing + mapper.fields, Tag(.map), .block)))
        }
        let document = try canonical(pairs: pairs, body: original.body, filename: filename)
        mapper.report.dropped = [.frontMatterPresentation]
        mapper.report.warnings += templateWarnings(in: document, format: format)
        return ImportMappingResult(document: document, report: mapper.report)
    }

    static func validate(_ document: PromptDocument) throws {
        if document.isReadOnly { throw ImportSkipReason.unsupportedFormat(document.frontMatter.format) }
        let errors = document.issues.filter { $0.severity == .error }.map(\.code)
        guard errors.isEmpty else { throw ImportSkipReason.invalidPrompt(errors) }
    }

    /// Identity decisions and generation belong to LibraryService's lock.
    /// This pure transformation changes no body bytes or metadata values.
    static func replacingIdentity(_ id: ULID, in document: PromptDocument,
                                  filename: String) throws -> (document: PromptDocument, presentationLost: Bool) {
        if let node = document.preservedHeader?.mapping.flatMap({ value("id", in: $0) }),
           let literal = PortableYAML.string(node), let mark = node.mark {
            // Yams exposes one-based, header-relative lines and scalar columns.
            // The opening delimiter adds one source line.
            // Common plain/quoted ULIDs can change without rewriting comments,
            // scalar styles, CRLFs, or another occurrence in metadata/body.
            let scalars = document.source.unicodeScalars
            var start = scalars.startIndex
            var line = 1
            while start < scalars.endIndex, line < mark.line + 1 {
                if scalars[start] == "\n" { line += 1 }
                start = scalars.index(after: start)
            }
            for _ in 1..<mark.column where start < scalars.endIndex { start = scalars.index(after: start) }
            for quote in ["", "'", "\""] {
                let token = quote + literal + quote
                guard document.source[start...].hasPrefix(token) else { continue }
                let valueStart = scalars.index(start, offsetBy: quote.unicodeScalars.count)
                let valueEnd = scalars.index(valueStart, offsetBy: literal.unicodeScalars.count)
                let source = String(document.source[..<valueStart]) + id.rawValue + document.source[valueEnd...]
                let parsed = PromptCodec.parse(source, filename: filename)
                if parsed.frontMatter.id == id, parsed.canRender { return (parsed, false) }
            }
        }
        var pairs = document.preservedHeader?.mapping?.filter { PortableYAML.string($0.key) != "id" }
            .map { ($0.key, $0.value) } ?? []
        pairs.insert((string("id"), string(id.rawValue)), at: 0)
        // Escaped or block-style identities need the canonical writer. Report
        // its presentation loss instead of claiming an exact source copy.
        return (try canonical(pairs: pairs, body: document.body, filename: filename), true)
    }

    private static func canonical(pairs: [(Node, Node)], body: String,
                                  filename: String) throws -> PromptDocument {
        let draft = PromptDocument(source: "", body: body,
            frontMatter: FrontMatter(title: (filename as NSString).deletingPathExtension),
            template: Template.parse(body), preservedHeader: Node(pairs, Tag(.map), .block))
        // Reparse the canonical source so generated declarations and native
        // keys use the same validation and ordering as ordinary saves.
        let source: String
        do { source = try PromptCodec.write(draft) }
        catch PromptWriteError.sourceTooLarge { throw ImportSkipReason.convertedTooLarge }
        catch { throw ImportSkipReason.library(.operationFailed) }
        let parsed = PromptCodec.parse(source, filename: filename)
        try validate(parsed)
        return parsed
    }

    private static func templateWarnings(in document: PromptDocument, format: ImportFormat) -> [ImportWarning] {
        let issues = document.issues.filter { $0.severity == .warning }
        let validation = issues.filter { $0.code != .invalidPlaceholder }.map { ImportWarning.validation($0.code) }
        var offsets = Set(issues.compactMap { issue -> Int? in
            if issue.code == .invalidPlaceholder, case .body(let offset) = issue.location { return offset }
            return nil
        })
        if format == .prompty {
            let bytes = Array(document.body.utf8)
            for offset in bytes.indices.dropLast() where bytes[offset] == 123
                && (bytes[offset + 1] == 37 || bytes[offset + 1] == 35) {
                offsets.insert(offset)
            }
        }
        return validation + offsets.sorted().map { .unsupportedTemplate(format, byteOffset: $0) }
    }

    private struct FieldMapper {
        let header: Node.Mapping
        let bodyNames: Set<String>
        var report: ImportMappingReport
        var fields: [(Node, Node)] = []
        private var used: Set<String> = []

        init(header: Node.Mapping, bodyNames: [String], report: ImportMappingReport) {
            self.header = header
            self.bodyNames = Set(bodyNames)
            self.report = report
            used = Set(value("fields", in: header)?.mapping?.compactMap { PortableYAML.string($0.key) } ?? [])
        }

        mutating func dotprompt() {
            guard let inputNode = value("input", in: header) else { return }
            guard let input = inputNode.mapping, let schema = value("schema", in: input) else {
                report.warnings.append(.unsupportedInput("input.schema"))
                return
            }
            let defaults = value("default", in: input)?.mapping
            guard let mapping = schema.mapping else {
                report.warnings.append(.unsupportedInput("input.schema"))
                return
            }
            if let type = value("type", in: mapping).flatMap(PortableYAML.string) {
                guard type == "object", let properties = value("properties", in: mapping)?.mapping else {
                    report.warnings.append(.unsupportedInput("input.schema"))
                    return
                }
                let required = value("required", in: mapping)?.sequence?.compactMap { PortableYAML.string($0) } ?? []
                for pair in properties {
                    guard let name = PortableYAML.string(pair.key) else { continue }
                    mapDeclaration(pair.value, name: name, source: "input.schema.properties." + name,
                                   fallback: defaults.flatMap { value(name, in: $0) },
                                   fallbackSource: "input.default." + name,
                                   optional: !required.contains(name))
                }
                return
            }
            for pair in mapping {
                guard let key = PortableYAML.string(pair.key) else {
                    report.warnings.append(.unsupportedInput("input.schema"))
                    continue
                }
                let source = "input.schema." + key
                if pair.value.mapping != nil {
                    mapDeclaration(pair.value, name: key, source: source,
                                   fallback: defaults.flatMap { value(key, in: $0) },
                                   fallbackSource: "input.default." + key)
                    continue
                }
                let pico = PicoName(key)
                guard canMap(pico.name, source: source) else { continue }
                let definition: Node
                if pico.kind == "enum" {
                    definition = Node([(string("type"), string("string")),
                                       (string("enum"), pair.value)], Tag(.map), .block)
                } else if pico.kind == nil, let scalar = PortableYAML.string(pair.value) {
                    let parts = scalar.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.first?.trimmingCharacters(in: .whitespaces) == "string" else {
                        report.warnings.append(.unsupportedInput(source))
                        continue
                    }
                    var properties = [(string("type"), string("string"))]
                    if parts.count == 2 {
                        properties.append((string("description"), string(parts[1].trimmingCharacters(in: .whitespaces))))
                    }
                    definition = Node(properties, Tag(.map), .block)
                } else {
                    report.warnings.append(.unsupportedInput(source))
                    continue
                }
                mapDeclaration(definition, name: pico.name, source: source,
                               fallback: defaults.flatMap { value(pico.name, in: $0) },
                               fallbackSource: "input.default." + pico.name,
                               optional: pico.optional, description: pico.description)
            }
        }

        mutating func prompty() {
            let samples = value("sample", in: header)?.mapping
            let inputs = value("inputs", in: header)
            var declared = Set<String>()
            if let mapping = inputs?.mapping {
                for pair in mapping {
                    guard let name = PortableYAML.string(pair.key) else {
                        report.warnings.append(.unsupportedInput("inputs"))
                        continue
                    }
                    declared.insert(name)
                    mapPrompty(pair.value, name: name, source: "inputs." + name, samples: samples)
                }
            } else if let sequence = inputs?.sequence {
                for (index, entry) in sequence.enumerated() {
                    let source = "inputs[\(index)]"
                    guard let mapping = entry.mapping,
                          let name = value("name", in: mapping).flatMap(PortableYAML.string) else {
                        report.warnings.append(.unsupportedInput(source))
                        continue
                    }
                    declared.insert(name)
                    mapPrompty(entry, name: name, source: source, samples: samples)
                }
            } else if inputs != nil {
                report.warnings.append(.unsupportedInput("inputs"))
                return
            }
            // Published v1 examples often declare only sample data. Apply it
            // to native implicit body fields, without overriding an explicit
            // unsupported input type or turning unused samples into controls.
            for pair in samples ?? Node.Mapping([], Tag(.map)) {
                guard let name = PortableYAML.string(pair.key), bodyNames.contains(name),
                      !declared.contains(name) else { continue }
                let source = "sample." + name
                mapDeclaration(Node([(string("type"), string("string"))], Tag(.map), .block),
                               name: name, source: source, fallback: pair.value, fallbackSource: source)
            }
        }

        private mutating func mapPrompty(_ node: Node, name: String, source: String, samples: Node.Mapping?) {
            let localSample = node.mapping.flatMap { value("sample", in: $0) }
            mapDeclaration(node, name: name, source: source,
                           fallback: localSample ?? samples.flatMap { value(name, in: $0) },
                           fallbackSource: localSample == nil ? "sample." + name : source + ".sample")
        }

        private mutating func canMap(_ name: String, source: String) -> Bool {
            guard Template.isValidName(name) else { report.warnings.append(.invalidName(source)); return false }
            guard !Template.isReserved(name) else { report.warnings.append(.reservedName(name)); return false }
            guard !used.contains(name) else { report.warnings.append(.fieldCollision(name)); return false }
            return true
        }

        private mutating func mapDeclaration(_ node: Node, name: String, source: String,
                                             fallback: Node?, fallbackSource: String,
                                             optional: Bool = false, description: String? = nil) {
            guard canMap(name, source: source) else { return }
            guard let properties = node.mapping,
                  value("type", in: properties).flatMap(PortableYAML.string) == "string" else {
                report.warnings.append(.unsupportedInput(source))
                return
            }
            var pairs: [(Node, Node)] = []
            let kind: FieldKind
            var choices: [String] = []
            if let options = value("enum", in: properties) {
                guard let sequence = options.sequence, !sequence.isEmpty else {
                    report.warnings.append(.invalidOptions(source)); return
                }
                choices = sequence.compactMap { PortableYAML.string($0) }
                guard choices.count == sequence.count else { report.warnings.append(.invalidOptions(source)); return }
                kind = .choice
                pairs.append((string("options"), options))
            } else { kind = .text }
            pairs.insert((string("type"), string(kind.rawValue)), at: 0)

            let explicitDefault = value("default", in: properties)
            func usableDefault(_ node: Node?) -> Node? {
                guard let node, let text = PortableYAML.string(node),
                      kind != .choice || choices.contains(text) else { return nil }
                return node
            }
            var defaultNode = usableDefault(explicitDefault)
            var defaultSource = defaultNode == nil ? nil : source + ".default"
            if defaultNode == nil {
                defaultNode = usableDefault(fallback)
                defaultSource = defaultNode == nil ? nil : fallbackSource
                if explicitDefault != nil || (fallback != nil && defaultNode == nil) {
                    report.warnings.append(.invalidDefault(source))
                    guard defaultNode != nil else { return }
                }
            }
            if let defaultNode {
                pairs.append((string("default"), defaultNode))
            }
            if let node = value("description", in: properties) {
                guard PortableYAML.string(node) != nil else { report.warnings.append(.invalidDescription(source)); return }
                pairs.append((string("description"), node))
            } else if let description { pairs.append((string("description"), string(description))) }
            let isOptional = optional || value("required", in: properties).flatMap(PortableYAML.boolean) == false
            if isOptional { pairs.append((string("optional"), Node("true", Tag(.bool)))) }
            fields.append((string(name), Node(pairs, Tag(.map), .block)))
            used.insert(name)
            report.mappings.append(ImportFieldMapping(sourceKey: source, fieldName: name, kind: kind,
                defaultSource: defaultSource))
        }
    }

    private struct PicoName {
        let name: String
        let optional: Bool
        let kind: String?
        let description: String?

        init(_ key: String) {
            let parts = key.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false)
            let base = String(parts[0])
            optional = base.hasSuffix("?")
            name = optional ? String(base.dropLast()) : base
            if parts.count == 2, parts[1].hasSuffix(")") {
                let annotation = parts[1].dropLast().split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                kind = annotation[0].trimmingCharacters(in: .whitespaces)
                description = annotation.count == 2 ? annotation[1].trimmingCharacters(in: .whitespaces) : nil
            } else {
                kind = parts.count == 1 ? nil : "unsupported"
                description = nil
            }
        }
    }

    private static func value(_ key: String, in mapping: Node.Mapping) -> Node? {
        mapping.first { PortableYAML.string($0.key) == key }?.value
    }

    private static func string(_ text: String) -> Node { Node(text, Tag(.str)) }
}
