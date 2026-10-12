import Foundation
import MonkeysPawCore
import Security

/// One login-keychain item shares an ACL across provider keys and device tokens.
/// Calls can prompt or block; services must invoke them from background work.
final class KeychainSecretStore: SecretStore {
    private struct Payload: Codable {
        static let currentVersion = 1
        let version: Int
        let entries: [String: String]
    }

    // The item is shared across instances, so its read/modify/write lock is too.
    private static let lock = NSLock()
    private static let itemAccount = "secret-map"
    private let keychain: KeychainAccess
    private let service: String

    init(keychain: KeychainAccess = SystemKeychainAccess(), service: String = "ch.lkmc.monkeyspaw") {
        self.keychain = keychain
        self.service = service
    }

    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // macOS has no environment tier; both sources read the persisted item.
        guard let value = try readEntries()?[account.rawValue] else { return nil }
        return StoredSecret(value: SecretValue(value), tier: .keychain)
    }

    @discardableResult
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let existing = try readEntries()
        var entries = existing ?? [:]
        entries[account.rawValue] = value.withValue { $0 }

        if existing != nil {
            try update(entries, failure: .writeFailed)
            return .keychain
        }

        do {
            try keychain.add(try encode(entries), service: service, account: Self.itemAccount)
        } catch KeychainAccessError.duplicateItem {
            // Another writer may have created the item. Revalidate and merge;
            // never overwrite its other accounts or an unreadable payload.
            guard var latest = try readEntries() else { throw SecretStoreError.writeFailed }
            latest[account.rawValue] = value.withValue { $0 }
            try update(latest, failure: .writeFailed)
        } catch {
            throw sanitized(error, fallback: .writeFailed)
        }
        return .keychain
    }

    func delete(account: SecretAccount) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard var entries = try readEntries() else { return }
        let removed = entries.removeValue(forKey: account.rawValue)
        if entries.isEmpty {
            do { try keychain.delete(service: service, account: Self.itemAccount) }
            catch KeychainAccessError.notFound { return }
            catch { throw sanitized(error, fallback: .deleteFailed) }
            return
        }
        guard removed != nil else { return }
        try update(entries, failure: .deleteFailed)
    }

    private func readEntries() throws -> [String: String]? {
        let data: Data
        do { data = try keychain.copyMatching(service: service, account: Self.itemAccount) }
        catch KeychainAccessError.notFound { return nil }
        catch { throw sanitized(error, fallback: .readFailed) }

        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == Payload.currentVersion else { throw SecretStoreError.readFailed }
            for rawAccount in payload.entries.keys {
                let parts = rawAccount.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw SecretStoreError.readFailed }
                _ = try SecretAccount(namespace: String(parts[0]), name: String(parts[1]))
            }
            return payload.entries
        } catch { throw SecretStoreError.readFailed }
    }

    private func encode(_ entries: [String: String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Payload(version: Payload.currentVersion, entries: entries))
    }

    private func update(_ entries: [String: String], failure: SecretStoreError) throws {
        do {
            try keychain.update(try encode(entries), service: service, account: Self.itemAccount)
        } catch { throw sanitized(error, fallback: failure) }
    }

    private func sanitized(_ error: Error, fallback: SecretStoreError) -> SecretStoreError {
        switch error {
        case KeychainAccessError.locked: return .locked
        case KeychainAccessError.unavailable: return .unavailable
        default: return fallback
        }
    }
}

/// Small internal boundary keeps Security status codes and error text out of Core.
protocol KeychainAccess {
    func copyMatching(service: String, account: String) throws -> Data
    func add(_ data: Data, service: String, account: String) throws
    func update(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

enum KeychainAccessError: Error {
    case notFound
    case duplicateItem
    case locked
    case unavailable
    case failure
}

struct SystemKeychainAccess: KeychainAccess {
    private static let interactionLock = NSLock()

    func copyMatching(service: String, account: String) throws -> Data {
        var query = item(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try Self.check(SecItemCopyMatching(query as CFDictionary, &result))
        guard let data = result as? Data else { throw KeychainAccessError.failure }
        return data
    }

    func add(_ data: Data, service: String, account: String) throws {
        var attributes = item(service: service, account: account)
        attributes[kSecValueData as String] = data
        try Self.check(SecItemAdd(attributes as CFDictionary, nil))
    }

    func update(_ data: Data, service: String, account: String) throws {
        let attributes = [kSecValueData as String: data]
        try Self.check(SecItemUpdate(item(service: service, account: account) as CFDictionary,
                                    attributes as CFDictionary))
    }

    func delete(service: String, account: String) throws {
        try Self.check(SecItemDelete(item(service: service, account: account) as CFDictionary))
    }

    private func item(service: String, account: String) -> [String: Any] {
        // Use the login keychain's default ACL, without sync or access groups
        // that require signing entitlements on unsigned/ad-hoc desktop builds.
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw KeychainAccessError.notFound
        case errSecDuplicateItem: throw KeychainAccessError.duplicateItem
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw KeychainAccessError.locked
        case errSecNotAvailable, errSecNoDefaultKeychain, errSecNoSuchKeychain,
             errSecInvalidKeychain, errSecMissingEntitlement:
            throw KeychainAccessError.unavailable
        default: throw KeychainAccessError.failure
        }
    }

    /// Hosted tests must also suppress legacy login-keychain ACL/unlock dialogs;
    /// per-query authentication-UI flags only cover the Data Protection keychain.
    static func withoutUserInteraction<T>(_ work: () throws -> T) throws -> T {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        var allowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw KeychainAccessError.unavailable
        }
        defer { _ = SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return try work()
    }
}
