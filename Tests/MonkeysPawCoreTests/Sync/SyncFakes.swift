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
        try checkParents(of: path)
        let known = try allDirectories()
        guard !known.contains(path) else { throw SyncFileOperationError(.occupied) }
        let displaced = try check(path, expecting: expecting)
        try fileStoreOperation { try files.write(bytes, at: path.string) }
        modes[path] = mode
        do {
            try flushFile(at: path)
            // Creating an ancestor also changes its parent's directory entry.
            var directory = parent(of: path)
            while true {
                try flushDirectory(at: directory)
                guard let current = directory, !known.contains(current) else { break }
                directory = parent(of: current)
            }
        } catch {
            throw SyncFileOperationError(.durabilityFailed, effect: .applied, displacedBytes: displaced)
        }
        return SyncFilePublication(displacedBytes: displaced)
    }

    func flushFile(at path: RelativePath) throws {
        _ = try fileStoreOperation { try files.read(at: path.string) }
        flushedFiles.append(path)
        try flush()
    }

    func flushDirectory(at path: RelativePath?) throws {
        let known = try allDirectories()
        if let path {
            try fileStoreOperation { try FileStorePath.validate(path.string) }
            guard known.contains(path) else { throw SyncFileOperationError(.notFound) }
        }
        folders.formUnion(known)
        flushedDirectories.append(path)
        try flush()
    }

    func setMode(_ mode: SyncFileMode, at path: RelativePath) throws {
        _ = try fileStoreOperation { try files.read(at: path.string) }
        modes[path] = mode
        do { try flushFile(at: path) }
        catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
    }

    func trash(at path: RelativePath, expecting: SyncFileExpectation) throws {
        guard let bytes = try check(path, expecting: expecting) else { throw SyncFileOperationError(.notFound) }
        try fileStoreOperation { try files.delete(at: path.string) }
        trashed[path] = bytes
        modes[path] = nil
        do { try flushDirectory(at: parent(of: path)) }
        catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
    }

    func createDirectory(at path: RelativePath) throws {
        try fileStoreOperation { try FileStorePath.validate(path.string) }
        try checkParents(of: path)
        guard try !allDirectories().contains(path), try fileStoreOperation({ try files.stamp(at: path.string) }) == nil else {
            throw SyncFileOperationError(.occupied)
        }
        folders.insert(path)
        var ancestor = parent(of: path)
        while let directory = ancestor {
            folders.insert(directory)
            ancestor = parent(of: directory)
        }
        do { try flushDirectory(at: parent(of: path)) }
        catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
    }

    func renameDirectory(from source: RelativePath, to destination: RelativePath) throws {
        try fileStoreOperation { try FileStorePath.validate(source.string) }
        try fileStoreOperation { try FileStorePath.validate(destination.string) }
        try checkParents(of: destination)
        let known = try allDirectories()
        guard known.contains(source) else { throw SyncFileOperationError(.notFound) }
        guard !destination.string.utf8.starts(with: (source.string + "/").utf8) else {
            throw SyncFileOperationError(.invalidPath)
        }
        if let destinationParent = parent(of: destination), !known.contains(destinationParent) {
            throw SyncFileOperationError(.notFound)
        }
        guard !known.contains(destination), try fileStoreOperation({ try files.stamp(at: destination.string) }) == nil else {
            throw SyncFileOperationError(.occupied)
        }
        let descendants = try fileStoreOperation({ try files.listFiles() })
            .filter { $0.relativePath.utf8.starts(with: (source.string + "/").utf8) }
        var effect = SyncFileMutationEffect.unchanged
        for file in descendants {
            let suffix = file.relativePath.utf8.dropFirst(source.string.utf8.count)
            let newPath = destination.string + String(decoding: suffix, as: UTF8.self)
            try fileStoreOperation(effect: effect) { try files.move(from: file.relativePath, to: newPath) }
            effect = .applied
            if let mode = modes.removeValue(forKey: RelativePath(file.relativePath)) {
                modes[RelativePath(newPath)] = mode
            }
        }
        folders.formUnion(known)
        let moved = known.filter { $0 == source || $0.string.utf8.starts(with: (source.string + "/").utf8) }
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
        if let path { try fileStoreOperation { try FileStorePath.validate(path.string) } }
        return try allDirectories().filter { parent(of: $0) == path }.sorted()
    }

    private func allDirectories() throws -> Set<RelativePath> {
        var known = folders
        for file in try fileStoreOperation({ try files.listFiles() }) {
            var ancestor = parent(of: RelativePath(file.relativePath))
            while let directory = ancestor {
                known.insert(directory)
                ancestor = parent(of: directory)
            }
        }
        return known
    }

    private func check(_ path: RelativePath, expecting: SyncFileExpectation) throws -> Data? {
        let stamp = try fileStoreOperation { try files.stamp(at: path.string) }
        switch expecting {
        case .absent:
            guard stamp == nil else { throw SyncFileOperationError(.occupied) }
            return nil
        case .matching(let expected, let bytes):
            guard let stamp, stamp == expected, try fileStoreOperation({ try files.read(at: path.string) }) == bytes else {
                throw SyncFileOperationError(.changed)
            }
            return bytes
        }
    }

    private func checkParents(of path: RelativePath) throws {
        var ancestor = parent(of: path)
        while let directory = ancestor {
            guard try fileStoreOperation({ try files.stamp(at: directory.string) }) == nil else {
                throw SyncFileOperationError(.invalidPath)
            }
            ancestor = parent(of: directory)
        }
    }

    private func flush() throws {
        flushCount += 1
        if flushCount == failFlushNumber { throw SyncFileOperationError(.durabilityFailed) }
    }

    private func fileStoreOperation<Value>(effect: SyncFileMutationEffect = .unchanged,
                                          _ operation: () throws -> Value) throws -> Value {
        do { return try operation() }
        catch let error as FileStoreError {
            let code: SyncFileFailureCode
            switch error {
            case .invalidPath, .outsideRoot, .invalidRoot, .notRegularFile: code = .invalidPath
            case .notFound: code = .notFound
            case .alreadyExists: code = .occupied
            case .ioFailure: code = .ioFailure
            }
            throw SyncFileOperationError(code, effect: effect)
        } catch { throw SyncFileOperationError(.ioFailure, effect: effect) }
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
                             prompts: [.assigned(personalPrompt): personal, .assigned(groupPrompt): shared],
                             favorites: [.assigned(groupPrompt): true])
    }

    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }

    static func write(_ object: [String: Any], to files: MemoryFileStore, path: String) throws {
        try files.writePrivate(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), at: path)
    }
}
