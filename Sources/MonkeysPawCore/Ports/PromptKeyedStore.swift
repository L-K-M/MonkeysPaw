public enum PromptKeyMigration: Sendable {
    case unchanged
    case migrated
}

/// History participates now; usage and values stores join in later slices.
/// Move all state or throw without changing it. Reject occupied destination
/// keys rather than replacing state. A completed move must be reversible by
/// migrating back; return unchanged when the source has no state.
public protocol PromptKeyedStore {
    @discardableResult
    func migrateKey(from source: PromptIdentity, to destination: PromptIdentity) throws -> PromptKeyMigration
}
