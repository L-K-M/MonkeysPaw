import Foundation

/// Owns B23 key rules. Call from serial background work when a native secret
/// store can prompt or block. The shared store serializes every compound edit.
public final class ProviderSettingsService {
    private let store: ProviderSettingsStore
    private let secrets: SecretStore
    private let log: LogSink?

    public init(store: ProviderSettingsStore, secrets: SecretStore, log: LogSink? = nil) {
        self.store = store
        self.secrets = secrets
        self.log = log
    }

    public var snapshot: ProviderSettingsSnapshot { store.snapshot }

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
                undo = try editSecret(account: .provider(draft.id), value: value)
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
                key = try reference.flatMap { try readSecret($0, source: .effective)?.value }
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
            let key = try profile.secretReference.flatMap { try readSecret($0, source: .effective)?.value }
            return ProviderConnection(profileID: id, kind: profile.kind, baseURL: profile.baseURL,
                                      modelID: profile.modelID, key: key)
        }
    }

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

    /// SecretStore promises atomic per-account edits. Metadata commit uses
    /// compensation because FileStore and OS secret stores cannot transact.
    private func editSecret(account: SecretAccount, value: SecretValue?) throws -> () throws -> Void {
        if value != nil, try readSecret(account, source: .effective)?.tier == .environment {
            throw ProviderSettingsError.secret(.readOnly)
        }
        let previous = try readSecret(account, source: .persisted)
        do {
            if let value { try secrets.write(value, account: account) }
            else { try secrets.delete(account: account) }
        } catch let error as SecretStoreError {
            log?.write(.warning, "Provider secret update failed.")
            throw ProviderSettingsError.secret(error)
        } catch {
            log?.write(.warning, "Provider secret update failed.")
            throw ProviderSettingsError.secret(value == nil ? .deleteFailed : .writeFailed)
        }
        return { [secrets] in
            if let previous { try secrets.write(previous.value, account: account) }
            else { try secrets.delete(account: account) }
        }
    }
}
