import Foundation

/// A rooted tree used for both library files and app-data files (§4.6).
/// Operations are synchronous. Callers serialize access to a pair of roots.
/// Drivers reject symlinks and nonregular files, including in path components.
public protocol FileStore {
    func listFiles() throws -> [StoredFile]
    func stamp(at path: String) throws -> FileStamp?
    func read(at path: String) throws -> Data
    /// Complete a same-directory temporary file, then atomically replace the
    /// destination. Create parents; on failure leave the destination intact.
    func write(_ data: Data, at path: String) throws
    func delete(at path: String) throws
    /// Move a regular file, creating parents. Never replace a destination.
    func move(from source: String, to destination: String) throws
}

/// Only equality is meaningful outside a driver. Include file incarnation in
/// the token, so delete/recreate with the same size and mtime is a change.
public struct FileStamp: Equatable, Sendable, CustomStringConvertible {
    private let token: String

    public init(_ token: String) { self.token = token }
    public var description: String { "<file stamp>" }
}

public struct StoredFile: Equatable, Sendable {
    public let relativePath: String
    public let stamp: FileStamp

    public init(relativePath: String, stamp: FileStamp) {
        self.relativePath = relativePath
        self.stamp = stamp
    }
}

public enum FileStoreError: String, Error, Sendable {
    case invalidPath
    case outsideRoot
    case invalidRoot
    case notFound
    case notRegularFile
    case alreadyExists
    case ioFailure
}

/// Lexical validation shared with per-OS drivers. Root containment and symlink
/// checks still belong to the driver. This is not M5's sync path policy.
public enum FileStorePath {
    public static func validate(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= Limits.maxPathBytes,
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw FileStoreError.invalidPath
        }
    }
}
