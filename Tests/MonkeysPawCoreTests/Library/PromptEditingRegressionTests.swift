import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptEditingRegressionTests: XCTestCase {
    func testLibraryEditingSaveReportsTheExternalPostCommitStamp() throws {
        let h = PromptEditingHarness()
        let (_, loaded) = try h.open()
        replaceAfterWrite(h, at: "a.md")

        let outcome = try h.library.saveForEditing(PromptCodec.parse("Mine", filename: "a.md"),
                                                  at: "a.md", expectedStamp: loaded.stamp)

        guard case .conflict(let stamp) = outcome else { return XCTFail("Expected a typed post-commit conflict.") }
        XCTAssertEqual(stamp, try h.files.stamp(at: "a.md"))
        XCTAssertEqual(try h.files.text(at: "a.md"), "External")
        XCTAssertNil(outcome.committedEntry, "External bytes must never be reported as our commit.")
    }

    func testLibraryEditingCopyReportsTheExternalPostCommitStamp() throws {
        let h = PromptEditingHarness()
        replaceAfterWrite(h, at: "copy 2.md")

        let outcome = try h.library.createCopyForEditing(PromptCodec.parse("Mine", filename: "copy.md"),
                                                        near: "copy.md")

        guard case .conflict(let stamp) = outcome else { return XCTFail("Expected a typed copy conflict.") }
        XCTAssertEqual(stamp, try h.files.stamp(at: "copy 2.md"))
        XCTAssertEqual(try h.files.text(at: "copy 2.md"), "External")
        XCTAssertNil(try h.files.stamp(at: "copy.md"))
        XCTAssertNil(outcome.committedEntry)
    }

    func testSynchronousSaveKeepsItsPostCommitConflictError() throws {
        let h = PromptEditingHarness()
        replaceAfterWrite(h, at: "a.md")
        XCTAssertThrowsError(try h.library.save(PromptCodec.parse("Mine", filename: "a.md"), at: "a.md")) {
            XCTAssertEqual($0 as? LibraryError, .conflict)
        }
        XCTAssertEqual(try h.files.text(at: "a.md"), "External")
    }

    func testDeletedInitialLoadDropsAnEarlierParkedModification() throws {
        for queuedMain in [false, true] {
            let h = PromptEditingHarness()
            try h.files.put("Original", at: "a.md")
            try h.index.rebuild()
            let previous = try h.library.load(at: "a.md")
            var changes: [PromptExternalChange] = []
            let session = h.editor.beginSession(at: "a.md") { changes.append($0) }
            try h.files.delete(at: "a.md")
            h.main.isHeld = queuedMain
            h.files.onStamp = { path, _ in
                h.files.onStamp = nil
                try h.files.put("Published before deletion", at: path)
                let stamp = try XCTUnwrap(h.files.stamp(at: path))
                let entry = LibraryEntry(path: path, document: PromptCodec.parse("Published before deletion", filename: path),
                                         stamp: stamp)
                // Publish without reentering the library's checked-read lock.
                h.index.acceptSaved(entry, replacing: previous)
                try h.files.delete(at: path)
            }
            defer { h.files.onStamp = nil }

            h.marker.ui { h.editor.load(session: session) {
                guard case .deleted = $0 else { return XCTFail("Expected the checked missing result.") }
            } }

            h.main.releaseAll()
            h.main.isHeld = false
            XCTAssertTrue(changes.isEmpty, "A publication preceding the missing read cannot resurrect the path.")
            try h.files.put("Later recreation", at: "a.md")
            let recreated = try h.files.stamp(at: "a.md")
            try h.index.apply(LibraryChangeSet(created: [RelativePath("a.md")]))
            XCTAssertEqual(changes, [PromptExternalChange(kind: .recreated, newStamp: recreated)])
        }
    }

    func testDeletedInitialLoadKeepsRecreationAfterItsCheckedRead() throws {
        let h = PromptEditingHarness()
        var changes: [PromptExternalChange] = []
        var order: [String] = []
        let session = h.editor.beginSession(at: "a.md") { changes.append($0); order.append("external") }
        h.main.beforeRun = {
            h.main.beforeRun = nil
            do {
                try h.files.put("New incarnation", at: "a.md")
                try h.index.apply(LibraryChangeSet(created: [RelativePath("a.md")]))
            } catch { XCTFail("Could not publish after the checked deletion.") }
        }
        defer { h.main.beforeRun = nil }
        h.marker.ui { h.editor.load(session: session) {
            guard case .deleted = $0 else { return XCTFail("Expected the checked missing result.") }
            order.append("deleted")
        } }
        XCTAssertEqual(order, ["deleted", "external"])
        XCTAssertEqual(changes, [PromptExternalChange(kind: .recreated, newStamp: try h.files.stamp(at: "a.md"))])
    }

    func testRecreationDuringTheMissingProbeIsNotDiscardedByTheDeletionVersion() throws {
        let h = PromptEditingHarness()
        try h.files.put("Original", at: "a.md")
        try h.index.rebuild()
        let previous = try h.library.load(at: "a.md")
        try h.files.delete(at: "a.md")
        var changes: [PromptExternalChange] = []
        var outcome: PromptLoadOutcome?
        let session = h.editor.beginSession(at: "a.md") { changes.append($0) }
        h.files.onStamp = { path, probed in
            h.files.onStamp = nil
            XCTAssertNil(probed)
            try h.files.put("Recreated after the missing probe", at: path)
            let entry = LibraryEntry(path: path,
                                     document: PromptCodec.parseFile(try h.files.read(at: path), filename: path),
                                     stamp: try XCTUnwrap(h.files.stamp(at: path)))
            h.index.acceptSaved(entry, replacing: previous)
        }
        defer { h.files.onStamp = nil }

        h.marker.ui { h.editor.load(session: session) { outcome = $0 } }

        let current = try h.files.stamp(at: "a.md")
        switch try XCTUnwrap(outcome) {
        case .loaded(let loaded):
            XCTAssertEqual(loaded.stamp, current)
            XCTAssertEqual(loaded.source, "Recreated after the missing probe")
        case .deleted:
            XCTAssertEqual(changes.last?.newStamp, current, "The creation after the probe must survive a deleted result.")
        case .failed: XCTFail("A stable recreation is readable.")
        }
    }

    func testMissingReadRecheckIsBoundedWhenPublicationKeepsChanging() throws {
        let h = PromptEditingHarness()
        try h.files.put("Original", at: "a.md")
        try h.index.rebuild()
        var previous = try h.library.load(at: "a.md")
        try h.files.delete(at: "a.md")
        let session = h.editor.beginSession(at: "a.md")
        var probes = 0
        var outcome: PromptLoadOutcome?
        func publishThenDelete(_ path: String, _ probed: FileStamp?) throws {
            h.files.onStamp = nil
            XCTAssertNil(probed)
            probes += 1
            try h.files.put("Publication \(probes)", at: path)
            let entry = LibraryEntry(path: path,
                                     document: PromptCodec.parseFile(try h.files.read(at: path), filename: path),
                                     stamp: try XCTUnwrap(h.files.stamp(at: path)))
            h.index.acceptSaved(entry, replacing: previous)
            previous = entry
            try h.files.delete(at: path)
            h.files.onStamp = publishThenDelete
        }
        h.files.onStamp = publishThenDelete
        defer { h.files.onStamp = nil }

        h.marker.ui { h.editor.load(session: session) { outcome = $0 } }

        guard case .failed(.library(.conflict)) = outcome else { return XCTFail("Continued churn must report a typed conflict.") }
        XCTAssertEqual(probes, 2, "Missing-read reconciliation must stop after one recheck.")
    }

    func testSaveBeforeLoadClassifiesTheNextPublicationAsModified() throws {
        let h = PromptEditingHarness()
        var changes: [PromptExternalChange] = []
        let session = h.editor.beginSession(at: "a.md") { changes.append($0) }
        guard case .saved = try h.save("Mine", session: session, stamp: nil) else { return XCTFail("Expected save.") }
        XCTAssertTrue(changes.isEmpty)

        try h.files.put("External", at: "a.md")
        let stamp = try h.files.stamp(at: "a.md")
        try h.index.apply(LibraryChangeSet(created: [RelativePath("a.md")]))

        XCTAssertEqual(changes, [PromptExternalChange(kind: .modified, newStamp: stamp)])
    }

    func testReloadAfterSaveDropsAnOlderParkedChangeAndKeepsTheOwnSaveQuiet() throws {
        let h = PromptEditingHarness()
        try h.files.put("Original", at: "a.md")
        try h.index.rebuild()
        var changes: [PromptExternalChange] = []
        let session = h.editor.beginSession(at: "a.md") { changes.append($0) }
        try h.files.put("Parked", at: "a.md")
        try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
        let previous = try h.library.load(at: "a.md")
        h.libraryFiles.beforeWrite = { path in
            h.libraryFiles.beforeWrite = nil
            // External writers can race the last stamp check and atomic write.
            // Their publication wins the index guard; our ensuing write wins disk.
            try h.files.put("Raced external edit", at: path)
            let external = LibraryEntry(path: path,
                                        document: PromptCodec.parseFile(try h.files.read(at: path), filename: path),
                                        stamp: try XCTUnwrap(h.files.stamp(at: path)))
            h.index.acceptSaved(external, replacing: previous)
        }
        defer { h.libraryFiles.beforeWrite = nil }
        guard case .saved(let own) = try h.save("Mine", session: session, stamp: nil) else { return XCTFail("Expected own commit.") }
        XCTAssertNotEqual(h.index.cachedEntry(at: "a.md")?.stamp, own.stamp)
        XCTAssertTrue(changes.isEmpty)

        h.marker.ui { h.editor.load(session: session) {
            guard case .loaded(let loaded) = $0 else { return XCTFail("Expected current disk source.") }
            XCTAssertEqual(loaded.stamp, own.stamp)
            XCTAssertEqual(loaded.source, own.document.source)
        } }

        XCTAssertTrue(changes.isEmpty, "The parked change is older than this checked reload.")
        try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
        XCTAssertTrue(changes.isEmpty, "The watcher must keep our committed stamp quiet.")
    }

    func testStaleLoadedReplyCannotRewindAnObservedDeletion() throws {
        let h = PromptEditingHarness()
        var changes: [PromptExternalChange] = []
        let (session, loaded) = try h.open(changes: { changes.append($0) })
        h.main.beforeRun = {
            h.main.beforeRun = nil
            do {
                try h.files.delete(at: "a.md")
                try h.index.apply(LibraryChangeSet(deleted: [RelativePath("a.md")]))
            } catch { XCTFail("Could not publish deletion during reload delivery.") }
        }
        defer { h.main.beforeRun = nil }
        h.marker.ui { h.editor.load(session: session) {
            guard case .loaded(let reread) = $0 else { return XCTFail("Expected a checked reload.") }
            XCTAssertEqual(reread.stamp, loaded.stamp)
        } }
        XCTAssertEqual(changes, [PromptExternalChange(kind: .deleted, newStamp: nil)])
        changes.removeAll()

        try h.files.put("Recreated", at: "a.md")
        let recreated = try h.files.stamp(at: "a.md")
        try h.index.apply(LibraryChangeSet(created: [RelativePath("a.md")]))

        XCTAssertEqual(changes, [PromptExternalChange(kind: .recreated, newStamp: recreated)])
    }

    func testStaleDeletedReplyCannotRewindAnObservedRecreation() throws {
        let h = PromptEditingHarness()
        var changes: [PromptExternalChange] = []
        let (session, _) = try h.open(changes: { changes.append($0) })
        try h.files.delete(at: "a.md")
        try h.index.apply(LibraryChangeSet(deleted: [RelativePath("a.md")]))
        changes.removeAll()
        h.main.beforeRun = {
            h.main.beforeRun = nil
            do {
                try h.files.put("Recreated", at: "a.md")
                try h.index.apply(LibraryChangeSet(created: [RelativePath("a.md")]))
            } catch { XCTFail("Could not publish recreation during missing reload delivery.") }
        }
        defer { h.main.beforeRun = nil }
        h.marker.ui { h.editor.load(session: session) {
            guard case .deleted = $0 else { return XCTFail("Expected the checked missing result.") }
        } }
        XCTAssertEqual(changes, [PromptExternalChange(kind: .recreated, newStamp: try h.files.stamp(at: "a.md"))])
        changes.removeAll()

        try h.files.put("Modified", at: "a.md")
        let modified = try h.files.stamp(at: "a.md")
        try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))

        XCTAssertEqual(changes, [PromptExternalChange(kind: .modified, newStamp: modified)])
    }

    func testLoadedPromptExplainsUnavailableTextEvenWithAnUnflaggedDocument() {
        let document = PromptCodec.parse("Valid", filename: "a.md")
        let entry = LibraryEntry(path: "a.md", document: document, stamp: FileStamp("checked"))
        let cases: [(Data, PromptReadOnlyReason)] = [
            (Data([0xff]), .invalidUTF8),
            (Data(repeating: 0x78, count: Limits.maxPromptBytes + 1), .sourceTooLarge),
        ]
        for (bytes, reason) in cases {
            let loaded = LoadedPrompt(bytes: bytes, entry: entry)
            XCTAssertNil(loaded.source)
            XCTAssertEqual(loaded.readOnlyReason, reason)
            XCTAssertEqual(loaded.sourceBytes, bytes)
        }
    }

    func testPostDeactivationSessionCompletesAllOperationsImmediately() {
        let h = PromptEditingHarness(heldWork: true)
        h.main.isHeld = true
        var replies = 0
        h.marker.ui {
            h.editor.deactivate()
            let session = h.editor.beginSession(at: "a.md")
            h.editor.load(session: session) {
                guard case .failed(.library(.operationFailed)) = $0 else { return XCTFail("Expected typed inactive load failure.") }
                XCTAssertTrue(h.marker.isUI)
                replies += 1
            }
            let saved: (PromptSaveOutcome) -> Void = {
                guard case .failed(.library(.operationFailed)) = $0 else { return XCTFail("Expected typed inactive write failure.") }
                XCTAssertTrue(h.marker.isUI)
                replies += 1
            }
            h.editor.save("Mine", session: session, expectedStamp: nil, completion: saved)
            h.editor.createCopy("Mine", near: "copy.md", session: session, completion: saved)
        }
        XCTAssertEqual(replies, 3)
        XCTAssertTrue(h.held.pending.isEmpty)
        XCTAssertTrue(h.main.pending.isEmpty)
        XCTAssertEqual(h.files.accessCount + h.data.accessCount, 0)
    }

    func testMainThreadHookRunsWhenHeldWorkExecutes() {
        let marker = EditingThreadMarker()
        let main = EditingMainThread(marker)
        main.isHeld = true
        var order: [String] = []
        main.beforeRun = { order.append("before") }
        main.run { order.append("first") }
        main.run { order.append("second") }
        XCTAssertTrue(order.isEmpty)
        main.releaseAll()
        XCTAssertEqual(order, ["before", "first", "before", "second"])
    }

    private func replaceAfterWrite(_ h: PromptEditingHarness, at path: String) {
        h.files.onWrite = { written in
            guard written == path else { return }
            h.files.onWrite = nil
            do { try h.files.put("External", at: path) }
            catch { XCTFail("Could not replace the committed bytes.") }
        }
    }
}
