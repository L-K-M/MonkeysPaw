import Foundation
import Darwin
import MonkeysPawCore

/// Foundation owns file bytes/replacement; POSIX metadata supplies nanosecond
/// change time and inode identity for stamps. No filesystem error text escapes.
final class RootedFileStore: FileStore {
    private enum Parents { case existing, create }

    private let root: URL
    private let manager = FileManager.default

    init(root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw FileStoreError.invalidRoot }
        // Resolve only the existing ancestor: a missing tail prevents Foundation
        // from fully resolving /var -> /private/var or a symlinked $HOME.
        // Append missing components literally; later operations reject symlinks.
        var ancestor = root.standardizedFileURL
        var missingComponents = [String]()
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            missingComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var canonicalRoot = ancestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            canonicalRoot.appendPathComponent(component, isDirectory: true)
        }
        self.root = canonicalRoot
        _ = try sanitized { try rootExists(parents: .existing) }
    }

    func listFiles() throws -> [StoredFile] {
        try sanitized {
            guard try rootExists(parents: .existing) else { return [] }
            var result = [StoredFile]()
            try collect(in: root, prefix: "", into: &result)
            return result.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
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

    func delete(at path: String) throws {
        try sanitized {
            guard let url = try locate(path, parents: .existing), let attributes = try attributes(at: url) else {
                throw FileStoreError.notFound
            }
            try requireRegular(attributes)
            try manager.removeItem(at: url)
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
            guard let destinationURL = try locate(destination, parents: .create) else {
                throw FileStoreError.invalidRoot
            }
            if let existing = try attributes(at: destinationURL) {
                if existing[.type] as? FileAttributeType == .typeSymbolicLink { throw FileStoreError.outsideRoot }
                throw FileStoreError.alreadyExists
            }
            try manager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private func locate(_ path: String, parents: Parents) throws -> URL? {
        try FileStorePath.validate(path)
        guard try rootExists(parents: parents) else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        var directory = root
        for part in parts.dropLast() {
            directory.appendPathComponent(part, isDirectory: true)
            guard try ensureDirectory(directory, parents: parents) else { return nil }
        }
        return directory.appendingPathComponent(parts.last!)
    }

    private func rootExists(parents: Parents) throws -> Bool {
        // Recheck the canonical root's ancestors too: a replaced root/ancestor
        // must not redirect subsequent operations outside the chosen tree.
        var directory = URL(fileURLWithPath: "/", isDirectory: true)
        for part in root.pathComponents.dropFirst() {
            directory.appendPathComponent(part, isDirectory: true)
            guard try ensureDirectory(directory, parents: parents) else { return false }
        }
        return true
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
            guard let attributes = try attributes(at: url) else { throw FileStoreError.ioFailure }
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
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw FileStoreError.ioFailure }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw FileStoreError.notRegularFile }
        return FileStamp("\(info.st_dev):\(info.st_ino):\(info.st_size):"
            + "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):"
            + "\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)")
    }

    private func sanitized<T>(_ work: () throws -> T) throws -> T {
        do { return try work() }
        catch let error as FileStoreError { throw error }
        catch { throw FileStoreError.ioFailure }
    }
}
