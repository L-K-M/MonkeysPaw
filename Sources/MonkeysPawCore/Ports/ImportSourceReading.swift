import Foundation

/// Native chooser/drop sources, independent of the rooted library FileStore.
/// Operations run on BackgroundWork and sanitize filesystem errors.
public protocol ImportSourceReading {
    /// Recursively enumerate files relative to the selected absolute folder.
    /// Never follow symlinks, including the root or any ancestor. Include a
    /// symlink/nonregular entry for reporting, without descending into it.
    /// Enumeration failure throws; it must not silently return a partial list.
    func listFiles(in folderPath: String) throws -> [ImportSourceEntry]

    /// Reject symlinked components and nonregular leaves. Read at most
    /// maximumBytes + 1 bytes, refusing overflow with .fileTooLarge, even
    /// when a file grows after stat inspection. Return only complete bytes.
    func readFile(at path: String, maximumBytes: Int) throws -> Data
}

public enum ImportSourceKind: String, Sendable {
    case regularFile, symbolicLink, other
}

public struct ImportSourceEntry: Equatable, Sendable {
    public let relativePath: String
    public let kind: ImportSourceKind

    public init(relativePath: String, kind: ImportSourceKind = .regularFile) {
        self.relativePath = relativePath
        self.kind = kind
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.relativePath.utf8.elementsEqual(rhs.relativePath.utf8)
    }
}

public enum ImportSourceError: String, Error, Sendable {
    case invalidPath, notFound, notRegularFile, symbolicLink, fileTooLarge, ioFailure
}
