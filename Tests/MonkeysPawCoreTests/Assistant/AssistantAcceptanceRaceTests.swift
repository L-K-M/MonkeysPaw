import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantAcceptanceRaceTests: XCTestCase {
    func testPreparationPrefersLoadedIdentityOnlyForInPlaceImprove() throws {
        let loadedID = try XCTUnwrap(ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PD"))
        let retainedID = try XCTUnwrap(ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PE"))
        let cases: [(AssistantCommand, AssistantAccessState, ULID)] = [
            (.improve(instruction: "", selectedFindings: []), .privatePrompt, loadedID),
            (.write(brief: "Brief"), .privatePrompt, retainedID),
            (.improve(instruction: "", selectedFindings: []), .group(.viewer), retainedID)
        ]
        for (command, access, expectedID) in cases {
            let h = try AssistantAcceptanceHarness(source: "---\nid: \(loadedID.rawValue)\n---\nOriginal")
            h.access = access
            h.e.ui { h.e.model.edit("Unsaved without front matter") }
            h.e.settle()
            let artifact = LlmArtifact(title: "Candidate", description: "", tags: [], fields: [], body: "Generated", notes: "")
            var result: Result<AssistantCandidate, AssistantFailure>?
            h.e.ui {
                h.service.prepare(artifact, for: command, context: h.context, retainingID: retainedID) { result = $0 }
            }
            h.e.settle()
            let candidate = try XCTUnwrap(result).get()
            XCTAssertEqual(candidate.content.document.frontMatter.id, expectedID)
        }
    }

    func testImproveAdoptsCommittedBytesAfterAnOlderIndexDeletion() async throws {
        for queued in [false, true] {
            let h = try AssistantAcceptanceHarness(source: "Original", queued: queued)
            try await h.ready(improve: true)
            let candidate = try XCTUnwrap(h.model.state.candidate)
            h.e.h.libraryFiles.beforeWrite = { path in
                guard path == "a.md" else { return }
                h.e.h.libraryFiles.beforeWrite = nil
                h.e.h.index.acceptCommand(nil, at: path, expectedVersion: h.e.h.index.publicationVersion)
            }
            let outcome = try h.accept()
            let entry = try XCTUnwrap(outcome.committed?.entry)

            XCTAssertEqual(h.e.h.index.cachedEntry(at: "a.md")?.stamp, entry.stamp)
            XCTAssertEqual(h.e.model.state.source.map { Data($0.utf8) }, candidate.content.canonicalBytes)
            XCTAssertEqual(h.e.model.state.stamp, entry.stamp)
            XCTAssertNil(h.e.model.state.conflict)
            XCTAssertEqual(h.model.state.phase, .saved)
            XCTAssertEqual(h.model.state.acceptanceOutcome?.committed?.entry.stamp, entry.stamp)
        }
    }

    func testBufferChangeDuringPublicationKeepsAuthoritativeCommitInBothModels() async throws {
        enum Mode: CaseIterable { case write, improve, privateCopy }
        for queued in [false, true] {
            for warning in [false, true] {
                for mode in Mode.allCases {
                    let h = try AssistantAcceptanceHarness(source: "Original", queued: queued)
                    if mode == .privateCopy { h.access = .group(.viewer); h.e.ui { h.model.contextChanged() } }
                    try await h.ready(improve: mode != .write)
                    let candidate = try XCTUnwrap(h.model.state.candidate)
                    let path = mode == .improve ? "a.md" : "Candidate.md"
                    if warning {
                        h.e.h.dataFiles.beforeWrite = { path in
                            if path.hasSuffix("/head.json") { throw FileStoreError.ioFailure }
                        }
                    }
                    h.e.h.files.onWrite = { written in
                        guard written == path else { return }
                        h.e.h.files.onWrite = nil
                        h.e.ui {
                            h.e.model.edit("Newer buffer")
                            h.model.contextChanged()
                            XCTAssertEqual(h.model.state.phase, .draft)
                            XCTAssertTrue(h.model.state.isStale)
                            XCTAssertTrue(h.model.state.isAccepting, "The worker still owes its actual result.")
                            XCTAssertNil(h.model.state.acceptanceOutcome, "A pending write cannot be reported as a conflict.")
                        }
                    }
                    var outcomes: [AssistantAcceptanceOutcome] = []
                    h.e.ui { h.model.accept(using: h.e.model) { outcomes.append($0); XCTAssertTrue(h.e.h.marker.isUI) } }
                    h.e.settle()

                    XCTAssertEqual(outcomes.count, 1)
                    let outcome = try XCTUnwrap(outcomes.first)
                    let entry = try XCTUnwrap(outcome.committed?.entry)
                    XCTAssertEqual(try h.e.h.files.read(at: path), candidate.content.canonicalBytes)
                    XCTAssertEqual(h.e.model.state.source, "Newer buffer")
                    XCTAssertTrue(h.e.model.state.isDirty)
                    XCTAssertNil(h.e.model.state.conflict)
                    XCTAssertEqual(h.e.model.state.provenanceMaintenanceFailed, warning)
                    XCTAssertEqual(h.model.state.phase, .saved)
                    XCTAssertFalse(h.model.state.isStale)
                    XCTAssertFalse(h.model.state.isAccepting)
                    XCTAssertEqual(h.model.state.acceptanceOutcome?.committed?.entry.stamp, entry.stamp)
                    switch h.model.state.acceptanceOutcome {
                    case .committedWithProvenanceWarning: XCTAssertTrue(warning)
                    case .saved: XCTAssertFalse(warning)
                    default: XCTFail("The committed outcome must replace the pending acceptance.")
                    }
                    h.e.ui { XCTAssertFalse(h.model.completeAcceptance(UUID(), outcome: outcome)) }
                    h.e.h.dataFiles.beforeWrite = nil
                    h.e.ui { h.model.showDiff() }
                    h.e.settle()
                    let nextID = try XCTUnwrap(h.model.state.candidate?.content.document.frontMatter.id)
                    if mode == .improve { XCTAssertEqual(nextID, entry.document.frontMatter.id) }
                    else { XCTAssertNotEqual(nextID, candidate.content.document.frontMatter.id) }
                }
            }
        }
    }

    func testImprovePreservesExternalChangesPublishedAfterItsOwnCommit() async throws {
        for queued in [false, true] {
            for deleted in [false, true] {
                let h = try AssistantAcceptanceHarness(source: "Original", queued: queued)
                try await h.ready(improve: true)
                let source = try XCTUnwrap(h.e.model.assistantSnapshot)
                var observer: UUID?
                observer = h.e.h.index.addObserver { change in
                    guard let stamp = change.stamps["a.md"], stamp != source.stamp else { return }
                    if let observer { h.e.h.index.removeObserver(observer) }
                    h.e.ui { h.e.model.edit("Newer buffer"); h.model.contextChanged() }
                    do {
                        if deleted {
                            try h.e.h.files.delete(at: "a.md")
                            try h.e.h.index.apply(LibraryChangeSet(deleted: ["a.md"]))
                        } else {
                            try h.e.h.files.put("Later external bytes", at: "a.md")
                            try h.e.h.index.apply(LibraryChangeSet(modified: ["a.md"]))
                        }
                    } catch { XCTFail("Could not publish the later external change.") }
                }
                defer { if let observer { h.e.h.index.removeObserver(observer) } }
                let outcome = try h.accept()
                let entry = try XCTUnwrap(outcome.committed?.entry)

                XCTAssertEqual(h.model.state.acceptanceOutcome?.committed?.entry.stamp, entry.stamp)
                XCTAssertEqual(h.e.model.state.source, "Newer buffer")
                XCTAssertTrue(h.e.model.state.isDirty)
                XCTAssertEqual(h.e.model.state.conflict?.kind, deleted ? .deleted : .modified)
                if deleted {
                    XCTAssertNil(try h.e.h.files.stamp(at: "a.md"))
                    XCTAssertNil(h.e.h.index.cachedEntry(at: "a.md"))
                } else {
                    XCTAssertEqual(h.e.model.state.conflict?.theirsSource, "Later external bytes")
                    XCTAssertEqual(h.e.h.index.cachedEntry(at: "a.md")?.stamp, try h.e.h.files.stamp(at: "a.md"))
                }
            }
        }
    }

    func testCommittedCompletionRejectsDuplicateAndUnissuedTokens() async throws {
        let h = try AssistantAcceptanceHarness()
        try await h.ready()
        var issued: AssistantAcceptance?
        h.e.ui { issued = h.model.accept() }
        let acceptance = try XCTUnwrap(issued)
        let entry = try h.e.h.library.save(acceptance.candidate.content.document, at: "Candidate.md")
        let outcome = AssistantAcceptanceOutcome.saved(AssistantCommittedPrompt(entry: entry, historyMaintenanceFailed: false))
        h.e.ui {
            XCTAssertTrue(h.model.completeAcceptance(acceptance.id, outcome: outcome))
            XCTAssertFalse(h.model.completeAcceptance(acceptance.id, outcome: outcome))
            XCTAssertFalse(h.model.completeAcceptance(UUID(), outcome: outcome))
        }
        h.e.settle()
        XCTAssertEqual(h.model.state.phase, .saved)
        XCTAssertEqual(h.model.state.acceptanceOutcome?.committed?.entry.stamp, entry.stamp)
    }

    func testBufferChangeAfterCommitBeforeQueuedReplyAdoptsSavedOutcome() async throws {
        let h = try AssistantAcceptanceHarness(source: "Original")
        try await h.ready(improve: true)
        let bytes = try XCTUnwrap(h.model.state.candidate).content.canonicalBytes
        var outcomes: [AssistantAcceptanceOutcome] = []
        h.e.ui { h.model.accept(using: h.e.model) { outcomes.append($0) } }
        h.e.h.main.releaseAll()
        h.e.h.held.releaseNext()
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(try h.e.h.files.read(at: "a.md"), bytes)
        h.e.ui { h.e.model.edit("Newer buffer"); h.model.contextChanged() }
        h.e.settle()

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNotNil(outcomes.first?.committed)
        XCTAssertEqual(h.model.state.phase, .saved)
        XCTAssertEqual(h.model.state.acceptanceOutcome?.committed?.entry.stamp, outcomes.first?.committed?.entry.stamp)
        XCTAssertEqual(h.e.model.state.source, "Newer buffer")
        XCTAssertTrue(h.e.model.state.isDirty)
        XCTAssertNil(h.e.model.state.conflict)
    }

    func testBufferChangeBeforePublicationCompletesWithConsistentConflictState() async throws {
        let h = try AssistantAcceptanceHarness(source: "Original")
        try await h.ready(improve: true)
        var outcomes: [AssistantAcceptanceOutcome] = []
        h.e.ui { h.model.accept(using: h.e.model) { outcomes.append($0) } }
        h.e.h.main.releaseAll()
        h.e.ui { h.e.model.edit("Newer buffer"); h.model.contextChanged() }
        XCTAssertEqual(h.model.state.phase, .draft)
        XCTAssertTrue(h.model.state.isStale)
        h.e.settle()

        XCTAssertEqual(outcomes.count, 1)
        guard case .conflict(.changedBuffer) = outcomes.first else {
            return XCTFail("A changed buffer must refuse publication.")
        }
        guard case .conflict(.changedBuffer) = h.model.state.acceptanceOutcome else {
            return XCTFail("The model must adopt the actual conflict.")
        }
        XCTAssertEqual(h.model.state.phase, .draft)
        XCTAssertTrue(h.model.state.isStale)
        XCTAssertFalse(h.model.state.isAccepting)
        XCTAssertEqual(try h.e.h.files.text(at: "a.md"), "Original")
        XCTAssertTrue(try h.e.h.data.listFiles().isEmpty)
    }
}
