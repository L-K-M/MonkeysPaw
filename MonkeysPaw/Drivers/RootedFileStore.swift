import Foundation
import Darwin
import MonkeysPawCore

/// Root-relative descriptors keep the 1,287-byte wrapped paths usable on macOS
/// and reject linked parents. Expectations still protect cooperating writers,
/// not a malicious process racing a leaf between its check and replacement.
final class RootedFileStore: FileStore, SyncFileOperations {
    private enum Parents { case existing, create }
    private enum WriteMode { case normal, privateFile }
    private enum Flush { case ordinary, checked }
    private let root: URL
    private let syncIO: SyncIO
    private let rootLock = NSLock()
    private var pinnedRoot: FileStamp?
    private static let directoryFlags = O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Fault seams never substitute an unlink for failed Trash or durability.
    struct SyncIO {
        var flush: (Int32) -> Bool = { RootedFileStore.flushDescriptor($0) }
        var fullFlush: (Int32) -> Bool = { fcntl($0, F_FULLFSYNC) == 0 }
        var rename: (Int32, String, Int32, String) -> Bool = { renameat($0, $1, $2, $3) == 0 }
        var trash: ((URL) throws -> URL)?
    }

    init(root: URL, syncIO: SyncIO = SyncIO()) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw FileStoreError.invalidRoot }
        // POSIX resolution also handles Darwin's /var -> /private/var. Missing
        // tails stay literal; every later traversal rejects replaced links.
        var canonical = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.standardizedFileURL.pathComponents.dropFirst() {
            canonical.appendPathComponent(component, isDirectory: true)
            if let resolved = realpath(canonical.path, nil) {
                canonical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                free(resolved)
            }
        }
        guard canonical.path != "/" else { throw FileStoreError.invalidRoot }
        self.root = canonical
        self.syncIO = syncIO
        if let descriptor = try openRoot(parents: .existing) { _ = Darwin.close(descriptor) }
    }

    func createRoot() throws {
        guard let descriptor = try openRoot(parents: .create) else { throw FileStoreError.invalidRoot }
        _ = Darwin.close(descriptor)
    }

    func requireRoot() throws {
        guard let descriptor = try openRoot(parents: .existing) else { throw FileStoreError.notFound }
        _ = Darwin.close(descriptor)
    }

    /// Sync cannot interpret a lost/recreated root as empty, or lazily recreate
    /// it during a pass. Ordinary unpinned stores retain their lazy-root behavior.
    func pinRoot() throws {
        guard let descriptor = try openRoot(parents: .existing) else { throw FileStoreError.notFound }
        defer { _ = Darwin.close(descriptor) }
        let identity = directoryStamp(try descriptorInfo(descriptor))
        rootLock.lock()
        pinnedRoot = identity
        rootLock.unlock()
    }

    func rootIdentity() throws -> FileStamp {
        guard let descriptor = try openRoot(parents: .existing) else { throw FileStoreError.notFound }
        defer { _ = Darwin.close(descriptor) }
        let info = try descriptorInfo(descriptor)
        // Device numbers may change after reboot; native persisted root proof
        // uses the filesystem's stable volume UUID instead.
        guard let volume = try root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else {
            throw FileStoreError.ioFailure
        }
        return FileStamp("\(volume):\(info.st_ino):\(info.st_gen):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)")
    }

    func listFiles() throws -> [StoredFile] {
        try fileOperation {
            guard let descriptor = try openRoot(parents: .existing) else { return [] }
            defer { _ = Darwin.close(descriptor) }
            var result: [StoredFile] = []
            try collect(in: descriptor, prefix: "", into: &result)
            try verifyPinnedRoot()
            return result.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        }
    }

    func stamp(at path: String) throws -> FileStamp? {
        try fileOperation {
            do {
                return try withParent(path, parents: .existing) { parent, name in
                    guard let info = try itemInfo(name, in: parent) else { return nil }
                    try requireRegular(info)
                    return fileStamp(info)
                }
            } catch FileStoreError.notFound {
                try verifyPinnedRoot()
                return nil
            }
        }
    }

    func read(at path: String) throws -> Data {
        try fileOperation {
            try withParent(path, parents: .existing) { parent, name in
                let descriptor = try regularFile(name, in: parent)
                defer { _ = Darwin.close(descriptor) }
                return try readBytes(descriptor)
            }
        }
    }

    func write(_ data: Data, at path: String) throws {
        try fileOperation { try atomicWrite(data, at: path, mode: .normal) }
    }

    func writePrivate(_ data: Data, at path: String) throws {
        try fileOperation { try atomicWrite(data, at: path, mode: .privateFile) }
    }

    private func atomicWrite(_ data: Data, at path: String, mode: WriteMode) throws {
        try withParent(path, parents: .create) { parent, name in
            if let info = try itemInfo(name, in: parent) { try requireRegular(info) }
            let (descriptor, temporary) = try temporaryFile(in: parent, permissions: mode == .privateFile ? 0o600 : 0o666)
            defer { _ = Darwin.close(descriptor); _ = unlinkat(parent, temporary, 0) }
            if mode == .privateFile, fchmod(descriptor, mode_t(Limits.privateFileMode)) != 0 { throw FileStoreError.ioFailure }
            try writeAll(data, to: descriptor)
            if mode == .privateFile, fsync(descriptor) != 0 { throw FileStoreError.ioFailure }
            try verifyPinnedRoot()
            guard renameat(parent, temporary, parent, name) == 0 else { throw FileStoreError.ioFailure }
            if mode == .privateFile { _ = fsync(parent) }
        }
    }

    func create(_ data: Data, at path: String) throws {
        try fileOperation {
            try withParent(path, parents: .create) { parent, name in
                let (descriptor, temporary) = try temporaryFile(in: parent, permissions: 0o666)
                defer { _ = Darwin.close(descriptor); _ = unlinkat(parent, temporary, 0) }
                try writeAll(data, to: descriptor)
                guard fsync(descriptor) == 0 else { throw FileStoreError.ioFailure }
                try verifyPinnedRoot()
                guard linkat(parent, temporary, parent, name, 0) == 0 else {
                    throw errno == EEXIST ? FileStoreError.alreadyExists : FileStoreError.ioFailure
                }
                _ = fsync(parent)
            }
        }
    }

    func delete(at path: String) throws {
        try fileOperation {
            try withParent(path, parents: .existing) { parent, name in
                guard let info = try itemInfo(name, in: parent) else { throw FileStoreError.notFound }
                try requireRegular(info)
                try verifyPinnedRoot()
                guard unlinkat(parent, name, 0) == 0 else {
                    throw errno == ENOENT ? FileStoreError.notFound : FileStoreError.ioFailure
                }
            }
        }
    }

    func move(from source: String, to destination: String) throws {
        try fileOperation {
            try FileStorePath.validate(source)
            try FileStorePath.validate(destination)
            try withParent(source, parents: .existing) { from, sourceName in
                guard let info = try itemInfo(sourceName, in: from) else { throw FileStoreError.notFound }
                try requireRegular(info)
                try withParent(destination, parents: .create) { to, destinationName in
                    if let existing = try itemInfo(destinationName, in: to) {
                        if isType(existing, mode_t(S_IFLNK)) { throw FileStoreError.outsideRoot }
                        throw FileStoreError.alreadyExists
                    }
                    try verifyPinnedRoot()
                    guard renameatx_np(from, sourceName, to, destinationName, UInt32(RENAME_EXCL)) == 0 else {
                        throw errno == EEXIST ? FileStoreError.alreadyExists : FileStoreError.ioFailure
                    }
                }
            }
        }
    }

    func publish(_ bytes: Data, at path: RelativePath, expecting: SyncFileExpectation,
                 mode: SyncFileMode) throws -> SyncFilePublication {
        try syncOperation {
            try requireRoot()
            let displaced = try checkedBytes(at: path, expecting: expecting)
            return try withParent(path.string, parents: .create, flush: .checked) { parent, name in
                let (descriptor, temporary) = try temporaryFile(in: parent, permissions: 0o666)
                defer { _ = Darwin.close(descriptor); _ = unlinkat(parent, temporary, 0) }
                try writeAll(bytes, to: descriptor)
                if mode == .readOnly, fchmod(descriptor, mode_t(0o444)) != 0 { throw SyncFileOperationError(.ioFailure) }
                guard syncIO.flush(descriptor) else { throw SyncFileOperationError(.durabilityFailed) }
                _ = try checkedBytes(at: path, expecting: expecting)
                try verifyPinnedRoot()
                switch expecting {
                case .absent:
                    guard linkat(parent, temporary, parent, name, 0) == 0 else {
                        throw SyncFileOperationError(errno == EEXIST ? .changed : .ioFailure)
                    }
                    guard unlinkat(parent, temporary, 0) == 0 else { throw SyncFileOperationError(.ioFailure, effect: .applied) }
                case .matching:
                    guard syncIO.rename(parent, temporary, parent, name) else { throw SyncFileOperationError(.ioFailure) }
                }
                do {
                    guard try read(at: path.string) == bytes else { throw SyncFileOperationError(.changed) }
                    try flushFile(at: path)
                    try flushDirectory(at: parentPath(of: path))
                } catch {
                    throw SyncFileOperationError((error as? SyncFileOperationError)?.code ?? .durabilityFailed,
                        effect: .applied, displacedBytes: displaced)
                }
                return SyncFilePublication(displacedBytes: displaced)
            }
        }
    }

    func flushFile(at path: RelativePath) throws {
        try syncOperation {
            try withParent(path.string, parents: .existing) { parent, name in
                let descriptor = try regularFile(name, in: parent)
                defer { _ = Darwin.close(descriptor) }
                guard syncIO.flush(descriptor) else { throw SyncFileOperationError(.durabilityFailed) }
            }
        }
    }

    func flushDirectory(at path: RelativePath?) throws {
        try syncOperation {
            // Reopen and flush every ancestor, including a lazily created data
            // root. No rejected directory fsync is reported as a successful commit.
            guard var descriptor = try openRoot(parents: .existing, flush: .checked) else { throw FileStoreError.notFound }
            defer { _ = Darwin.close(descriptor) }
            if let path {
                try FileStorePath.validate(path.string)
                for part in parts(path.string) {
                    let child = try openDirectory(part, in: descriptor, parents: .existing)
                    guard let child else { throw FileStoreError.notFound }
                    _ = Darwin.close(descriptor)
                    descriptor = child
                    guard syncIO.flush(descriptor) else { throw SyncFileOperationError(.durabilityFailed) }
                }
            }
            // This barrier follows the directory fsyncs, including deletions
            // whose file no longer exists. Do not full-flush a read-only OS ancestor.
            guard syncIO.fullFlush(descriptor) else { throw SyncFileOperationError(.durabilityFailed) }
        }
    }

    func setMode(_ mode: SyncFileMode, at path: RelativePath) throws {
        try syncOperation {
            try withParent(path.string, parents: .existing) { parent, name in
                let descriptor = try regularFile(name, in: parent)
                defer { _ = Darwin.close(descriptor) }
                let permission: mode_t
                switch mode {
                case .readOnly: permission = 0o444
                case .normal:
                    // The kernel applies umask to a 0666 probe. Never temporarily
                    // change that process-global mask to discover normal mode.
                    let (probe, temporary) = try temporaryFile(in: parent, permissions: 0o666)
                    defer { _ = Darwin.close(probe); _ = unlinkat(parent, temporary, 0) }
                    permission = try descriptorInfo(probe).st_mode & mode_t(0o777)
                }
                try verifyPinnedRoot()
                guard fchmod(descriptor, permission) == 0 else { throw SyncFileOperationError(.ioFailure) }
                guard syncIO.flush(descriptor) else { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
            }
        }
    }

    func trash(at path: RelativePath, expecting: SyncFileExpectation) throws {
        try syncOperation {
            guard case .matching = expecting else { throw SyncFileOperationError(.changed) }
            try withParent(path.string, parents: .existing) { parent, name in
                _ = try checkedBytes(at: path, expecting: expecting)
                try verifyPinnedRoot()
                let destination: URL
                do {
                    if let trash = syncIO.trash { destination = try trash(root.appendingPathComponent(path.string)) }
                    else { destination = try systemTrash(name, in: parent) }
                } catch let error as SyncFileOperationError { throw error }
                catch {
                    let sourceExists = (try? itemInfo(name, in: parent)) != nil
                    throw SyncFileOperationError(.ioFailure, effect: sourceExists ? .unchanged : .applied)
                }
                do {
                    let file = Darwin.open(destination.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard file >= 0 else { throw SyncFileOperationError(.durabilityFailed) }
                    defer { _ = Darwin.close(file) }
                    try requireRegular(descriptorInfo(file))
                    guard syncIO.flush(file) else { throw SyncFileOperationError(.durabilityFailed) }
                    try flushDirectory(at: parentPath(of: path))
                    let directory = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY | Self.directoryFlags)
                    guard directory >= 0 else { throw SyncFileOperationError(.durabilityFailed) }
                    defer { _ = Darwin.close(directory) }
                    guard syncIO.flush(directory) else { throw SyncFileOperationError(.durabilityFailed) }
                    try flushTrashDirectory(destination.deletingLastPathComponent())
                } catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
            }
        }
    }

    private func flushTrashDirectory(_ url: URL) throws {
        var descriptor = Darwin.open("/", O_RDONLY | Self.directoryFlags)
        guard descriptor >= 0 else { throw SyncFileOperationError(.durabilityFailed) }
        defer { _ = Darwin.close(descriptor) }
        guard syncIO.flush(descriptor) else { throw SyncFileOperationError(.durabilityFailed) }
        for part in url.pathComponents.dropFirst() {
            guard let child = try openDirectory(part, in: descriptor, parents: .existing) else { throw FileStoreError.notFound }
            _ = Darwin.close(descriptor)
            descriptor = child
            guard syncIO.flush(descriptor) else { throw SyncFileOperationError(.durabilityFailed) }
        }
        guard syncIO.fullFlush(descriptor) else { throw SyncFileOperationError(.durabilityFailed) }
    }

    private func systemTrash(_ name: String, in parent: Int32) throws -> URL {
        // Obtain the system Trash on the library volume, then move by descriptor
        // so even a maximum wrapped source path is usable. Refuse cross-volume
        // or unavailable Trash; do not fall back to irreversible deletion.
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: root, create: true)
        let descriptor = Darwin.open(trash.path, O_RDONLY | Self.directoryFlags)
        guard descriptor >= 0 else { throw SyncFileOperationError(.ioFailure) }
        defer { _ = Darwin.close(descriptor) }
        let prefix = UUID().uuidString + "-"
        let remaining = Int(NAME_MAX) - prefix.utf8.count
        var shortened = ""
        for scalar in name.unicodeScalars {
            guard shortened.utf8.count + scalar.utf8.count <= remaining else { break }
            shortened.unicodeScalars.append(scalar)
        }
        let destination = prefix + shortened
        guard renameatx_np(parent, name, descriptor, destination, UInt32(RENAME_EXCL)) == 0 else {
            throw SyncFileOperationError(.ioFailure)
        }
        return trash.appendingPathComponent(destination)
    }

    func createDirectory(at path: RelativePath) throws {
        try syncOperation {
            try requireRoot()
            try withParent(path.string, parents: .create, flush: .checked) { parent, name in
                guard try itemInfo(name, in: parent) == nil else { throw SyncFileOperationError(.occupied) }
                try verifyPinnedRoot()
                guard mkdirat(parent, name, mode_t(0o777)) == 0 else {
                    throw SyncFileOperationError(errno == EEXIST ? .occupied : .ioFailure)
                }
                do { try flushDirectory(at: path) }
                catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
            }
        }
    }

    func renameDirectory(from source: RelativePath, to destination: RelativePath) throws {
        try syncOperation {
            try FileStorePath.validate(source.string)
            try FileStorePath.validate(destination.string)
            try withParent(source.string, parents: .existing) { from, sourceName in
                guard let info = try itemInfo(sourceName, in: from) else { throw FileStoreError.notFound }
                try requireDirectory(info)
                try withParent(destination.string, parents: .existing) { to, destinationName in
                    guard try itemInfo(destinationName, in: to) == nil else { throw SyncFileOperationError(.occupied) }
                    try verifyPinnedRoot()
                    guard renameatx_np(from, sourceName, to, destinationName, UInt32(RENAME_EXCL)) == 0 else {
                        throw SyncFileOperationError(errno == EEXIST ? .occupied : .ioFailure)
                    }
                    do { try flushDirectory(at: parentPath(of: source)); try flushDirectory(at: parentPath(of: destination)) }
                    catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
                }
            }
        }
    }

    func directories(at path: RelativePath?) throws -> [RelativePath] {
        try syncOperation {
            do {
                return try withDirectory(path) { descriptor in
                    try childNames(in: descriptor).compactMap { name in
                        guard let info = try itemInfo(name, in: descriptor), isType(info, mode_t(S_IFDIR)) else { return nil }
                        let relative = (path.map { $0.string + "/" } ?? "") + name
                        try FileStorePath.validate(relative)
                        return RelativePath(relative)
                    }.sorted()
                }
            } catch FileStoreError.notFound { try requireRoot(); return [] }
        }
    }

    func directoryIdentity(at path: RelativePath) throws -> FileStamp? {
        try syncOperation {
            do {
                return try withParent(path.string, parents: .existing) { parent, name in
                    guard let info = try itemInfo(name, in: parent) else { return nil }
                    try requireDirectory(info)
                    return directoryStamp(info)
                }
            } catch FileStoreError.notFound { try requireRoot(); return nil }
        }
    }

    func removeEmptyDirectory(at path: RelativePath, expecting: FileStamp) throws {
        try syncOperation {
            try withParent(path.string, parents: .existing) { parent, name in
                guard let info = try itemInfo(name, in: parent) else { throw FileStoreError.notFound }
                try requireDirectory(info)
                guard directoryStamp(info) == expecting else { throw SyncFileOperationError(.changed) }
                try verifyPinnedRoot()
                guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
                    throw SyncFileOperationError(errno == ENOTEMPTY || errno == EEXIST ? .occupied : .ioFailure)
                }
                do { try flushDirectory(at: parentPath(of: path)) }
                catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
            }
        }
    }

    private func checkedBytes(at path: RelativePath, expecting: SyncFileExpectation) throws -> Data? {
        let stamp = try stamp(at: path.string)
        switch expecting {
        case .absent:
            guard stamp == nil else { throw SyncFileOperationError(.changed) }
            return nil
        case .matching(let expected, let bytes):
            guard stamp == expected else { throw SyncFileOperationError(.changed) }
            let current = try read(at: path.string)
            guard current == bytes, try self.stamp(at: path.string) == expected else { throw SyncFileOperationError(.changed) }
            return current
        }
    }

    private func parts(_ path: String) -> [String] {
        // Slash + combining mark can be one Character. POSIX separates scalars.
        path.unicodeScalars.split(separator: "/").map { String(String.UnicodeScalarView($0)) }
    }

    private func parentPath(of path: RelativePath) -> RelativePath? {
        let scalars = path.string.unicodeScalars
        guard let slash = scalars.lastIndex(of: "/") else { return nil }
        return RelativePath(String(scalars[..<slash]))
    }

    private func withParent<T>(_ path: String, parents: Parents, flush: Flush = .ordinary,
                               _ work: (Int32, String) throws -> T) throws -> T {
        try FileStorePath.validate(path)
        guard var descriptor = try openRoot(parents: parents) else { throw FileStoreError.notFound }
        defer { _ = Darwin.close(descriptor) }
        let components = parts(path)
        for part in components.dropLast() {
            guard let child = try openDirectory(part, in: descriptor, parents: parents, flush: flush) else {
                throw FileStoreError.notFound
            }
            _ = Darwin.close(descriptor)
            descriptor = child
        }
        return try work(descriptor, components.last!)
    }

    private func withDirectory<T>(_ path: RelativePath?, _ work: (Int32) throws -> T) throws -> T {
        guard let path else {
            guard let descriptor = try openRoot(parents: .existing) else { throw FileStoreError.notFound }
            defer { _ = Darwin.close(descriptor) }
            return try work(descriptor)
        }
        return try withParent(path.string, parents: .existing) { parent, name in
            guard let descriptor = try openDirectory(name, in: parent, parents: .existing) else { throw FileStoreError.notFound }
            defer { _ = Darwin.close(descriptor) }
            return try work(descriptor)
        }
    }

    private func openRoot(parents: Parents, flush: Flush = .ordinary) throws -> Int32? {
        rootLock.lock()
        let pinned = pinnedRoot
        rootLock.unlock()
        let components = root.pathComponents.dropFirst()
        var descriptor = Darwin.open("/", (flush == .checked ? O_RDONLY : O_EVTONLY) | Self.directoryFlags)
        guard descriptor >= 0 else { throw FileStoreError.ioFailure }
        defer { if descriptor >= 0 { _ = Darwin.close(descriptor) } }
        if flush == .checked, !syncIO.flush(descriptor) { throw SyncFileOperationError(.durabilityFailed) }
        for (index, part) in components.enumerated() {
            let read = flush == .checked || index == components.count - 1
            guard let child = try openDirectory(part, in: descriptor, parents: pinned == nil ? parents : .existing,
                                                access: read ? O_RDONLY : O_EVTONLY) else {
                if pinned != nil { throw FileStoreError.notFound }
                return nil
            }
            _ = Darwin.close(descriptor)
            descriptor = child
            if flush == .checked, !syncIO.flush(descriptor) { throw SyncFileOperationError(.durabilityFailed) }
        }
        if let pinned, directoryStamp(try descriptorInfo(descriptor)) != pinned { throw FileStoreError.notFound }
        let result = descriptor
        descriptor = -1
        return result
    }

    private func verifyPinnedRoot() throws {
        rootLock.lock()
        let pinned = pinnedRoot
        rootLock.unlock()
        if pinned != nil { try requireRoot() }
    }

    private func openDirectory(_ name: String, in parent: Int32, parents: Parents,
                               flush: Flush = .ordinary, access: Int32 = O_RDONLY) throws -> Int32? {
        var descriptor = openat(parent, name, access | Self.directoryFlags)
        if descriptor >= 0 { return descriptor }
        guard let info = try itemInfo(name, in: parent) else {
            guard parents == .create else { return nil }
            guard mkdirat(parent, name, mode_t(0o777)) == 0 else { throw FileStoreError.ioFailure }
            descriptor = openat(parent, name, access | Self.directoryFlags)
            guard descriptor >= 0 else { throw FileStoreError.ioFailure }
            if flush == .checked, !syncIO.flush(descriptor) || !syncIO.flush(parent) {
                _ = Darwin.close(descriptor)
                throw SyncFileOperationError(.durabilityFailed, effect: .applied)
            }
            return descriptor
        }
        try requireDirectory(info)
        throw FileStoreError.ioFailure
    }

    private func itemInfo(_ name: String, in parent: Int32) throws -> Darwin.stat? {
        var info = Darwin.stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        if errno == ENOENT { return nil }
        throw FileStoreError.ioFailure
    }

    private func descriptorInfo(_ descriptor: Int32) throws -> Darwin.stat {
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { throw FileStoreError.ioFailure }
        return info
    }

    private func isType(_ info: Darwin.stat, _ type: mode_t) -> Bool { info.st_mode & mode_t(S_IFMT) == type }
    private func requireRegular(_ info: Darwin.stat) throws {
        if isType(info, mode_t(S_IFLNK)) { throw FileStoreError.outsideRoot }
        guard isType(info, mode_t(S_IFREG)) else { throw FileStoreError.notRegularFile }
    }
    private func requireDirectory(_ info: Darwin.stat) throws {
        if isType(info, mode_t(S_IFLNK)) { throw FileStoreError.outsideRoot }
        guard isType(info, mode_t(S_IFDIR)) else { throw FileStoreError.invalidRoot }
    }

    private func regularFile(_ name: String, in parent: Int32) throws -> Int32 {
        guard let info = try itemInfo(name, in: parent) else { throw FileStoreError.notFound }
        try requireRegular(info)
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FileStoreError.ioFailure }
        do { try requireRegular(descriptorInfo(descriptor)) }
        catch { _ = Darwin.close(descriptor); throw error }
        return descriptor
    }

    private func temporaryFile(in parent: Int32, permissions: mode_t) throws -> (Int32, String) {
        for _ in 0..<Limits.exclusiveCreateAttemptCap {
            let name = ".monkeyspaw-sync-" + UUID().uuidString
            let descriptor = openat(parent, name, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, permissions)
            if descriptor >= 0 { return (descriptor, name) }
            guard errno == EEXIST || errno == EINTR else { throw FileStoreError.ioFailure }
        }
        throw FileStoreError.ioFailure
    }

    private func readBytes(_ descriptor: Int32) throws -> Data {
        try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
    }

    private static func flushDescriptor(_ descriptor: Int32) -> Bool {
        guard fsync(descriptor) == 0 else { return false }
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { return false }
        // On Darwin fsync alone can leave drive caches unordered. Unsupported
        // full flushes fail closed, rather than acknowledging a weaker commit.
        if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
            return fcntl(descriptor, F_FULLFSYNC) == 0
        }
        return true
    }

    private func writeAll(_ bytes: Data, to descriptor: Int32) throws {
        try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                throw FileStoreError.ioFailure
            }
        }
    }

    private func childNames(in descriptor: Int32) throws -> [String] {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw FileStoreError.ioFailure }
        guard let stream = fdopendir(duplicate) else { _ = Darwin.close(duplicate); throw FileStoreError.ioFailure }
        defer { _ = closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw FileStoreError.ioFailure }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    private func collect(in descriptor: Int32, prefix: String, into result: inout [StoredFile]) throws {
        for name in try childNames(in: descriptor) {
            guard let info = try itemInfo(name, in: descriptor) else { continue }
            let path = prefix + name
            if isType(info, mode_t(S_IFDIR)) {
                guard let child = try openDirectory(name, in: descriptor, parents: .existing) else { continue }
                defer { _ = Darwin.close(child) }
                try collect(in: child, prefix: path + "/", into: &result)
            } else if isType(info, mode_t(S_IFREG)) {
                try FileStorePath.validate(path)
                result.append(StoredFile(relativePath: path, stamp: fileStamp(info)))
            }
        }
    }

    private func directoryStamp(_ info: Darwin.stat) -> FileStamp {
        FileStamp("\(info.st_dev):\(info.st_ino):\(info.st_gen):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)")
    }
    private func fileStamp(_ info: Darwin.stat) -> FileStamp {
        FileStamp("\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):"
            + "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)")
    }

    private func syncOperation<T>(_ work: () throws -> T) throws -> T {
        do { return try work() }
        catch let error as SyncFileOperationError { throw error }
        catch let error as FileStoreError {
            let code: SyncFileFailureCode
            switch error {
            case .invalidPath, .outsideRoot, .invalidRoot, .notRegularFile: code = .invalidPath
            case .notFound: code = .notFound
            case .alreadyExists: code = .occupied
            case .ioFailure: code = .ioFailure
            }
            throw SyncFileOperationError(code)
        } catch { throw SyncFileOperationError(.ioFailure) }
    }
    private func fileOperation<T>(_ work: () throws -> T) throws -> T {
        do { return try work() }
        catch let error as FileStoreError { throw error }
        catch { throw FileStoreError.ioFailure }
    }
}
