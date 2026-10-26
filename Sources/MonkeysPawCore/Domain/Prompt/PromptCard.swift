/// The card projection of a document: body structure for display, not a new
/// grammar. Placeholders matching an effective field become field segments
/// with a per-name occurrence index from zero; builtins stay builtin. Escaped
/// openers and deferred or unknown placeholders flatten to the literal text
/// the user typed, merging with adjacent literal tokens.
public struct PromptCard: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        case text(String)
        case field(name: String, label: String, kind: FieldKind, occurrence: Int)
        case builtin(BuiltinName)
    }

    public let segments: [Segment]
    public var hasFields: Bool {
        segments.contains { if case .field = $0 { return true }; return false }
    }

    init(document: PromptDocument) {
        var fields = [String: PromptField]()
        for field in document.effectiveFields where fields[field.name] == nil {
            fields[field.name] = field
        }
        var segments: [Segment] = []
        var occurrences = [String: Int]()

        func text(_ piece: String) {
            if case .text(let prior) = segments.last {
                segments[segments.count - 1] = .text(prior + piece)
            } else {
                segments.append(.text(piece))
            }
        }

        for token in document.template.tokens {
            switch token {
            case .literal(let piece):
                text(piece)
            case .escapedOpener:
                text("{{")
            case .placeholder(let name):
                if let builtin = BuiltinName(rawValue: name) {
                    segments.append(.builtin(builtin))
                } else if let field = fields[name] {
                    let occurrence = occurrences[name, default: 0]
                    occurrences[name] = occurrence + 1
                    segments.append(.field(name: name, label: field.label,
                                           kind: field.kind, occurrence: occurrence))
                } else {
                    text("{{\(name)}}")
                }
            }
        }
        self.segments = segments
    }
}
