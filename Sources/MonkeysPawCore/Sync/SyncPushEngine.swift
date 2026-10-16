import Foundation

enum SyncPushResult: Equatable {
    case acknowledged, unchanged, replan, held, skipped
    /// The caller refreshes memberships before the next scan; 403 implies no role.
    case refreshMemberships
}

enum SyncPushError: Error, Equatable {
    case busy
    case pendingOperation
    case applyRequired(SyncApplyOutcome)
}

/// Executes one scanner candidate, including its move-then-edit sequence.
/// Y10 owns pass ordering, root health/epochs, scheduling and backoff. Inputs
/// always come from disk through the shared library lock, never editor buffers.
final class SyncPushEngine {
    private let binding: SyncLibraryIdentity
    private let client: SyncHTTPClient
    private let states: SyncStateStore
    private let pending: SyncPendingOperationStore
    private let mutations: SyncLibraryMutations
    private let journal: SyncApplyJournal
    private let ownership: () throws -> SyncLibraryBinding?
    private let device: String
    private let freshID: () throws -> ULID
    private let now: () -> Date
    private let permit: SyncWorkPermit?
    private let lock = NSLock()
    private var running = false
    /// A validated head requiring folder/occupant preparation, retained only
    /// until this serialized invocation returns. The exact request stays durable.
    private(set) var policyHead: SyncConflictHead?

    init(binding: SyncLibraryIdentity, client: SyncHTTPClient, states: SyncStateStore,
         pending: SyncPendingOperationStore, mutations: SyncLibraryMutations, journal: SyncApplyJournal,
         ownership: @escaping () throws -> SyncLibraryBinding?, device: String,
         freshID: @escaping () throws -> ULID, now: @escaping () -> Date = Date.init,
         permit: SyncWorkPermit? = nil) throws {
        guard client.server.baseURL == binding.account.serverURL else { throw SyncError.bindingMismatch }
        self.binding = binding
        self.client = client
        self.states = states
        self.pending = pending
        self.mutations = mutations
        self.journal = journal
        self.ownership = ownership
        self.device = device
        self.freshID = freshID
        self.now = now
        self.permit = permit
    }

    func push(_ change: SyncLocalChange, availability: SyncReconciliationSnapshot.Availability,
              accessGeneration: Int64 = 0, baseBytes: Data? = nil) async throws -> SyncPushResult {
        try begin(availability)
        defer { end() }
        if let apply = journal.pending { throw SyncPushError.applyRequired(.recoveryRequired(operationID: apply.id)) }
        guard try pending.load(for: binding) == nil else { throw SyncPushError.pendingOperation }
        switch change {
        case .create(let local), .update(let local, _), .rename(let local, _), .move(let local, _):
            guard case .assigned(let id) = local.identity else { return .replan }
            return try await pushFile(id, at: RelativePath(local.file.path),
                                      accessGeneration: accessGeneration, baseBytes: baseBytes)
        case .delete(let identity, _):
            guard case .assigned(let id) = identity else { return .replan }
            let state = try currentState()
            guard let record = state.prompts[identity], record.rev > 0 else { return .unchanged }
            let path = try SyncLocalScanner.rooted(record.path, scope: record.scope, groups: state.groups)
            let snapshot = try snapshot(state)
            guard !snapshot.files.contains(where: { $0.identityKey == id.rawValue || RelativePath($0.path) == path }),
                  try mutations.read(at: path) == nil else { return .replan }
            guard try !isHeld(identity, path: path, hash: record.canonicalHash!) else { return .held }
            let intent = try SyncConflictIntent(id: id, operation: .delete, baseRev: record.rev,
                scope: record.scope, path: record.path, sentBytes: nil, inputBytes: Data(), accessGeneration: accessGeneration)
            return try await send(SyncPendingOperation(binding: binding, intent: intent,
                libraryPath: path, file: nil, recorded: record))
        }
    }

    /// Recover exact sent facts before accepting another candidate. GET proves
    /// success or absence; an uncommitted request is replanned with fresh bytes.
    func resume(availability: SyncReconciliationSnapshot.Availability,
                accessGeneration: Int64 = 0) async throws -> SyncPushResult {
        try begin(availability)
        defer { end() }
        if journal.pending != nil { try requireCommit(journal.replay(permit: permit)) }
        guard let request = try pending.load(for: binding) else { return .unchanged }
        let state = try currentState()
        let local = try live(request.intent.id, in: snapshot(state))
        if try held(request, local: local) { try retireHeld(request); return .held }
        let result: SyncPushResult
        do {
            let prompt = try await client.prompt(id: request.intent.id)
            let head = try SyncConflictHead(prompt, userID: binding.account.userID)
            guard head.id == request.intent.id else { throw SyncConflictPolicyError.invalidHead }
            if unchangedHead(head, request: request) {
                try clearPending()
                return .replan
            }
            result = try await dispatch(.conflict(head: SyncAPI.ConflictHead(rev: head.rev,
                scope: wireScope(head.scope), path: head.path.string, content: String(decoding: head.bytes, as: UTF8.self))),
                request: request)
        } catch let error as SyncHTTPClientError {
            if error == .notFound, request.intent.baseRev == 0 {
                try clearPending()
                return .replan
            }
            // Invisible GET is not proof that an update/move was deleted.
            result = try await dispatch(error, request: request)
        }
        return try await finishMove(request, result: result, accessGeneration: accessGeneration)
    }

    private func pushFile(_ id: ULID, at path: RelativePath, accessGeneration: Int64,
                          baseBytes: Data?) async throws -> SyncPushResult {
        let state = try currentState()
        let key = PromptIdentity.assigned(id)
        guard let file = try mutations.read(at: path), file.identityKey == id.rawValue,
              LibraryPath.isPrompt(file.path), SyncLocalScanner.contentIssue(file) == nil,
              let location = SyncLocalScanner.location(of: path, binding: binding, groups: state.groups) else { return .replan }
        guard try !isHeld(key, path: path, hash: file.hash) else { return .held }
        let wire = try SyncPathValidator.validate(location.path.string, scope: location.scope.pathScope)
        let destination = RelativePath(wire.path)
        let form = try SyncLocalScanner.canonical(file.bytes, path: destination, scope: location.scope)
        let recorded = state.prompts[key]
        let operation: SyncOperation = recorded.map { $0.rev > 0 && $0.scope != location.scope } == true ? .move : .put
        if recorded?.scope == location.scope, recorded?.path == destination,
           recorded?.canonicalHash == SyncHash(bytes: form.bytes) { return .unchanged }
        let fingerprint = try SyncInputFingerprint(bytes: file.bytes, path: destination, scope: location.scope,
            accessGeneration: accessGeneration, operation: operation)
        guard SyncConflictPolicy.shouldAttempt(fingerprint, lastError: recorded?.lastError) else { return .skipped }
        var sent = form.bytes
        if operation == .move, let recorded {
            let baseline: Data
            if let known = baseBytes, try matchesBase(known, id: id, recorded: recorded) {
                baseline = try SyncLocalScanner.canonical(known, path: recorded.path, scope: recorded.scope).bytes
            }
            else if try matchesBase(file.bytes, id: id, recorded: recorded) {
                baseline = try SyncLocalScanner.canonical(file.bytes, path: recorded.path, scope: recorded.scope).bytes
            } else {
                let prompt = try await client.prompt(id: id)
                let head = try SyncConflictHead(prompt, userID: binding.account.userID)
                guard head.id == id else { throw SyncConflictPolicyError.invalidHead }
                guard head.rev == recorded.rev, head.scope == recorded.scope, head.path == recorded.path,
                      head.hash == recorded.canonicalHash else {
                    // No mutation was sent. The changed server head is still authoritative.
                    return try install(head, error: nil)
                }
                baseline = head.bytes
            }
            sent = try SyncLocalScanner.canonical(baseline, path: destination, scope: location.scope).bytes
        }
        let intent = try SyncConflictIntent(id: id, operation: operation, baseRev: recorded?.rev ?? 0,
            scope: location.scope, path: destination, sentBytes: sent, inputBytes: file.bytes, accessGeneration: accessGeneration)
        let request = try SyncPendingOperation(binding: binding, intent: intent, libraryPath: path, file: file, recorded: recorded)
        let result = try await send(request)
        return try await finishMove(request, result: result, accessGeneration: accessGeneration)
    }

    private func send(_ request: SyncPendingOperation) async throws -> SyncPushResult {
        guard SyncConflictPolicy.shouldAttempt(request.intent.fingerprint, lastError: request.recorded?.lastError) else { return .skipped }
        try savePending(request)
        // Journaling/GET may race a save. Never send the earlier captured bytes.
        let state = try currentState()
        let local = try live(request.intent.id, in: snapshot(state))
        if try held(request, local: local) { try retireHeld(request); return .held }
        let current = try mutations.read(at: request.libraryPath)
        guard state.prompts[.assigned(request.intent.id)] == request.recorded,
              same(current, request.file), request.intent.operation != .delete || local == nil else {
            try clearPending()
            return .replan
        }
        do {
            let response: SyncAPI.WriteResponse
            let intent = request.intent
            switch intent.operation {
            case .put:
                response = try await client.putPrompt(id: intent.id, request: SyncAPI.PutPromptRequest(
                    baseRev: intent.baseRev, scope: wireScope(intent.scope), path: intent.path.string,
                    content: String(decoding: intent.sentBytes!, as: UTF8.self)))
            case .delete: response = try await client.deletePrompt(id: intent.id, baseRev: intent.baseRev)
            case .move:
                response = try await client.movePrompt(id: intent.id, request: SyncAPI.MovePromptRequest(
                    baseRev: intent.baseRev, scope: wireScope(intent.scope), path: intent.path.string))
            }
            guard response.rev > intent.baseRev else { throw SyncHTTPClientError.malformedResponse }
            if intent.operation == .delete { return try deleted(request) }
            let head = try SyncConflictHead(SyncAPI.Prompt(id: intent.id.rawValue, rev: response.rev,
                scope: wireScope(intent.scope), path: intent.path.string,
                content: String(decoding: intent.sentBytes!, as: UTF8.self)), userID: binding.account.userID)
            return try acknowledge(head, request: request)
        } catch let error as SyncHTTPClientError { return try await dispatch(error, request: request) }
    }

    private func dispatch(_ error: SyncHTTPClientError, request: SyncPendingOperation) async throws -> SyncPushResult {
        var accessible: SyncAPI.Prompt?
        if error == .forbidden, request.intent.baseRev > 0 {
            do { accessible = try await client.prompt(id: request.intent.id) }
            catch let failure as SyncHTTPClientError {
                if failure == .unauthorized || failure == .transport(.cancelled) { throw failure }
                accessible = nil
            }
        }
        let state = try currentState()
        let snapshot = try snapshot(state)
        let local = try live(request.intent.id, in: snapshot)
        if try held(request, local: local) { try retireHeld(request); return .held }
        let occupied = snapshot.files.compactMap { file -> RelativePath? in
            guard let location = SyncLocalScanner.location(of: RelativePath(file.path), binding: binding, groups: state.groups),
                  location.scope == request.intent.scope else { return nil }
            return location.path
        }
        guard let outcome = try SyncConflictPolicy.resolve(error, intent: request.intent,
            userID: binding.account.userID, local: local, recorded: request.recorded,
            accessibleHead: accessible, occupiedPaths: occupied) else { throw error }
        switch outcome {
        case .acknowledged(let head): return try acknowledge(head, request: request)
        case .deleteSucceeded: return try deleted(request)
        case .fileError(let issue):
            return try fileError(issue, request: request, state: state)
        case .serverWins(let head, _):
            let result = try install(head, error: nil)
            try clearPending()
            return result
        case .remoteDeleted:
            try rescueAndRemove(request.intent.id, state: state, snapshot: snapshot, local: local)
            try clearPending()
            return .replan
        case .denied(let restore, _, let issue):
            if let restore { _ = try install(restore, error: issue) }
            else { try rescueAndRemove(request.intent.id, state: state, snapshot: snapshot, local: local) }
            try clearPending()
            return .refreshMemberships
        case .clashRename(let path): return try rename(path, request: request, state: state, local: local)
        case .adoptExisting:
            guard case .pathTaken(let existing) = error else { throw SyncConflictPolicyError.invalidResponse }
            let decision = try SyncAdoption.pathTaken(existing, intent: request.intent, local: snapshot, groups: state.groups)
            if case .adopt = decision {
                try requireCommit(journal.apply(SyncAdoption.application(decision, state: state, local: snapshot,
                    groups: state.groups, device: device, at: now(), freshID: freshID, mutations: mutations), permit: permit))
                try clearPending()
                return .acknowledged
            }
            // A newer local edit cannot be adopted as the sent create.
            do {
                let path = try SyncNaming.clash(request.intent.path, scope: request.intent.scope.pathScope, occupiedPaths: occupied)
                return try rename(path, request: request, state: state, local: local)
            } catch SyncNamingError.exhausted {
                return try fileError(.init(code: .pathClash, fingerprint: request.intent.fingerprint), request: request, state: state)
            }
        }
    }

    private func fileError(_ issue: SyncPromptError, request: SyncPendingOperation, state: SyncState) throws -> SyncPushResult {
        var next = state
        let key = PromptIdentity.assigned(request.intent.id)
        let record = next.prompts[key] ?? request.recorded
        next.prompts[key] = try SyncPromptState(scope: record?.scope ?? request.intent.scope,
            path: record?.path ?? request.intent.path, rev: record?.rev ?? 0,
            canonicalHash: record?.canonicalHash, origin: record?.origin, lastError: issue)
        try commit(state, next: next)
        try clearPending()
        return .skipped
    }

    private func acknowledge(_ head: SyncConflictHead, request: SyncPendingOperation) throws -> SyncPushResult {
        let state = try currentState()
        let key = PromptIdentity.assigned(head.id)
        let previous = state.prompts[key]
        let adopted = try SyncPromptState(scope: head.scope, path: head.path, rev: head.rev,
                                         canonicalHash: head.hash, origin: head.origin)
        guard previous == request.recorded || previous == adopted else {
            try clearPending()
            return .replan
        }
        var next = try setting(adopted, for: key, in: state)
        var edits: [SyncLibraryEdit] = []
        if head.scope.pathScope == .group, let current = try mutations.read(at: request.libraryPath),
           same(current, request.file) {
            let form = try SyncLocalScanner.canonical(current.bytes, path: head.path, scope: head.scope)
            try next.applyGroupFavorite(SyncFavoriteInput.preferred(form.favorite, after: state.prompts[key]?.favoriteInput), for: key)
            if form.bytes != current.bytes {
                edits.append(try mutations.publication(form.bytes, at: request.libraryPath, expecting: current,
                    transition: SyncIdentityTransition(from: key, to: key), mode: mode(head.scope, state: state)))
            }
        }
        try commit(state, next: next, edits: edits)
        try clearPending()
        return .acknowledged
    }

    private func finishMove(_ request: SyncPendingOperation, result: SyncPushResult,
                            accessGeneration: Int64) async throws -> SyncPushResult {
        guard request.intent.operation == .move, result == .acknowledged else { return result }
        let followup = try await pushFile(request.intent.id, at: request.libraryPath,
                                         accessGeneration: accessGeneration, baseBytes: nil)
        return followup == .unchanged ? .acknowledged : followup
    }

    private func deleted(_ request: SyncPendingOperation) throws -> SyncPushResult {
        let state = try currentState()
        let key = PromptIdentity.assigned(request.intent.id)
        guard state.prompts[key] == request.recorded || state.prompts[key] == nil else {
            try clearPending()
            return .replan
        }
        let next = try setting(nil, for: key, in: state)
        // A file recreated in flight survives and will get the 410 rescue policy.
        try commit(state, next: next)
        try clearPending()
        return .acknowledged
    }

    private func install(_ head: SyncConflictHead, error: SyncPromptError?) throws -> SyncPushResult {
        let expected = try states.load(for: binding)
        let state = try expected ?? SyncState(binding: binding)
        let snapshot = try snapshot(state)
        let path: RelativePath
        do { path = try SyncLocalScanner.rooted(head.path, scope: head.scope, groups: state.groups) }
        catch SyncError.invalidScope { policyHead = head; throw SyncReconciliationError.requiresPolicy }
        let remote = SyncReconciliationRemote(id: head.id, scope: head.scope, path: head.path, libraryPath: path,
            rev: head.rev, bytes: head.bytes, hash: head.hash, mode: mode(head.scope, state: state))
        let local = try live(head.id, in: snapshot)
        let pathKey = try SyncNaming.pathKey(path)
        let targets = try snapshot.files.filter { try SyncNaming.pathKey(RelativePath($0.path)) == pathKey }
        guard targets.count <= 1, targets.allSatisfy({
            RelativePath($0.path) == path && $0.identityKey == head.id.rawValue && !snapshot.heldPaths.contains(path)
        }) else { policyHead = head; throw SyncReconciliationError.requiresPolicy }
        if targets.isEmpty, try mutations.read(at: path) != nil {
            policyHead = head
            throw SyncReconciliationError.requiresPolicy
        }
        let installation = SyncReconciliationInstall(remote: remote, source: local, target: targets.first)
        let record = try SyncPromptState(scope: head.scope, path: head.path, rev: head.rev,
                                        canonicalHash: head.hash, origin: head.origin, lastError: error)
        var next = try setting(record, for: .assigned(head.id), in: state)
        if head.scope.pathScope == .group, let local,
           let form = try? SyncLocalScanner.canonical(local.bytes, path: head.path, scope: head.scope) {
            try next.applyGroupFavorite(SyncFavoriteInput.preferred(form.favorite,
                after: state.prompts[.assigned(head.id)]?.favoriteInput), for: .assigned(head.id))
        }
        let operation: SyncReconciliationOperation
        // B5 is only for adoption. Private formatting/comments are real losing
        // bytes on a conflict, even when identity-neutral content compares equal.
        if let local, (try? SyncLocalScanner.canonical(local.bytes, path: head.path, scope: head.scope).bytes) != head.bytes {
            operation = .preserve(.init(id: head.id, reason: .dirtyUpsert, local: local, installation: installation))
        } else { operation = .install(installation) }
        let plan = SyncReconciliationPlan(mode: .normal, expectedState: expected, nextState: next,
            operations: [operation], occupiedPaths: Set(snapshot.files.map { RelativePath($0.path) }),
            localIdentities: try Set(snapshot.files.map { try $0.identity }))
        let candidates = snapshot.files.compactMap { file -> SyncConflictCopyCandidate? in
            let path = RelativePath(file.path)
            guard !snapshot.heldPaths.contains(path),
                  let location = SyncLocalScanner.location(of: path, binding: binding, groups: state.groups) else { return nil }
            return SyncConflictCopyCandidate(scope: location.scope, file: file)
        }
        let copies = try SyncConflictPolicy.copies(for: plan, device: device, at: now(), freshID: freshID,
                                                  existingCopies: candidates, mutations: mutations)
        try requireCommit(journal.apply(SyncReconciler.application(plan, mutations: mutations, copies: copies), permit: permit))
        return .replan
    }

    private func rescueAndRemove(_ id: ULID, state: SyncState, snapshot: SyncReconciliationSnapshot,
                                 local: SyncLibraryFile?) throws {
        var next = try setting(nil, for: .assigned(id), in: state)
        var edits: [SyncLibraryEdit] = []
        if let local {
            let location = SyncLocalScanner.location(of: RelativePath(local.path), binding: binding, groups: state.groups)
            let folder: String?
            if case .group(let group) = location?.scope { folder = state.groups[group]?.folder }
            else { folder = nil }
            let copy = try SyncConflictPolicy.copy(local, origin: .conflictOf(id), userID: binding.account.userID,
                groupFolder: folder, device: device, at: now(), freshID: allocate(in: snapshot, state: state),
                occupiedPaths: snapshot.files.map { RelativePath($0.path) }, mutations: mutations)
            if let bytes = copy.edit.bytes, copy.edit.heldIssue == nil,
               let copyID = PromptCodec.parseFile(bytes, filename: LibraryPath.filename(copy.edit.path)).frontMatter.id {
                next.prompts[.assigned(copyID)] = try SyncPromptState(scope: .user(binding.account.userID),
                    path: RelativePath(copy.edit.path), rev: 0, origin: copy.origin)
            }
            edits = [copy.edit, try mutations.trash(local)]
        }
        try commit(state, next: next, edits: edits)
    }

    private func rename(_ path: RelativePath, request: SyncPendingOperation, state: SyncState,
                        local: SyncLibraryFile?) throws -> SyncPushResult {
        guard let local, let location = SyncLocalScanner.location(of: RelativePath(local.path), binding: binding, groups: state.groups),
              location.scope == request.intent.scope,
              (try? SyncNaming.pathKey(location.path)) == (try? SyncNaming.pathKey(request.intent.path)) else {
            try clearPending()
            return .replan
        }
        let destination = try SyncLocalScanner.rooted(path, scope: request.intent.scope, groups: state.groups)
        let key = PromptIdentity.assigned(request.intent.id)
        var next = state
        if let recorded = next.prompts[key], recorded.rev == 0 {
            next.prompts[key] = try SyncPromptState(scope: request.intent.scope, path: path, rev: 0, origin: recorded.origin)
        }
        let edit = try mutations.publication(local.bytes, at: destination, expecting: nil,
                                            transition: SyncIdentityTransition(from: nil, to: key))
        try commit(state, next: next, edits: [edit, try mutations.trash(local)])
        try clearPending()
        return .replan
    }

    private func currentState() throws -> SyncState {
        try states.load(for: binding) ?? SyncState(binding: binding)
    }

    private func snapshot(_ state: SyncState) throws -> SyncReconciliationSnapshot {
        let files = try mutations.listedFiles()
        guard !files.isEmpty else { return SyncReconciliationSnapshot(binding: binding, files: files) }
        let owner = try currentOwnership()
        let rescues = try journal.heldRescues(in: binding.root)
        let heldPaths = try Set(files.filter { try isHeld($0.identity, path: RelativePath($0.path), hash: $0.hash,
            state: state, owner: owner, rescues: rescues) }
            .map { RelativePath($0.path) })
        return SyncReconciliationSnapshot(binding: binding, files: files, heldPaths: heldPaths)
    }

    private func currentOwnership() throws -> SyncLibraryBinding? {
        let owner = try ownership()
        guard owner == nil || (owner?.root == binding.root && owner?.owner == binding.account) else { throw SyncError.bindingMismatch }
        try owner?.validate()
        return owner
    }

    private func isHeld(_ identity: PromptIdentity, path: RelativePath, hash: SyncHash) throws -> Bool {
        let owner = try currentOwnership()
        return try isHeld(identity, path: path, hash: hash, state: currentState(), owner: owner,
            rescues: journal.heldRescues(in: binding.root))
    }

    private func isHeld(_ identity: PromptIdentity, path: RelativePath, hash: SyncHash, state: SyncState,
                        owner: SyncLibraryBinding?, rescues: [SyncRetainedRescue]) -> Bool {
        if owner?.isHeld(identity: identity, path: path, contentHash: hash) == true { return true }
        if let location = SyncLocalScanner.location(of: path, binding: binding, groups: state.groups),
           case .group(let id) = location.scope, let folder = owner?.managedFolders.first(where: {
               $0.value.folder.utf8.elementsEqual(path.string.utf8.split(separator: 47).dropFirst().first ?? [])
           }), folder.key != id || folder.value.owner != binding.account { return true }
        return rescues.contains { $0.path == path || $0.hash == hash }
    }

    private func held(_ request: SyncPendingOperation, local: SyncLibraryFile?) throws -> Bool {
        try isHeld(.assigned(request.intent.id), path: RelativePath(local?.path ?? request.libraryPath.string),
            hash: local?.hash ?? request.file?.hash ?? request.recorded?.canonicalHash ?? SyncHash(bytes: Data()))
    }

    private func live(_ id: ULID, in snapshot: SyncReconciliationSnapshot) throws -> SyncLibraryFile? {
        let files = snapshot.files.filter { $0.identityKey == id.rawValue }
        guard files.count <= 1 else { throw SyncReconciliationError.invalidLocalSnapshot }
        return files.first
    }

    private func matchesBase(_ bytes: Data, id: ULID, recorded: SyncPromptState) throws -> Bool {
        guard let form = try? SyncLocalScanner.canonical(bytes, path: recorded.path, scope: recorded.scope),
              PromptCodec.parseFile(form.bytes, filename: LibraryPath.filename(recorded.path.string)).frontMatter.id == id else { return false }
        return SyncHash(bytes: form.bytes) == recorded.canonicalHash
    }

    private func unchangedHead(_ head: SyncConflictHead, request: SyncPendingOperation) -> Bool {
        guard let recorded = request.recorded else { return false }
        return head.rev == recorded.rev && head.scope == recorded.scope && head.path == recorded.path
            && head.hash == recorded.canonicalHash
    }

    private func setting(_ record: SyncPromptState?, for key: PromptIdentity, in state: SyncState) throws -> SyncState {
        var prompts = state.prompts
        prompts[key] = record
        let favorites = state.favorites.filter { id, _ in
            guard let prompt = prompts[id], case .group = prompt.scope else { return false }
            return true
        }
        return try SyncState(binding: state.binding, databaseID: state.databaseID, cursors: state.cursors,
                             groups: state.groups, prompts: prompts, favorites: favorites)
    }

    private func allocate(in snapshot: SyncReconciliationSnapshot, state: SyncState) throws -> ULID {
        let id = try freshID()
        guard !snapshot.files.contains(where: { $0.identityKey == id.rawValue }), state.prompts[.assigned(id)] == nil else {
            throw SyncError.invalidState
        }
        return id
    }

    private func commit(_ old: SyncState, next: SyncState, edits: [SyncLibraryEdit] = []) throws {
        let expected = try states.load(for: binding)
        let empty = try SyncState(binding: binding)
        guard expected == old || (expected == nil && old == empty) else {
            throw SyncPushError.applyRequired(.replanAsConflict(operationID: UUID()))
        }
        try requireCommit(journal.apply(SyncApplyPlan(expectedState: expected, nextState: next, edits: edits), permit: permit))
    }

    private func requireCommit(_ result: SyncApplyOutcome) throws {
        guard result == .committed else { throw SyncPushError.applyRequired(result) }
    }

    private func wireScope(_ scope: SyncScopeKey) -> SyncAPI.PromptScope {
        switch scope {
        case .user: return .user
        case .group(let id): return .group(groupID: id.rawValue)
        }
    }

    private func mode(_ scope: SyncScopeKey, state: SyncState) -> SyncFileMode {
        if case .group(let id) = scope, state.groups[id]?.role == .viewer { return .readOnly }
        return .normal
    }

    private func same(_ lhs: SyncLibraryFile?, _ rhs: SyncLibraryFile?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.path.utf8.elementsEqual(rhs.path.utf8) && lhs.stamp == rhs.stamp
            && lhs.identityKey == rhs.identityKey && lhs.hash == rhs.hash && lhs.bytes == rhs.bytes
    }

    private func begin(_ availability: SyncReconciliationSnapshot.Availability) throws {
        try permit?.check()
        guard case .available = availability else { throw SyncReconciliationError.unavailableLibrary }
        lock.lock()
        defer { lock.unlock() }
        guard !running else { throw SyncPushError.busy }
        running = true
        policyHead = nil
    }

    private func end() {
        lock.lock()
        defer { lock.unlock() }
        running = false
    }

    private func savePending(_ request: SyncPendingOperation) throws {
        if let permit { try permit.mutate { try pending.save(request) } }
        else { try pending.save(request) }
    }

    private func clearPending() throws {
        if let permit { try permit.mutate { try pending.clear() } }
        else { try pending.clear() }
    }

    private func retireHeld(_ request: SyncPendingOperation) throws {
        let retire = { try self.pending.retainHeld(request); try self.pending.clear() }
        if let permit { try permit.mutate(retire) }
        else { try retire() }
    }
}
