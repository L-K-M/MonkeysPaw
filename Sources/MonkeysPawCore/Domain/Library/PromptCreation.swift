import Foundation

/// A query supplies a title, never a directory or an ignored library entry.
public enum PromptCreation {
    public static func relativePath(title: String, now: Date) -> String {
        let cleaned = title.unicodeScalars.map { scalar -> String in
            if scalar == "/" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar) { return " " }
            return String(scalar)
        }.joined()
        let name = cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "._")))
        let path = name + ".md"
        guard !name.isEmpty, path != "README.md", path.utf8.count <= Limits.promptFilenameMaxBytes,
              (try? FileStorePath.validate(path)) != nil else {
            return "Prompt \(Int(now.timeIntervalSince1970)).md"
        }
        return path
    }
}
