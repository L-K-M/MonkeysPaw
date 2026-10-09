/// Snapshots supplied at form-open/repeat invocation. No system state is read.
public struct PromptBuiltinValues: Equatable, Sendable {
    public let clipboard: String?
    public let date: String?
    public let time: String?

    public init(clipboard: String? = nil, date: String? = nil, time: String? = nil) {
        self.clipboard = clipboard
        self.date = date
        self.time = time
    }

    fileprivate func value(_ name: BuiltinName) -> String? {
        switch name {
        case .clipboard: return clipboard
        case .date: return date
        case .time: return time
        }
    }
}

public enum PromptRenderer {
    public static func render(_ document: PromptDocument, values: [String: String] = [:],
                              builtins: PromptBuiltinValues = PromptBuiltinValues()) throws -> String {
        guard !document.isReadOnly else { throw PromptRenderError.unsupportedFormat(document.frontMatter.format) }
        guard document.canRender else { throw PromptRenderError.invalidPrompt }
        var resolved = [String: String]()

        for field in document.effectiveFields {
            let value = values[field.name] ?? field.defaultValue
            guard !value.isEmpty || field.optional else { throw PromptRenderError.missingRequiredValue(field.name) }
            if field.kind == .choice, !value.isEmpty, !field.options.contains(where: { $0.value == value }) {
                throw PromptRenderError.invalidChoiceValue(field.name)
            }
            resolved[field.name] = value
        }
        for name in document.template.builtins {
            guard let value = builtins.value(name) else { throw PromptRenderError.missingBuiltin(name) }
            resolved[name.rawValue] = value
        }

        var result = ""
        for token in document.template.tokens {
            switch token {
            case .literal(let text): result += text
            case .escapedOpener: result += "{{"
            case .placeholder(let name):
                // All names were resolved above; deferred names cannot pass validation.
                guard let value = resolved[name] else { throw PromptRenderError.invalidPrompt }
                result += value
            }
        }
        return result
    }
}

public enum PromptRenderError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidPrompt
    case unsupportedFormat(PromptFormatVersion)
    case missingRequiredValue(String)
    case invalidChoiceValue(String)
    case missingBuiltin(BuiltinName)

    /// Identifiers are available to the form, but error descriptions contain no
    /// template fragments or supplied values, even if a caller prints an error.
    public var description: String {
        switch self {
        case .invalidPrompt: return "Resolve prompt validation errors before rendering."
        case .unsupportedFormat: return "This prompt format cannot be rendered."
        case .missingRequiredValue: return "Fill every required field before rendering."
        case .invalidChoiceValue: return "Select a listed choice value before rendering."
        case .missingBuiltin: return "Supply every builtin snapshot used by this prompt."
        }
    }
}
