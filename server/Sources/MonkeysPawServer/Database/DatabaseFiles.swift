import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc

// glibc exposes this syscall wrapper on our supported Ubuntu releases.
@_silgen_name("renameat2")
private func renameNoReplace(_ oldDirectory: Int32, _ old: UnsafePointer<CChar>,
                             _ newDirectory: Int32, _ new: UnsafePointer<CChar>, _ flags: UInt32) -> Int32
#endif

enum DatabaseFiles {
    static func url(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.contains("\0") else { throw BackupRestoreError.invalidBackup }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        return file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent)
    }

    static func occupied(_ file: URL) throws -> Bool {
        var info = stat()
        if lstat(file.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw BackupRestoreError.failed }
        return false
    }

    static func checkHeader(_ file: URL) throws {
        let fd = try openRegular(file)
        defer { close(fd) }
        var header = [UInt8](repeating: 0, count: 16)
        guard read(fd, &header, header.count) == header.count, header == Array("SQLite format 3\0".utf8) else {
            throw BackupRestoreError.invalidBackup
        }
    }

    static func checkRegular(_ file: URL) throws {
        close(try openRegular(file))
    }

    private static func openRegular(_ file: URL) throws -> Int32 {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw BackupRestoreError.invalidBackup }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(fd)
            throw BackupRestoreError.invalidBackup
        }
        return fd
    }

    static func createEmpty(_ file: URL) throws {
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw BackupRestoreError.failed }
        close(fd)
    }

    static func sync(_ file: URL) throws {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw BackupRestoreError.failed }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw BackupRestoreError.failed }
    }

    static func publish(_ temporary: URL, to destination: URL) throws {
        let result: Int32
        #if canImport(Darwin)
        result = renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL))
        #else
        result = temporary.path.withCString { old in
            destination.path.withCString { new in
                renameNoReplace(AT_FDCWD, old, AT_FDCWD, new, 1) // RENAME_NOREPLACE
            }
        }
        #endif
        guard result == 0 else {
            throw errno == EEXIST ? BackupRestoreError.destinationOccupied : .failed
        }
        try sync(destination.deletingLastPathComponent())
    }

    static func preserve(_ file: URL, at recovery: URL) throws {
        guard link(file.path, recovery.path) == 0 else { throw BackupRestoreError.failed }
        try sync(recovery.deletingLastPathComponent())
    }

    static func replace(_ file: URL, with staged: URL) throws {
        guard rename(staged.path, file.path) == 0 else { throw BackupRestoreError.failed }
        try sync(file.deletingLastPathComponent())
    }
}
