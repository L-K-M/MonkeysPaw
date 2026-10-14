import Foundation
@testable import MonkeysPawCore

final class MemoryFileStore: FileStore {
    private struct File {
        let path: String
        let bytes: Data
        let stamp: FileStamp
        let isPrivate: Bool
    }
    private var files = [Data: File]()
    private var generation = 0
    var directories = Set<RelativePath>()
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
    var onCreate: ((String) throws -> Void)?
    var onMove: ((String, String) throws -> Void)?
    private(set) var accessCount = 0
    private(set) var listCount = 0

    func listFiles() throws -> [StoredFile] {
        accessCount += 1
        listCount += 1
        // Deliberately unsorted to prove service ordering.
        return files.values.map { StoredFile(relativePath: $0.path, stamp: $0.stamp) }
            .sorted { $0.relativePath > $1.relativePath }
    }

    func stamp(at path: String) throws -> FileStamp? {
        accessCount += 1
        try FileStorePath.validate(path)
        let stamp = files[Data(path.utf8)]?.stamp
        try onStamp?(path, stamp)
        return stamp
    }

    func read(at path: String) throws -> Data {
        accessCount += 1
        try FileStorePath.validate(path)
        try onRead?(path)
        guard let file = files[Data(path.utf8)] else { throw FileStoreError.notFound }
        return file.bytes
    }

    func write(_ data: Data, at path: String) throws {
        try store(data, at: path, isPrivate: false)
    }

    func create(_ data: Data, at path: String) throws {
        try FileStorePath.validate(path)
        try onCreate?(path)
        guard files[Data(path.utf8)] == nil else { throw FileStoreError.alreadyExists }
        try store(data, at: path, isPrivate: false)
    }

    func writePrivate(_ data: Data, at path: String) throws {
        try store(data, at: path, isPrivate: true)
    }

    func isPrivate(at path: String) -> Bool { files[Data(path.utf8)]?.isPrivate == true }

    private func store(_ data: Data, at path: String, isPrivate: Bool) throws {
        accessCount += 1
        try FileStorePath.validate(path)
        writeCount += 1
        if failNextWrite || writeCount == failWriteNumber {
            failNextWrite = false
            throw FileStoreError.ioFailure
        }
        generation += 1
        rememberParents(of: path)
        files[Data(path.utf8)] = File(path: path, bytes: data, stamp: FileStamp("memory-\(generation)"),
                                       isPrivate: isPrivate)
        onWrite?(path)
    }

    func delete(at path: String) throws {
        accessCount += 1
        try FileStorePath.validate(path)
        deleteCount += 1
        if failNextDelete || deleteCount == failDeleteNumber {
            failNextDelete = false
            throw FileStoreError.ioFailure
        }
        guard files.removeValue(forKey: Data(path.utf8)) != nil else { throw FileStoreError.notFound }
    }

    func move(from source: String, to destination: String) throws {
        accessCount += 1
        try FileStorePath.validate(source)
        try FileStorePath.validate(destination)
        moveCount += 1
        if moveCount == failMoveNumber { throw FileStoreError.ioFailure }
        try onMove?(source, destination)
        guard files[Data(destination.utf8)] == nil else { throw FileStoreError.alreadyExists }
        guard let file = files[Data(source.utf8)] else { throw FileStoreError.notFound }
        rememberParents(of: destination)
        files[Data(destination.utf8)] = File(path: destination, bytes: file.bytes, stamp: file.stamp,
                                              isPrivate: file.isPrivate)
        files[Data(source.utf8)] = nil
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
