#if os(Linux)
import CGtk
import Foundation
import Glibc
import MonkeysPawCore

/// Only explicit Setup writes this choice. Shortcut values remain in KDE's
/// daemon/portal settings; this file contains one validated mechanism enum.
enum KDEHotkeyChoice: String, Codable { case native, portal }

struct KDEHotkeyChoiceStore {
    enum LoadResult: Equatable {
        case absent
        case loaded(KDEHotkeyChoice)
        case corrupt
        case unreadable
    }

    enum WriteError: Error { case ioFailure }

    private struct Record: Codable { let mechanism: KDEHotkeyChoice }
    private let file: URL

    init(paths: LinuxPaths) {
        file = paths.dataDirectory.appendingPathComponent("shortcut-mechanism.json")
    }

    func load() -> LoadResult {
        // O_NONBLOCK also prevents a replaced file from turning into a FIFO wait.
        let descriptor = Glibc.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return .absent }
            return errno == ELOOP ? .corrupt : .unreadable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .unreadable }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_size <= Limits.shortcutChoiceFileMaxBytes else { return .corrupt }

        do {
            let data = try handle.read(upToCount: Limits.shortcutChoiceFileMaxBytes + 1) ?? Data()
            guard data.count <= Limits.shortcutChoiceFileMaxBytes,
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { return .corrupt }
            return .loaded(record.mechanism)
        } catch {
            return .unreadable
        }
    }

    func save(_ choice: KDEHotkeyChoice) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Record(mechanism: choice))

            // mkstemp creates a new owner-private inode before any record is
            // written. rename replaces even a corrupt previous record atomically.
            var template = Array(file.deletingLastPathComponent()
                .appendingPathComponent(".shortcut-choice-XXXXXX").path.utf8CString)
            let descriptor = g_mkstemp_full(&template, O_RDWR | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw WriteError.ioFailure }
            let temporary = String(cString: template)
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer {
                try? handle.close()
                _ = Glibc.unlink(temporary)
            }

            guard fchmod(descriptor, 0o600) == 0 else { throw WriteError.ioFailure }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard Glibc.rename(temporary, file.path) == 0 else { throw WriteError.ioFailure }
        } catch {
            // Filesystem and decoding errors may carry record data or paths.
            throw WriteError.ioFailure
        }
    }
}
#endif
