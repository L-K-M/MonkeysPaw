/// Counts and best-guess kind of a clipboard text snapshot for card display.
/// Plain ordered line checks on the split lines; the first matching kind wins.
public struct ClipboardSummary: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case empty
        case diff
        case error
        case link
        case code
        case text
    }

    public let lineCount: Int
    public let characterCount: Int
    public let kind: Kind

    init(_ text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A final newline terminates the last line; it does not add another.
        if lines.last == "" { lines.removeLast() }
        lineCount = lines.count
        characterCount = text.count
        kind = Kind.classify(text, lines: lines)
    }
}

extension ClipboardSummary.Kind {
    static func classify(_ text: String, lines: [String]) -> Self {
        if text.allSatisfy(\.isWhitespace) { return .empty }

        let startsDiff = lines.contains { $0.hasPrefix("diff --git") || $0.hasPrefix("@@ ") }
        let patchLines = lines.count { $0.hasPrefix("+") || $0.hasPrefix("-") }
        let hasMarker = lines.contains {
            $0.hasPrefix("+++") || $0.hasPrefix("---") || $0.hasPrefix("@@")
        }
        if startsDiff || (patchLines >= 3 && hasMarker) { return .diff }

        if text.contains("Traceback") || text.contains("Exception") || text.contains("panic:")
            || text.contains("error:") || text.contains("Error:") || text.contains("fatal:") {
            return .error
        }

        if let line = lines.first, lines.count == 1,
           line.hasPrefix("http://") || line.hasPrefix("https://") {
            return .link
        }

        let nonempty = lines.filter { !$0.allSatisfy(\.isWhitespace) }
        let codeLines = nonempty.count {
            $0.hasPrefix("    ") || $0.hasPrefix("\t") || $0.hasSuffix("{")
                || $0.hasSuffix("}") || $0.hasSuffix(";") || $0.hasSuffix(":")
        }
        if !nonempty.isEmpty, codeLines * 3 >= nonempty.count { return .code }

        return .text
    }
}
