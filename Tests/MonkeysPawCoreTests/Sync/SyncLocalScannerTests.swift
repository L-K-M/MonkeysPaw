import Foundation
import XCTest
@testable import MonkeysPawCore

enum SyncScanTestSupport {
    static let id = SyncTestValues.personalPrompt
    static let other = SyncTestValues.groupPrompt
    static let fresh = SyncTestValues.device
    static var personal: SyncScopeKey { .user(SyncTestValues.user) }
    static var team: SyncScopeKey { .group(SyncTestValues.group) }

    static func bytes(_ body: String = "Body\r\n", id: ULID? = id, extra: String = "") -> Data {
        let header = id.map { "id: '\($0.rawValue)'\n" } ?? ""
        return Data(("---\n" + header + "title: Exact\n" + extra + "---\n" + body).utf8)
    }

    static func groups(role: SyncAPI.Role = .editor) throws -> [ULID: SyncGroupState] {
        [SyncTestValues.group: try SyncGroupState(name: "Team", folder: "Team", role: role)]
    }

    @discardableResult
    static func installState(_ rig: SyncApplyTestRig, groups: [ULID: SyncGroupState] = [:],
                             prompts: [PromptIdentity: SyncPromptState] = [:], favorites: [PromptIdentity: Bool] = [:],
                             database: UUID? = nil) throws -> SyncState {
        let state = try SyncState(binding: rig.binding, databaseID: database, groups: groups, prompts: prompts, favorites: favorites)
        try rig.states.update(for: rig.binding) { $0 = state }
        return state
    }

    static func scan(_ rig: SyncApplyTestRig, ownership: SyncLibraryBinding? = nil,
                     retained: [SyncRetainedRescue] = [], ids: [ULID] = [fresh]) throws -> SyncLocalScan {
        var index = 0
        return try SyncLocalScanner.scan(binding: rig.binding, state: rig.states.load(for: rig.binding),
            ownership: ownership, retainedRescues: retained, availability: .available, freshID: {
                guard index < ids.count else { throw SyncError.invalidState }
                defer { index += 1 }
                return ids[index]
            }, mutations: rig.mutations)
    }

    static func prepare(_ rig: SyncApplyTestRig) throws -> SyncLocalScan {
        for _ in 0..<3 {
            let scan = try self.scan(rig)
            guard let plan = scan.preparation else { return scan }
            guard try rig.journal.apply(plan) == .committed else { throw SyncError.invalidState }
        }
        throw SyncError.invalidState
    }

    static func record(_ bytes: Data, scope: SyncScopeKey = personal, path: RelativePath = "a.md", rev: Int64 = 3) throws -> SyncPromptState {
        let form = try SyncLocalScanner.canonical(bytes, path: path, scope: scope)
        return try SyncPromptState(scope: scope, path: path, rev: rev, canonicalHash: SyncHash(bytes: form.bytes))
    }
}

final class SyncLocalScannerTests: XCTestCase {
    private let id = SyncScanTestSupport.id
    private let other = SyncScanTestSupport.other
    private let fresh = SyncScanTestSupport.fresh

    func testGitCopyKeepsAssignedIdentityAndBecomesCreate() throws {
        let rig = try SyncApplyTestRig()
        let bytes = SyncScanTestSupport.bytes(extra: "# exact comment\n")
        try rig.files.write(bytes, at: "a.md")
        let scan = try SyncScanTestSupport.prepare(rig)
        guard case .create(let prompt) = try XCTUnwrap(scan.changes.first) else { return XCTFail("Expected create") }
        XCTAssertEqual(prompt.identity, .assigned(id))
        XCTAssertEqual(prompt.canonical.bytes, bytes)
        XCTAssertEqual(try rig.files.read(at: "a.md"), bytes)
        XCTAssertEqual(scan.changes.count, 1)
    }

    func testIdlessIdentityAssignmentMigratesAllKeysAndPendingFavorite() throws {
        let rig = try SyncApplyTestRig()
        let path = "Groups/Team/a.md"
        let local = PromptIdentity(path: path, id: nil)
        let bytes = SyncScanTestSupport.bytes(id: nil, extra: "favorite: true\nprivate: false\n")
        try rig.files.write(bytes, at: path)
        let pending = try SyncPromptState(scope: SyncScanTestSupport.team, path: "a.md", rev: 0)
        try SyncScanTestSupport.installState(rig, groups: SyncScanTestSupport.groups(), prompts: [local: pending], favorites: [local: true])
        _ = try HistoryStore(files: rig.data).snapshot(bytes, for: local, at: Date(timeIntervalSince1970: 1))
        let provenance = PromptProvenance(timestamp: Date(timeIntervalSince1970: 1),
            providerHost: "example.test", model: "test", usage: nil)
        try HistoryStore(files: rig.data).setHeadProvenance(provenance, for: local, bytes: bytes)
        try rig.usage.recordUse(identity: local)
        try rig.values.record(identity: local, values: ["field": "remembered"])
        let first = try SyncScanTestSupport.scan(rig)
        XCTAssertTrue(first.changes.isEmpty)
        let plan = try XCTUnwrap(first.preparation)
        XCTAssertEqual(plan.edits.count, 1)
        XCTAssertNil(plan.nextState.prompts[local])
        XCTAssertEqual(plan.nextState.favorites[.assigned(fresh)], true)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        let identity = PromptIdentity.assigned(fresh)
        XCTAssertEqual(try rig.library.history(for: identity).count, 1)
        XCTAssertTrue(try rig.library.history(for: local).isEmpty)
        XCTAssertEqual(try rig.usage.useEvents(for: identity).count, 1)
        XCTAssertTrue(try rig.usage.useEvents(for: local).isEmpty)
        XCTAssertEqual(try rig.values.rememberedValues(for: identity), ["field": "remembered"])
        XCTAssertTrue(try rig.values.rememberedValues(for: local).isEmpty)
        let rewritten = try rig.files.read(at: path)
        XCTAssertEqual(try HistoryStore(files: rig.data).headProvenance(for: identity, bytes: rewritten), provenance)
        let form = try CanonicalForm.group(rewritten, filename: "a.md")
        XCTAssertEqual(form.bytes, rewritten)
        XCTAssertNil(form.favorite)
        XCTAssertFalse(String(decoding: rewritten, as: UTF8.self).contains("private:"))
        XCTAssertEqual(rig.states.snapshot.value?.prompts[identity]?.rev, 0)
        XCTAssertNil(rig.states.snapshot.value?.prompts[identity]?.canonicalHash)
        let second = try SyncScanTestSupport.scan(rig)
        XCTAssertNil(second.preparation)
        guard case .create(let candidate) = try XCTUnwrap(second.changes.first) else { return XCTFail("Expected create") }
        XCTAssertEqual(candidate.identity, identity)
        XCTAssertEqual(candidate.canonical.canonicalHash, SHA256.hexDigest(rewritten))
    }

    func testIdentityMatchesBeforePathAndDetectsRenameMoveAndEdit() throws {
        let rig = try SyncApplyTestRig()
        let original = SyncScanTestSupport.bytes()
        try SyncScanTestSupport.installState(rig, groups: SyncScanTestSupport.groups(),
            prompts: [.assigned(id): SyncScanTestSupport.record(original)])
        // The idless replacement sorts before the renamed ID-bearing original.
        try rig.files.write(SyncScanTestSupport.bytes(id: nil), at: "a.md")
        try rig.files.write(original, at: "z.md")
        let scan = try SyncScanTestSupport.prepare(rig)
        XCTAssertEqual(scan.changes.count, 2)
        XCTAssertTrue(scan.changes.contains { if case .rename(let prompt, _) = $0 { return prompt.identity == .assigned(id) }; return false })
        XCTAssertTrue(scan.changes.contains { if case .create(let prompt) = $0 { return prompt.identity == .assigned(fresh) }; return false })
        try rig.files.move(from: "z.md", to: "Groups/Team/new.md")
        try rig.files.write(SyncScanTestSupport.bytes("Moved and edited"), at: "Groups/Team/new.md")
        let moved = try SyncScanTestSupport.prepare(rig)
        XCTAssertTrue(moved.changes.contains { if case .move(let prompt, let old) = $0 {
            return prompt.identity == .assigned(id) && old.path == "a.md" && prompt.scope == SyncScanTestSupport.team
        }; return false })
        XCTAssertFalse(moved.changes.contains { if case .delete = $0 { return true }; return false })
        try rig.files.move(from: "Groups/Team/new.md", to: "edit.md")
        try rig.states.update(for: rig.binding) { $0.prompts[.assigned(id)] = try SyncScanTestSupport.record(original, path: "edit.md") }
        let edited = try SyncScanTestSupport.scan(rig)
        XCTAssertTrue(edited.changes.contains { if case .update(let prompt, _) = $0 { return prompt.identity == .assigned(id) }; return false })
    }

    func testIdlessRecordedPathRestoresIdentityInsteadOfDeletingOrCreating() throws {
        let rig = try SyncApplyTestRig()
        let original = SyncScanTestSupport.bytes()
        try SyncScanTestSupport.installState(rig, prompts: [.assigned(id): SyncScanTestSupport.record(original)])
        try rig.files.write(SyncScanTestSupport.bytes("Changed", id: nil), at: "a.md")
        let scan = try SyncScanTestSupport.prepare(rig)
        guard case .update(let prompt, _) = try XCTUnwrap(scan.changes.first) else { return XCTFail("Expected update") }
        XCTAssertEqual(prompt.identity, .assigned(id))
        XCTAssertEqual(scan.changes.count, 1)
    }

    func testExternalIdentityAssignmentMigratesLocalPathStateBeforeCreate() throws {
        let rig = try SyncApplyTestRig()
        let path = "Groups/Team/a.md"
        let local = PromptIdentity(path: path, id: nil)
        let bytes = try CanonicalForm.group(SyncScanTestSupport.bytes(id: other), filename: "a.md").bytes
        try rig.files.write(bytes, at: path)
        let pending = try SyncPromptState(scope: SyncScanTestSupport.team, path: "a.md", rev: 0)
        try SyncScanTestSupport.installState(rig, groups: SyncScanTestSupport.groups(), prompts: [local: pending], favorites: [local: true])
        _ = try HistoryStore(files: rig.data).snapshot(bytes, for: local, at: Date(timeIntervalSince1970: 1))
        try rig.usage.recordUse(identity: local)
        try rig.values.record(identity: local, values: ["field": "remembered"])
        let first = try SyncScanTestSupport.scan(rig)
        let plan = try XCTUnwrap(first.preparation)
        XCTAssertNil(plan.nextState.prompts[local])
        XCTAssertEqual(plan.nextState.favorites[.assigned(other)], true)
        XCTAssertEqual(plan.edits.count, 1)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertEqual(try rig.values.rememberedValues(for: .assigned(other)), ["field": "remembered"])
        XCTAssertEqual(try rig.usage.useEvents(for: .assigned(other)).count, 1)
        XCTAssertEqual(try rig.library.history(for: .assigned(other)).count, 1)
        XCTAssertTrue(try rig.values.rememberedValues(for: local).isEmpty)
        XCTAssertEqual(try rig.files.read(at: path), bytes)
        let second = try SyncScanTestSupport.scan(rig)
        XCTAssertNil(second.preparation)
        guard case .create(let candidate) = try XCTUnwrap(second.changes.first) else { return XCTFail("Expected create") }
        XCTAssertEqual(candidate.identity, .assigned(other))
    }

    func testExternalAssignmentReplansUntouchedKeyedMigrationAfterRacingEdit() throws {
        let rig = try SyncApplyTestRig()
        let local = PromptIdentity(path: "a.md", id: nil)
        try rig.files.write(SyncScanTestSupport.bytes(id: other), at: "a.md")
        let pending = try SyncPromptState(scope: SyncScanTestSupport.personal, path: "a.md", rev: 0)
        try SyncScanTestSupport.installState(rig, prompts: [local: pending])
        try rig.values.record(identity: local, values: ["field": "remembered"])
        let plan = try XCTUnwrap(SyncScanTestSupport.scan(rig).preparation)
        let latest = SyncScanTestSupport.bytes("Changed during preparation", id: other)
        try rig.files.write(latest, at: "a.md")
        XCTAssertEqual(try rig.journal.apply(plan), .replanAsConflict(operationID: plan.edits[0].id))
        XCTAssertEqual(try rig.files.read(at: "a.md"), latest)
        let replan = try XCTUnwrap(SyncScanTestSupport.scan(rig).preparation)
        XCTAssertEqual(try rig.journal.replan(replan), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), latest)
        XCTAssertEqual(try rig.values.rememberedValues(for: .assigned(other)), ["field": "remembered"])
        XCTAssertTrue(try rig.values.rememberedValues(for: local).isEmpty)
    }

    func testDuplicateRepairUsesExactUTF8OrderAndKeepsWinnerKeyedState() throws {
        let rig = try SyncApplyTestRig()
        let original = SyncScanTestSupport.bytes()
        let paths = ["é.md", "e\u{301}.md", "z.md"]
        for path in paths { try rig.files.write(original, at: path) }
        try rig.values.record(identity: .assigned(id), values: ["field": "winner"])
        try rig.usage.recordUse(identity: .assigned(id))
        _ = try HistoryStore(files: rig.data).snapshot(original, for: .assigned(id), at: Date(timeIntervalSince1970: 1))
        let scan = try SyncScanTestSupport.scan(rig, ids: [fresh, other])
        let plan = try XCTUnwrap(scan.preparation)
        XCTAssertEqual(plan.edits.map(\.path), ["z.md", "é.md"])
        XCTAssertTrue(plan.edits.allSatisfy { $0.kind == .repairDuplicate })
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        let identityAt: (String) throws -> PromptIdentity = { try XCTUnwrap(rig.mutations.read(at: RelativePath($0))).identity }
        XCTAssertEqual(try identityAt("e\u{301}.md"), .assigned(id))
        XCTAssertEqual(try identityAt("z.md"), .assigned(fresh))
        XCTAssertEqual(try identityAt("é.md"), .assigned(other))
        XCTAssertEqual(try rig.values.rememberedValues(for: .assigned(id)), ["field": "winner"])
        XCTAssertTrue(try rig.values.rememberedValues(for: .assigned(fresh)).isEmpty)
        XCTAssertEqual(try rig.usage.useEvents(for: .assigned(id)).count, 1)
        XCTAssertEqual(try rig.library.history(for: .assigned(id)).count, 1)
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        XCTAssertNil(try SyncScanTestSupport.scan(restarted).preparation)
    }

    func testMalformedFutureAndInvalidUTF8RemainExactAndHeld() throws {
        let rig = try SyncApplyTestRig()
        let samples: [(String, Data, SyncIssueCode)] = [
            ("broken.md", Data("---\ntitle: [\n---\nLocal".utf8), .content(.invalidYAML)),
            ("future.md", SyncScanTestSupport.bytes(extra: "format: 999\n"), .content(.unsupportedFormat)),
            ("binary.md", Data([0xFF, 0x00]), .content(.invalidUTF8)),
            ("marker.md", SyncScanTestSupport.bytes(id: other, extra: "x-monkeyspaw-rescued: 'true'\n"), .content(.invalidMetadataType))
        ]
        for (path, bytes, _) in samples { try rig.files.write(bytes, at: path) }
        let scan = try SyncScanTestSupport.scan(rig)
        XCTAssertTrue(scan.changes.isEmpty)
        XCTAssertEqual(scan.snapshot.heldPaths.count, samples.count)
        XCTAssertTrue(try XCTUnwrap(scan.preparation).edits.isEmpty)
        XCTAssertEqual(try rig.journal.apply(XCTUnwrap(scan.preparation)), .committed)
        for (path, bytes, issue) in samples {
            XCTAssertEqual(try rig.files.read(at: path), bytes)
            XCTAssertEqual(scan.issues[RelativePath(path)], issue)
        }
        XCTAssertNil(try SyncScanTestSupport.scan(rig).preparation)
    }

    func testOrphanGroupFilesBlockMatchingUntilRescued() throws {
        let rig = try SyncApplyTestRig()
        let samples = ["Groups/Unknown/a.md", "Groups/loose.md", "Groups/Unknown/binary.bin", "groups/Team/a.md"]
        for path in samples { try rig.files.write(SyncScanTestSupport.bytes(), at: path) }
        try rig.files.write(SyncScanTestSupport.bytes(id: nil), at: "local.md")
        let scan = try SyncScanTestSupport.scan(rig)
        XCTAssertEqual(Set(scan.orphanFiles.map(\.path)), Set(samples))
        XCTAssertTrue(scan.changes.isEmpty)
        XCTAssertNil(scan.preparation)
        XCTAssertTrue(scan.snapshot.heldPaths.isSuperset(of: Set(samples.map { RelativePath($0) })))
        XCTAssertEqual(rig.files.writeCount, samples.count + 1)
    }

    func testForeignOwnedGroupFolderIsRescuedBeforeMatchingCurrentGroup() throws {
        let rig = try SyncApplyTestRig()
        try SyncScanTestSupport.installState(rig, groups: SyncScanTestSupport.groups())
        try rig.files.write(SyncScanTestSupport.bytes(), at: "Groups/Team/a.md")
        let ownership = try SyncLibraryBinding(root: rig.binding.root, owner: rig.binding.account,
            managedFolders: [SyncTestValues.group: SyncManagedFolder(
                owner: SyncTestValues.account(userID: SyncTestValues.otherUser), folder: "Team")])
        let scan = try SyncScanTestSupport.scan(rig, ownership: ownership)
        XCTAssertEqual(scan.orphanFiles.map(\.path), ["Groups/Team/a.md"])
        XCTAssertNil(scan.preparation)
        XCTAssertTrue(scan.changes.isEmpty)
    }

    func testIgnoredPathsAreFullListingOccupantsNeverBrowserDeletes() throws {
        let rig = try SyncApplyTestRig()
        let paths = [".git/a.md", "_draft/a.md", "_a.md", "README.md"]
        var records: [PromptIdentity: SyncPromptState] = [:]
        for (index, path) in paths.enumerated() {
            let id = ULID("0000000000000000000000001\(index)")!
            let bytes = SyncScanTestSupport.bytes(id: id)
            try rig.files.write(bytes, at: path)
            // A hidden directory cannot be a wire baseline; pending local state
            // still demonstrates full-list occupancy without browser inference.
            let rev: Int64 = path.hasPrefix(".git/") ? 0 : 3
            records[.assigned(id)] = try SyncPromptState(scope: SyncScanTestSupport.personal,
                path: RelativePath(path), rev: rev, canonicalHash: rev == 0 ? nil : SyncHash(bytes: bytes))
        }
        let eligible = [".prompt.md", "folder/README.md"]
        for (index, path) in eligible.enumerated() {
            try rig.files.write(SyncScanTestSupport.bytes(id: index == 0 ? id : other), at: path)
        }
        try SyncScanTestSupport.installState(rig, prompts: records)
        let scan = try SyncScanTestSupport.prepare(rig)
        XCTAssertEqual(scan.snapshot.files.count, paths.count + eligible.count)
        XCTAssertEqual(scan.changes.count, 2)
        XCTAssertFalse(scan.changes.contains { if case .delete = $0 { return true }; return false })
        for path in paths { XCTAssertEqual(scan.issues[RelativePath(path)], .localVisibility) }
        // An ID moved into an ignored location must not become a delete of its
        // formerly visible path, even though the browser omits the live version.
        try rig.files.move(from: ".prompt.md", to: "_hidden.md")
        try rig.states.update(for: rig.binding) { $0.prompts[.assigned(id)] = try SyncScanTestSupport.record(SyncScanTestSupport.bytes(), path: ".prompt.md") }
        let moved = try SyncScanTestSupport.scan(rig)
        XCTAssertFalse(moved.changes.contains { if case .delete(let value, _) = $0 { return value == .assigned(id) }; return false })
    }

    func testTrueAbsenceProducesDeleteButReplacementDoesNot() throws {
        let rig = try SyncApplyTestRig()
        try SyncScanTestSupport.installState(rig, prompts: [.assigned(id): SyncScanTestSupport.record(SyncScanTestSupport.bytes())])
        let missing = try SyncScanTestSupport.scan(rig)
        guard case .delete(let identity, _) = try XCTUnwrap(missing.changes.first) else { return XCTFail("Expected delete") }
        XCTAssertEqual(identity, .assigned(id))
        try rig.files.write(SyncScanTestSupport.bytes("Replacement", id: other), at: "a.md")
        let replacement = try SyncScanTestSupport.prepare(rig)
        XCTAssertFalse(replacement.changes.contains { if case .delete = $0 { return true }; return false })
        guard case .create(let candidate) = try XCTUnwrap(replacement.changes.first) else { return XCTFail("Keep import identity") }
        XCTAssertEqual(candidate.identity, .assigned(other))
    }

    func testFavoriteTrueFalseAndAbsentRewriteOnceWithoutUpload() throws {
        for favorite in ["favorite: true\n", "favorite: false\n", ""] {
            let rig = try SyncApplyTestRig()
            let bytes = SyncScanTestSupport.bytes(extra: favorite + "private: false\n")
            let canonical = try CanonicalForm.group(bytes, filename: "a.md").bytes
            try rig.files.write(bytes, at: "Groups/Team/a.md")
            try SyncScanTestSupport.installState(rig, groups: SyncScanTestSupport.groups(role: .viewer),
                prompts: [.assigned(id): SyncScanTestSupport.record(canonical, scope: SyncScanTestSupport.team)], favorites: [.assigned(id): true])
            let initial = rig.files.writeCount
            let first = try SyncScanTestSupport.scan(rig)
            let plan = try XCTUnwrap(first.preparation)
            XCTAssertEqual(plan.edits.count, 1)
            XCTAssertEqual(try rig.journal.apply(plan), .committed)
            XCTAssertEqual(rig.files.writeCount, initial + 1)
            XCTAssertEqual(rig.states.snapshot.value?.favorites[.assigned(id)], favorite == "favorite: false\n" ? nil : true)
            XCTAssertEqual(rig.libraryOperations.modes["Groups/Team/a.md"], .readOnly)
            let second = try SyncScanTestSupport.scan(rig)
            XCTAssertNil(second.preparation)
            XCTAssertTrue(second.changes.isEmpty)
            XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), canonical)
        }
    }

    func testEnteringGroupRetainsFavoriteUntilMoveAcknowledgesScope() throws {
        let rig = try SyncApplyTestRig()
        let bytes = SyncScanTestSupport.bytes(extra: "favorite: true\nprivate: false\n")
        try rig.files.write(bytes, at: "Groups/Team/a.md")
        try SyncScanTestSupport.installState(rig, groups: SyncScanTestSupport.groups(),
            prompts: [.assigned(id): SyncScanTestSupport.record(bytes)])
        let scan = try SyncScanTestSupport.scan(rig)
        XCTAssertNil(scan.preparation)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), bytes)
        guard case .move(let prompt, _) = try XCTUnwrap(scan.changes.first) else { return XCTFail("Expected move") }
        XCTAssertEqual(prompt.canonical.favorite, true)
        let baseline = try CanonicalForm.group(bytes, filename: "a.md").bytes
        try rig.states.update(for: rig.binding) {
            $0.prompts[.assigned(self.id)] = try SyncScanTestSupport.record(baseline, scope: SyncScanTestSupport.team)
        }
        let after = try SyncScanTestSupport.prepare(rig)
        XCTAssertEqual(rig.states.snapshot.value?.favorites[.assigned(id)], true)
        XCTAssertTrue(after.changes.isEmpty)
    }

    func testAccountHoldsPrecedeAssignmentDuplicateRepairAndDeletion() throws {
        let rig = try SyncApplyTestRig()
        let privateBytes = SyncScanTestSupport.bytes()
        let idlessBytes = SyncScanTestSupport.bytes(id: nil)
        try rig.files.write(privateBytes, at: "held.md")
        try rig.files.write(privateBytes, at: "copy.md")
        try rig.files.write(idlessBytes, at: "renamed.md")
        let source = try SyncTestValues.account(userID: SyncTestValues.otherUser)
        let ownership = try SyncLibraryBinding(root: rig.binding.root, owner: rig.binding.account, holds: [
            SyncHeldPrompt(identity: .assigned(id), path: "held.md", sourceAccount: source, contentHash: SyncHash(bytes: privateBytes)),
            SyncHeldPrompt(identity: PromptIdentity(path: "old.md", id: nil), path: "old.md", sourceAccount: source, contentHash: SyncHash(bytes: idlessBytes))
        ])
        let scan = try SyncScanTestSupport.scan(rig, ownership: ownership, ids: [])
        XCTAssertNil(scan.preparation)
        XCTAssertTrue(scan.changes.isEmpty)
        XCTAssertEqual(scan.snapshot.heldPaths, ["held.md", "copy.md", "renamed.md"])
        try rig.files.write(SyncScanTestSupport.bytes("Edited", id: id), at: "copy.md")
        XCTAssertTrue(try SyncScanTestSupport.scan(rig, ownership: ownership, ids: []).snapshot.heldPaths.contains("copy.md"))
        let otherOwner = try SyncLibraryBinding(root: rig.binding.root, owner: source)
        XCTAssertThrowsError(try SyncScanTestSupport.scan(rig, ownership: otherOwner)) { XCTAssertEqual($0 as? SyncError, .bindingMismatch) }
        let wrongRoot = try SyncLibraryBinding(root: SyncLibraryRoot("/another"), owner: rig.binding.account)
        XCTAssertThrowsError(try SyncScanTestSupport.scan(rig, ownership: wrongRoot))
        try SyncScanTestSupport.installState(rig, prompts: [.assigned(id): SyncScanTestSupport.record(privateBytes, path: "missing.md")])
        XCTAssertFalse(try SyncScanTestSupport.scan(rig, ownership: ownership, ids: []).changes.contains { if case .delete = $0 { return true }; return false })
    }

    func testRawRescueHoldSurvivesRestartAndDoesNotRepairItsEmbeddedID() throws {
        let rig = try SyncApplyTestRig()
        let bytes = SyncScanTestSupport.bytes(extra: "format: 999\n")
        try rig.files.write(bytes, at: "a.md")
        let source = try XCTUnwrap(rig.mutations.read(at: "a.md"))
        let rescue = try rig.mutations.rescue(source, at: "Conflicts/raw.md", freshID: fresh)
        XCTAssertEqual(try rig.journal.apply(rig.plan([rescue, rig.mutations.trash(source)])), .committed)
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        try restarted.files.write(SyncScanTestSupport.bytes(), at: "live.md")
        let retained = try restarted.journal.heldRescues(in: restarted.binding.root)
        let scan = try SyncScanTestSupport.scan(restarted, retained: retained, ids: [])
        XCTAssertTrue(scan.snapshot.heldPaths.contains("Conflicts/raw.md"))
        XCTAssertFalse(scan.snapshot.heldPaths.contains("live.md"))
        XCTAssertTrue(try XCTUnwrap(scan.preparation).edits.isEmpty)
        XCTAssertEqual(try restarted.files.read(at: "Conflicts/raw.md"), bytes)
    }

    func testUnavailableRootAndRacingListingFailWithoutDeleteEvidence() throws {
        let rig = try SyncApplyTestRig()
        XCTAssertThrowsError(try SyncLocalScanner.scan(binding: rig.binding, state: nil, availability: .unavailable,
            freshID: { self.fresh }, mutations: rig.mutations)) { XCTAssertEqual($0 as? SyncReconciliationError, .unavailableLibrary) }
        try rig.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        rig.files.onRead = { path in
            rig.files.onRead = nil
            try rig.files.write(SyncScanTestSupport.bytes("Raced"), at: path)
        }
        XCTAssertThrowsError(try SyncScanTestSupport.scan(rig)) { XCTAssertEqual($0 as? LibraryError, .conflict) }
        XCTAssertNil(rig.states.snapshot.value)
        XCTAssertNil(rig.journal.pending)
    }

    func testSymlinkLeafOrParentOmittedFromListingIsNeverReadOrDeleted() throws {
        for failure in [FileStoreError.notRegularFile, .outsideRoot] {
            let rig = try SyncApplyTestRig()
            try SyncScanTestSupport.installState(rig, prompts: [.assigned(id): SyncScanTestSupport.record(SyncScanTestSupport.bytes())])
            // The rooted port omits links from enumeration and rejects stamps
            // before reading a link leaf or traversing a linked parent.
            rig.files.onStamp = { path, _ in if path == "a.md" { throw failure } }
            rig.files.onRead = { _ in XCTFail("A rejected link must never be followed") }
            let scan = try SyncScanTestSupport.scan(rig)
            XCTAssertTrue(scan.changes.isEmpty)
            XCTAssertEqual(scan.issues["a.md"], .localVisibility)
            XCTAssertTrue(scan.snapshot.heldPaths.contains("a.md"))
            XCTAssertTrue(try XCTUnwrap(scan.preparation).edits.isEmpty)
        }
    }

    func testMaximumGroupWrapperRetainsFullWirePath() throws {
        let rig = try SyncApplyTestRig()
        let folder = String(repeating: "g", count: 255)
        let path = [String(repeating: "a", count: 255), String(repeating: "b", count: 255),
                    String(repeating: "c", count: 255), String(repeating: "d", count: 251), "a.md"].joined(separator: "/")
        XCTAssertEqual(path.utf8.count, 1024)
        let group = try SyncGroupState(name: "Team", folder: folder, role: .editor)
        try SyncScanTestSupport.installState(rig, groups: [SyncTestValues.group: group])
        try rig.files.write(SyncScanTestSupport.bytes(), at: "Groups/" + folder + "/" + path)
        let scan = try SyncScanTestSupport.prepare(rig)
        guard case .create(let prompt) = try XCTUnwrap(scan.changes.first) else { return XCTFail("Expected full path") }
        XCTAssertEqual(prompt.path.string, path)
        XCTAssertEqual(prompt.file.path.utf8.count, 1287)
    }
}
