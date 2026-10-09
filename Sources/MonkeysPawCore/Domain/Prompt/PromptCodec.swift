import Foundation
import Yams

public enum PromptCodec {
    /// Filename is a basename used only for title fallback; no path or file is read.
    public static func parse(_ source: String, filename: String) -> PromptDocument {
        let title = (filename as NSString).deletingPathExtension
        guard source.utf8.count <= Limits.maxPromptBytes else {
            return PromptDocument(source: source, body: source,
                                  frontMatter: FrontMatter(title: title, isPrivate: true),
                                  template: Template.parse(""), decodingIssues: [PromptIssue(.sourceTooLarge)])
        }
        let parts = split(source)
        let template = Template.parse(parts.body)
        guard let header = parts.header else {
            let issues = parts.unclosed ? [PromptIssue(.unclosedFrontMatter,
                                                       at: .frontMatter(line: 1, column: 1))] : []
            return PromptDocument(source: source, body: parts.body,
                                  frontMatter: FrontMatter(title: title, isPrivate: parts.unclosed),
                                  template: template, decodingIssues: issues)
        }

        do {
            let parser = try Parser(yaml: header, resolver: PortableYAML.syntaxResolver, encoding: .utf8,
                                    duplicateKeyPolicy: .deferAnchoredKeys)
            let root = try parser.singleRoot()
            var decodingIssues = [PromptIssue]()
            // Deferred key comparisons are safe only after rejecting anchors.
            // Node's anchor references are weak; retain Parser through that check.
            let normalized = withExtendedLifetime(parser) {
                root.map { PortableYAML.normalize($0, issues: &decodingIssues) }
            }
            let mapping: Node.Mapping
            if let value = normalized?.mapping {
                mapping = value
            } else if normalized == nil || (normalized?.tag.rawValue == Tag.Name.null.rawValue
                                             && normalized?.scalar?.string == "") {
                mapping = Node.Mapping([], Tag(.map))
            } else {
                decodingIssues.append(PromptIssue(.frontMatterNotMapping, at: normalized.flatMap(PortableYAML.location)))
                return PromptDocument(source: source, body: parts.body,
                                      frontMatter: FrontMatter(title: title, isPrivate: true),
                                      template: template, decodingIssues: decodingIssues)
            }
            var decoder = FrontMatterDecoder(mapping: mapping, issues: decodingIssues)
            let metadata = decoder.decode(fallbackTitle: title)
            return PromptDocument(source: source, body: parts.body, frontMatter: metadata,
                                  template: template, preservedHeader: .mapping(mapping),
                                  decodingIssues: decoder.issues, declarationLocations: decoder.locations)
        } catch {
            // Never retain, print or forward error.description: Yams embeds YAML.
            return PromptDocument(source: source, body: parts.body,
                                  frontMatter: FrontMatter(title: title, isPrivate: true),
                                  template: template, decodingIssues: [yamlIssue(error)])
        }
    }

    /// Returns content only. Atomic writes/history/id assignment belong to stores.
    public static func write(_ document: PromptDocument) throws -> String {
        guard !document.isReadOnly else { throw PromptWriteError.unsupportedFormat(document.frontMatter.format) }
        guard !document.issues.contains(where: { $0.severity == .error }) else { throw PromptWriteError.invalidPrompt }
        guard let mapping = document.preservedHeader?.mapping else { return document.body }
        var ordered = [(Node, Node)]()
        for name in knownKeys {
            for pair in mapping where PortableYAML.string(pair.key) == name {
                var value = pair.value
                if name == "id", let id = document.frontMatter.id { value = Node(id.rawValue, Tag(.str)) }
                if name == "format" { value = Node(document.frontMatter.format.decimalValue, Tag(.int)) }
                ordered.append((pair.key, value))
            }
        }
        ordered += mapping.filter { pair in
            guard let key = PortableYAML.string(pair.key) else { return true }
            return !knownKeys.contains(key)
        }.map { ($0.key, $0.value) }

        let yaml: String
        do {
            yaml = try serialize(node: PortableYAML.canonical(Node(ordered, Tag(.map), .block)),
                                 indent: 2, width: -1, allowUnicode: true, sortKeys: false)
        } catch {
            throw PromptWriteError.serializationFailed
        }
        let result = "---\n" + yaml + "---\n" + document.body
        guard result.utf8.count <= Limits.maxPromptBytes else { throw PromptWriteError.sourceTooLarge }
        return result
    }

    private static let knownKeys = ["id", "title", "description", "tags", "favorite", "private", "fields", "format"]

    private struct SourceParts {
        let header: String?
        let body: String
        let unclosed: Bool
    }

    private static func split(_ source: String) -> SourceParts {
        let bytes = Array(source.utf8)
        func line(at start: Int) -> (contentEnd: Int, next: Int) {
            var end = start
            while end < bytes.count, bytes[end] != 10 { end += 1 }
            let contentEnd = end < bytes.count && end > start && bytes[end - 1] == 13 ? end - 1 : end
            return (contentEnd, end < bytes.count ? end + 1 : end)
        }
        let first = line(at: 0)
        guard bytes[0..<first.contentEnd].elementsEqual([45, 45, 45]) else {
            return SourceParts(header: nil, body: source, unclosed: false)
        }
        let headerStart = first.next
        var start = headerStart
        while start < bytes.count {
            let current = line(at: start)
            if bytes[start..<current.contentEnd].elementsEqual([45, 45, 45]) {
                return SourceParts(header: String(decoding: bytes[headerStart..<start], as: UTF8.self),
                                   body: String(decoding: bytes[current.next...], as: UTF8.self), unclosed: false)
            }
            start = current.next
        }
        return SourceParts(header: nil, body: String(decoding: bytes[headerStart...], as: UTF8.self), unclosed: true)
    }

    private static func yamlIssue(_ error: Error) -> PromptIssue {
        guard let error = error as? YamlError else { return PromptIssue(.invalidYAML) }
        switch error {
        case .duplicatedKeysInMapping(_, let context):
            return PromptIssue(.duplicateKey, at: .frontMatter(line: context.mark.line + 1, column: context.mark.column))
        case .scanner(_, _, let mark, _), .parser(_, _, let mark, _), .composer(_, _, let mark, _):
            return PromptIssue(.invalidYAML, at: .frontMatter(line: mark.line + 1, column: mark.column))
        default: return PromptIssue(.invalidYAML)
        }
    }
}

public enum PromptWriteError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidPrompt
    case unsupportedFormat(PromptFormatVersion)
    case serializationFailed
    case sourceTooLarge

    public var description: String {
        switch self {
        case .invalidPrompt: return "Resolve prompt validation errors before writing."
        case .unsupportedFormat: return "This prompt format cannot be rewritten."
        case .serializationFailed: return "The front matter could not be serialized."
        case .sourceTooLarge: return "Canonical content exceeds the prompt size limit."
        }
    }
}

private struct FrontMatterDecoder {
    let mapping: Node.Mapping
    var issues: [PromptIssue]
    private(set) var locations = [String: PromptIssueLocation]()

    mutating func decode(fallbackTitle: String) -> FrontMatter {
        var id: ULID?
        if let node = value("id", in: mapping) {
            id = PortableYAML.string(node).flatMap(ULID.init)
            if id == nil { add(.invalidID, node) }
        }
        let title = string("title", in: mapping, error: .invalidMetadataType) ?? fallbackTitle
        let description = string("description", in: mapping, error: .invalidMetadataType)
        var tags = [String]()
        if let node = value("tags", in: mapping) {
            if let sequence = node.sequence {
                tags = sequence.compactMap { PortableYAML.string($0) }
                if tags.count != sequence.count { add(.invalidMetadataType, node) }
            } else {
                add(.invalidMetadataType, node)
            }
        }
        let favorite = boolean("favorite", in: mapping, defaultValue: false,
                               invalidValue: false, error: .invalidMetadataType)
        let isPrivate = boolean("private", in: mapping, defaultValue: false,
                                invalidValue: true, error: .invalidMetadataType)
        var format = PromptFormatVersion.current
        if let node = value("format", in: mapping) {
            if let version = PortableYAML.formatVersion(node) {
                format = version
                if version.isFuture { add(.unsupportedFormat, node) }
            } else {
                add(.invalidFormat, node)
            }
        }
        let fields = declarations()
        return FrontMatter(id: id, title: title, description: description, tags: tags,
                           favorite: favorite, isPrivate: isPrivate, fields: fields, format: format)
    }

    private mutating func declarations() -> [PromptField] {
        guard let node = value("fields", in: mapping) else { return [] }
        guard let mapping = node.mapping else { add(.invalidFieldDeclaration, node); return [] }
        var fields = [PromptField]()
        for pair in mapping {
            guard let name = PortableYAML.string(pair.key) else { add(.invalidFieldName, pair.key); continue }
            if let location = PortableYAML.location(pair.key) { locations[name] = location }
            if !Template.isValidName(name) { add(.invalidFieldName, pair.key) }
            if Template.isReserved(name) { add(.reservedFieldName, pair.key) }
            guard let properties = pair.value.mapping else {
                add(.invalidFieldDeclaration, pair.value)
                fields.append(PromptField(name: name))
                continue
            }
            var kind = FieldKind.text
            if let node = value("type", in: properties) {
                if let decoded = PortableYAML.string(node).flatMap(FieldKind.init(rawValue:)) {
                    kind = decoded
                } else {
                    add(.unknownFieldType, node)
                }
            }
            let label = string("label", in: properties, error: .invalidFieldProperty) ?? name
            let description = string("description", in: properties, error: .invalidFieldProperty)
            let defaultValue = string("default", in: properties, error: .invalidFieldDefault) ?? ""
            let optional = boolean("optional", in: properties, defaultValue: false,
                                   invalidValue: false, error: .invalidFieldBoolean)
            let remember = boolean("remember", in: properties, defaultValue: true,
                                   invalidValue: false, error: .invalidFieldBoolean)
            let options = options(kind: kind, properties: properties, declaration: pair.value)
            if kind == .choice, let node = value("default", in: properties),
               let defaultString = PortableYAML.string(node), !options.contains(where: { $0.value == defaultString }) {
                add(.invalidFieldDefault, node)
            }
            fields.append(PromptField(name: name, kind: kind, label: label, description: description,
                                      defaultValue: defaultValue, options: options, optional: optional, remember: remember))
        }
        return fields
    }

    private mutating func options(kind: FieldKind, properties: Node.Mapping, declaration: Node) -> [FieldOption] {
        guard let node = value("options", in: properties) else {
            if kind == .choice { add(.invalidFieldOptions, declaration) }
            return []
        }
        guard kind == .choice, let sequence = node.sequence, !sequence.isEmpty else {
            add(.invalidFieldOptions, node)
            return []
        }
        var options = [FieldOption]()
        for entry in sequence {
            if let text = PortableYAML.string(entry) {
                options.append(FieldOption(label: text, value: text))
            } else if let mapping = entry.mapping,
                      let label = PortableYAML.string(value("label", in: mapping)),
                      let value = PortableYAML.string(value("value", in: mapping)) {
                options.append(FieldOption(label: label, value: value))
            } else {
                add(.invalidFieldOptions, entry)
            }
        }
        return options
    }

    private func value(_ key: String, in mapping: Node.Mapping) -> Node? {
        // Do not choose one value from an ambiguous mapping. The recursive
        // validator already reports duplicate keys, and writing is blocked.
        let matches = mapping.filter { PortableYAML.string($0.key) == key }
        return matches.count == 1 ? matches[0].value : nil
    }

    private mutating func string(_ key: String, in mapping: Node.Mapping, error: PromptIssueCode) -> String? {
        guard let node = value(key, in: mapping) else { return nil }
        guard let string = PortableYAML.string(node) else { add(error, node); return nil }
        return string
    }

    private mutating func boolean(_ key: String, in mapping: Node.Mapping, defaultValue: Bool,
                                  invalidValue: Bool, error: PromptIssueCode) -> Bool {
        guard let node = value(key, in: mapping) else {
            return mapping.contains { PortableYAML.string($0.key) == key } ? invalidValue : defaultValue
        }
        guard let boolean = PortableYAML.boolean(node) else { add(error, node); return invalidValue }
        return boolean
    }

    private mutating func add(_ code: PromptIssueCode, _ node: Node) {
        issues.append(PromptIssue(code, at: PortableYAML.location(node)))
    }
}
