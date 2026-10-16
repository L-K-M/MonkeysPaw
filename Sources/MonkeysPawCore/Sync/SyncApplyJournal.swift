import Foundation

struct SyncApplyPlan {
    let id: UUID
    let expectedState: SyncState?
    let nextState: SyncState
    let edits: [SyncLibraryEdit]
    let directories: [SyncDirectoryEdit]
    let bindingChange: SyncBindingChange?

    init(id: UUID = UUID(), expectedState: SyncState?, nextState: SyncState, edits: [SyncLibraryEdit],
         directories: [SyncDirectoryEdit] = [], bindingChange: SyncBindingChange? = nil) {
        self.id = id
        self.expectedState = expectedState
        self.nextState = nextState
        self.edits = edits
        self.directories = directories
        self.bindingChange = bindingChange
    }
}

/// Independent ownership and upload holds commit inside the same recovery gate
/// as folder changes. Y11 enables a new account only after this plan commits.
struct SyncBindingChange: Codable {
    let expected: SyncLibraryBinding?
    let next: SyncLibraryBinding

    private enum CodingKeys: String, CodingKey { case expected, next }

    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(expected, forKey: .expected)
        try value.encode(next, forKey: .next)
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
    var directorySteps: [SyncDirectoryStep]
    let bindingChange: SyncBindingChange?
    var description: String { "<sync apply journal>" }
    var customMirror: Mirror { Mirror(self, children: ["journal": description]) }

    init(plan: SyncApplyPlan, steps: [SyncApplyStep], directorySteps: [SyncDirectoryStep]? = nil) throws {
        guard directorySteps != nil || plan.directories.isEmpty else { throw SyncError.invalidState }
        version = Limits.syncApplyJournalVersion
        id = plan.id
        expectedState = plan.expectedState
        nextState = plan.nextState
        self.steps = steps
        self.directorySteps = directorySteps ?? []
        bindingChange = plan.bindingChange
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case version, id, expectedState, nextState, steps, directorySteps, bindingChange }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        version = try value.decode(Int.self, forKey: .version)
        id = try value.decode(UUID.self, forKey: .id)
        expectedState = try value.decodeIfPresent(SyncState.self, forKey: .expectedState)
        nextState = try value.decode(SyncState.self, forKey: .nextState)
        steps = try value.decode([SyncApplyStep].self, forKey: .steps)
        directorySteps = try value.decodeIfPresent([SyncDirectoryStep].self, forKey: .directorySteps) ?? []
        bindingChange = try value.decodeIfPresent(SyncBindingChange.self, forKey: .bindingChange)
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
        try value.encode(directorySteps, forKey: .directorySteps)
        try value.encode(bindingChange, forKey: .bindingChange)
    }

    func validate() throws {
        try SyncIdentifiers.version(version, current: Limits.syncApplyJournalVersion)
        try expectedState?.validate()
        try nextState.validate()
        guard expectedState == nil || expectedState?.binding == nextState.binding,
              Set(steps.map { $0.edit.id }).count == steps.count,
              Set(steps.map { RelativePath($0.edit.path) }).count == steps.count else { throw SyncError.invalidState }
        let operationIDs = steps.map { $0.edit.id } + directorySteps.map { $0.edit.id }
        guard Set(operationIDs).count == operationIDs.count,
              Set(directorySteps.map { $0.edit.source }).count == directorySteps.count else { throw SyncError.invalidState }
        if let change = bindingChange {
            try change.expected?.validate()
            try change.next.validate()
            guard change.next.root == nextState.binding.root,
                  change.expected == nil || (change.expected?.root == nextState.binding.root
                    && change.expected?.owner == nextState.binding.account) else { throw SyncError.bindingMismatch }
        }
        for step in directorySteps {
            try step.edit.validate()
            guard !step.completed || step.started else { throw SyncError.invalidState }
            let transitions = try step.edit.identityTransitions()
            for migration in step.migrations {
                try migration.validate()
                guard transitions.contains(where: { matches(migration, transition: $0) }) else { throw SyncError.invalidState }
            }
        }
        for step in steps {
            try step.edit.validate()
            guard step.edit.kind != .repairDuplicate || step.migrations.isEmpty else { throw SyncError.invalidState }
            guard !step.completed || step.started else { throw SyncError.invalidState }
            for migration in step.migrations {
                try migration.validate()
                guard let transition = step.edit.transition, let source = transition.source,
                      source != transition.destination else { throw SyncError.invalidState }
                guard matches(migration, transition: transition) else { throw SyncError.invalidState }
            }
        }
    }

    private func matches(_ migration: SyncKeyedMigration, transition: SyncIdentityTransition) -> Bool {
        guard let source = transition.source, source != transition.destination else { return false }
        switch migration.change {
        case .file(let move):
            if migration.store == .usage { return move.source == "usage/" + source && move.destination == "usage/" + transition.destination }
            let from = "history/" + source + "/"
            let to = "history/" + transition.destination + "/"
            return move.source.utf8.starts(with: from.utf8) && move.destination.utf8.starts(with: to.utf8)
                && move.source.utf8.dropFirst(from.utf8.count).elementsEqual(move.destination.utf8.dropFirst(to.utf8.count))
        case .values(let from, let to, _): return from == source && to == transition.destination
        }
    }
}

enum SyncApplyOutcome: Equatable {
    case committed
    /// Retain the journal and bytes; the planner must account for prior steps.
    /// The ID identifies the plan for a state conflict or the edit for a file conflict.
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
    private let accounts: SyncAccountStore?
    private let persistence: SyncPersistence<SyncApplyRecord>
    private let lock = NSLock()

    init(files: FileStore, operations: SyncFileOperations,
         mutations: SyncLibraryMutations, states: SyncStateStore, accounts: SyncAccountStore? = nil) throws {
        self.files = files
        self.operations = operations
        self.mutations = mutations
        self.states = states
        self.accounts = accounts
        persistence = SyncPersistence(files: files, operations: operations,
            path: "sync/apply.json", version: Limits.syncApplyJournalVersion)
        do {
            if let record = try persistence.load() {
                mutations.resume(record.id, nextState: record.nextState)
            } else if let permit = mutations.pendingPermit {
                try settleRemovedJournal(permit)
            } else if mutations.hasUnreadableJournal {
                try SyncDurability.flushParents(of: "sync/apply.json", operations: operations)
                mutations.finishEmptyRecovery()
            }
        } catch {
            // Corrupt/future journals cannot authorize editing around recovery.
            mutations.blockForRecovery()
            throw error
        }
    }

    var pending: SyncApplyRecord? { persistence.snapshot.value }

    /// Explicit resolutions retain sent facts without queuing an automatic
    /// retry. The private copy remains the recovery source until acknowledgement.
    func retainResolution(_ bytes: Data) throws {
        guard bytes.count <= Limits.syncRecordMaxBytes else { throw SyncError.invalidState }
        let path = "sync/retained/resolution-" + SyncHash(bytes: bytes).rawValue + ".json"
        if try files.stamp(at: path) == nil { try files.writePrivate(bytes, at: path) }
        guard try files.read(at: path) == bytes else { throw SyncError.invalidState }
        try SyncDurability.flushFileAndParents(path, operations: operations)
    }

    func apply(_ plan: SyncApplyPlan, permit: SyncWorkPermit? = nil) throws -> SyncApplyOutcome {
        if let permit {
            try permit.validate(plan.nextState.binding)
            return try permit.mutate {
                let intended = try permit.intendedWrites(edits: plan.edits, directories: plan.directories, library: mutations)
                var receipts: [SyncFileChange] = []
                let result = try applyPlan(plan) { receipts = try permit.capture(intended, library: self.mutations) }
                if result == .committed { permit.remember(receipts) }
                return result
            }
        }
        return try applyPlan(plan)
    }

    private func applyPlan(_ plan: SyncApplyPlan, captureReceipts: (() throws -> Void)? = nil) throws -> SyncApplyOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard try loadRecord() == nil else { throw SyncError.invalidState }
        guard try states.load(for: plan.nextState.binding) == plan.expectedState else {
            return .replanAsConflict(operationID: plan.id)
        }
        if let change = plan.bindingChange {
            guard let accounts else { throw SyncError.invalidState }
            guard try accounts.binding(for: change.next.root) == change.expected else {
                return .replanAsConflict(operationID: plan.id)
            }
        }
        try mutations.begin(plan.id, nextState: plan.nextState)
        do {
            let steps = try plan.edits.map { edit in
                try edit.validate()
                return SyncApplyStep(edit: edit, migrations: try mutations.prepareMigrations(for: edit))
            }
            let directories = try plan.directories.map {
                SyncDirectoryStep(edit: $0, migrations: try mutations.prepareMigrations(for: $0))
            }
            let record = try SyncApplyRecord(plan: plan, steps: steps, directorySteps: directories)
            try persistence.update { current in
                guard current == nil else { throw SyncError.invalidState }
                return record
            }
        } catch {
            if persistence.snapshot.error == nil, persistence.snapshot.value == nil { mutations.finish(plan.id) }
            throw Self.safe(error)
        }
        return try run(captureReceipts: captureReceipts)
    }

    /// No new names or IDs are generated on replay. Safe to call twice.
    func replay(permit: SyncWorkPermit? = nil) throws -> SyncApplyOutcome {
        if let permit {
            return try permit.mutate { try replayPlan(permit: permit) }
        }
        return try replayPlan()
    }

    private func replayPlan(permit: SyncWorkPermit? = nil) throws -> SyncApplyOutcome {
        lock.lock()
        defer { lock.unlock() }
        // An uncertain publication can leave the cache nil or on an older intent.
        let record: SyncApplyRecord?
        do {
            record = try persistence.recover(validating: { record in
                if let record { try permit?.validate(record.nextState.binding) }
            })
        } catch {
            mutations.blockForRecovery()
            throw error
        }
        if let record {
            mutations.resume(record.id, nextState: record.nextState)
            _ = try states.recover(for: record.nextState.binding)
            let intended = try permit?.intendedWrites(edits: record.steps.map(\.edit),
                directories: record.directorySteps.map(\.edit), library: mutations) ?? []
            var receipts: [SyncFileChange] = []
            let result = try run {
                if let permit { receipts = try permit.capture(intended, library: self.mutations) }
            }
            if result == .committed { permit?.remember(receipts) }
            return result
        } else {
            if let permit = mutations.pendingPermit {
                do { try settleRemovedJournal(permit) }
                catch {
                    mutations.blockForRecovery()
                    throw error
                }
            } else if mutations.hasUnreadableJournal {
                try SyncDurability.flushParents(of: "sync/apply.json", operations: operations)
                mutations.finishEmptyRecovery()
            }
            return .committed
        }
    }

    /// Replace a conflicted plan only after accounting for its committed steps.
    /// Preserve the entire old intent durably first. An incomplete identity
    /// migration must be recovered, never silently dropped by replanning.
    func replan(_ plan: SyncApplyPlan) throws -> SyncApplyOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let previous = try loadRecord(), previous.id != plan.id,
              previous.nextState.binding == plan.nextState.binding else { throw SyncError.invalidState }
        guard try previous.steps.allSatisfy({ try mutations.canReplan($0) }),
              try previous.directorySteps.allSatisfy({ try mutations.canReplan($0) }) else {
            throw LibraryError.recoveryRequired
        }
        guard try states.load(for: plan.nextState.binding) == plan.expectedState else {
            return .replanAsConflict(operationID: plan.id)
        }
        if let change = plan.bindingChange {
            guard let accounts else { throw SyncError.invalidState }
            guard try accounts.binding(for: change.next.root) == change.expected else {
                return .replanAsConflict(operationID: plan.id)
            }
        }
        let steps = try plan.edits.map { edit in
            try edit.validate()
            return SyncApplyStep(edit: edit, migrations: try mutations.prepareMigrations(for: edit))
        }
        let directories = try plan.directories.map {
            SyncDirectoryStep(edit: $0, migrations: try mutations.prepareMigrations(for: $0))
        }
        let replacement = try SyncApplyRecord(plan: plan, steps: steps, directorySteps: directories)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try retain(encoder.encode(previous), path: "sync/retained/" + previous.id.uuidString.lowercased() + "-journal.json")
            try persistence.update { current in
                guard current?.id == previous.id else { throw SyncError.invalidState }
                return replacement
            }
            try mutations.replacePermit(previous.id, with: replacement.id, nextState: replacement.nextState)
        } catch { throw Self.safe(error) }
        return try run()
    }

    private func loadRecord() throws -> SyncApplyRecord? {
        do { return try persistence.load() }
        catch {
            mutations.blockForRecovery()
            throw error
        }
    }

    private func run(captureReceipts: (() throws -> Void)? = nil) throws -> SyncApplyOutcome {
        guard var record = try loadRecord() else { return .committed }
        try mutations.begin(record.id, nextState: record.nextState)
        let binding = record.nextState.binding
        let state = try states.load(for: binding)
        guard state == record.expectedState || state == record.nextState else {
            return .replanAsConflict(operationID: record.id)
        }
        var stateCommitted = false

        do {
            if let change = record.bindingChange {
                guard let accounts else { throw SyncError.invalidState }
                let actual = try accounts.binding(for: change.next.root)
                guard actual == change.expected || actual == change.next else {
                    return .replanAsConflict(operationID: record.id)
                }
            }
            if state != record.nextState, let conflict = try runDirectories(&record, kind: .reserve) { return conflict }
            if let conflict = try runDirectories(&record, kind: .rename) { return conflict }
            for index in record.steps.indices {
                let step = record.steps[index]
                try retain(step.edit, binding: record.nextState.binding)
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
                        catch SyncError.invalidState {
                            throw SyncFileOperationError(.invalidState, effect: operationError.effect, displacedBytes: displaced)
                        }
                        catch { throw operationError }
                    }
                    throw operationError
                }
                if let displaced = result.displacedBytes, displaced != step.edit.retainedBytes {
                    do { try retain(displaced, path: retentionPrefix(step.edit) + "-displaced.bin") }
                    catch SyncError.invalidState {
                        throw SyncFileOperationError(.invalidState, effect: result.effect, displacedBytes: displaced)
                    }
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
            if let conflict = try runDirectories(&record, kind: .removeEmpty) { return conflict }
            for step in record.directorySteps {
                // Once the mapping committed, this reserved namespace is owned
                // even if files arrived while final journal removal was pending.
                if step.edit.kind == .reserve, state == record.nextState, step.completed { continue }
                if case .replanAsConflict = try mutations.verify(step.edit) {
                    return .replanAsConflict(operationID: step.edit.id)
                }
            }
            try captureReceipts?()
            if let change = record.bindingChange {
                guard let accounts else { throw SyncError.invalidState }
                try accounts.updateBinding(for: change.next.root) { actual in
                    guard actual == change.expected || actual == change.next else { throw StateCommitFailure.changed }
                    return change.next
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
            try mutations.stateCommitted(record.id)
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

    private func settleRemovedJournal(_ permit: SyncLibraryWriteGate.Permit) throws {
        // Preparation may leave state identical; equality alone cannot prove commit.
        guard permit.commit == .stateDurable else { throw LibraryError.recoveryRequired }
        let previous = states.snapshot.value
        _ = try states.recover(for: permit.nextState.binding) { state in
            guard state == permit.nextState else { throw LibraryError.recoveryRequired }
        }
        do { try SyncDurability.flushParents(of: "sync/apply.json", operations: operations) }
        catch {
            states.blockForRecovery(retaining: previous)
            throw error
        }
        mutations.resume(permit.id, nextState: permit.nextState)
        mutations.finish(permit.id)
    }

    private func runDirectories(_ record: inout SyncApplyRecord, kind: SyncDirectoryEdit.Kind) throws -> SyncApplyOutcome? {
        for index in record.directorySteps.indices where record.directorySteps[index].edit.kind == kind {
            let edit = record.directorySteps[index].edit
            if !record.directorySteps[index].started {
                record.directorySteps[index].started = true
                try save(record)
            }
            if case .replanAsConflict = try mutations.apply(edit) { return .replanAsConflict(operationID: edit.id) }
            for migration in record.directorySteps[index].migrations {
                try mutations.migrate(migration, operations: operations)
            }
            record.directorySteps[index].completed = true
            try save(record)
        }
        return nil
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
        // Optional for existing version-1 records, which remain readable.
        let serverURL: String?
        let userID: String?
        let libraryRoot: SyncLibraryRoot?
        let destinationPath: String?
        let origin: SyncPromptOrigin?
    }

    private func retain(_ edit: SyncLibraryEdit, binding: SyncLibraryIdentity) throws {
        guard let bytes = edit.retainedBytes else { return }
        let prefix = retentionPrefix(edit)
        try retain(bytes, path: prefix + ".bin")
        let metadata = Retention(version: Limits.syncApplyJournalVersion, sourcePath: edit.retainedSourcePath,
            hash: SyncHash(bytes: bytes), copyID: edit.copyID, heldIssue: edit.kind == .rescue ? edit.heldIssue : nil,
            serverURL: binding.account.serverURL.absoluteString, userID: binding.account.userID.rawValue,
            libraryRoot: binding.root, destinationPath: edit.kind == .rescue ? edit.path : nil, origin: edit.copyOrigin)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let path = prefix + ".json"
        let encoded = try encoder.encode(metadata)
        if let current = try SyncDurability.readIfPresent(path, files: files), current != encoded {
            let old: Retention
            do { old = try JSONDecoder().decode(Retention.self, from: current) }
            catch { throw SyncError.invalidState }
            guard old.version == metadata.version,
                  old.sourcePath.map({ RelativePath($0) }) == metadata.sourcePath.map({ RelativePath($0) }), old.hash == metadata.hash,
                  old.copyID == metadata.copyID, old.heldIssue == metadata.heldIssue,
                  old.serverURL == nil || old.serverURL == metadata.serverURL,
                  old.userID == nil || old.userID == metadata.userID,
                  old.libraryRoot == nil || old.libraryRoot == metadata.libraryRoot,
                  old.destinationPath == nil || old.destinationPath.map({ RelativePath($0) }) == metadata.destinationPath.map({ RelativePath($0) }),
                  old.origin == nil || old.origin == metadata.origin,
                  var object = try JSONSerialization.jsonObject(with: current) as? [String: Any],
                  let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                throw SyncError.invalidState
            }
            // Upgrade old retained records during replay, preserving supported
            // unknown fields. The pending journal supplies the bound destination.
            object.merge(fields) { _, new in new }
            let upgraded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard upgraded.count <= Limits.syncRecordMaxBytes else { throw SyncError.invalidState }
            try files.writePrivate(upgraded, at: path)
            try SyncDurability.flushFileAndParents(path, operations: operations)
        } else { try retain(encoded, path: path) }
    }

    /// Raw holds have no wire identity/marker. Never infer upload consent from
    /// their absent state entry, or let their embedded IDs shadow managed heads.
    func heldRescues(in root: SyncLibraryRoot) throws -> [SyncRetainedRescue] {
        var result: [SyncRetainedRescue] = []
        for file in try files.listFiles() {
            let path = file.relativePath
            guard path.hasPrefix("sync/retained/"), path.hasSuffix(".json") else { continue }
            let stem = String(path.dropFirst("sync/retained/".count).dropLast(5))
            guard let operationID = UUID(uuidString: stem), operationID.uuidString.lowercased() == stem else { continue }
            let data = try files.read(at: path)
            guard data.count <= Limits.syncRecordMaxBytes else { throw SyncError.invalidState }
            let metadata: Retention
            do { metadata = try JSONDecoder().decode(Retention.self, from: data) }
            catch { throw SyncError.invalidState }
            try SyncIdentifiers.version(metadata.version, current: Limits.syncApplyJournalVersion)
            guard let issue = metadata.heldIssue else { continue }
            guard let server = metadata.serverURL, let user = metadata.userID, let libraryRoot = metadata.libraryRoot,
                  let destination = metadata.destinationPath,
                  let source = metadata.sourcePath else {
                // Legacy hold records cannot safely identify a destination.
                throw SyncError.invalidState
            }
            let binding = try SyncLibraryIdentity(account: SyncAccountIdentity(serverURL: server, userID: SyncIdentifiers.ulid(user)), root: libraryRoot)
            guard binding.root == root else { continue }
            let wire = try SyncPathValidator.validate(destination, scope: .user)
            guard wire.path.utf8.elementsEqual(destination.utf8) else { throw SyncError.invalidState }
            try FileStorePath.validate(source)
            let raw = try files.read(at: "sync/retained/" + stem + ".bin")
            guard SyncHash(bytes: raw) == metadata.hash else { throw SyncError.invalidState }
            result.append(SyncRetainedRescue(operationID: operationID, binding: binding, path: RelativePath(destination),
                sourcePath: RelativePath(source), hash: metadata.hash, issue: issue, origin: metadata.origin ?? .rescued))
        }
        return result.sorted { $0.path < $1.path }
    }

    private func retain(_ bytes: Data, path: String) throws {
        if let current = try SyncDurability.readIfPresent(path, files: files) {
            guard current == bytes else { throw SyncError.invalidState }
        } else { try files.writePrivate(bytes, at: path) }
        try SyncDurability.flushFileAndParents(path, operations: operations)
    }

    private static func safe(_ error: Error) -> Error {
        if let error = error as? CancellationError { return error }
        if let error = error as? SyncError { return error }
        if let error = error as? LibraryError { return error }
        if let error = error as? SyncFileOperationError { return error }
        if let error = error as? FileStoreError { return SyncError.writeFailed(error) }
        return SyncError.invalidState
    }
}
