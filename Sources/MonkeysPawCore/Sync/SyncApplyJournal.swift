import Foundation

struct SyncApplyPlan {
    let id: UUID
    let expectedState: SyncState?
    let nextState: SyncState
    let edits: [SyncLibraryEdit]

    init(id: UUID = UUID(), expectedState: SyncState?, nextState: SyncState, edits: [SyncLibraryEdit]) {
        self.id = id
        self.expectedState = expectedState
        self.nextState = nextState
        self.edits = edits
    }
}

struct SyncApplyStep: Codable {
    let edit: SyncLibraryEdit
    let migrations: [SyncKeyedMigration]
    var started = false
    var completed = false
}

struct SyncApplyRecord: Codable, CustomStringConvertible, CustomReflectable {
    let version: Int
    let id: UUID
    let expectedState: SyncState?
    let nextState: SyncState
    var steps: [SyncApplyStep]
    var description: String { "<sync apply journal>" }
    var customMirror: Mirror { Mirror(self, children: ["journal": description]) }

    init(plan: SyncApplyPlan, steps: [SyncApplyStep]) throws {
        version = Limits.syncApplyJournalVersion
        id = plan.id
        expectedState = plan.expectedState
        nextState = plan.nextState
        self.steps = steps
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case version, id, expectedState, nextState, steps }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        version = try value.decode(Int.self, forKey: .version)
        id = try value.decode(UUID.self, forKey: .id)
        expectedState = try value.decodeIfPresent(SyncState.self, forKey: .expectedState)
        nextState = try value.decode(SyncState.self, forKey: .nextState)
        steps = try value.decode([SyncApplyStep].self, forKey: .steps)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(version, forKey: .version)
        try value.encode(id, forKey: .id)
        // Explicit null prevents supported-field preservation resurrecting a
        // superseded plan's baseline after an authorized recovery reset.
        try value.encode(expectedState, forKey: .expectedState)
        try value.encode(nextState, forKey: .nextState)
        try value.encode(steps, forKey: .steps)
    }

    func validate() throws {
        try SyncIdentifiers.version(version, current: Limits.syncApplyJournalVersion)
        try expectedState?.validate()
        try nextState.validate()
        guard expectedState == nil || expectedState?.binding == nextState.binding,
              Set(steps.map { $0.edit.id }).count == steps.count,
              Set(steps.map { RelativePath($0.edit.path) }).count == steps.count else { throw SyncError.invalidState }
        for step in steps {
            try step.edit.validate()
            guard !step.completed || step.started else { throw SyncError.invalidState }
            for migration in step.migrations {
                try migration.validate()
                guard let transition = step.edit.transition, let source = transition.source,
                      source != transition.destination else { throw SyncError.invalidState }
                switch migration.change {
                case .file(let move):
                    if migration.store == .usage {
                        guard move.source == "usage/" + source, move.destination == "usage/" + transition.destination else {
                            throw SyncError.invalidState
                        }
                    } else {
                        let from = "history/" + source + "/"
                        let to = "history/" + transition.destination + "/"
                        guard move.source.utf8.starts(with: from.utf8), move.destination.utf8.starts(with: to.utf8),
                              move.source.utf8.dropFirst(from.utf8.count).elementsEqual(
                                move.destination.utf8.dropFirst(to.utf8.count)) else { throw SyncError.invalidState }
                    }
                case .values(let from, let to, _):
                    guard from == source, to == transition.destination else { throw SyncError.invalidState }
                }
            }
        }
    }
}

enum SyncApplyOutcome: Equatable {
    case committed
    /// Retain the journal and bytes; the planner must account for prior steps.
    case replanAsConflict(operationID: UUID)
    /// Incomplete identity migration needs recovery, not a new conflict plan.
    case recoveryRequired(operationID: UUID)
}

/// One serial journal per app-data/library graph. All intents and raw losing
/// bytes are private and durable before mutation. Progress records are hints:
/// replay always checks actual files and reestablishes durability. Composition
/// must create/recover this journal before enabling ordinary library writes.
final class SyncApplyJournal {
    private enum StateCommitFailure: Error { case changed }
    private let files: FileStore
    private let operations: SyncFileOperations
    private let mutations: SyncLibraryMutations
    private let states: SyncStateStore
    private let persistence: SyncPersistence<SyncApplyRecord>
    private let lock = NSLock()

    init(files: FileStore, operations: SyncFileOperations,
         mutations: SyncLibraryMutations, states: SyncStateStore) throws {
        self.files = files
        self.operations = operations
        self.mutations = mutations
        self.states = states
        persistence = SyncPersistence(files: files, operations: operations,
            path: "sync/apply.json", version: Limits.syncApplyJournalVersion)
        do {
            if let record = try persistence.load() { try mutations.begin(record.id) }
        } catch {
            // Corrupt/future journals cannot authorize editing around recovery.
            try mutations.begin(UUID())
            throw error
        }
    }

    var pending: SyncApplyRecord? { persistence.snapshot.value }

    func apply(_ plan: SyncApplyPlan) throws -> SyncApplyOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard try persistence.load() == nil else { throw SyncError.invalidState }
        guard try states.load(for: plan.nextState.binding) == plan.expectedState else {
            return .replanAsConflict(operationID: plan.id)
        }
        try mutations.begin(plan.id)
        do {
            let steps = try plan.edits.map { edit in
                try edit.validate()
                return SyncApplyStep(edit: edit, migrations: try mutations.prepareMigrations(for: edit))
            }
            let record = try SyncApplyRecord(plan: plan, steps: steps)
            try persistence.update { current in
                guard current == nil else { throw SyncError.invalidState }
                return record
            }
        } catch {
            if persistence.snapshot.error == nil, persistence.snapshot.value == nil { mutations.finish(plan.id) }
            throw Self.safe(error)
        }
        return try run()
    }

    /// No new names or IDs are generated on replay. Safe to call twice.
    func replay() throws -> SyncApplyOutcome {
        lock.lock()
        defer { lock.unlock() }
        return try run()
    }

    /// Replace a conflicted plan only after accounting for its committed steps.
    /// Preserve the entire old intent durably first. An incomplete identity
    /// migration must be recovered, never silently dropped by replanning.
    func replan(_ plan: SyncApplyPlan) throws -> SyncApplyOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let previous = try persistence.load(), previous.id != plan.id,
              previous.nextState.binding == plan.nextState.binding else { throw SyncError.invalidState }
        guard try previous.steps.allSatisfy({ try mutations.canReplan($0) }) else {
            throw LibraryError.recoveryRequired
        }
        guard try states.load(for: plan.nextState.binding) == plan.expectedState else {
            return .replanAsConflict(operationID: plan.id)
        }
        let steps = try plan.edits.map { edit in
            try edit.validate()
            return SyncApplyStep(edit: edit, migrations: try mutations.prepareMigrations(for: edit))
        }
        let replacement = try SyncApplyRecord(plan: plan, steps: steps)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try retain(encoder.encode(previous), path: "sync/retained/" + previous.id.uuidString.lowercased() + "-journal.json")
            try persistence.update { current in
                guard current?.id == previous.id else { throw SyncError.invalidState }
                return replacement
            }
            try mutations.replacePermit(previous.id, with: replacement.id)
        } catch { throw Self.safe(error) }
        return try run()
    }

    private func run() throws -> SyncApplyOutcome {
        guard var record = try persistence.load() else { return .committed }
        try mutations.begin(record.id)
        let binding = record.nextState.binding
        let state = try states.load(for: binding)
        guard state == record.expectedState || state == record.nextState else {
            return .replanAsConflict(operationID: record.id)
        }
        var stateCommitted = false

        do {
            for index in record.steps.indices {
                let step = record.steps[index]
                try retain(step.edit)
                if !step.started {
                    record.steps[index].started = true
                    try save(record)
                }
                let result: SyncLibraryMutationResult
                do { result = try mutations.apply(step.edit, attempt: step.started ? .replay : .first) }
                catch let operationError as SyncFileOperationError {
                    // A native race can report additional displaced bytes after
                    // publication. Keep them even when durability failed.
                    if let displaced = operationError.displacedBytes, displaced != step.edit.retainedBytes {
                        do { try retain(displaced, path: retentionPrefix(step.edit) + "-displaced.bin") }
                        catch { throw operationError }
                    }
                    throw operationError
                }
                if let displaced = result.displacedBytes, displaced != step.edit.retainedBytes {
                    do { try retain(displaced, path: retentionPrefix(step.edit) + "-displaced.bin") }
                    catch { throw SyncFileOperationError(.ioFailure, effect: result.effect, displacedBytes: displaced) }
                }
                if case .replanAsConflict = result.outcome {
                    return try mutations.canReplan(step) ? .replanAsConflict(operationID: step.edit.id)
                        : .recoveryRequired(operationID: step.edit.id)
                }
                for migration in step.migrations {
                    try mutations.migrate(migration, operations: operations)
                }
                record.steps[index].completed = true
                try save(record)
            }

            // Do not commit a baseline after a noncooperating edit during other
            // steps or keyed-state migration. Never remove that newer version.
            for step in record.steps {
                if case .replanAsConflict = try mutations.verify(step.edit) {
                    return .replanAsConflict(operationID: step.edit.id)
                }
            }
            let empty = try SyncState(binding: binding)
            try states.update(for: binding) { state in
                guard state == record.expectedState || state == record.nextState
                    || (record.expectedState == nil && state == empty) else {
                    throw StateCommitFailure.changed
                }
                state = record.nextState
            }
            stateCommitted = true
            // StateStore's private write and checked flush must finish first.
            try persistence.reset(nil)
            mutations.finish(record.id)
            return .committed
        } catch LibraryError.keyedStateConflict {
            return .recoveryRequired(operationID: record.id)
        } catch StateCommitFailure.changed {
            return .replanAsConflict(operationID: record.id)
        } catch {
            if stateCommitted { states.blockForRecovery(retaining: state) }
            throw Self.safe(error)
        }
    }

    private func save(_ record: SyncApplyRecord) throws {
        try persistence.update { current in
            guard current?.id == record.id else { throw SyncError.invalidState }
            return record
        }
    }

    private func retentionPrefix(_ edit: SyncLibraryEdit) -> String {
        "sync/retained/" + edit.id.uuidString.lowercased()
    }

    private struct Retention: Codable {
        let version: Int
        let sourcePath: String?
        let hash: SyncHash
        let copyID: String?
        let heldIssue: SyncIssueCode?
    }

    private func retain(_ edit: SyncLibraryEdit) throws {
        guard let bytes = edit.retainedBytes else { return }
        let prefix = retentionPrefix(edit)
        try retain(bytes, path: prefix + ".bin")
        let metadata = Retention(version: Limits.syncApplyJournalVersion, sourcePath: edit.retainedSourcePath,
            hash: SyncHash(bytes: bytes), copyID: edit.copyID, heldIssue: edit.heldIssue)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try retain(encoder.encode(metadata), path: prefix + ".json")
    }

    private func retain(_ bytes: Data, path: String) throws {
        if let current = try SyncDurability.readIfPresent(path, files: files) {
            guard current == bytes else { throw SyncError.invalidState }
        } else { try files.writePrivate(bytes, at: path) }
        try SyncDurability.flushFileAndParents(path, operations: operations)
    }

    private static func safe(_ error: Error) -> Error {
        if let error = error as? SyncError { return error }
        if let error = error as? SyncFileOperationError { return error }
        if let error = error as? FileStoreError { return SyncError.writeFailed(error) }
        return SyncError.invalidState
    }
}
