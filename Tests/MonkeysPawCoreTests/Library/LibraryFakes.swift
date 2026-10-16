import Foundation
@testable import MonkeysPawCore

/// Services call file stores from worker threads, so shared state is locked.
/// Test callbacks run outside the lock because some tests block inside them.
final class MemoryFileStore: FileStore {
    enum PathMatching { case exact, caseInsensitive }

    private struct File {
        let path: String
        let bytes: Data
        let stamp: FileStamp
        let isPrivate: Bool
    }
    private var files = [Data: File]()
    private var generation = 0
    private let pathMatching: PathMatching
    var directories = Set<RelativePath>()
    var directoryIdentities: [RelativePath: FileStamp] = [:]
    var failNextWrite = false
    var failWriteNumber: Int?
    private(set) var writeCount = 0
    var failNextDelete = false
    var failDeleteNumber: Int?
    private(set) var deleteCount = 0
    var failMoveNumber: Int?
    var moveCount = 0
    var onStamp: ((String, FileStamp?) throws -> Void)?
    var onRead: ((String) throws -> Void)?
    var onWrite: ((String) -> Void)?
    var onPrivateWrite: ((String) throws -> Void)?
    var onCreate: ((String) throws -> Void)?
    var onDelete: ((String) throws -> Void)?
    var onMove: ((String, String) throws -> Void)?
    private(set) var accessCount = 0
    private(set) var listCount = 0
    private let lock = NSRecursiveLock()

    init(pathMatching: PathMatching = .exact) { self.pathMatching = pathMatching }

    private func key(_ path: String) -> Data {
        if pathMatching == .caseInsensitive {
            return Data(SyncPathCaseFold.fold(path.precomposedStringWithCanonicalMapping)
                .precomposedStringWithCanonicalMapping.utf8)
        }
        return Data(path.utf8)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func listFiles() throws -> [StoredFile] {
        locked {
            accessCount += 1
            listCount += 1
            // Deliberately unsorted to prove service ordering.
            return files.values.map { StoredFile(relativePath: $0.path, stamp: $0.stamp) }
                .sorted { $0.relativePath > $1.relativePath }
        }
    }

    func stamp(at path: String) throws -> FileStamp? {
        locked { accessCount += 1 }
        try FileStorePath.validate(path)
        let stamp = locked { files[key(path)]?.stamp }
        try onStamp?(path, stamp)
        return stamp
    }

    func read(at path: String) throws -> Data {
        locked { accessCount += 1 }
        try FileStorePath.validate(path)
        try onRead?(path)
        guard let file = locked({ files[key(path)] }) else { throw FileStoreError.notFound }
        return file.bytes
    }

    func write(_ data: Data, at path: String) throws {
        try store(data, at: path, isPrivate: false)
    }

    func create(_ data: Data, at path: String) throws {
        try FileStorePath.validate(path)
        try onCreate?(path)
        try locked {
            guard files[key(path)] == nil else { throw FileStoreError.alreadyExists }
            try store(data, at: path, isPrivate: false, notify: false)
        }
        onWrite?(path)
    }

    func writePrivate(_ data: Data, at path: String) throws {
        try onPrivateWrite?(path)
        try store(data, at: path, isPrivate: true)
    }

    func isPrivate(at path: String) -> Bool { locked { files[key(path)]?.isPrivate == true } }

    private func store(_ data: Data, at path: String, isPrivate: Bool, notify: Bool = true) throws {
        try locked {
            accessCount += 1
            try FileStorePath.validate(path)
            writeCount += 1
            if failNextWrite || writeCount == failWriteNumber {
                failNextWrite = false
                throw FileStoreError.ioFailure
            }
            generation += 1
            rememberParents(of: path)
            let storedPath = files[key(path)]?.path ?? path
            files[key(path)] = File(path: storedPath, bytes: data, stamp: FileStamp("memory-\(generation)"),
                                    isPrivate: isPrivate)
        }
        if notify { onWrite?(path) }
    }

    func delete(at path: String) throws {
        try onDelete?(path)
        try locked {
            accessCount += 1
            try FileStorePath.validate(path)
            deleteCount += 1
            if failNextDelete || deleteCount == failDeleteNumber {
                failNextDelete = false
                throw FileStoreError.ioFailure
            }
            guard files.removeValue(forKey: key(path)) != nil else { throw FileStoreError.notFound }
        }
    }

    func move(from source: String, to destination: String) throws {
        locked { accessCount += 1 }
        try FileStorePath.validate(source)
        try FileStorePath.validate(destination)
        try locked {
            moveCount += 1
            if moveCount == failMoveNumber { throw FileStoreError.ioFailure }
        }
        try onMove?(source, destination)
        let sourceKey = key(source)
        let destinationKey = key(destination)
        try locked {
            guard files[destinationKey] == nil || (pathMatching == .caseInsensitive
                && sourceKey == destinationKey && !source.utf8.elementsEqual(destination.utf8)) else {
                throw FileStoreError.alreadyExists
            }
            guard let file = files.removeValue(forKey: sourceKey) else { throw FileStoreError.notFound }
            rememberParents(of: destination)
            files[destinationKey] = File(path: destination, bytes: file.bytes, stamp: file.stamp,
                                        isPrivate: file.isPrivate)
        }
    }

    func put(_ source: String, at path: String) throws { try write(Data(source.utf8), at: path) }
    func text(at path: String) throws -> String { String(decoding: try read(at: path), as: UTF8.self) }

    private func rememberParents(of path: String) {
        var bytes = Array(path.utf8)
        while let slash = bytes.lastIndex(of: 47) {
            bytes.removeSubrange(slash...)
            directories.insert(RelativePath(String(decoding: bytes, as: UTF8.self)))
        }
    }
}

final class LibraryClock: WallClock {
    var date = Date(timeIntervalSince1970: 1.234)
    // Single-threaded test counter; callers must serialize clock access.
    private(set) var readCount = 0
    func now() -> Date {
        readCount += 1
        return date
    }
}

final class LibraryEntropy: EntropySource {
    var value = Array(UInt8(0)...UInt8(9))
    var requests = [Int]()
    func bytes(count: Int) throws -> [UInt8] {
        requests.append(count)
        return value
    }
}

final class MemoryKeyedStore: PromptKeyedStore {
    var values = [PromptIdentity: String]()
    var migrations = [(PromptIdentity, PromptIdentity)]()
    var failNextMigration = false

    func migrateKey(from source: PromptIdentity, to destination: PromptIdentity) throws -> PromptKeyMigration {
        migrations.append((source, destination))
        if failNextMigration {
            failNextMigration = false
            throw FileStoreError.ioFailure
        }
        guard let value = values[source] else { return .unchanged }
        guard values[destination] == nil else { throw LibraryError.keyedStateConflict }
        values[destination] = value
        values[source] = nil
        return .migrated
    }
}
