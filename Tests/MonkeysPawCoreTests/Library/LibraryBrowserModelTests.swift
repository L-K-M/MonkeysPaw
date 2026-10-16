import Foundation
import XCTest
@testable import MonkeysPawCore

final class LibraryBrowserModelTests: XCTestCase {
    func testConflictsFilterUsesValidOriginThroughRenameAndMarkerRemoval() throws {
        let h = PromptFlowHarness()
        let original = SyncTestValues.personalPrompt
        let copyID = SyncTestValues.device
        let marked = try SyncConflictMetadata.settingOrigin(.conflictOf(original), in:
            SyncScanTestSupport.bytes("Losing bytes", id: copyID), filename: "copy.md")
        _ = try h.put(String(decoding: marked, as: UTF8.self), at: "from-another-device.md")
        _ = try h.put("Ordinary content", at: "Conflicts/Personal/ordinary (conflict Desktop 2026-10-14 1200).md")
        _ = try h.put("---\nx-monkeyspaw-conflict-of: false\n---\nInvalid marker", at: "invalid.md")
        _ = try h.put("---\nx-monkeyspaw-rescued: true\n---\nRescued", at: "rescued.md")
        try h.index.rebuild()
        let model = browser(h)
        model.selectSection(.conflicts)
        XCTAssertEqual(model.rows.map(\.relativePath), ["from-another-device.md", "rescued.md"])
        XCTAssertEqual(model.rows.first?.conflictOf, original)
        model.selectPrompt(model.rows.first?.selection)
        try h.library.move(from: "from-another-device.md", to: "ordinary-name.md")
        try h.index.rebuild(origin: .sync)
        XCTAssertEqual(model.rows.map(\.relativePath), ["ordinary-name.md", "rescued.md"])
        XCTAssertEqual(model.selectedEntry?.relativePath, "ordinary-name.md")
        XCTAssertEqual(count(.conflicts, in: model), 2)
        model.setFilter("no match")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(count(.conflicts, in: model), 2)
        let cleared = try SyncConflictMetadata.settingOrigin(nil, in: marked, filename: "ordinary-name.md")
        try h.library.write(cleared, at: "ordinary-name.md")
        try h.index.rebuild(origin: .sync)
        XCTAssertEqual(count(.conflicts, in: model), 1)
    }

    func testSectionsCountsNestedFoldersAndNormalizedTagsIncludeAllStates() throws {
        let h = PromptFlowHarness()
        _ = try h.put("---\ntitle: Alpha\ntags: [CODE, code, review]\nfavorite: true\n---\nBody", at: "work/deep/a.md")
        _ = try h.put("---\ntitle: Beta\ntags: [code]\n---\nBody", at: "work/b.md")
        _ = try h.put("---\nformat: 2\ntags: [future]\n---\nBody", at: "work/deep/future.md")
        _ = try h.put("---\ntitle: [broken\n---\nBody", at: "invalid.md")
        _ = try h.put("Root", at: "root.md")
        try h.index.rebuild()
        let model = browser(h)

        XCTAssertEqual(Array(model.sections.prefix(3)).map(\.id), [.all, .favourites, .recent])
        XCTAssertEqual(count(.all, in: model), 5)
        XCTAssertEqual(count(.favourites, in: model), 1)
        XCTAssertEqual(count(.recent, in: model), 0)
        XCTAssertEqual(count(.folder("work"), in: model), 3)
        XCTAssertEqual(count(.folder("work/deep"), in: model), 2)
        XCTAssertEqual(count(.tag("code"), in: model), 2, "Repeated normalized tags count each entry once")
        let nested = try XCTUnwrap(model.sections.first { $0.id == .folder("work/deep") })
        XCTAssertEqual(nested.parent, .folder("work"))
        XCTAssertEqual(nested.depth, 1)
        let future = try XCTUnwrap(model.rows.first { $0.relativePath == "work/deep/future.md" })
        XCTAssertTrue(future.isReadOnly)
        XCTAssertFalse(future.canRender)
        XCTAssertFalse(future.issues.isEmpty)
        let invalid = try XCTUnwrap(model.rows.first { $0.relativePath == "invalid.md" })
        XCTAssertFalse(invalid.canRender)
        XCTAssertFalse(invalid.issues.isEmpty)

        model.selectSection(.folder("work"))
        XCTAssertEqual(model.rows.count, 3)
        model.selectSection(.folder("work/deep"))
        XCTAssertEqual(model.rows.count, 2)
        model.selectSection(.favourites)
        XCTAssertEqual(paths(model), ["work/deep/a.md"])
        model.selectSection(.tag("CoDe"))
        XCTAssertEqual(paths(model), ["work/deep/a.md", "work/b.md"])
    }

    func testFilterReusesPickerMatcherAcrossFieldsAndExactTagSemanticsWithoutIO() throws {
        let h = PromptFlowHarness()
        _ = try h.put("---\ntitle: Review\ntags: [Café, code]\ndescription: Correctness\n---\nPython", at: "notes/a.md")
        _ = try h.put("Other", at: "b.md")
        try h.index.rebuild()
        let model = browser(h)
        let libraryReads = h.library.accessCount
        let dataReads = h.data.accessCount
        for query in ["rvw", "notes", "correctness", "python", "#CODE rvw python",
                      "#CAFÉ", "#Cafe\u{301}", "#cod", "#cafe", "#", "rvw missing", "  "] {
            model.setFilter(query)
            XCTAssertEqual(Set(model.rows.map(\.relativePath)), Set(h.index.search(query).map { RelativePath($0.relativePath) }), query)
        }
        model.setFilter("#code")
        model.selectSection(.tag("CAFÉ"))
        XCTAssertEqual(paths(model), ["notes/a.md"])
        model.setFilter("#missing")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(count(.all, in: model), 2, "Sidebar counts are independent of the text filter")
        XCTAssertEqual(count(.tag("code"), in: model), 1)
        XCTAssertEqual(h.library.accessCount, libraryReads)
        XCTAssertEqual(h.data.accessCount, dataReads)
        XCTAssertEqual(h.delivery.clipboard.readCount, 0)
    }

    func testRecentUsesNewestRetainedTimestampAndUpdatesOnCopyWithoutIndexPublish() throws {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let h = PromptFlowHarness(mainMode: mode)
            let alpha = try h.put("---\ntitle: Alpha\n---\nBody", at: "a.md")
            let beta = try h.put("---\ntitle: Beta\n---\nBody", at: "b.md")
            _ = try h.put("Unused", at: "c.md")
            try h.usage.recordUse(identity: alpha.identity, at: Date(timeIntervalSince1970: 10))
            try h.usage.recordUse(identity: alpha.identity, at: Date(timeIntervalSince1970: 1))
            try h.usage.recordUse(identity: beta.identity, at: Date(timeIntervalSince1970: 20))
            try h.open()
            let model = browser(h)
            model.selectSection(.recent)
            XCTAssertEqual(paths(model), ["b.md", "a.md"])
            XCTAssertEqual(count(.recent, in: model), 2)
            XCTAssertEqual(model.rows.last?.lastUsedAt, Date(timeIntervalSince1970: 10))
            h.delivery.main.drain()
            var changes = 0
            var callbackOnMain = false
            model.onChange = { changes += 1; callbackOnMain = h.delivery.main.isRunning }
            h.clock.date = Date(timeIntervalSince1970: 30)
            h.picker.use(mode: .copyOnly)
            h.settle()
            XCTAssertEqual(paths(model), ["a.md", "b.md"])
            XCTAssertEqual(changes, 1)
            XCTAssertTrue(callbackOnMain)
            XCTAssertEqual(h.picker.state, .done(.copiedOnly(.requested)))
            XCTAssertEqual(h.delivery.clipboard.readText(), "Body")
            let reads = h.data.accessCount
            model.setFilter("Alpha")
            XCTAssertEqual(h.data.accessCount, reads)
        }
    }

    func testRecentIsBoundedBeforeFilteringAndExcludesDeletedAndUnindexedIdentities() throws {
        let h = PromptFlowHarness()
        for number in 0..<(Limits.libraryRecentCap + 3) {
            let source = number == 0 ? "---\ntags: [excluded]\n---\nBody" : "Body"
            let entry = try h.put(source, at: "p\(number).md")
            try h.usage.recordUse(identity: entry.identity, at: Date(timeIntervalSince1970: Double(number)))
        }
        try h.usage.recordUse(identity: PromptIdentity(path: "missing.md", id: nil), at: Date(timeIntervalSince1970: 999))
        try h.index.rebuild()
        let model = browser(h)
        model.selectSection(.recent)
        XCTAssertEqual(model.rows.count, Limits.libraryRecentCap)
        XCTAssertEqual(model.rows.first?.relativePath, RelativePath("p102.md"))
        XCTAssertEqual(model.rows.last?.relativePath, RelativePath("p3.md"))
        model.setFilter("#excluded")
        XCTAssertTrue(model.rows.isEmpty, "Filtering does not bring entries outside the Recent bound back in")
        model.setFilter("")
        try h.library.delete(at: "p102.md")
        try h.index.apply(LibraryChangeSet(deleted: ["p102.md"]))
        XCTAssertEqual(model.rows.first?.relativePath, RelativePath("p101.md"))
        XCTAssertEqual(model.rows.last?.relativePath, RelativePath("p2.md"))
    }

    func testSelectionFollowsAssignedRenameAndSurvivesFilterAndSectionChanges() throws {
        let h = PromptFlowHarness()
        let alpha = try h.put("---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\ntitle: Alpha\n---\nBody", at: "folder/a.md")
        _ = try h.put("Other", at: "b.md")
        try h.index.rebuild()
        let model = browser(h)
        model.selectSection(.folder("folder"))
        model.selectPrompt(model.rows[0].selection)
        model.setFilter("no match")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.selection?.identity, alpha.identity)
        let moved = try h.service.move(from: "folder/a.md", to: "other/new.md")
        try h.index.apply(LibraryChangeSet(created: ["other/new.md"], deleted: ["folder/a.md"]))
        XCTAssertEqual(model.selection?.identity, alpha.identity)
        XCTAssertEqual(model.selection?.relativePath, "other/new.md")
        XCTAssertEqual(model.selectedEntry?.stamp, moved.stamp)
        XCTAssertEqual(model.selectedSection, .all, "An absent folder falls back to All")
        XCTAssertEqual(model.filter, "no match")
        try h.library.delete(at: "other/new.md")
        try h.index.apply(LibraryChangeSet(deleted: ["other/new.md"]))
        XCTAssertNil(model.selection)
        XCTAssertNil(model.selectedEntry)
    }

    func testByteDistinctPathsFoldersAndDuplicateIDsNeverCollapseSelection() throws {
        let h = PromptFlowHarness()
        let paths: [RelativePath] = ["é/a.md", "e\u{301}/a.md", "é/b.md", "e\u{301}/b.md"]
        for path in paths {
            _ = try h.put("---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\ntitle: Same\n---\nBody", at: path.string)
        }
        try h.index.rebuild()
        let model = browser(h)
        XCTAssertEqual(Set(model.rows.map(\.relativePath)), Set(paths))
        XCTAssertEqual(count(.folder("é"), in: model), 2)
        XCTAssertEqual(count(.folder("e\u{301}"), in: model), 2)
        let selected = try XCTUnwrap(model.rows.first { $0.relativePath == paths[1] }).selection
        model.selectPrompt(selected)
        try h.index.rebuild()
        XCTAssertEqual(model.selection, selected)
        try h.library.delete(at: selected.relativePath.string)
        try h.index.apply(LibraryChangeSet(deleted: [selected.relativePath]))
        XCTAssertNil(model.selection, "An ambiguous duplicate id must not select a different file")
    }

    func testLocalRenameChangesIdentityAndFolderPrefixesUseScalarBoundaries() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Body", at: "a/\u{301}child/x.md")
        _ = try h.put("Body", at: "a-sibling/y.md")
        _ = try h.put("Body", at: "a/other/z.md")
        try h.index.rebuild()
        let model = browser(h)
        let folders = model.sections.compactMap { section -> RelativePath? in
            if case .folder(let path) = section.id { return path }
            return nil
        }
        XCTAssertEqual(folders, ["a", "a/other", "a/\u{301}child", "a-sibling"])
        XCTAssertEqual(count(.folder("a"), in: model), 2)
        model.selectSection(.folder("a/\u{301}child"))
        XCTAssertEqual(paths(model), ["a/\u{301}child/x.md"])
        model.selectPrompt(model.rows[0].selection)
        _ = try h.service.move(from: "a/\u{301}child/x.md", to: "new.md")
        try h.index.apply(LibraryChangeSet(created: ["new.md"], deleted: ["a/\u{301}child/x.md"]))
        XCTAssertNil(model.selection, "Unassigned identity is the path hash under §5.2")
    }

    func testObserverTokensRealChangesAndRemovalDuringPublication() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Body")
        try h.index.rebuild()
        let model = browser(h)
        var changes = 0
        var first = 0
        var second = 0
        var secondToken: UUID?
        model.onChange = { changes += 1 }
        let firstToken = model.addObserver { _ in
            first += 1
            model.removeObserver(secondToken!)
        }
        secondToken = model.addObserver { _ in second += 1 }
        model.setFilter("")
        model.selectSection(.all)
        model.selectSection(.folder("absent"))
        model.selectPrompt(nil)
        try h.index.rebuild()
        XCTAssertEqual(changes, 0)
        model.setFilter("Body")
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
        model.removeObserver(firstToken)
        model.setFilter("missing")
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(first, 1)
    }

    func testUnreadableContentStaysVisibleReadOnlyAndEmptyLibraryHasZeroCounts() throws {
        let h = PromptFlowHarness()
        let model = browser(h)
        XCTAssertEqual(model.sections.map(\.count), [0, 0, 0, 0])
        XCTAssertTrue(model.rows.isEmpty)
        try h.library.write(Data([0xff]), at: "bytes.md")
        try h.library.write(Data(repeating: 65, count: Limits.maxPromptBytes + 1), at: "oversize.md")
        try h.index.rebuild()
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertTrue(model.rows.allSatisfy { $0.isReadOnly && !$0.canRender })
        XCTAssertEqual(model.rows.flatMap(\.issues).map(\.code), [.invalidUTF8, .sourceTooLarge])
    }

    func testIntentNotificationsUseMainThreadAndQueuedNoOpChangesStayQuiet() throws {
        let h = PromptFlowHarness(mainMode: .deferred)
        _ = try h.put("Body")
        try h.open()
        let model = browser(h)
        h.delivery.main.drain()
        var changes = 0
        model.onChange = { changes += 1; XCTAssertTrue(h.delivery.main.isRunning) }
        model.setFilter("changed")
        model.setFilter("")
        h.delivery.main.drain()
        XCTAssertEqual(changes, 0, "Queued publication reports only a real latest-state change")
        model.selectPrompt(model.rows[0].selection)
        XCTAssertEqual(changes, 0)
        h.delivery.main.drain()
        XCTAssertEqual(changes, 1)
    }

    func testReentrantViewChangeDoesNotNotifyObserversTwiceWithTheSameLatestState() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Body")
        try h.index.rebuild()
        let model = browser(h)
        var filters: [String] = []
        let token = model.addObserver { filters.append($0.filter) }
        model.onChange = {
            if model.filter == "first" { model.setFilter("latest") }
        }
        model.setFilter("first")
        XCTAssertEqual(filters, ["latest"])
        model.removeObserver(token)
        model.onChange = nil
    }

    func testCombiningMarkAtStartOfFilenamePreservesFolderAndItsMatcherField() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Body", at: "folder/\u{301}name.md")
        try h.index.rebuild()
        let model = browser(h)
        XCTAssertEqual(model.rows[0].folder, "folder")
        model.selectSection(.folder("folder"))
        model.setFilter("folder")
        XCTAssertEqual(paths(model), ["folder/\u{301}name.md"])
        XCTAssertEqual(h.index.search("folder").map(\.relativePath), ["folder/\u{301}name.md"])
    }

    func testQueuedCallbacksReadLatestStateAndRemovalOrReleaseCancelsDelivery() throws {
        let h = PromptFlowHarness(mainMode: .deferred)
        _ = try h.put("Before")
        try h.open()
        var model: LibraryBrowserModel? = browser(h)
        var snapshots: [[RelativePath]] = []
        var onMain = false
        model?.onChange = { onMain = h.delivery.main.isRunning }
        let token = model!.addObserver { snapshots.append($0.rows.map(\.relativePath)) }
        _ = try h.put("Intermediate", at: "b.md")
        try h.index.apply(LibraryChangeSet(created: ["b.md"]))
        _ = try h.put("Latest", at: "c.md")
        try h.index.apply(LibraryChangeSet(created: ["c.md"]))
        XCTAssertEqual(model?.rows.count, 1)
        h.delivery.main.drain()
        XCTAssertTrue(onMain)
        XCTAssertEqual(snapshots.count, 1, "A second queued callback observes the same latest state and stays quiet")
        XCTAssertEqual(Set(snapshots[0]), ["a.md", "b.md", "c.md"])
        _ = try h.put("Added", at: "d.md")
        try h.index.apply(LibraryChangeSet(created: ["d.md"]))
        model?.removeObserver(token)
        h.delivery.main.drain()
        XCTAssertEqual(snapshots.count, 1)
        weak var released = model
        try h.index.rebuild()
        model = nil
        XCTAssertNil(released)
        h.delivery.main.drain()
    }

    func testPickerAndBrowserReceiveSamePublishAndReleasingEitherKeepsTheOther() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Body")
        try h.open()
        var model: LibraryBrowserModel? = browser(h)
        _ = try h.put("Added", at: "b.md")
        try h.index.apply(LibraryChangeSet(created: ["b.md"]))
        XCTAssertEqual(model?.rows.count, 2)
        XCTAssertEqual(h.picker.results.count, 2)
        model = nil
        _ = try h.put("Added again", at: "c.md")
        try h.index.apply(LibraryChangeSet(created: ["c.md"]))
        XCTAssertEqual(h.picker.results.count, 3)
        var owner: PromptFlowHarness? = PromptFlowHarness()
        _ = try owner!.put("Before")
        try owner!.index.rebuild()
        let surviving = browser(owner!)
        let index = owner!.index
        let library = owner!.library
        weak var released = owner!.picker
        owner = nil
        XCTAssertNil(released)
        try library.put("New", at: "b.md")
        try index.apply(LibraryChangeSet(created: ["b.md"]))
        XCTAssertEqual(surviving.rows.count, 2)
    }

    func testDeactivationAndCompositionRetirementRejectQueuedIndexAndUsageCallbacks() throws {
        for explicitRetirement in [true, false] {
            let h = PromptFlowHarness(mainMode: .deferred)
            let entry = try h.put("Body")
            try h.open()
            let guarded = RetirableBrowserMain(h.delivery.main)
            let model = LibraryBrowserModel(index: h.index, usage: h.usage, favorites: h.service, main: guarded)
            let picker = PickerModel(index: h.index, fill: h.fill, delivery: h.delivery.service, main: guarded)
            picker.open()
            h.delivery.main.drain()
            let before = model.state
            let pickerBefore = picker.results
            var changes = 0
            model.onChange = { changes += 1 }
            _ = try h.put("Later", at: "b.md")
            try h.index.apply(LibraryChangeSet(created: ["b.md"]))
            try h.index.recordUse(of: entry.identity)
            if explicitRetirement { model.deactivate() }
            guarded.isActive = false
            h.delivery.main.drain()
            XCTAssertEqual(model.state, before)
            XCTAssertEqual(picker.results, pickerBefore)
            XCTAssertEqual(changes, 0)
            if explicitRetirement {
                model.setFilter("later")
                model.selectPrompt(nil)
                if case .inactive = model.toggleFavorite() {} else { XCTFail("Retired intent was accepted") }
                XCTAssertEqual(model.state, before)
            }
        }
    }

    func testFailedPublishesAndUsageWritesKeepBrowserStateAndSelection() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Before")
        try h.index.rebuild()
        let model = browser(h)
        model.selectPrompt(model.rows[0].selection)
        let before = model.state
        var changes = 0
        model.onChange = { changes += 1 }
        h.data.failNextWrite = true
        XCTAssertThrowsError(try h.index.recordUse(of: model.selection!.identity))
        _ = try h.put("After")
        h.library.onRead = { _ in throw FileStoreError.ioFailure }
        XCTAssertThrowsError(try h.index.rebuild())
        XCTAssertThrowsError(try h.index.apply(LibraryChangeSet(modified: ["a.md"])))
        XCTAssertEqual(model.state, before)
        XCTAssertEqual(changes, 0)
    }

    func testEditorCloseRetainsSelectionAndReopensAfterCleanOrDiscardedDraft() throws {
        for queuedMain in [false, true] {
            for dirty in [false, true] {
                let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
                let source = "---\ntitle: Kept\nfavorite: true\n---\nOriginal"
                let original = try e.open(source)
                let model = browser(e)
                e.ui {
                    model.selectPrompt(original)
                    model.selectSection(.favourites)
                    model.setFilter("Kept")
                    if dirty { e.model.edit(source + " Mine") }
                    e.model.close()
                }
                e.settle()
                if dirty { try e.decide(.discard); e.settle() }

                XCTAssertNil(e.model.state.prompt)
                XCTAssertEqual(model.selection, original)
                XCTAssertEqual(model.filter, "Kept")
                XCTAssertEqual(model.selectedSection, .favourites)
                let retained = try XCTUnwrap(model.selection)
                e.ui { e.model.open(retained) }
                e.settle()
                XCTAssertEqual(e.model.state.prompt, original)
                XCTAssertEqual(e.model.state.source, source)
            }
        }
    }

    func testEditorCloseDuringSaveRetainsCommittedSelection() throws {
        for queuedMain in [false, true] {
            for assigned in [false, true] {
                let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
                let source = assigned ? historyCommandSource : "Original"
                let original = try e.open(source)
                let model = browser(e)
                e.ui {
                    model.selectPrompt(original)
                    e.model.edit(source + " Saved")
                    e.model.save()
                    e.model.close()
                }
                e.settle()

                XCTAssertNil(e.model.state.prompt)
                let committed = e.selection(try e.h.library.load(at: "a.md"))
                XCTAssertEqual(model.selection, committed)
                e.ui { e.model.open(committed) }
                e.settle()
                XCTAssertTrue(try XCTUnwrap(e.model.state.source).hasSuffix(" Saved"))
            }
        }
    }

    func testExternalDeletionDiscoveredByRereadRetainsSelectionForFreshOpen() throws {
        for queuedMain in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
            let original = try e.open()
            let model = browser(e)
            e.ui { model.selectPrompt(original) }
            e.settle()
            try e.h.files.delete(at: "a.md")
            e.ui { e.model.revert() }
            e.settle()

            XCTAssertNil(e.model.state.prompt)
            XCTAssertEqual(model.selection, original)
            e.ui { model.setFilter("Original"); e.model.request(.rename) }
            e.settle()
            XCTAssertNil(e.model.state.prompt)
            XCTAssertEqual(model.selection, original)
            try e.h.files.put("Restored", at: "a.md")
            let retained = try XCTUnwrap(model.selection)
            e.ui { e.model.open(retained) }
            e.settle()
            XCTAssertEqual(e.model.state.source, "Restored")
        }
    }

    func testExternalDeletionPublicationRetainsSelectionThroughRestoreAndConflictDiscard() throws {
        for queuedMain in [false, true] {
            for dirty in [false, true] {
                let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
                let original = try e.open(historyCommandSource)
                let model = browser(e)
                e.ui { model.selectPrompt(original); if dirty { e.model.edit(historyCommandSource + " Mine") } }
                try e.change(nil)
                e.settle()
                XCTAssertNil(model.selection, "The deleted file has no row while its selection key is retained.")
                if dirty {
                    XCTAssertEqual(e.model.state.conflict?.kind, .deleted)
                    e.ui { e.model.resolveConflict(.discard) }
                    e.settle()
                }
                XCTAssertNil(e.model.state.prompt)

                try e.h.files.put(historyCommandSource, at: "a.md")
                try e.h.index.apply(LibraryChangeSet(created: ["a.md"]))
                e.settle()
                XCTAssertEqual(model.selection, original)
                e.ui { e.model.open(original) }
                e.settle()
                XCTAssertEqual(e.model.state.source, historyCommandSource)
            }
        }
    }

    func testCommittedDeleteClearsRetainedSelectionEvenWhenTheFileIsRestored() throws {
        for queuedMain in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
            let original = try e.open(historyCommandSource)
            let model = browser(e)
            for _ in 0..<2 {
                e.ui { model.selectPrompt(original); e.model.delete() }
                e.settle()
                XCTAssertNil(e.model.state.prompt)
                XCTAssertNil(model.selection)
                try e.h.files.put(historyCommandSource, at: "a.md")
                try e.h.index.apply(LibraryChangeSet(created: ["a.md"]))
                e.settle()
                XCTAssertNil(model.selection, "A committed Delete must retire the selection key.")
                e.ui { e.model.open(original) }
                e.settle()
            }
        }
    }

    func testCopyAdoptionFollowsEditorAndClosePreservesCopyFilterAndSection() throws {
        for queuedMain in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
            let source = "---\ntitle: Kept\nfavorite: true\n---\nOriginal"
            let original = try e.open(source)
            let model = browser(e)
            e.ui { model.selectPrompt(original); e.model.edit(source + " Copy"); e.model.saveAsCopy() }
            e.settle()
            let copy = try XCTUnwrap(e.model.state.lastCopy)
            XCTAssertNotEqual(copy, original)
            // Copy creation is indexed by the watcher, as in the native tests.
            try e.h.index.apply(LibraryChangeSet(created: [copy.relativePath]))
            e.settle()
            XCTAssertEqual(model.selection, copy)
            e.ui { model.selectSection(.favourites); model.setFilter("Kept"); e.model.close() }
            e.settle()
            XCTAssertNil(e.model.state.prompt)
            XCTAssertNil(e.model.state.lastCopy)
            XCTAssertEqual(model.selection, copy)
            let retained = try XCTUnwrap(model.selection)
            e.ui { e.model.open(retained) }
            e.settle()
            XCTAssertEqual(e.model.state.prompt, copy)
            XCTAssertEqual(model.filter, "Kept")
            XCTAssertEqual(model.selectedSection, .favourites)
        }
    }

    func testQueuedCloseRetainsCommittedRenameAndMoveSelectionForBothIdentityKinds() throws {
        for queuedMain in [false, true] {
            for assigned in [false, true] {
                for command in [HistoryTestCommand.rename, .move] {
                    let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
                    let original = try e.open(assigned ? historyCommandSource : "Original")
                    let revision = try historySnapshot(e.h, identity: original.identity)
                    let model = browser(e)
                    e.ui {
                        model.selectPrompt(original)
                        command.run(e.model, revision: revision) { _ in }
                        e.model.close()
                    }
                    e.settle()
                    XCTAssertNil(e.model.state.prompt)
                    let committed = e.selection(try e.h.library.load(at: command.destination))
                    XCTAssertEqual(model.selection, committed)
                    let retained = try XCTUnwrap(model.selection)
                    e.ui { e.model.open(retained) }
                    e.settle()
                    XCTAssertEqual(e.model.state.prompt, committed)
                }
            }
        }
    }

    func testFiveThousandEntryFilterSmokeHasNoFilesystemWork() throws {
        let h = PromptFlowHarness()
        for number in 0..<5_000 {
            _ = try h.put("Explain the supplied topic with examples.", at: "folder/Prompt \(number).md")
        }
        try h.index.rebuild()
        let model = browser(h)
        let reads = (h.library.accessCount, h.data.accessCount)
        let start = ContinuousClock.now
        model.setFilter("prmpt 4999 examples")
        let elapsed = start.duration(to: .now)
        XCTAssertEqual(paths(model), ["folder/Prompt 4999.md"])
        XCTAssertEqual(h.library.accessCount, reads.0)
        XCTAssertEqual(h.data.accessCount, reads.1)
        // Catch gross regressions only, without depending on tight CI timings.
        XCTAssertLessThan(elapsed, .seconds(10), "5,000-entry cached filter smoke exceeded generous bound")
        print("M3 C1: 5,000-entry cached filter took \(elapsed)")
    }

    private func browser(_ h: PromptFlowHarness) -> LibraryBrowserModel {
        LibraryBrowserModel(index: h.index, usage: h.usage, favorites: h.service, main: h.delivery.main)
    }

    private func browser(_ e: EditorHarness) -> LibraryBrowserModel {
        LibraryBrowserModel(index: e.h.index, usage: e.h.usage, favorites: e.h.library,
                            main: e.h.main, editor: e.model)
    }

    private func paths(_ model: LibraryBrowserModel) -> [RelativePath] { model.rows.map(\.relativePath) }

    private func count(_ section: LibrarySectionID, in model: LibraryBrowserModel) -> Int? {
        model.sections.first { $0.id == section }?.count
    }
}

private final class RetirableBrowserMain: MainThread {
    let main: FakeMainThread
    var isActive = true
    init(_ main: FakeMainThread) { self.main = main }
    func run(_ work: @escaping () -> Void) {
        main.run { [weak self] in
            guard self?.isActive == true else { return }
            work()
        }
    }
}
