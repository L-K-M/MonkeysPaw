#if os(Linux)
import CGtk
import Foundation
import Glibc
import MonkeysPawCore

/// Portal tokens are opaque strings, not UUIDs. Keep their representation
/// bounded and their diagnostic description redacted (§12).
struct PortalRestoreToken: Equatable, CustomStringConvertible {
    let value: String

    init?(_ value: String) {
        guard !value.isEmpty, value.utf8.count <= Limits.portalTokenMaxBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        self.value = value
    }

    var description: String { "<portal restore token>" }
}

/// Only the session driver decides when a Start result replaces this token.
struct PortalTokenStore {
    enum LoadResult: Equatable {
        case absent
        case loaded(PortalRestoreToken)
        case corrupt
        case unreadable
    }

    enum WriteError: Error { case ioFailure }

    private struct Record: Codable { let restoreToken: String }
    private let file: URL

    init(paths: LinuxPaths) {
        file = paths.dataDirectory.appendingPathComponent("portal.json")
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
              info.st_size <= Limits.portalTokenFileMaxBytes else { return .corrupt }

        do {
            let data = try handle.read(upToCount: Limits.portalTokenFileMaxBytes + 1) ?? Data()
            guard data.count <= Limits.portalTokenFileMaxBytes,
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  let token = PortalRestoreToken(record.restoreToken) else { return .corrupt }
            return .loaded(token)
        } catch {
            return .unreadable
        }
    }

    func save(_ token: PortalRestoreToken) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Record(restoreToken: token.value))

            // mkstemp creates a new owner-private inode before any token is
            // written. rename replaces even a corrupt previous record atomically.
            var template = Array(file.deletingLastPathComponent()
                .appendingPathComponent(".portal-XXXXXX").path.utf8CString)
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
            // Filesystem and decoding errors may carry token data or paths.
            throw WriteError.ioFailure
        }
    }
}
#endif
