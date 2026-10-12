import Darwin
import Foundation
import MonkeysPawCore

/// Driver-local snapshot and canonical ancestor topology for the recursive
/// FSEvents stream. Scans stay anchored to opened directories so replacing
/// an ancestor cannot redirect enumeration through a symlink.
final class FileWatchTree {
    private enum Location { case tree, rootComponent }
    private struct RootUnavailable: Error { let reason: FileStoreError }
    struct Node: Equatable {
        enum Kind { case directory, file }
        let kind: Kind
        let identity: String
        let stamp: FileStamp
    }

    struct Snapshot {
        var files = [RelativePath: Node]()
        var nodes = [Data: Node]()
        var rootError: FileStoreError? = .notFound
    }

    let root: URL
    private static let directoryFlags = O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    init(root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw FileStoreError.invalidRoot }
        // Mirror RootedFileStore's POSIX resolution exactly, including literal
        // missing tails and Darwin's /var -> /private/var ancestor.
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

        var directory = URL(fileURLWithPath: "/", isDirectory: true)
        for part in canonical.pathComponents.dropFirst() {
            directory.appendPathComponent(part, isDirectory: true)
            guard let node = try Self.node(at: directory, location: .rootComponent) else { break }
            guard node.kind == .directory else { throw FileStoreError.invalidRoot }
        }
    }

    /// Record safe canonical ancestors so the stream can attach to the
    /// nearest existing directory when the root is missing or replaced.
    /// Internal hooks bracket fd-relative enumeration for deterministic races.
    func scan(beforeEnumeration: () throws -> Void = {}, afterEnumeration: () throws -> Void = {}) throws -> Snapshot {
        var snapshot = Snapshot()
        guard let descriptor = try openRoot(into: &snapshot) else { return snapshot }
        defer { _ = Darwin.close(descriptor) }
        let ancestors = snapshot.nodes

        var enumerationError: Error?
        do {
            try beforeEnumeration()
            try collect(in: descriptor, prefix: "", into: &snapshot)
            try afterEnumeration()
        } catch { enumerationError = error }

        // Rewalk from / without following links. The fresh topology, even on
        // failure, prevents rearming FSEvents through a detached ancestor.
        var checked = Snapshot()
        if let current = try openRoot(into: &checked) { _ = Darwin.close(current) }
        if checked.rootError != nil { return checked }
        guard ancestors.allSatisfy({ checked.nodes[$0.key]?.identity == $0.value.identity }) else {
            checked.rootError = .notFound
            return checked
        }
        if let error = enumerationError {
            if let loss = error as? RootUnavailable {
                checked.rootError = loss.reason
                return checked
            }
            throw error
        }
        return snapshot
    }

    /// Returns an owned root descriptor, or only the safe ancestor topology
    /// and typed root loss. Every openat name is exactly one path component.
    private func openRoot(into snapshot: inout Snapshot) throws -> Int32? {
        // O_EVTONLY permits traversing search-only ancestors without requiring
        // read permission on them. Only the library itself is opened for reading.
        var descriptor = Darwin.open("/", O_EVTONLY | Self.directoryFlags)
        guard descriptor >= 0 else { throw FileStoreError.ioFailure }
        defer { if descriptor >= 0 { _ = Darwin.close(descriptor) } }
        var directory = URL(fileURLWithPath: "/", isDirectory: true)
        snapshot.nodes[Data(directory.path.utf8)] = try Self.directoryNode(at: descriptor)

        let parts = root.pathComponents.dropFirst()
        for (index, part) in parts.enumerated() {
            let access = index == parts.count - 1 ? O_RDONLY : O_EVTONLY
            let (child, failure) = part.withCString {
                let opened = Darwin.openat(descriptor, $0, access | Self.directoryFlags)
                return (opened, errno)
            }
            guard child >= 0 else {
                snapshot.rootError = Self.directoryFailure(part, relativeTo: descriptor, failure: failure)
                return nil
            }
            _ = Darwin.close(descriptor)
            descriptor = child
            directory.appendPathComponent(part, isDirectory: true)
            do { snapshot.nodes[Data(directory.path.utf8)] = try Self.directoryNode(at: descriptor) }
            catch {
                snapshot.rootError = error as? FileStoreError ?? .ioFailure
                return nil
            }
        }
        guard Darwin.faccessat(descriptor, ".", R_OK | X_OK, 0) == 0 else {
            snapshot.rootError = .ioFailure
            return nil
        }
        snapshot.rootError = nil
        let opened = descriptor
        descriptor = -1 // Transfer ownership to the scan.
        return opened
    }

    /// O_DIRECTORY/O_NOFOLLOW can reject a link with ENOTDIR or ELOOP.
    /// Classify it using only the already-open parent, never its pathname.
    private static func directoryFailure(_ name: String, relativeTo descriptor: Int32, failure: Int32) -> FileStoreError {
        var info = Darwin.stat()
        if Darwin.fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) { return .outsideRoot }
            if info.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) { return .invalidRoot }
        }
        switch failure {
        case ENOENT: return .notFound
        case ENOTDIR: return .invalidRoot
        case ELOOP: return .outsideRoot
        default: return .ioFailure
        }
    }

    /// Emits regular files only, ordered by UTF-8 path bytes. Directory nodes
    /// describe monitor topology and never appear in the diff.
    static func changes(from old: Snapshot, to new: Snapshot) -> [FileStoreEvent] {
        let paths = Set(old.files.keys).union(new.files.keys)
        return paths.sorted().compactMap { path in
            let kind: FileStoreEvent.Kind
            switch (old.files[path], new.files[path]) {
            case (nil, .some): kind = .created
            case (.some, nil): kind = .deleted
            case (let before?, let after?) where before != after: kind = .modified
            default: return nil
            }
            return FileStoreEvent(relativePath: path.string, kind: kind)
        }
    }

    private func collect(in descriptor: Int32, prefix: String, into snapshot: inout Snapshot) throws {
        let enumerationFailure: Error = prefix.isEmpty ? RootUnavailable(reason: .ioFailure) : FileStoreError.ioFailure
        // fdopendir owns its descriptor on success; retain the scan's descriptor
        // for openat/fstatat and close the duplicate only via closedir.
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw enumerationFailure }
        guard let stream = Darwin.fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            throw enumerationFailure
        }
        defer { _ = Darwin.closedir(stream) }

        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                guard errno == 0 else { throw enumerationFailure }
                return
            }
            let nameLength = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: nameLength) { String(validatingUTF8: $0) }
            }
            // Unrepresentable native names cannot become UTF-8 Core paths.
            guard let name, name != ".", name != ".." else { continue }
            let path = prefix + name
            // Mirror FileStore visibility: invalid paths are unobservable to both layers.
            guard (try? FileStorePath.validate(path)) != nil else { continue }
            var info = Darwin.stat()
            guard Darwin.fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT || errno == ENOTDIR { continue }
                throw FileStoreError.ioFailure
            }
            guard let node = Self.node(info) else { continue }
            if node.kind == .directory {
                // A child can be swapped after fstatat too. Never follow it,
                // and take directory identity from the descriptor actually read.
                let (child, failure) = name.withCString {
                    let opened = Darwin.openat(descriptor, $0, O_RDONLY | Self.directoryFlags)
                    return (opened, errno)
                }
                guard child >= 0 else {
                    if failure == ENOENT || failure == ENOTDIR || failure == ELOOP { continue }
                    throw FileStoreError.ioFailure
                }
                defer { _ = Darwin.close(child) }
                snapshot.nodes[Data(root.appendingPathComponent(path).path.utf8)] = try Self.directoryNode(at: child)
                try collect(in: child, prefix: path + "/", into: &snapshot)
            } else {
                snapshot.files[RelativePath(path)] = node
            }
        }
    }

    private static func directoryNode(at descriptor: Int32) throws -> Node {
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0, let node = Self.node(info), node.kind == .directory else {
            throw FileStoreError.ioFailure
        }
        return node
    }

    private static func node(at url: URL, location: Location = .tree) throws -> Node? {
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw FileStoreError.ioFailure
        }
        if location == .rootComponent {
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) { throw FileStoreError.outsideRoot }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw FileStoreError.invalidRoot }
        }
        return node(info)
    }

    private static func node(_ info: Darwin.stat) -> Node? {
        let kind: Node.Kind
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFREG): kind = .file
        default: return nil // Never follow or emit symlinks or special files.
        }
        let identity = "\(info.st_dev):\(info.st_ino)"
        let stamp = FileStamp(identity + ":\(info.st_size):"
            + "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):"
            + "\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)")
        return Node(kind: kind, identity: identity, stamp: stamp)
    }
}
