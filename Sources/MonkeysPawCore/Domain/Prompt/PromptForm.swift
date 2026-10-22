/// The editable projection omits identity, format and advanced metadata.
/// Those stay in the codec's preserved header, shared with the Source draft.
public struct PromptForm: Equatable, Sendable {
    public let title: String
    public let description: String
    public let tags: [String]
    public let isPrivate: Bool
    public let body: String

    init?(_ document: PromptDocument) {
        guard !document.isReadOnly,
              !document.decodingIssues.contains(where: { $0.severity == .error }) else { return nil }
        title = document.frontMatter.title
        description = document.frontMatter.description ?? ""
        tags = document.frontMatter.tags
        isPrivate = document.frontMatter.isPrivate
        body = document.body
    }
}

/// A single-property intent leaves every other header entry untouched.
public enum PromptEdit: Sendable {
    case title(String)
    case description(String)
    case tags([String])
    case isPrivate(Bool)
    case body(String)
}
