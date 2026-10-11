import Darwin
import Foundation
import MonkeysPawCore

/// Driver-local snapshot and canonical ancestor topology for the recursive
/// FSEvents stream. Like FileStore, component checks guard accidents, not
/// racing adversaries.
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
        snapshot.nodes[Data(directory.path.utf8)] = filesystemRoot

        for part in root.pathComponents.dropFirst() {
            directory.appendPathComponent(part, isDirectory: true)
            let node: Node
            do {
                guard let existing = try Self.node(at: directory, location: .rootComponent) else { return snapshot }
                node = existing
            } catch {
                snapshot.rootError = error as? FileStoreError ?? .ioFailure
                return snapshot
            }
            snapshot.nodes[Data(directory.path.utf8)] = node
        }
        do {
            try collect(in: root, prefix: "", into: &snapshot)
            snapshot.rootError = rootFailure()
        } catch let error as RootUnavailable {
            snapshot.rootError = error.reason
        } catch {
            guard let reason = rootFailure() else { throw error }
            snapshot.rootError = reason
        }
        return snapshot
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

    private func collect(in directory: URL, prefix: String, into snapshot: inout Snapshot) throws {
        let children: [URL]
        do { children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            if prefix.isEmpty { throw RootUnavailable(reason: .notFound) }
            return
        }
        catch {
            if prefix.isEmpty { throw RootUnavailable(reason: .ioFailure) }
            throw FileStoreError.ioFailure
        }

        for url in children {
            let path = prefix + url.lastPathComponent
            // Mirror FileStore visibility: invalid paths are unobservable to both layers.
            guard (try? FileStorePath.validate(path)) != nil, let node = try Self.node(at: url) else { continue }
            if node.kind == .directory {
                snapshot.nodes[Data(url.path.utf8)] = node
                try collect(in: url, prefix: path + "/", into: &snapshot)
            } else {
                snapshot.files[RelativePath(path)] = node
            }
        }
    }

    /// Root loss can race enumeration after its first successful read. Recheck
    /// before publishing so a partially collected tree cannot invent deletions.
    private func rootFailure() -> FileStoreError? {
        do {
            guard try Self.node(at: root, location: .rootComponent) != nil else { return .notFound }
            return Darwin.access(root.path, R_OK | X_OK) == 0 ? nil : .ioFailure
        } catch { return error as? FileStoreError ?? .ioFailure }
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
