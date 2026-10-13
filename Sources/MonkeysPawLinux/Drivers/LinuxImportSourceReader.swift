#if os(Linux)
import Foundation
import Glibc
import MonkeysPawCore

/// Confined to the graph's serial BackgroundWork. Keep the enumerated root
/// open so replacing a parent with a link cannot redirect a later read.
final class LinuxImportSourceReader: ImportSourceReading {
    private var folder: (path: String, descriptor: Int32)?
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private let inspectEntry: (String) -> Void

    // The seam reproduces vanished entries without permission tricks under root.
    init(inspectEntry: @escaping (String) -> Void = { _ in }) { self.inspectEntry = inspectEntry }

    deinit { closeFolder() }

    func requests(for urls: [URL]) -> [ImportRequest] {
        closeFolder()
        var files: [String] = []
        var requests: [ImportRequest] = []
        for url in urls where url.isFileURL {
            guard url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { continue }
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                requests.append(.folder(url.path))
            } else { files.append(url.path) }
        }
        if !files.isEmpty { requests.insert(.files(files), at: 0) }
        return requests
    }

    func listFiles(in folderPath: String) throws -> [ImportSourceEntry] {
        try validateSourcePath(folderPath)
        closeFolder()
        let descriptor: Int32
        if folderPath == "/" {
            descriptor = Glibc.open("/", Self.directoryFlags)
            guard descriptor >= 0 else { throw ImportSourceError.ioFailure }
        } else {
            let (parent, name) = try openParent(of: folderPath)
            defer { _ = Glibc.close(parent) }
            descriptor = try openDirectory(name, relativeTo: parent)
        }
        defer { _ = Glibc.close(descriptor) }
        var entries: [ImportSourceEntry] = []
        var pathBytes = 0
        try collect(in: descriptor, prefix: "", pathBytes: &pathBytes, into: &entries)
        let retained = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard retained >= 0 else { throw ImportSourceError.ioFailure }
        folder = (folderPath, retained)
        return entries
    }

    func readFile(at path: String, maximumBytes: Int) throws -> Data {
        try validateSourcePath(path)
        guard path != "/" else { throw ImportSourceError.notRegularFile }
        guard maximumBytes >= 0 else { throw ImportSourceError.invalidPath }
        let cap = min(maximumBytes, Limits.importFileCapBytes)
        let parent: Int32
        let name: String
        if let folder, path.utf8.starts(with: (folder.path == "/" ? "/" : folder.path + "/").utf8) {
            let prefixCount = folder.path.utf8.count + (folder.path == "/" ? 0 : 1)
            let relative = String(decoding: path.utf8.dropFirst(prefixCount), as: UTF8.self)
            let parts = components(relative)
            parent = try walk(parts.dropLast(), from: folder.descriptor)
            name = parts.last!
        } else { (parent, name) = try openParent(of: path) }
        defer { _ = Glibc.close(parent) }

        // O_NONBLOCK prevents a raced FIFO from hanging before fstat rejects it.
        let descriptor = Glibc.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(name, relativeTo: parent, code: errno) }
        defer { _ = Glibc.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ImportSourceError.ioFailure }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ImportSourceError.notRegularFile }
        guard info.st_size <= cap else { throw ImportSourceError.fileTooLarge }

        // The extra byte also detects growth after stat, without unbounded I/O.
        var bytes = Data(count: cap + 1)
        var count = 0
        try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            while count < buffer.count {
                let read = Glibc.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if read < 0 {
                    if errno == EINTR { continue }
                    throw ImportSourceError.ioFailure
                }
                if read == 0 { break }
                count += read
            }
        }
        guard count <= cap else { throw ImportSourceError.fileTooLarge }
        bytes.removeSubrange(count..<bytes.count)
        return bytes
    }

    private func closeFolder() {
        if let folder { _ = Glibc.close(folder.descriptor) }
        folder = nil
    }

    private func validateSourcePath(_ path: String) throws {
        guard path.utf8.first == UInt8(ascii: "/") else { throw ImportSourceError.invalidPath }
        if path == "/" { return }
        for component in path.utf8.dropFirst().split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false) {
            do { try FileStorePath.validate(String(decoding: component, as: UTF8.self)) }
            catch { throw ImportSourceError.invalidPath }
        }
    }

    private func openParent(of path: String) throws -> (Int32, String) {
        let parts = components(path)
        guard let name = parts.last else { throw ImportSourceError.notRegularFile }
        let parentPath = "/" + parts.dropLast().joined(separator: "/")
        // Only selection ancestors may be aliases. Walk the canonical result
        // with no-follow flags, including the selected leaf itself.
        guard let resolved = realpath(parentPath, nil) else {
            throw errno == ENOENT ? ImportSourceError.notFound : ImportSourceError.ioFailure
        }
        defer { free(resolved) }
        let canonical = components(String(cString: resolved))
        let root = Glibc.open("/", Self.directoryFlags)
        guard root >= 0 else { throw ImportSourceError.ioFailure }
        defer { _ = Glibc.close(root) }
        return (try walk(canonical[...], from: root), name)
    }

    private func components(_ path: String) -> [String] {
        // POSIX separates slash bytes even when a following combining mark
        // joins that slash's Swift Character. Each openat sees one component.
        path.utf8.split(separator: UInt8(ascii: "/")).map { String(decoding: $0, as: UTF8.self) }
    }

    private func walk(_ parts: ArraySlice<String>, from root: Int32) throws -> Int32 {
        var descriptor = fcntl(root, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw ImportSourceError.ioFailure }
        do {
            for part in parts {
                let child = try openDirectory(part, relativeTo: descriptor)
                _ = Glibc.close(descriptor)
                descriptor = child
            }
            return descriptor
        } catch {
            _ = Glibc.close(descriptor)
            throw error
        }
    }

    private func openDirectory(_ name: String, relativeTo parent: Int32) throws -> Int32 {
        let descriptor = Glibc.openat(parent, name, Self.directoryFlags)
        guard descriptor >= 0 else { throw failure(name, relativeTo: parent, code: errno) }
        return descriptor
    }

    private func failure(_ name: String, relativeTo parent: Int32, code: Int32) -> ImportSourceError {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            let kind = info.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK) { return .symbolicLink }
            if kind != mode_t(S_IFREG), kind != mode_t(S_IFDIR) { return .notRegularFile }
        }
        switch code {
        case ENOENT: return .notFound
        case ELOOP: return .symbolicLink
        case ENOTDIR: return .notRegularFile
        default: return .ioFailure
        }
    }

    private func collect(in descriptor: Int32, prefix: String, pathBytes: inout Int,
                         into entries: inout [ImportSourceEntry]) throws {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw ImportSourceError.ioFailure }
        guard let stream = fdopendir(duplicate) else {
            _ = Glibc.close(duplicate)
            throw ImportSourceError.ioFailure
        }
        defer { _ = closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ImportSourceError.ioFailure }
                return
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw ImportSourceError.invalidPath }
            if name == "." || name == ".." { continue }
            let path = prefix + name
            // The relative-path cap bounds recursion; the source-byte cap also
            // budgets all enumerated names, including empty directories.
            pathBytes += path.utf8.count
            guard pathBytes <= Limits.importFileCapBytes else { throw ImportSourceError.fileTooLarge }
            guard path.utf8.count <= Limits.maxPathBytes else {
                // Descendants cannot fit either. Keep a candidate for Core's
                // invalidPath skip, without discarding valid sibling sources.
                entries.append(ImportSourceEntry(relativePath: path))
                continue
            }
            inspectEntry(path)
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                // Let Core read and report a vanished leaf as a typed skip.
                guard errno == ENOENT else { throw ImportSourceError.ioFailure }
                entries.append(ImportSourceEntry(relativePath: path))
                continue
            }
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                let child: Int32
                do { child = try openDirectory(name, relativeTo: descriptor) }
                catch ImportSourceError.notFound {
                    entries.append(ImportSourceEntry(relativePath: path))
                    continue
                } catch ImportSourceError.symbolicLink {
                    entries.append(ImportSourceEntry(relativePath: path, kind: .symbolicLink))
                    continue
                }
                defer { _ = Glibc.close(child) }
                try collect(in: child, prefix: path + "/", pathBytes: &pathBytes, into: &entries)
            case mode_t(S_IFREG): entries.append(ImportSourceEntry(relativePath: path))
            case mode_t(S_IFLNK): entries.append(ImportSourceEntry(relativePath: path, kind: .symbolicLink))
            default: entries.append(ImportSourceEntry(relativePath: path, kind: .other))
            }
        }
    }
}
#endif
