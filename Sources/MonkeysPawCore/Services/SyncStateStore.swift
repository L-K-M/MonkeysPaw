import Foundation

/// One active app-data state, with explicit account/root validation on every
/// read and update. A mismatched document stays untouched until reset intent.
public final class SyncStateStore: @unchecked Sendable {
    private let persistence: SyncPersistence<SyncState>

    public init(files: FileStore, operations: SyncFileOperations) {
        persistence = SyncPersistence(files: files, operations: operations,
                                      path: "sync/state.json", version: Limits.syncStateVersion)
    }

    var snapshot: SyncStoreSnapshot<SyncState> { persistence.snapshot }

    func load(for binding: SyncLibraryIdentity) throws -> SyncState? {
        let state = try persistence.load()
        guard state == nil || state?.binding == binding else { throw SyncError.bindingMismatch }
        return state
    }

    func update(for binding: SyncLibraryIdentity, _ change: (inout SyncState) throws -> Void) throws {
        try persistence.update { current in
            guard current == nil || current?.binding == binding else { throw SyncError.bindingMismatch }
            var state = try current ?? SyncState(binding: binding)
            try change(&state)
            guard state.binding == binding else { throw SyncError.bindingMismatch }
            return state
        }
    }

    /// Account/root transitions must persist ownership/holds before this intent.
    func reset(for binding: SyncLibraryIdentity) throws { try persistence.reset(SyncState(binding: binding)) }
    /// Sign-out clears active state only; it never changes library ownership.
    func clear() throws { try persistence.reset(nil) }

    func blockForRecovery(retaining state: SyncState?) { persistence.blockForRecovery(retaining: state) }
}
