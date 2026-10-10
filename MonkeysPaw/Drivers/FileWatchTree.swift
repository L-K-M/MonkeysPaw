import Darwin
import Foundation
import MonkeysPawCore

/// Driver-local snapshot and canonical ancestor topology for the recursive
/// FSEvents stream. Like FileStore, component checks guard accidents, not
/// racing adversaries.
final class FileWatchTree {
    private enum Location { case tree, rootComponent }
    struct Node: Equatable {
        enum Kind { case directory, file }
        let kind: Kind
        let identity: String
        let stamp: FileStamp
    }

    struct Snapshot {
        var files = [String: Node]()
        var nodes = [String: Node]()
    }

    let root: URL
    private let manager = FileManager.default

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
    func scan() throws -> Snapshot {
        var snapshot = Snapshot()
        var directory = URL(fileURLWithPath: "/", isDirectory: true)
        guard let filesystemRoot = try Self.node(at: directory) else { throw FileStoreError.ioFailure }
        snapshot.nodes[directory.path] = filesystemRoot

        for part in root.pathComponents.dropFirst() {
            directory.appendPathComponent(part, isDirectory: true)
            guard let node = try Self.node(at: directory), node.kind == .directory else { return snapshot }
            snapshot.nodes[directory.path] = node
        }
        try collect(in: root, prefix: "", into: &snapshot)
        return snapshot
    }

    static func changes(from old: Snapshot, to new: Snapshot) -> [FileStoreEvent] {
        let paths = Set(old.files.keys).union(new.files.keys)
        return paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.compactMap { path in
            let kind: FileStoreEvent.Kind
            switch (old.files[path], new.files[path]) {
            case (nil, .some): kind = .created
            case (.some, nil): kind = .deleted
            case (let before?, let after?) where before != after: kind = .modified
            default: return nil
            }
            return FileStoreEvent(relativePath: path, kind: kind)
        }
    }

    private func collect(in directory: URL, prefix: String, into snapshot: inout Snapshot) throws {
        let children: [URL]
        do { children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) { return }
        catch { throw FileStoreError.ioFailure }

        for url in children {
            let path = prefix + url.lastPathComponent
            guard (try? FileStorePath.validate(path)) != nil, let node = try Self.node(at: url) else { continue }
            if node.kind == .directory {
                snapshot.nodes[url.path] = node
                try collect(in: url, prefix: path + "/", into: &snapshot)
            } else {
                snapshot.files[path] = node
            }
        }
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
