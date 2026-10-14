import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncGroupFolderTests: XCTestCase {
    private let group = SyncTestValues.group
    private let date = Date(timeIntervalSince1970: 1_791_936_000)

    func testReservedPreflightIncludesEmptyFoldersAndLooseFiles() throws {
        for path in ["Groups", "Conflicts", "GROUPS"] {
            let rig = try Rig()
            try rig.base.libraryOperations.createDirectory(at: RelativePath(path))
            let inventory = try rig.inventory()
            XCTAssertThrowsError(try SyncGroupFolders.preflight(inventory, ownership: nil)) {
                XCTAssertEqual($0 as? SyncGroupFolderError, .reservedFolders([RelativePath(path)]))
            }
            let owner = try SyncLibraryBinding(root: rig.base.binding.root, owner: rig.base.binding.account)
            XCTAssertNoThrow(try SyncGroupFolders.preflight(inventory, ownership: owner))
        }
        let rig = try Rig()
        try rig.base.files.put("keep", at: "Groups")
        XCTAssertThrowsError(try SyncGroupFolders.preflight(rig.inventory(), ownership: nil)) {
            XCTAssertEqual($0 as? SyncGroupFolderError, .reservedFolders(["Groups"]))
        }
        XCTAssertEqual(try rig.base.files.text(at: "Groups"), "keep")
    }

    func testAllocationSanitizesNormalizesFoldsAndPersists() throws {
        let rig = try Rig()
        let names = ["A/B", "A\\B", "Straße", "STRASSE", "Cafe\u{301}", "Café", "---_..", "\u{001f}"]
        let members = names.enumerated().map { SyncAPI.GroupMembership(groupID: id(10 + $0.offset).rawValue, name: $0.element, role: .editor) }
        let plan = try SyncGroupFolders.update(Array(members.reversed()), state: nil, ownership: nil,
            inventory: rig.inventory(), mutations: rig.base.mutations)
        XCTAssertEqual(plan.nextState.groups[id(10)]?.folder, "A-B")
        XCTAssertEqual(plan.nextState.groups[id(11)]?.folder, "A-B (2)")
        XCTAssertEqual(plan.nextState.groups[id(12)]?.folder, "Straße")
        XCTAssertEqual(plan.nextState.groups[id(13)]?.folder, "STRASSE (2)")
        XCTAssertEqual(plan.nextState.groups[id(14)]?.folder, "Café")
        XCTAssertEqual(plan.nextState.groups[id(15)]?.folder, "Café (2)")
        XCTAssertEqual(plan.nextState.groups[id(16)]?.folder, "Group")
        XCTAssertEqual(plan.nextState.groups[id(17)]?.folder, "Group (2)")
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        let restarted = try Rig(files: rig.base.files, data: rig.base.data)
        let state = try XCTUnwrap(restarted.base.states.load(for: rig.base.binding))
        let owned = try XCTUnwrap(restarted.accounts.binding(for: rig.base.binding.root))
        let repeatPlan = try SyncGroupFolders.update(members, state: state, ownership: owned,
            inventory: restarted.inventory(), mutations: restarted.base.mutations)
        XCTAssertEqual(repeatPlan.nextState, state)
        XCTAssertNil(repeatPlan.bindingChange)
        XCTAssertTrue(repeatPlan.edits.isEmpty)
        XCTAssertTrue(repeatPlan.directories.isEmpty)
    }

    func testSuffixFitsUnicodeSegmentAndMoreThanTwentyGroups() throws {
        let stem = String(repeating: "界", count: 85)
        var occupied: [String] = []
        for number in 1...30 {
            let folder = try SyncNaming.groupFolder(stem, occupied: occupied)
            XCTAssertLessThanOrEqual(folder.utf8.count, 255)
            if number > 1 { XCTAssertTrue(folder.hasSuffix(" (\(number))")) }
            XCTAssertNoThrow(try SyncIdentifiers.folder(folder))
            occupied.append(folder)
        }
        XCTAssertEqual(try SyncNaming.groupFolder("I", occupied: ["i"]), "I (2)")
        XCTAssertEqual(try SyncNaming.groupFolder("İ", occupied: ["i"]), "İ")
    }

    func testOccupiedUnownedDirectoriesAndLooseFilesAreNeverAdopted() throws {
        let rig = try Rig()
        let owned = try rig.seed(groups: [:])
        try rig.base.libraryOperations.createDirectory(at: "Groups/Team")
        try rig.base.files.put("unknown", at: "Groups/Other")
        let plan = try SyncGroupFolders.update([member("Team"), member("Other", id: id(20))],
            state: rig.state(), ownership: owned, inventory: rig.inventory(), mutations: rig.base.mutations)
        XCTAssertEqual(plan.nextState.groups[group]?.folder, "Team (2)")
        XCTAssertEqual(plan.nextState.groups[id(20)]?.folder, "Other (2)")
        XCTAssertTrue(plan.directories.isEmpty)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertEqual(try rig.base.files.text(at: "Groups/Other"), "unknown")
        XCTAssertTrue(try rig.base.mutations.directoryIdentities().keys.contains("Groups/Team"))
    }

    func testRenameChangesOnlyFolderMappingAndPreservesUnknownSubtree() throws {
        let rig = try Rig()
        let bytes = SyncApplyTestRig.bytes("clean", id: id(30))
        try rig.base.files.write(bytes, at: "Groups/Team/sub/A.md")
        let raw = Data([0xFF, 0, 13, 10])
        try rig.base.files.write(raw, at: "Groups/Team/.hidden/_raw.bin")
        let prompt = try record("sub/A.md", bytes: bytes)
        var owned = try rig.seed(groups: [group: groupState()], prompts: [.assigned(id(30)): prompt])
        owned.holds = [try SyncHeldPrompt(identity: .assigned(id(30)), path: "Groups/Team/sub/A.md",
            sourceAccount: rig.base.binding.account, contentHash: SyncHash(bytes: bytes))]
        try rig.accounts.updateBinding(for: owned.root) { _ in owned }
        let old = try rig.state()
        let plan = try SyncGroupFolders.update([member("New")], state: old, ownership: owned,
            inventory: rig.inventory(), mutations: rig.base.mutations)
        XCTAssertEqual(plan.nextState.prompts, old.prompts)
        XCTAssertEqual(plan.nextState.cursors, old.cursors)
        XCTAssertEqual(plan.nextState.databaseID, old.databaseID)
        XCTAssertEqual(plan.directories.count, 1)
        XCTAssertNil(plan.directories.first?.intermediate)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertEqual(try rig.base.files.read(at: "Groups/New/sub/A.md"), bytes)
        XCTAssertEqual(try rig.base.files.read(at: "Groups/New/.hidden/_raw.bin"), raw)
        XCTAssertNil(try rig.base.files.stamp(at: "Groups/Team/sub/A.md"))
        XCTAssertEqual(try rig.accounts.binding(for: owned.root)?.holds.first?.path, "Groups/New/sub/A.md")
    }

    func testCaseOnlyRenameReplaysFromIntermediateWithSameIdentity() throws {
        let rig = try Rig()
        let bytes = SyncApplyTestRig.bytes("keep")
        try rig.base.files.write(bytes, at: "Groups/Team/A.md")
        let owned = try rig.seed(groups: [group: groupState()])
        let plan = try SyncGroupFolders.update([member("TEAM")], state: rig.state(), ownership: owned,
            inventory: rig.inventory(), mutations: rig.base.mutations)
        let edit = try XCTUnwrap(plan.directories.first)
        let temporary = try XCTUnwrap(edit.intermediate)
        var renames = 0
        rig.base.libraryOperations.onOperation = { operation in
            guard operation.hasPrefix("rename-directory:") else { return }
            renames += 1
            if renames == 2 { rig.base.libraryOperations.failOperationNumber = rig.base.libraryOperations.operationCount }
        }
        XCTAssertThrowsError(try rig.journal.apply(plan))
        XCTAssertEqual(renames, 2)
        XCTAssertEqual(try rig.base.files.read(at: temporary.string + "/A.md"), bytes)
        XCTAssertEqual(try rig.state().groups[group]?.folder, "Team")
        let restarted = try Rig(files: rig.base.files, data: rig.base.data)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.base.files.read(at: "Groups/TEAM/A.md"), bytes)
        XCTAssertEqual(try restarted.base.libraryOperations.directoryIdentity(at: "Groups/TEAM"), edit.identity)
        XCTAssertNil(try restarted.base.libraryOperations.directoryIdentity(at: temporary))
        XCTAssertEqual(try restarted.state().groups[group]?.folder, "TEAM")
    }

    func testEmptyRenameRejectsReplacementDirectoryOnReplay() throws {
        let rig = try Rig()
        try rig.base.libraryOperations.createDirectory(at: "Groups/Team")
        let owned = try rig.seed(groups: [group: groupState()])
        let plan = try SyncGroupFolders.update([member("New")], state: rig.state(), ownership: owned,
            inventory: rig.inventory(), mutations: rig.base.mutations)
        rig.base.data.failWriteNumber = rig.base.data.writeCount + 3
        XCTAssertThrowsError(try rig.journal.apply(plan))
        // Regardless of progress-save timing, a different destination inode
        // cannot prove this journal's rename happened.
        rig.base.files.directoryIdentities["Groups/New"] = FileStamp("unowned-replacement")
        let restarted = try Rig(files: rig.base.files, data: rig.base.data)
        if case .replanAsConflict = try restarted.journal.replay() {} else { XCTFail("Unowned folder accepted") }
        XCTAssertEqual(try restarted.state().groups[group]?.folder, "Team")
    }

    func testRoleTransitionsRemodeEveryRegularFileWithoutRewritingBytes() throws {
        let rig = try Rig()
        let samples: [(String, Data)] = [
            ("A.md", SyncApplyTestRig.bytes("valid")),
            ("future.md", Data("---\nformat: 999\n---\nFuture".utf8)),
            ("_raw.bin", Data([0xFF, 0, 10]))
        ]
        for (path, bytes) in samples { try rig.base.files.write(bytes, at: "Groups/Team/" + path) }
        var owned = try rig.seed(groups: [group: groupState()])
        for role in [SyncAPI.Role.viewer, .editor, .viewer, .owner] {
            let plan = try SyncGroupFolders.update([member("Team", role: role)], state: rig.state(), ownership: owned,
                inventory: rig.inventory(), mutations: rig.base.mutations)
            XCTAssertEqual(plan.edits.count, samples.count)
            XCTAssertEqual(try rig.journal.apply(plan), .committed)
            for (path, bytes) in samples {
                XCTAssertEqual(try rig.base.files.read(at: "Groups/Team/" + path), bytes)
                XCTAssertEqual(rig.base.libraryOperations.modes[RelativePath("Groups/Team/" + path)], role == .viewer ? .readOnly : .normal)
            }
            owned = try XCTUnwrap(rig.accounts.binding(for: rig.base.binding.root))
        }
    }

    func testViewerReplacementAndInterruptedReplayAlwaysSetExactMode() throws {
        let rig = try Rig()
        let owned = try rig.seed(groups: [group: groupState(role: .viewer)])
        for number in 1...3 {
            let file = try rig.base.mutations.read(at: "Groups/Team/A.md")
            let bytes = SyncApplyTestRig.bytes("version \(number)")
            let edit = try rig.base.mutations.publication(bytes, at: "Groups/Team/A.md", expecting: file,
                transition: SyncIdentityTransition(from: file?.identity, to: .assigned(SyncTestValues.personalPrompt)),
                mode: SyncGroupFolders.mode(for: .group(group), groups: rig.state().groups))
            let state = try rig.state()
            if number == 2 { rig.base.libraryOperations.failFlushNumber = rig.base.libraryOperations.flushCount + 1 }
            let plan = SyncApplyPlan(expectedState: state, nextState: state, edits: [edit])
            if number == 2 {
                XCTAssertThrowsError(try rig.journal.apply(plan))
                try rig.base.libraryOperations.setMode(.normal, at: "Groups/Team/A.md")
                rig.base.libraryOperations.failFlushNumber = nil
                XCTAssertEqual(try rig.journal.replay(), .committed)
            } else { XCTAssertEqual(try rig.journal.apply(plan), .committed) }
            XCTAssertEqual(rig.base.libraryOperations.modes["Groups/Team/A.md"], .readOnly)
            XCTAssertEqual(try rig.base.files.read(at: "Groups/Team/A.md"), bytes)
        }
        let upgrade = try SyncGroupFolders.update([member("Team", role: .editor)], state: rig.state(), ownership: owned,
            inventory: rig.inventory(), mutations: rig.base.mutations)
        XCTAssertEqual(try rig.journal.apply(upgrade), .committed)
        XCTAssertEqual(rig.base.libraryOperations.modes["Groups/Team/A.md"], .normal)
    }

    func testRemovedScopeTrashesOnlyCleanAndRescuesDirtyUnknownAndRaw() throws {
        let rig = try Rig()
        let clean = SyncApplyTestRig.bytes("clean", id: id(30))
        let base = SyncApplyTestRig.bytes("before", id: id(31))
        let dirty = SyncApplyTestRig.bytes("after", id: id(31))
        let unknown = SyncApplyTestRig.bytes("unknown", id: id(32))
        let rawSamples: [(String, Data)] = [
            ("notes.txt", Data("do not inject an ID".utf8)), ("binary.md", Data([0xFF, 0, 10])),
            ("future.md", Data("---\nformat: 999\n---\nFuture".utf8)), ("bad.md", Data("---\na: [\n---\nBad".utf8))
        ]
        try rig.base.files.write(clean, at: "Groups/Team/clean.md")
        try rig.base.files.write(dirty, at: "Groups/Team/dirty.md")
        try rig.base.files.write(unknown, at: "Groups/Team/unknown.md")
        try rig.base.files.put("idless", at: "Groups/Team/idless.md")
        for (path, bytes) in rawSamples { try rig.base.files.write(bytes, at: "Groups/Team/" + path) }
        let records: [PromptIdentity: SyncPromptState] = [
            .assigned(id(30)): try record("clean.md", bytes: clean), .assigned(id(31)): try record("dirty.md", bytes: base)
        ]
        let owned = try rig.seed(groups: [group: groupState(role: .viewer)], prompts: records,
            favorites: [.assigned(id(30)): true])
        let old = try rig.state()
        let plan = try SyncGroupFolders.removed([.group(group)], state: old, ownership: owned,
            inventory: rig.inventory(), at: date, freshID: generator(), mutations: rig.base.mutations)
        let copies = plan.edits.filter { $0.kind == .rescue }
        XCTAssertEqual(copies.count, 7)
        XCTAssertEqual(plan.edits.prefix(copies.count).map(\.kind), Array(repeating: .rescue, count: copies.count))
        XCTAssertNil(plan.nextState.groups[group])
        XCTAssertNil(plan.nextState.cursors[.group(group)])
        XCTAssertEqual(plan.nextState.cursors[.user(SyncTestValues.user)], old.cursors[.user(SyncTestValues.user)])
        XCTAssertEqual(plan.nextState.databaseID, old.databaseID)
        XCTAssertTrue(plan.nextState.favorites.isEmpty)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertEqual(rig.base.libraryOperations.trashed["Groups/Team/clean.md"], clean)
        for copy in copies {
            XCTAssertEqual(try rig.base.files.read(at: copy.path), copy.bytes)
            XCTAssertEqual(rig.base.libraryOperations.modes[RelativePath(copy.path)], .normal)
            XCTAssertEqual(try rig.base.data.read(at: "sync/retained/" + copy.id.uuidString.lowercased() + ".bin"), copy.retainedBytes)
            if copy.heldIssue == nil {
                let fresh = try XCTUnwrap(copy.copyID)
                XCTAssertFalse([id(30), id(31), id(32)].contains { $0.rawValue == fresh })
                XCTAssertEqual(try SyncConflictMetadata.origin(in: XCTUnwrap(copy.bytes), filename: "copy.md"), .rescued)
            } else { XCTAssertEqual(copy.bytes, copy.retainedBytes) }
        }
        XCTAssertNil(try rig.base.libraryOperations.directoryIdentity(at: "Groups/Team"))
        let holds = try rig.journal.heldRescues(in: rig.base.binding.root)
        XCTAssertEqual(holds.count, rawSamples.count)
        var state = try rig.state()
        var scan = try SyncLocalScanner.scan(binding: rig.base.binding, state: state,
            ownership: rig.accounts.binding(for: rig.base.binding.root), retainedRescues: holds,
            availability: .available, freshID: generator(200), mutations: rig.base.mutations)
        if let preparation = scan.preparation {
            XCTAssertEqual(try rig.journal.apply(preparation), .committed)
            state = try rig.state()
            scan = try SyncLocalScanner.scan(binding: rig.base.binding, state: state,
                ownership: rig.accounts.binding(for: rig.base.binding.root), retainedRescues: holds,
                availability: .available, freshID: generator(300), mutations: rig.base.mutations)
        }
        let pushedIDs = scan.changes.compactMap { if case .create(let prompt) = $0 { return prompt.identity }; return nil }
        XCTAssertEqual(pushedIDs.count, 3)
        XCTAssertTrue(Set(pushedIDs).isDisjoint(with: [.assigned(id(30)), .assigned(id(31)), .assigned(id(32))]))
        XCTAssertTrue(scan.orphanFiles.isEmpty)
    }

    func testMovedOutAndRenamedFilesAreRescuedBeforeScopeStateDrops() throws {
        let rig = try Rig()
        let bytes = SyncApplyTestRig.bytes("unchanged", id: id(30))
        try rig.base.files.write(bytes, at: "personal/moved.md")
        let owned = try rig.seed(groups: [group: groupState()], prompts: [.assigned(id(30)): try record("old.md", bytes: bytes)])
        let plan = try SyncGroupFolders.removed([.group(group)], state: rig.state(), ownership: owned,
            inventory: rig.inventory(), at: date, freshID: generator(), mutations: rig.base.mutations)
        XCTAssertEqual(plan.edits.filter { $0.kind == .rescue }.count, 1)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertNil(try rig.base.files.stamp(at: "personal/moved.md"))
        XCTAssertNil(try rig.state().prompts[.assigned(id(30))])
    }

    func testAccessibleMoveMustBeInstalledBeforeRemovedFolderPolicy() throws {
        let rig = try Rig()
        try rig.base.files.write(SyncApplyTestRig.bytes("keep", id: id(30)), at: "Groups/Team/A.md")
        let owned = try rig.seed(groups: [group: groupState()])
        XCTAssertThrowsError(try SyncGroupFolders.removed([.group(group)], state: rig.state(), ownership: owned,
            inventory: rig.inventory(), retainingIDs: [.assigned(id(30))], at: date,
            freshID: generator(), mutations: rig.base.mutations)) {
            XCTAssertEqual($0 as? SyncGroupFolderError, .accessibleInstallationRequired)
        }
        XCTAssertNotNil(try rig.base.files.stamp(at: "Groups/Team/A.md"))
        XCTAssertTrue(rig.base.libraryOperations.trashed.isEmpty)
    }

    func testStaleFoldersLooseFilesAndEmptyDirectoriesPreserveAllBytes() throws {
        let rig = try Rig()
        let known = SyncApplyTestRig.bytes("known")
        try rig.base.files.write(known, at: "Groups/Team/A.md")
        let loose = SyncApplyTestRig.bytes("loose", id: id(30))
        try rig.base.files.write(loose, at: "Groups/loose.md")
        let raw = Data([0, 0xFF])
        try rig.base.files.write(raw, at: "Groups/Old/notes.bin")
        try rig.base.libraryOperations.createDirectory(at: "Groups/Empty")
        try rig.base.files.put("case variant", at: "GROUPS/Other/a.md")
        let owned = try rig.seed(groups: [group: groupState()])
        let plan = try SyncGroupFolders.stale(state: rig.state(), ownership: owned, inventory: rig.inventory(),
            at: date, freshID: generator(), mutations: rig.base.mutations)
        XCTAssertEqual(plan.edits.filter { $0.kind == .rescue }.count, 3)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertEqual(try rig.base.files.read(at: "Groups/Team/A.md"), known)
        XCTAssertNil(try rig.base.libraryOperations.directoryIdentity(at: "Groups/Empty"))
        XCTAssertNil(try rig.base.libraryOperations.directoryIdentity(at: "GROUPS"))
        XCTAssertFalse(try rig.base.files.listFiles().contains { $0.relativePath == "Groups/loose.md" })
        XCTAssertTrue(plan.edits.contains { $0.kind == .rescue && $0.bytes == raw })
    }

    func testForeignOwnedStaleFolderCopiesRemainHeldFromCurrentAccount() throws {
        let rig = try Rig()
        try rig.base.files.write(SyncApplyTestRig.bytes("old account"), at: "Groups/Old/A.md")
        var owned = try rig.seed(groups: [:])
        owned.managedFolders[group] = try SyncManagedFolder(owner: SyncTestValues.account(userID: SyncTestValues.otherUser), folder: "Old")
        try rig.accounts.updateBinding(for: owned.root) { _ in owned }
        let plan = try SyncGroupFolders.stale(state: rig.state(), ownership: owned, inventory: rig.inventory(),
            at: date, freshID: generator(), mutations: rig.base.mutations)
        let copy = try XCTUnwrap(plan.edits.first { $0.kind == .rescue })
        XCTAssertTrue(try XCTUnwrap(plan.bindingChange).next.holds.contains { $0.path == RelativePath(copy.path) })
        XCTAssertEqual(plan.bindingChange?.next.holds.first?.sourceAccount, try SyncTestValues.account(userID: SyncTestValues.otherUser))
    }

    func testAccountChangeRescuesCleanGroupsAndHoldsIdlessPrivateAcrossRenameAndEdit() throws {
        let rig = try Rig()
        let shared = SyncApplyTestRig.bytes("clean", id: id(30))
        try rig.base.files.write(shared, at: "Groups/Team/A.md")
        try rig.base.files.put("private idless", at: "personal.md")
        try rig.base.files.write(SyncApplyTestRig.bytes("private", id: id(31)), at: "existing.md")
        try rig.base.files.write(Data([0xFF]), at: "forensic.md")
        let owned = try rig.seed(groups: [group: groupState()], prompts: [.assigned(id(30)): try record("A.md", bytes: shared)])
        let newAccount = try SyncTestValues.account(userID: SyncTestValues.otherUser)
        let plan = try XCTUnwrap(SyncGroupFolders.accountChange(to: newAccount, state: rig.state(), ownership: owned,
            inventory: rig.inventory(), at: date, freshID: generator(), mutations: rig.base.mutations))
        XCTAssertEqual(plan.edits.filter { $0.kind == .rescue }.count, 1)
        XCTAssertEqual(plan.bindingChange?.next.holds.count, 4)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        let holds = try XCTUnwrap(rig.accounts.binding(for: rig.base.binding.root))
        XCTAssertEqual(holds.owner, newAccount)
        XCTAssertTrue(holds.managedFolders.isEmpty)
        let assigned = try XCTUnwrap(PromptCodec.parseFile(rig.base.files.read(at: "personal.md"), filename: "personal.md").frontMatter.id)
        try rig.base.files.move(from: "personal.md", to: "renamed.md")
        try rig.base.files.write(SyncApplyTestRig.bytes("changed", id: assigned), at: "renamed.md")
        let binding = SyncLibraryIdentity(account: newAccount, root: rig.base.binding.root)
        let scan = try SyncLocalScanner.scan(binding: binding, state: nil, ownership: holds,
            retainedRescues: rig.journal.heldRescues(in: binding.root), availability: .available,
            freshID: generator(200), mutations: rig.base.mutations)
        XCTAssertTrue(scan.changes.isEmpty)
        XCTAssertTrue(scan.snapshot.heldPaths.contains("renamed.md"))
        XCTAssertEqual(try rig.base.files.read(at: "forensic.md"), Data([0xFF]))
    }

    func testAccountChangeAfterSignOutUsesIndependentGroupOwnership() throws {
        let rig = try Rig()
        try rig.base.files.put("group", at: "Groups/Team/A.md")
        let owned = try SyncLibraryBinding(root: rig.base.binding.root, owner: rig.base.binding.account,
            managedFolders: [group: SyncManagedFolder(owner: rig.base.binding.account, folder: "Team")])
        try rig.accounts.updateBinding(for: owned.root) { _ in owned }
        let plan = try XCTUnwrap(SyncGroupFolders.accountChange(to: SyncTestValues.account(userID: SyncTestValues.otherUser),
            state: nil, ownership: owned, inventory: rig.inventory(), at: date, freshID: generator(), mutations: rig.base.mutations))
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertEqual(plan.bindingChange?.next.holds.count, 1)
        XCTAssertNil(try rig.base.files.stamp(at: "Groups/Team/A.md"))
    }

    func testSameAccountReauthenticationKeepsQueuedEdits() throws {
        let rig = try Rig()
        try rig.base.files.put("unsent", at: "a.md")
        let owned = try rig.seed(groups: [:])
        let writes = rig.base.data.writeCount
        XCTAssertNil(try SyncGroupFolders.accountChange(to: rig.base.binding.account, state: rig.state(), ownership: owned,
            inventory: rig.inventory(), at: date, freshID: generator(), mutations: rig.base.mutations))
        XCTAssertEqual(rig.base.data.writeCount, writes)
        XCTAssertEqual(try rig.base.files.text(at: "a.md"), "unsent")
    }

    func testLateUnknownFileBlocksDirectoryRemovalAndStateCommit() throws {
        let rig = try Rig()
        try rig.base.files.put("local", at: "Groups/Team/A.md")
        let owned = try rig.seed(groups: [group: groupState()])
        let old = try rig.state()
        let plan = try SyncGroupFolders.removed([.group(group)], state: old, ownership: owned, inventory: rig.inventory(),
            at: date, freshID: generator(), mutations: rig.base.mutations)
        var added = false
        rig.base.libraryOperations.onOperation = { operation in
            guard operation.hasPrefix("remove-directory:"), !added else { return }
            added = true
            try! rig.base.files.put("late bytes", at: "Groups/Team/late.bin")
        }
        if case .replanAsConflict = try rig.journal.apply(plan) {} else { XCTFail("Late file was ignored") }
        XCTAssertTrue(added)
        XCTAssertEqual(try rig.base.files.text(at: "Groups/Team/late.bin"), "late bytes")
        XCTAssertEqual(try rig.state(), old)
        XCTAssertNotNil(rig.journal.pending)
    }

    func testMaximumJoinedPathAndPrivateRescueCap() throws {
        let rig = try Rig()
        let folder = String(repeating: "f", count: 255)
        let wire = String(repeating: "a", count: 255) + "/" + String(repeating: "b", count: 255) + "/"
            + String(repeating: "c", count: 255) + "/" + String(repeating: "d", count: 251) + "/p.md"
        XCTAssertEqual(wire.utf8.count, 1024)
        let source = "Groups/" + folder + "/" + wire
        XCTAssertEqual(source.utf8.count, 1287)
        try rig.base.files.put("long source", at: source)
        let owned = try rig.seed(groups: [group: SyncGroupState(name: "Team", folder: folder, role: .editor)])
        let plan = try SyncGroupFolders.removed([.group(group)], state: rig.state(), ownership: owned, inventory: rig.inventory(),
            at: date, freshID: generator(), mutations: rig.base.mutations)
        let copy = try XCTUnwrap(plan.edits.first { $0.kind == .rescue })
        XCTAssertLessThanOrEqual(copy.path.utf8.count, 1024)
        XCTAssertEqual(copy.retainedSourcePath, source)
        XCTAssertNoThrow(try SyncPathValidator.validate(copy.path, scope: .user))
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
    }

    func testRemovalRecoversEveryLibraryAndPrivatePersistenceFailureWithoutLosingBytes() throws {
        func prepared() throws -> (Rig, SyncApplyPlan) {
            let rig = try Rig()
            try rig.base.files.write(SyncApplyTestRig.bytes("dirty", id: id(30)), at: "Groups/Team/sub/A.md")
            try rig.base.files.write(Data([0xFF, 0, 10]), at: "Groups/Team/raw.md")
            let owned = try rig.seed(groups: [group: groupState(role: .viewer)])
            let plan = try SyncGroupFolders.removed([.group(group)], state: rig.state(), ownership: owned,
                inventory: rig.inventory(), at: date, freshID: generator(), mutations: rig.base.mutations)
            return (rig, plan)
        }
        let (baseline, basePlan) = try prepared()
        let before = [baseline.base.libraryOperations.operationCount, baseline.base.dataOperations.operationCount, baseline.base.data.writeCount]
        XCTAssertEqual(try baseline.journal.apply(basePlan), .committed)
        let counts = [baseline.base.libraryOperations.operationCount - before[0],
                      baseline.base.dataOperations.operationCount - before[1], baseline.base.data.writeCount - before[2]]
        for kind in counts.indices {
            XCTAssertGreaterThan(counts[kind], 0)
            for fault in 1...counts[kind] {
                let (rig, plan) = try prepared()
                let context = "kind \(kind), operation \(fault)"
                switch kind {
                case 0: rig.base.libraryOperations.failOperationNumber = rig.base.libraryOperations.operationCount + fault
                case 1: rig.base.dataOperations.failOperationNumber = rig.base.dataOperations.operationCount + fault
                default: rig.base.data.failWriteNumber = rig.base.data.writeCount + fault
                }
                XCTAssertThrowsError(try rig.journal.apply(plan), context)
                // Every absent source has a byte-exact preserved destination
                // and permanent raw retention before any trash operation.
                for edit in plan.edits where edit.kind == .rescue {
                    let source = try XCTUnwrap(edit.retainedSourcePath)
                    if try rig.base.files.stamp(at: source) == nil {
                        XCTAssertEqual(try rig.base.files.read(at: edit.path), edit.bytes, context)
                        XCTAssertEqual(try rig.base.data.read(at: "sync/retained/" + edit.id.uuidString.lowercased() + ".bin"), edit.retainedBytes, context)
                    }
                }
                let restarted = try Rig(files: rig.base.files, data: rig.base.data)
                // A failure before intent publication leaves the original intact
                // and permits the identical stable plan to be submitted again.
                if restarted.journal.pending == nil, try restarted.base.states.load(for: restarted.base.binding) == plan.expectedState {
                    XCTAssertEqual(try restarted.journal.apply(plan), .committed, context)
                } else { XCTAssertEqual(try restarted.journal.replay(), .committed, context) }
                XCTAssertEqual(try restarted.journal.replay(), .committed, context)
                XCTAssertEqual(try restarted.state(), plan.nextState, context)
                XCTAssertEqual(try restarted.accounts.binding(for: restarted.base.binding.root), plan.bindingChange?.next, context)
            }
        }
    }

    func testRenameAndDowngradeRecoverEveryLibraryFailure() throws {
        func prepared() throws -> (Rig, SyncApplyPlan) {
            let rig = try Rig()
            try rig.base.files.write(SyncApplyTestRig.bytes("keep"), at: "Groups/Team/sub/A.md")
            try rig.base.files.write(Data([0xFF]), at: "Groups/Team/raw.bin")
            let owned = try rig.seed(groups: [group: groupState()])
            let plan = try SyncGroupFolders.update([member("TEAM", role: .viewer)], state: rig.state(), ownership: owned,
                inventory: rig.inventory(), mutations: rig.base.mutations)
            return (rig, plan)
        }
        let (baseline, basePlan) = try prepared()
        let before = baseline.base.libraryOperations.operationCount
        XCTAssertEqual(try baseline.journal.apply(basePlan), .committed)
        let count = baseline.base.libraryOperations.operationCount - before
        XCTAssertGreaterThan(count, 0)
        for fault in 1...count {
            let (rig, plan) = try prepared()
            rig.base.libraryOperations.failOperationNumber = rig.base.libraryOperations.operationCount + fault
            XCTAssertThrowsError(try rig.journal.apply(plan), "operation \(fault)")
            let restarted = try Rig(files: rig.base.files, data: rig.base.data)
            XCTAssertEqual(try restarted.journal.replay(), .committed, "operation \(fault)")
            XCTAssertEqual(try restarted.journal.replay(), .committed, "operation \(fault)")
            XCTAssertEqual(try restarted.base.files.read(at: "Groups/TEAM/sub/A.md"), SyncApplyTestRig.bytes("keep"))
            XCTAssertEqual(try restarted.base.files.read(at: "Groups/TEAM/raw.bin"), Data([0xFF]))
            XCTAssertEqual(restarted.base.libraryOperations.modes["Groups/TEAM/sub/A.md"], .readOnly)
            XCTAssertEqual(restarted.base.libraryOperations.modes["Groups/TEAM/raw.bin"], .readOnly)
        }
    }

    func testAccountHoldsAreDurableBeforeNewOwnerCanScanAndSurviveBindingFailure() throws {
        let rig = try Rig()
        try rig.base.files.put("idless", at: "private.md")
        try rig.base.files.put("group", at: "Groups/Team/A.md")
        let owned = try rig.seed(groups: [group: groupState()])
        let newOwner = try SyncTestValues.account(userID: SyncTestValues.otherUser)
        let plan = try XCTUnwrap(SyncGroupFolders.accountChange(to: newOwner, state: rig.state(), ownership: owned,
            inventory: rig.inventory(), at: date, freshID: generator(), mutations: rig.base.mutations))
        var fail = true
        rig.base.dataOperations.onOperation = { operation in
            if operation == "file:sync/binding.json", fail {
                fail = false
                rig.base.dataOperations.failOperationNumber = rig.base.dataOperations.operationCount
            }
        }
        XCTAssertThrowsError(try rig.journal.apply(plan))
        XCTAssertThrowsError(try rig.base.library.entries()) {
            XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
        }
        let restarted = try Rig(files: rig.base.files, data: rig.base.data)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        let nextOwnership = try XCTUnwrap(restarted.accounts.binding(for: rig.base.binding.root))
        XCTAssertEqual(nextOwnership.owner, newOwner)
        let scan = try SyncLocalScanner.scan(binding: SyncLibraryIdentity(account: newOwner, root: rig.base.binding.root),
            state: nil, ownership: nextOwnership, availability: .available, freshID: generator(300), mutations: restarted.base.mutations)
        XCTAssertTrue(scan.changes.isEmpty)
        XCTAssertEqual(scan.snapshot.heldPaths.count, 2)
    }

    func testHeldValidGroupRemovalMigratesHoldToFreshPrivateID() throws {
        let rig = try Rig()
        let bytes = SyncApplyTestRig.bytes("held", id: id(30))
        try rig.base.files.write(bytes, at: "Groups/Team/A.md")
        var owned = try rig.seed(groups: [group: groupState()], prompts: [.assigned(id(30)): try record("A.md", bytes: bytes)])
        owned.holds = [try SyncHeldPrompt(identity: .assigned(id(30)), path: "Groups/Team/A.md",
            sourceAccount: rig.base.binding.account, contentHash: SyncHash(bytes: bytes))]
        try rig.accounts.updateBinding(for: owned.root) { _ in owned }
        let plan = try SyncGroupFolders.removed([.group(group)], state: rig.state(), ownership: owned,
            inventory: rig.inventory(), at: date, freshID: generator(), mutations: rig.base.mutations)
        let copy = try XCTUnwrap(plan.edits.first { $0.kind == .rescue })
        let held = try XCTUnwrap(plan.bindingChange?.next.holds.first)
        XCTAssertEqual(held.path, RelativePath(copy.path))
        XCTAssertNotEqual(held.identity, .assigned(id(30)))
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        let scan = try SyncLocalScanner.scan(binding: rig.base.binding, state: rig.state(),
            ownership: rig.accounts.binding(for: rig.base.binding.root), availability: .available,
            freshID: generator(300), mutations: rig.base.mutations)
        XCTAssertTrue(scan.changes.isEmpty)
    }

    func testIdlessFolderRenameKeepsRememberedValuesAndPendingLocalKey() throws {
        let rig = try Rig()
        try rig.base.files.put("{{name}}", at: "Groups/Team/A.md")
        let source = PromptIdentity(path: "Groups/Team/A.md", id: nil)
        let target = PromptIdentity(path: "Groups/New/A.md", id: nil)
        try rig.base.values.record(identity: source, values: ["name": "remembered"])
        try rig.base.usage.recordUse(identity: source, at: date)
        let pending = try SyncPromptState(scope: .group(group), path: "A.md", rev: 0)
        let owned = try rig.seed(groups: [group: groupState()], prompts: [source: pending])
        let plan = try SyncGroupFolders.update([member("New")], state: rig.state(), ownership: owned,
            inventory: rig.inventory(), mutations: rig.base.mutations)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertEqual(try rig.base.values.rememberedValues(for: target), ["name": "remembered"])
        XCTAssertTrue(try rig.base.values.rememberedValues(for: source).isEmpty)
        XCTAssertEqual(try rig.base.usage.useEvents(for: target), [date])
        XCTAssertEqual(try rig.state().prompts[target], pending)
        XCTAssertNil(try rig.state().prompts[source])
        XCTAssertEqual(try rig.base.files.text(at: "Groups/New/A.md"), "{{name}}")
    }

    func testRenameDeduplicatesOccupiedEmptyDestinationAndRejectsLateOccupation() throws {
        for late in [false, true] {
            let rig = try Rig()
            let bytes = SyncApplyTestRig.bytes("keep")
            try rig.base.files.write(bytes, at: "Groups/Team/A.md")
            let owned = try rig.seed(groups: [group: groupState()])
            if !late { try rig.base.libraryOperations.createDirectory(at: "Groups/New") }
            let plan = try SyncGroupFolders.update([member("New")], state: rig.state(), ownership: owned,
                inventory: rig.inventory(), mutations: rig.base.mutations)
            if late {
                try rig.base.libraryOperations.createDirectory(at: "Groups/New")
                if case .replanAsConflict = try rig.journal.apply(plan) {} else { XCTFail("Occupied directory accepted") }
                XCTAssertEqual(try rig.base.files.read(at: "Groups/Team/A.md"), bytes)
                XCTAssertEqual(try rig.state().groups[group]?.folder, "Team")
            } else {
                XCTAssertEqual(plan.nextState.groups[group]?.folder, "New (2)")
                XCTAssertEqual(try rig.journal.apply(plan), .committed)
                XCTAssertEqual(try rig.base.files.read(at: "Groups/New (2)/A.md"), bytes)
            }
            XCTAssertNotNil(try rig.base.libraryOperations.directoryIdentity(at: "Groups/New"))
            XCTAssertNil(try rig.base.files.stamp(at: "Groups/New/A.md"))
        }
    }

    func testInterruptedFolderKeyMigrationMustRecoverBeforeReplanning() throws {
        let rig = try Rig()
        try rig.base.files.put("{{name}}", at: "Groups/Team/A.md")
        let source = PromptIdentity(path: "Groups/Team/A.md", id: nil)
        let target = PromptIdentity(path: "Groups/New/A.md", id: nil)
        try rig.base.values.record(identity: source, values: ["name": "keep"])
        let owned = try rig.seed(groups: [group: groupState()])
        let plan = try SyncGroupFolders.update([member("New")], state: rig.state(), ownership: owned,
            inventory: rig.inventory(), mutations: rig.base.mutations)
        var injected = false
        rig.base.dataOperations.onOperation = { operation in
            guard operation == "file:values.json", !injected else { return }
            injected = true
            rig.base.dataOperations.failOperationNumber = rig.base.dataOperations.operationCount
        }
        XCTAssertThrowsError(try rig.journal.apply(plan))
        XCTAssertTrue(injected)
        let replacement = SyncApplyPlan(expectedState: plan.expectedState, nextState: plan.nextState, edits: [])
        XCTAssertThrowsError(try rig.journal.replan(replacement)) {
            XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
        }
        let restarted = try Rig(files: rig.base.files, data: rig.base.data)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.base.values.rememberedValues(for: target), ["name": "keep"])
        XCTAssertTrue(try restarted.base.values.rememberedValues(for: source).isEmpty)
        XCTAssertEqual(try restarted.base.files.text(at: "Groups/New/A.md"), "{{name}}")
    }

    func testAccountChangeRescuesActualGroupIDLocationOutsideItsFolder() throws {
        let rig = try Rig()
        let bytes = SyncApplyTestRig.bytes("offline move", id: id(30))
        try rig.base.files.write(bytes, at: "moved.md")
        let owned = try rig.seed(groups: [group: groupState()], prompts: [.assigned(id(30)): try record("A.md", bytes: bytes)])
        let plan = try XCTUnwrap(SyncGroupFolders.accountChange(to: SyncTestValues.account(userID: SyncTestValues.otherUser),
            state: rig.state(), ownership: owned, inventory: rig.inventory(), at: date,
            freshID: generator(), mutations: rig.base.mutations))
        let copy = try XCTUnwrap(plan.edits.first { $0.kind == .rescue })
        XCTAssertEqual(copy.retainedSourcePath, "moved.md")
        XCTAssertNotEqual(copy.copyID, id(30).rawValue)
        XCTAssertEqual(try rig.journal.apply(plan), .committed)
        XCTAssertNil(try rig.base.files.stamp(at: "moved.md"))
        XCTAssertTrue(try XCTUnwrap(rig.accounts.binding(for: rig.base.binding.root)).holds.contains { $0.path == RelativePath(copy.path) })
    }

    private func id(_ number: Int) -> ULID {
        let digits = String(number)
        return ULID(String(repeating: "0", count: 26 - digits.count) + digits)!
    }

    private func generator(_ first: Int = 100) -> () throws -> ULID {
        var value = first
        return { defer { value += 1 }; return self.id(value) }
    }

    private func member(_ name: String, id: ULID = SyncTestValues.group, role: SyncAPI.Role = .editor) -> SyncAPI.GroupMembership {
        SyncAPI.GroupMembership(groupID: id.rawValue, name: name, role: role)
    }

    private func groupState(role: SyncAPI.Role = .editor) throws -> SyncGroupState {
        try SyncGroupState(name: "Team", folder: "Team", role: role)
    }

    private func record(_ path: RelativePath, bytes: Data) throws -> SyncPromptState {
        try SyncPromptState(scope: .group(group), path: path, rev: 1,
            canonicalHash: SyncHash(try CanonicalForm.group(bytes, filename: LibraryPath.filename(path.string)).canonicalHash))
    }

    private final class Rig {
        let base: SyncApplyTestRig
        let accounts: SyncAccountStore
        let journal: SyncApplyJournal

        init(files: MemoryFileStore = MemoryFileStore(), data: MemoryFileStore = MemoryFileStore()) throws {
            base = try SyncApplyTestRig(files: files, data: data)
            accounts = SyncAccountStore(files: data, operations: base.dataOperations)
            journal = try SyncApplyJournal(files: data, operations: base.dataOperations, mutations: base.mutations,
                states: base.states, accounts: accounts)
        }

        func state() throws -> SyncState { try XCTUnwrap(base.states.load(for: base.binding)) }

        func seed(groups: [ULID: SyncGroupState], prompts: [PromptIdentity: SyncPromptState] = [:],
                  favorites: [PromptIdentity: Bool] = [:]) throws -> SyncLibraryBinding {
            var cursors = Dictionary(uniqueKeysWithValues: groups.keys.map { (SyncScopeKey.group($0), "group cursor") })
            cursors[.user(SyncTestValues.user)] = "private cursor"
            let old = try SyncState(binding: base.binding, databaseID: SyncTestValues.uuid, cursors: cursors,
                groups: groups, prompts: prompts, favorites: favorites)
            try base.states.update(for: base.binding) { $0 = old }
            let owned = try SyncLibraryBinding(root: base.binding.root, owner: base.binding.account,
                managedFolders: groups.mapValues { try SyncManagedFolder(owner: base.binding.account, folder: $0.folder) })
            try accounts.updateBinding(for: owned.root) { _ in owned }
            return owned
        }

        func inventory(held: Set<RelativePath> = []) throws -> SyncGroupFolderInventory {
            try SyncGroupFolders.inventory(binding: base.binding, availability: .available, heldPaths: held, mutations: base.mutations)
        }
    }
}
