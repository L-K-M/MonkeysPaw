import Foundation

extension SyncReconciler {
    /// Y6 supplies copies for preservation outcomes. Adoption, path relocation,
    /// visibility and folder lifecycle require preparatory work and replanning;
    /// none can silently acknowledge this collection's cursors.
    static func application(_ plan: SyncReconciliationPlan, mutations: SyncLibraryMutations,
                            copies: [RelativePath: SyncReconciliationCopy] = [:]) throws -> SyncApplyPlan {
        var preservations: [SyncReconciliationPreservation] = []
        var installations: [SyncReconciliationInstall] = []
        var removals: [RelativePath: SyncLibraryFile] = [:]
        for operation in plan.operations {
            switch operation {
            case .install(let installation): installations.append(installation)
            case .remove(let file): removals[RelativePath(file.path)] = file
            case .preserve(let preservation):
                preservations.append(preservation)
                if let installation = preservation.installation { installations.append(installation) }
                else { removals[RelativePath(preservation.local.path)] = preservation.local }
            case .restoreUpdate: continue
            case .adoption, .pathClash, .localVisibility, .removedScope:
                throw SyncReconciliationError.requiresPolicy
            }
        }
        guard Set(copies.keys) == Set(preservations.map { RelativePath($0.local.path) }) else {
            throw SyncReconciliationError.requiresPolicy
        }
        var next = plan.nextState
        var edits: [SyncLibraryEdit] = []
        var destinations = Set(try plan.occupiedPaths.map(folded))
        destinations.formUnion(try installations.map { try folded($0.remote.libraryPath) })
        var identities = plan.localIdentities.union(next.prompts.keys)
        for preservation in preservations {
            let source = RelativePath(preservation.local.path)
            guard let copy = copies[source] else { throw SyncReconciliationError.requiresPolicy }
            let edit = copy.edit
            try edit.validate()
            guard edit.kind == .rescue, edit.retainedBytes == preservation.local.bytes,
                  edit.retainedSourcePath.map({ RelativePath($0) }) == source,
                  destinations.insert(try folded(RelativePath(edit.path))).inserted else {
                throw SyncReconciliationError.requiresPolicy
            }
            if preservation.reason == .restoreMissing {
                guard copy.origin == .rescued else { throw SyncReconciliationError.requiresPolicy }
            } else if case .conflictOf(let id) = copy.origin, id != preservation.id {
                throw SyncReconciliationError.requiresPolicy
            }
            if edit.heldIssue == nil {
                guard let rawID = edit.copyID, let id = try? SyncIdentifiers.ulid(rawID),
                      identities.insert(.assigned(id)).inserted else { throw SyncReconciliationError.requiresPolicy }
                next.prompts[.assigned(id)] = try SyncPromptState(scope: .user(next.binding.account.userID),
                    path: RelativePath(edit.path), rev: 0, origin: copy.origin)
            }
            edits.append(edit) // Copies are durable before originals can be retired.
        }
        for installation in installations {
            let remote = installation.remote
            let target = installation.target
            guard try target == nil || target?.identity == .assigned(remote.id) else {
                throw SyncReconciliationError.requiresPolicy
            }
            edits.append(try mutations.publication(remote.bytes, at: remote.libraryPath, expecting: target,
                transition: SyncIdentityTransition(from: target?.identity, to: .assigned(remote.id)), mode: remote.mode))
            if let source = installation.source, RelativePath(source.path) != remote.libraryPath {
                removals[RelativePath(source.path)] = source
            }
        }
        let publications = Set(edits.map { RelativePath($0.path) })
        for path in removals.keys.sorted() {
            guard !publications.contains(path), let file = removals[path] else {
                throw SyncReconciliationError.requiresPolicy
            }
            edits.append(try mutations.trash(file))
        }
        guard Set(edits.map { RelativePath($0.path) }).count == edits.count else {
            throw SyncReconciliationError.requiresPolicy
        }
        try next.validate()
        return SyncApplyPlan(expectedState: plan.expectedState, nextState: next, edits: edits)
    }

    static func apply(_ plan: SyncReconciliationPlan, mutations: SyncLibraryMutations,
                      journal: SyncApplyJournal, copies: [RelativePath: SyncReconciliationCopy] = [:]) throws -> SyncApplyOutcome {
        try journal.apply(application(plan, mutations: mutations, copies: copies))
    }
}
