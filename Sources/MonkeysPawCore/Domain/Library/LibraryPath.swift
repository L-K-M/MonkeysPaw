enum LibraryPath {
    static func validate(_ path: String) throws {
        try FileStorePath.validate(path)
        guard isPrompt(path) else { throw LibraryError.invalidPromptPath }
    }

    static func isPrompt(_ path: String) -> Bool {
        // A slash followed by a combining mark shares a grapheme. Folder
        // boundaries are slash scalars, including for import destinations.
        let parts = path.unicodeScalars.split(separator: "/").map { String(String.UnicodeScalarView($0)) }
        guard let filename = parts.last, filename.hasSuffix(".md"),
              !parts.contains(where: { $0.utf8.first == 95 }),
              !parts.dropLast().contains(where: { $0.utf8.first == 46 }) else { return false }
        return path != "README.md"
    }

    static func filename(_ path: String) -> String {
        let scalars = path.unicodeScalars
        let start = scalars.lastIndex(of: "/").map { scalars.index(after: $0) } ?? scalars.startIndex
        return String(path[start...])
    }
}
