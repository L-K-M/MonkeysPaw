import Yams

extension PromptCodec {
    /// Patch only changed properties; untouched optional keys and nested metadata survive.
    static func editingField(_ settings: PromptFieldSettings, in document: PromptDocument,
                             filename: String) throws -> PromptDocument {
        guard let current = PromptForm(document)?.fieldSettings.first(where: { $0.name == settings.name }),
              settings.validationIssue == nil else { throw PromptWriteError.invalidPrompt }
        var header = document.preservedHeader?.mapping?.map { ($0.key, $0.value) } ?? []
        let fieldsIndex = header.firstIndex { PortableYAML.string($0.0) == "fields" }
        var fields = fieldsIndex.flatMap { header[$0].1.mapping?.map { ($0.key, $0.value) } } ?? []
        let fieldIndex = fields.firstIndex { PortableYAML.string($0.0) == settings.name }
        var properties = fieldIndex.flatMap { fields[$0].1.mapping?.map { ($0.key, $0.value) } } ?? []
        let originalOptions = properties.first { PortableYAML.string($0.0) == "options" }?.1.sequence
        var changed = false

        func equal(_ left: String?, _ right: String?) -> Bool {
            switch (left, right) {
            case (.none, .none): return true
            case (.some(let left), .some(let right)): return left.utf8.elementsEqual(right.utf8)
            default: return false
            }
        }
        func set(_ key: String, _ value: Node?) {
            changed = true
            if let index = properties.firstIndex(where: { PortableYAML.string($0.0) == key }) {
                if let value { properties[index].1 = value }
                else { properties.remove(at: index) }
            } else if let value { properties.append((Node(key, Tag(.str)), value)) }
        }
        func string(_ value: String?) -> Node? { value.map { Node($0, Tag(.str)) } }

        if settings.kind != current.kind {
            set("type", Node(settings.kind.rawValue, Tag(.str)))
            if settings.kind != .choice { set("options", nil) }
        }
        if !equal(settings.label, current.label) { set("label", string(settings.label)) }
        if !equal(settings.description, current.description) { set("description", string(settings.description)) }
        if !equal(settings.defaultValue, current.defaultValue) { set("default", string(settings.defaultValue)) }
        if settings.optional != current.optional { set("optional", Node(settings.optional ? "true" : "false", Tag(.bool))) }
        if settings.remember != current.remember { set("remember", Node(settings.remember ? "true" : "false", Tag(.bool))) }

        let optionsUnchanged = settings.options.count == current.options.count && zip(settings.options, current.options).allSatisfy {
            equal($0.label, $1.label) && equal($0.value, $1.value) && $0.originalIndex == $1.originalIndex
        }
        if settings.kind == .choice, !optionsUnchanged {
            let options = settings.options.map { option -> Node in
                let original = option.originalIndex.flatMap { index in
                    originalOptions.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                }
                if original?.mapping == nil, equal(option.label, option.value) {
                    return Node(option.value, Tag(.str))
                }
                var pairs = original?.mapping?.map { ($0.key, $0.value) } ?? []
                for (key, value) in [("label", option.label), ("value", option.value)] {
                    if let index = pairs.firstIndex(where: { PortableYAML.string($0.0) == key }) {
                        pairs[index].1 = Node(value, Tag(.str))
                    } else { pairs.append((Node(key, Tag(.str)), Node(value, Tag(.str)))) }
                }
                return Node(pairs, Tag(.map), .block)
            }
            set("options", Node(options, Tag(.seq), .block))
        }
        guard changed else { return document }

        let declaration = Node(properties, Tag(.map), .block)
        if let fieldIndex { fields[fieldIndex].1 = declaration }
        else { fields.append((Node(settings.name, Tag(.str)), declaration)) }
        let declarations = Node(fields, Tag(.map), .block)
        if let fieldsIndex { header[fieldsIndex].1 = declarations }
        else { header.append((Node("fields", Tag(.str)), declarations)) }
        let headerDocument = PromptDocument(source: "", body: "", frontMatter: document.frontMatter,
            template: Template.parse(""), preservedHeader: Node(header, Tag(.map), .block))
        let source = try write(headerDocument) + document.body
        guard source.utf8.count <= Limits.maxPromptBytes else { throw PromptWriteError.sourceTooLarge }
        let result = parse(source, filename: filename)
        guard !result.decodingIssues.contains(where: { $0.severity == .error }) else { throw PromptWriteError.invalidPrompt }
        return result
    }
}
