#if os(Linux)
import Foundation
import MonkeysPawCore

/// Browsing substitutes defaults and names, including for empty choice fields.
/// Delivery's strict renderer instead requires real field and clipboard values.
enum LinuxLibraryPreview {
    static func text(for document: PromptDocument, now: Date = Date(),
                     timeZone: TimeZone = .current) -> String {
        guard document.canRender else { return document.issues.map(\.message).joined(separator: "\n") }

        var values = [String: String]()
        for field in document.effectiveFields {
            values[field.name] = field.defaultValue.isEmpty ? "{\(field.name)}" : field.defaultValue
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        values[BuiltinName.date.rawValue] = formatter.string(from: now)
        formatter.dateFormat = "HH:mm"
        values[BuiltinName.time.rawValue] = formatter.string(from: now)
        values[BuiltinName.clipboard.rawValue] = "{clipboard}"

        return document.template.tokens.map { token in
            switch token {
            case .literal(let text): return text
            case .escapedOpener: return "{{"
            case .placeholder(let name): return values[name] ?? "{\(name)}"
            }
        }.joined()
    }
}
#endif
