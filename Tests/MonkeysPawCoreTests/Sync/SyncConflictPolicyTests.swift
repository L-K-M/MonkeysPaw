import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncConflictPolicyTests: XCTestCase {
    private let id = SyncTestValues.personalPrompt
    private let fresh = SyncTestValues.groupPrompt
    private let user = SyncTestValues.user
    private var personal: SyncScopeKey { .user(user) }
    private var team: SyncScopeKey { .group(SyncTestValues.group) }
    private let date = Date(timeIntervalSince1970: 1_791_925_200)

    func testEditEditAndEditDeleteKeepLocalBytesPrivately() throws {
        let rig = try SyncApplyTestRig()
        let local = try file(rig, body: "Local\r\n")
        let intent = try request()
        let outcome = try resolve(.conflict(head: head("Server", scope: .group(groupID: SyncTestValues.group.rawValue), path: "New.md")),
                                  intent, local: local)
        guard case .serverWins(let remote, let losing) = outcome else { return XCTFail("Expected server win") }
        XCTAssertEqual(remote.scope, team)
        XCTAssertEqual(remote.path, "New.md")
        XCTAssertEqual(losing?.bytes, local.bytes)
        let copy = try makeCopy(local, rig)
        XCTAssertEqual(copy.edit.copyID, fresh.rawValue)
        XCTAssertEqual(copy.edit.retainedBytes, local.bytes)
        XCTAssertEqual(copy.origin, .conflictOf(id))
        XCTAssertEqual(try SyncConflictMetadata.origin(in: XCTUnwrap(copy.edit.bytes), filename: "Copy.md"), .conflictOf(id))
        XCTAssertTrue(copy.edit.path.hasPrefix("Conflicts/Personal/"))
        guard case .remoteDeleted(let saved) = try resolve(.deleted, intent, local: local) else {
            return XCTFail("Expected edit/delete rescue")
        }
        XCTAssertEqual(saved?.bytes, local.bytes)
    }

    func testLocalDeleteAgainstRemoteEditRestoresHeadWithoutCopy() throws {
        let intent = try request(operation: .delete)
        guard case .serverWins(let remote, let local) = try resolve(.conflict(head: head("Remote edit")), intent) else {
            return XCTFail("Expected restoration")
        }
        XCTAssertEqual(remote.bytes, bytes("Remote edit"))
        XCTAssertNil(local)
    }

    func testMoveConflictUsesHeadOwnershipButPathTakenRenamesIntendedDestination() throws {
        let intent = try request(operation: .move, scope: team, path: "Destination.md")
        let rig = try SyncApplyTestRig()
        let local = try file(rig, body: "Local move and edit")
        guard case .serverWins(let remote, _) = try resolve(.conflict(head: head("Elsewhere", path: "Actual.md")), intent, local: local) else {
            return XCTFail("Expected authoritative head")
        }
        XCTAssertEqual(remote.scope, personal)
        XCTAssertEqual(remote.path, "Actual.md")
        // Even nonsensical unrelated content cannot be used as original ownership.
        let error = SyncHTTPClientError.pathTaken(existing: .init(id: fresh.rawValue, rev: 1, content: "Unrelated"))
        guard case .clashRename(let path) = try resolve(error, intent, local: local, occupied: ["DESTINATION (2).md"]) else {
            return XCTFail("Expected destination rename")
        }
        XCTAssertEqual(path, "Destination (3).md")
        let occupied = (2...20).map { RelativePath("Destination (\($0)).md") }
        guard case .fileError(let failure) = try resolve(error, intent, local: local, occupied: occupied) else {
            return XCTFail("Expected bounded clash error")
        }
        XCTAssertEqual(failure.code, .pathClash)
    }

    func testCreatePathTakenAdoptsOnlyIdentityNeutralEquality() throws {
        let intent = try request(base: 0, body: "Sent")
        let equal = SyncHTTPClientError.pathTaken(existing: .init(id: fresh.rawValue, rev: 4,
            content: String(decoding: bytes("Sent", id: fresh), as: UTF8.self)))
        guard case .adoptExisting(let remote) = try resolve(equal, intent) else { return XCTFail("Expected adoption") }
        XCTAssertEqual(remote.id, fresh)
        XCTAssertEqual(remote.scope, personal)
        let unequal = SyncHTTPClientError.pathTaken(existing: .init(id: fresh.rawValue, rev: 4,
            content: String(decoding: bytes("Different", id: fresh), as: UTF8.self)))
        guard case .clashRename(let path) = try resolve(unequal, intent) else { return XCTFail("Expected rename") }
        XCTAssertEqual(path, "a (2).md")
    }

    func testLostCreateEditAndMoveAcknowledgementsCompareExactSentFacts() throws {
        for operation in [SyncOperation.put, .move] {
            for base: Int64 in operation == .put ? [0, 3] : [3] {
                let scope = operation == .move ? team : personal
                let intent = try request(operation: operation, base: base, scope: scope, body: "Sent")
                let rig = try SyncApplyTestRig()
                let newer = try file(rig, body: "Edited while request was in flight")
                let envelope = SyncAPI.ConflictHead(rev: base + 1,
                    scope: operation == .move ? .group(groupID: SyncTestValues.group.rawValue) : .user,
                    path: "a.md", content: String(decoding: try XCTUnwrap(intent.sentBytes), as: UTF8.self))
                guard case .acknowledged(let remote) = try resolve(.conflict(head: envelope), intent, local: newer) else {
                    return XCTFail("Expected lost acknowledgement adoption")
                }
                XCTAssertEqual(remote.hash, intent.sentHash)
                XCTAssertNotEqual(remote.bytes, newer.bytes)
                XCTAssertEqual(try rig.files.read(at: "a.md"), newer.bytes)
                // A head equal to a *later* re-read is a real conflict.
                let changedHead = head("Edited while request was in flight", rev: base + 2)
                guard case .serverWins = try resolve(.conflict(head: changedHead), intent, local: newer) else {
                    return XCTFail("A newer read must not count as sent")
                }
            }
        }
        let sent = try request(body: "Sent")
        for envelope in [head("Sent", path: "Renamed.md"), head("Sent", scope: .group(groupID: SyncTestValues.group.rawValue))] {
            guard case .serverWins = try resolve(.conflict(head: envelope), sent) else {
                return XCTFail("Scope and path must also match")
            }
        }
    }

    func testLostMoveAcknowledgementRequiresKnownCanonicalMovedBaseline() throws {
        let intent = try SyncConflictIntent(id: id, operation: .move, baseRev: 1, scope: team, path: "a.md",
            sentBytes: nil, inputBytes: bytes("Local accompanying edit"), accessGeneration: 0)
        let canonical = try CanonicalForm.group(bytes("Server baseline"), filename: "a.md").bytes
        let envelope = SyncAPI.ConflictHead(rev: 2, scope: .group(groupID: SyncTestValues.group.rawValue), path: "a.md",
                                            content: String(decoding: canonical, as: UTF8.self))
        guard case .serverWins = try resolve(.conflict(head: envelope), intent) else { return XCTFail("Unknown baseline cannot prove success") }
    }

    func testLostGroupAcknowledgementUsesCanonicalSentBytesAndPrivateBytesRemainExact() throws {
        let raw = bytes("Sent", extra: "favorite: true\nprivate: true\n")
        let canonical = try CanonicalForm.group(raw, filename: "a.md").bytes
        let intent = try SyncConflictIntent(id: id, operation: .put, baseRev: 1, scope: team, path: "a.md",
            sentBytes: canonical, inputBytes: raw, accessGeneration: 0)
        let envelope = SyncAPI.ConflictHead(rev: 2, scope: .group(groupID: SyncTestValues.group.rawValue), path: "a.md",
                                            content: String(decoding: canonical, as: UTF8.self))
        guard case .acknowledged = try resolve(.conflict(head: envelope), intent) else { return XCTFail("Canonical group acknowledgement") }
        XCTAssertEqual(intent.fingerprint.contentHash, SyncHash(bytes: raw))
        XCTAssertNotEqual(intent.fingerprint.contentHash, intent.sentHash)
        let privateIntent = try request()
        let sameContentDifferentBytes = head("Sent", rev: 2)
        let withComment = SyncAPI.ConflictHead(rev: 2, scope: .user, path: "a.md",
            content: sameContentDifferentBytes.content.replacingOccurrences(of: "title: Exact", with: "# another representation\ntitle: Exact"))
        guard case .serverWins = try resolve(.conflict(head: withComment), privateIntent) else {
            return XCTFail("Private acknowledgement compares every byte")
        }
    }

    func testDelete404And410AreSuccessWhileOtherOperationsRemainDistinct() throws {
        for error in [SyncHTTPClientError.notFound, .deleted] {
            guard case .deleteSucceeded = try resolve(error, request(operation: .delete)) else { return XCTFail("Expected delete success") }
        }
        for operation in [SyncOperation.put, .move] {
            let intent = try request(operation: operation)
            guard case .fileError(let failure) = try resolve(.notFound, intent) else { return XCTFail("404 is an input error") }
            XCTAssertEqual(failure.code, .notFound)
            guard case .remoteDeleted = try resolve(.deleted, intent) else { return XCTFail("410 requires rescue") }
        }
        guard case .fileError = try resolve(.notFound, request(base: 0)) else { return XCTFail("A create 404 is not success") }
    }

    func testForbiddenCreatesUpdatesMovesAndDeletesRequireAccessibleRecordedHead() throws {
        let rig = try SyncApplyTestRig()
        let local = try file(rig, body: "Keep private")
        let recorded = try SyncPromptState(scope: personal, path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: bytes("Old")))
        let accessible = prompt("Current")
        for operation in [SyncOperation.put, .move, .delete] {
            let intent = try request(operation: operation, scope: operation == .move ? team : personal,
                                     path: operation == .move ? "New.md" : "a.md")
            for available in [false, true] {
                let outcome = try resolve(.forbidden, intent, local: operation == .delete ? nil : local,
                    recorded: recorded, accessible: available ? accessible : nil)
                guard case .denied(let restored, let saved, let error) = outcome else { return XCTFail("Expected denial") }
                XCTAssertEqual(restored?.bytes, available ? bytes("Current") : nil)
                XCTAssertEqual(saved?.bytes, operation == .delete ? nil : local.bytes)
                XCTAssertEqual(error.code, .forbidden)
                XCTAssertFalse(SyncConflictPolicy.shouldAttempt(intent.fingerprint, lastError: error))
            }
        }
        for head in [accessible, prompt("Wrong ID", id: fresh), prompt("New ownership", scope: .group(groupID: SyncTestValues.group.rawValue)), prompt("Moved", path: "Elsewhere.md")] {
            let create = try request(base: 0)
            guard case .denied(let restore, let saved, _) = try resolve(.forbidden, create, local: local, recorded: recorded, accessible: head) else {
                return XCTFail("Expected create rescue")
            }
            XCTAssertNil(restore)
            XCTAssertEqual(saved?.bytes, local.bytes)
        }
        guard case .denied(let unavailable, _, _) = try resolve(.forbidden, request(), local: local, recorded: recorded,
                                                               accessible: prompt("Wrong ID", id: fresh)) else { return XCTFail() }
        XCTAssertNil(unavailable)
    }

    func testValidationFingerprintPersistsAndOnlyRepairedInputRetries() throws {
        let rig = try SyncApplyTestRig()
        let intent = try request()
        let envelope = SyncHTTPClientError.validation(issues: [.init(code: "path.too_long", severity: .error)])
        guard case .fileError(let error) = try resolve(envelope, intent) else { return XCTFail("Expected per-file error") }
        XCTAssertEqual(error.code, .path(.pathTooLong))
        let pending = try SyncPromptState(scope: personal, path: "a.md", rev: 0, lastError: error)
        try rig.states.update(for: rig.binding) { $0 = try SyncState(binding: rig.binding, prompts: [.assigned(id): pending]) }
        let restarted = SyncStateStore(files: rig.data, operations: rig.dataOperations)
        let saved = try restarted.load(for: rig.binding)?.prompts[.assigned(id)]?.lastError
        XCTAssertFalse(SyncConflictPolicy.shouldAttempt(intent.fingerprint, lastError: saved))
        let changes = [
            try request(body: "Changed"), try request(path: "Fixed.md"), try request(scope: team),
            try request(access: 1), try request(operation: .move)
        ]
        for change in changes { XCTAssertTrue(SyncConflictPolicy.shouldAttempt(change.fingerprint, lastError: saved)) }
        let serialized = String(decoding: try rig.data.read(at: "sync/state.json"), as: UTF8.self)
        XCTAssertFalse(serialized.contains("Sent"))
        XCTAssertThrowsError(try resolve(.validation(issues: [.init(code: "untrusted-error-body", severity: .error)]), intent))
        XCTAssertNil(try resolve(.unauthorized, intent))
        XCTAssertNil(try resolve(.transport(.networkFailure), intent))
    }

    func testForbiddenWithMalformedOrMismatchedAccessibleHeadStillRescues() throws {
        let rig = try SyncApplyTestRig()
        let local = try file(rig, body: "Keep me")
        let recorded = try SyncPromptState(scope: personal, path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: bytes("Old")))
        let badHeads = [
            SyncAPI.Prompt(id: id.rawValue, rev: 2, scope: .user, path: "a.md", content: "---\ntitle: [\n---\nBad"),
            SyncAPI.Prompt(id: id.rawValue, rev: 2, scope: .user, path: "a.md", content: String(decoding: bytes("Wrong ID", id: fresh), as: UTF8.self))
        ]
        for head in badHeads {
            for operation in [SyncOperation.put, .move] {
                guard case .denied(let restore, let saved, _) = try resolve(.forbidden, request(operation: operation),
                    local: local, recorded: recorded, accessible: head) else { return XCTFail("Expected local preservation") }
                XCTAssertNil(restore)
                XCTAssertEqual(saved?.bytes, local.bytes)
            }
        }
    }

    func testBatchCopiesReserveDestinationsAndExcludeOtherLosingCopies() throws {
        let rig = try SyncApplyTestRig()
        let first = try file(rig, body: "Losing version")
        let oldCopy = try makeCopy(first, rig)
        try rig.files.write(try XCTUnwrap(oldCopy.edit.bytes), at: "other/a.md")
        let second = try XCTUnwrap(rig.mutations.read(at: "other/a.md"))
        let old = try SyncState(binding: rig.binding, databaseID: SyncTestValues.uuid, cursors: [personal: "old"],
            prompts: [.assigned(id): SyncPromptState(scope: personal, path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: bytes("Base"))),
                .assigned(fresh): SyncPromptState(scope: personal, path: "other/a.md", rev: 1, canonicalHash: second.hash, origin: .conflictOf(id))])
        try rig.states.update(for: rig.binding) { $0 = old }
        var next = old
        next.prompts = [:]
        next.cursors[personal] = "new"
        let plan = SyncReconciliationPlan(mode: .normal, expectedState: old, nextState: next,
            operations: [.preserve(.init(id: id, reason: .dirtyRemoval, local: first, installation: nil)),
                         .preserve(.init(id: fresh, reason: .dirtyRemoval, local: second, installation: nil))],
            occupiedPaths: ["a.md", "other/a.md"], localIdentities: [.assigned(id), .assigned(fresh)])
        var ids = [SyncTestValues.device, SyncTestValues.otherUser].makeIterator()
        let copies = try SyncConflictPolicy.copies(for: plan, device: "Device", at: date,
            freshID: { try XCTUnwrap(ids.next()) }, existingCopies: [.init(scope: personal, file: second)], mutations: rig.mutations)
        XCTAssertEqual(copies.count, 2)
        XCTAssertTrue(copies.values.allSatisfy { $0.edit.kind == .rescue })
        XCTAssertEqual(Set(copies.values.map { $0.edit.path }).count, 2)
        XCTAssertTrue(copies.values.contains { $0.edit.path.hasSuffix(" (2).md") })
        XCTAssertEqual(try rig.journal.apply(SyncReconciler.application(plan, mutations: rig.mutations, copies: copies)), .committed)
        XCTAssertEqual(try rig.files.listFiles().count, 2)
        XCTAssertEqual(rig.states.snapshot.value?.cursors[personal], "new")
    }

    func testBatchCopiesReserveAnIncomingServerConflictShapedPath() throws {
        let rig = try SyncApplyTestRig()
        let local = try file(rig, body: "Losing")
        let incoming = try SyncNaming.conflict(source: "a.md", groupFolder: nil, device: "Device", at: date, occupiedPaths: [])
        let data = bytes("Ordinary server prompt", id: fresh)
        var plan = try reconciliation(rig, local: local)
        var next = plan.nextState
        next.prompts[.assigned(fresh)] = try SyncPromptState(scope: personal, path: incoming, rev: 1, canonicalHash: SyncHash(bytes: data))
        let remote = SyncReconciliationRemote(id: fresh, scope: personal, path: incoming, libraryPath: incoming,
            rev: 1, bytes: data, hash: SyncHash(bytes: data), mode: .normal)
        plan = SyncReconciliationPlan(mode: plan.mode, expectedState: plan.expectedState, nextState: next,
            operations: plan.operations + [.install(.init(remote: remote, source: nil, target: nil))],
            occupiedPaths: plan.occupiedPaths, localIdentities: plan.localIdentities)
        let copies = try SyncConflictPolicy.copies(for: plan, device: "Device", at: date,
            freshID: { SyncTestValues.device }, mutations: rig.mutations)
        XCTAssertNotEqual(copies["a.md"]?.edit.path, incoming.string)
        XCTAssertEqual(try rig.journal.apply(SyncReconciler.application(plan, mutations: rig.mutations, copies: copies)), .committed)
        XCTAssertEqual(try rig.files.read(at: incoming.string), data)
        XCTAssertEqual(rig.states.snapshot.value?.cursors[personal], "new")
    }

    func testSameMinuteDifferentVersionsGetDistinctCopiesAndSameVersionReusesAfterRename() throws {
        let rig = try SyncApplyTestRig()
        let local = try file(rig, body: "Version one")
        let first = try makeCopy(local, rig)
        XCTAssertEqual(try rig.journal.apply(rig.plan([first.edit])), .committed)
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        let newPath = "Renamed elsewhere.md"
        try restarted.files.move(from: first.edit.path, to: newPath)
        let existing = try XCTUnwrap(restarted.mutations.read(at: RelativePath(newPath)))
        let candidate = SyncConflictCopyCandidate(scope: personal, file: existing)
        let reused = try makeCopy(local, restarted, freshID: SyncTestValues.device, occupied: [RelativePath(newPath)], candidates: [candidate])
        XCTAssertEqual(reused.edit.kind, .apply)
        XCTAssertEqual(reused.edit.path, newPath)
        XCTAssertEqual(reused.edit.transition?.destination, fresh.rawValue)
        let secondLocal = try file(restarted, body: "Version two")
        let second = try makeCopy(secondLocal, restarted, freshID: SyncTestValues.device,
                                  occupied: [RelativePath(first.edit.path)], candidates: [candidate])
        XCTAssertEqual(second.edit.kind, .rescue)
        XCTAssertTrue(second.edit.path.hasSuffix(" (2).md"))
        XCTAssertEqual(second.edit.retainedBytes, secondLocal.bytes)
        // Similar bytes in another account cannot authorize reuse.
        let foreign = SyncConflictCopyCandidate(scope: .user(SyncTestValues.otherUser), file: existing)
        XCTAssertEqual(try makeCopy(local, restarted, freshID: SyncTestValues.device, candidates: [foreign]).edit.kind, .rescue)
    }

    func testAConflictOfAnExistingCopyKeepsRootOriginWithoutSelfReuse() throws {
        let rig = try SyncApplyTestRig()
        let local = try file(rig, body: "Original losing version")
        let first = try makeCopy(local, rig)
        try rig.files.write(try XCTUnwrap(first.edit.bytes), at: "Renamed copy.md")
        let source = try XCTUnwrap(rig.mutations.read(at: "Renamed copy.md"))
        let result = try SyncConflictPolicy.copy(source, origin: .conflictOf(fresh), userID: user,
            device: "Device", at: date, freshID: SyncTestValues.device, occupiedPaths: ["Renamed copy.md"],
            existingCopies: [.init(scope: personal, file: source)], mutations: rig.mutations)
        XCTAssertEqual(result.edit.kind, .rescue)
        XCTAssertEqual(result.origin, .conflictOf(id))
        XCTAssertEqual(try SyncConflictMetadata.origin(in: XCTUnwrap(result.edit.bytes), filename: "Copy.md"), .conflictOf(id))
    }

    func testRescuesOfDistinctSourcesWithEqualBodiesRemainDistinct() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.write(bytes("Same body"), at: "Groups/Team/First.md")
        let firstSource = try XCTUnwrap(rig.mutations.read(at: "Groups/Team/First.md"))
        let first = try SyncConflictPolicy.copy(firstSource, origin: .rescued, userID: user, device: "Device", at: date,
            freshID: SyncTestValues.device, occupiedPaths: ["Groups/Team/First.md"], mutations: rig.mutations)
        try rig.files.write(try XCTUnwrap(first.edit.bytes), at: first.edit.path)
        let existing = try XCTUnwrap(rig.mutations.read(at: RelativePath(first.edit.path)))
        try rig.files.write(bytes("Same body", id: fresh), at: "Groups/Team/Second.md")
        let secondSource = try XCTUnwrap(rig.mutations.read(at: "Groups/Team/Second.md"))
        let second = try SyncConflictPolicy.copy(secondSource, origin: .rescued, userID: user, device: "Device", at: date,
            freshID: SyncTestValues.otherUser, occupiedPaths: [RelativePath(first.edit.path), "Groups/Team/Second.md"],
            existingCopies: [.init(scope: personal, file: existing)], mutations: rig.mutations)
        XCTAssertEqual(second.edit.kind, .rescue)
        XCTAssertEqual(second.edit.copyID, SyncTestValues.otherUser.rawValue)
        XCTAssertNotEqual(second.edit.path, first.edit.path)
        XCTAssertEqual(second.edit.retainedBytes, secondSource.bytes)
    }

    func testReconciliationReusesCopyDurablyBeforeReplacingSource() throws {
        let rig = try SyncApplyTestRig()
        let local = try file(rig, body: "Local losing bytes")
        let first = try makeCopy(local, rig)
        try rig.files.write(try XCTUnwrap(first.edit.bytes), at: "Renamed copy.md")
        let existing = try XCTUnwrap(rig.mutations.read(at: "Renamed copy.md"))
        let copy = try makeCopy(local, rig, freshID: SyncTestValues.device, occupied: ["a.md", "Renamed copy.md"],
                                candidates: [.init(scope: personal, file: existing)])
        let plan = try reconciliation(rig, local: local, existing: existing)
        let application = try SyncReconciler.application(plan, mutations: rig.mutations, copies: ["a.md": copy])
        XCTAssertEqual(application.edits.map(\.kind), [.apply, .apply])
        XCTAssertEqual(try rig.journal.apply(application), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), bytes("Server"))
        XCTAssertEqual(try rig.files.read(at: existing.path), existing.bytes)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(fresh)]?.rev, 4)
        let retained = try rig.data.listFiles().filter { $0.relativePath.hasSuffix(".bin") }
        XCTAssertTrue(try retained.contains { try rig.data.read(at: $0.relativePath) == local.bytes })
    }

    func testRacingEditOfReusedCopyCannotLoseTheOriginalLocalVersion() throws {
        let rig = try SyncApplyTestRig()
        let local = try file(rig, body: "Local losing bytes")
        let first = try makeCopy(local, rig)
        try rig.files.write(try XCTUnwrap(first.edit.bytes), at: "Renamed copy.md")
        let existing = try XCTUnwrap(rig.mutations.read(at: "Renamed copy.md"))
        let copy = try makeCopy(local, rig, candidates: [.init(scope: personal, file: existing)])
        let plan = try reconciliation(rig, local: local, existing: existing)
        let application = try SyncReconciler.application(plan, mutations: rig.mutations, copies: ["a.md": copy])
        let edited = bytes("Edited the preserved copy", id: fresh)
        try rig.files.write(edited, at: existing.path)
        XCTAssertEqual(try rig.journal.apply(application), .replanAsConflict(operationID: copy.edit.id))
        XCTAssertEqual(try rig.files.read(at: "a.md"), local.bytes)
        XCTAssertEqual(try rig.files.read(at: existing.path), edited)
        XCTAssertEqual(rig.states.snapshot.value?.cursors[personal], "old")
    }

    func testReconciliationRejectsStateOriginThatDisagreesWithCopyMarker() throws {
        let rig = try SyncApplyTestRig()
        let local = try file(rig, body: "Losing")
        let valid = try makeCopy(local, rig)
        let forged = SyncReconciliationCopy(edit: valid.edit, origin: .rescued)
        let plan = try reconciliation(rig, local: local)
        XCTAssertThrowsError(try SyncReconciler.application(plan, mutations: rig.mutations, copies: ["a.md": forged])) {
            XCTAssertEqual($0 as? SyncReconciliationError, .requiresPolicy)
        }
    }

    func testReconciliationRejectsTrashEditAsPreservationCopy() throws {
        let rig = try SyncApplyTestRig()
        let local = try file(rig, body: "Losing")
        let plan = try reconciliation(rig, local: local)
        let old = rig.states.snapshot.value
        let edit = try rig.mutations.trash(local)
        try edit.validate()
        let copy = SyncReconciliationCopy(edit: edit, origin: .conflictOf(id))
        let writes = rig.files.writeCount
        XCTAssertThrowsError(try SyncReconciler.apply(plan, mutations: rig.mutations, journal: rig.journal,
            copies: ["a.md": copy])) {
            XCTAssertEqual($0 as? SyncReconciliationError, .requiresPolicy)
        }
        XCTAssertEqual(try rig.files.read(at: "a.md"), local.bytes)
        XCTAssertEqual(rig.files.writeCount, writes)
        XCTAssertTrue(rig.libraryOperations.trashed.isEmpty)
        XCTAssertEqual(rig.states.snapshot.value, old)
        XCTAssertNil(rig.journal.pending)
    }

    func testForensicRescueRetainsRawBytesAndTypedHoldWithoutInjectedText() throws {
        let inputs = [Data([0xff, 0x00, 0xfe]), Data("---\nformat: 2\n---\nFuture".utf8),
                      Data("---\ntitle: [\n---\nMalformed".utf8), bytes("Body", extra: "x-monkeyspaw-rescued: 'true'\n")]
        for raw in inputs {
            let rig = try SyncApplyTestRig()
            try rig.files.write(raw, at: "Groups/Team/a.md")
            let local = try XCTUnwrap(rig.mutations.read(at: "Groups/Team/a.md"))
            let copy = try SyncConflictPolicy.copy(local, origin: .rescued, userID: user, device: "Device", at: date,
                freshID: fresh, occupiedPaths: ["Groups/Team/a.md"], mutations: rig.mutations)
            XCTAssertEqual(copy.edit.bytes, raw)
            XCTAssertEqual(copy.edit.retainedBytes, raw)
            XCTAssertNotNil(copy.edit.heldIssue)
            XCTAssertNil(copy.edit.copyID)
            XCTAssertEqual(try rig.journal.apply(rig.plan([copy.edit])), .committed)
            XCTAssertEqual(try rig.files.read(at: copy.edit.path), raw)
        }
    }

    func testPolicyDiagnosticsRedactInputAndHeadBytes() throws {
        let intent = try request(body: "Content sentinel")
        let outcome = try resolve(.conflict(head: head("Remote sentinel")), intent)
        for value: Any in [intent, try SyncConflictHead(prompt("Remote sentinel"), userID: user), try XCTUnwrap(outcome)] {
            XCTAssertFalse(String(describing: value).contains("sentinel"))
            XCTAssertFalse(String(reflecting: value).contains("sentinel"))
            XCTAssertFalse(String(describing: Mirror(reflecting: value).children.map(\.value)).contains("sentinel"))
        }
    }

    private func bytes(_ body: String, id: ULID? = nil, extra: String = "") -> Data {
        Data(("---\nid: '\((id ?? self.id).rawValue)'\ntitle: Exact\n" + extra + "---\n" + body).utf8)
    }

    private func request(operation: SyncOperation = .put, base: Int64 = 1, scope: SyncScopeKey? = nil,
                         path: RelativePath = "a.md", body: String = "Sent", access: Int64 = 0) throws -> SyncConflictIntent {
        let scope = scope ?? personal
        let raw = bytes(body)
        let sent = try scope.pathScope == .group ? CanonicalForm.group(raw, filename: "a.md").bytes : raw
        return try SyncConflictIntent(id: id, operation: operation, baseRev: base, scope: scope, path: path,
            sentBytes: operation == .delete ? nil : sent, inputBytes: raw, accessGeneration: access)
    }

    private func head(_ body: String, rev: Int64 = 2, scope: SyncAPI.PromptScope = .user, path: String = "a.md") -> SyncAPI.ConflictHead {
        var data = bytes(body)
        if case .group = scope { data = try! CanonicalForm.group(data, filename: "a.md").bytes }
        return .init(rev: rev, scope: scope, path: path, content: String(decoding: data, as: UTF8.self))
    }

    private func prompt(_ body: String, id: ULID? = nil, scope: SyncAPI.PromptScope = .user, path: String = "a.md") -> SyncAPI.Prompt {
        var data = bytes(body, id: id)
        if case .group = scope { data = try! CanonicalForm.group(data, filename: "a.md").bytes }
        return .init(id: (id ?? self.id).rawValue, rev: 2, scope: scope, path: path, content: String(decoding: data, as: UTF8.self))
    }

    private func file(_ rig: SyncApplyTestRig, body: String) throws -> SyncLibraryFile {
        try rig.files.write(bytes(body), at: "a.md")
        return try XCTUnwrap(rig.mutations.read(at: "a.md"))
    }

    private func resolve(_ error: SyncHTTPClientError, _ intent: SyncConflictIntent, local: SyncLibraryFile? = nil,
                         recorded: SyncPromptState? = nil, accessible: SyncAPI.Prompt? = nil,
                         occupied: [RelativePath] = []) throws -> SyncConflictOutcome? {
        try SyncConflictPolicy.resolve(error, intent: intent, userID: user, local: local,
            recorded: recorded, accessibleHead: accessible, occupiedPaths: occupied)
    }

    private func makeCopy(_ file: SyncLibraryFile, _ rig: SyncApplyTestRig, freshID: ULID? = nil,
                          occupied: [RelativePath] = [], candidates: [SyncConflictCopyCandidate] = []) throws -> SyncReconciliationCopy {
        try SyncConflictPolicy.copy(file, origin: .conflictOf(id), userID: user, device: "Device", at: date,
            freshID: freshID ?? fresh, occupiedPaths: occupied, existingCopies: candidates, mutations: rig.mutations)
    }

    private func reconciliation(_ rig: SyncApplyTestRig, local: SyncLibraryFile,
                                existing: SyncLibraryFile? = nil) throws -> SyncReconciliationPlan {
        var records: [PromptIdentity: SyncPromptState] = [.assigned(id): try SyncPromptState(scope: personal,
            path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: bytes("Old")))]
        if let existing {
            records[.assigned(fresh)] = try SyncPromptState(scope: personal, path: RelativePath(existing.path), rev: 4,
                canonicalHash: existing.hash, origin: .conflictOf(id))
        }
        let old = try SyncState(binding: rig.binding, databaseID: SyncTestValues.uuid, cursors: [personal: "old"], prompts: records)
        try rig.states.update(for: rig.binding) { $0 = old }
        var next = old
        next.cursors[personal] = "new"
        next.prompts[.assigned(id)] = try SyncPromptState(scope: personal, path: "a.md", rev: 2, canonicalHash: SyncHash(bytes: bytes("Server")))
        let remote = SyncReconciliationRemote(id: id, scope: personal, path: "a.md", libraryPath: "a.md",
            rev: 2, bytes: bytes("Server"), hash: SyncHash(bytes: bytes("Server")), mode: .normal)
        return SyncReconciliationPlan(mode: .normal, expectedState: old, nextState: next,
            operations: [.preserve(.init(id: id, reason: .dirtyUpsert, local: local,
                                        installation: .init(remote: remote, source: local, target: local)))],
            occupiedPaths: Set(try rig.files.listFiles().map { RelativePath($0.relativePath) }), localIdentities: Set(records.keys))
    }
}
