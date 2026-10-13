import Darwin
import Foundation
import MonkeysPawCore

/// Used only on the graph's serial BackgroundWork. Folder reads retain the
/// enumerated root so a replaced interior ancestor cannot redirect a read.
final class MacImportSourceReader: ImportSourceReading {
    private struct Folder {
        let path: String
        let descriptor: Int32
    }

    private var folders: [Folder] = []
    private static let directoryFlags = O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private let willInspectEntry: (String) -> Void

    /// Tests can remove an entry between readdir and its no-follow inspection.
    init(willInspectEntry: @escaping (String) -> Void = { _ in }) {
        self.willInspectEntry = willInspectEntry
    }

    deinit { closeFolders() }

    func requests(for urls: [URL]) -> [ImportRequest] {
        closeFolders()
        var files: [String] = []
        var requests: [ImportRequest] = []
        for url in urls where url.isFileURL {
            var info = Darwin.stat()
            // lstat classifies the selected leaf without resolving a link.
            if Darwin.lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                requests.append(.folder(url.path))
            } else { files.append(url.path) }
        }
        if !files.isEmpty { requests.insert(.files(files), at: 0) }
        return requests
    }

    func listFiles(in folderPath: String) throws -> [ImportSourceEntry] {
        try validateSourcePath(folderPath)
        closeFolders()
        let descriptor: Int32
        if folderPath == "/" {
            descriptor = Darwin.open("/", O_RDONLY | Self.directoryFlags)
            guard descriptor >= 0 else { throw ImportSourceError.ioFailure }
        } else {
            let (parent, name) = try openParent(of: folderPath)
            defer { _ = Darwin.close(parent) }
            descriptor = try openDirectory(name, relativeTo: parent, access: O_RDONLY)
        }
        defer { _ = Darwin.close(descriptor) }
        var entries: [ImportSourceEntry] = []
        try collect(in: descriptor, into: &entries)
        let retained = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard retained >= 0 else { throw ImportSourceError.ioFailure }
        folders.append(Folder(path: folderPath, descriptor: retained))
        return entries
    }

    func readFile(at path: String, maximumBytes: Int) throws -> Data {
        try validateSourcePath(path)
        guard path != "/" else { throw ImportSourceError.notRegularFile }
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw ImportSourceError.invalidPath
        }
        let parent: Int32
        let name: String
        if let folder = folders.filter({ path.utf8.starts(with: ($0.path == "/" ? "/" : $0.path + "/").utf8) })
            .max(by: { $0.path.utf8.count < $1.path.utf8.count }) {
            let prefixCount = folder.path.utf8.count + (folder.path == "/" ? 0 : 1)
            let relative = String(decoding: path.utf8.dropFirst(prefixCount), as: UTF8.self)
            let parts = relative.split(separator: "/").map(String.init)
            guard let last = parts.last else { throw ImportSourceError.invalidPath }
            parent = try walk(parts.dropLast(), from: folder.descriptor)
            name = last
        } else {
            (parent, name) = try openParent(of: path)
        }
        defer { _ = Darwin.close(parent) }
        // Nonblocking avoids opening a raced FIFO before fstat rejects it.
        let descriptor = Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(name, relativeTo: parent, code: errno) }
        defer { _ = Darwin.close(descriptor) }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw ImportSourceError.ioFailure }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ImportSourceError.notRegularFile }

        // Read the cap plus one, even if the file grows after inspection.
        var bytes = Data(count: maximumBytes + 1)
        var count = 0
        try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            while count < buffer.count {
                let read = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if read < 0 {
                    if errno == EINTR { continue }
                    throw ImportSourceError.ioFailure
                }
                if read == 0 { break }
                count += read
            }
        }
        guard count <= maximumBytes else { throw ImportSourceError.fileTooLarge }
        bytes.removeSubrange(count..<bytes.count)
        return bytes
    }

    private func closeFolders() {
        for folder in folders { _ = Darwin.close(folder.descriptor) }
        folders = []
    }

    private func openParent(of path: String) throws -> (Int32, String) {
        try validateSourcePath(path)
        guard path != "/" else { throw ImportSourceError.notRegularFile }
        let url = URL(fileURLWithPath: path)
        // Canonicalize only ancestors of the selection, including macOS /var.
        guard let resolved = Darwin.realpath(url.deletingLastPathComponent().path, nil) else {
            throw errno == ENOENT ? ImportSourceError.notFound : ImportSourceError.ioFailure
        }
        defer { free(resolved) }
        let parts = String(cString: resolved).split(separator: "/").map(String.init)
        let root = Darwin.open("/", O_EVTONLY | Self.directoryFlags)
        guard root >= 0 else { throw ImportSourceError.ioFailure }
        defer { _ = Darwin.close(root) }
        return (try walk(parts[...], from: root), url.lastPathComponent)
    }

    private func validateSourcePath(_ path: String) throws {
        guard path.utf8.first == UInt8(ascii: "/") else { throw ImportSourceError.invalidPath }
        if path == "/" { return }
        // Absolute sources have no whole-library-path cap. Reuse the public
        // lexical validator on individual components, without normalizing them.
        for component in path.utf8.dropFirst().split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false) {
            do { try FileStorePath.validate(String(decoding: component, as: UTF8.self)) }
            catch { throw ImportSourceError.invalidPath }
        }
    }

    private func walk(_ parts: ArraySlice<String>, from root: Int32) throws -> Int32 {
        var descriptor = Darwin.fcntl(root, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw ImportSourceError.ioFailure }
        do {
            for part in parts {
                let child = try openDirectory(part, relativeTo: descriptor, access: O_EVTONLY)
                _ = Darwin.close(descriptor)
                descriptor = child
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func openDirectory(_ name: String, relativeTo parent: Int32, access: Int32) throws -> Int32 {
        let descriptor = Darwin.openat(parent, name, access | Self.directoryFlags)
        guard descriptor >= 0 else { throw failure(name, relativeTo: parent, code: errno) }
        return descriptor
    }

    private func failure(_ name: String, relativeTo parent: Int32, code: Int32) -> ImportSourceError {
        var info = Darwin.stat()
        if Darwin.fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) { return .symbolicLink }
            let kind = info.st_mode & mode_t(S_IFMT)
            if kind != mode_t(S_IFREG), kind != mode_t(S_IFDIR) { return .notRegularFile }
        }
        switch code {
        case ENOENT: return .notFound
        case ELOOP: return .symbolicLink
        case ENOTDIR: return .notRegularFile
        default: return .ioFailure
        }
    }

    private func collect(in root: Int32, into entries: inout [ImportSourceEntry]) throws {
        var pendingFolders = [""]
        var remainingPathBytes = Limits.importFileCapBytes
        // Queue paths, not descriptors or recursive calls. Reopen each folder
        // from the pinned root without following links in any component.
        while let folderPath = pendingFolders.popLast() {
            let descriptor: Int32
            if folderPath.isEmpty {
                descriptor = Darwin.fcntl(root, F_DUPFD_CLOEXEC, 0)
                guard descriptor >= 0 else { throw ImportSourceError.ioFailure }
            } else {
                let parts = folderPath.split(separator: "/").map(String.init)
                guard let name = parts.last else { throw ImportSourceError.invalidPath }
                let parent: Int32
                do { parent = try walk(parts.dropLast(), from: root) }
                catch {
                    guard let source = error as? ImportSourceError,
                          [ImportSourceError.notFound, .symbolicLink, .notRegularFile].contains(source) else { throw error }
                    entries.append(ImportSourceEntry(relativePath: folderPath,
                        kind: source == .symbolicLink ? .symbolicLink : .other))
                    continue
                }
                defer { _ = Darwin.close(parent) }
                descriptor = Darwin.openat(parent, name, O_RDONLY | Self.directoryFlags)
                if descriptor < 0 {
                    let code = errno
                    guard [ENOENT, EACCES, EPERM, ELOOP, ENOTDIR].contains(code) else {
                        throw ImportSourceError.ioFailure
                    }
                    let kind: ImportSourceKind = failure(name, relativeTo: parent, code: code) == .symbolicLink
                        ? .symbolicLink : .other
                    entries.append(ImportSourceEntry(relativePath: folderPath, kind: kind))
                    continue
                }
            }
            defer { _ = Darwin.close(descriptor) }
            let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw ImportSourceError.ioFailure }
            guard let stream = Darwin.fdopendir(duplicate) else {
                _ = Darwin.close(duplicate)
                throw ImportSourceError.ioFailure
            }
            defer { _ = Darwin.closedir(stream) }
            let prefix = folderPath.isEmpty ? "" : folderPath + "/"
            while true {
                errno = 0
                guard let entry = Darwin.readdir(stream) else {
                    guard errno == 0 else { throw ImportSourceError.ioFailure }
                    break
                }
                let length = Int(entry.pointee.d_namlen) + 1
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: length) { String(validatingUTF8: $0) }
                }
                guard let name else { throw ImportSourceError.invalidPath }
                if name == "." || name == ".." { continue }
                let path = prefix + name
                // Count directories too, so empty trees cannot bypass the budget.
                guard path.utf8.count <= Limits.maxPathBytes else { throw ImportSourceError.invalidPath }
                let pathBytes = path.utf8.count + 1
                guard pathBytes <= remainingPathBytes else { throw ImportSourceError.ioFailure }
                remainingPathBytes -= pathBytes
                willInspectEntry(path)
                var info = Darwin.stat()
                guard Darwin.fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    guard errno == ENOENT else { throw ImportSourceError.ioFailure }
                    // Keep the candidate so Core reports a typed source skip on read.
                    entries.append(ImportSourceEntry(relativePath: path))
                    continue
                }
                switch info.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFDIR): pendingFolders.append(path)
                case mode_t(S_IFREG): entries.append(ImportSourceEntry(relativePath: path))
                case mode_t(S_IFLNK): entries.append(ImportSourceEntry(relativePath: path, kind: .symbolicLink))
                default: entries.append(ImportSourceEntry(relativePath: path, kind: .other))
                }
            }
        }
    }
}
