#if os(Linux)
import CGtk
import Foundation
import Glibc
import MonkeysPawCore

/// Foundation owns reads/replacements; POSIX handles exclusive creation and
/// supplies nanosecond change time and inode identity for stamps. No filesystem
/// error text escapes.
/// Per-component checks and the atomic-write window are check-then-act: they
/// defend accidents, not a racing local adversary. Unlink bounds deletion;
/// full fd-relative hardening is deferred.
final class RootedFileStore: FileStore, SyncFileOperations {
    private enum Parents { case existing, create }
    private enum DirectoryIdentity { case root, sync }

    private let root: URL
    private let manager = FileManager.default
    private let syncDescriptor: (Int32) -> Int32
    private let trashRoot: URL
    private let rootLock = NSLock()
    private var rootIdentity: FileStamp?

    init(root: URL, trashRoot: URL? = nil, syncDescriptor: @escaping (Int32) -> Int32 = Glibc.fsync) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw FileStoreError.invalidRoot }
        // POSIX resolution is required: Foundation's URL resolver does not
        // canonicalize /var -> /private/var on Darwin. Resolve each prefix;
        // keep unresolved components literal for later operation checks.
        var canonicalRoot = URL(fileURLWithPath: "/", isDirectory: true)
        for component in Self.components(root.standardizedFileURL.path) {
            canonicalRoot.appendPathComponent(component, isDirectory: true)
            if let resolvedPath = realpath(canonicalRoot.path, nil) {
                canonicalRoot = URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
                free(resolvedPath)
            }
        }
        guard canonicalRoot.path != "/" else { throw FileStoreError.invalidRoot }

        self.root = canonicalRoot
        self.trashRoot = trashRoot ?? LinuxPaths().dataDirectory.deletingLastPathComponent().appendingPathComponent("Trash")
        self.syncDescriptor = syncDescriptor
        // Missing roots are intentional: writes create them lazily. This check
        // only rejects symlink or non-directory ancestors that already exist.
        _ = try sanitized { try rootExists(parents: .existing) }
    }

    /// A library selection may use a symlinked home/ancestor, but the selected
    /// directory itself must not be an alias. Config/data keep their root rules.
    convenience init(libraryRoot root: URL, trashRoot: URL? = nil) throws {
        try self.init(root: root, trashRoot: trashRoot)
        try sanitized {
            if let attributes = try attributes(at: root),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw FileStoreError.outsideRoot
            }
        }
    }

    func listFiles() throws -> [StoredFile] {
        try sanitized {
            guard try rootExists(parents: .existing) else { return [] }
            var result = [StoredFile]()
            try collect(in: root, prefix: "", into: &result)
            return result.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
        }
    }

    /// Composition prepares the default library, rather than writing a sentinel.
    func createRoot() throws {
        try sanitized { _ = try rootExists(parents: .create) }
    }

    /// A vanished library must not publish deletions over the cached index.
    func requireRoot() throws {
        try sanitized {
            guard try rootExists(parents: .existing) else { throw FileStoreError.notFound }
        }
    }

    func stamp(at path: String) throws -> FileStamp? {
        try sanitized {
            guard let url = try locate(path, parents: .existing), let attributes = try attributes(at: url) else {
                return nil
            }
            try requireRegular(attributes)
            return try fileStamp(at: url)
        }
    }

    func read(at path: String) throws -> Data {
        try sanitized {
            guard let url = try locate(path, parents: .existing), let attributes = try attributes(at: url) else {
                throw FileStoreError.notFound
            }
            try requireRegular(attributes)
            return try Data(contentsOf: url)
        }
    }

    func write(_ data: Data, at path: String) throws {
        try sanitized {
            guard let url = try locate(path, parents: .create) else { throw FileStoreError.invalidRoot }
            if let attributes = try attributes(at: url) { try requireRegular(attributes) }
            try data.write(to: url, options: .atomic)
        }
    }

    func create(_ data: Data, at path: String) throws {
        try sanitized {
            guard let url = try locate(path, parents: .create) else { throw FileStoreError.invalidRoot }
            let parent = url.deletingLastPathComponent()
            var generator = SystemRandomNumberGenerator()
            var descriptor: Int32 = -1
            var temporaryPath = ""
            for _ in 0..<Limits.exclusiveCreateAttemptCap {
                // Two independent 64-bit draws keep the temporary name unguessable.
                let suffix = String(generator.next(), radix: 16) + "-" + String(generator.next(), radix: 16)
                let candidate = parent.appendingPathComponent(".monkeyspaw-create-" + suffix).path
                // The kernel applies umask at creation without changing the process mask.
                let opened = candidate.withCString {
                    Glibc.open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, mode_t(0o666))
                }
                if opened >= 0 {
                    descriptor = opened
                    temporaryPath = candidate
                    break
                }
                // EEXIST means a name collision and EINTR an interrupted call; retry both.
                guard errno == EEXIST || errno == EINTR else { throw FileStoreError.ioFailure }
            }
            guard descriptor >= 0 else { throw FileStoreError.ioFailure }
            defer {
                _ = unlink(temporaryPath)
                _ = Glibc.close(descriptor)
            }
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let written = Glibc.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written > 0 {
                        offset += written
                        continue
                    }
                    if written < 0 && errno == EINTR { continue }
                    throw FileStoreError.ioFailure
                }
            }
            guard fsync(descriptor) == 0 else { throw FileStoreError.ioFailure }
            // link publishes complete bytes and atomically refuses any existing
            // leaf, including directories and dangling symlinks, without following it.
            guard link(temporaryPath, url.path) == 0 else {
                throw errno == EEXIST ? FileStoreError.alreadyExists : FileStoreError.ioFailure
            }
            // Persist the new directory entry too; best-effort like writePrivate,
            // since some filesystems reject directory fsync.
            let directoryDescriptor = Glibc.open(parent.path, O_RDONLY | O_CLOEXEC)
            if directoryDescriptor >= 0 {
                _ = fsync(directoryDescriptor)
                _ = Glibc.close(directoryDescriptor)
            }
        }
    }

    func writePrivate(_ data: Data, at path: String) throws {
        try sanitized {
            guard let url = try locate(path, parents: .create) else { throw FileStoreError.invalidRoot }
            if let attributes = try attributes(at: url) { try requireRegular(attributes) }

            // mkstemp creates a private file. fchmod pins 0600 even under a
            // restrictive umask, before any bytes are written or renamed.
            var template = Array(url.deletingLastPathComponent()
                .appendingPathComponent(".monkeyspaw-private-XXXXXX").path.utf8CString)
            let descriptor = mkstemp(&template)
            guard descriptor >= 0 else { throw FileStoreError.ioFailure }
            let temporaryPath = String(cString: template)
            defer {
                _ = Glibc.close(descriptor)
                _ = unlink(temporaryPath)
            }
            guard fchmod(descriptor, mode_t(Limits.privateFileMode)) == 0 else { throw FileStoreError.ioFailure }
            // Data.write consumes all bytes or throws; a FileHandle single
            // write(2) could silently publish a truncated private file.
            try data.write(to: URL(fileURLWithPath: temporaryPath))
            guard fsync(descriptor) == 0 else { throw FileStoreError.ioFailure }
            guard rename(temporaryPath, url.path) == 0 else { throw FileStoreError.ioFailure }
            // Persist the directory entry too; best-effort, since some
            // filesystems reject directory fsync.
            let dirFd = Glibc.open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
            if dirFd >= 0 {
                _ = fsync(dirFd)
                _ = Glibc.close(dirFd)
            }
        }
    }

    func delete(at path: String) throws {
        try sanitized {
            guard let url = try locate(path, parents: .existing), let attributes = try attributes(at: url) else {
                throw FileStoreError.notFound
            }
            try requireRegular(attributes)
            guard unlink(url.path) == 0 else {
                throw errno == ENOENT ? FileStoreError.notFound : FileStoreError.ioFailure
            }
        }
    }

    func move(from source: String, to destination: String) throws {
        try sanitized {
            // Validate both names before creating any directories.
            try FileStorePath.validate(source)
            try FileStorePath.validate(destination)
            guard let sourceURL = try locate(source, parents: .existing),
                  let sourceAttributes = try attributes(at: sourceURL) else { throw FileStoreError.notFound }
            try requireRegular(sourceAttributes)
            if let existingURL = try locate(destination, parents: .existing),
               let existing = try attributes(at: existingURL) {
                if existing[.type] as? FileAttributeType == .typeSymbolicLink { throw FileStoreError.outsideRoot }
                throw FileStoreError.alreadyExists
            }
            guard let destinationURL = try locate(destination, parents: .create) else {
                throw FileStoreError.invalidRoot
            }
            try manager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private func locate(_ path: String, parents: Parents) throws -> URL? {
        try FileStorePath.validate(path)
        guard try rootExists(parents: parents) else { return nil }
        let parts = Self.components(path)
        guard let filename = parts.last else { throw FileStoreError.notFound }
        var directory = root
        for part in parts.dropLast() {
            directory.appendPathComponent(part, isDirectory: true)
            guard try ensureDirectory(directory, parents: parents) else { return nil }
        }
        return directory.appendingPathComponent(filename)
    }

    private func rootExists(parents: Parents) throws -> Bool {
        rootLock.lock()
        defer { rootLock.unlock() }
        // Recheck the canonical root's ancestors too: a replaced root/ancestor
        // must not redirect subsequent operations outside the chosen tree.
        var directory = URL(fileURLWithPath: "/", isDirectory: true)
        for part in Self.components(root.path) {
            directory.appendPathComponent(part, isDirectory: true)
            if rootIdentity != nil, try attributes(at: directory) == nil { throw FileStoreError.notFound }
            guard try ensureDirectory(directory, parents: parents) else { return false }
        }
        let identity = try directoryStamp(at: root)
        if let rootIdentity, identity != rootIdentity { throw FileStoreError.invalidRoot }
        rootIdentity = identity
        return true
    }

    private static func components(_ path: String) -> [String] {
        path.utf8.split(separator: UInt8(ascii: "/")).map { String(decoding: $0, as: UTF8.self) }
    }

    private func ensureDirectory(_ url: URL, parents: Parents) throws -> Bool {
        if let attributes = try attributes(at: url) {
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw FileStoreError.outsideRoot }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw FileStoreError.invalidRoot }
            return true
        }
        guard parents == .create else { return false }
        try manager.createDirectory(at: url, withIntermediateDirectories: false)
        return true
    }

    private func collect(in directory: URL, prefix: String, into result: inout [StoredFile]) throws {
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let attributes = try attributes(at: url) else { continue }
            let path = prefix + url.lastPathComponent
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink: continue
            case .typeDirectory:
                try collect(in: url, prefix: path + "/", into: &result)
            case .typeRegular:
                try FileStorePath.validate(path)
                result.append(StoredFile(relativePath: path, stamp: try fileStamp(at: url)))
            default: continue
            }
        }
    }

    private func attributes(at url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try manager.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) { return nil }
    }

    private func requireRegular(_ attributes: [FileAttributeKey: Any]) throws {
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw FileStoreError.outsideRoot }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw FileStoreError.notRegularFile }
    }

    private func fileStamp(at url: URL) throws -> FileStamp {
        var info = Glibc.stat()
        guard Glibc.lstat(url.path, &info) == 0 else { throw FileStoreError.ioFailure }
        guard info.st_mode & mode_t(Glibc.S_IFMT) == mode_t(Glibc.S_IFREG) else { throw FileStoreError.notRegularFile }
        return FileStamp("\(info.st_dev):\(info.st_ino):\(info.st_size):"
            + "\(info.st_mtim.tv_sec):\(info.st_mtim.tv_nsec):\(info.st_ctim.tv_sec):\(info.st_ctim.tv_nsec)")
    }

    // Sync capabilities keep ordinary FileStore's atomic/best-effort contract.
    // Every post-mutation failure retains the applied effect and losing bytes.
    func publish(_ bytes: Data, at path: RelativePath, expecting: SyncFileExpectation,
                 mode: SyncFileMode) throws -> SyncFilePublication {
        try syncOperation {
            let displaced = try check(path, expecting: expecting)
            guard let url = try locate(path.string, parents: .create) else { throw FileStoreError.invalidRoot }
            let (temporary, descriptor) = try makeTemporary(in: url.deletingLastPathComponent())
            defer { _ = Glibc.close(descriptor); _ = unlink(temporary.path) }
            if mode == .readOnly {
                guard fchmod(descriptor, 0o444) == 0 else { throw SyncFileOperationError(.ioFailure) }
            }
            try writeAll(bytes, descriptor: descriptor)
            try flush(descriptor)
            _ = try check(path, expecting: expecting)
            switch expecting {
            case .absent:
                guard link(temporary.path, url.path) == 0 else {
                    throw SyncFileOperationError(errno == EEXIST ? .occupied : .ioFailure)
                }
                _ = unlink(temporary.path)
            case .matching:
                guard rename(temporary.path, url.path) == 0 else { throw SyncFileOperationError(.ioFailure) }
            }
            do {
                guard try read(at: path.string) == bytes else { throw SyncFileOperationError(.changed) }
                try flushFile(at: path)
                try flushAncestors(of: url.deletingLastPathComponent())
            } catch {
                throw SyncFileOperationError(.durabilityFailed, effect: .applied, displacedBytes: displaced)
            }
            return SyncFilePublication(displacedBytes: displaced)
        }
    }

    func flushFile(at path: RelativePath) throws {
        try syncOperation {
            guard let url = try locate(path.string, parents: .existing), let attributes = try attributes(at: url) else {
                throw FileStoreError.notFound
            }
            try requireRegular(attributes)
            let descriptor = Glibc.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw SyncFileOperationError(.ioFailure) }
            defer { _ = Glibc.close(descriptor) }
            try flush(descriptor)
        }
    }

    func flushDirectory(at path: RelativePath?) throws {
        try syncOperation { try flushDirectoryURL(directory(at: path)) }
    }

    func setMode(_ mode: SyncFileMode, at path: RelativePath) throws {
        try syncOperation {
            guard let url = try locate(path.string, parents: .existing), let attributes = try attributes(at: url) else {
                throw FileStoreError.notFound
            }
            try requireRegular(attributes)
            var permissions: mode_t = 0o444
            if mode == .normal {
                // Let the kernel apply umask without reading/changing process state.
                let (temporary, descriptor) = try makeTemporary(in: url.deletingLastPathComponent())
                defer { _ = Glibc.close(descriptor); _ = unlink(temporary.path) }
                var info = Glibc.stat()
                guard fstat(descriptor, &info) == 0 else { throw SyncFileOperationError(.ioFailure) }
                permissions = info.st_mode & 0o777
            }
            let descriptor = Glibc.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw SyncFileOperationError(.ioFailure) }
            defer { _ = Glibc.close(descriptor) }
            guard fchmod(descriptor, permissions) == 0 else { throw SyncFileOperationError(.ioFailure) }
            do {
                try flush(descriptor)
                try flushAncestors(of: url.deletingLastPathComponent())
            } catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
        }
    }

    func trash(at path: RelativePath, expecting: SyncFileExpectation) throws {
        try syncOperation {
            guard case .matching = expecting else { throw SyncFileOperationError(.changed) }
            _ = try check(path, expecting: expecting)
            guard let source = try locate(path.string, parents: .existing) else { throw FileStoreError.notFound }
            // Freedesktop home trash. Cross-volume rename fails without erasing
            // the source; never substitute unlink or a partially copied file.
            let directories = try prepareTrash()
            let name = UUID().uuidString
            let destination = directories.files.appendingPathComponent(name)
            let info = directories.info.appendingPathComponent(name + ".trashinfo")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
            guard let encoded = source.path.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw SyncFileOperationError(.invalidPath)
            }
            let metadata = Data(("[Trash Info]\nPath=" + encoded + "\nDeletionDate=" + formatter.string(from: Date()) + "\n").utf8)
            let descriptor = Glibc.open(info.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw SyncFileOperationError(.ioFailure) }
            defer { _ = Glibc.close(descriptor) }
            var moved = false
            defer { if !moved { _ = unlink(info.path) } }
            guard fchmod(descriptor, 0o600) == 0 else { throw SyncFileOperationError(.ioFailure) }
            try writeAll(metadata, descriptor: descriptor)
            try flush(descriptor)
            try flushAncestors(of: directories.info)
            _ = try check(path, expecting: expecting)
            guard mp_rename_exclusive(source.path, destination.path) == 0 else { throw SyncFileOperationError(.ioFailure) }
            moved = true
            do {
                let file = Glibc.open(destination.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard file >= 0 else { throw SyncFileOperationError(.ioFailure) }
                defer { _ = Glibc.close(file) }
                try flush(file)
                try flushAncestors(of: directories.files)
                try flushAncestors(of: source.deletingLastPathComponent())
            } catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
        }
    }

    func createDirectory(at path: RelativePath) throws {
        try syncOperation {
            guard let url = try locate(path.string, parents: .create) else { throw FileStoreError.invalidRoot }
            guard try attributes(at: url) == nil else { throw SyncFileOperationError(.occupied) }
            guard mkdir(url.path, 0o777) == 0 else {
                throw SyncFileOperationError(errno == EEXIST ? .occupied : .ioFailure)
            }
            do { try flushAncestors(of: url) }
            catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
        }
    }

    func renameDirectory(from source: RelativePath, to destination: RelativePath) throws {
        try syncOperation {
            try FileStorePath.validate(destination.string)
            let sourceURL = try directory(at: source)
            guard let destinationURL = try locate(destination.string, parents: .existing) else { throw FileStoreError.notFound }
            guard try attributes(at: destinationURL) == nil else { throw SyncFileOperationError(.occupied) }
            guard mp_rename_exclusive(sourceURL.path, destinationURL.path) == 0 else {
                throw SyncFileOperationError(errno == EEXIST ? .occupied : .ioFailure)
            }
            do {
                try flushAncestors(of: sourceURL.deletingLastPathComponent())
                try flushAncestors(of: destinationURL.deletingLastPathComponent())
            } catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
        }
    }

    func directories(at path: RelativePath?) throws -> [RelativePath] {
        try syncOperation {
            let directory = try directory(at: path)
            return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { url in
                guard try attributes(at: url)?[.type] as? FileAttributeType == .typeDirectory else { return nil }
                let relative = (path.map { $0.string + "/" } ?? "") + url.lastPathComponent
                try FileStorePath.validate(relative)
                return RelativePath(relative)
            }.sorted { $0.string.utf8.lexicographicallyPrecedes($1.string.utf8) }
        }
    }

    func directoryIdentity(at path: RelativePath) throws -> FileStamp? {
        try syncOperation {
            guard let url = try locate(path.string, parents: .existing), try attributes(at: url) != nil else { return nil }
            _ = try ensureDirectory(url, parents: .existing)
            return try directoryStamp(at: url, kind: .sync)
        }
    }

    func removeEmptyDirectory(at path: RelativePath, expecting: FileStamp) throws {
        try syncOperation {
            let url = try directory(at: path)
            guard try directoryStamp(at: url, kind: .sync) == expecting else { throw SyncFileOperationError(.changed) }
            guard rmdir(url.path) == 0 else {
                throw SyncFileOperationError(errno == ENOTEMPTY || errno == EEXIST ? .occupied : .ioFailure)
            }
            do { try flushAncestors(of: url.deletingLastPathComponent()) }
            catch { throw SyncFileOperationError(.durabilityFailed, effect: .applied) }
        }
    }

    private func directory(at path: RelativePath?) throws -> URL {
        guard try rootExists(parents: .existing) else { throw FileStoreError.notFound }
        _ = try directoryStamp(at: root, kind: .sync)
        guard let path else { return root }
        guard let url = try locate(path.string, parents: .existing), try ensureDirectory(url, parents: .existing) else {
            throw FileStoreError.notFound
        }
        return url
    }

    private func directoryStamp(at url: URL, kind: DirectoryIdentity = .root) throws -> FileStamp {
        var info = Glibc.stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(Glibc.S_IFMT) == mode_t(Glibc.S_IFDIR) else {
            throw FileStoreError.invalidRoot
        }
        var seconds: Int64 = 0
        var nanos: UInt32 = 0
        let hasBirth = mp_directory_birth(url.path, &seconds, &nanos) == 0
        // Ordinary stores remain usable on filesystems without statx birth time.
        // Sync cannot promise directory incarnation there, so it fails closed.
        guard hasBirth || kind == .root else { throw FileStoreError.ioFailure }
        return FileStamp("\(info.st_dev):\(info.st_ino):\(seconds):\(nanos)")
    }

    private func check(_ path: RelativePath, expecting: SyncFileExpectation) throws -> Data? {
        try FileStorePath.validate(path.string)
        let stamp = try stamp(at: path.string)
        switch expecting {
        case .absent:
            guard stamp == nil else { throw SyncFileOperationError(.occupied) }
            return nil
        case .matching(let expected, let bytes):
            guard stamp == expected, try read(at: path.string) == bytes else { throw SyncFileOperationError(.changed) }
            return bytes
        }
    }

    private func makeTemporary(in directory: URL) throws -> (URL, Int32) {
        for _ in 0..<Limits.exclusiveCreateAttemptCap {
            let url = directory.appendingPathComponent(".monkeyspaw-sync-" + UUID().uuidString)
            let descriptor = Glibc.open(url.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o666)
            if descriptor >= 0 { return (url, descriptor) }
            guard errno == EEXIST || errno == EINTR else { throw SyncFileOperationError(.ioFailure) }
        }
        throw SyncFileOperationError(.ioFailure)
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Glibc.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                throw SyncFileOperationError(.ioFailure)
            }
        }
    }

    private func flush(_ descriptor: Int32) throws {
        while syncDescriptor(descriptor) != 0 {
            guard errno == EINTR else { throw SyncFileOperationError(.durabilityFailed) }
        }
    }

    private func flushAncestors(of url: URL) throws {
        var directory = url
        while true {
            try flushDirectoryURL(directory)
            if directory.path == "/" { return }
            directory.deleteLastPathComponent()
        }
    }

    private func flushDirectoryURL(_ directory: URL) throws {
        guard try ensureDirectory(directory, parents: .existing) else { throw FileStoreError.notFound }
        let descriptor = Glibc.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SyncFileOperationError(.ioFailure) }
        defer { _ = Glibc.close(descriptor) }
        try flush(descriptor)
    }

    private func prepareTrash() throws -> (files: URL, info: URL) {
        guard trashRoot.isFileURL, trashRoot.path.hasPrefix("/"), trashRoot.path != "/" else {
            throw FileStoreError.invalidRoot
        }
        var parent = URL(fileURLWithPath: "/", isDirectory: true)
        for component in Self.components(trashRoot.deletingLastPathComponent().path) {
            parent.appendPathComponent(component, isDirectory: true)
            _ = try ensureDirectory(parent, parents: .create)
        }
        let files = trashRoot.appendingPathComponent("files")
        let info = trashRoot.appendingPathComponent("info")
        for url in [trashRoot, files, info] {
            if try attributes(at: url) == nil {
                try manager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            _ = try ensureDirectory(url, parents: .existing)
            var attributes = Glibc.stat()
            guard lstat(url.path, &attributes) == 0, attributes.st_uid == geteuid(), attributes.st_mode & 0o777 == 0o700 else {
                throw SyncFileOperationError(.ioFailure)
            }
        }
        return (files, info)
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
        }
        catch { throw SyncFileOperationError(.ioFailure) }
    }

    private func sanitized<T>(_ work: () throws -> T) throws -> T {
        do { return try work() }
        catch let error as FileStoreError { throw error }
        catch { throw FileStoreError.ioFailure }
    }
}
#endif
