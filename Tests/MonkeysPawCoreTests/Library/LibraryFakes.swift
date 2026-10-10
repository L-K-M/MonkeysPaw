import Foundation
@testable import MonkeysPawCore

final class MemoryFileStore: FileStore {
    private struct File { let bytes: Data; let stamp: FileStamp }
    private var files = [String: File]()
    private var generation = 0
    var failNextWrite = false
    var failNextDelete = false
    var failMoveNumber: Int?
    var moveCount = 0
    var onWrite: ((String) -> Void)?

    func listFiles() throws -> [StoredFile] {
        // Deliberately unsorted to prove service ordering.
        files.map { StoredFile(relativePath: $0.key, stamp: $0.value.stamp) }.sorted { $0.relativePath > $1.relativePath }
    }

    func stamp(at path: String) throws -> FileStamp? {
        try FileStorePath.validate(path)
        return files[path]?.stamp
    }

    func read(at path: String) throws -> Data {
        try FileStorePath.validate(path)
        guard let file = files[path] else { throw FileStoreError.notFound }
        return file.bytes
    }

    func write(_ data: Data, at path: String) throws {
        try FileStorePath.validate(path)
        if failNextWrite {
            failNextWrite = false
            throw FileStoreError.ioFailure
        }
        generation += 1
        files[path] = File(bytes: data, stamp: FileStamp("memory-\(generation)"))
        onWrite?(path)
    }

    func delete(at path: String) throws {
        try FileStorePath.validate(path)
        if failNextDelete {
            failNextDelete = false
            throw FileStoreError.ioFailure
        }
        guard files.removeValue(forKey: path) != nil else { throw FileStoreError.notFound }
    }

    func move(from source: String, to destination: String) throws {
        try FileStorePath.validate(source)
        try FileStorePath.validate(destination)
        moveCount += 1
        if moveCount == failMoveNumber { throw FileStoreError.ioFailure }
        guard files[destination] == nil else { throw FileStoreError.alreadyExists }
        guard let file = files[source] else { throw FileStoreError.notFound }
        files[destination] = file
        files[source] = nil
    }

    func put(_ source: String, at path: String) throws { try write(Data(source.utf8), at: path) }
    func text(at path: String) throws -> String { String(decoding: try read(at: path), as: UTF8.self) }
}

final class LibraryClock: Clock {
    var date = Date(timeIntervalSince1970: 1.234)
    func now() -> Date { date }
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
