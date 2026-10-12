import Foundation
import XCTest
@testable import MonkeysPawCore

final class EditorHistoryTests: XCTestCase {
    func testHistoryListsNewestFirstWithSizeValidityAndReadOnlyPreview() throws {
        for queuedMain in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
            let selection = try e.open(historyCommandSource)
            let sources = [Data("Previous\r\n".utf8), Data("---\ntitle: [broken\n---\nForensic".utf8),
                Data([0xff, 0xfe]), Data("---\nformat: 2\n---\nFuture".utf8),
                Data(repeating: 0x78, count: Limits.maxPromptBytes + 1)]
            let revisions = try sources.map { try historySnapshot(e.h, identity: selection.identity, bytes: $0) }
            let before = e.model.state.source
            e.ui { e.model.loadHistory() }
            XCTAssertTrue(e.model.state.history.isLoading)
            XCTAssertTrue(e.model.state.history.revisions.isEmpty)
            e.settle()
            let rows = e.model.state.history.revisions
            XCTAssertEqual(rows.map(\.revision), revisions.reversed())
            XCTAssertEqual(rows.map(\.byteCount), sources.reversed().map(\.count))
            XCTAssertEqual(rows.map(\.isForensic), [true, true, true, true, false])
            XCTAssertTrue(rows.allSatisfy { $0.revision.timestamp == e.h.clock.date })
            for row in rows {
                let accesses = e.h.files.accessCount + e.h.data.accessCount
                e.ui { e.model.selectRevision(row.revision) }
                e.settle()
                XCTAssertEqual(e.model.state.history.previewSource, row.source)
                XCTAssertEqual(e.h.files.accessCount + e.h.data.accessCount, accesses)
                XCTAssertEqual(e.model.state.source, before)
                XCTAssertFalse(e.model.state.isDirty)
            }
            XCTAssertFalse(e.model.state.history.isLoading)
            XCTAssertNil(e.model.state.history.failure)
        }
    }

    func testForensicAndFutureRevisionsRefuseRestoreWithTypedReasonAndNoSnapshot() throws {
        let fixtures: [(Data, PromptWriteError)] = [
            (Data("---\ntitle: [broken\n---\nBroken".utf8), .invalidPrompt),
            (Data([0xff, 0xfe]), .invalidPrompt),
            (Data(repeating: 0x78, count: Limits.maxPromptBytes + 1), .invalidPrompt),
            (Data("---\nformat: 2\n---\nFuture".utf8), .unsupportedFormat(PromptFormatVersion(2)!))
        ]
        for (bytes, reason) in fixtures {
            let e = EditorHarness()
            let selection = try e.open(historyCommandSource)
            let revision = try historySnapshot(e.h, identity: selection.identity, bytes: bytes)
            e.ui { e.model.loadHistory(); e.model.selectRevision(revision) }
            XCTAssertEqual(e.model.state.history.revisions.first?.restoreFailure, reason)
            var result: PromptCommandOutcome?
            e.ui { e.model.restore(revision) { result = $0; XCTAssertTrue(e.h.marker.isUI) } }
            guard case .forensic(let actual) = result else { return XCTFail("Expected a forensic refusal.") }
            XCTAssertEqual(actual, reason)
            XCTAssertEqual(try e.h.files.text(at: "a.md"), historyCommandSource)
            XCTAssertEqual(try e.h.library.history(for: selection.identity), [revision])
            XCTAssertEqual(e.model.state.history.selectedRevision, revision)
        }
    }

    func testRestoreReloadsEditorAndHistoryKeepingIdentityAndExactBody() throws {
        for queuedMain in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
            let selection = try e.open(historyCommandSource)
            let body = "  Before id {{x}}\r\n\r\n"
            let revision = try historySnapshot(e.h, identity: selection.identity, bytes: Data(body.utf8))
            e.ui { e.model.loadHistory() }
            e.settle()
            e.ui { e.model.selectRevision(revision) }
            let stamp = e.model.state.stamp
            var result: PromptCommandOutcome?
            e.ui { e.model.restore(revision) { result = $0; XCTAssertTrue(e.h.marker.isUI) } }
            XCTAssertEqual(e.model.state.status, queuedMain ? .idle : .commandRunning)
            e.settle()
            XCTAssertNotNil(result?.committedEntry)
            XCTAssertEqual(e.model.state.prompt, selection)
            XCTAssertNotEqual(e.model.state.stamp, stamp)
            XCTAssertEqual(e.model.state.stamp, try e.h.files.stamp(at: "a.md"))
            XCTAssertTrue(try XCTUnwrap(e.model.state.source).hasSuffix(body))
            XCTAssertEqual(e.model.state.history.revisions.count, 2)
            XCTAssertEqual(e.model.state.history.revisions[0].source, historyCommandSource)
            XCTAssertEqual(e.model.state.history.selectedRevision, revision)
            XCTAssertFalse(e.model.state.isDirty)
            XCTAssertNil(e.model.state.conflict)
        }
    }

    func testStaleRestoreOpensConflictAndKeepsLoadedBuffer() throws {
        let e = EditorHarness()
        let selection = try e.open(historyCommandSource)
        let revision = try historySnapshot(e.h, identity: selection.identity)
        try e.h.files.put(historyCommandSource + "Theirs", at: "a.md")
        var result: PromptCommandOutcome?
        e.ui { e.model.restore(revision) { result = $0 } }
        guard case .conflict(let stamp) = result else { return XCTFail("Expected stamped restore conflict.") }
        XCTAssertEqual(e.model.state.conflict?.stamp, stamp)
        XCTAssertEqual(e.model.state.conflict?.theirsSource, historyCommandSource + "Theirs")
        XCTAssertEqual(e.model.state.source, historyCommandSource)
        XCTAssertEqual(try e.h.library.history(for: selection.identity), [revision])
    }

    func testRestoreHistoryMaintenanceWarningIsCommittedAndReloaded() throws {
        let e = EditorHarness()
        let selection = try e.open(historyCommandSource)
        let revision = try historySnapshot(e.h, identity: selection.identity)
        for _ in 1..<Limits.historyCapPerPrompt { try historySnapshot(e.h, identity: selection.identity) }
        e.h.data.failNextDelete = true
        var result: PromptCommandOutcome?
        e.ui { e.model.restore(revision) { result = $0 } }
        guard case .updatedButHistoryMaintenanceFailed(let entry) = result else {
            return XCTFail("Expected committed retention warning.")
        }
        XCTAssertEqual(e.model.state.stamp, entry.stamp)
        XCTAssertEqual(e.model.state.source, entry.document.source)
        XCTAssertTrue(e.model.state.historyMaintenanceFailed)
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertEqual(e.model.state.history.revisions.count, Limits.historyCapPerPrompt + 1)
    }

    func testMissingOrWrongIdentityRevisionIsTypedFailure() throws {
        for missing in [false, true] {
            let e = EditorHarness()
            let selection = try e.open(historyCommandSource)
            let identity = missing ? selection.identity : PromptIdentity(path: "other.md", id: nil)
            let revision = try historySnapshot(e.h, identity: identity)
            if missing { try HistoryStore(files: e.h.data).remove(revision) }
            var result: PromptCommandOutcome?
            e.ui { e.model.restore(revision) { result = $0 } }
            guard case .failed(let failure) = result else { return XCTFail("Expected revision failure.") }
            XCTAssertEqual(failure, .library(missing ? .revisionNotFound : .identityMismatch))
            XCTAssertEqual(try e.h.files.text(at: "a.md"), historyCommandSource)
        }
    }

    func testHistoryFailuresAreSanitizedAndRetiredRepliesAreDropped() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        let selection = try e.open(historyCommandSource)
        try historySnapshot(e.h, identity: selection.identity)
        e.h.dataFiles.onList = { throw EditingTestError.privateDetails }
        e.ui { e.model.loadHistory() }
        e.settle()
        XCTAssertEqual(e.model.state.history.failure, .library(.operationFailed))
        XCTAssertFalse(e.model.state.history.isLoading)
        e.h.dataFiles.onList = nil
        e.ui { e.model.loadHistory() }
        e.h.held.releaseAll()
        e.ui { e.model.close() }
        e.settle()
        XCTAssertNil(e.model.state.prompt)
        XCTAssertTrue(e.model.state.history.revisions.isEmpty)
    }

    func testNewerDraftAfterRestoreReplySurvivesCheckedReload() throws {
        let e = EditorHarness(heldWork: true)
        let selection = try e.open(historyCommandSource)
        let revision = try historySnapshot(e.h, identity: selection.identity)
        e.ui { e.model.restore(revision) }
        e.h.held.releaseNext()
        e.ui { e.model.edit("Draft after restore") }
        try e.change(historyCommandSource + "External after restore")
        e.settle()
        XCTAssertEqual(e.model.state.source, "Draft after restore")
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertEqual(e.model.state.conflict?.theirsSource, historyCommandSource + "External after restore")
    }
}
