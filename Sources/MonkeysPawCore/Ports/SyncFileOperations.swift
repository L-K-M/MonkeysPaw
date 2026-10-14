import Foundation

public enum SyncFileMode: Equatable, Sendable, Codable {
    case readOnly
    /// Ordinary writable permissions, 0666 & ~umask, without changing umask.
    case normal
}

/// A checked read under the library mutation lock. Matching requires both the
/// incarnation stamp and exact bytes immediately before the native mutation.
public enum SyncFileExpectation: Sendable, CustomStringConvertible, CustomReflectable {
    case absent
    case matching(stamp: FileStamp, bytes: Data)

    public var description: String { "<sync file expectation>" }
    public var customMirror: Mirror { Mirror(self, children: ["expectation": description]) }
}

public struct SyncFilePublication: Sendable, CustomStringConvertible, CustomReflectable {
    /// Losing bytes retained before replacement, for journaled recovery/rescue.
    public let displacedBytes: Data?

    public init(displacedBytes: Data?) { self.displacedBytes = displacedBytes }
    public var description: String { "<sync publication>" }
    public var customMirror: Mirror { Mirror(self, children: ["publication": description]) }
}

public enum SyncFileFailureCode: String, Sendable {
    case changed, invalidPath, notFound, occupied, ioFailure, durabilityFailed
    /// Permanent consistency failure; retrying I/O cannot resolve it.
    case invalidState
}

public enum SyncFileMutationEffect: Equatable, Sendable {
    case unchanged
    /// A mutation occurred, but its crash durability could not be confirmed.
    case applied
}

/// A post-publication flush failure is not an unchanged file. Drivers return
/// its applied effect and retained displaced bytes, never underlying error text.
public struct SyncFileOperationError: Error, Sendable, CustomStringConvertible, CustomReflectable {
    public let code: SyncFileFailureCode
    public let effect: SyncFileMutationEffect
    public let displacedBytes: Data?

    public init(_ code: SyncFileFailureCode, effect: SyncFileMutationEffect = .unchanged,
                displacedBytes: Data? = nil) {
        self.code = code
        self.effect = effect
        self.displacedBytes = displacedBytes
    }

    public var description: String { "Sync file operation failed: " + code.rawValue }
    public var customMirror: Mirror { Mirror(self, children: ["code": code.rawValue]) }
}

/// Optional native capability beyond FileStore; it does not alter that port.
/// Use the same rooted tree as the associated FileStore. Every path is lexical,
/// rooted-relative, byte-exact, and revalidated by the driver. Refuse symlinks
/// (including parents), nonregular files and occupied/unowned destinations.
/// Callers serialize through the library lock, never across network work.
/// Checks protect cooperating writers, not a malicious racing local process.
/// Native implementations arrive in Y18/Y19; Core tests supply a memory fake.
public protocol SyncFileOperations {
    /// Atomically publish complete bytes with the requested mode, after checking
    /// expectation. Retain displaced bytes before publication and verify the
    /// resulting bytes. Flush the file and all affected directories, including
    /// newly created ancestors, before returning success. On uncertain durability
    /// throw SyncFileOperationError with .applied and the displaced bytes.
    func publish(_ bytes: Data, at path: RelativePath, expecting: SyncFileExpectation,
                 mode: SyncFileMode) throws -> SyncFilePublication

    /// Checked durability, never best effort. A file flush preserves its mode.
    func flushFile(at path: RelativePath) throws
    /// Nil means the rooted tree itself. Flush after adding/removing its entries.
    func flushDirectory(at path: RelativePath?) throws
    /// Apply 0444 or normal permissions, flush and report any partial mutation.
    func setMode(_ mode: SyncFileMode, at path: RelativePath) throws
    /// Check the exact regular file, then move it to recoverable system trash.
    /// Flush the affected source/trash directories; never substitute unlink.
    func trash(at path: RelativePath, expecting: SyncFileExpectation) throws
    /// Exclusive managed directory creation. Even an empty directory is occupied.
    /// Flush newly created ancestors and their parents before success.
    func createDirectory(at path: RelativePath) throws
    /// Never replace or merge into an occupied destination. Flush both parents.
    /// Require an existing destination parent; never create it implicitly.
    /// Case-only renames use journaled, exclusive intermediate names at the caller.
    func renameDirectory(from source: RelativePath, to destination: RelativePath) throws
    /// Direct child directories only, relative to this root; include empty/hidden
    /// directories for ownership/preflight checks, and never follow symlinks.
    func directories(at path: RelativePath?) throws -> [RelativePath]
}
