import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptHistoryCommandTests: XCTestCase {
    func testEveryCommandRunsOnWorkAndRepliesOnMainWithoutOwnExternalChanges() throws {
        for heldWork in [false, true] {
            for queuedMain in [false, true] {
                for command in HistoryTestCommand.allCases {
                    let h = PromptEditingHarness(heldWork: heldWork)
                    var changes: [PromptExternalChange] = []
                    let (session, loaded) = try h.open(historyCommandSource) { changes.append($0) }
                    let revision = try historySnapshot(h, identity: loaded.entry.identity)
                    h.main.isHeld = queuedMain
                    var outcome: PromptCommandOutcome?
                    h.marker.ui { command.run(h.editor, session: session, stamp: loaded.stamp, revision: revision) {
                        outcome = $0
                        XCTAssertTrue(h.marker.isUI)
                    } }
                    if heldWork {
                        XCTAssertNil(outcome)
                        XCTAssertEqual(try h.files.text(at: "a.md"), historyCommandSource)
                    }
                    h.held.releaseAll()
                    if queuedMain { XCTAssertNil(outcome) }
                    h.main.releaseAll()
                    let result = try XCTUnwrap(outcome)
                    if command == .delete {
                        guard case .deleted = result else { return XCTFail("Expected delete success.") }
                        XCTAssertNil(try h.files.stamp(at: "a.md"))
                        XCTAssertEqual(try h.library.history(for: loaded.entry.identity), [revision])
                    } else {
                        let entry = try XCTUnwrap(result.committedEntry)
                        XCTAssertEqual(entry.relativePath, command.destination)
                        XCTAssertEqual(entry.identity, loaded.entry.identity)
                        XCTAssertEqual(entry.document.body, command == .restore ? "Previous\r\n" : "Original\r\n")
                        var load: PromptLoadOutcome?
                        h.marker.ui { h.editor.load(session: session) { load = $0 } }
                        h.held.releaseAll(); h.main.releaseAll()
                        guard case .loaded(let current) = load else { return XCTFail("Moved session did not follow its file.") }
                        XCTAssertEqual(current.entry.relativePath, command.destination)
                    }
                    XCTAssertTrue(changes.isEmpty, "Own \(command) publication must stay quiet.")
                }
            }
        }
    }

    func testEveryCommandRejectsStaleStampBeforeMigrationOrHistoryWork() throws {
        for command in HistoryTestCommand.allCases {
            let h = PromptEditingHarness()
            let (session, loaded) = try h.open(historyCommandSource)
            let revision = try historySnapshot(h, identity: loaded.entry.identity)
            h.keyed.values[loaded.entry.identity] = "remembered"
            try h.files.put(historyCommandSource + "Theirs", at: "a.md")
            let stamp = try h.files.stamp(at: "a.md")
            let accesses = h.data.accessCount
            let outcome = try commandResult(h) { command.run(h.editor, session: session, stamp: loaded.stamp,
                revision: revision, completion: $0) }
            guard case .conflict(let current) = outcome else { return XCTFail("Expected stale \(command) conflict.") }
            XCTAssertEqual(current, stamp)
            XCTAssertEqual(h.data.accessCount, accesses)
            XCTAssertEqual(try h.files.text(at: "a.md"), historyCommandSource + "Theirs")
            XCTAssertTrue(h.keyed.migrations.isEmpty)
        }
    }

    func testEveryCommandReportsMissingAndNeverRestoresDeletedPrompt() throws {
        for command in HistoryTestCommand.allCases {
            let h = PromptEditingHarness()
            let (session, loaded) = try h.open(historyCommandSource)
            let revision = try historySnapshot(h, identity: loaded.entry.identity)
            try h.files.delete(at: "a.md")
            let outcome = try commandResult(h) { command.run(h.editor, session: session, stamp: loaded.stamp,
                revision: revision, completion: $0) }
            guard case .missing = outcome else { return XCTFail("Expected missing \(command).") }
            XCTAssertTrue(try h.files.listFiles().isEmpty)
            XCTAssertEqual(try h.library.history(for: loaded.entry.identity), [revision])
        }
    }

    func testEveryCommandRefusesFutureFormatWithoutFileOrHistoryWrites() throws {
        for command in HistoryTestCommand.allCases {
            let h = PromptEditingHarness()
            let source = "---\nformat: 2\n---\nFuture"
            let (session, loaded) = try h.open(source)
            let revision = try historySnapshot(h, identity: loaded.entry.identity)
            let outcome = try commandResult(h) { command.run(h.editor, session: session, stamp: loaded.stamp,
                revision: revision, completion: $0) }
            guard case .readOnly(let reason) = outcome else { return XCTFail("Expected read-only \(command).") }
            XCTAssertEqual(reason, .unsupportedFormat(PromptFormatVersion(2)!))
            XCTAssertEqual(try h.files.text(at: "a.md"), source)
            XCTAssertEqual(try h.library.history(for: loaded.entry.identity), [revision])
        }
    }

    func testRenameAndMoveRefuseOccupiedDestinationsWithoutMigration() throws {
        for command in [HistoryTestCommand.rename, .move] {
            let h = PromptEditingHarness()
            let (session, loaded) = try h.open("Original")
            let revision = try historySnapshot(h, identity: loaded.entry.identity)
            h.keyed.values[loaded.entry.identity] = "remembered"
            try h.files.put("Occupied", at: command.destination)
            let outcome = try commandResult(h) { command.run(h.editor, session: session, stamp: loaded.stamp,
                revision: revision, completion: $0) }
            guard case .destinationOccupied = outcome else { return XCTFail("Expected occupied destination.") }
            XCTAssertEqual(try h.files.text(at: "a.md"), "Original")
            XCTAssertEqual(try h.files.text(at: command.destination), "Occupied")
            XCTAssertTrue(h.keyed.migrations.isEmpty)
            XCTAssertEqual(try h.library.history(for: loaded.entry.identity), [revision])
        }
    }

    func testRacedOccupiedDestinationRollsBackLocalHistoryAndValues() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open("Original")
        let revision = try historySnapshot(h, identity: loaded.entry.identity)
        h.keyed.values[loaded.entry.identity] = "remembered"
        h.files.onMove = { _, destination in try h.files.put("Raced", at: destination) }
        let outcome = try commandResult(h) { h.editor.rename(to: "renamed.md", session: session,
            expectedStamp: loaded.stamp, completion: $0) }
        guard case .destinationOccupied = outcome else { return XCTFail("Expected raced occupied destination.") }
        XCTAssertEqual(try h.files.text(at: "a.md"), "Original")
        XCTAssertEqual(try h.files.text(at: "renamed.md"), "Raced")
        XCTAssertEqual(h.keyed.values[loaded.entry.identity], "remembered")
        XCTAssertEqual(try h.library.history(for: loaded.entry.identity), [revision])
        XCTAssertTrue(try h.library.history(for: PromptIdentity(path: "renamed.md", id: nil)).isEmpty)
    }

    func testLocalMoveMigratesHistoryAndValuesWithoutAssigningID() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open("---\ntitle: Keep title\n---\nOriginal")
        let revision = try historySnapshot(h, identity: loaded.entry.identity)
        h.keyed.values[loaded.entry.identity] = "remembered"
        let outcome = try commandResult(h) { h.editor.move(to: "new/deep", session: session,
            expectedStamp: loaded.stamp, completion: $0) }
        let moved = try XCTUnwrap(outcome.committedEntry)
        XCTAssertEqual(moved.identity, PromptIdentity(path: "new/deep/a.md", id: nil))
        XCTAssertNil(moved.document.frontMatter.id)
        XCTAssertEqual(moved.document.frontMatter.title, "Keep title")
        XCTAssertEqual(h.keyed.values[moved.identity], "remembered")
        XCTAssertNil(h.keyed.values[loaded.entry.identity])
        XCTAssertTrue(try h.library.history(for: loaded.entry.identity).isEmpty)
        let migrated = try XCTUnwrap(h.library.history(for: moved.identity).first)
        XCTAssertEqual(migrated.filename, revision.filename)
        let restored = try commandResult(h) { h.editor.restore(migrated, session: session,
            expectedStamp: moved.stamp, completion: $0) }
        XCTAssertEqual(restored.committedEntry?.document.body, "Previous\r\n")
        XCTAssertNotNil(restored.committedEntry?.document.frontMatter.id)
    }

    func testInvalidNamesAndFoldersAreTypedFailures() throws {
        for filename in ["../bad.md", "folder/name.md", "", "bad.txt", "_hidden.md", "README.md", "bad\\name.md"] {
            let h = PromptEditingHarness()
            let (session, loaded) = try h.open()
            let outcome = try commandResult(h) { h.editor.rename(to: filename, session: session,
                expectedStamp: loaded.stamp, completion: $0) }
            guard case .failed = outcome else { return XCTFail("Invalid filename was accepted.") }
            XCTAssertEqual(try h.files.text(at: "a.md"), "Original")
        }
        for folder in ["../outside", "/absolute", "a//b", ".hidden", "_hidden", "a/../b"] {
            let h = PromptEditingHarness()
            let (session, loaded) = try h.open()
            let outcome = try commandResult(h) { h.editor.move(to: folder, session: session,
                expectedStamp: loaded.stamp, completion: $0) }
            guard case .failed = outcome else { return XCTFail("Invalid folder was accepted.") }
        }
    }

    func testSamePathAndRootMoveAreSuccessfulWithoutHistoryGrowth() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open()
        let same = try commandResult(h) { h.editor.rename(to: "a.md", session: session,
            expectedStamp: loaded.stamp, completion: $0) }
        XCTAssertEqual(same.committedEntry?.stamp, loaded.stamp)
        let moved = try commandResult(h) { h.editor.move(to: "folder", session: session,
            expectedStamp: loaded.stamp, completion: $0) }
        let movedStamp = try XCTUnwrap(moved.committedEntry).stamp
        let back = try commandResult(h) { h.editor.move(to: "", session: session,
            expectedStamp: movedStamp, completion: $0) }
        XCTAssertEqual(back.committedEntry?.relativePath, "a.md")
        XCTAssertTrue(try h.data.listFiles().isEmpty)
    }

    func testCommandIOAndMigrationFailuresAreTypedAndPreserveSource() throws {
        for command in [HistoryTestCommand.rename, .move, .delete, .restore] {
            let h = PromptEditingHarness()
            let (session, loaded) = try h.open(historyCommandSource)
            let revision = try historySnapshot(h, identity: loaded.entry.identity)
            switch command {
            case .rename, .move: h.files.failMoveNumber = 1
            case .delete: h.files.failNextDelete = true
            case .restore: h.files.failNextWrite = true
            }
            let outcome = try commandResult(h) { command.run(h.editor, session: session, stamp: loaded.stamp,
                revision: revision, completion: $0) }
            guard case .failed(let failure) = outcome else { return XCTFail("Expected file failure.") }
            XCTAssertEqual(failure, .fileStore(.ioFailure))
            XCTAssertEqual(try h.files.text(at: "a.md"), historyCommandSource)
            XCTAssertEqual(try h.library.history(for: loaded.entry.identity), [revision])
        }
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open()
        h.keyed.values[loaded.entry.identity] = "remembered"
        h.keyed.failNextMigration = true
        let outcome = try commandResult(h) { h.editor.rename(to: "renamed.md", session: session,
            expectedStamp: loaded.stamp, completion: $0) }
        guard case .failed(let failure) = outcome else { return XCTFail("Expected migration failure.") }
        XCTAssertEqual(failure, .fileStore(.ioFailure))
        XCTAssertEqual(try h.files.text(at: "a.md"), "Original")
    }

    func testMovedSessionIgnoresQueuedOldPathPublicationAndObservesNewPath() throws {
        let h = PromptEditingHarness()
        var changes: [PromptExternalChange] = []
        let (session, loaded) = try h.open(historyCommandSource) { changes.append($0) }
        h.main.isHeld = true
        try h.index.apply(LibraryChangeSet(modified: ["a.md"]))
        let outcome = try commandResult(h) { h.editor.rename(to: "renamed.md", session: session,
            expectedStamp: loaded.stamp, completion: $0) }
        XCTAssertNotNil(outcome.committedEntry)
        XCTAssertTrue(changes.isEmpty)
        try h.files.put(historyCommandSource + "External", at: "renamed.md")
        try h.index.apply(LibraryChangeSet(modified: ["renamed.md"]))
        h.main.releaseAll()
        XCTAssertEqual(changes, [PromptExternalChange(kind: .modified, newStamp: try h.files.stamp(at: "renamed.md"))])
    }

    func testMoveKeepsBasenameWhenCombiningMarkSharesSlashGrapheme() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open(historyCommandSource, at: "from/\u{301}a.md")
        let renamed = try commandResult(h) { h.editor.rename(to: "\u{301}renamed.md", session: session,
            expectedStamp: loaded.stamp, completion: $0) }
        let stamp = try XCTUnwrap(renamed.committedEntry?.stamp)
        let moved = try commandResult(h) { h.editor.move(to: "to", session: session,
            expectedStamp: stamp, completion: $0) }
        XCTAssertEqual(moved.committedEntry.map { RelativePath($0.relativePath) }, RelativePath("to/\u{301}renamed.md"))
        XCTAssertEqual(try h.files.text(at: "to/\u{301}renamed.md"), historyCommandSource)
    }

    func testCommittedMoveReturnsDestinationObservationAndKeepsSessionThere() throws {
        for observation in 0..<3 {
            let h = PromptEditingHarness()
            let (session, loaded) = try h.open(historyCommandSource)
            h.files.onRead = { path in
                guard path == "renamed.md" else { return }
                if observation == 2 { throw FileStoreError.ioFailure }
                h.files.onRead = nil
                if observation == 0 { try h.files.put(historyCommandSource + "External", at: path) }
                else { try h.files.delete(at: path) }
            }
            let result = try commandResult(h) { h.editor.rename(to: "renamed.md", session: session,
                expectedStamp: loaded.stamp, completion: $0) }
            guard case .relocated(let baseline, let current) = result else { return XCTFail("Expected checked relocation.") }
            XCTAssertEqual(baseline.relativePath, "renamed.md")
            XCTAssertEqual(baseline.identity, loaded.entry.identity)
            XCTAssertEqual(baseline.document.source, historyCommandSource)
            XCTAssertNil(result.committedEntry, "A divergent destination cannot be treated as an ordinary successful update.")
            switch (observation, current) {
            case (0, .loaded(let external)):
                XCTAssertEqual(external.source, historyCommandSource + "External")
                XCTAssertEqual(external.stamp, try h.files.stamp(at: "renamed.md"))
            case (1, .deleted): break
            case (2, .failed(let failure)): XCTAssertEqual(failure, .fileStore(.ioFailure))
            default: XCTFail("Incorrect destination observation.")
            }
            h.files.onRead = nil
            var reloaded: PromptLoadOutcome?
            h.marker.ui { h.editor.load(session: session) { reloaded = $0 } }
            if observation == 1 {
                guard case .deleted = reloaded else { return XCTFail("Expected missing destination.") }
            } else {
                guard case .loaded(let current) = reloaded else { return XCTFail("Expected destination reload.") }
                XCTAssertEqual(current.entry.relativePath, "renamed.md")
            }
            XCTAssertNil(try h.files.stamp(at: "a.md"))
        }
    }

    func testMissingHistoryMigrationFileDoesNotReportLivePromptMissing() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open()
        let revision = try historySnapshot(h, identity: loaded.entry.identity)
        h.data.onMove = { _, _ in throw FileStoreError.notFound }
        let result = try commandResult(h) { h.editor.rename(to: "renamed.md", session: session,
            expectedStamp: loaded.stamp, completion: $0) }
        guard case .failed(let failure) = result else { return XCTFail("An app-data failure cannot report prompt deletion.") }
        XCTAssertEqual(failure, .fileStore(.notFound))
        XCTAssertEqual(try h.files.text(at: "a.md"), "Original")
        XCTAssertEqual(try h.library.history(for: loaded.entry.identity), [revision])
    }
}
