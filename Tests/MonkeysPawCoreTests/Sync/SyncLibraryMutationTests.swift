import XCTest
@testable import MonkeysPawCore

final class SyncLibraryMutationTests: XCTestCase {
    func testServerBytesRemainExactAndDisplacedBytesStayPrivate() throws {
        let rig = try SyncApplyTestRig()
        let original = SyncApplyTestRig.bytes("Local\n")
        let document = PromptCodec.parseFile(original, filename: "a.md")
        XCTAssertTrue(document.issues.filter { $0.severity == .error }.isEmpty, "\(document.issues.map(\.code))")
        try rig.files.write(original, at: "a.md")
        let edit = try rig.replacement()
        XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .committed)
        XCTAssertEqual(try rig.files.read(at: "a.md"), edit.bytes)
        let retained = "sync/retained/" + edit.id.uuidString.lowercased() + ".bin"
        XCTAssertEqual(try rig.data.read(at: retained), original)
        XCTAssertTrue(rig.data.isPrivate(at: retained))
        XCTAssertNil(try rig.data.stamp(at: "sync/apply.json"))
    }

    func testOrdinaryEditorStillRejectsAssignedIdentityChange() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.write(SyncApplyTestRig.bytes("Local"), at: "a.md")
        let different = PromptCodec.parseFile(SyncApplyTestRig.bytes("Other", id: SyncTestValues.groupPrompt), filename: "a.md")
        XCTAssertThrowsError(try rig.library.save(different, at: "a.md")) {
            XCTAssertEqual($0 as? LibraryError, .identityMismatch)
        }
    }

    func testEditBetweenPlanningAndApplyReplansWithoutOverwrite() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.write(SyncApplyTestRig.bytes("Old"), at: "a.md")
        let edit = try rig.replacement()
        let changed = SyncApplyTestRig.bytes("New local edit")
        try rig.files.write(changed, at: "a.md")
        XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .replanAsConflict(operationID: edit.id))
        XCTAssertEqual(try rig.files.read(at: "a.md"), changed)
        XCTAssertNil(rig.states.snapshot.value?.cursors[.user(SyncTestValues.user)])
    }

    func testSameBytesReplacementIsAChangedIncarnation() throws {
        let rig = try SyncApplyTestRig()
        let original = SyncApplyTestRig.bytes("Old")
        try rig.files.write(original, at: "a.md")
        let edit = try rig.replacement()
        try rig.files.delete(at: "a.md")
        try rig.files.write(original, at: "a.md")
        XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .replanAsConflict(operationID: edit.id))
        XCTAssertEqual(try rig.files.read(at: "a.md"), original)
    }

    func testEditAtDriverPublicationRacePointIsPreserved() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.write(SyncApplyTestRig.bytes("Old"), at: "a.md")
        let edit = try rig.replacement()
        let changed = SyncApplyTestRig.bytes("Raced")
        rig.libraryOperations.beforePublish = { _ in try rig.files.write(changed, at: "a.md") }
        XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .replanAsConflict(operationID: edit.id))
        XCTAssertEqual(try rig.files.read(at: "a.md"), changed)
    }

    func testReadRaceAndPostPublicationReplacementReplan() throws {
        for afterPublication in [false, true] {
            let rig = try SyncApplyTestRig()
            try rig.files.write(SyncApplyTestRig.bytes("Old"), at: "a.md")
            let edit = try rig.replacement()
            let changed = SyncApplyTestRig.bytes("Replacement", id: SyncTestValues.groupPrompt)
            if afterPublication {
                rig.files.onWrite = { path in
                    guard path == "a.md" else { return }
                    rig.files.onWrite = nil
                    try! rig.files.write(changed, at: path)
                }
            } else {
                rig.files.onRead = { path in
                    guard path == "a.md" else { return }
                    rig.files.onRead = nil
                    try rig.files.write(changed, at: path)
                }
            }
            XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .replanAsConflict(operationID: edit.id))
            XCTAssertEqual(try rig.files.read(at: "a.md"), changed)
        }
    }

    func testMismatchedIdentityIsNeverTrashedIncludingOnReplay() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.write(SyncApplyTestRig.bytes("Old"), at: "a.md")
        let edit = try rig.mutations.trash(XCTUnwrap(rig.mutations.read(at: "a.md")))
        let other = SyncApplyTestRig.bytes("Unrelated", id: SyncTestValues.groupPrompt)
        try rig.files.write(other, at: "a.md")
        XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .replanAsConflict(operationID: edit.id))
        XCTAssertEqual(try rig.journal.replay(), .replanAsConflict(operationID: edit.id))
        XCTAssertEqual(try rig.files.read(at: "a.md"), other)
        XCTAssertTrue(rig.libraryOperations.trashed.isEmpty)
    }

    func testFreshRescueKeepsRawSourceAndStableIDAcrossReplay() throws {
        let rig = try SyncApplyTestRig()
        let original = SyncApplyTestRig.bytes("Losing bytes\r\n")
        try rig.files.write(original, at: "a.md")
        let file = try XCTUnwrap(rig.mutations.read(at: "a.md"))
        let rescue = try rig.mutations.rescue(file, at: "Conflicts/Copy.md", freshID: SyncTestValues.groupPrompt)
        let replace = try rig.replacement()
        rig.libraryOperations.failFlushNumber = 1
        XCTAssertThrowsError(try rig.journal.apply(rig.plan([rescue, replace])))
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.journal.replay(), .committed)
        XCTAssertEqual(try restarted.files.read(at: "Conflicts/Copy.md"), rescue.bytes)
        XCTAssertEqual(try restarted.library.load(at: "Conflicts/Copy.md").document.frontMatter.id, SyncTestValues.groupPrompt)
        let retained = "sync/retained/" + rescue.id.uuidString.lowercased() + ".bin"
        XCTAssertEqual(try restarted.data.read(at: retained), original)
        XCTAssertEqual(try restarted.files.listFiles().count, 2)
    }

    func testForensicAndFutureRescuesAreHeldAndNeverAltered() throws {
        for bytes in [Data([0xff, 0xfe]), Data("---\ntitle: [broken\n---\nBody".utf8),
                      Data("---\nformat: 999\n---\nFuture".utf8)] {
            let rig = try SyncApplyTestRig()
            try rig.files.write(bytes, at: "unknown.md")
            let file = try XCTUnwrap(rig.mutations.read(at: "unknown.md"))
            let edit = try rig.mutations.rescue(file, at: "Conflicts/unknown.md", freshID: SyncTestValues.groupPrompt)
            XCTAssertNotNil(edit.heldIssue)
            XCTAssertNil(edit.copyID)
            XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .committed)
            XCTAssertEqual(try rig.files.read(at: "Conflicts/unknown.md"), bytes)
            XCTAssertEqual(try rig.files.read(at: "unknown.md"), bytes)
        }
    }

    func testNonPromptTextRescueRemainsRawAndHeld() throws {
        let rig = try SyncApplyTestRig()
        let raw = Data("Unmanaged documentation\r\n".utf8)
        try rig.files.write(raw, at: "notes.txt")
        let file = try XCTUnwrap(rig.mutations.read(at: "notes.txt"))
        let edit = try rig.mutations.rescue(file, at: "Conflicts/notes.md", freshID: SyncTestValues.groupPrompt)
        XCTAssertEqual(edit.heldIssue, .localVisibility)
        XCTAssertNil(edit.copyID)
        XCTAssertEqual(edit.bytes, raw)
        XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .committed)
        XCTAssertEqual(try rig.files.read(at: "Conflicts/notes.md"), raw)
    }

    func testInvalidServerBytesAndWrongTransitionFailBeforePublication() throws {
        let rig = try SyncApplyTestRig()
        let transition = try SyncIdentityTransition(from: nil, to: .assigned(SyncTestValues.personalPrompt))
        for bytes in [Data([0xff]), SyncApplyTestRig.bytes("Wrong", id: SyncTestValues.groupPrompt),
                      Data("---\nformat: 99\n---\nFuture".utf8)] {
            XCTAssertThrowsError(try rig.mutations.publication(bytes, at: "a.md", expecting: nil, transition: transition))
        }
        XCTAssertTrue(try rig.files.listFiles().isEmpty)
    }

    func testModeAndDiskFullFailuresDoNotAcknowledgeAndReplayRecovers() throws {
        for modeFailure in [false, true] {
            let rig = try SyncApplyTestRig()
            let original = SyncApplyTestRig.bytes("Old")
            try rig.files.write(original, at: "a.md")
            let edit = try rig.replacement()
            if modeFailure { rig.libraryOperations.failMode = true }
            else { rig.files.failNextWrite = true }
            XCTAssertThrowsError(try rig.journal.apply(rig.plan([edit])))
            XCTAssertEqual(try rig.files.read(at: "a.md"), original)
            XCTAssertNil(rig.states.snapshot.value)
            let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
            XCTAssertEqual(try restarted.journal.replay(), .committed)
            XCTAssertEqual(try restarted.journal.replay(), .committed)
        }
    }

    func testIdentityAdoptionMigratesAllKeyedStateAndProvenance() throws {
        let rig = try SyncApplyTestRig()
        let old = SyncTestValues.personalPrompt
        let new = SyncTestValues.groupPrompt
        let original = SyncApplyTestRig.bytes("Same body\r\n", id: old)
        try rig.files.write(original, at: "a.md")
        let history = HistoryStore(files: rig.data)
        let identity = PromptIdentity.assigned(old)
        let provenance = PromptProvenance(timestamp: Date(timeIntervalSince1970: 1), providerHost: "example.test", model: "test", usage: nil)
        let revision = try history.snapshot(original, for: identity, at: Date(timeIntervalSince1970: 1))
        try history.archiveProvenance(provenance, for: revision, bytes: original)
        try history.setHeadProvenance(provenance, for: identity, bytes: original)
        try rig.usage.recordUse(identity: identity, at: Date(timeIntervalSince1970: 12))
        try rig.values.record(identity: identity, values: ["field": "remembered"])
        let current = try XCTUnwrap(rig.mutations.read(at: "a.md"))
        let edit = try rig.mutations.publication(SyncApplyTestRig.bytes("Same body\r\n", id: new), at: "a.md", expecting: current,
            transition: SyncIdentityTransition(from: identity, to: .assigned(new)), kind: .adopt)
        XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .committed)
        XCTAssertEqual(try rig.values.rememberedValues(for: .assigned(new)), ["field": "remembered"])
        XCTAssertEqual(try rig.values.rememberedValues(for: identity), [:])
        XCTAssertEqual(try rig.usage.useEvents(for: .assigned(new)), [Date(timeIntervalSince1970: 12)])
        XCTAssertEqual(try rig.library.history(for: .assigned(new)).count, 1)
        XCTAssertEqual(try rig.library.provenance(at: "a.md"), provenance)
        let migratedRevision = try XCTUnwrap(rig.library.history(for: .assigned(new)).first)
        XCTAssertEqual(try rig.library.provenance(for: migratedRevision), provenance)
        XCTAssertFalse(try rig.data.listFiles().contains { $0.relativePath.contains(old.rawValue) })
    }

    func testIdlessAdoptionMigratesPathKeyAndPreservesOtherValues() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.put("Body\r\n", at: "a.md")
        let local = PromptIdentity(path: "a.md", id: nil)
        try rig.values.record(identity: local, values: ["field": "old"])
        try rig.values.record(identity: .assigned(SyncTestValues.device), values: ["other": "keep"])
        try rig.usage.recordUse(identity: local)
        let edit = try rig.replacement(body: "Body\r\n")
        XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .committed)
        XCTAssertEqual(try rig.values.rememberedValues(for: .assigned(SyncTestValues.personalPrompt)), ["field": "old"])
        XCTAssertEqual(try rig.values.rememberedValues(for: .assigned(SyncTestValues.device)), ["other": "keep"])
        XCTAssertEqual(try rig.usage.useEvents(for: .assigned(SyncTestValues.personalPrompt)).count, 1)
    }

    func testOccupiedIdentityStateIsNeverReplaced() throws {
        let rig = try SyncApplyTestRig()
        try rig.files.put("Local", at: "a.md")
        try rig.values.record(identity: PromptIdentity(path: "a.md", id: nil), values: ["old": "source"])
        try rig.values.record(identity: .assigned(SyncTestValues.personalPrompt), values: ["new": "destination"])
        let edit = try rig.replacement()
        XCTAssertThrowsError(try rig.journal.apply(rig.plan([edit])))
        XCTAssertEqual(try rig.files.text(at: "a.md"), "Local")
        XCTAssertEqual(try rig.values.rememberedValues(for: .assigned(SyncTestValues.personalPrompt)), ["new": "destination"])
        XCTAssertNoThrow(try rig.library.load(at: "a.md"))
    }

    func testAdoptionDoesNotRebindStaleProvenanceToChangedContent() throws {
        let rig = try SyncApplyTestRig()
        let old = PromptIdentity.assigned(SyncTestValues.personalPrompt)
        let provenance = PromptProvenance(timestamp: Date(timeIntervalSince1970: 1),
            providerHost: "example.test", model: "test", usage: nil)
        try HistoryStore(files: rig.data).setHeadProvenance(provenance, for: old,
            bytes: SyncApplyTestRig.bytes("Previous LLM output"))
        try rig.files.write(SyncApplyTestRig.bytes("Externally edited"), at: "a.md")
        let current = try XCTUnwrap(rig.mutations.read(at: "a.md"))
        let edit = try rig.mutations.publication(SyncApplyTestRig.bytes("Externally edited", id: SyncTestValues.groupPrompt),
            at: "a.md", expecting: current,
            transition: SyncIdentityTransition(from: old, to: .assigned(SyncTestValues.groupPrompt)), kind: .adopt)
        XCTAssertEqual(try rig.journal.apply(rig.plan([edit])), .committed)
        XCTAssertNil(try rig.library.provenance(at: "a.md"))
    }
}
