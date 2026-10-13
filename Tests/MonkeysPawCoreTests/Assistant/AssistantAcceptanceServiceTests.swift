import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantAcceptanceServiceTests: XCTestCase {
    private let id = ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PD")!

    private func prepared(_ e: EditorHarness, improve: Bool = false, body: String = "  文書 e\u{301}\r\n\n") throws -> AssistantPreparedSave {
        let artifact = LlmArtifact(title: "Candidate", description: "", tags: [], fields: [], body: body, notes: "Never persist")
        let result = improve ? ArtifactMerge.improve(artifact, original: try XCTUnwrap(e.model.assistantSnapshot).document)
            : ArtifactMerge.write(artifact, id: id)
        guard case .ready(var content) = result else { throw EditingTestError.unexpectedOutcome }
        if content.document.frontMatter.id == nil {
            let document = try PromptCodec.assigningIdentity(id, to: content.document)
            content = ArtifactMergeCandidate(document: document, canonicalBytes: Data(try PromptCodec.write(document).utf8))
        }
        return AssistantPreparedSave(content: content,
            metadata: AssistantSaveMetadata(providerHost: "example.com", model: "model", usage: nil), permit: AssistantSavePermit())
    }

    private func accept(_ e: EditorHarness, _ prepared: AssistantPreparedSave,
                        destination: AssistantSaveDestination = .newPrompt) throws -> AssistantAcceptanceOutcome {
        var outcome: AssistantAcceptanceOutcome?
        e.ui { e.h.editor.accept(prepared, source: e.model.assistantSnapshot, destination: destination) {
            XCTAssertTrue(e.h.marker.isUI)
            outcome = $0
        } }
        e.settle()
        return try XCTUnwrap(outcome)
    }

    func testCreateSavesExactBytesAndPreflightedIdentityWithRacedAlternateNames() throws {
        for queued in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: queued)
            let candidate = try prepared(e)
            try e.h.files.put("Occupied", at: "Candidate.md")
            e.h.files.onCreate = { path in
                if path == "Candidate 2.md" { try e.h.files.put("Racer", at: path) }
            }
            let result = try accept(e, candidate)
            let entry = try XCTUnwrap(result.committed?.entry)
            XCTAssertEqual(entry.relativePath, "Candidate 3.md")
            XCTAssertEqual(entry.document.frontMatter.id, id)
            XCTAssertEqual(try e.h.files.read(at: entry.relativePath), candidate.content.canonicalBytes)
            XCTAssertEqual(try e.h.files.text(at: "Candidate.md"), "Occupied")
            XCTAssertEqual(try e.h.files.text(at: "Candidate 2.md"), "Racer")
            XCTAssertEqual(e.h.index.browseContents().map { $0.entry.relativePath }, [entry.relativePath])
            XCTAssertEqual(try e.h.library.provenance(at: entry.relativePath)?.origin, .llm)
            XCTAssertTrue(try e.h.library.history(for: entry.identity).isEmpty)
        }
    }

    func testImproveSavesExactPreviewAndNormalHistoryWithRetainedOrFirstSaveIdentity() throws {
        for assigned in [false, true] {
            let e = EditorHarness(heldWork: true)
            let source = assigned ? "---\nid: \(id.rawValue)\n---\nOriginal" : "Original"
            try e.open(source)
            let candidate = try prepared(e, improve: true)
            let result = try accept(e, candidate, destination: .improve)
            let entry = try XCTUnwrap(result.committed?.entry)
            XCTAssertEqual(entry.identity, .assigned(id))
            XCTAssertEqual(try e.h.files.read(at: "a.md"), candidate.content.canonicalBytes)
            let revision = try XCTUnwrap(e.h.library.history(for: entry.identity).first)
            let snapshot = try e.h.library.historyForEditing(entry.identity, filename: "a.md").first
            XCTAssertEqual(snapshot?.source, source)
            XCTAssertNil(try e.h.library.provenance(for: revision))
        }
    }

    func testStaleOrDeletedSourceProducesConflictForEveryDestinationWithoutAppDataWrites() throws {
        for destination in [AssistantSaveDestination.newPrompt, .improve, .privateCopy] {
            for deleted in [false, true] {
                let e = EditorHarness(heldWork: true, queuedMain: true)
                try e.open("Original")
                let candidate = try prepared(e, improve: destination == .improve)
                var result: AssistantAcceptanceOutcome?
                e.ui { e.h.editor.accept(candidate, source: e.model.assistantSnapshot, destination: destination) { result = $0 } }
                if deleted { try e.h.files.delete(at: "a.md") }
                else { try e.h.files.put("Newer", at: "a.md") }
                e.settle()
                if deleted {
                    guard case .conflict(.deleted) = result else { return XCTFail("Expected deleted conflict.") }
                } else {
                    guard case .conflict(.modified(let stamp)) = result else { return XCTFail("Expected stale conflict.") }
                    XCTAssertEqual(stamp, try e.h.files.stamp(at: "a.md"))
                    XCTAssertEqual(try e.h.files.text(at: "a.md"), "Newer")
                }
                XCTAssertTrue(try e.h.data.listFiles().isEmpty)
                XCTAssertNil(try e.h.files.stamp(at: "Candidate.md"))
            }
        }
    }

    func testCreationKeepsSourceAndNewerDestinationPublicationsWithGlobalIndexVersion() throws {
        for destination in [AssistantSaveDestination.newPrompt, .privateCopy] {
            for replaceDestination in [false, true] {
                let e = EditorHarness(heldWork: true, queuedMain: true)
                try e.h.files.put("Other", at: "other.md")
                try e.open("Original", at: "folder/a.md")
                let source = try XCTUnwrap(e.model.assistantSnapshot)
                let candidate = try prepared(e)
                let path = destination == .privateCopy ? "Candidate.md" : "folder/Candidate.md"
                var published: LibraryEntry?
                e.h.data.onWrite = { record in
                    guard record.hasSuffix("/head.json") else { return }
                    e.h.data.onWrite = nil
                    let changedPath = replaceDestination ? path : "other.md"
                    do {
                        try e.h.files.put("Newer publication", at: changedPath)
                        let entry = LibraryEntry(path: changedPath,
                            document: PromptCodec.parse("Newer publication", filename: changedPath),
                            stamp: try XCTUnwrap(e.h.files.stamp(at: changedPath)))
                        let version = e.h.index.editingSnapshot(at: changedPath).version
                        e.h.index.acceptCommand(entry, at: changedPath, expectedVersion: version)
                        published = entry
                    } catch { XCTFail("Could not publish the test's newer index entry.") }
                }
                let outcome = try accept(e, candidate, destination: destination)
                let commit = try XCTUnwrap(outcome.committed?.entry)
                let newer = try XCTUnwrap(published)

                XCTAssertEqual(commit.relativePath, path)
                XCTAssertEqual(e.h.index.cachedEntry(at: path)?.stamp, replaceDestination ? newer.stamp : commit.stamp)
                XCTAssertEqual(e.h.index.cachedEntry(at: source.relativePath.string)?.stamp, source.stamp)
                XCTAssertEqual(try e.h.files.read(at: source.relativePath.string), source.sourceBytes)
                if replaceDestination {
                    XCTAssertNil(try e.h.library.provenance(at: path), "Replacement bytes cannot inherit the commit's origin.")
                } else {
                    XCTAssertEqual(try e.h.files.read(at: path), candidate.content.canonicalBytes)
                    XCTAssertEqual(e.h.index.cachedEntry(at: "other.md")?.stamp, newer.stamp)
                }
            }
        }
    }

    func testRetiringUnrelatedSessionDoesNotCancelSourcelessAcceptance() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        let session = e.h.editor.beginSession(at: "other.md")
        let candidate = try prepared(e)
        var replies: [AssistantAcceptanceOutcome] = []
        e.ui {
            e.h.editor.accept(candidate, source: nil, destination: .newPrompt) {
                XCTAssertTrue(e.h.marker.isUI)
                replies.append($0)
            }
            e.h.editor.retire(session)
        }
        e.settle()

        XCTAssertEqual(replies.count, 1)
        XCTAssertNotNil(replies.first?.committed)
        XCTAssertEqual(try e.h.files.read(at: "Candidate.md"), candidate.content.canonicalBytes)
    }

    func testCreationReconcilesDestinationDeletionPublishedBeforeCommit() throws {
        for hasSource in [false, true] {
            for queued in [false, true] {
                let e = EditorHarness(heldWork: true, queuedMain: queued)
                if hasSource { try e.open("Original", at: "folder/a.md") }
                let source = e.model.assistantSnapshot
                let candidate = try prepared(e)
                let path = hasSource ? "folder/Candidate.md" : "Candidate.md"
                e.h.files.onCreate = { destination in
                    guard destination == path else { return }
                    e.h.files.onCreate = nil
                    e.h.index.acceptCommand(nil, at: destination, expectedVersion: e.h.index.publicationVersion)
                }
                let outcome = try accept(e, candidate)
                let commit = try XCTUnwrap(outcome.committed?.entry)

                XCTAssertEqual(commit.relativePath, path)
                XCTAssertEqual(try e.h.files.read(at: path), candidate.content.canonicalBytes)
                XCTAssertEqual(e.h.index.cachedEntry(at: path)?.stamp, commit.stamp,
                    "A deletion published before creation cannot hide its committed destination.")
                if let source {
                    XCTAssertEqual(e.h.index.cachedEntry(at: source.relativePath.string)?.stamp, source.stamp)
                }
            }
        }
    }

    func testCreationDoesNotResurrectDestinationDeletedAfterCommit() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        let candidate = try prepared(e)
        e.h.data.onWrite = { record in
            guard record.hasSuffix("/head.json") else { return }
            e.h.data.onWrite = nil
            do { try e.h.files.delete(at: "Candidate.md") }
            catch { XCTFail("Could not delete the test's committed destination.") }
            e.h.index.acceptCommand(nil, at: "Candidate.md", expectedVersion: e.h.index.publicationVersion)
        }
        let outcome = try accept(e, candidate)

        XCTAssertNotNil(outcome.committed, "Acceptance must report the file that committed before deletion.")
        XCTAssertNil(try e.h.files.stamp(at: "Candidate.md"))
        XCTAssertNil(e.h.index.cachedEntry(at: "Candidate.md"))
    }

    func testCancelledQueuedSaveAndGraphRetirementCompleteOnceWithoutWrites() throws {
        for retired in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: true)
            let candidate = try prepared(e)
            var result: AssistantAcceptanceOutcome?
            var replies = 0
            e.ui { e.h.editor.accept(candidate, source: nil, destination: .newPrompt) {
                XCTAssertTrue(e.h.marker.isUI); result = $0; replies += 1
            } }
            if retired { e.ui { e.h.editor.deactivate() } }
            else { candidate.permit.invalidate(.failed(.cancelled)) }
            XCTAssertNil(result)
            e.settle()
            guard case .failed(let failure) = result else { return XCTFail("Expected refusal.") }
            XCTAssertEqual(failure, retired ? .inactive : .cancelled)
            XCTAssertEqual(replies, 1)
            XCTAssertTrue(try e.h.files.listFiles().isEmpty)
            XCTAssertTrue(try e.h.data.listFiles().isEmpty)
        }
    }

    func testFinalPublicationGuardRollsBackStagedHistory() throws {
        let e = EditorHarness()
        try e.open("Original")
        let candidate = try prepared(e, improve: true)
        e.h.data.onWrite = { path in
            if path.hasSuffix(".md") { candidate.permit.invalidate(.conflict(.changedBuffer)) }
        }
        guard case .conflict(.changedBuffer) = try accept(e, candidate, destination: .improve) else {
            return XCTFail("The last check must refuse a retired preview.")
        }
        XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original")
        XCTAssertTrue(try e.h.data.listFiles().isEmpty)
    }

    func testCreationRechecksSourceStampAfterNameProbe() throws {
        for destination in [AssistantSaveDestination.newPrompt, .privateCopy] {
            let e = EditorHarness()
            try e.open("Original")
            let candidate = try prepared(e)
            e.h.files.onStamp = { path, _ in
                guard path == "Candidate.md" else { return }
                e.h.files.onStamp = nil
                try e.h.files.put("Newer", at: "a.md")
            }
            guard case .conflict(.modified(let stamp)) = try accept(e, candidate, destination: destination) else {
                return XCTFail("Creation must recheck its source at publication.")
            }
            XCTAssertEqual(stamp, try e.h.files.stamp(at: "a.md"))
            XCTAssertEqual(try e.h.files.text(at: "a.md"), "Newer")
            XCTAssertNil(try e.h.files.stamp(at: "Candidate.md"))
            XCTAssertTrue(try e.h.data.listFiles().isEmpty)
        }
    }

    func testPreviewMismatchAndOccupiedIdentityFailWithoutPublication() throws {
        for occupied in [false, true] {
            let e = EditorHarness()
            let good = try prepared(e)
            let candidate: AssistantPreparedSave
            if occupied {
                try e.h.files.put("---\nid: \(id.rawValue)\n---\nExisting", at: "other.md")
                candidate = good
            } else {
                candidate = AssistantPreparedSave(content: ArtifactMergeCandidate(document: good.content.document,
                    canonicalBytes: good.content.canonicalBytes + Data("Different".utf8)), metadata: good.metadata, permit: good.permit)
            }
            guard case .failed(.editing(.library(let failure))) = try accept(e, candidate) else {
                return XCTFail("Expected identity/preview refusal.")
            }
            XCTAssertEqual(failure, occupied ? .identityMismatch : .previewMismatch)
            XCTAssertNil(try e.h.files.stamp(at: "Candidate.md"))
            XCTAssertTrue(try e.h.data.listFiles().isEmpty)
        }
    }
}
