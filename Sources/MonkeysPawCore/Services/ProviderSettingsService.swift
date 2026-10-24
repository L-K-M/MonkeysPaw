import Foundation

/// Owns B23 key rules. Call from serial background work when a native secret
/// store can prompt or block. The shared store serializes every compound edit.
/// Cancelled secret reads report `.secret(.readFailed)` without starting recovery.
public final class ProviderSettingsService {
    private struct Credential: Codable {
        static let currentVersion = 1
        let version: Int
        let origin: String
        let kind: ProviderKind
        let key: String
    }

    private let store: ProviderSettingsStore
    private let secrets: SecretStore
    private let log: LogSink?

    public init(store: ProviderSettingsStore, secrets: SecretStore, log: LogSink? = nil) {
        self.store = store
        self.secrets = secrets
        self.log = log
    }

    public var snapshot: ProviderSettingsSnapshot { store.snapshot }

    /// §26 S10: remote applies and committed edits notify on the UI-agnostic
    /// observer path. Call from composition; the token removes the observer.
    @discardableResult public func observe(_ observer: @escaping @Sendable () -> Void) -> UUID {
        store.observe(observer)
    }

    public func removeObserver(_ id: UUID) { store.removeObserver(id) }

    public func save(_ draft: ProviderDraft) throws {
        var undo: (() throws -> Void)?
        try store.update({ settings in
            let previous = settings.profiles.first { $0.id == draft.id }
            let candidate = try ProviderProfile(id: draft.id, displayName: draft.displayName, kind: draft.kind,
                baseURL: draft.baseURL, modelID: draft.modelID)
            try checkDestination(draft, baseURL: candidate.baseURL, previous: previous)
            try validateKey(draft.key)

            let reference: SecretAccount?
            switch draft.key {
            case .keep:
                reference = try keptReference(for: draft.id, previous: previous)
            case .replace(let value):
                reference = .provider(draft.id)
                let bound = try bindSecret(value, kind: candidate.kind, baseURL: candidate.baseURL)
                undo = try editSecret(account: .provider(draft.id), value: bound)
            case .clear:
                reference = nil
                undo = try editSecret(account: .provider(draft.id), value: nil)
            }
            let profile = try ProviderProfile(id: candidate.id, displayName: candidate.displayName,
                kind: candidate.kind, baseURL: candidate.baseURL.absoluteString, modelID: candidate.modelID,
                secretReference: reference)
            var profiles = settings.profiles
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
            else { profiles.append(profile) }
            return try ProviderSettings(profiles: profiles, selectedProfileID: settings.selectedProfileID ?? profile.id)
        }, rollback: { try undo?() })
    }

    public func selectProfile(_ id: ProviderProfileID?) throws {
        try store.update { try ProviderSettings(profiles: $0.profiles, selectedProfileID: id) }
    }

    public func deleteProfile(_ id: ProviderProfileID) throws {
        var undo: (() throws -> Void)?
        try store.update({ settings in
            guard settings.profiles.contains(where: { $0.id == id }) else { throw ProviderSettingsError.profileNotFound }
            undo = try editSecret(account: .provider(id), value: nil)
            return try ProviderSettings(profiles: settings.profiles.filter { $0.id != id },
                selectedProfileID: settings.selectedProfileID == id ? nil : settings.selectedProfileID)
        }, rollback: { try undo?() })
    }

    /// Only the selected draft's ID is consulted. Replace/Clear apply in memory;
    /// Keep cannot borrow a saved key after a kind/origin change. No files or
    /// secrets are written, even when a Test uses an unsaved profile or model.
    public func resolveForTesting(_ draft: ProviderDraft) throws -> ProviderConnection {
        try store.withSettings { settings in
            let previous = settings.profiles.first { $0.id == draft.id }
            let baseURL = try ProviderSettings.normalizeBaseURL(draft.baseURL, kind: draft.kind)
            try checkDestination(draft, baseURL: baseURL, previous: previous)
            try validateKey(draft.key)
            let key: SecretValue?
            switch draft.key {
            case .replace(let value): key = value
            case .clear: key = nil
            case .keep:
                let reference = try keptReference(for: draft.id, previous: previous)
                key = try reference.flatMap { try resolveSecret($0, kind: draft.kind, baseURL: baseURL) }
            }
            return ProviderConnection(profileID: draft.id, kind: draft.kind, baseURL: baseURL,
                                      modelID: draft.modelID, key: key)
        }
    }

    public func connection(for id: ProviderProfileID) throws -> ProviderConnection {
        try store.withSettings { settings in
            guard let profile = settings.profiles.first(where: { $0.id == id }) else {
                throw ProviderSettingsError.profileNotFound
            }
            let key = try profile.secretReference.flatMap {
                try resolveSecret($0, kind: profile.kind, baseURL: profile.baseURL)
            }
            return ProviderConnection(profileID: id, kind: profile.kind, baseURL: profile.baseURL,
                                      modelID: profile.modelID, key: key)
        }
    }

    /// §26 S4/S6: the stored object verbatim, plus the persisted bound envelope
    /// for each referenced account. A missing persisted value falls back to the
    /// last decrypted remote document; environment overrides never upload.
    func exportSyncPayload(remoteSecrets: [String: String]) throws -> ProviderSyncPayload {
        try store.withDocument { object, settings in
            let stored = object.isEmpty ? ProviderSettingsService.defaultObject : object
            var secrets: [String: String] = [:]
            for profile in settings.profiles {
                guard let account = profile.secretReference, account.namespace == "provider" else { continue }
                if let persisted = try readSecret(account, source: .persisted) {
                    persisted.value.withValue { secrets[account.rawValue] = $0 }
                } else if let carried = remoteSecrets[account.rawValue] {
                    secrets[account.rawValue] = carried
                }
            }
            return ProviderSyncPayload(settings: stored, secrets: secrets)
        }
    }

    /// §26 S7: write the payload's secrets for referenced provider accounts and
    /// drop local provider secrets the remote metadata no longer references,
    /// then commit the metadata object verbatim. A metadata failure restores
    /// every mutated account through the same rollback contract as edits.
    func applySynced(settings object: [String: Any], secrets payload: [String: String]) throws {
        var undo: [() throws -> Void] = []
        try store.applySynced(object, mutate: { current, remote in
            let referenced = Set(remote.profiles.compactMap(\.secretReference).filter { $0.namespace == "provider" })
            for account in referenced {
                guard let envelope = payload[account.rawValue] else { continue }
                // An environment override pins the device; leave it alone.
                if try readForEdit(account, source: .effective).stored?.tier == .environment { continue }
                undo.append(try editSecret(account: account, value: SecretValue(envelope)))
            }
            let previous = Set(current.profiles.compactMap(\.secretReference).filter { $0.namespace == "provider" })
            for account in previous.subtracting(referenced) {
                undo.append(try editSecret(account: account, value: nil))
            }
        }, rollback: { for restore in undo.reversed() { try restore() } })
    }

    /// A missing file exports the canonical empty settings document.
    static let defaultObject: [String: Any] = [
        "version": ProviderSettings.currentVersion, "profiles": [[String: Any]](),
        "selectedProfileID": NSNull(),
    ]

    /// UI receives a tier without receiving the stored value.
    public func secretTier(for id: ProviderProfileID) throws -> SecretTier? {
        try store.withSettings { settings in
            guard let profile = settings.profiles.first(where: { $0.id == id }) else {
                throw ProviderSettingsError.profileNotFound
            }
            return try profile.secretReference.flatMap { try readSecret($0, source: .effective)?.tier }
        }
    }

    private func checkDestination(_ draft: ProviderDraft, baseURL: URL, previous: ProviderProfile?) throws {
        guard let previous, draft.key == .keep else { return }
        if previous.kind != draft.kind || previous.credentialOrigin != ProviderSettings.credentialOrigin(baseURL) {
            throw ProviderSettingsError.keyRequiredForChangedDestination
        }
    }

    private func keptReference(for id: ProviderProfileID, previous: ProviderProfile?) throws -> SecretAccount? {
        if let previous { return previous.secretReference }
        // New IDs may have an explicit environment override. Never adopt an
        // orphaned persisted key whose original destination is unknown.
        return try readSecret(.provider(id), source: .effective)?.tier == .environment ? .provider(id) : nil
    }

    private func validateKey(_ edit: ProviderKeyEdit) throws {
        guard case .replace(let value) = edit else { return }
        let valid = value.withValue {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        guard valid else { throw ProviderSettingsError.invalidKey }
    }

    private func readSecret(_ account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        do { return try secrets.read(account: account, source: source) }
        catch let error as SecretStoreError { throw ProviderSettingsError.secret(error) }
        catch { throw ProviderSettingsError.secret(.readFailed) }
    }

    private func readForEdit(_ account: SecretAccount, source: SecretReadSource) throws
        -> (stored: StoredSecret?, unreadable: Bool) {
        do { return (try secrets.read(account: account, source: source), false) }
        // Abort before mutation, while preserving the public typed-error contract.
        catch is CancellationError { throw ProviderSettingsError.secret(.readFailed) }
        catch let error as SecretStoreError where error != .locked && error != .unavailable && error != .readFailed {
            throw ProviderSettingsError.secret(error)
        }
        catch { return (nil, true) }
    }

    // Bind inside the secret: a failed rollback can leave metadata byte-identical.
    private func bindSecret(_ value: SecretValue, kind: ProviderKind, baseURL: URL) throws -> SecretValue {
        do {
            return try value.withValue { key in
                let credential = Credential(version: Credential.currentVersion, origin: ProviderSettings.credentialOrigin(baseURL),
                                            kind: kind, key: key)
                return SecretValue(String(decoding: try JSONEncoder().encode(credential), as: UTF8.self))
            }
        } catch { throw ProviderSettingsError.secret(.writeFailed) }
    }

    private func resolveSecret(_ account: SecretAccount, kind: ProviderKind, baseURL: URL) throws -> SecretValue? {
        guard let stored = try readSecret(account, source: .effective) else { return nil }
        // Environment values are raw, explicit operator overrides (B23).
        if stored.tier == .environment { return stored.value }
        let credential = stored.value.withValue {
            try? JSONDecoder().decode(Credential.self, from: Data($0.utf8))
        }
        guard let credential, credential.version == Credential.currentVersion, credential.kind == kind,
              credential.origin == ProviderSettings.credentialOrigin(baseURL) else {
            throw ProviderSettingsError.keyRequiredForChangedDestination
        }
        let key = SecretValue(credential.key)
        try validateKey(.replace(key))
        return key
    }

    /// Readable edits compensate because metadata and OS secrets cannot transact.
    /// Explicit recovery discards an unreadable payload without restoring it.
    private func editSecret(account: SecretAccount, value: SecretValue?) throws -> () throws -> Void {
        if value != nil, try readForEdit(account, source: .effective).stored?.tier == .environment {
            throw ProviderSettingsError.secret(.readOnly)
        }
        let (previous, unreadable) = try readForEdit(account, source: .persisted)
        if value == nil, previous == nil, !unreadable { return {} }

        var failure = SecretStoreError.deleteFailed
        do {
            // Discard only this account. A shared unreadable map must fail closed
            // in the driver rather than erase unrelated accounts. A failed write
            // after discarding an unreadable payload can leave the account empty.
            if unreadable || value == nil { try secrets.delete(account: account) }
            if let value {
                failure = .writeFailed
                try secrets.write(value, account: account)
            }
        } catch let error as SecretStoreError {
            log?.write(.warning, "Provider secret update failed.")
            throw ProviderSettingsError.secret(error)
        } catch {
            log?.write(.warning, "Provider secret update failed.")
            throw ProviderSettingsError.secret(failure)
        }
        return { [secrets] in
            if let previous { try secrets.write(previous.value, account: account) }
            // An unreadable discarded payload cannot be restored. Remove any
            // replacement so failed metadata cannot authorize a different key.
            else if value != nil { try secrets.delete(account: account) }
        }
    }
}
