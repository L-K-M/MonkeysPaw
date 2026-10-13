import Foundation
import XCTest
@testable import MonkeysPawCore

final class ProvenanceTests: XCTestCase {
    private let metadata = PromptProvenance(timestamp: Date(timeIntervalSince1970: 1.234),
        providerHost: "example.com", model: "model-1", usage: AssistantTokenUsage(inputTokens: 11, outputTokens: 7))

    private func origin(_ seconds: Double) -> PromptProvenance {
        PromptProvenance(timestamp: Date(timeIntervalSince1970: seconds), providerHost: "example.com", model: "model-1",
            usage: AssistantTokenUsage(inputTokens: 11, outputTokens: 7))
    }

    private func save(_ h: PromptEditingHarness, _ source: String, stamp: FileStamp? = nil,
                      provenance: PromptProvenance? = nil) throws -> PromptSaveOutcome {
        try h.library.saveForEditing(PromptCodec.parse(source, filename: "a.md"), at: "a.md",
                                    expectedStamp: stamp, provenance: provenance)
    }

    func testHeadRecordIsVersionedUTCPrivateAndContentBound() throws {
        let h = PromptEditingHarness()
        let entry = try XCTUnwrap(save(h, "Generated\r\n", provenance: metadata).committedEntry)
        XCTAssertEqual(try h.library.provenance(at: "a.md"), metadata)
        XCTAssertTrue(try h.library.history(for: entry.identity).isEmpty)
        let path = "history/" + (try entry.identity.storageKey) + "/head.json"
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: h.data.read(at: path)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["origin"] as? String, "llm")
        XCTAssertEqual(object["timestamp"] as? String, "1970-01-01T00:00:01.234Z")
        XCTAssertEqual(object["contentSHA256"] as? String, SHA256.hexDigest(try h.files.read(at: "a.md")))
        XCTAssertTrue(h.data.isPrivate(at: path))
        try h.files.put(entry.document.source + "External", at: "a.md")
        XCTAssertNil(try h.library.provenance(at: "a.md"))
    }

    func testManualSaveArchivesOriginAndRestoreRecoversIt() throws {
        let h = PromptEditingHarness()
        let generated = try XCTUnwrap(save(h, "Generated", provenance: metadata).committedEntry)
        let manual = try XCTUnwrap(save(h, "Manual", stamp: generated.stamp).committedEntry)
        XCTAssertEqual(manual.identity, generated.identity)
        XCTAssertNil(try h.library.provenance(at: "a.md"))
        let revision = try XCTUnwrap(h.library.history(for: manual.identity).first)
        XCTAssertEqual(try h.library.provenance(for: revision), metadata)
        let snapshots = try h.library.historyForEditing(manual.identity, filename: "a.md")
        XCTAssertEqual(snapshots.first?.provenance, metadata)
        let restored = try h.library.restore(revision, at: "a.md", expectedStamp: manual.stamp)
        XCTAssertEqual(restored.document.body, "Generated")
        XCTAssertEqual(try h.library.provenance(at: "a.md"), metadata)
        XCTAssertNil(try h.library.provenance(for: XCTUnwrap(h.library.history(for: manual.identity).first)))
    }

    func testHistoryListingOmitsCorruptSidecarAndRestoreCommitsWithProvenanceWarning() throws {
        let h = PromptEditingHarness()
        var entry = try XCTUnwrap(save(h, "First", provenance: origin(1)).committedEntry)
        for (offset, source) in ["Second", "Third", "Current"].enumerated() {
            entry = try XCTUnwrap(save(h, source, stamp: entry.stamp, provenance: origin(Double(offset + 2))).committedEntry)
        }
        let revisions = try h.library.history(for: entry.identity)
        XCTAssertEqual(revisions.count, 3)
        let corrupt = try XCTUnwrap(revisions.dropFirst().first)
        let revisionPath = "history/" + (try entry.identity.storageKey) + "/" + corrupt.filename
        let sidecarPath = revisionPath + ".json"
        try h.data.put("Corrupt JSON", at: sidecarPath)
        let before = try h.data.listFiles()
        let snapshots = try h.library.historyForEditing(entry.identity, filename: "a.md")
        XCTAssertEqual(snapshots.map(\.revision), revisions)
        XCTAssertEqual(snapshots.compactMap(\.source).map { PromptCodec.parse($0, filename: "a.md").body },
                       ["Third", "Second", "First"])
        XCTAssertEqual(snapshots.map(\.provenance), [origin(3), nil, origin(1)])
        XCTAssertThrowsError(try h.library.provenance(for: corrupt)) {
            XCTAssertEqual($0 as? LibraryError, .invalidProvenance)
        }
        XCTAssertEqual(try h.data.listFiles(), before)
        guard case .updatedButProvenanceFailed(let restored, false) =
            try h.library.restoreForEditing(corrupt, at: "a.md", expectedStamp: entry.stamp) else {
            return XCTFail("Corrupt provenance must warn after restoring readable revision content.")
        }
        XCTAssertEqual(restored.document.body, "Second")
        XCTAssertEqual(restored.stamp, try h.files.stamp(at: "a.md"))
        XCTAssertNil(try h.library.provenance(at: "a.md"))
        XCTAssertEqual(try h.data.text(at: sidecarPath), "Corrupt JSON")

        for unreadablePath in [sidecarPath, revisionPath] {
            h.data.onRead = { path in if path == unreadablePath { throw FileStoreError.ioFailure } }
            XCTAssertThrowsError(try h.library.historyForEditing(entry.identity, filename: "a.md")) {
                XCTAssertEqual($0 as? FileStoreError, .ioFailure)
            }
            XCTAssertThrowsError(try h.library.restoreForEditing(corrupt, at: "a.md", expectedStamp: restored.stamp)) {
                XCTAssertEqual($0 as? FileStoreError, .ioFailure)
            }
            XCTAssertEqual(try h.files.read(at: "a.md"), Data(restored.document.source.utf8))
        }
    }

    func testUnassignedRenameMoveAndFirstSaveMigrateAllRecordsAndDeleteRetainsThem() throws {
        let h = PromptEditingHarness()
        try h.files.put("Original", at: "a.md")
        let identity = try h.library.load(at: "a.md").identity
        let store = HistoryStore(files: h.data)
        let revision = try store.snapshot(Data("Older".utf8), for: identity, at: h.clock.date)
        try store.setHeadProvenance(metadata, for: identity, bytes: Data("Original".utf8))
        try store.archiveProvenance(metadata, for: revision, bytes: Data("Older".utf8))
        let renamed = try h.library.move(from: "a.md", to: "renamed.md")
        let moved = try h.library.move(from: "renamed.md", to: "folder/renamed.md")
        XCTAssertNotEqual(renamed.identity, identity)
        XCTAssertNotEqual(moved.identity, renamed.identity)
        XCTAssertEqual(try h.library.provenance(at: moved.relativePath), metadata)
        let assigned = try h.library.assignIdentity(to: moved.relativePath, expectedStamp: moved.stamp)
        guard case .assigned = assigned.identity else { return XCTFail("Expected first-save identity.") }
        let histories = try h.library.history(for: assigned.identity)
        XCTAssertEqual(histories.count, 2)
        for item in histories { XCTAssertEqual(try h.library.provenance(for: item), metadata) }
        XCTAssertNil(try h.library.provenance(at: assigned.relativePath))
        let before = try h.data.listFiles()
        try h.library.delete(at: assigned.relativePath, expectedStamp: assigned.stamp)
        XCTAssertEqual(try h.data.listFiles(), before)
        XCTAssertEqual(try h.library.history(for: assigned.identity), histories)
    }

    func testAssignedMovesKeepHeadAndRevisionProvenanceWithoutMigration() throws {
        let h = PromptEditingHarness()
        let first = try XCTUnwrap(save(h, "First", provenance: origin(1)).committedEntry)
        let second = try XCTUnwrap(save(h, "Second", stamp: first.stamp, provenance: origin(2)).committedEntry)
        let before = try h.data.listFiles()
        let renamed = try h.library.move(from: "a.md", to: "b.md")
        let moved = try h.library.move(from: "b.md", to: "folder/b.md")
        XCTAssertEqual(moved.identity, first.identity)
        XCTAssertEqual(renamed.identity, first.identity)
        XCTAssertEqual(try h.data.listFiles(), before)
        XCTAssertEqual(try h.library.provenance(at: moved.relativePath), origin(2))
        let revision = try XCTUnwrap(h.library.history(for: moved.identity).first)
        XCTAssertEqual(try h.library.provenance(for: revision), origin(1))
        try h.library.delete(at: moved.relativePath, expectedStamp: second.stamp)
        XCTAssertEqual(try h.data.listFiles(), before)
    }

    func testHistoryCapPrunesSidecarsAndLeavesUnrelatedFiles() throws {
        let h = PromptEditingHarness()
        var entry = try XCTUnwrap(save(h, "0", provenance: metadata).committedEntry)
        try h.data.put("Keep", at: "settings.json")
        let directory = "history/" + (try entry.identity.storageKey)
        try h.data.put("Keep too", at: directory + "/unrecognized.json")
        for index in 1...(Limits.historyCapPerPrompt + 3) {
            entry = try XCTUnwrap(save(h, "\(index)", stamp: entry.stamp, provenance: metadata).committedEntry)
        }
        let revisions = try h.library.history(for: entry.identity)
        XCTAssertEqual(revisions.count, Limits.historyCapPerPrompt)
        for revision in revisions { XCTAssertEqual(try h.library.provenance(for: revision), metadata) }
        let sidecars = try h.data.listFiles().filter { $0.relativePath.hasSuffix(".md.json") }
        XCTAssertEqual(sidecars.count, Limits.historyCapPerPrompt)
        XCTAssertEqual(try h.data.text(at: "settings.json"), "Keep")
        XCTAssertEqual(try h.data.text(at: directory + "/unrecognized.json"), "Keep too")
    }

    func testHistoryListingIgnoresOrphanedSidecarsWithoutReadingThem() throws {
        let h = PromptEditingHarness()
        let first = try XCTUnwrap(save(h, "First", provenance: metadata).committedEntry)
        let second = try XCTUnwrap(save(h, "Second", stamp: first.stamp).committedEntry)
        let revision = try XCTUnwrap(h.library.history(for: second.identity).first)
        let path = "history/" + (try second.identity.storageKey) + "/" + revision.filename
        try h.data.delete(at: path)
        XCTAssertNotNil(try h.data.stamp(at: path + ".json"))
        h.data.onRead = { read in if read == path + ".json" { XCTFail("Listings must ignore orphaned sidecars.") } }

        XCTAssertTrue(try h.library.historyForEditing(second.identity, filename: "a.md").isEmpty)
        XCTAssertThrowsError(try h.library.provenance(for: revision)) {
            XCTAssertEqual($0 as? LibraryError, .revisionNotFound)
        }
    }

    func testHeadAndArchiveWriteFailuresAreCommittedWarnings() throws {
        for archive in [false, true] {
            let h = PromptEditingHarness()
            var stamp: FileStamp?
            if archive { stamp = try XCTUnwrap(save(h, "Before", provenance: metadata).committedEntry).stamp }
            h.dataFiles.beforeWrite = { path in
                if path.hasSuffix(archive ? ".md.json" : "/head.json") { throw FileStoreError.ioFailure }
            }
            guard case .savedButProvenanceFailed(let entry, let history) = try save(h, "Committed", stamp: stamp,
                                                                                  provenance: metadata) else {
                return XCTFail("A provenance failure must carry the commit.")
            }
            XCTAssertFalse(history)
            XCTAssertEqual(entry.stamp, try h.files.stamp(at: "a.md"))
            XCTAssertEqual(entry.document.body, "Committed")
            if archive { XCTAssertEqual(try h.library.provenance(at: "a.md"), metadata) }
        }
    }

    func testPublicationFailureRollsBackHistoryAndPreservesHead() throws {
        let h = PromptEditingHarness()
        let first = try XCTUnwrap(save(h, "Before", provenance: metadata).committedEntry)
        let before = try h.data.listFiles()
        h.files.failNextWrite = true
        XCTAssertThrowsError(try save(h, "Failed", stamp: first.stamp, provenance: metadata))
        XCTAssertEqual(try h.data.listFiles(), before)
        XCTAssertEqual(try h.library.provenance(at: "a.md"), metadata)
        XCTAssertEqual(try h.files.text(at: "a.md"), first.document.source)
    }

    func testExternalReplacementAfterPublicationKeepsArchivedProvenance() throws {
        let h = PromptEditingHarness()
        let first = try XCTUnwrap(save(h, "Before", provenance: metadata).committedEntry)
        h.files.onWrite = { path in
            guard path == "a.md" else { return }
            h.files.onWrite = nil
            do { try h.files.put(first.document.source + "External", at: path) }
            catch { XCTFail("Could not publish the test's external replacement.") }
        }
        guard case .conflict = try save(h, "Committed", stamp: first.stamp, provenance: metadata) else {
            return XCTFail("Expected post-publication replacement conflict.")
        }
        let revision = try XCTUnwrap(h.library.history(for: first.identity).first)
        XCTAssertEqual(try h.library.provenance(for: revision), metadata)
        XCTAssertNil(try h.library.provenance(at: "a.md"))
    }

    func testUnknownVersionAndInvalidMetadataFailExplicitly() throws {
        let h = PromptEditingHarness()
        let first = try XCTUnwrap(save(h, "Before", provenance: metadata).committedEntry)
        let path = "history/" + (try first.identity.storageKey) + "/head.json"
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: h.data.read(at: path)) as? [String: Any])
        record["version"] = 2
        try h.data.write(JSONSerialization.data(withJSONObject: record), at: path)
        XCTAssertThrowsError(try h.library.provenance(at: "a.md")) {
            XCTAssertEqual($0 as? LibraryError, .invalidProvenance)
        }
        guard case .savedButProvenanceFailed(let entry, false) = try save(h, "Manual", stamp: first.stamp) else {
            return XCTFail("Unavailable provenance must remain explicit after commit.")
        }
        XCTAssertEqual(entry.document.body, "Manual")
        XCTAssertNil(try h.library.provenance(at: "a.md"))
    }

    func testCorruptHeadDoesNotBlockEditorSaveAndIsReplacedWithExplicitWarning() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        let generated = try XCTUnwrap(save(e.h, "Generated", provenance: metadata).committedEntry)
        let path = "history/" + (try generated.identity.storageKey) + "/head.json"
        try e.h.data.put("Corrupt JSON", at: path)
        XCTAssertThrowsError(try e.h.library.provenance(at: "a.md")) {
            XCTAssertEqual($0 as? LibraryError, .invalidProvenance)
        }
        try e.h.index.rebuild()
        e.ui { e.model.open(e.selection(generated)) }
        e.settle()
        e.ui { e.model.edit(generated.document.source + " Manual"); e.model.save() }
        e.settle()

        XCTAssertEqual(e.model.state.status, .saved)
        XCTAssertTrue(e.model.state.provenanceMaintenanceFailed)
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertEqual(e.model.state.stamp, try e.h.files.stamp(at: "a.md"))
        XCTAssertNil(try e.h.data.stamp(at: path))
        XCTAssertNil(try e.h.library.provenance(at: "a.md"))
    }

    func testEditorRestoreWithCorruptProvenanceAdoptsCommitAndBothMaintenanceWarnings() throws {
        for historyFailure in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: true)
            let first = try XCTUnwrap(save(e.h, "Generated", provenance: metadata).committedEntry)
            let current = try XCTUnwrap(save(e.h, "Manual", stamp: first.stamp).committedEntry)
            let revision = try XCTUnwrap(e.h.library.history(for: current.identity).first)
            let directory = "history/" + (try current.identity.storageKey)
            try e.h.data.put("Corrupt JSON", at: directory + "/" + revision.filename + ".json")
            if historyFailure {
                let store = HistoryStore(files: e.h.data)
                for _ in 1..<Limits.historyCapPerPrompt {
                    _ = try store.snapshot(Data("Older".utf8), for: current.identity, at: e.h.clock.date)
                }
                e.h.dataFiles.onDelete = { path in if path.hasSuffix(".md") { throw FileStoreError.ioFailure } }
            }
            try e.h.index.rebuild()
            e.ui { e.model.open(e.selection(current)) }
            e.settle()
            var replies: [PromptCommandOutcome] = []
            e.ui { e.model.restore(revision) { replies.append($0); XCTAssertTrue(e.h.marker.isUI) } }
            e.settle()

            XCTAssertEqual(replies.count, 1)
            guard case .updatedButProvenanceFailed(let restored, let history) = replies.first else {
                return XCTFail("Restore must commit readable content and report its unavailable provenance.")
            }
            XCTAssertEqual(history, historyFailure)
            XCTAssertEqual(restored.document.body, "Generated")
            XCTAssertEqual(e.model.state.source, restored.document.source)
            XCTAssertEqual(e.model.state.stamp, restored.stamp)
            XCTAssertEqual(e.h.index.cachedEntry(at: "a.md")?.stamp, restored.stamp)
            XCTAssertTrue(e.model.state.provenanceMaintenanceFailed)
            XCTAssertEqual(e.model.state.historyMaintenanceFailed, historyFailure)
            XCTAssertFalse(e.model.state.isDirty)
        }
    }

    func testSynchronousRestoreReportsCorruptProvenanceOnlyAfterContentCommits() throws {
        let h = PromptEditingHarness()
        let first = try XCTUnwrap(save(h, "Generated", provenance: metadata).committedEntry)
        let current = try XCTUnwrap(save(h, "Manual", stamp: first.stamp).committedEntry)
        let revision = try XCTUnwrap(h.library.history(for: current.identity).first)
        let path = "history/" + (try current.identity.storageKey) + "/" + revision.filename + ".json"
        try h.data.put("Corrupt JSON", at: path)

        XCTAssertThrowsError(try h.library.restore(revision, at: "a.md", expectedStamp: current.stamp)) {
            XCTAssertEqual($0 as? LibraryError, .provenanceMaintenanceFailed)
        }
        let restored = try h.library.load(at: "a.md")
        XCTAssertEqual(restored.document.body, "Generated")
        XCTAssertNotEqual(restored.stamp, current.stamp)
        XCTAssertNil(try h.library.provenance(at: "a.md"))
    }
}
