import Yams

public enum FieldKind: String, Sendable {
    case text
    case multiline
    case choice
}

public struct FieldOption: Equatable, Sendable {
    public let label: String
    public let value: String

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Declarations retain file order; effective fields retain body first-use order.
public struct PromptField: Equatable, Sendable {
    public let name: String
    public let kind: FieldKind
    public let label: String
    public let description: String?
    public let defaultValue: String
    public let options: [FieldOption]
    public let optional: Bool
    public let remember: Bool
    public let isImplicit: Bool

    init(name: String, kind: FieldKind = .text, label: String? = nil, description: String? = nil,
         defaultValue: String = "", options: [FieldOption] = [], optional: Bool = false,
         remember: Bool = true, isImplicit: Bool = false) {
        self.name = name
        self.kind = kind
        self.label = label ?? name
        self.description = description
        self.defaultValue = defaultValue
        self.options = options
        self.optional = optional
        self.remember = remember
        self.isImplicit = isImplicit
    }
}

public struct FrontMatter: Equatable, Sendable {
    public let id: ULID?
    public let title: String
    public let description: String?
    public let tags: [String]
    public let favorite: Bool
    public let isPrivate: Bool
    public let fields: [PromptField]
    public let format: PromptFormatVersion

    init(id: ULID? = nil, title: String, description: String? = nil, tags: [String] = [],
         favorite: Bool = false, isPrivate: Bool = false, fields: [PromptField] = [],
         format: PromptFormatVersion = .current) {
        self.id = id
        self.title = title
        self.description = description
        self.tags = tags
        self.favorite = favorite
        self.isPrivate = isPrivate
        self.fields = fields
        self.format = format
    }
}

/// Invalid documents remain editable through their exact original source/body.
/// The preserved YAML tree is internal: callers cannot mutate Yams' shared tags
/// and bypass validation. Reparse edited source before rendering or writing it.
public struct PromptDocument {
    public let source: String
    public let body: String
    public let frontMatter: FrontMatter
    public let template: Template

    public var issues: [PromptIssue] { PromptValidator.validate(self) }
    public var isReadOnly: Bool { frontMatter.format.isFuture }
    public var canRender: Bool { !isReadOnly && !issues.contains { $0.severity == .error } }

    public var effectiveFields: [PromptField] {
        var declarations = [String: PromptField]()
        for field in frontMatter.fields where declarations[field.name] == nil {
            declarations[field.name] = field
        }
        return template.names.compactMap { name in
            guard !Template.isReserved(name) else { return nil }
            return declarations[name] ?? PromptField(name: name, isImplicit: true)
        }
    }

    let preservedHeader: Node?
    let decodingIssues: [PromptIssue]
    let declarationLocations: [String: PromptIssueLocation]

    init(source: String, body: String, frontMatter: FrontMatter, template: Template,
         preservedHeader: Node? = nil, decodingIssues: [PromptIssue] = [],
         declarationLocations: [String: PromptIssueLocation] = [:]) {
        self.source = source
        self.body = body
        self.frontMatter = frontMatter
        self.template = template
        self.preservedHeader = preservedHeader
        self.decodingIssues = decodingIssues
        self.declarationLocations = declarationLocations
    }
}
