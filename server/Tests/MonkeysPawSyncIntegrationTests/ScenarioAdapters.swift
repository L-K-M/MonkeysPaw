#if DEBUG
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import MonkeysPawCore

/// Portable test storage, with recoverable test trash. Native system-trash and
/// power-loss guarantees are owned by the platform suites, not this adapter.
final class ScenarioDisk: FileStore, SyncFileOperations {
    let root: URL
    private let trashRoot: URL
    private let lock = NSRecursiveLock()
    private(set) var writes = 0
    private(set) var trashCount = 0

    init(root: URL, trash: URL) throws {
        self.root = root
        trashRoot = trash
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    func resetMetrics() { locked { writes = 0; trashCount = 0 } }

    func listFiles() throws -> [StoredFile] {
        try locked {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw FileStoreError.ioFailure
            }
            var files: [StoredFile] = []
            for case let url as URL in enumerator {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let type = attributes[.type] as? FileAttributeType
                if type == .typeSymbolicLink { enumerator.skipDescendants(); continue }
                guard type == .typeRegular else { continue }
                let path = String(url.path.dropFirst(root.path.count + 1))
                guard let stamp = try stamp(at: path) else { throw FileStoreError.notFound }
                files.append(.init(relativePath: path, stamp: stamp))
            }
            return files.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        }
    }

    func stamp(at path: String) throws -> FileStamp? {
        try locked {
            let url = try checked(path)
            guard let attributes = try attributes(url) else { return nil }
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw FileStoreError.notRegularFile }
            let bytes = try Data(contentsOf: url)
            return FileStamp("\(attributes[.systemFileNumber]!)" + SHA256.hexDigest(bytes))
        }
    }

    func read(at path: String) throws -> Data {
        try locked {
            guard try stamp(at: path) != nil else { throw FileStoreError.notFound }
            return try Data(contentsOf: checked(path))
        }
    }

    func write(_ data: Data, at path: String) throws { try locked { try write(data, at: path, permissions: 0o644) } }
    func writePrivate(_ data: Data, at path: String) throws { try locked { try write(data, at: path, permissions: 0o600) } }
    func create(_ data: Data, at path: String) throws {
        try locked {
            guard try attributes(checked(path)) == nil else { throw FileStoreError.alreadyExists }
            try write(data, at: path, permissions: 0o644)
        }
    }

    private func write(_ data: Data, at path: String, permissions: Int) throws {
        let url = try checked(path)
        if let attributes = try attributes(url), attributes[.type] as? FileAttributeType != .typeRegular {
            throw FileStoreError.notRegularFile
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        writes += 1
    }

    func delete(at path: String) throws {
        try locked {
            guard try stamp(at: path) != nil else { throw FileStoreError.notFound }
            try FileManager.default.removeItem(at: checked(path))
        }
    }

    func move(from source: String, to destination: String) throws {
        try locked {
            guard try stamp(at: source) != nil else { throw FileStoreError.notFound }
            let target = try checked(destination)
            guard try attributes(target) == nil else { throw FileStoreError.alreadyExists }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: checked(source), to: target)
        }
    }

    func publish(_ bytes: Data, at path: RelativePath, expecting: SyncFileExpectation,
                 mode: SyncFileMode) throws -> SyncFilePublication {
        try locked {
            let displaced = try check(path, expecting)
            try write(bytes, at: path.string, permissions: mode == .readOnly ? 0o444 : 0o644)
            do {
                guard try read(at: path.string) == bytes else { throw SyncFileOperationError(.changed) }
                try flushFile(at: path)
                try flushAncestors(of: path)
            } catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied, displacedBytes: displaced) }
            return .init(displacedBytes: displaced)
        }
    }

    func flushFile(at path: RelativePath) throws { try locked { _ = try read(at: path.string); try flush(checked(path.string)) } }
    func flushDirectory(at path: RelativePath?) throws {
        try locked {
            let url = try path.map { try checked($0.string) } ?? root
            guard try attributes(url)?[.type] as? FileAttributeType == .typeDirectory else {
                throw SyncFileOperationError(.invalidPath)
            }
            try flush(url)
        }
    }

    func setMode(_ mode: SyncFileMode, at path: RelativePath) throws {
        try locked {
            _ = try read(at: path.string)
            try FileManager.default.setAttributes([.posixPermissions: mode == .readOnly ? 0o444 : 0o644],
                                                 ofItemAtPath: checked(path.string).path)
            try flushFile(at: path)
        }
    }

    func mode(at path: String) throws -> SyncFileMode {
        try locked {
            _ = try read(at: path)
            let permissions = try FileManager.default.attributesOfItem(atPath: checked(path).path)[.posixPermissions] as! Int
            return permissions & 0o222 == 0 ? .readOnly : .normal
        }
    }

    func trash(at path: RelativePath, expecting: SyncFileExpectation) throws {
        try locked {
            guard try check(path, expecting) != nil else { throw SyncFileOperationError(.notFound) }
            try FileManager.default.moveItem(at: checked(path.string), to: trashRoot.appendingPathComponent(UUID().uuidString))
            trashCount += 1
            try flushAncestors(of: path)
            try flush(trashRoot)
        }
    }

    func createDirectory(at path: RelativePath) throws {
        try locked {
            let url = try checked(path.string)
            guard try attributes(url) == nil else { throw SyncFileOperationError(.occupied) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try flush(url)
            try flushAncestors(of: path)
        }
    }

    func renameDirectory(from source: RelativePath, to destination: RelativePath) throws {
        try locked {
            guard try directoryIdentity(at: source) != nil else { throw SyncFileOperationError(.notFound) }
            let target = try checked(destination.string)
            guard try attributes(target) == nil else { throw SyncFileOperationError(.occupied) }
            guard try attributes(target.deletingLastPathComponent())?[.type] as? FileAttributeType == .typeDirectory else {
                throw SyncFileOperationError(.notFound)
            }
            try FileManager.default.moveItem(at: checked(source.string), to: target)
            try flushAncestors(of: source)
            try flushAncestors(of: destination)
        }
    }

    func directories(at path: RelativePath?) throws -> [RelativePath] {
        try locked {
            let url = try path.map { try checked($0.string) } ?? root
            guard try attributes(url)?[.type] as? FileAttributeType == .typeDirectory else { return [] }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).compactMap { child in
                guard try attributes(child)?[.type] as? FileAttributeType == .typeDirectory else { return nil }
                return RelativePath(String(child.path.dropFirst(root.path.count + 1)))
            }.sorted()
        }
    }

    func directoryIdentity(at path: RelativePath) throws -> FileStamp? {
        try locked {
            guard let attributes = try attributes(checked(path.string)) else { return nil }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SyncFileOperationError(.invalidPath) }
            return FileStamp("directory-\(attributes[.systemFileNumber]!)")
        }
    }

    func removeEmptyDirectory(at path: RelativePath, expecting: FileStamp) throws {
        try locked {
            guard try directoryIdentity(at: path) == expecting else { throw SyncFileOperationError(.changed) }
            let url = try checked(path.string)
            guard try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty else { throw SyncFileOperationError(.occupied) }
            try FileManager.default.removeItem(at: url)
            try flushAncestors(of: path)
        }
    }

    func symlink(at path: String, to target: URL) throws {
        try locked {
            let url = try checked(path)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        }
    }

    private func check(_ path: RelativePath, _ expectation: SyncFileExpectation) throws -> Data? {
        let actual = try stamp(at: path.string)
        switch expectation {
        case .absent:
            guard actual == nil else { throw SyncFileOperationError(.occupied) }
            return nil
        case .matching(let stamp, let bytes):
            guard actual == stamp, try read(at: path.string) == bytes else { throw SyncFileOperationError(.changed) }
            return bytes
        }
    }

    private func checked(_ path: String) throws -> URL {
        try FileStorePath.validate(path)
        var url = root
        for component in path.split(separator: "/") {
            if let attributes = try attributes(url), attributes[.type] as? FileAttributeType != .typeDirectory {
                throw FileStoreError.invalidPath
            }
            url.appendPathComponent(String(component))
        }
        if try attributes(url)?[.type] as? FileAttributeType == .typeSymbolicLink { throw FileStoreError.invalidPath }
        return url
    }

    private func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
    }

    private func flushAncestors(of path: RelativePath) throws {
        var url = try checked(path.string).deletingLastPathComponent()
        while true {
            try flush(url)
            if url.path.utf8.elementsEqual(root.path.utf8) { return }
            guard url.path.utf8.starts(with: (root.path + "/").utf8) else { throw SyncFileOperationError(.invalidPath) }
            url.deleteLastPathComponent()
        }
    }

    private func flush(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SyncFileOperationError(.durabilityFailed) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw SyncFileOperationError(.durabilityFailed) }
    }

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }
}

final class ScenarioSecrets: SecretStore {
    private let files: ScenarioDisk
    init(files: ScenarioDisk) { self.files = files }
    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        let path = account.namespace + "/" + account.name
        guard try files.stamp(at: path) != nil else { return nil }
        return .init(value: .init(String(decoding: try files.read(at: path), as: UTF8.self)), tier: .file)
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        try value.withValue { try files.writePrivate(Data($0.utf8), at: account.namespace + "/" + account.name) }
        return .file
    }
    func delete(account: SecretAccount) throws {
        let path = account.namespace + "/" + account.name
        if try files.stamp(at: path) != nil { try files.delete(at: path) }
    }
}

final class ScenarioClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}

final class ScenarioEntropy: EntropySource {
    private var sequence: UInt64
    init(seed: UInt64) { sequence = seed << 32 }
    func bytes(count: Int) throws -> [UInt8] {
        sequence += 1
        return (0..<count).map { index in index < count - 8 ? 0 : UInt8(truncatingIfNeeded: sequence >> ((count - 1 - index) * 8)) }
    }
}

/// Timers are deliberately driven only by explicit scenario actions.
final class ScenarioScheduler: Scheduler {
    private let lock = NSLock()
    private var work: [(Duration, () -> Void)] = []
    func after(_ delay: Duration, _ body: @escaping () -> Void) { lock.lock(); defer { lock.unlock() }; work.append((delay, body)) }

    func fire(delay: Duration) {
        lock.lock()
        let ready = work.filter { $0.0 == delay }
        work.removeAll { $0.0 == delay }
        lock.unlock()
        ready.forEach { $0.1() }
    }
}

struct ScenarioMainThread: MainThread {
    func run(_ work: @escaping () -> Void) { work() }
}
#endif
