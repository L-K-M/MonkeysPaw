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

    func testInvalidPullMarkersFailBeforeEvenAnOwnEchoCanBeSkipped() throws {
        let rig = try SyncApplyTestRig()
        let invalid = bytes("x-monkeyspaw-rescued: 'true'")
        let pull = try collected(invalid)
        defer { try? pull.discard() }
        let old = try SyncState(binding: rig.binding, databaseID: SyncTestValues.uuid,
            cursors: [.user(SyncTestValues.user): "old"], prompts: [.assigned(copy): SyncPromptState(
                scope: .user(SyncTestValues.user), path: "a.md", rev: 3, canonicalHash: SyncHash(bytes: invalid))])
        XCTAssertThrowsError(try SyncReconciler.plan(pull, state: old, local: .init(binding: rig.binding, files: []))) {
            XCTAssertEqual($0 as? SyncReconciliationError, .invalidPull)
        }
    }

    private func collected(_ data: Data) throws -> SyncCollectedPull {
        let page = SyncAPI.SyncScope(identity: .user(userID: SyncTestValues.user.rawValue), mode: .delta,
            head: 10, cursor: "new", hasMore: false, items: [.upsert(seq: 10, prompt: .init(id: copy.rawValue,
                rev: 2, path: "a.md", content: String(decoding: data, as: UTF8.self)))])
        let staging = SyncPullStaging(files: MemoryFileStore())
        try staging.append(.init(databaseID: SyncTestValues.uuid.uuidString.lowercased(), scopes: [page], removed: []))
        return SyncCollectedPull(databaseID: SyncTestValues.uuid,
            scopes: [.user(SyncTestValues.user): SyncCollectedScope(page: page, snapshotHead: nil, firstPage: 0)],
            removed: [], staging: staging)
    }

    private func origin(_ header: String) throws -> SyncPromptOrigin? {
        try SyncConflictMetadata.origin(in: bytes(header), filename: "a.md")
    }

    private func bytes(_ header: String, body: String = "Body") -> Data {
        Data(("---\nid: '\(copy.rawValue)'\n" + header + "\n---\n" + body).utf8)
    }
}
