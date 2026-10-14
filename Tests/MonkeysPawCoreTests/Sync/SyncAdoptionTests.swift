import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncAdoptionTests: XCTestCase {
    private let id = SyncScanTestSupport.id
    private let other = SyncScanTestSupport.other
    private let fresh = SyncScanTestSupport.fresh
    private let date = Date(timeIntervalSince1970: 1_791_925_200)

    func testCopiedIDAdoptsExactRepresentationAndFullHashWithoutUpload() throws {
        let rig = try SyncApplyTestRig()
        let original = SyncScanTestSupport.bytes(extra: "# local comment\n")
        try rig.files.write(original, at: "a.md")
        let remote = try remote(rig, bytes: SyncScanTestSupport.bytes(extra: "# server comment\n"))
        let snapshot = try SyncScanTestSupport.scan(rig).snapshot
        let decision = try SyncAdoption.match(remote, local: snapshot, groups: [:])
        guard case .adopt = decision else { return XCTFail("Representation-only equality should adopt") }
        let plan = try application(decision, rig, snapshot)
        XCTAssertNil(plan.nextState.databaseID)
        XCTAssertTrue(plan.nextState.cursors.isEmpty)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), remote.bytes)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.canonicalHash, SyncHash(bytes: remote.bytes))
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.rev, remote.rev)
        let scan = try SyncScanTestSupport.scan(rig)
        XCTAssertNil(scan.preparation)
        XCTAssertTrue(scan.changes.isEmpty)
    }

    func testIdlessAndDifferentIDAdoptWithHistoryUsageValuesAndProvenanceMigration() throws {
        for localID: ULID? in [nil, other] {
            let rig = try SyncApplyTestRig()
            let bytes = SyncScanTestSupport.bytes(id: localID, extra: "# git copy\n")
            try rig.files.write(bytes, at: "a.md")
            let original = PromptIdentity(path: "a.md", id: localID)
            _ = try HistoryStore(files: rig.data).snapshot(bytes, for: original, at: date)
            let provenance = PromptProvenance(timestamp: date, providerHost: "example.test", model: "test", usage: nil)
            try HistoryStore(files: rig.data).setHeadProvenance(provenance, for: original, bytes: bytes)
            try rig.usage.recordUse(identity: original)
            try rig.values.record(identity: original, values: ["field": "remembered"])
            let remote = try remote(rig)
            let snapshot = try SyncScanTestSupport.scan(rig).snapshot
            let decision = try SyncAdoption.match(remote, local: snapshot, groups: [:])
            guard case .adopt(_, let source) = decision else { return XCTFail("Expected B5 path adoption") }
            XCTAssertEqual(try source.identity, original)
            let plan = try application(decision, rig, snapshot)
            XCTAssertEqual(try rig.journal.apply(plan), .committed)
            let destination = PromptIdentity.assigned(id)
            XCTAssertEqual(try rig.files.read(at: "a.md"), remote.bytes)
            XCTAssertEqual(try rig.library.history(for: destination).count, 1)
            XCTAssertTrue(try rig.library.history(for: original).isEmpty)
            XCTAssertEqual(try rig.usage.useEvents(for: destination).count, 1)
            XCTAssertTrue(try rig.usage.useEvents(for: original).isEmpty)
            XCTAssertEqual(try rig.values.rememberedValues(for: destination), ["field": "remembered"])
            XCTAssertTrue(try rig.values.rememberedValues(for: original).isEmpty)
            XCTAssertEqual(try HistoryStore(files: rig.data).headProvenance(for: destination, bytes: remote.bytes), provenance)
            XCTAssertNil(rig.states.snapshot.value?.prompts[original])
            XCTAssertEqual(rig.states.snapshot.value?.prompts[destination]?.canonicalHash, SyncHash(bytes: remote.bytes))
            XCTAssertTrue(try SyncScanTestSupport.scan(rig).changes.isEmpty)
        }
    }

    func testPlainIdlessBodyMatchesIDOnlyServerAndPreservesFrontMatterBoundary() throws {
        let rig = try SyncApplyTestRig()
        let plain = Data("Plain body\r\n".utf8)
        try rig.files.write(plain, at: "a.md")
        let bytes = Data(("---\nid: '\(id.rawValue)'\n---\nPlain body\r\n").utf8)
        let head = try remote(rig, bytes: bytes)
        let snapshot = try SyncScanTestSupport.scan(rig).snapshot
        guard case .adopt = try SyncAdoption.match(head, local: snapshot, groups: [:]) else { return XCTFail("Id-only header") }
        try rig.files.write(Data("---\n---\n---\ntitle: Exact\n---\nBody\r\n".utf8), at: "a.md")
        let boundary = try SyncScanTestSupport.scan(rig).snapshot
        guard case .clash = try SyncAdoption.match(remote(rig), local: boundary, groups: [:]) else {
            return XCTFail("Body text cannot become metadata")
        }
    }

    func testDirtyIDMatchPreservesLocalThroughY6BeforeServerInstallation() throws {
        let rig = try SyncApplyTestRig()
        let losing = SyncScanTestSupport.bytes("Local changes\r\n")
        try rig.files.write(losing, at: "a.md")
        let snapshot = try SyncScanTestSupport.scan(rig).snapshot
        let head = try remote(rig, bytes: SyncScanTestSupport.bytes("Server changes\n"))
        let decision = try SyncAdoption.match(head, local: snapshot, groups: [:])
        guard case .conflict = decision else { return XCTFail("Dirty first-sync ID match") }
        let plan = try application(decision, rig, snapshot)
        XCTAssertEqual(plan.edits.map(\.kind), [.rescue, .adopt])
        let copy = plan.edits[0]
        XCTAssertEqual(copy.retainedBytes, losing)
        XCTAssertEqual(copy.copyOrigin, .conflictOf(id))
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), head.bytes)
        XCTAssertEqual(try SyncConflictMetadata.origin(in: XCTUnwrap(copy.bytes), filename: "Copy.md"), .conflictOf(id))
        XCTAssertEqual(PromptCodec.parseFile(try rig.files.read(at: copy.path), filename: "Copy.md").body, "Local changes\r\n")
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(fresh)]?.rev, 0)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.canonicalHash, head.hash)
        XCTAssertNil(rig.states.snapshot.value?.databaseID)
    }

    func testIdentityMatchWinsOverEqualPathOccupantAndCrossScopeLocations() throws {
        let rig = try SyncApplyTestRig()
        try SyncScanTestSupport.installState(rig, groups: SyncScanTestSupport.groups())
        try rig.files.write(SyncScanTestSupport.bytes("Original"), at: "Groups/Team/elsewhere.md")
        try rig.files.write(SyncScanTestSupport.bytes("Server", id: other), at: "a.md")
        var snapshot = try SyncScanTestSupport.scan(rig).snapshot
        let head = try remote(rig, bytes: SyncScanTestSupport.bytes("Server"))
        guard case .clash(_, let occupant) = try SyncAdoption.match(head, local: snapshot, groups: SyncScanTestSupport.groups()) else {
            return XCTFail("An unrelated occupant must relocate before the ID match installs")
        }
        XCTAssertEqual(occupant.path, "a.md")
        try rig.files.delete(at: "a.md")
        snapshot = try SyncScanTestSupport.scan(rig).snapshot
        let decision = try SyncAdoption.match(head, local: snapshot, groups: SyncScanTestSupport.groups())
        guard case .conflict(_, let source) = decision else { return XCTFail("ID first across scope") }
        XCTAssertEqual(source.path, "Groups/Team/elsewhere.md")
        let plan = try application(decision, rig, snapshot, groups: SyncScanTestSupport.groups())
        XCTAssertTrue(plan.edits[0].path.hasPrefix("Conflicts/Team/"))
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertNil(try rig.files.stamp(at: "Groups/Team/elsewhere.md"))
        XCTAssertEqual(try rig.files.read(at: "a.md"), head.bytes)
    }

    func testAlternativeIDRequiresSameScopePathKeyAndAllNeutralContent() throws {
        let rig = try SyncApplyTestRig()
        try SyncScanTestSupport.installState(rig, groups: SyncScanTestSupport.groups())
        let equal = SyncScanTestSupport.bytes(id: other)
        try rig.files.write(SyncScanTestSupport.bytes(id: fresh), at: "elsewhere.md")
        try rig.files.write(equal, at: "Groups/Team/a.md")
        let snapshot = try SyncScanTestSupport.scan(rig).snapshot
        guard case .unmatched = try SyncAdoption.match(remote(rig), local: snapshot, groups: SyncScanTestSupport.groups()) else {
            return XCTFail("Body equality at another scope/path is insufficient")
        }
        try rig.files.delete(at: "elsewhere.md")
        try rig.files.delete(at: "Groups/Team/a.md")
        for extra in ["favorite: true\n", "private: true\n", "x-extra: value\n", "description: ''\n"] {
            try rig.files.write(SyncScanTestSupport.bytes(id: other, extra: extra), at: "a.md")
            let local = try SyncScanTestSupport.scan(rig).snapshot
            guard case .clash = try SyncAdoption.match(remote(rig), local: local, groups: SyncScanTestSupport.groups()) else {
                return XCTFail("Private personal/unknown/optional metadata matters")
            }
        }
    }

    func testCaseFoldedAdoptionMigratesKeysAndChecksBothIncarnations() throws {
        let rig = try SyncApplyTestRig()
        let bytes = SyncScanTestSupport.bytes(id: other)
        try rig.files.write(bytes, at: "Straße.md")
        try rig.values.record(identity: .assigned(other), values: ["field": "remembered"])
        let snapshot = try SyncScanTestSupport.scan(rig).snapshot
        let head = try remote(rig, path: "STRASSE.md")
        let plan = try application(SyncAdoption.match(head, local: snapshot, groups: [:]), rig, snapshot)
        XCTAssertEqual(plan.edits.map(\.kind), [.adopt, .trash])
        XCTAssertEqual(plan.edits[0].adoptingSource?.bytes, bytes)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertNil(try rig.files.stamp(at: "Straße.md"))
        XCTAssertEqual(try rig.files.read(at: "STRASSE.md"), head.bytes)
        XCTAssertEqual(try rig.values.rememberedValues(for: .assigned(id)), ["field": "remembered"])

        let raced = try SyncApplyTestRig()
        try raced.files.write(bytes, at: "Straße.md")
        let before = try SyncScanTestSupport.scan(raced).snapshot
        let remote = try self.remote(raced, path: "STRASSE.md")
        let stale = try application(SyncAdoption.match(remote, local: before, groups: [:]), raced, before)
        let latest = SyncScanTestSupport.bytes("New external edit", id: other)
        try raced.files.write(latest, at: "Straße.md")
        XCTAssertEqual(try raced.journal.apply(stale), .replanAsConflict(operationID: stale.edits[0].id))
        XCTAssertEqual(try raced.files.read(at: "Straße.md"), latest)
        XCTAssertNil(try raced.files.stamp(at: "STRASSE.md"))
        XCTAssertNil(raced.states.snapshot.value)
    }

    func testGroupAdoptionIngestsTrueFalseAbsentAndInstallsServerBytesOnce() throws {
        for favorite in ["favorite: true\n", "favorite: false\n", ""] {
            let rig = try SyncApplyTestRig()
            let groups = try SyncScanTestSupport.groups(role: .viewer)
            let bytes = SyncScanTestSupport.bytes(id: other, extra: favorite + "private: false\n")
            try rig.files.write(bytes, at: "Groups/Team/a.md")
            let pending = try SyncPromptState(scope: SyncScanTestSupport.team, path: "a.md", rev: 0)
            try SyncScanTestSupport.installState(rig, groups: groups, prompts: [.assigned(other): pending], favorites: [.assigned(other): true])
            let remote = try self.remote(rig, scope: SyncScanTestSupport.team, groups: groups)
            let snapshot = try SyncScanTestSupport.scan(rig).snapshot
            let decision = try SyncAdoption.match(remote, local: snapshot, groups: groups)
            guard case .adopt = decision else { return XCTFail("Group personal keys are neutral") }
            let plan = try application(decision, rig, snapshot, groups: groups)
            XCTAssertEqual(plan.edits.count, 1)
            XCTAssertEqual(plan.nextState.favorites[.assigned(id)], favorite == "favorite: false\n" ? nil : true)
            XCTAssertNil(plan.nextState.favorites[.assigned(other)])
            let initial = rig.files.writeCount
            XCTAssertEqual(try rig.journal.apply(plan), .committed)
            XCTAssertEqual(rig.files.writeCount, initial + 1)
            XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), remote.bytes)
            XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.canonicalHash, remote.hash)
            XCTAssertEqual(rig.libraryOperations.modes["Groups/Team/a.md"], .readOnly)
            XCTAssertTrue(try SyncScanTestSupport.scan(rig).changes.isEmpty)
        }
    }

    func testCaseFoldedAdoptionReplaysAfterUncertainPublication() throws {
        let rig = try SyncApplyTestRig()
        let bytes = SyncScanTestSupport.bytes(id: other)
        try rig.files.write(bytes, at: "Straße.md")
        try rig.values.record(identity: .assigned(other), values: ["field": "remembered"])
        let snapshot = try SyncScanTestSupport.scan(rig).snapshot
        let head = try remote(rig, path: "STRASSE.md")
        let plan = try application(SyncAdoption.match(head, local: snapshot, groups: [:]), rig, snapshot)
        rig.libraryOperations.failFlushNumber = 1
        XCTAssertThrowsError(try rig.journal.apply(plan))
        XCTAssertNil(rig.states.snapshot.value)
        XCTAssertEqual(try rig.files.read(at: "Straße.md"), bytes)
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.files.read(at: "STRASSE.md"), head.bytes)
        XCTAssertNil(try restarted.files.stamp(at: "Straße.md"))
        XCTAssertEqual(try restarted.values.rememberedValues(for: .assigned(id)), ["field": "remembered"])
        XCTAssertTrue(try restarted.values.rememberedValues(for: .assigned(other)).isEmpty)
        XCTAssertEqual(restarted.states.snapshot.value?.prompts[.assigned(id)]?.canonicalHash, head.hash)
    }

    func testPathTakenAdoptsOnlySentAndFreshEqualityAndPreservesInFlightEdits() throws {
        let rig = try SyncApplyTestRig()
        let sent = SyncScanTestSupport.bytes(id: other)
        try rig.files.write(sent, at: "a.md")
        let intent = try SyncConflictIntent(id: other, operation: .put, baseRev: 0,
            scope: SyncScanTestSupport.personal, path: "a.md", sentBytes: sent, inputBytes: sent, accessGeneration: 0)
        let head = try remote(rig)
        let existing = SyncAPI.ExistingPrompt(id: id.rawValue, rev: head.rev, content: String(decoding: head.bytes, as: UTF8.self))
        let snapshot = try SyncScanTestSupport.scan(rig).snapshot
        guard case .adopt = try SyncAdoption.pathTaken(existing, intent: intent, local: snapshot, groups: [:]) else {
            return XCTFail("Equal create should converge")
        }
        let latest = SyncScanTestSupport.bytes("Typed during HTTP", id: other)
        try rig.files.write(latest, at: "a.md")
        let changed = try SyncScanTestSupport.scan(rig).snapshot
        let decision = try SyncAdoption.pathTaken(existing, intent: intent, local: changed, groups: [:])
        guard case .clash = decision else { return XCTFail("Latest content cannot be acknowledged as the sent content") }
        XCTAssertThrowsError(try application(decision, rig, changed))
        XCTAssertEqual(try rig.files.read(at: "a.md"), latest)
        // Replacement and rename during HTTP require another scan, not ID adoption.
        try rig.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        guard case .replan = try SyncAdoption.pathTaken(existing, intent: intent,
            local: SyncScanTestSupport.scan(rig).snapshot, groups: [:]) else { return XCTFail("Replaced ID") }
        try rig.files.write(sent, at: "moved.md")
        guard case .replan = try SyncAdoption.pathTaken(existing, intent: intent,
            local: SyncScanTestSupport.scan(rig).snapshot, groups: [:]) else { return XCTFail("Moved during request") }
    }

    func testFreshReadBeforePublicationPreventsLosingPostPlanEdit() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.write(SyncScanTestSupport.bytes(id: other), at: "a.md")
        let snapshot = try SyncScanTestSupport.scan(rig).snapshot
        let decision = try SyncAdoption.match(remote(rig), local: snapshot, groups: [:])
        let plan = try application(decision, rig, snapshot)
        let latest = SyncScanTestSupport.bytes("Changed after planning", id: other)
        try rig.files.write(latest, at: "a.md")
        XCTAssertEqual(try rig.journal.apply(plan), .replanAsConflict(operationID: plan.edits[0].id))
        XCTAssertEqual(try rig.files.read(at: "a.md"), latest)
        XCTAssertNil(rig.states.snapshot.value)
        XCTAssertNotNil(rig.journal.pending)
    }

    func testAccountHoldsBlockBothIDAndAlternativeIDAdoption() throws {
        for localID: ULID? in [id, other, nil] {
            let rig = try SyncApplyTestRig()
            let bytes = SyncScanTestSupport.bytes(id: localID)
            try rig.files.write(bytes, at: "a.md")
            let ownership = try SyncLibraryBinding(root: rig.binding.root, owner: rig.binding.account, holds: [
                SyncHeldPrompt(identity: PromptIdentity(path: "a.md", id: localID), path: "a.md",
                    sourceAccount: SyncTestValues.account(userID: SyncTestValues.otherUser), contentHash: SyncHash(bytes: bytes))
            ])
            let snapshot = try SyncScanTestSupport.scan(rig, ownership: ownership, ids: []).snapshot
            let decision = try SyncAdoption.match(remote(rig), local: snapshot, groups: [:])
            guard case .held("a.md") = decision else { return XCTFail("Prior account cannot be adopted") }
            XCTAssertThrowsError(try application(decision, rig, snapshot))
            XCTAssertEqual(try rig.files.read(at: "a.md"), bytes)
            XCTAssertNil(rig.states.snapshot.value)
        }
    }

    func testMalformedAndFutureTargetsNeverAdoptOrInstallOverRawBytes() throws {
        for bytes in [Data("---\ntitle: [\n---\nRaw".utf8), SyncScanTestSupport.bytes(extra: "format: 999\n"), Data([0xFF])] {
            let rig = try SyncApplyTestRig()
            try rig.files.write(bytes, at: "a.md")
            let snapshot = try SyncScanTestSupport.scan(rig).snapshot
            let decision = try SyncAdoption.match(remote(rig), local: snapshot, groups: [:])
            guard case .held = decision else { return XCTFail("Raw file stays held") }
            XCTAssertThrowsError(try application(decision, rig, snapshot))
            XCTAssertEqual(try rig.files.read(at: "a.md"), bytes)
        }
    }

    func testOrphanRescueIsRequiredBeforeAdoptionAndForeignScopeIsRejected() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.write(SyncScanTestSupport.bytes(), at: "Groups/Unknown/a.md")
        try rig.files.write(SyncScanTestSupport.bytes(id: other), at: "a.md")
        let snapshot = try SyncScanTestSupport.scan(rig).snapshot
        XCTAssertThrowsError(try SyncAdoption.match(remote(rig), local: snapshot, groups: [:])) {
            XCTAssertEqual($0 as? SyncReconciliationError, .requiresPolicy)
        }
        let foreign = try remote(rig, scope: .user(SyncTestValues.otherUser))
        XCTAssertThrowsError(try SyncAdoption.match(foreign, local: snapshot, groups: [:])) { XCTAssertEqual($0 as? SyncError, .bindingMismatch) }
    }

    func testIgnoredRemotePathRecordsVisibilityWithoutAcknowledgingOrRetiring() throws {
        let rig = try SyncApplyTestRig()
        let bytes = SyncScanTestSupport.bytes()
        try rig.files.write(bytes, at: "a.md")
        try SyncScanTestSupport.installState(rig, prompts: [.assigned(id): SyncScanTestSupport.record(bytes)], database: SyncTestValues.uuid)
        try rig.states.update(for: rig.binding) { $0.cursors[SyncScanTestSupport.personal] = "old opaque cursor" }
        let old = try XCTUnwrap(rig.states.load(for: rig.binding))
        let head = try remote(rig, path: "_remote.md")
        let snapshot = try SyncScanTestSupport.scan(rig).snapshot
        guard case .localVisibility = try SyncAdoption.match(head, local: snapshot, groups: [:]) else {
            return XCTFail("A safe excluded server path is a typed visibility error")
        }
        let plan = try SyncAdoption.localVisibility(head, state: old, binding: rig.binding, groups: [:])
        XCTAssertTrue(plan.edits.isEmpty)
        XCTAssertEqual(plan.nextState.databaseID, old.databaseID)
        XCTAssertEqual(plan.nextState.cursors, old.cursors)
        XCTAssertEqual(plan.nextState.prompts[.assigned(id)]?.rev, old.prompts[.assigned(id)]?.rev)
        XCTAssertEqual(plan.nextState.prompts[.assigned(id)]?.canonicalHash, old.prompts[.assigned(id)]?.canonicalHash)
        XCTAssertEqual(plan.nextState.prompts[.assigned(id)]?.lastError?.code, .localVisibility)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), bytes)
        XCTAssertNil(try rig.files.stamp(at: "_remote.md"))
    }

    func testAdoptionThenReconciliationCommitsCursorWithoutRepresentationUpload() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.write(SyncScanTestSupport.bytes(id: other, extra: "# copied\n"), at: "a.md")
        let head = try remote(rig)
        let scope = SyncAPI.SyncScope(identity: .user(userID: SyncTestValues.user.rawValue), mode: .snapshot,
            head: 10, cursor: "opaque snapshot head", hasMore: false, items: [
                .upsert(seq: 10, prompt: .init(id: id.rawValue, rev: head.rev, path: "a.md", content: String(decoding: head.bytes, as: UTF8.self)))
            ])
        let staging = SyncPullStaging(files: MemoryFileStore())
        try staging.append(.init(databaseID: SyncTestValues.uuid.uuidString.lowercased(), scopes: [scope], removed: []))
        let pull = SyncCollectedPull(databaseID: SyncTestValues.uuid,
            scopes: [SyncScanTestSupport.personal: SyncCollectedScope(page: scope, snapshotHead: scope.head, firstPage: 0)], removed: [], staging: staging)
        defer { try? pull.discard() }
        let snapshot = try SyncScanTestSupport.scan(rig).snapshot
        let first = try SyncReconciler.plan(pull, state: nil, local: snapshot)
        guard case .adoption = try XCTUnwrap(first.operations.first) else { return XCTFail("Expected Y5 seam") }
        let adopt = try application(SyncAdoption.match(head, local: snapshot, groups: [:]), rig, snapshot)
        XCTAssertEqual(try rig.journal.apply(adopt), .committed)
        XCTAssertNil(rig.states.snapshot.value?.databaseID)
        XCTAssertTrue(try XCTUnwrap(rig.states.snapshot.value).cursors.isEmpty)
        let scan = try SyncScanTestSupport.scan(rig)
        let final = try SyncReconciler.plan(pull, state: rig.states.load(for: rig.binding), local: scan.snapshot)
        XCTAssertTrue(final.operations.isEmpty)
        XCTAssertEqual(try SyncReconciler.apply(final, mutations: rig.mutations, journal: rig.journal), .committed)
        XCTAssertEqual(rig.states.snapshot.value?.databaseID, pull.databaseID)
        XCTAssertEqual(rig.states.snapshot.value?.cursors, pull.cursors)
        XCTAssertTrue(try SyncScanTestSupport.scan(rig).changes.isEmpty)
    }

    private func remote(_ rig: SyncApplyTestRig, bytes: Data? = nil, path: RelativePath = "a.md",
                        scope: SyncScopeKey = SyncScanTestSupport.personal,
                        groups: [ULID: SyncGroupState] = [:]) throws -> SyncReconciliationRemote {
        let bytes = try SyncLocalScanner.canonical(bytes ?? SyncScanTestSupport.bytes(), path: path, scope: scope).bytes
        let mode: SyncFileMode
        if case .group(let group) = scope, groups[group]?.role == .viewer { mode = .readOnly }
        else { mode = .normal }
        return try SyncReconciliationRemote(id: id, scope: scope, path: path,
            libraryPath: SyncLocalScanner.rooted(path, scope: scope, groups: groups), rev: 7,
            bytes: bytes, hash: SyncHash(bytes: bytes), mode: mode)
    }

    private func application(_ decision: SyncAdoptionDecision, _ rig: SyncApplyTestRig,
                             _ snapshot: SyncReconciliationSnapshot, groups: [ULID: SyncGroupState] = [:]) throws -> SyncApplyPlan {
        try SyncAdoption.application(decision, state: rig.states.load(for: rig.binding), local: snapshot,
            groups: groups, device: "Device", at: date, freshID: { self.fresh }, mutations: rig.mutations)
    }
}
