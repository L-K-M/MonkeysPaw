import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptEditingChangeTests: XCTestCase {
    func testExternalPublicationBetweenInitialReadAndCompletionIsNotLost() throws {
        let h = PromptEditingHarness()
        try h.files.put("Original", at: "a.md")
        try h.index.rebuild()
        var order: [String] = []
        var changes: [PromptExternalChange] = []
        let session = h.editor.beginSession(at: "a.md") { changes.append($0); order.append("external") }
        h.main.beforeRun = {
            h.main.beforeRun = nil
            do {
                try h.files.put("External", at: "a.md")
                try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
            } catch { XCTFail("Could not inject publication after the checked read.") }
        }
        defer { h.main.beforeRun = nil }
        h.marker.ui { h.editor.load(session: session) {
            guard case .loaded(let loaded) = $0 else { return XCTFail("Expected checked load.") }
            XCTAssertEqual(loaded.source, "Original")
            order.append("loaded")
        } }
        XCTAssertEqual(order, ["loaded", "external"])
        XCTAssertEqual(changes, [PromptExternalChange(kind: .modified, newStamp: try h.files.stamp(at: "a.md"))])
    }

    func testReentrantIndexPublicationCannotDeliverAnOlderStampAfterANewerOne() throws {
        for queuedMain in [false, true] {
            let h = PromptEditingHarness()
            var changes: [PromptExternalChange] = []
            _ = try h.open(changes: { changes.append($0) })
            h.main.isHeld = queuedMain
            let counter = EditingIndexCounter()
            let observer = h.index.addObserver {
                guard counter.value == 0 else { return }
                counter.value += 1
                do {
                    try h.files.put("Newest", at: "a.md")
                    try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
                } catch { XCTFail("Reentrant index publication failed.") }
            }
            defer { h.index.removeObserver(observer) }
            try h.files.put("Older", at: "a.md")
            try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
            h.main.releaseAll()
            XCTAssertEqual(changes, [PromptExternalChange(kind: .modified, newStamp: try h.files.stamp(at: "a.md"))])
        }
    }

    func testExternalModificationPublishesOncePerChangedOpenPathSnapshot() throws {
        let h = PromptEditingHarness()
        var changes: [PromptExternalChange] = []
        let (_, loaded) = try h.open(changes: { [weak h] change in
            XCTAssertTrue(h?.marker.isUI == true)
            changes.append(change)
        })
        try h.files.put("Other", at: "other.md")
        try h.index.apply(LibraryChangeSet(created: [RelativePath("other.md")]))
        XCTAssertTrue(changes.isEmpty)
        try h.files.put("External", at: "a.md")
        try h.files.put("Other edited", at: "other.md")
        let stamp = try XCTUnwrap(h.files.stamp(at: "a.md"))
        let set = LibraryChangeSet(modified: [RelativePath("a.md"), RelativePath("other.md")])
        try h.index.apply(set)
        XCTAssertEqual(changes, [PromptExternalChange(kind: .modified, newStamp: stamp)])
        XCTAssertNotEqual(stamp, loaded.stamp)
        try h.index.apply(set)
        try h.index.rebuild()
        XCTAssertEqual(changes.count, 1, "Re-publishing unchanged content is quiet.")
    }

    func testQueuedDeleteAndRecreateKeepBothPublicationsAndIncarnationStamp() throws {
        let h = PromptEditingHarness()
        var changes: [PromptExternalChange] = []
        let (_, loaded) = try h.open(changes: { changes.append($0) })
        h.main.isHeld = true
        try h.files.delete(at: "a.md")
        try h.index.apply(LibraryChangeSet(deleted: [RelativePath("a.md")]))
        try h.files.put("Original", at: "a.md")
        let recreated = try XCTUnwrap(h.files.stamp(at: "a.md"))
        try h.index.apply(LibraryChangeSet(created: [RelativePath("a.md")]))
        XCTAssertTrue(changes.isEmpty)
        h.main.releaseAll()
        XCTAssertEqual(changes, [PromptExternalChange(kind: .deleted, newStamp: nil),
                                PromptExternalChange(kind: .recreated, newStamp: recreated)])
        XCTAssertNotEqual(recreated, loaded.stamp)
    }

    func testDeleteRecreateInOneWatchSetIsOneModification() throws {
        let h = PromptEditingHarness()
        var changes: [PromptExternalChange] = []
        _ = try h.open(changes: { changes.append($0) })
        try h.files.delete(at: "a.md")
        try h.files.put("Original", at: "a.md")
        let stamp = try h.files.stamp(at: "a.md")
        try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
        XCTAssertEqual(changes, [PromptExternalChange(kind: .modified, newStamp: stamp)])
    }

    func testExternalChangesUseByteExactPaths() throws {
        let h = PromptEditingHarness()
        let composed = "é.md"
        let decomposed = "e\u{301}.md"
        var changes: [PromptExternalChange] = []
        _ = try h.open(at: composed, changes: { changes.append($0) })
        try h.files.put("Distinct", at: decomposed)
        try h.index.apply(LibraryChangeSet(created: [RelativePath(decomposed)]))
        XCTAssertTrue(changes.isEmpty)
        try h.files.delete(at: decomposed)
        try h.index.apply(LibraryChangeSet(deleted: [RelativePath(decomposed)]))
        XCTAssertTrue(changes.isEmpty)
        try h.files.put("Open path edited", at: composed)
        let stamp = try h.files.stamp(at: composed)
        try h.index.apply(LibraryChangeSet(modified: [RelativePath(composed)]))
        XCTAssertEqual(changes, [PromptExternalChange(kind: .modified, newStamp: stamp)])
    }

    func testOwnSaveUpdatesIndexAndStampWithoutExternalConflict() throws {
        let h = PromptEditingHarness()
        var changes: [PromptExternalChange] = []
        let (session, loaded) = try h.open(changes: { changes.append($0) })
        guard case .saved(let saved) = try h.save("Mine", session: session, stamp: loaded.stamp) else {
            return XCTFail("Expected save.")
        }
        XCTAssertEqual(h.index.cachedEntry(at: "a.md")?.stamp, saved.stamp)
        XCTAssertEqual(h.index.cachedEntry(at: "a.md")?.identity, saved.identity)
        try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
        XCTAssertTrue(changes.isEmpty)
        try h.files.put("External", at: "a.md")
        try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
        XCTAssertEqual(changes.count, 1)
    }

    func testOwnIndexPublicationDuringWriteIsDeferredAndSuppressed() throws {
        let h = PromptEditingHarness()
        var changes: [PromptExternalChange] = []
        let (session, loaded) = try h.open(changes: { changes.append($0) })
        h.files.onWrite = { [weak h] path in
            guard let h, path == "a.md" else { return }
            h.files.onWrite = nil
            do {
                let document = PromptCodec.parseFile(try h.files.read(at: path), filename: path)
                let stamp = try XCTUnwrap(h.files.stamp(at: path))
                h.index.acceptSaved(LibraryEntry(path: path, document: document, stamp: stamp), replacing: loaded.entry)
            } catch { XCTFail("Could not publish simulated watcher snapshot.") }
            XCTAssertTrue(changes.isEmpty, "Do not mistake our commit for an external write.")
        }
        defer { h.files.onWrite = nil }
        guard case .saved = try h.save("Mine", session: session, stamp: loaded.stamp) else { return XCTFail("Expected save.") }
        XCTAssertTrue(changes.isEmpty)
    }

    func testExternalEditAfterWorkerSaveSurvivesDelayedCompletionAndKeepsNewerIndex() throws {
        let h = PromptEditingHarness(heldWork: true)
        var changes: [PromptExternalChange] = []
        let (session, loaded) = try h.open(changes: { changes.append($0) })
        h.main.isHeld = true
        var outcome: PromptSaveOutcome?
        h.marker.ui { h.editor.save("Mine", session: session, expectedStamp: loaded.stamp) { outcome = $0 } }
        h.held.releaseAll()
        try h.files.put("External", at: "a.md")
        let externalStamp = try XCTUnwrap(h.files.stamp(at: "a.md"))
        try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
        h.main.releaseAll()
        guard case .saved(let own) = outcome else { return XCTFail("Expected the committed save result.") }
        XCTAssertNotEqual(own.stamp, externalStamp)
        XCTAssertEqual(changes, [PromptExternalChange(kind: .modified, newStamp: externalStamp)])
        XCTAssertEqual(h.index.cachedEntry(at: "a.md")?.stamp, externalStamp)
        XCTAssertEqual(h.index.cachedEntry(at: "a.md")?.document.body, "External")
    }

    func testExternalEditWhileSaveIsQueuedPublishesAfterTheConflictResult() throws {
        let h = PromptEditingHarness(heldWork: true)
        var order: [String] = []
        let (session, loaded) = try h.open(changes: { _ in order.append("external") })
        h.marker.ui { h.editor.save("Mine", session: session, expectedStamp: loaded.stamp) {
            guard case .conflict = $0 else { return XCTFail("Expected conflict.") }
            order.append("save")
        } }
        try h.files.put("External", at: "a.md")
        try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
        XCTAssertTrue(order.isEmpty)
        h.held.releaseAll()
        XCTAssertEqual(order, ["save", "external"])
    }

    func testSaveCompletionCanRetireSessionBeforeDeferredExternalEvents() throws {
        let h = PromptEditingHarness(heldWork: true)
        let (session, loaded) = try h.open(changes: { _ in XCTFail("Completion retired this session.") })
        h.marker.ui { h.editor.save("Mine", session: session, expectedStamp: loaded.stamp) { _ in h.editor.retire(session) } }
        try h.files.put("External", at: "a.md")
        try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
        h.held.releaseAll()
    }

    func testQueuedExternalEventIsDroppedForRetiredSessionOnly() throws {
        let h = PromptEditingHarness()
        let (retired, _) = try h.open(changes: { _ in XCTFail("Retired event.") })
        var liveChanges: [PromptExternalChange] = []
        let live = h.marker.ui { h.editor.beginSession(at: "a.md") { liveChanges.append($0) } }
        h.marker.ui { h.editor.load(session: live) { _ in } }
        h.main.isHeld = true
        try h.files.put("External", at: "a.md")
        try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
        h.marker.ui { h.editor.retire(retired) }
        h.main.releaseAll()
        XCTAssertEqual(liveChanges.count, 1)
    }

    func testLoadedPathNotYetIndexedStillObservesDeletion() throws {
        let h = PromptEditingHarness()
        try h.files.put("Original", at: "a.md")
        var changes: [PromptExternalChange] = []
        let session = h.marker.ui { h.editor.beginSession(at: "a.md") { changes.append($0) } }
        h.marker.ui { h.editor.load(session: session) { _ in } }
        try h.files.put("Unrelated", at: "other.md")
        try h.index.apply(LibraryChangeSet(created: [RelativePath("other.md")]))
        XCTAssertTrue(changes.isEmpty, "An unindexed open path did not disappear when another path changed.")
        try h.files.delete(at: "a.md")
        try h.index.apply(LibraryChangeSet(deleted: [RelativePath("a.md")]))
        XCTAssertEqual(changes, [PromptExternalChange(kind: .deleted, newStamp: nil)])
    }

    func testReloadDetectingDeletionClassifiesTheNextIncarnationAsRecreated() throws {
        let h = PromptEditingHarness()
        var changes: [PromptExternalChange] = []
        let (session, _) = try h.open(changes: { changes.append($0) })
        try h.files.delete(at: "a.md")
        h.marker.ui { h.editor.load(session: session) {
            guard case .deleted = $0 else { return XCTFail("Reload must detect the missing path.") }
        } }
        // The watcher has not published the deletion; its index still contains
        // the earlier incarnation, while this editor knows the path is missing.
        try h.index.apply(LibraryChangeSet())
        XCTAssertTrue(changes.isEmpty)
        try h.files.put("Recreated", at: "a.md")
        let stamp = try h.files.stamp(at: "a.md")
        try h.index.apply(LibraryChangeSet(created: [RelativePath("a.md")]))
        XCTAssertEqual(changes, [PromptExternalChange(kind: .recreated, newStamp: stamp)])
        try h.files.put("Modified after recreation", at: "a.md")
        let modified = try h.files.stamp(at: "a.md")
        try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
        XCTAssertEqual(changes, [PromptExternalChange(kind: .recreated, newStamp: stamp),
                                PromptExternalChange(kind: .modified, newStamp: modified)])
    }

    func testMissingLoadThenRecreationStillReportsTheNextDeletion() throws {
        let h = PromptEditingHarness()
        var changes: [PromptExternalChange] = []
        let (session, _) = try h.open(changes: { changes.append($0) })
        try h.files.delete(at: "a.md")
        h.marker.ui { h.editor.load(session: session) {
            guard case .deleted = $0 else { return XCTFail("Expected missing load.") }
        } }
        try h.files.put("Recreated", at: "a.md")
        let stamp = try h.files.stamp(at: "a.md")
        try h.index.apply(LibraryChangeSet(created: [RelativePath("a.md")]))
        try h.files.delete(at: "a.md")
        try h.index.apply(LibraryChangeSet(deleted: [RelativePath("a.md")]))
        XCTAssertEqual(changes, [PromptExternalChange(kind: .recreated, newStamp: stamp),
                                PromptExternalChange(kind: .deleted, newStamp: nil)])
    }

    func testMissingSaveThenRecreationStillReportsTheNextDeletion() throws {
        let h = PromptEditingHarness()
        var changes: [PromptExternalChange] = []
        let (session, loaded) = try h.open(changes: { changes.append($0) })
        try h.files.delete(at: "a.md")
        guard case .deleted = try h.save("Mine", session: session, stamp: loaded.stamp) else {
            return XCTFail("Expected missing save.")
        }
        try h.files.put("Recreated", at: "a.md")
        let stamp = try h.files.stamp(at: "a.md")
        try h.index.apply(LibraryChangeSet(created: [RelativePath("a.md")]))
        try h.files.delete(at: "a.md")
        try h.index.apply(LibraryChangeSet(deleted: [RelativePath("a.md")]))
        XCTAssertEqual(changes, [PromptExternalChange(kind: .recreated, newStamp: stamp),
                                PromptExternalChange(kind: .deleted, newStamp: nil)])
    }

    func testMissingSessionKeepsRecreationAndDeletionWhileSaveIsHeld() throws {
        let h = PromptEditingHarness(heldWork: true)
        var changes: [PromptExternalChange] = []
        let (session, loaded) = try h.open(changes: { changes.append($0) })
        try h.files.delete(at: "a.md")
        guard case .deleted = try h.save("Mine", session: session, stamp: loaded.stamp) else {
            return XCTFail("Expected missing save.")
        }
        h.marker.ui { h.editor.save("Mine", session: session, expectedStamp: loaded.stamp) { _ in } }
        try h.files.put("Recreated", at: "a.md")
        let stamp = try h.files.stamp(at: "a.md")
        try h.index.apply(LibraryChangeSet(created: [RelativePath("a.md")]))
        try h.files.delete(at: "a.md")
        try h.index.apply(LibraryChangeSet(deleted: [RelativePath("a.md")]))
        XCTAssertTrue(changes.isEmpty)
        h.held.releaseAll()
        XCTAssertEqual(changes, [PromptExternalChange(kind: .recreated, newStamp: stamp),
                                PromptExternalChange(kind: .deleted, newStamp: nil)])
    }

    func testDeferredRecreationAfterMissingSaveStillReportsLaterWatcherDeletion() throws {
        let h = PromptEditingHarness(heldWork: true)
        var changes: [PromptExternalChange] = []
        let (session, loaded) = try h.open(changes: { changes.append($0) })
        try h.files.delete(at: "a.md")
        guard case .deleted = try h.save("Mine", session: session, stamp: loaded.stamp) else {
            return XCTFail("Expected missing save.")
        }
        h.marker.ui { h.editor.save("Mine", session: session, expectedStamp: loaded.stamp) { _ in } }
        try h.files.put("Recreated", at: "a.md")
        let stamp = try h.files.stamp(at: "a.md")
        try h.index.apply(LibraryChangeSet(created: [RelativePath("a.md")]))
        try h.files.delete(at: "a.md")
        h.held.releaseAll()
        XCTAssertEqual(changes, [PromptExternalChange(kind: .recreated, newStamp: stamp)])
        try h.index.apply(LibraryChangeSet(deleted: [RelativePath("a.md")]))
        XCTAssertEqual(changes, [PromptExternalChange(kind: .recreated, newStamp: stamp),
                                PromptExternalChange(kind: .deleted, newStamp: nil)])
    }

    func testServiceLifetimeDoesNotStealOrRetainOtherIndexSubscribers() throws {
        let h = PromptEditingHarness()
        let counter = EditingIndexCounter()
        let observer = h.index.addObserver { counter.value += 1 }
        defer { h.index.removeObserver(observer) }
        var editor: PromptEditingService? = PromptEditingService(library: h.library, index: h.index,
            work: h.held, main: h.main)
        weak var lifetime = editor
        editor = nil
        XCTAssertNil(lifetime)
        try h.index.rebuild()
        XCTAssertEqual(counter.value, 1)
        h.editor.deactivate()
        try h.index.rebuild()
        XCTAssertEqual(counter.value, 2)
    }
}

/// Tests publish synchronously; the Sendable callback never crosses threads.
private final class EditingIndexCounter: @unchecked Sendable { var value = 0 }
