import Foundation

/// A rooted tree used for both library files and app-data files (§4.6).
/// Operations are synchronous. Callers serialize access to a pair of roots.
/// Reads/replacements reject symlinks and nonregular files; all operations
/// reject symlinked parents. Exclusive create treats any existing leaf as occupied.
/// Per-component checks and the atomic-write window are check-then-act: they
/// defend accidents, not a racing local adversary. Unlink bounds deletion;
/// full fd-relative hardening is deferred.
public protocol FileStore {
    func listFiles() throws -> [StoredFile]
    func stamp(at path: String) throws -> FileStamp?
    func read(at path: String) throws -> Data
    /// Complete a same-directory temporary file, then atomically replace the
    /// destination. Create parents; on failure leave the destination intact.
    /// Atomic replacement alone does not promise crash durability.
    func write(_ data: Data, at path: String) throws
    /// Write complete bytes through a same-directory temporary descriptor and
    /// fsync before atomically publishing only if the destination is absent.
    /// Create parents; never follow or replace an occupied leaf, including a
    /// symlink. Throw alreadyExists for any occupied destination. The kernel
    /// applies ordinary-write permissions (0666 & ~umask) without reading or
    /// changing the process-wide mask. The directory entry is not synced, so
    /// this does not promise crash durability.
    func create(_ data: Data, at path: String) throws
    /// The same atomic replacement, with mode 0600 on the temporary file
    /// before writing private bytes or publishing the destination.
    /// Additionally fsync the completed temporary file before rename; a failed
    /// sync fails the write. A best-effort directory fsync after rename also
    /// persists the new entry where the filesystem allows it.
    func writePrivate(_ data: Data, at path: String) throws
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

    // Compare path bytes; this hand-written equality must list every stored property.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stamp == rhs.stamp && lhs.relativePath.utf8.elementsEqual(rhs.relativePath.utf8)
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
        let parts = path.utf8.split(separator: 47, omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= Limits.maxPathBytes,
              !path.utf8.contains(92),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              parts.allSatisfy({ !$0.isEmpty && !$0.elementsEqual([46]) && !$0.elementsEqual([46, 46]) }) else {
            throw FileStoreError.invalidPath
        }
    }
}
