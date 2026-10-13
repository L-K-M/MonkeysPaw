import Foundation

enum SyncReconciliationError: Error, Equatable {
    case invalidPull
    case invalidLocalSnapshot
    case unavailableLibrary
    case bindingMismatch
    case groupFolderRequired(ULID)
    case requiresPolicy
}

/// Y7 supplies the full rooted listing, including managed files outside browser
/// enumeration. An unavailable root must never masquerade as an empty library.
struct SyncReconciliationSnapshot {
    enum Availability { case available, unavailable }
    let binding: SyncLibraryIdentity
    let files: [SyncLibraryFile]
    let availability: Availability

    init(binding: SyncLibraryIdentity, files: [SyncLibraryFile], availability: Availability = .available) {
        self.binding = binding
        self.files = files
        self.availability = availability
    }
}

struct SyncReconciliationRemote: CustomStringConvertible, CustomReflectable {
    let id: ULID
    let scope: SyncScopeKey
    let path: RelativePath
    let libraryPath: RelativePath
    let rev: Int64
    let bytes: Data
    let hash: SyncHash
    let mode: SyncFileMode
    var description: String { "<reconciliation remote>" }
    var customMirror: Mirror { Mirror(self, children: ["remote": description]) }
}

/// Source and target baselines carry the actual ID, bytes and incarnation.
/// A distinct target occupant requires Y6 relocation and a fresh plan first.
struct SyncReconciliationInstall: CustomStringConvertible, CustomReflectable {
    let remote: SyncReconciliationRemote
    let source: SyncLibraryFile?
    let target: SyncLibraryFile?
    var description: String { "<reconciliation install>" }
    var customMirror: Mirror { Mirror(self, children: ["install": description]) }
}

struct SyncReconciliationPreservation: CustomStringConvertible, CustomReflectable {
    enum Reason: Equatable { case dirtyUpsert, dirtyRemoval, restoreMissing, restoreViewer }
    let id: ULID
    let reason: Reason
    let local: SyncLibraryFile
    let installation: SyncReconciliationInstall?
    var description: String { "<reconciliation preservation>" }
    var customMirror: Mirror { Mirror(self, children: ["preservation": description]) }
}

/// Y8 re-reads this local version and updates on the adopted server revision,
/// only after the entire journal commits. Viewer differences use preservation.
struct SyncReconciliationRestoreUpdate: CustomStringConvertible, CustomReflectable {
    let remote: SyncReconciliationRemote
    let local: SyncLibraryFile
    var description: String { "<reconciliation restore update>" }
    var customMirror: Mirror { Mirror(self, children: ["update": description]) }
}

enum SyncReconciliationOperation: CustomStringConvertible, CustomReflectable {
    case install(SyncReconciliationInstall)
    case remove(SyncLibraryFile)
    case preserve(SyncReconciliationPreservation)
    /// Y7 handles ID-first / identity-neutral path adoption before replanning.
    case adoption(remote: SyncReconciliationRemote, local: SyncLibraryFile)
    /// Y6 relocates this occupant, preserving its identity and keyed history.
    case pathClash(remote: SyncReconciliationRemote, occupant: SyncLibraryFile)
    case localVisibility(SyncReconciliationRemote)
    /// Y9 owns folder rescue/trash/lifecycle. Resolve it before cursor commit.
    case removedScope(SyncScopeKey)
    case restoreUpdate(SyncReconciliationRestoreUpdate)
    var description: String { "<reconciliation operation>" }
    var customMirror: Mirror { Mirror(self, children: ["operation": description]) }
}

struct SyncReconciliationPlan: CustomStringConvertible, CustomReflectable {
    enum Mode: Equatable { case normal, firstSync, restore }
    let mode: Mode
    let expectedState: SyncState?
    /// Prospective only. No caller may persist this outside the apply journal.
    let nextState: SyncState
    let operations: [SyncReconciliationOperation]
    let occupiedPaths: Set<RelativePath>
    let localIdentities: Set<PromptIdentity>
    var restoreUpdates: [SyncReconciliationRestoreUpdate] {
        operations.compactMap { if case .restoreUpdate(let update) = $0 { return update }; return nil }
    }
    var description: String { "<reconciliation plan>" }
    var customMirror: Mirror { Mirror(self, children: ["plan": description]) }
}

/// Y6 chooses naming, metadata and a stable fresh ID before journal creation.
/// A new rescue retains exact losing bytes/source mapping. A reused copy is a
/// checked .apply of its unchanged bytes, so racing edits block source retirement.
struct SyncReconciliationCopy {
    let edit: SyncLibraryEdit
    let origin: SyncPromptOrigin
}
