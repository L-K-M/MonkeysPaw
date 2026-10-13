import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Never unlink this file: locks must continue to refer to the same inode.
final class DatabaseFileLock: @unchecked Sendable {
    enum Mode { case shared, exclusive }
    private let mutex = NSLock()
    private var descriptor: Int32

    init(directory: URL, mode: Mode) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(".monkeyspaw.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw BackupRestoreError.failed }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(fd)
            throw BackupRestoreError.failed
        }
        guard flock(fd, (mode == .shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            close(fd)
            throw busy ? BackupRestoreError.databaseInUse : .failed
        }
        descriptor = fd
    }

    func release() {
        mutex.withLock {
            guard descriptor >= 0 else { return }
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }
}
