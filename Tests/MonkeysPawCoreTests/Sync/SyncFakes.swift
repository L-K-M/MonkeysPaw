import Foundation
@testable import MonkeysPawCore

/// Models the new capability, including a mutation followed by failed flush.
/// This is not native fsync/trash proof; Y18/Y19 own those driver tests.
final class MemorySyncFileOperations: SyncFileOperations {
    let files: MemoryFileStore
    var failFlushNumber: Int?
    private(set) var flushCount = 0
    private(set) var flushedFiles: [RelativePath] = []
    private(set) var flushedDirectories: [RelativePath?] = []
    private(set) var modes: [RelativePath: SyncFileMode] = [:]
    private(set) var trashed: [RelativePath: Data] = [:]
    private var folders = Set<RelativePath>()

    init(files: MemoryFileStore) { self.files = files }

    func publish(_ bytes: Data, at path: RelativePath, expecting: SyncFileExpectation,
                 mode: SyncFileMode) throws -> SyncFilePublication {
        let displaced = try check(path, expecting: expecting)
        try files.write(bytes, at: path.string)
        modes[path] = mode
        do {
            try flushFile(at: path)
            try flushDirectory(at: parent(of: path))
        } catch {
            throw SyncFileOperationError(.durabilityFailed, effect: .applied, displacedBytes: displaced)
        }
        return SyncFilePublication(displacedBytes: displaced)
    }

    func flushFile(at path: RelativePath) throws {
        _ = try files.read(at: path.string)
        flushedFiles.append(path)
        try flush()
    }

    func flushDirectory(at path: RelativePath?) throws {
        let known = try allDirectories()
        if let path {
            try FileStorePath.validate(path.string)
            guard known.contains(path) else { throw SyncFileOperationError(.notFound) }
        }
        folders.formUnion(known)
        flushedDirectories.append(path)
        try flush()
    }

    func setMode(_ mode: SyncFileMode, at path: RelativePath) throws {
        _ = try files.read(at: path.string)
        modes[path] = mode
        do { try flushFile(at: path) }
        catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
    }

    func trash(at path: RelativePath, expecting: SyncFileExpectation) throws {
        guard let bytes = try check(path, expecting: expecting) else { throw SyncFileOperationError(.notFound) }
        trashed[path] = bytes
        try files.delete(at: path.string)
        modes[path] = nil
        do { try flushDirectory(at: parent(of: path)) }
        catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
    }

    func createDirectory(at path: RelativePath) throws {
        try FileStorePath.validate(path.string)
        guard !folders.contains(path), try files.stamp(at: path.string) == nil else {
            throw SyncFileOperationError(.occupied)
        }
        folders.insert(path)
        do { try flushDirectory(at: parent(of: path)) }
        catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
    }

    func renameDirectory(from source: RelativePath, to destination: RelativePath) throws {
        try FileStorePath.validate(source.string)
        try FileStorePath.validate(destination.string)
        guard folders.contains(source) else { throw SyncFileOperationError(.notFound) }
        guard !folders.contains(destination), try files.stamp(at: destination.string) == nil else {
            throw SyncFileOperationError(.occupied)
        }
        let descendants = try files.listFiles().filter { $0.relativePath.utf8.starts(with: (source.string + "/").utf8) }
        for file in descendants {
            let suffix = file.relativePath.utf8.dropFirst(source.string.utf8.count)
            try files.move(from: file.relativePath, to: destination.string + String(decoding: suffix, as: UTF8.self))
        }
        let moved = folders.filter { $0 == source || $0.string.utf8.starts(with: (source.string + "/").utf8) }
        for folder in moved {
            folders.remove(folder)
            let suffix = folder.string.utf8.dropFirst(source.string.utf8.count)
            folders.insert(RelativePath(destination.string + String(decoding: suffix, as: UTF8.self)))
        }
        do {
            try flushDirectory(at: parent(of: source))
            try flushDirectory(at: parent(of: destination))
        } catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
    }

    func directories(at path: RelativePath?) throws -> [RelativePath] {
        if let path { try FileStorePath.validate(path.string) }
        return try allDirectories().filter { parent(of: $0) == path }.sorted()
    }

    private func allDirectories() throws -> Set<RelativePath> {
        var known = folders
        for file in try files.listFiles() {
            var ancestor = parent(of: RelativePath(file.relativePath))
            while let directory = ancestor {
                known.insert(directory)
                ancestor = parent(of: directory)
            }
        }
        return known
    }

    private func check(_ path: RelativePath, expecting: SyncFileExpectation) throws -> Data? {
        let stamp = try files.stamp(at: path.string)
        switch expecting {
        case .absent:
            guard stamp == nil else { throw SyncFileOperationError(.occupied) }
            return nil
        case .matching(let expected, let bytes):
            guard let stamp, stamp == expected, try files.read(at: path.string) == bytes else {
                throw SyncFileOperationError(.changed)
            }
            return bytes
        }
    }

    private func flush() throws {
        flushCount += 1
        if flushCount == failFlushNumber { throw SyncFileOperationError(.durabilityFailed) }
    }

    private func parent(of path: RelativePath) -> RelativePath? {
        let bytes = path.string.utf8
        guard let slash = bytes.lastIndex(of: 47) else { return nil }
        return RelativePath(String(decoding: bytes[..<slash], as: UTF8.self))
    }
}

enum SyncTestValues {
    static let user = ULID("00000000000000000000000001")!
    static let otherUser = ULID("00000000000000000000000002")!
    static let group = ULID("00000000000000000000000003")!
    static let personalPrompt = ULID("00000000000000000000000004")!
    static let groupPrompt = ULID("00000000000000000000000005")!
    static let device = ULID("00000000000000000000000006")!
    static let uuid = UUID(uuidString: "1a2b3c4d-0000-4000-8000-000000000001")!

    static func account(userID: ULID = user, server: String = "https://example.test/paw") throws -> SyncAccountIdentity {
        try SyncAccountIdentity(serverURL: server, userID: userID)
    }

    static func binding(root: String = "/library", userID: ULID = user,
                        server: String = "https://example.test/paw") throws -> SyncLibraryIdentity {
        try SyncLibraryIdentity(account: account(userID: userID, server: server), root: SyncLibraryRoot(root))
    }

    static func state() throws -> SyncState {
        let fingerprint = try SyncInputFingerprint(bytes: Data("canonical".utf8), path: "Group.md",
                                                   scope: .group(group), accessGeneration: 17, operation: .put)
        let personal = try SyncPromptState(scope: .user(user), path: "Conflicts/Personal/Copy.md", rev: 7,
                                           canonicalHash: SyncHash(bytes: Data("personal".utf8)),
                                           origin: .conflictOf(groupPrompt),
                                           lastError: SyncPromptError(code: .notFound, fingerprint: fingerprint))
        let shared = try SyncPromptState(scope: .group(group), path: "Folder/Group.md", rev: .max,
                                         canonicalHash: SyncHash(bytes: Data("canonical".utf8)))
        return try SyncState(binding: binding(), databaseID: uuid,
                             cursors: [.user(user): "0", .group(group): "snap:any opaque value / Ω + ="],
                             groups: [group: SyncGroupState(name: "Team", folder: "Team", role: .viewer)],
                             prompts: [personalPrompt: personal, groupPrompt: shared], favorites: [groupPrompt: true])
    }

    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }

    static func write(_ object: [String: Any], to files: MemoryFileStore, path: String) throws {
        try files.writePrivate(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), at: path)
    }
}
