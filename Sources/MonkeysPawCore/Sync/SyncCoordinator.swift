import Foundation

struct SyncOwnWriteExpectation {
    let path: RelativePath
    let hash: SyncHash?
}

/// Admission and revocation share a lock. An admitted synchronous journal
/// transaction finishes durably; revocation prevents all later admissions.
/// No lock is held across HTTP, or while callers drain an async task.
final class SyncWorkPermit: @unchecked Sendable {
    let binding: SyncLibraryIdentity
    let epoch: UInt64
    private let lock = NSLock()
    private var revoked = false
    private var mutations = 0
    private var receipts: [RelativePath: SyncFileChange] = [:]

    init(binding: SyncLibraryIdentity, epoch: UInt64) {
        self.binding = binding
        self.epoch = epoch
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked, !Task.isCancelled else { throw SyncHTTPClientError.transport(.cancelled) }
    }

    @discardableResult func revoke() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        revoked = true
        receipts.removeAll()
        return mutations == 0
    }

    func mutate<Value>(_ body: () throws -> Value) throws -> Value {
        lock.lock()
        guard !revoked, !Task.isCancelled else {
            lock.unlock()
            throw SyncHTTPClientError.transport(.cancelled)
        }
        mutations += 1
        lock.unlock()
        defer {
            lock.lock()
            mutations -= 1
            lock.unlock()
        }
        return try body()
    }

    func validate(_ binding: SyncLibraryIdentity) throws {
        try check()
        guard binding == self.binding else { throw SyncError.bindingMismatch }
    }

    func intendedWrites(edits: [SyncLibraryEdit], directories: [SyncDirectoryEdit],
                        library: SyncLibraryMutations) throws -> [SyncOwnWriteExpectation] {
        var paths: [RelativePath: SyncOwnWriteExpectation] = [:]
        if !directories.isEmpty {
            for file in try library.listedFiles() {
                let path = RelativePath(file.path)
                for edit in directories where edit.kind == .rename {
                    if try SyncGroupFolders.contains(path, in: edit.source) {
                        let target = SyncGroupFolders.relocated(path, from: edit.source, to: edit.destination!)
                        paths[path] = SyncOwnWriteExpectation(path: path, hash: nil)
                        paths[target] = SyncOwnWriteExpectation(path: target, hash: file.hash)
                    }
                }
            }
            // On replay, only journaled baselines prove the renamed bytes.
            for edit in directories where edit.kind == .rename {
                for file in edit.localFiles {
                    let path = RelativePath(file.path)
                    let target = SyncGroupFolders.relocated(path, from: edit.source, to: edit.destination!)
                    paths[path] = SyncOwnWriteExpectation(path: path, hash: nil)
                    paths[target] = SyncOwnWriteExpectation(path: target, hash: file.hash)
                }
            }
        }
        for edit in edits {
            let path = RelativePath(edit.path)
            paths[path] = SyncOwnWriteExpectation(path: path, hash: edit.hash)
        }
        return Array(paths.values)
    }

    /// Capture verified intended bytes before state I/O. A subsequent external
    /// incarnation must never be attributed to the earlier journaled write.
    func capture(_ intended: [SyncOwnWriteExpectation], library: SyncLibraryMutations) throws -> [SyncFileChange] {
        var changes: [SyncFileChange] = []
        for expected in intended.sorted(by: { $0.path < $1.path }) {
            // Absence has no incarnation; a reused path's later user deletion
            // cannot be distinguished from this journal's deletion.
            guard let hash = expected.hash else { continue }
            let file = try library.read(at: expected.path)
            guard file?.hash == hash else { continue }
            changes.append(SyncFileChange(path: expected.path, stamp: file?.stamp, hash: file?.hash.rawValue))
        }
        return changes
    }

    func remember(_ changes: [SyncFileChange]) {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked else { return }
        for change in changes { receipts[change.path] = change }
        if receipts.count > Limits.syncOwnWriteReceiptCap { receipts.removeAll() }
    }

    func owns(_ change: SyncFileChange, library: SyncLibraryMutations) -> Bool {
        lock.lock()
        let receipt = revoked ? nil : receipts[change.path]
        lock.unlock()
        guard let receipt, receipt.stamp == change.stamp, receipt.hash == change.hash else { return false }
        do {
            return try mutate {
                let actual = try library.read(at: change.path)
                return actual?.stamp == receipt.stamp && actual?.hash.rawValue == receipt.hash
            }
        } catch { return false }
    }
}

struct SyncPermittedTransport: HTTPTransporting {
    let transport: HTTPTransporting
    let permit: SyncWorkPermit

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try permit.check()
        do {
            let response = try await transport.send(request)
            try permit.check()
            return response
        } catch {
            try permit.check()
            throw error
        }
    }
}

struct SyncPassResult {
    var counts = SyncCounts()
    var details: [SyncFileDetail] = []
    var rerun = false
}

enum SyncCoordinatorError: Error { case recoveryRequired, noProgress, fileErrors }

/// One invocation executes a complete pass. SyncService serializes invocations
/// and owns triggers/UI; each coordinator belongs to exactly one graph epoch.
final class SyncCoordinator {
    let permit: SyncWorkPermit
    private let states: SyncStateStore
    private let accounts: SyncAccountStore
    private let mutations: SyncLibraryMutations
    private let journal: SyncApplyJournal
    private let pending: SyncPendingOperationStore
    private let collector: SyncPullCollector
    private let client: SyncHTTPClient
    private let push: SyncPushEngine
    private let device: String
    private let freshID: () throws -> ULID
    private let date: () -> Date
    private let now: () -> ContinuousClock.Instant
    private var accessGeneration: Int64 = 0

    init(binding: SyncLibraryIdentity, epoch: UInt64, client: SyncHTTPClient,
         files: FileStore, states: SyncStateStore, accounts: SyncAccountStore,
         mutations: SyncLibraryMutations, journal: SyncApplyJournal, pending: SyncPendingOperationStore,
         device: String, freshID: @escaping () throws -> ULID,
         date: @escaping () -> Date, now: @escaping () -> ContinuousClock.Instant) throws {
        permit = SyncWorkPermit(binding: binding, epoch: epoch)
        self.states = states
        self.accounts = accounts
        self.mutations = mutations
        self.journal = journal
        self.pending = pending
        self.device = device
        self.freshID = freshID
        self.date = date
        self.now = now
        let client = client.permitting(permit)
        self.client = client
        collector = SyncPullCollector(client: client, files: files, userID: binding.account.userID, now: now, permit: permit)
        push = try SyncPushEngine(binding: binding, client: client, states: states, pending: pending,
            mutations: mutations, journal: journal, ownership: { try accounts.binding(for: binding.root) },
            device: device, freshID: freshID, now: date, permit: permit)
    }

    func run(progress: (SyncPassResult) -> Void = { _ in }, phase: (SyncPhase) -> Void) async throws -> SyncPassResult {
        try permit.check()
        phase(.recovering)
        _ = try currentState()
        if let record = journal.pending {
            try permit.validate(record.nextState.binding)
            try requireCommit(journal.replay(permit: permit))
        }
        let resumed = try await performingPush { try await self.push.resume(availability: .available, accessGeneration: self.accessGeneration) }
        try permit.check()
        if try pending.load(for: permit.binding) != nil { throw SyncCoordinatorError.recoveryRequired }
        var result = SyncPassResult()
        result.rerun = resumed == .refreshMemberships
        let deadline = now().advanced(by: Limits.syncCollectionBudget)
        var recollected = false
        var foldersPrepared = false
        var pull: SyncCollectedPull?
        defer { try? pull?.discard() }

        for _ in 0..<Limits.syncPreparationLimit {
            try permit.check()
            if pull == nil {
                let state = try currentState()
                phase(state?.databaseID == nil ? .resyncing : .collecting)
                pull = try await collector.collect(request(state), deadline: deadline)
                foldersPrepared = false
                try permit.check()
            }
            guard let collected = pull else { throw SyncCoordinatorError.noProgress }
            phase(.reconciling)
            // Folder allocation/mode changes prepare reconciliation without
            // committing this pull's UUID or cursors.
            let old = try currentState()
            let local = try snapshot(old)
            let memberships = collected.scopes.values.compactMap { scope -> SyncAPI.GroupMembership? in
                guard case .group(let id, let name, let role) = scope.identity else { return nil }
                return SyncAPI.GroupMembership(groupID: id, name: name, role: role)
            }
            let inventory = try SyncGroupFolders.inventory(binding: permit.binding, availability: .available,
                heldPaths: local.heldPaths, mutations: mutations)
            if !foldersPrepared {
                let folders = try SyncGroupFolders.update(memberships, state: old, ownership: ownership(),
                    inventory: inventory, mutations: mutations)
                foldersPrepared = true
                if changed(folders) { try commit(folders); continue }
            }
            // Orphan paths cannot participate in adoption or duplicate matching.
            // Their journaled retirement may request a fresh scope snapshot.
            let stale = try SyncGroupFolders.stale(state: old, ownership: ownership(), inventory: inventory,
                at: date(), freshID: freshID, mutations: mutations)
            if changed(stale) { phase(.groupFolders); try commit(stale); continue }
            let plan: SyncReconciliationPlan
            do { plan = try SyncReconciler.plan(collected, state: old, local: local) }
            catch SyncReconciliationError.invalidLocalSnapshot {
                phase(.scanning)
                let scan = try scan(old)
                guard let preparation = scan.preparation else { throw SyncReconciliationError.invalidLocalSnapshot }
                try commit(preparation)
                continue
            } catch SyncReconciliationError.snapshotRequired {
                guard !recollected else { throw SyncCoordinatorError.noProgress }
                try collected.discard()
                pull = nil
                recollected = true
                continue
            }
            if plan.mode == .restore { phase(.resyncing) }
            if try preparePolicy(plan, local: local, phase: phase) { continue }

            phase(.groupFolders)
            if !collected.removed.isEmpty {
                // Install every final accessible head before retiring its old
                // group. Keep old removed-scope records for rescue classification.
                let current = try old ?? SyncState(binding: permit.binding)
                let preparatory = try preparingAccessible(plan, old: current)
                let accessible = try application(preparatory, local: local)
                if changed(accessible) {
                    try commit(accessible)
                    continue
                }
                let removal = try SyncGroupFolders.removed(collected.removed, state: current, ownership: ownership(),
                    inventory: inventory, retainingIDs: Set(plan.nextState.prompts.keys),
                    at: date(), freshID: freshID, mutations: mutations)
                if changed(removal) { try commit(removal); continue }
            }
            try commit(application(plan, local: local))
            result.counts.pulled = plan.operations.count
            progress(result)
            try collected.discard()
            pull = nil
            phase(.scanning)
            let finalScan = try preparedScan(phase: phase)
            phase(.pushing)
            for change in finalScan.changes {
                try permit.check()
                let outcome = try await performingPush {
                    try await self.push.push(change, availability: .available, accessGeneration: self.accessGeneration)
                }
                try permit.check()
                switch outcome {
                case .acknowledged: result.counts.pushed += 1
                case .refreshMemberships: result.rerun = true
                case .replan: result.rerun = true
                case .unchanged, .held, .skipped: break
                }
                let committed = try currentState()
                result.details = try errorDetails(committed)
                result.counts.fileErrors = result.details.count
                result.counts.conflicts = committed?.prompts.values.filter { $0.origin != nil }.count ?? 0
                progress(result)
                // Membership refresh precedes any further push after a denial.
                if outcome == .refreshMemberships { break }
            }
            try permit.check()
            let final = try scan(currentState())
            result.details = final.issues.sorted { $0.key < $1.key }.map { SyncFileDetail(path: $0.key, code: $0.value.rawValue) }
            let state = try currentState()
            for detail in try errorDetails(state) {
                if !result.details.contains(where: { $0.path == detail.path }) {
                    result.details.append(detail)
                }
            }
            result.details.sort { $0.path < $1.path }
            result.counts.fileErrors = result.details.count
            result.counts.held = final.snapshot.heldPaths.count
            result.counts.conflicts = state?.prompts.values.filter { $0.origin != nil }.count ?? 0
            result.counts.pending = try final.changes.filter { try retryable($0, state: state) }.count
            result.counts.pending += (final.preparation?.edits.count ?? 0) + final.orphanFiles.count
            if final.preparation != nil || !final.orphanFiles.isEmpty || result.counts.pending > 0 { result.rerun = true }
            return result
        }
        throw SyncCoordinatorError.noProgress
    }

    private func currentState() throws -> SyncState? {
        try permit.check()
        let state = try states.load(for: permit.binding)
        accessGeneration = Self.accessGeneration(state?.groups ?? [:])
        return state
    }

    /// Settle exact intents on the original, healthy graph before replacement.
    /// This does not collect a new pull or scan/push unrelated local changes.
    func recoverJournal() async throws {
        try permit.check()
        _ = try currentState()
        if let record = journal.pending {
            try permit.validate(record.nextState.binding)
            try requireCommit(journal.replay(permit: permit))
        }
        _ = try await performingPush { try await self.push.resume(availability: .available, accessGeneration: self.accessGeneration) }
        try permit.check()
        guard journal.pending == nil, try pending.load(for: permit.binding) == nil else {
            throw SyncCoordinatorError.recoveryRequired
        }
    }

    private func ownership() throws -> SyncLibraryBinding? { try accounts.binding(for: permit.binding.root) }

    private func errorDetails(_ state: SyncState?) throws -> [SyncFileDetail] {
        guard let state else { return [] }
        return try state.prompts.values.compactMap { record in
            guard let error = record.lastError else { return nil }
            return try SyncFileDetail(path: SyncLocalScanner.rooted(record.path, scope: record.scope, groups: state.groups),
                code: error.code.rawValue)
        }.sorted { $0.path < $1.path }
    }

    private func performingPush(_ operation: () async throws -> SyncPushResult) async throws -> SyncPushResult {
        do { return try await operation() }
        catch SyncReconciliationError.requiresPolicy {
            for _ in 0..<Limits.syncPreparationLimit {
                guard let head = push.policyHead else { throw SyncCoordinatorError.recoveryRequired }
                try permit.check()
                var state = try currentState()
                if case .group(let id) = head.scope, state?.groups[id] == nil {
                    // /me supplies authoritative membership without reconciling
                    // a new pull over the still-pending sent-version baseline.
                    let me = try await client.me()
                    guard me.user.id == permit.binding.account.userID.rawValue,
                          me.groups.contains(where: { $0.groupID == id.rawValue }) else {
                        throw SyncCoordinatorError.recoveryRequired
                    }
                    let local = try snapshot(state)
                    let inventory = try SyncGroupFolders.inventory(binding: permit.binding, availability: .available,
                        heldPaths: local.heldPaths, mutations: mutations)
                    try commit(SyncGroupFolders.update(me.groups, state: state, ownership: ownership(),
                        inventory: inventory, mutations: mutations))
                    state = try currentState()
                }
                guard let state else { throw SyncCoordinatorError.recoveryRequired }
                let local = try snapshot(state)
                let path = try SyncLocalScanner.rooted(head.path, scope: head.scope, groups: state.groups)
                let remote = SyncReconciliationRemote(id: head.id, scope: head.scope, path: head.path,
                    libraryPath: path, rev: head.rev, bytes: head.bytes, hash: head.hash,
                    mode: try SyncGroupFolders.mode(for: head.scope, groups: state.groups))
                let key = try SyncNaming.pathKey(path)
                let targets = try local.files.filter { try SyncNaming.pathKey(RelativePath($0.path)) == key }
                let target = targets.first { RelativePath($0.path) != path || $0.identityKey != head.id.rawValue
                    || local.heldPaths.contains(RelativePath($0.path)) }
                if let target {
                    let plan = SyncReconciliationPlan(mode: .normal, expectedState: state, nextState: state,
                        operations: [], occupiedPaths: Set(local.files.map { RelativePath($0.path) }),
                        localIdentities: try Set(local.files.map { try $0.identity }))
                    try relocate(target, remote: remote, plan: plan, local: local)
                }
                do { return try await push.resume(availability: .available, accessGeneration: accessGeneration) }
                catch SyncReconciliationError.requiresPolicy { continue }
            }
            throw SyncCoordinatorError.noProgress
        }
    }

    private func retryable(_ change: SyncLocalChange, state: SyncState?) throws -> Bool {
        let identity: PromptIdentity
        let fingerprint: SyncInputFingerprint
        switch change {
        case .create(let local), .update(let local, _), .rename(let local, _), .move(let local, _):
            identity = local.identity
            let record = state?.prompts[identity]
            let operation: SyncOperation = record.map { $0.rev > 0 && $0.scope != local.scope } == true ? .move : .put
            fingerprint = try SyncInputFingerprint(bytes: local.file.bytes, path: local.path, scope: local.scope,
                accessGeneration: accessGeneration, operation: operation)
        case .delete(let key, let record):
            identity = key
            fingerprint = try SyncInputFingerprint(bytes: Data(), path: record.path, scope: record.scope,
                accessGeneration: accessGeneration, operation: .delete)
        }
        return SyncConflictPolicy.shouldAttempt(fingerprint, lastError: state?.prompts[identity]?.lastError)
    }

    private func request(_ state: SyncState?) -> SyncAPI.PullRequest {
        SyncAPI.PullRequest(databaseID: state?.databaseID?.uuidString.lowercased(),
            cursors: Dictionary(uniqueKeysWithValues: (state?.cursors ?? [:]).map { ($0.key.rawValue, $0.value) }))
    }

    private func snapshot(_ state: SyncState?) throws -> SyncReconciliationSnapshot {
        let files = try mutations.listedFiles()
        let ownership = try ownership()
        guard ownership == nil || ownership?.owner == permit.binding.account else { throw SyncError.bindingMismatch }
        let rescues = try journal.heldRescues(in: permit.binding.root)
        let held = try Set(files.filter { file in
            try ownership?.isHeld(identity: file.identity, path: RelativePath(file.path), contentHash: file.hash) == true
                || rescues.contains { $0.path == RelativePath(file.path) || $0.hash == file.hash }
        }.map { RelativePath($0.path) })
        return SyncReconciliationSnapshot(binding: permit.binding, files: files, heldPaths: held)
    }

    private func scan(_ state: SyncState?) throws -> SyncLocalScan {
        try permit.check()
        return try SyncLocalScanner.scan(binding: permit.binding, state: state, ownership: ownership(),
            retainedRescues: journal.heldRescues(in: permit.binding.root), availability: .available,
            accessGeneration: accessGeneration, freshID: freshID, mutations: mutations)
    }

    private func preparedScan(phase: (SyncPhase) -> Void) throws -> SyncLocalScan {
        for _ in 0..<Limits.syncPreparationLimit {
            let state = try currentState()
            let local = try scan(state)
            if !local.orphanFiles.isEmpty {
                phase(.groupFolders)
                let inventory = try SyncGroupFolders.inventory(binding: permit.binding, availability: .available,
                    heldPaths: local.snapshot.heldPaths, mutations: mutations)
                try commit(SyncGroupFolders.stale(state: state, ownership: ownership(), inventory: inventory,
                    at: date(), freshID: freshID, mutations: mutations))
            } else if let preparation = local.preparation { try commit(preparation) }
            else { return local }
            phase(.scanning)
        }
        throw SyncCoordinatorError.noProgress
    }

    private func changed(_ plan: SyncApplyPlan) -> Bool {
        plan.expectedState != plan.nextState || !plan.edits.isEmpty || !plan.directories.isEmpty || plan.bindingChange != nil
    }

    private func commit(_ plan: SyncApplyPlan) throws {
        try permit.check()
        try requireCommit(journal.apply(plan, permit: permit))
        accessGeneration = Self.accessGeneration(plan.nextState.groups)
    }

    /// Error fingerprints must survive same-account reauthentication/restart.
    /// Names/paths are fingerprinted separately; only authoritative access
    /// affects this stable, nonnegative generation.
    private static func accessGeneration(_ groups: [ULID: SyncGroupState]) -> Int64 {
        guard !groups.isEmpty else { return 0 }
        let roles = groups.keys.sorted { $0.rawValue < $1.rawValue }.map { $0.rawValue + ":" + groups[$0]!.role.rawValue }
        let hash = SyncHash(bytes: Data(roles.joined(separator: "\n").utf8)).rawValue
        return Int64(hash.prefix(15), radix: 16)!
    }

    private func requireCommit(_ outcome: SyncApplyOutcome) throws {
        guard outcome == .committed else { throw SyncCoordinatorError.recoveryRequired }
    }

    private func application(_ plan: SyncReconciliationPlan, local: SyncReconciliationSnapshot) throws -> SyncApplyPlan {
        let candidates = local.files.compactMap { file -> SyncConflictCopyCandidate? in
            guard !local.heldPaths.contains(RelativePath(file.path)),
                  let location = SyncLocalScanner.location(of: RelativePath(file.path), binding: permit.binding,
                    groups: plan.nextState.groups) else { return nil }
            return SyncConflictCopyCandidate(scope: location.scope, file: file)
        }
        let copies = try SyncConflictPolicy.copies(for: plan, device: device, at: date(), freshID: freshID,
            existingCopies: candidates, mutations: mutations)
        return try SyncReconciler.application(plan, mutations: mutations, copies: copies)
    }

    private func preparingAccessible(_ plan: SyncReconciliationPlan, old: SyncState) throws -> SyncReconciliationPlan {
        var next = old
        next.groups.merge(plan.nextState.groups) { _, new in new }
        let removed = Set(plan.operations.compactMap { op -> SyncScopeKey? in
            if case .removedScope(let scope) = op { return scope }; return nil
        })
        next.prompts = plan.nextState.prompts
        var favorites = plan.nextState.favorites
        for (id, record) in old.prompts where removed.contains(record.scope) && next.prompts[id] == nil {
            next.prompts[id] = record
            favorites[id] = old.favorites[id]
        }
        next = try SyncState(binding: next.binding, databaseID: old.databaseID, cursors: old.cursors,
            groups: next.groups, prompts: next.prompts, favorites: favorites)
        return SyncReconciliationPlan(mode: plan.mode, expectedState: plan.expectedState, nextState: next,
            operations: plan.operations.filter { if case .removedScope = $0 { return false }; return true },
            occupiedPaths: plan.occupiedPaths, localIdentities: plan.localIdentities)
    }

    private func preparePolicy(_ plan: SyncReconciliationPlan, local: SyncReconciliationSnapshot,
                               phase: (SyncPhase) -> Void) throws -> Bool {
        for operation in plan.operations {
            switch operation {
            case .adoption(let remote, _):
                phase(.scanning)
                let decision = try SyncAdoption.match(remote, local: local, groups: plan.nextState.groups)
                switch decision {
                case .adopt(_, let occupant), .conflict(_, let occupant):
                    let preparation: SyncApplyPlan
                    do {
                        preparation = try SyncAdoption.application(decision, state: plan.expectedState, local: local,
                            groups: plan.nextState.groups, device: device, at: date(), freshID: freshID, mutations: mutations)
                    } catch SyncReconciliationError.requiresPolicy {
                        try relocate(occupant, remote: remote, plan: plan, local: local)
                        return true
                    }
                    try commit(preparation)
                case .clash(_, let occupant): try relocate(occupant, remote: remote, plan: plan, local: local)
                case .held(let path):
                    guard let occupant = local.files.first(where: { RelativePath($0.path) == path }) else {
                        throw SyncCoordinatorError.recoveryRequired
                    }
                    try relocate(occupant, remote: remote, plan: plan, local: local)
                default: throw SyncReconciliationError.requiresPolicy
                }
                return true
            case .pathClash(let remote, let occupant):
                try relocate(occupant, remote: remote, plan: plan, local: local)
                return true
            case .localVisibility(let remote):
                let issue = try SyncAdoption.localVisibility(remote, state: plan.expectedState, binding: permit.binding,
                    groups: plan.nextState.groups, accessGeneration: accessGeneration)
                if changed(issue) { try commit(issue) }
                throw SyncCoordinatorError.fileErrors
            default: continue
            }
        }
        return false
    }

    private func relocate(_ file: SyncLibraryFile, remote: SyncReconciliationRemote,
                          plan: SyncReconciliationPlan, local: SyncReconciliationSnapshot) throws {
        let path = RelativePath(file.path)
        let location = SyncLocalScanner.location(of: path, binding: permit.binding, groups: plan.nextState.groups)
        var next = try plan.expectedState ?? SyncState(binding: permit.binding, groups: plan.nextState.groups)
        let held = local.heldPaths.contains(path)
        if held || !LibraryPath.isPrompt(file.path) || SyncLocalScanner.contentIssue(file) != nil
            || location == nil || (location?.scope.pathScope == .group &&
            (try? SyncGroupFolders.mode(for: location!.scope, groups: plan.nextState.groups)) == .readOnly) {
            let inventory = try SyncGroupFolders.inventory(binding: permit.binding, availability: .available,
                heldPaths: local.heldPaths, mutations: mutations)
            try commit(SyncGroupFolders.rescueOccupant(file, state: plan.expectedState, ownership: ownership(),
                inventory: inventory, at: date(), freshID: freshID, mutations: mutations))
            return
        }
        let occupied = local.files.compactMap { other -> RelativePath? in
            guard let otherLocation = SyncLocalScanner.location(of: RelativePath(other.path), binding: permit.binding,
                groups: plan.nextState.groups), otherLocation.scope == location!.scope else { return nil }
            return otherLocation.path
        }
        let destination: RelativePath
        do { destination = try SyncNaming.clash(location!.path, scope: location!.scope.pathScope, occupiedPaths: occupied) }
        catch SyncNamingError.exhausted {
            let identity = try file.identity
            let record = next.prompts[identity]
            let issue = try SyncPromptError(code: .pathClash, fingerprint: SyncInputFingerprint(bytes: file.bytes,
                path: location!.path, scope: location!.scope, accessGeneration: accessGeneration, operation: .put))
            next.prompts[identity] = try SyncPromptState(scope: record?.scope ?? location!.scope,
                path: record?.path ?? location!.path, rev: record?.rev ?? 0,
                canonicalHash: record?.canonicalHash, origin: record?.origin, lastError: issue)
            let diagnostics = SyncApplyPlan(expectedState: plan.expectedState, nextState: next, edits: [])
            if changed(diagnostics) { try commit(diagnostics) }
            throw SyncCoordinatorError.fileErrors
        }
        let rooted = try SyncLocalScanner.rooted(destination, scope: location!.scope, groups: plan.nextState.groups)
        let identity = try file.identity
        let target = PromptIdentity(path: rooted.string, id: PromptCodec.parseFile(file.bytes,
            filename: LibraryPath.filename(file.path)).frontMatter.id)
        next = try SyncLocalScanner.migrating(next, from: identity, to: target)
        let publication = try mutations.publication(file.bytes, at: rooted, expecting: nil,
            transition: SyncIdentityTransition(from: identity, to: target), mode: .normal,
            kind: .relocate, adoptingSource: file)
        try commit(SyncApplyPlan(expectedState: plan.expectedState, nextState: next,
            edits: [publication, try mutations.trash(file)]))
    }
}
