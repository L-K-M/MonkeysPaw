import Foundation
import XCTest
@testable import MonkeysPawCore

final class GroupAccessServiceTests: XCTestCase {
    func testNewLocalGroupFavoriteSurvivesRestartAndIngestWithoutUIByteWrites() throws {
        for initial in [false, true] {
            let rig = try GroupAccessRig(role: .editor)
            let path = "Groups/Team/new.md"
            let document = PromptCodec.parse("---\ntitle: New\nfavorite: \(initial)\n---\nNew body", filename: "new.md")
            let entry = try rig.base.library.create(document, at: path)
            XCTAssertEqual(entry.favorite, initial)
            let bytes = try rig.base.files.read(at: path)
            let writes = rig.base.files.writeCount
            guard case .saved(let starred) = rig.base.library.toggleFavorite(of: entry) else {
                XCTFail("A new group prompt must be favouritable while offline")
                continue
            }
            XCTAssertEqual(starred.favorite, !initial)
            XCTAssertEqual(rig.base.files.writeCount, writes)
            XCTAssertEqual(try rig.base.files.read(at: path), bytes)
            let reopened = SyncStateStore(files: rig.base.data, operations: rig.base.dataOperations)
            let state = try XCTUnwrap(reopened.load(for: rig.base.binding))
            XCTAssertEqual(state.prompts[entry.identity]?.rev, 0)
            XCTAssertNil(state.prompts[entry.identity]?.canonicalHash)
            XCTAssertEqual(state.favorites[entry.identity] == true, !initial)
            let scan = try SyncLocalScanner.scan(binding: rig.base.binding, state: state,
                availability: .available, freshID: { SyncTestValues.personalPrompt }, mutations: rig.base.mutations)
            if let preparation = scan.preparation { XCTAssertEqual(try rig.base.journal.apply(preparation), .committed) }
            XCTAssertEqual(rig.base.states.snapshot.value?.favorites[entry.identity] == true, !initial,
                "Ingest must not undo the newer personal intent with an unchanged raw favourite key")
        }
    }

    func testNeverBoundGroupsRemainOrdinaryLocalFolders() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.put("Local", at: "Groups/Notes/a.md")
        let accounts = SyncAccountStore(files: rig.data, operations: rig.dataOperations)
        let access = try GroupAccessService(library: rig.library, states: rig.states, accounts: accounts, libraryRoot: rig.binding.root.path)
        let entry = try rig.library.load(at: "Groups/Notes/a.md")
        XCTAssertEqual(entry.access, .local)
        XCTAssertNil(try rig.library.loadForEditing(at: entry.relativePath).readOnlyReason)
        _ = try rig.library.save(PromptCodec.parse("Edited", filename: "a.md"), at: entry.relativePath)
        _ = try rig.library.move(from: entry.relativePath, to: "Notes/a.md")
        XCTAssertTrue(access.snapshot.groups.isEmpty)
    }

    func testSignedOutBindingKeepsManagedGroupsReadOnlyAcrossRestart() throws {
        let rig = try GroupAccessRig(role: .viewer)
        try rig.accounts.updateBinding(for: rig.base.binding.root) { _ in
            try SyncLibraryBinding(root: rig.base.binding.root, owner: rig.base.binding.account,
                managedFolders: [SyncTestValues.group: SyncManagedFolder(owner: rig.base.binding.account, folder: "Team")])
        }
        try rig.base.states.clear()
        let restarted = try SyncApplyTestRig(files: rig.base.files, data: rig.base.data)
        let accounts = SyncAccountStore(files: restarted.data, operations: restarted.dataOperations)
        let access = try GroupAccessService(library: restarted.library, states: restarted.states, accounts: accounts,
            libraryRoot: restarted.binding.root.path)
        XCTAssertTrue(access.snapshot.groups.isEmpty)
        XCTAssertEqual(try restarted.library.loadForEditing(at: rig.path).readOnlyReason, .groupUnavailable)
        XCTAssertThrowsError(try restarted.library.save(PromptCodec.parse("Overwrite", filename: "a.md"), at: rig.path))
        XCTAssertEqual(try restarted.files.read(at: rig.path), rig.bytes)
    }

    func testAccountMetadataFailureAndResetRefreshAccessWithoutStateChange() throws {
        let rig = try GroupAccessRig(role: .editor)
        try rig.base.data.put("broken", at: "sync/account.json")
        XCTAssertThrowsError(try rig.accounts.loadAccount())
        XCTAssertTrue(rig.access.snapshot.isBlocked)
        XCTAssertThrowsError(try rig.base.library.create(PromptCodec.parse("Private", filename: "p.md"), at: "p.md"))
        try rig.accounts.resetAccount()
        XCTAssertFalse(rig.access.snapshot.isBlocked)
        XCTAssertNil(try rig.base.library.loadForEditing(at: rig.path).readOnlyReason)
    }

    func testSplitSyncRenameKeepsCleanAndDirtyEditorsAtExistingDestination() throws {
        for dirty in [false, true] {
            let rig = try GroupAccessRig(role: .editor)
            try rig.open()
            let draft = String(decoding: rig.bytes, as: UTF8.self) + "Draft"
            if dirty { rig.ui { rig.model.edit(draft) } }
            let destination = "Groups/Team/other.md"
            try rig.base.files.move(from: rig.path, to: destination)
            try rig.index.apply(.init(created: [RelativePath(destination)]), origin: .sync)
            try rig.index.apply(.init(deleted: [RelativePath(rig.path)]), origin: .sync)
            rig.settle()
            XCTAssertEqual(rig.model.state.prompt?.relativePath, RelativePath(destination))
            if dirty {
                XCTAssertEqual(rig.model.state.source, draft)
                XCTAssertEqual(rig.model.state.conflict?.kind, .modified)
                XCTAssertEqual(rig.model.state.conflict?.origin, .sync)
            } else {
                XCTAssertEqual(rig.model.state.source, String(decoding: rig.bytes, as: UTF8.self))
                XCTAssertNil(rig.model.state.conflict)
            }
        }
    }

    func testEmptyIndexRefreshesAfterStateAndEmptyJournalRecovery() throws {
        for stateFailure in [false, true] {
            let rig = try GroupAccessRig(role: .editor)
            if stateFailure { rig.base.states.blockForRecovery(retaining: rig.base.states.snapshot.value) }
            else { rig.base.library.blockSyncApplyForRecovery() }
            let index = PromptIndex(service: rig.base.library, usage: rig.base.usage, clock: LibraryClock())
            XCTAssertThrowsError(try index.rebuild())
            XCTAssertTrue(index.search("").isEmpty)
            if stateFailure { _ = try rig.base.states.recover(for: rig.base.binding) }
            else { rig.base.library.finishEmptySyncRecovery() }
            XCTAssertEqual(index.search("").count, 1)
            XCTAssertNil(index.lastSyncRefreshFailure)
        }
    }

    func testViewerGuardsEveryLibraryMutationWithoutChangingBytes() throws {
        let rig = try GroupAccessRig(role: .editor)
        let original = try rig.base.library.load(at: rig.path)
        _ = try rig.base.library.save(PromptCodec.parse("Changed", filename: "a.md"), at: rig.path, expectedStamp: original.stamp)
        let revision = try XCTUnwrap(rig.base.library.history(for: original.identity).first)
        try rig.role(.viewer)
        let entry = try rig.base.library.load(at: rig.path)
        let bytes = try rig.base.files.read(at: rig.path)
        let writes = rig.base.files.writeCount
        let mutations: [(String, () throws -> Void)] = [
            ("save stamped", { _ = try rig.base.library.save(entry.document, at: rig.path, expectedStamp: entry.stamp) }),
            ("save overwrite", { _ = try rig.base.library.save(entry.document, at: rig.path) }),
            ("create", { _ = try rig.base.library.create(PromptCodec.parse("New", filename: "a.md"), at: "Groups/Team/new.md") }),
            ("import", { _ = try rig.base.library.createImported(PromptCodec.parse("Imported", filename: "a.md"), at: "Groups/Team/import.md") }),
            ("rename", { _ = try rig.base.library.move(from: rig.path, to: "Groups/Team/renamed.md") }),
            ("move out", { _ = try rig.base.library.move(from: rig.path, to: "private.md") }),
            ("delete stamped", { try rig.base.library.delete(at: rig.path, expectedStamp: entry.stamp) }),
            ("delete overwrite", { try rig.base.library.delete(at: rig.path) }),
            ("restore", { _ = try rig.base.library.restore(revision, at: rig.path) }),
            ("assign identity", { _ = try rig.base.library.assignIdentity(to: rig.path) })
        ]
        for (route, mutate) in mutations {
            XCTAssertThrowsError(try mutate(), route) { XCTAssertEqual($0 as? LibraryError, .accessDenied, route) }
            XCTAssertEqual(try rig.base.files.read(at: rig.path), bytes, route)
        }
        try rig.base.files.put("Private", at: "private.md")
        XCTAssertThrowsError(try rig.base.library.move(from: "private.md", to: "Groups/Team/private.md")) {
            XCTAssertEqual($0 as? LibraryError, .accessDenied)
        }
        XCTAssertEqual(rig.base.files.writeCount, writes + 1)
        XCTAssertEqual(try rig.base.library.loadForEditing(at: rig.path).readOnlyReason, .groupViewer)
    }

    func testViewerCommandsAndOverwriteAreReadOnlyButPrivateCopyIsWritable() throws {
        let rig = try GroupAccessRig(role: .viewer)
        let entry = try rig.base.library.load(at: rig.path)
        guard case .readOnly(.groupViewer) = try rig.base.library.saveForEditing(entry.document, at: rig.path, expectedStamp: nil),
              case .readOnly(.groupViewer) = try rig.base.library.moveForEditing(at: rig.path, to: "other.md", expectedStamp: entry.stamp),
              case .readOnly(.groupViewer) = try rig.base.library.deleteForEditing(at: rig.path, expectedStamp: entry.stamp) else {
            return XCTFail("Viewer editing routes must refuse before mutation")
        }
        let revision = HistoryRevision(identity: entry.identity, filename: "unused", timestamp: Date())
        guard case .readOnly(.groupViewer) = try rig.base.library.restoreForEditing(revision, at: rig.path, expectedStamp: entry.stamp) else {
            return XCTFail("Viewer restore must refuse before reading history")
        }
        let copy = try XCTUnwrap(rig.base.library.createCopyForEditing(entry.document, near: rig.path).committedEntry)
        XCTAssertTrue(copy.relativePath.hasPrefix("Conflicts/Team/"))
        XCTAssertNotEqual(copy.identity, entry.identity)
        XCTAssertEqual(copy.access, .local)
        XCTAssertEqual(try SyncConflictMetadata.origin(in: copy.document), .conflictOf(SyncTestValues.groupPrompt))
        XCTAssertEqual(try rig.base.files.read(at: rig.path), rig.bytes)
    }

    func testEditorAndOwnerCanMutateAndViewerDestinationsRemainDenied() throws {
        for role in [SyncAPI.Role.editor, .owner] {
            let rig = try GroupAccessRig(role: role)
            let entry = try rig.base.library.load(at: rig.path)
            let updated = try rig.base.library.save(PromptCodec.parse("Updated", filename: "a.md"), at: rig.path, expectedStamp: entry.stamp)
            let revision = try XCTUnwrap(rig.base.library.history(for: entry.identity).first)
            _ = try rig.base.library.restore(revision, at: rig.path, expectedStamp: updated.stamp)
            _ = try rig.base.library.move(from: rig.path, to: "Groups/Team/renamed.md")
            _ = try rig.base.library.create(PromptCodec.parse("New", filename: "a.md"), at: "Groups/Team/new.md")
            _ = try rig.base.library.createImported(PromptCodec.parse("Imported", filename: "a.md"), at: "Groups/Team/import.md")
            try rig.base.library.delete(at: "Groups/Team/renamed.md")
            XCTAssertNil(try rig.base.files.stamp(at: "Groups/Team/renamed.md"))
        }
    }

    func testUnknownRemovedAndMovedViewerIdentityCannotBypassPolicy() throws {
        let rig = try GroupAccessRig(role: .viewer)
        XCTAssertThrowsError(try rig.base.library.create(PromptCodec.parse("New", filename: "a.md"), at: "Groups/Unknown/new.md"))
        XCTAssertThrowsError(try rig.base.library.create(PromptCodec.parse("New", filename: "a.md"), at: "GROUPS/team/new.md"))
        try rig.base.files.move(from: rig.path, to: "outside.md")
        XCTAssertThrowsError(try rig.base.library.save(PromptCodec.parse("Overwrite", filename: "a.md"), at: "outside.md"))
        XCTAssertThrowsError(try rig.base.library.delete(at: "outside.md"))
        try rig.removeMembership()
        XCTAssertThrowsError(try rig.base.library.save(PromptCodec.parse(String(decoding: rig.bytes, as: UTF8.self), filename: "a.md"), at: "outside.md"))
        XCTAssertThrowsError(try rig.base.library.create(PromptCodec.parse("New", filename: "a.md"), at: rig.path))
        XCTAssertEqual(try rig.base.files.read(at: "outside.md"), rig.bytes)
    }

    func testExternallyMovedEditorPromptHonorsViewerOrUnmappedDestination() throws {
        for destination in ["Groups/ReadOnly/a.md", "Groups/Unmapped/a.md"] {
            let rig = try GroupAccessRig(role: .editor)
            try rig.base.states.update(for: rig.base.binding) {
                $0.groups[SyncTestValues.otherUser] = try SyncGroupState(name: "ReadOnly", folder: "ReadOnly", role: .viewer)
            }
            try rig.base.files.move(from: rig.path, to: destination)
            let entry = try rig.base.library.load(at: destination)
            XCTAssertNotNil(entry.access.readOnlyReason)
            XCTAssertThrowsError(try rig.base.library.save(entry.document, at: destination)) {
                XCTAssertEqual($0 as? LibraryError, .accessDenied)
            }
            XCTAssertThrowsError(try rig.base.library.delete(at: destination)) {
                XCTAssertEqual($0 as? LibraryError, .accessDenied)
            }
            XCTAssertEqual(try rig.base.files.read(at: destination), rig.bytes)
        }
    }

    func testViewerFavoritePersistsWithoutByteModeStampOrHistoryWrites() throws {
        let rig = try GroupAccessRig(role: .viewer)
        try rig.base.libraryOperations.setMode(.readOnly, at: RelativePath(rig.path))
        let before = try rig.base.library.load(at: rig.path)
        let writes = rig.base.files.writeCount
        let operations = rig.base.libraryOperations.operationCount
        guard case .saved(let starred) = rig.base.library.toggleFavorite(of: before) else { return XCTFail("Overlay toggle failed") }
        XCTAssertTrue(starred.favorite)
        XCTAssertFalse(starred.document.frontMatter.favorite)
        XCTAssertEqual(starred.stamp, before.stamp)
        XCTAssertEqual(try rig.base.files.read(at: rig.path), rig.bytes)
        XCTAssertEqual(rig.base.files.writeCount, writes)
        XCTAssertEqual(rig.base.libraryOperations.operationCount, operations)
        XCTAssertEqual(rig.base.libraryOperations.modes[RelativePath(rig.path)], .readOnly)
        XCTAssertEqual(try rig.base.library.history(for: starred.identity), [])
        let restarted = SyncStateStore(files: rig.base.data, operations: rig.base.dataOperations)
        XCTAssertEqual(try restarted.load(for: rig.base.binding)?.favorites[starred.identity], true)
        guard case .saved(let unstarred) = rig.base.library.toggleFavorite(of: starred) else { return XCTFail("Unstar failed") }
        XCTAssertFalse(unstarred.favorite)
        XCTAssertNil(rig.base.states.snapshot.value?.favorites[starred.identity])
        XCTAssertEqual(try rig.base.files.read(at: rig.path), rig.bytes)
    }

    func testOverlayRefreshesDirtyEditorBrowserCountsAndRanking() throws {
        let rig = try GroupAccessRig(role: .editor)
        try rig.open()
        let dirty = String(decoding: rig.bytes, as: UTF8.self) + "Unsaved"
        rig.ui { rig.model.edit(dirty) }
        let browser = LibraryBrowserModel(index: rig.index, usage: rig.base.usage, favorites: rig.base.library,
            main: rig.main, editor: rig.model)
        let row = try XCTUnwrap(browser.rows.first)
        browser.selectPrompt(row.selection)
        browser.selectSection(.favourites)
        XCTAssertEqual(browser.rows.count, 0)
        let writes = rig.base.files.writeCount
        guard case .saved = browser.toggleFavorite() else { return XCTFail("Dirty group toggle must use overlay") }
        rig.settle()
        XCTAssertEqual(rig.model.state.source, dirty)
        XCTAssertTrue(rig.model.state.isDirty)
        XCTAssertNil(rig.model.state.conflict)
        XCTAssertEqual(browser.rows.count, 1)
        XCTAssertEqual(browser.sections.first { $0.id == .favourites }?.count, 1)
        XCTAssertEqual(browser.sections.first { $0.id == .group(SyncTestValues.group) }?.role, .editor)
        XCTAssertEqual(browser.sections.first { $0.id == .group(SyncTestValues.group) }?.count, 1)
        XCTAssertFalse(browser.sections.contains { if case .folder(let path) = $0.id { return path.string == "Groups" }; return false })
        XCTAssertTrue(try XCTUnwrap(rig.index.search("").first).entry.favorite)
        let starredScore = try XCTUnwrap(rig.index.search("Exact").first).score
        _ = browser.toggleFavorite()
        rig.settle()
        XCTAssertGreaterThan(starredScore, try XCTUnwrap(rig.index.search("Exact").first).score)
        XCTAssertEqual(rig.base.files.writeCount, writes)
    }

    func testPickerUsesOverlayAndRefreshesWithoutReopening() throws {
        let h = PromptFlowHarness()
        let bytes = try GroupAccessRig.content()
        try h.library.write(bytes, at: "Groups/Team/a.md")
        let operations = MemorySyncFileOperations(files: h.data)
        let states = SyncStateStore(files: h.data, operations: operations)
        let binding = try SyncTestValues.binding()
        try states.update(for: binding) { $0 = try GroupAccessRig.state(binding: binding, bytes: bytes, role: .viewer) }
        let accounts = SyncAccountStore(files: h.data, operations: operations)
        let access = try GroupAccessService(library: h.service, states: states, accounts: accounts, libraryRoot: binding.root.path)
        try h.open()
        XCTAssertFalse(try XCTUnwrap(h.picker.results.first).favorite)
        _ = h.service.toggleFavorite(of: try h.service.load(at: "Groups/Team/a.md"))
        h.settle()
        XCTAssertTrue(try XCTUnwrap(h.picker.results.first).favorite)
        XCTAssertEqual(try h.library.read(at: "Groups/Team/a.md"), bytes)
        XCTAssertEqual(access.snapshot.groups.count, 1)
    }

    func testAccountAndServerSwitchClearOverlayAndRejectOldEntry() throws {
        for binding in [try SyncTestValues.binding(userID: SyncTestValues.otherUser),
                        try SyncTestValues.binding(server: "https://other.test")] {
            let rig = try GroupAccessRig(role: .viewer)
            let old = try rig.base.library.load(at: rig.path)
            _ = rig.base.library.toggleFavorite(of: old)
            XCTAssertTrue(try rig.base.library.load(at: rig.path).favorite)
            try rig.base.states.reset(for: binding)
            try rig.base.states.update(for: binding) { $0 = try GroupAccessRig.state(binding: binding, bytes: rig.bytes, role: .viewer) }
            XCTAssertFalse(try rig.base.library.load(at: rig.path).favorite)
            guard case .libraryFailure(.accessDenied) = rig.base.library.toggleFavorite(of: old) else {
                return XCTFail("An old account row must not edit the next account's overlay")
            }
            XCTAssertTrue(try XCTUnwrap(rig.base.states.snapshot.value).favorites.isEmpty)
            try rig.base.states.clear()
            XCTAssertFalse(try rig.base.library.load(at: rig.path).favorite)
            XCTAssertEqual(try rig.base.library.loadForEditing(at: rig.path).readOnlyReason, .groupUnavailable)
        }
    }

    func testRootMismatchAndCorruptStateFailClosed() throws {
        let rig = try GroupAccessRig(role: .editor)
        let other = try SyncTestValues.binding(root: "/other")
        try rig.base.states.reset(for: other)
        XCTAssertTrue(rig.access.snapshot.isBlocked)
        XCTAssertThrowsError(try rig.base.library.save(PromptCodec.parse("Private", filename: "a.md"), at: "private.md")) {
            XCTAssertEqual($0 as? LibraryError, .syncUnavailable)
        }
        try rig.base.states.reset(for: rig.base.binding)
        try rig.base.data.put("broken", at: "sync/state.json")
        XCTAssertThrowsError(try rig.base.states.load(for: rig.base.binding))
        XCTAssertTrue(rig.access.snapshot.isBlocked)
        XCTAssertThrowsError(try rig.base.library.delete(at: rig.path))
        XCTAssertEqual(try rig.base.files.read(at: rig.path), rig.bytes)
    }

    func testQueuedSaveDowngradeAndRemovalKeepDraftAndDenyPublication() throws {
        for removed in [false, true] {
            let rig = try GroupAccessRig(role: .editor, held: true, queued: true)
            try rig.open()
            let dirty = String(decoding: rig.bytes, as: UTF8.self) + "Never auto upload"
            rig.ui { rig.model.edit(dirty); rig.model.save() }
            if removed { try rig.removeMembership() }
            else { try rig.role(.viewer) }
            rig.settle()
            XCTAssertEqual(try rig.base.files.read(at: rig.path), rig.bytes)
            XCTAssertEqual(rig.model.state.source, dirty)
            XCTAssertTrue(rig.model.state.isDirty)
            XCTAssertFalse(rig.model.state.canEdit)
            XCTAssertTrue(rig.model.state.canSaveAsCopy)
            XCTAssertEqual(rig.model.state.readOnlyReason, removed ? .groupUnavailable : .groupViewer)
            rig.ui { rig.model.saveAsCopy() }
            rig.settle()
            let copy = try XCTUnwrap(rig.model.state.lastCopy)
            XCTAssertTrue(copy.relativePath.string.hasPrefix("Conflicts/"))
            XCTAssertNotEqual(copy.identity, .assigned(SyncTestValues.groupPrompt))
            XCTAssertTrue(try rig.base.library.load(at: copy.relativePath.string).document.body.hasSuffix("Never auto upload"))
        }
    }

    func testRoleNotificationPreservesDirtyBufferAndCurrentMainThreadPolicy() throws {
        let rig = try GroupAccessRig(role: .editor, queued: true)
        try rig.open()
        let dirty = String(decoding: rig.bytes, as: UTF8.self) + "Draft"
        rig.ui { rig.model.edit(dirty) }
        try rig.role(.viewer)
        try rig.role(.owner)
        rig.settle()
        XCTAssertEqual(rig.model.state.source, dirty)
        XCTAssertTrue(rig.model.state.isDirty)
        XCTAssertTrue(rig.model.state.canEdit)
        XCTAssertEqual(rig.model.assistantAccess, .group(.owner))
        XCTAssertNil(rig.model.state.conflict)
    }

    func testDirtyRemoteOverwriteRenameAndDeleteKeepBufferAndUsePrivateCopies() throws {
        for action in ["overwrite", "rename", "delete"] {
            let rig = try GroupAccessRig(role: .editor)
            try rig.open()
            let dirty = String(decoding: rig.bytes, as: UTF8.self) + "Unsaved only"
            rig.ui { rig.model.edit(dirty) }
            try rig.remote(action)
            rig.settle()
            XCTAssertEqual(rig.model.state.source, dirty, action)
            XCTAssertTrue(rig.model.state.isDirty, action)
            XCTAssertEqual(rig.model.state.conflict?.origin, .sync, action)
            if action == "rename" { XCTAssertEqual(rig.model.state.prompt?.relativePath, "Groups/Team/renamed.md") }
            if action == "delete" { XCTAssertFalse(rig.model.state.conflict?.choices.contains(.keepMine) == true) }
            let beforeCopy = rig.base.files.writeCount
            rig.ui { rig.model.resolveConflict(.saveAsCopy) }
            rig.settle()
            let copy = try XCTUnwrap(rig.model.state.lastCopy)
            XCTAssertTrue(copy.relativePath.string.hasPrefix("Conflicts/"), action)
            XCTAssertEqual(rig.base.files.writeCount, beforeCopy + 1, action)
            XCTAssertTrue(try rig.base.library.load(at: copy.relativePath.string).document.body.hasSuffix("Unsaved only"))
            if action != "delete" {
                let serverPath = action == "rename" ? "Groups/Team/renamed.md" : rig.path
                XCTAssertEqual(try rig.base.files.read(at: serverPath), try GroupAccessRig.content("Server"))
            }
        }
    }

    func testCleanRemoteRenameFollowsIdentity() throws {
        let rig = try GroupAccessRig(role: .editor)
        try rig.open()
        try rig.remote("rename")
        rig.settle()
        XCTAssertEqual(rig.model.state.prompt?.relativePath, "Groups/Team/renamed.md")
        XCTAssertNil(rig.model.state.conflict)
        XCTAssertFalse(rig.model.state.isDirty)
        XCTAssertEqual(rig.model.state.source, String(decoding: try GroupAccessRig.content("Server"), as: UTF8.self))
    }

    func testAssistantViewerCanCreatePrivateCopyButCannotAcceptInGroup() throws {
        for destination in [AssistantSaveDestination.improve, .newPrompt, .privateCopy] {
            let rig = try GroupAccessRig(role: .viewer, held: true)
            try rig.open()
            let source = try XCTUnwrap(rig.model.assistantSnapshot)
            let prepared = try rig.prepared(improve: destination == .improve)
            var results: [AssistantAcceptanceOutcome] = []
            rig.ui { rig.editing.accept(prepared, source: source, destination: destination) { results.append($0) } }
            rig.settle()
            XCTAssertEqual(results.count, 1)
            let outcome = try XCTUnwrap(results.first)
            if destination == .privateCopy {
                let copy = try XCTUnwrap(outcome.committed?.entry)
                XCTAssertEqual(copy.access, .local)
                XCTAssertFalse(copy.relativePath.hasPrefix("Groups/"))
                XCTAssertEqual(try rig.base.files.read(at: copy.relativePath), prepared.content.canonicalBytes)
            } else { XCTAssertNil(outcome.committed) }
            XCTAssertEqual(try rig.base.files.read(at: rig.path), rig.bytes)
        }
    }

    func testQueuedAssistantAcceptanceInvalidatedAcrossDowngradeAndUpgrade() throws {
        let rig = try GroupAccessRig(role: .editor, held: true, queued: true)
        try rig.open()
        let source = try XCTUnwrap(rig.model.assistantSnapshot)
        let prepared = try rig.prepared(improve: true)
        var results: [AssistantAcceptanceOutcome] = []
        rig.ui { rig.editing.accept(prepared, source: source, destination: .improve) { results.append($0) } }
        try rig.role(.viewer)
        try rig.role(.editor)
        rig.settle()
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first?.committed)
        XCTAssertEqual(try rig.base.files.read(at: rig.path), rig.bytes)
        XCTAssertNotEqual(rig.model.assistantSnapshot?.accessGeneration, source.accessGeneration)
    }

    func testCommittedModeChangeRefreshesOpenDirtyEditorWithoutRewrite() throws {
        let rig = try GroupAccessRig(role: .editor)
        try rig.open()
        let dirty = String(decoding: rig.bytes, as: UTF8.self) + "Draft"
        rig.ui { rig.model.edit(dirty) }
        let old = try XCTUnwrap(rig.base.states.snapshot.value)
        var next = old
        next.groups[SyncTestValues.group] = try SyncGroupState(name: "Team", folder: "Team", role: .viewer)
        let file = try XCTUnwrap(rig.base.mutations.read(at: RelativePath(rig.path)))
        let mode = try rig.base.mutations.mode(.readOnly, for: file)
        let writes = rig.base.files.writeCount
        XCTAssertEqual(try rig.base.journal.apply(SyncApplyPlan(expectedState: old, nextState: next, edits: [mode])), .committed)
        rig.settle()
        XCTAssertEqual(rig.base.libraryOperations.modes[RelativePath(rig.path)], .readOnly)
        XCTAssertEqual(rig.base.files.writeCount, writes)
        XCTAssertEqual(rig.model.state.source, dirty)
        XCTAssertEqual(rig.model.state.readOnlyReason, .groupViewer)
        XCTAssertNil(rig.model.state.conflict)
    }

    func testPersonalSyncDeletionKeepsDirtyTextAndCannotRecreateRetiredID() throws {
        let rig = try GroupAccessRig(role: .editor)
        let source = SyncApplyTestRig.bytes("Personal")
        try rig.base.files.write(source, at: "personal.md")
        try rig.base.states.update(for: rig.base.binding) {
            $0.prompts[.assigned(SyncTestValues.personalPrompt)] = try SyncPromptState(scope: .user(SyncTestValues.user),
                path: "personal.md", rev: 1, canonicalHash: SyncHash(bytes: source))
        }
        try rig.index.rebuild()
        let entry = try rig.base.library.load(at: "personal.md")
        rig.ui { rig.model.open(.init(identity: entry.identity, relativePath: "personal.md")) }
        rig.settle()
        let dirty = String(decoding: source, as: UTF8.self) + "Dirty personal"
        rig.ui { rig.model.edit(dirty) }
        let old = try XCTUnwrap(rig.base.states.snapshot.value)
        var next = old
        next.prompts[entry.identity] = nil
        let file = try XCTUnwrap(rig.base.mutations.read(at: "personal.md"))
        XCTAssertEqual(try rig.base.journal.apply(.init(expectedState: old, nextState: next,
            edits: [rig.base.mutations.trash(file)])), .committed)
        rig.settle()
        XCTAssertEqual(rig.model.state.source, dirty)
        XCTAssertFalse(rig.model.state.conflict?.choices.contains(.keepMine) == true)
        rig.ui { rig.model.save() }
        rig.settle()
        XCTAssertEqual(rig.model.state.conflict?.origin, .sync)
        XCTAssertFalse(rig.model.state.conflict?.choices.contains(.keepMine) == true)
        rig.ui { rig.model.resolveConflict(.saveAsCopy) }
        rig.settle()
        XCTAssertTrue(try XCTUnwrap(rig.model.state.lastCopy).relativePath.string.hasPrefix("Conflicts/Personal/"))
        XCTAssertNil(try rig.base.files.stamp(at: "personal.md"))
    }

    func testFavoriteFailureKeepsPriorOverlayAndRejectsPendingApply() throws {
        let rig = try GroupAccessRig(role: .viewer)
        let entry = try rig.base.library.load(at: rig.path)
        rig.base.data.failNextWrite = true
        XCTAssertNil(rig.base.library.toggleFavorite(of: entry).savedEntry)
        XCTAssertTrue(try XCTUnwrap(rig.base.states.snapshot.value).favorites.isEmpty)
        XCTAssertFalse(try XCTUnwrap(rig.index.search("").first).entry.favorite)
        let state = try XCTUnwrap(rig.base.states.snapshot.value)
        let permit = UUID()
        try rig.base.library.beginSyncApply(permit, nextState: state)
        guard case .libraryFailure(.recoveryRequired) = rig.base.library.toggleFavorite(of: entry) else {
            return XCTFail("An active apply must fence overlay writes")
        }
        rig.base.library.endSyncApply(permit)
        XCTAssertEqual(try rig.base.files.read(at: rig.path), rig.bytes)
    }

    func testSyncEnginePublishesRolesModesAndOverlayWithoutUpload() async throws {
        let rig = try SyncServiceRig()
        let index = PromptIndex(service: rig.base.library, usage: rig.base.usage, clock: LibraryClock())
        let access = try GroupAccessService(library: rig.base.library, states: rig.base.states, accounts: rig.accounts, libraryRoot: rig.base.binding.root.path)
        let bytes = try GroupAccessRig.content()
        rig.transport.handler = { index, request in
            XCTAssertEqual(request.method, .post, "Neither a role mode nor an overlay may issue a PUT")
            let group = SyncAPI.SyncScope(identity: .group(groupID: SyncTestValues.group.rawValue, name: "Team",
                role: index == 0 ? .editor : .viewer), mode: .snapshot, head: 1, cursor: "group", hasMore: false,
                items: [.upsert(seq: 1, prompt: .init(id: SyncTestValues.groupPrompt.rawValue, rev: 1, path: "a.md",
                    content: String(decoding: bytes, as: UTF8.self)))])
            return try SyncServiceRig.pull(groups: [group])
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(index.search("").count, 1)
        rig.service.syncNow()
        await rig.settle()
        XCTAssertEqual(access.snapshot.groups[SyncTestValues.group]?.role, .viewer)
        XCTAssertEqual(rig.base.libraryOperations.modes["Groups/Team/a.md"], .readOnly)
        let requests = rig.transport.requests.count
        _ = rig.base.library.toggleFavorite(of: try rig.base.library.load(at: "Groups/Team/a.md"))
        XCTAssertEqual(rig.transport.requests.count, requests)
        XCTAssertTrue(try XCTUnwrap(index.search("").first).entry.favorite)
        rig.service.syncNow()
        await rig.settle()
        XCTAssertTrue(try XCTUnwrap(index.search("").first).entry.favorite)
        XCTAssertEqual(try rig.base.files.read(at: "Groups/Team/a.md"), bytes)
        rig.service.stop()
        await rig.service.drain()
    }

    func testSyncRenameFollowsIdentityAssignedByOpenEditorFirstSave() throws {
        let rig = try GroupAccessRig(role: .editor)
        try rig.base.files.put("Local", at: "local.md")
        try rig.index.rebuild()
        let unassigned = try rig.base.library.load(at: "local.md")
        rig.ui { rig.model.open(.init(identity: unassigned.identity, relativePath: "local.md")) }
        rig.settle()
        rig.ui { rig.model.edit("Saved locally"); rig.model.save() }
        rig.settle()
        let entry = try rig.base.library.load(at: "local.md")
        let bytes = try rig.base.files.read(at: "local.md")
        try rig.base.states.update(for: rig.base.binding) {
            $0.prompts[entry.identity] = try SyncPromptState(scope: .user(SyncTestValues.user), path: "local.md",
                rev: 1, canonicalHash: SyncHash(bytes: bytes))
        }
        let old = try XCTUnwrap(rig.base.states.snapshot.value)
        var next = old
        next.prompts[entry.identity] = try SyncPromptState(scope: .user(SyncTestValues.user), path: "remote.md",
            rev: 2, canonicalHash: SyncHash(bytes: bytes))
        let file = try XCTUnwrap(rig.base.mutations.read(at: "local.md"))
        let create = try rig.base.mutations.publication(bytes, at: "remote.md", expecting: nil,
            transition: SyncIdentityTransition(from: nil, to: entry.identity))
        XCTAssertEqual(try rig.base.journal.apply(.init(expectedState: old, nextState: next,
            edits: [rig.base.mutations.trash(file), create])), .committed)
        rig.settle()
        XCTAssertEqual(rig.model.state.prompt?.relativePath, "remote.md")
        XCTAssertNil(rig.model.state.conflict)
    }
}

private extension PromptFavoriteOutcome {
    var savedEntry: LibraryEntry? { if case .saved(let entry) = self { return entry }; return nil }
}

private final class GroupAccessRig {
    let base: SyncApplyTestRig
    let marker = EditingThreadMarker()
    let main: EditingMainThread
    let work: HeldBackgroundWork
    let index: PromptIndex
    let editing: PromptEditingService
    let model: EditorModel
    let access: GroupAccessService
    let accounts: SyncAccountStore
    let path = "Groups/Team/a.md"
    let bytes: Data

    init(role: SyncAPI.Role, held: Bool = false, queued: Bool = false) throws {
        let base = try SyncApplyTestRig()
        self.base = base
        let bytes = try Self.content()
        self.bytes = bytes
        try base.files.write(bytes, at: path)
        try base.states.update(for: base.binding) { $0 = try Self.state(binding: base.binding, bytes: bytes, role: role) }
        accounts = SyncAccountStore(files: base.data, operations: base.dataOperations)
        access = try GroupAccessService(library: base.library, states: base.states, accounts: accounts, libraryRoot: base.binding.root.path)
        main = EditingMainThread(marker)
        main.isHeld = queued
        work = HeldBackgroundWork(marker)
        index = PromptIndex(service: base.library, usage: base.usage, clock: LibraryClock())
        editing = PromptEditingService(library: base.library, index: index,
            work: held ? work : InlineBackgroundWork(marker), main: main)
        model = EditorModel(editing: editing, clock: LibraryClock(), timeZone: { .gmt }, main: main)
        try index.rebuild()
    }

    static func content(_ body: String = "Original") throws -> Data {
        try CanonicalForm.group(SyncApplyTestRig.bytes(body, id: SyncTestValues.groupPrompt), filename: "a.md").bytes
    }

    static func state(binding: SyncLibraryIdentity, bytes: Data, role: SyncAPI.Role) throws -> SyncState {
        try SyncState(binding: binding, groups: [SyncTestValues.group: SyncGroupState(name: "Team", folder: "Team", role: role)],
            prompts: [.assigned(SyncTestValues.groupPrompt): SyncPromptState(scope: .group(SyncTestValues.group),
                path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: bytes))])
    }

    func ui(_ operation: () -> Void) { marker.ui(operation) }
    func settle() {
        for _ in 0..<1_000 {
            if work.pending.isEmpty && main.pending.isEmpty { return }
            if !work.pending.isEmpty { work.releaseNext() }
            if !main.pending.isEmpty { main.releaseNext() }
        }
        XCTFail("Queues failed to settle")
    }
    func open() throws {
        let entry = try base.library.load(at: path)
        ui { model.open(LibraryPromptSelection(identity: entry.identity, relativePath: RelativePath(path))) }
        settle()
    }
    func role(_ role: SyncAPI.Role) throws {
        try base.states.update(for: base.binding) {
            $0.groups[SyncTestValues.group] = try SyncGroupState(name: "Team", folder: "Team", role: role)
        }
    }
    func removeMembership() throws {
        try base.states.update(for: base.binding) { $0 = try SyncState(binding: base.binding) }
    }
    func remote(_ action: String) throws {
        let old = try XCTUnwrap(base.states.snapshot.value)
        var next = old
        let source = try XCTUnwrap(base.mutations.read(at: RelativePath(path)))
        var edits: [SyncLibraryEdit] = []
        if action != "overwrite" { edits.append(try base.mutations.trash(source)) }
        if action == "delete" { next.prompts[.assigned(SyncTestValues.groupPrompt)] = nil }
        else {
            let newPath: RelativePath = action == "rename" ? "Groups/Team/renamed.md" : RelativePath(path)
            let bytes = try Self.content("Server")
            edits.append(try base.mutations.publication(bytes, at: newPath, expecting: action == "rename" ? nil : source,
                transition: SyncIdentityTransition(from: action == "rename" ? nil : source.identity,
                    to: .assigned(SyncTestValues.groupPrompt))))
            next.prompts[.assigned(SyncTestValues.groupPrompt)] = try SyncPromptState(scope: .group(SyncTestValues.group),
                path: action == "rename" ? "renamed.md" : "a.md", rev: 2, canonicalHash: SyncHash(bytes: bytes))
        }
        XCTAssertEqual(try base.journal.apply(SyncApplyPlan(expectedState: old, nextState: next, edits: edits)), .committed)
    }
    func prepared(improve: Bool) throws -> AssistantPreparedSave {
        let artifact = LlmArtifact(title: "Candidate", description: "", tags: [], fields: [], body: "Assistant", notes: "")
        let result = improve ? ArtifactMerge.improve(artifact, original: try XCTUnwrap(model.assistantSnapshot).document)
            : ArtifactMerge.write(artifact, id: SyncTestValues.personalPrompt)
        guard case .ready(let content) = result else { throw EditingTestError.unexpectedOutcome }
        return AssistantPreparedSave(content: content,
            metadata: AssistantSaveMetadata(providerHost: "example.test", model: "test", usage: nil), permit: AssistantSavePermit())
    }
}
