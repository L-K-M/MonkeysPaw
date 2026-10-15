/// Platform-owned storage. Implementations serialize account access and never
/// log values or underlying errors. A failed mutation preserves readable values.
/// Explicit deletion may discard an unreadable target without reading its value;
/// an unreadable shared map must fail closed rather than lose unrelated accounts.
///
/// Effective reads follow the platform ladder and report the actual tier.
/// Persisted reads bypass environment overrides so a service can restore an
/// old value after a failed settings write. Write affects only persisted storage,
/// never the environment; Services reject user edits of environment-backed keys
/// while allowing compensation to restore persisted values beneath an override.
/// Successful writes report a persistent tier. Delete is idempotent, removes
/// all persisted copies of that account and leaves the environment untouched
/// (§19 B23).
public protocol SecretStore {
    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret?
    @discardableResult
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier
    func delete(account: SecretAccount) throws
}
