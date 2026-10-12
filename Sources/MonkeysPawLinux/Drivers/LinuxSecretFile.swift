#if os(Linux)
import Foundation
import Glibc
import MonkeysPawCore

/// Plaintext, deliberately labelled, and separate from provider settings.
/// The owning SecretStore serializes every read/modify/replace operation.
struct LinuxSecretFile {
    private enum DirectoryAccess { case existing, create }
    private struct Record: Codable {
        var version = 1
        var storage = "unencrypted"
        var secrets: [String: String] = [:]
    }

    private let directory: URL
    private let name = "secrets-unencrypted.json"

    init(paths: LinuxPaths) { directory = paths.configDirectory }

    func read(account: SecretAccount) throws -> SecretValue? {
        try load().secrets[account.rawValue].map(SecretValue.init)
    }

    func write(_ value: SecretValue?, account: SecretAccount) throws {
        var record = try load()
        if value == nil, record.secrets[account.rawValue] == nil { return }
        record.secrets[account.rawValue] = value?.withValue { $0 }
        let data = try JSONEncoder().encode(record)
        // Reuse the existing private JSON-state cap; never truncate a map.
        guard data.count <= Limits.valuesFileCapBytes,
              let parent = try openDirectory(.create) else { throw SecretStoreError.writeFailed }
        defer { _ = Glibc.close(parent) }
        try checkLeaf(parent: parent)

        let temporary = ".secrets-\(UUID().uuidString)"
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(Limits.privateFileMode))
        guard descriptor >= 0 else { throw SecretStoreError.writeFailed }
        defer {
            _ = Glibc.close(descriptor)
            _ = unlinkat(parent, temporary, 0)
        }
        guard fchmod(descriptor, mode_t(Limits.privateFileMode)) == 0 else { throw SecretStoreError.writeFailed }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Glibc.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                throw SecretStoreError.writeFailed
            }
        }
        guard fsync(descriptor) == 0 else { throw SecretStoreError.writeFailed }
        try checkLeaf(parent: parent)
        guard renameat(parent, temporary, parent, name) == 0 else { throw SecretStoreError.writeFailed }
        // Some filesystems cannot sync directories. Publication has succeeded.
        _ = fsync(parent)
    }

    private func load() throws -> Record {
        guard let parent = try openDirectory(.existing) else { return Record() }
        defer { _ = Glibc.close(parent) }
        let descriptor = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return Record() }
            throw SecretStoreError.readFailed
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Self.isPrivateRegularFile(info),
              info.st_size <= Limits.valuesFileCapBytes else { throw SecretStoreError.readFailed }
        let data = try handle.read(upToCount: Limits.valuesFileCapBytes + 1) ?? Data()
        guard data.count <= Limits.valuesFileCapBytes,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, record.storage == "unencrypted" else { throw SecretStoreError.readFailed }
        for account in record.secrets.keys {
            let parts = account.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  (try? SecretAccount(namespace: String(parts[0]), name: String(parts[1]))) != nil else {
                throw SecretStoreError.readFailed
            }
        }
        return record
    }

    private func checkLeaf(parent: Int32) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw SecretStoreError.writeFailed
        }
        guard Self.isPrivateRegularFile(info) else { throw SecretStoreError.writeFailed }
    }

    private static func isPrivateRegularFile(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_uid == geteuid()
            && info.st_mode & 0o777 == mode_t(Limits.privateFileMode) && info.st_nlink == 1
    }

    private func openDirectory(_ access: DirectoryAccess) throws -> Int32? {
        // Walk from / using directory descriptors: no symlinked config root or
        // ancestor can redirect secrets, including during replacement.
        var descriptor = Glibc.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SecretStoreError.readFailed }
        do {
            for component in directory.standardizedFileURL.pathComponents.dropFirst() {
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                if next < 0, errno == ENOENT, access == .create {
                    guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                        throw SecretStoreError.writeFailed
                    }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard next >= 0 else {
                    if errno == ENOENT, access == .existing { _ = Glibc.close(descriptor); return nil }
                    throw SecretStoreError.readFailed
                }
                _ = Glibc.close(descriptor)
                descriptor = next
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
                throw SecretStoreError.readFailed
            }
            return descriptor
        } catch {
            _ = Glibc.close(descriptor)
            throw error
        }
    }
}
#endif
