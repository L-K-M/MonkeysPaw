/// The editable projection omits identity, format and advanced metadata.
/// Those stay in the codec's preserved header, shared with the Source draft.
public struct PromptForm: Equatable, Sendable {
    public let title: String
    public let description: String
    public let tags: [String]
    public let isPrivate: Bool
    public let body: String
    public let fieldSettings: [PromptFieldSettings]

    init?(_ document: PromptDocument) {
        guard !document.isReadOnly,
              !document.decodingIssues.contains(where: { $0.severity == .error }) else { return nil }
        title = document.frontMatter.title
        description = document.frontMatter.description ?? ""
        tags = document.frontMatter.tags
        isPrivate = document.frontMatter.isPrivate
        body = document.body
        let used = Set(document.effectiveFields.map(\.name))
        let fields = document.effectiveFields + document.frontMatter.fields.filter { !used.contains($0.name) }
        let declarations = document.preservedHeader?.mapping?.first { PortableYAML.string($0.key) == "fields" }?.value.mapping
        let defaults = Set(declarations?.compactMap { pair -> String? in
            guard pair.value.mapping?.contains(where: { PortableYAML.string($0.key) == "default" }) == true else { return nil }
            return PortableYAML.string(pair.key)
        } ?? [])
        fieldSettings = fields.map { PromptFieldSettings($0, hasDefault: defaults.contains($0.name)) }
    }
}

/// A single-property intent leaves every other header entry untouched.
public enum PromptEdit: Sendable {
    case title(String)
    case description(String)
    case tags([String])
    case isPrivate(Bool)
    case body(String)
    case field(PromptFieldSettings)
}
