import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptEditingServiceTests: XCTestCase {
    func testCreateLoadEditSavePreservesUnknownMetadataBodyIdentityAndHistory() throws {
        let h = PromptEditingHarness()
        let session = h.marker.ui { h.editor.beginSession(at: "nested/New.md") }
        let body = "  Text 👋 e\u{301}\r\n\r\n"
        let source = "---\nextra: {nested: [a, b]}\ntitle: New\nmodel: custom\n---\n" + body
        let created = try saved(h.copy(source, near: "nested/New.md", session: session))
        XCTAssertNotNil(created.document.frontMatter.id)
        XCTAssertEqual(created.relativePath, "nested/New.md")
        XCTAssertEqual(Data(created.document.body.utf8), Data(body.utf8))
        XCTAssertTrue(try h.library.history(for: created.identity).isEmpty)

        let loaded = try load(h, session)
        XCTAssertEqual(loaded.sourceBytes, try h.files.read(at: created.relativePath))
        XCTAssertEqual(loaded.source, created.document.source)
        XCTAssertEqual(loaded.stamp, created.stamp)
        XCTAssertNil(loaded.readOnlyReason)
        let changed = loaded.source!.replacingOccurrences(of: "title: New", with: "title: Edited")
            .replacingOccurrences(of: body, with: body + "End\r\n")
        let savedEntry = try saved(h.save(changed, session: session, stamp: loaded.stamp))
        XCTAssertEqual(savedEntry.identity, created.identity)
        XCTAssertEqual(savedEntry.document.frontMatter.title, "Edited")
        XCTAssertEqual(Data(savedEntry.document.body.utf8), Data((body + "End\r\n").utf8))
        XCTAssertNotEqual(savedEntry.stamp, loaded.stamp)
        XCTAssertTrue(savedEntry.document.source.hasPrefix("---\nid: "))
        let written = try h.files.text(at: created.relativePath)
        XCTAssertEqual(written, try PromptCodec.write(savedEntry.document))
        XCTAssertEqual(written, try PromptCodec.write(PromptCodec.parse(changed, filename: "New.md")))
        XCTAssertTrue(written.contains("extra:"))
        XCTAssertTrue(written.contains("model: custom\n"))
        let revision = try XCTUnwrap(h.library.history(for: created.identity).first)
        XCTAssertEqual(try h.data.read(at: historyPath(revision)), loaded.sourceBytes)
        XCTAssertEqual(h.entropy.requests, [Limits.ulidEntropyBytes])
    }

    func testFirstSaveAssignsIdentityAndMigratesKeyedStateAndHistory() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open("---\nunknown: retained\n---\nBody\r\n")
        h.keyed.values[loaded.entry.identity] = "state"
        _ = try HistoryStore(files: h.data).snapshot(Data("Older".utf8), for: loaded.entry.identity, at: h.clock.date)

        let entry = try saved(h.save(loaded.source! + "Edited\r\n", session: session, stamp: loaded.stamp))

        XCTAssertNotEqual(entry.identity, loaded.entry.identity)
        XCTAssertNotNil(entry.document.frontMatter.id)
        XCTAssertEqual(h.keyed.values[entry.identity], "state")
        XCTAssertNil(h.keyed.values[loaded.entry.identity])
        XCTAssertTrue(try h.library.history(for: loaded.entry.identity).isEmpty)
        let history = try h.library.history(for: entry.identity)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(try h.data.read(at: historyPath(history[0])), loaded.sourceBytes)
        XCTAssertTrue(entry.document.source.contains("unknown: retained\n"))
    }

    func testCopyRemovesAssignedIDWithoutChangingOriginalStateOrHistory() throws {
        let h = PromptEditingHarness()
        let id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let (session, loaded) = try h.open("---\nid: \(id)\nmodel: {name: custom}\n---\nBody\r\n", at: "folder/Name.md")
        h.keyed.values[loaded.entry.identity] = "original state"
        _ = try HistoryStore(files: h.data).snapshot(Data("Revision".utf8), for: loaded.entry.identity, at: h.clock.date)
        let previousHistory = try h.library.history(for: loaded.entry.identity)

        let copy = try saved(h.copy(loaded.source!, near: loaded.entry.relativePath, session: session))

        XCTAssertEqual(copy.relativePath, "folder/Name 2.md")
        XCTAssertNotEqual(copy.identity, loaded.entry.identity)
        XCTAssertEqual(Data(copy.document.body.utf8), Data(loaded.document.body.utf8))
        XCTAssertTrue(copy.document.source.contains("model:"))
        XCTAssertEqual(try h.files.read(at: loaded.entry.relativePath), loaded.sourceBytes)
        XCTAssertEqual(h.keyed.values, [loaded.entry.identity: "original state"])
        XCTAssertEqual(try h.library.history(for: loaded.entry.identity), previousHistory)
        XCTAssertTrue(try h.library.history(for: copy.identity).isEmpty)
    }

    func testStaleStampReportsCurrentStampAndNeverWrites() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open()
        try h.files.put("External", at: "a.md")
        let current = try XCTUnwrap(h.files.stamp(at: "a.md"))
        let historyAccesses = h.data.accessCount

        guard case .conflict(let stamp) = try h.save("Mine", session: session, stamp: loaded.stamp) else {
            return XCTFail("Expected a stamped conflict.")
        }
        XCTAssertEqual(stamp, current)
        XCTAssertEqual(try h.files.text(at: "a.md"), "External")
        XCTAssertEqual(h.data.accessCount, historyAccesses)
        XCTAssertTrue(h.entropy.requests.isEmpty)
    }

    func testDeletionAndRecreationAreDistinctStampedSaveOutcomes() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open()
        try h.files.delete(at: "a.md")
        guard case .deleted = try h.save("Mine", session: session, stamp: loaded.stamp) else {
            return XCTFail("Expected deletion, without recreation.")
        }
        XCTAssertNil(try h.files.stamp(at: "a.md"))
        try h.files.put("Original", at: "a.md")
        guard case .conflict(let stamp) = try h.save("Mine", session: session, stamp: loaded.stamp) else {
            return XCTFail("A new incarnation must conflict even with identical bytes.")
        }
        XCTAssertEqual(stamp, try h.files.stamp(at: "a.md"))
        XCTAssertNotEqual(stamp, loaded.stamp)
    }

    func testNilStampExplicitlyOverwritesOrRecreates() throws {
        let h = PromptEditingHarness()
        let (session, _) = try h.open()
        try h.files.put("External", at: "a.md")
        let overwritten = try saved(h.save("Mine", session: session, stamp: nil))
        let revision = try XCTUnwrap(h.library.history(for: overwritten.identity).first)
        XCTAssertEqual(try h.data.text(at: historyPath(revision)), "External")
        try h.files.delete(at: "a.md")
        let recreated = try saved(h.save(overwritten.document.source, session: session, stamp: nil))
        XCTAssertEqual(recreated.identity, overwritten.identity)
        XCTAssertEqual(recreated.document.body, "Mine")
    }

    func testDeletionDuringStagingReportsDeletedAndRollsBack() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open()
        h.data.onWrite = { [files = h.files] _ in try? files.delete(at: "a.md") }
        defer { h.data.onWrite = nil }

        guard case .deleted = try h.save("Mine", session: session, stamp: loaded.stamp) else {
            return XCTFail("Expected deletion after the second stamp check.")
        }
        XCTAssertNil(try h.files.stamp(at: "a.md"))
        XCTAssertTrue(try h.data.listFiles().isEmpty)
    }

    func testHeldWorkerAndQueuedMainDeliverOnlyAfterBothAreReleased() throws {
        let h = PromptEditingHarness(heldWork: true)
        let (session, loaded) = try h.open()
        h.main.isHeld = true
        let accesses = h.files.accessCount + h.data.accessCount
        var result: PromptSaveOutcome?
        h.marker.ui { h.editor.save("Mine", session: session, expectedStamp: loaded.stamp) {
            XCTAssertTrue(h.marker.isUI)
            result = $0
        } }
        XCTAssertEqual(h.files.accessCount + h.data.accessCount, accesses)
        XCTAssertNil(result)
        XCTAssertEqual(h.held.pending.count, 1)

        h.held.releaseNext()
        XCTAssertNil(result)
        XCTAssertEqual(try h.files.text(at: "a.md"), try h.library.load(at: "a.md").document.source)
        h.main.releaseAll()
        XCTAssertEqual(try saved(XCTUnwrap(result)).document.body, "Mine")
    }

    func testSessionRegistrationDoesNotWaitForAnIndexFileRead() throws {
        let h = PromptEditingHarness(heldWork: true)
        _ = try h.open()
        let reading = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let refreshed = expectation(description: "Index refresh finished")
        let registered = expectation(description: "UI session registered while index reads")
        h.files.onRead = { _ in
            reading.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        defer { h.files.onRead = nil }
        DispatchQueue.global().async {
            do { try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")])) }
            catch { XCTFail("Index refresh failed.") }
            refreshed.fulfill()
        }
        XCTAssertEqual(reading.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            _ = h.editor.beginSession(at: "a.md")
            registered.fulfill()
        }
        wait(for: [registered], timeout: 1)
        release.signal()
        wait(for: [refreshed], timeout: 5)
    }

    func testRetiredQueuedSessionDoesNoIOWhileLiveSessionStillSaves() throws {
        let h = PromptEditingHarness(heldWork: true)
        let (retired, loaded) = try h.open()
        let live = h.marker.ui { h.editor.beginSession(at: "a.md") }
        var result: PromptSaveOutcome?
        h.marker.ui {
            h.editor.save("Retired", session: retired, expectedStamp: loaded.stamp) { _ in XCTFail("Retired reply.") }
            h.editor.save("Live", session: live, expectedStamp: loaded.stamp) { result = $0 }
            h.editor.retire(retired)
        }
        let accesses = h.files.accessCount + h.data.accessCount
        h.held.releaseNext()
        XCTAssertEqual(h.files.accessCount + h.data.accessCount, accesses)
        h.held.releaseNext()
        XCTAssertEqual(try saved(XCTUnwrap(result)).document.body, "Live")
    }

    func testRetirementDropsRepliesAlreadyQueuedOnMain() throws {
        let h = PromptEditingHarness(heldWork: true)
        let (session, loaded) = try h.open()
        h.main.isHeld = true
        h.marker.ui { h.editor.save("Committed", session: session, expectedStamp: loaded.stamp) { _ in XCTFail("Retired reply.") } }
        h.held.releaseAll()
        h.marker.ui { h.editor.retire(session) }
        h.main.releaseAll()
        XCTAssertEqual(try h.library.load(at: "a.md").document.body, "Committed")
    }

    func testRetirementDropsLoadAndCopyRequestsAndTheirLateReplies() throws {
        for releaseWorker in [false, true] {
            let h = PromptEditingHarness(heldWork: true)
            let (session, _) = try h.open()
            h.main.isHeld = true
            h.marker.ui {
                h.editor.load(session: session) { _ in XCTFail("Retired load reply.") }
                h.editor.createCopy("Copy", near: "copy.md", session: session) { _ in XCTFail("Retired copy reply.") }
            }
            if releaseWorker { h.held.releaseAll() }
            let accesses = h.files.accessCount + h.data.accessCount
            h.marker.ui { h.editor.retire(session) }
            h.held.releaseAll()
            h.main.releaseAll()
            XCTAssertEqual(h.files.accessCount + h.data.accessCount, accesses)
            XCTAssertEqual(try h.files.stamp(at: "copy.md") != nil, releaseWorker)
        }
    }

    func testGraphDeactivationDropsWorkRepliesChangesAndNewIntents() throws {
        let h = PromptEditingHarness(heldWork: true)
        let (session, loaded) = try h.open(changes: { _ in XCTFail("Retired graph event.") })
        h.main.isHeld = true
        try h.files.put("External", at: "a.md")
        try h.index.apply(LibraryChangeSet(modified: [RelativePath("a.md")]))
        h.marker.ui {
            h.editor.save("Mine", session: session, expectedStamp: loaded.stamp) { _ in XCTFail("Retired graph reply.") }
            h.editor.deactivate()
            h.editor.load(session: session) { _ in XCTFail("Inactive load.") }
            let inactive = h.editor.beginSession(at: "a.md")
            h.editor.createCopy("Copy", near: "copy.md", session: inactive) { _ in XCTFail("Inactive copy.") }
        }
        let accesses = h.files.accessCount + h.data.accessCount
        h.held.releaseAll()
        h.main.releaseAll()
        XCTAssertEqual(h.files.accessCount + h.data.accessCount, accesses)
        XCTAssertEqual(try h.files.text(at: "a.md"), "External")
    }

    func testInvalidSourceReturnsIssuesWithoutAnyFileAccessOrWrites() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open()
        let accesses = h.files.accessCount + h.data.accessCount
        for source in ["---\ntitle: [broken\n---\nBody", "{{broken", "---\nid: invalid\n---\nBody"] {
            guard case .invalid(let issues) = try h.save(source, session: session, stamp: loaded.stamp) else {
                return XCTFail("Expected validation issues.")
            }
            XCTAssertTrue(issues.contains { $0.severity == .error })
            XCTAssertEqual(h.files.accessCount + h.data.accessCount, accesses)
            guard case .invalid = try h.copy(source, near: "copy.md", session: session) else {
                return XCTFail("Invalid copy must fail before creating anything.")
            }
        }
        XCTAssertEqual(try h.files.read(at: "a.md"), loaded.sourceBytes)
        XCTAssertNil(try h.files.stamp(at: "copy.md"))
    }

    func testInvalidYAMLLoadsAsEditableOriginalSourceAndCanBeCorrected() throws {
        let h = PromptEditingHarness()
        let original = "---\ntitle: [broken\n---\nBody\r\n"
        let (session, loaded) = try h.open(original)
        XCTAssertEqual(loaded.source, original)
        XCTAssertEqual(loaded.document.issues.map(\.code), [.invalidYAML])
        XCTAssertNil(loaded.readOnlyReason)
        let corrected = try saved(h.save("Corrected\r\n", session: session, stamp: loaded.stamp))
        let revision = try XCTUnwrap(h.library.history(for: corrected.identity).first)
        XCTAssertEqual(try h.data.text(at: historyPath(revision)), original)
    }

    func testReadOnlyFilesRetainOriginalBytesAndRefuseSaves() throws {
        let cases: [(Data, PromptReadOnlyReason)] = [
            (Data("---\nformat: 2\n---\nFuture\r\n".utf8), .unsupportedFormat(PromptFormatVersion(2)!)),
            (Data([0xff, 0xfe]), .invalidUTF8),
            (Data(repeating: 0x78, count: Limits.maxPromptBytes + 1), .sourceTooLarge),
        ]
        for (bytes, reason) in cases {
            let h = PromptEditingHarness()
            try h.files.write(bytes, at: "a.md")
            try h.index.rebuild()
            let session = h.marker.ui { h.editor.beginSession(at: "a.md") }
            let loaded = try load(h, session)
            XCTAssertEqual(loaded.sourceBytes, bytes)
            XCTAssertEqual(loaded.readOnlyReason, reason)
            if reason != cases[0].1 { XCTAssertNil(loaded.source) }
            guard case .readOnly(let returned) = try h.save("Replacement", session: session, stamp: loaded.stamp) else {
                return XCTFail("Existing read-only sources must refuse rewriting.")
            }
            XCTAssertEqual(returned, reason)
            XCTAssertEqual(try h.files.read(at: "a.md"), bytes)
            XCTAssertTrue(try h.data.listFiles().isEmpty)
        }
    }

    func testFutureDraftAndCanonicalSizeOverflowRefuseWriting() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open()
        guard case .readOnly = try h.save("---\nformat: 999\n---\nFuture", session: session, stamp: loaded.stamp) else {
            return XCTFail("Future draft must be read-only.")
        }
        guard case .invalid(let issues) = try h.save(String(repeating: "x", count: Limits.maxPromptBytes),
                                                  session: session, stamp: loaded.stamp) else {
            return XCTFail("Adding canonical identity metadata must obey the cap.")
        }
        XCTAssertEqual(issues.map(\.code), [.sourceTooLarge])
        XCTAssertEqual(try h.files.read(at: "a.md"), loaded.sourceBytes)
        XCTAssertTrue(try h.data.listFiles().isEmpty)
    }

    func testTypedWriteAndLoadFailuresPreserveDraftAndDisk() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open()
        h.files.failNextWrite = true
        guard case .failed(.fileStore(.ioFailure)) = try h.save("Mine", session: session, stamp: loaded.stamp) else {
            return XCTFail("Expected typed I/O failure.")
        }
        XCTAssertEqual(try h.files.read(at: "a.md"), loaded.sourceBytes)
        XCTAssertTrue(try h.data.listFiles().isEmpty)
        h.files.onRead = { _ in throw EditingTestError.privateDetails }
        defer { h.files.onRead = nil }
        var result: PromptLoadOutcome?
        h.marker.ui { h.editor.load(session: session) { result = $0 } }
        guard case .failed(.library(.operationFailed)) = result else { return XCTFail("Unsanitized load failure.") }
    }

    func testLoadMissingAndRacingFilesReturnTypedOutcomes() throws {
        let h = PromptEditingHarness()
        let session = h.marker.ui { h.editor.beginSession(at: "a.md") }
        var result: PromptLoadOutcome?
        h.marker.ui { h.editor.load(session: session) { result = $0 } }
        guard case .deleted = result else { return XCTFail("Expected a missing load.") }
        try h.files.put("Before", at: "a.md")
        h.files.onRead = { [files = h.files] path in
            files.onRead = nil
            try files.put("After", at: path)
        }
        h.marker.ui { h.editor.load(session: session) { result = $0 } }
        guard case .failed(.library(.conflict)) = result else { return XCTFail("Racing load must refuse mismatched bytes/stamp.") }
    }

    func testHistoryMaintenanceFailureCarriesCommittedEntryAndStamp() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open()
        var entry = try saved(h.save("0", session: session, stamp: loaded.stamp))
        for index in 1..<Limits.historyCapPerPrompt {
            entry = try saved(h.save("\(index)", session: session, stamp: entry.stamp))
        }
        h.data.failNextDelete = true

        guard case .savedButHistoryMaintenanceFailed(let committed) = try h.save("Committed", session: session, stamp: entry.stamp) else {
            return XCTFail("A committed save must not look like a failed write.")
        }
        XCTAssertEqual(committed.document.body, "Committed")
        XCTAssertEqual(committed.stamp, try h.files.stamp(at: "a.md"))
        XCTAssertEqual(committed.identity, entry.identity)
        XCTAssertEqual(try h.library.history(for: entry.identity).count, Limits.historyCapPerPrompt + 1)
        let next = try saved(h.save("Next", session: session, stamp: committed.stamp))
        XCTAssertEqual(next.document.body, "Next")
        XCTAssertEqual(try h.library.history(for: entry.identity).count, Limits.historyCapPerPrompt)
    }

    func testCommittedHistoryFailureKeepsOwnVersionIfExternalWriterChangesDuringPrune() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open()
        let entry = try saved(h.save("Before", session: session, stamp: loaded.stamp))
        var ownStamp: FileStamp?
        h.dataFiles.onList = {
            guard try h.files.text(at: "a.md").hasSuffix("Committed") else { return }
            h.dataFiles.onList = nil
            ownStamp = try h.files.stamp(at: "a.md")
            try h.files.put("External", at: "a.md")
            throw FileStoreError.ioFailure
        }
        defer { h.dataFiles.onList = nil }
        guard case .savedButHistoryMaintenanceFailed(let committed) = try h.save("Committed", session: session, stamp: entry.stamp) else {
            return XCTFail("Expected the captured committed version.")
        }
        XCTAssertEqual(committed.document.body, "Committed")
        XCTAssertEqual(committed.stamp, ownStamp)
        XCTAssertNotEqual(committed.stamp, try h.files.stamp(at: "a.md"))
        XCTAssertEqual(try h.files.text(at: "a.md"), "External")
    }

    func testCopyHistoryMaintenanceFailureAlsoCarriesCommittedOutcome() throws {
        let h = PromptEditingHarness()
        let (session, _) = try h.open()
        h.dataFiles.onList = {
            if try h.files.stamp(at: "copy.md") != nil { throw FileStoreError.ioFailure }
        }
        defer { h.dataFiles.onList = nil }
        guard case .savedButHistoryMaintenanceFailed(let copy) = try h.copy("Copy", near: "copy.md", session: session) else {
            return XCTFail("Exclusive creation also commits before pruning.")
        }
        XCTAssertEqual(copy.relativePath, "copy.md")
        XCTAssertEqual(copy.stamp, try h.files.stamp(at: "copy.md"))
    }

    func testCopyPreservesDestinationThatArrivesAfterProbeAndRetriesExclusively() throws {
        let h = PromptEditingHarness()
        let (session, loaded) = try h.open(at: "Name.md")
        let external = Data([0xff, 0xfe, 0x0a])
        var attempts: [String] = []
        h.files.onCreate = { [files = h.files] path in
            attempts.append(path)
            if path == "Name 2.md" { try files.write(external, at: path) }
        }
        defer { h.files.onCreate = nil }
        let copy = try saved(h.copy(loaded.source!, near: "Name.md", session: session))
        XCTAssertEqual(attempts, ["Name 2.md", "Name 3.md"])
        XCTAssertEqual(copy.relativePath, "Name 3.md")
        XCTAssertEqual(try h.files.read(at: "Name 2.md"), external)
        XCTAssertEqual(try h.files.read(at: "Name.md"), loaded.sourceBytes)
    }

    func testCopyRetriesAreBoundedAndIOFailuresAreNotRetried() throws {
        let h = PromptEditingHarness()
        let (session, _) = try h.open()
        var attempts = 0
        h.files.onCreate = { [files = h.files] path in
            attempts += 1
            try files.put("External", at: path)
        }
        guard case .failed(.library(.copyLimitReached)) = try h.copy("Copy", near: "copy.md", session: session) else {
            return XCTFail("Expected bounded copy exhaustion.")
        }
        XCTAssertEqual(attempts, Limits.libraryCreateAttemptCap)
        attempts = 0
        h.files.onCreate = { _ in attempts += 1; throw FileStoreError.ioFailure }
        defer { h.files.onCreate = nil }
        guard case .failed(.fileStore(.ioFailure)) = try h.copy("Copy", near: "other.md", session: session) else {
            return XCTFail("Expected typed copy failure.")
        }
        XCTAssertEqual(attempts, 1)
    }

    private func saved(_ outcome: PromptSaveOutcome) throws -> LibraryEntry {
        guard case .saved(let entry) = outcome else {
            XCTFail("Expected a successful save.")
            throw EditingTestError.unexpectedOutcome
        }
        return entry
    }

    private func load(_ h: PromptEditingHarness, _ session: PromptEditingSession) throws -> LoadedPrompt {
        var result: PromptLoadOutcome?
        h.marker.ui { h.editor.load(session: session) { result = $0; XCTAssertTrue(h.marker.isUI) } }
        h.held.releaseAll()
        h.main.releaseAll()
        guard case .loaded(let loaded) = try XCTUnwrap(result) else { throw EditingTestError.unexpectedOutcome }
        return loaded
    }

    private func historyPath(_ revision: HistoryRevision) throws -> String {
        "history/" + (try revision.identity.storageKey) + "/" + revision.filename
    }
}
