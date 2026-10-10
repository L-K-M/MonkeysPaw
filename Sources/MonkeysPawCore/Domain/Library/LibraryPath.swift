enum LibraryPath {
    static func validate(_ path: String) throws {
        try FileStorePath.validate(path)
        guard isPrompt(path) else { throw LibraryError.invalidPromptPath }
    }

    static func isPrompt(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard let filename = parts.last, filename.hasSuffix(".md"),
              !parts.contains(where: { $0.hasPrefix("_") }),
              !parts.dropLast().contains(where: { $0.hasPrefix(".") }) else { return false }
        return path != "README.md"
    }

    static func filename(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }
}
