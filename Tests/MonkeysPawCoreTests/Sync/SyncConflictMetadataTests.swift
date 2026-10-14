import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncConflictMetadataTests: XCTestCase {
    private let original = SyncTestValues.personalPrompt
    private let copy = SyncTestValues.groupPrompt

    func testTypedOriginsAndFalseRescueMarker() throws {
        XCTAssertEqual(try origin("x-monkeyspaw-conflict-of: '\(original.rawValue)'"), .conflictOf(original))
        XCTAssertEqual(try origin("x-monkeyspaw-rescued: true"), .rescued)
        XCTAssertNil(try origin("x-monkeyspaw-rescued: false"))
        XCTAssertNil(try origin("title: Ordinary (conflict Device 2026-10-13 2100)"))
        let group = bytes("x-monkeyspaw-conflict-of: '\(original.rawValue)'")
        XCTAssertNil(try SyncConflictMetadata.origin(in: group, filename: "a.md", scope: .group))
    }

    func testInvalidMarkersCannotClaimAnOrigin() throws {
        let invalid = [
            "x-monkeyspaw-conflict-of: false", "x-monkeyspaw-conflict-of: null",
            "x-monkeyspaw-conflict-of: [bad]", "x-monkeyspaw-conflict-of: invalid",
            "x-monkeyspaw-conflict-of: '\(ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!.rawValue.lowercased())'",
            "x-monkeyspaw-conflict-of: '\(copy.rawValue)'",
            "x-monkeyspaw-rescued: 'true'", "x-monkeyspaw-rescued: 1", "x-monkeyspaw-rescued: null",
            "x-monkeyspaw-conflict-of: '\(original.rawValue)'\nx-monkeyspaw-rescued: true"
        ]
        for header in invalid {
            XCTAssertThrowsError(try origin(header), header) {
                XCTAssertEqual($0 as? SyncConflictMetadataError, .invalidOrigin)
            }
        }
        for malformed in [Data([0xff]), Data("---\nx-monkeyspaw-rescued: true\nx-monkeyspaw-rescued: false\n---\nBody".utf8)] {
            XCTAssertThrowsError(try SyncConflictMetadata.origin(in: malformed, filename: "a.md")) {
                XCTAssertEqual($0 as? SyncConflictMetadataError, .invalidPrompt)
            }
        }
    }

    func testMarkersSurviveNormalCopiesRenamesAndPrivateCanonicalization() throws {
        let marked = try SyncConflictMetadata.settingOrigin(.conflictOf(original),
            in: bytes("favorite: true\nx-custom:\n  nested: [true, 1, '1']", body: "Body\r\n\u{FEFF}Tail\r\n"), filename: "a.md")
        let document = PromptCodec.parseFile(marked, filename: "a.md")
        let draft = try PromptCodec.removingIdentity(from: document)
        let fresh = try PromptCodec.assigningIdentity(SyncTestValues.device, to: draft)
        let copied = Data(try PromptCodec.write(fresh).utf8)
        XCTAssertEqual(try SyncConflictMetadata.origin(in: copied, filename: "Renamed.md"), .conflictOf(original))
        XCTAssertEqual(PromptCodec.parseFile(copied, filename: "Renamed.md").body, document.body)
        XCTAssertEqual(try CanonicalForm.user(copied, filename: "Renamed.md").bytes, copied)
        XCTAssertTrue(String(decoding: copied, as: UTF8.self).contains("x-custom:"))
        XCTAssertEqual(try SyncConflictMetadata.settingOrigin(.conflictOf(original), in: marked, filename: "a.md"), marked)
    }

    func testKeepBothClearsMarkersWithoutChangingBodyOrOtherMetadata() throws {
        for marker in ["x-monkeyspaw-conflict-of: '\(original.rawValue)'", "x-monkeyspaw-rescued: true", "x-monkeyspaw-rescued: false"] {
            let input = bytes(marker + "\nx-extra: 'keep'", body: "Exact\r\n\n")
            let cleared = try SyncConflictMetadata.settingOrigin(nil, in: input, filename: "Copy.md")
            XCTAssertNil(try SyncConflictMetadata.origin(in: cleared, filename: "Copy.md"))
            XCTAssertFalse(String(decoding: cleared, as: UTF8.self).contains("x-monkeyspaw-"))
            XCTAssertEqual(PromptCodec.parseFile(cleared, filename: "Copy.md").body, "Exact\r\n\n")
            XCTAssertTrue(String(decoding: cleared, as: UTF8.self).contains("x-extra: keep"))
        }
    }

    func testPrivatePullMirrorsMarkersAndClearsAnOldOrigin() throws {
        let rig = try SyncApplyTestRig()
        for marker in ["x-monkeyspaw-conflict-of: '\(original.rawValue)'", "x-monkeyspaw-rescued: true", "x-monkeyspaw-rescued: false"] {
            let pull = try collected(bytes(marker))
            defer { try? pull.discard() }
            let old = try SyncState(binding: rig.binding, databaseID: SyncTestValues.uuid,
                cursors: [.user(SyncTestValues.user): "old"], prompts: [.assigned(copy): SyncPromptState(
                    scope: .user(SyncTestValues.user), path: "a.md", rev: 1,
                    canonicalHash: SyncHash(bytes: bytes("title: Old")), origin: .conflictOf(original))])
            let plan = try SyncReconciler.plan(pull, state: old, local: .init(binding: rig.binding, files: []))
            XCTAssertEqual(plan.nextState.prompts[.assigned(copy)]?.origin, try origin(marker))
        }
    }

    func testInvalidMatchingEchoRecordsAnErrorWithoutTrustingItsOrigin() throws {
        let rig = try SyncApplyTestRig()
        let invalid = bytes("x-monkeyspaw-rescued: 'true'")
        let pull = try collected(invalid)
        defer { try? pull.discard() }
        let old = try SyncState(binding: rig.binding, databaseID: SyncTestValues.uuid,
            cursors: [.user(SyncTestValues.user): "old"], prompts: [.assigned(copy): SyncPromptState(
                scope: .user(SyncTestValues.user), path: "a.md", rev: 3, canonicalHash: SyncHash(bytes: invalid))])
        let plan = try SyncReconciler.plan(pull, state: old, local: .init(binding: rig.binding, files: []))
        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertNil(plan.nextState.prompts[.assigned(copy)]?.origin)
        XCTAssertEqual(plan.nextState.prompts[.assigned(copy)]?.lastError?.code, .content(.invalidMetadataType))
    }

    func testInvalidRemoteMarkerInstallsExactBytesWithPerFileError() throws {
        let rig = try SyncApplyTestRig()
        let invalid = bytes("x-monkeyspaw-rescued: 'true'")
        let pull = try collected(invalid)
        defer { try? pull.discard() }
        let old = try SyncState(binding: rig.binding, databaseID: SyncTestValues.uuid, cursors: [.user(SyncTestValues.user): "old"])
        try rig.states.update(for: rig.binding) { $0 = old }
        let plan = try SyncReconciler.plan(pull, state: old, local: .init(binding: rig.binding, files: []))
        let record = try XCTUnwrap(plan.nextState.prompts[.assigned(copy)])
        XCTAssertNil(record.origin)
        XCTAssertEqual(record.lastError?.code, .content(.invalidMetadataType))
        XCTAssertEqual(try rig.journal.apply(SyncReconciler.application(plan, mutations: rig.mutations)), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), invalid)
        XCTAssertEqual(rig.states.snapshot.value?.cursors[.user(SyncTestValues.user)], "new")
    }

    func testRawVisibilityHoldSurvivesRestartAndCannotShadowTheOriginalID() throws {
        let rig = try SyncApplyTestRig()
        let raw = bytes("title: Source", body: "Raw losing version")
        try rig.files.write(raw, at: "_draft/a.md")
        let source = try XCTUnwrap(rig.mutations.read(at: "_draft/a.md"))
        let edit = try rig.mutations.rescue(source, at: "Conflicts/Raw.md", freshID: SyncTestValues.device)
        XCTAssertEqual(edit.bytes, raw)
        XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .committed)
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        let holds = try restarted.journal.heldRescues(in: restarted.binding.root)
        let hold = try XCTUnwrap(holds.first)
        XCTAssertEqual(hold.path, "Conflicts/Raw.md")
        XCTAssertEqual(hold.sourcePath, "_draft/a.md")
        XCTAssertEqual(hold.hash, SyncHash(bytes: raw))
        XCTAssertEqual(hold.issue, .localVisibility)
        XCTAssertEqual(hold.origin, .rescued)
        XCTAssertTrue(try restarted.journal.heldRescues(in: SyncLibraryRoot("/other-root")).isEmpty)
        try restarted.files.delete(at: "_draft/a.md")
        let server = bytes("title: Source", body: "Server version")
        try restarted.files.write(server, at: "a.md")
        let pull = try collected(server)
        defer { try? pull.discard() }
        let old = try SyncState(binding: restarted.binding, databaseID: SyncTestValues.uuid,
            cursors: [.user(SyncTestValues.user): "old"], prompts: [.assigned(copy): SyncPromptState(
                scope: .user(SyncTestValues.user), path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: server))])
        let local = try restarted.files.listFiles().map { try XCTUnwrap(restarted.mutations.read(at: RelativePath($0.relativePath))) }
        let plan = try SyncReconciler.plan(pull, state: old, local: .init(binding: restarted.binding, files: local,
            heldPaths: Set(holds.map(\.path))))
        XCTAssertTrue(plan.operations.isEmpty)
        XCTAssertEqual(plan.nextState.prompts[.assigned(copy)]?.path, "a.md")
        XCTAssertEqual(try restarted.files.read(at: "Conflicts/Raw.md"), raw)
    }

    func testLegacyRetentionCanReplayAndGainBoundHoldMetadata() throws {
        let rig = try SyncApplyTestRig()
        let raw = bytes("title: Hidden")
        try rig.files.write(raw, at: "_hidden/a.md")
        let edit = try rig.mutations.rescue(XCTUnwrap(rig.mutations.read(at: "_hidden/a.md")),
            at: "Conflicts/Raw.md", freshID: SyncTestValues.device)
        rig.libraryOperations.failFlushNumber = 1
        XCTAssertThrowsError(try rig.journal.apply(rig.plan([edit])))
        let path = "sync/retained/" + edit.id.uuidString.lowercased() + ".json"
        var legacy = try JSONSerialization.jsonObject(with: rig.data.read(at: path)) as! [String: Any]
        for key in ["serverURL", "userID", "libraryRoot", "destinationPath", "origin"] { legacy[key] = nil }
        legacy["vendor_extension"] = true
        try SyncTestValues.write(legacy, to: rig.data, path: path)
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        let hold = try XCTUnwrap(restarted.journal.heldRescues(in: restarted.binding.root).first)
        XCTAssertEqual(hold.path, "Conflicts/Raw.md")
        let upgraded = try JSONSerialization.jsonObject(with: rig.data.read(at: path)) as! [String: Any]
        XCTAssertEqual(upgraded["vendor_extension"] as? Bool, true)
        XCTAssertEqual(try rig.files.read(at: "Conflicts/Raw.md"), raw)
    }

    func testInvalidGroupMarkerIsAFileErrorWithReadOnlyExactPublication() throws {
        let rig = try SyncApplyTestRig()
        let group = SyncTestValues.group
        let invalid = try CanonicalForm.group(bytes("x-monkeyspaw-rescued: 'true'"), filename: "a.md").bytes
        let pull = try collected(invalid, scope: .group(group))
        defer { try? pull.discard() }
        let old = try SyncState(binding: rig.binding, databaseID: SyncTestValues.uuid,
            cursors: [.user(SyncTestValues.user): "old", .group(group): "old group"],
            groups: [group: SyncGroupState(name: "Team", folder: "Team", role: .viewer)])
        try rig.states.update(for: rig.binding) { $0 = old }
        let plan = try SyncReconciler.plan(pull, state: old, local: .init(binding: rig.binding, files: []))
        XCTAssertEqual(plan.nextState.prompts[.assigned(copy)]?.lastError?.code, .content(.invalidMetadataType))
        XCTAssertNil(plan.nextState.prompts[.assigned(copy)]?.origin)
        XCTAssertEqual(try rig.journal.apply(SyncReconciler.application(plan, mutations: rig.mutations)), .committed)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), invalid)
        XCTAssertEqual(rig.libraryOperations.modes["Groups/Team/a.md"], .readOnly)
    }

    private func collected(_ data: Data, scope: SyncScopeKey = .user(SyncTestValues.user)) throws -> SyncCollectedPull {
        let identity: SyncAPI.ScopeIdentity
        switch scope {
        case .user(let id): identity = .user(userID: id.rawValue)
        case .group(let id): identity = .group(groupID: id.rawValue, name: "Team", role: .viewer)
        }
        let page = SyncAPI.SyncScope(identity: identity, mode: .delta,
            head: 10, cursor: "new", hasMore: false, items: [.upsert(seq: 10, prompt: .init(id: copy.rawValue,
                rev: 2, path: "a.md", content: String(decoding: data, as: UTF8.self)))])
        var pages = [page]
        if case .group = scope { pages.append(.init(identity: .user(userID: SyncTestValues.user.rawValue), mode: .delta,
            head: 0, cursor: "user", hasMore: false, items: [])) }
        let staging = SyncPullStaging(files: MemoryFileStore())
        try staging.append(.init(databaseID: SyncTestValues.uuid.uuidString.lowercased(), scopes: pages, removed: []))
        return SyncCollectedPull(databaseID: SyncTestValues.uuid,
            scopes: try Dictionary(uniqueKeysWithValues: pages.map { (try SyncScopeKey($0.identity),
                SyncCollectedScope(page: $0, snapshotHead: nil, firstPage: 0)) }),
            removed: [], staging: staging)
    }

    private func origin(_ header: String) throws -> SyncPromptOrigin? {
        try SyncConflictMetadata.origin(in: bytes(header), filename: "a.md")
    }

    private func bytes(_ header: String, body: String = "Body") -> Data {
        Data(("---\nid: '\(copy.rawValue)'\n" + header + "\n---\n" + body).utf8)
    }
}
