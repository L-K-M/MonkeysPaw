import Foundation
import XCTest
@testable import MonkeysPawCore

final class LibraryServiceTests: XCTestCase {
    private var library: MemoryFileStore!
    private var data: MemoryFileStore!
    private var clock: LibraryClock!
    private var entropy: LibraryEntropy!
    private var keyed: MemoryKeyedStore!
    private var service: LibraryService!

    override func setUp() {
        library = MemoryFileStore()
        data = MemoryFileStore()
        clock = LibraryClock()
        entropy = LibraryEntropy()
        keyed = MemoryKeyedStore()
        service = LibraryService(library: library, data: data, clock: clock, entropy: entropy, keyedStores: [keyed])
    }

    func testEnumerationIgnoresOnlySpecifiedPathsAndSorts() throws {
        let included = ["a.md", "z.md", ".visible.md", "readme.md", "notes/README.md",
                        "nested/folder/a.md", "Groups/team/a.md", "Conflicts/a.md"]
        let ignored = ["README.md", ".git/a.md", "folder/.hidden/a.md", "_drafts/a.md",
                       "folder/_private/a.md", "_file.md", "nested/_file.md", "a.MD", "a.txt"]
        for path in included + ignored { try library.put("Body", at: path) }
        let entries = try service.entries()
        XCTAssertEqual(entries.map(\.relativePath), included.sorted())
        XCTAssertEqual(entries.first(where: { $0.relativePath == "nested/folder/a.md" })?.folder, "nested/folder")
        XCTAssertEqual(entries.first(where: { $0.relativePath == "a.md" })?.folder, "")
        XCTAssertEqual(entries.first(where: { $0.relativePath == "a.md" })?.document.frontMatter.title, "a")
        XCTAssertTrue(entries.allSatisfy { $0.issues.isEmpty })
        XCTAssertTrue(entropy.requests.isEmpty, "Listing must never assign identity.")
    }

    func testBadYAMLNonUTF8AndOversizeRemainListed() throws {
        try library.put("---\ntitle: [broken\n---\nBody", at: "bad.md")
        try library.write(Data([0xff, 0xfe]), at: "bytes.md")
        try library.write(Data(repeating: 0x78, count: Limits.maxPromptBytes + 1), at: "large.md")
        let entries = try service.entries()
        XCTAssertEqual(entries.map(\.relativePath), ["bad.md", "bytes.md", "large.md"])
        XCTAssertEqual(entries.map { $0.issues.map(\.code) }, [[.invalidYAML], [.invalidUTF8], [.sourceTooLarge]])
        XCTAssertTrue(entries.allSatisfy { !$0.document.canRender && $0.issues.allSatisfy { $0.severity == .error } })
        for entry in entries {
            XCTAssertThrowsError(try service.save(entry.document, at: entry.relativePath)) {
                XCTAssertEqual($0 as? PromptWriteError, .invalidPrompt)
            }
        }
        XCTAssertTrue(try data.listFiles().isEmpty)
    }

    func testCanonicalSavePreservesUnknownKeysAndExactBodyBytes() throws {
        let body = "  👋 {{x}}\r\n\r\nlast line\r\n\r\n"
        let source = "---\nextra_z: {second: 2, first: 1}\nfavorite: true\nextra_a: value\ntitle: Saved\ntags: [code]\n---\n" + body
        let document = PromptCodec.parse(source, filename: "Old.md")
        let saved = try service.save(document, at: "nested/New.md")
        let written = try library.text(at: "nested/New.md")
        XCTAssertTrue(written.hasPrefix("---\nid: "))
        let keys = ["id:", "title:", "tags:", "favorite:", "extra_z:", "extra_a:"]
        let positions = try keys.map { try XCTUnwrap(written.range(of: $0)).lowerBound }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(Array(saved.document.body.utf8), Array(body.utf8))
        XCTAssertEqual(saved.document.frontMatter.title, "Saved")
        XCTAssertTrue(written.contains("extra_z:\n  second: 2\n  first: 1\n"))
        XCTAssertEqual(try PromptCodec.write(saved.document), written)
        XCTAssertTrue(try service.history(for: saved.identity).isEmpty, "New files have no overwritten bytes.")
    }

    func testPlainFileGetsDeterministicIDAndOnlyIDHeader() throws {
        let body = "  plain body\r\n\n"
        try library.put(body, at: "Plain.md")
        let old = try service.load(at: "Plain.md")
        let saved = try service.save(old.document, at: "Plain.md", expectedStamp: old.stamp)
        let expected = try ULID.generate(at: clock.date, entropy: Array(0...9))
        XCTAssertEqual(saved.identity, .assigned(expected))
        XCTAssertEqual(entropy.requests, [10])
        XCTAssertEqual(try library.text(at: "Plain.md"), "---\nid: \(expected.rawValue)\n---\n" + body)
        let revisions = try service.history(for: saved.identity)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(try data.text(at: historyPath(revisions[0])), body)
        XCTAssertTrue(try service.history(for: old.identity).isEmpty)
    }

    func testResaveAndExplicitAssignNeverRewriteID() throws {
        let assigned = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        try library.put("---\nid: \(assigned.lowercased())\n---\nBody", at: "a.md")
        let entry = try service.load(at: "a.md")
        let assignedEntry = try service.assignIdentity(to: "a.md")
        XCTAssertEqual(entry.stamp, assignedEntry.stamp)
        let saved = try service.save(entry.document, at: "a.md")
        XCTAssertEqual(saved.document.frontMatter.id?.rawValue, assigned)
        XCTAssertTrue(entropy.requests.isEmpty)
        XCTAssertTrue(try library.text(at: "a.md").contains("id: \(assigned)\n"))
        let withoutID = PromptCodec.parse("Edited", filename: "a.md")
        let edited = try service.save(withoutID, at: "a.md")
        XCTAssertEqual(edited.identity, entry.identity, "Removing id from a draft does not change an assigned file.")
    }

    func testAssignMigratesAllRegisteredStateAndExistingLocalHistory() throws {
        try library.put("Body", at: "a.md")
        let local = try service.load(at: "a.md").identity
        keyed.values[local] = "remembered"
        _ = try HistoryStore(files: data).snapshot(Data("Old".utf8), for: local, at: Date(timeIntervalSince1970: 0))
        let assigned = try service.assignIdentity(to: "a.md")
        XCTAssertEqual(keyed.values[assigned.identity], "remembered")
        XCTAssertNil(keyed.values[local])
        XCTAssertEqual(keyed.migrations.count, 1)
        XCTAssertEqual(keyed.migrations[0].0, local)
        XCTAssertEqual(keyed.migrations[0].1, assigned.identity)
        XCTAssertTrue(try service.history(for: local).isEmpty)
        XCTAssertEqual(try service.history(for: assigned.identity).count, 2)
        let prefix = "history/" + (try assigned.identity.storageKey)
        XCTAssertEqual(try data.listFiles().filter { $0.relativePath.hasPrefix(prefix) }.count, 2)
    }

    func testMoveMigratesUnassignedKeysAndKeepsAssignedKeys() throws {
        try library.put("Plain", at: "old.md")
        let original = try service.load(at: "old.md")
        keyed.values[original.identity] = "usage"
        _ = try HistoryStore(files: data).snapshot(Data("Revision".utf8), for: original.identity, at: clock.date)
        let moved = try service.move(from: "old.md", to: "folder/new.md")
        XCTAssertEqual(moved.identity, PromptIdentity(path: "folder/new.md", id: nil))
        XCTAssertNotEqual(moved.identity, original.identity)
        XCTAssertEqual(moved.document.frontMatter.title, "new")
        XCTAssertEqual(keyed.values[moved.identity], "usage")
        XCTAssertTrue(try service.history(for: original.identity).isEmpty)
        XCTAssertEqual(try service.history(for: moved.identity).count, 1)
        XCTAssertNil(try library.stamp(at: "old.md"))
        let assigned = try service.assignIdentity(to: "folder/new.md")
        let migrations = keyed.migrations.count
        let movedAgain = try service.move(from: "folder/new.md", to: "assigned.md")
        XCTAssertEqual(movedAgain.identity, assigned.identity)
        XCTAssertEqual(keyed.migrations.count, migrations)
        XCTAssertEqual(try library.text(at: "assigned.md"), try PromptCodec.write(assigned.document))
    }

    func testExpectedStampConflictRetryAndDeduplicatedCopy() throws {
        try library.put("Original", at: "Name.md")
        let opened = try service.load(at: "Name.md")
        try library.put("External", at: "Name.md")
        let mine = PromptCodec.parse("Mine", filename: "Name.md")
        XCTAssertThrowsError(try service.save(mine, at: "Name.md", expectedStamp: opened.stamp)) {
            XCTAssertEqual($0 as? LibraryError, .conflict)
        }
        XCTAssertEqual(try library.text(at: "Name.md"), "External")
        XCTAssertTrue(entropy.requests.isEmpty)
        try library.put("Taken", at: "Name 2.md")
        XCTAssertEqual(try service.availablePath(for: "Name.md"), "Name 3.md")
        XCTAssertEqual(try service.availablePath(for: "folder/Name.md"), "folder/Name.md")
        let copy = try service.save(mine, at: service.availablePath(for: "Name.md"))
        XCTAssertEqual(copy.relativePath, "Name 3.md")
        XCTAssertEqual(try library.text(at: "Name.md"), "External")
        entropy.value[0] = 1
        let reread = try service.load(at: "Name.md")
        let retried = try service.save(mine, at: "Name.md", expectedStamp: reread.stamp)
        XCTAssertEqual(retried.document.body, "Mine")
        XCTAssertNotEqual(retried.identity, copy.identity)
        let revision = try XCTUnwrap(service.history(for: retried.identity).first)
        XCTAssertEqual(try data.text(at: historyPath(revision)), "External")
    }

    func testDeletionAndRecreationConflictEvenWithSameBytes() throws {
        try library.put("Same", at: "a.md")
        let opened = try service.load(at: "a.md")
        try library.delete(at: "a.md")
        XCTAssertThrowsError(try service.save(opened.document, at: "a.md", expectedStamp: opened.stamp)) {
            XCTAssertEqual($0 as? LibraryError, .conflict)
        }
        try library.put("Same", at: "a.md")
        XCTAssertThrowsError(try service.save(opened.document, at: "a.md", expectedStamp: opened.stamp)) {
            XCTAssertEqual($0 as? LibraryError, .conflict)
        }
        XCTAssertTrue(try data.listFiles().isEmpty)
    }

    func testHistorySnapshotsExactPreviousBytesAndRestoreGrowsHistory() throws {
        let original = "---\ntitle: Original # comment\nunknown: value\n---\n old\r\n\r\n"
        try library.put(original, at: "a.md")
        let first = try service.assignIdentity(to: "a.md")
        clock.date = Date(timeIntervalSince1970: 2)
        let edited = try service.save(PromptCodec.parse("Changed", filename: "a.md"), at: "a.md")
        let revisions = try service.history(for: first.identity)
        XCTAssertEqual(revisions.count, 2)
        XCTAssertEqual(revisions.map(\.timestamp), [Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 1.234)])
        XCTAssertEqual(try data.text(at: historyPath(revisions[1])), original)
        XCTAssertEqual(revisions[1].filename, "19700101T000001.234Z-000000.md")
        clock.date = Date(timeIntervalSince1970: 3)
        let restored = try service.restore(revisions[1], at: "a.md", expectedStamp: edited.stamp)
        XCTAssertEqual(restored.document.body, " old\r\n\r\n")
        XCTAssertEqual(restored.identity, first.identity, "A pre-assignment revision keeps the assigned key.")
        let after = try service.history(for: first.identity)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(try data.read(at: historyPath(after[0])), Data(try PromptCodec.write(edited.document).utf8))
    }

    func testCapFiftyAndSameMillisecondOrdering() throws {
        let first = try service.save(PromptCodec.parse("0", filename: "a.md"), at: "a.md")
        for index in 1...55 {
            try service.save(PromptCodec.parse("\(index)", filename: "a.md"), at: "a.md")
        }
        let revisions = try service.history(for: first.identity)
        XCTAssertEqual(revisions.count, 50)
        XCTAssertEqual(revisions.first?.filename, "19700101T000001.234Z-000054.md")
        XCTAssertEqual(revisions.last?.filename, "19700101T000001.234Z-000005.md")
        XCTAssertEqual(PromptCodec.parse(try data.read(at: historyPath(revisions[0])), filename: "a.md").body, "54")
        XCTAssertEqual(PromptCodec.parse(try data.read(at: historyPath(revisions[49])), filename: "a.md").body, "5")
        XCTAssertEqual(try data.listFiles().count, 50)
        try service.restore(revisions[49], at: "a.md")
        let after = try service.history(for: first.identity)
        XCTAssertEqual(after.count, 50)
        XCTAssertEqual(after.first?.filename, "19700101T000001.234Z-000055.md")
    }

    func testDeleteRetainsHistoryAndRestoreResurrectsIdentity() throws {
        try library.put("Original", at: "a.md")
        let entry = try service.assignIdentity(to: "a.md")
        let revisions = try service.history(for: entry.identity)
        try service.delete(at: "a.md")
        XCTAssertTrue(try service.entries().isEmpty)
        XCTAssertEqual(try service.history(for: entry.identity), revisions)
        let restored = try service.restore(revisions[0], at: "a.md")
        XCTAssertEqual(restored.identity, entry.identity)
        XCTAssertEqual(restored.document.body, "Original")
        XCTAssertEqual(try service.history(for: entry.identity), revisions, "No current file was overwritten.")
    }

    func testRefusesFutureFormatsAndIdentityReplacement() throws {
        let future = PromptCodec.parse("---\nformat: 2\n---\nFuture", filename: "a.md")
        XCTAssertThrowsError(try service.save(future, at: "a.md")) {
            XCTAssertEqual($0 as? PromptWriteError, .unsupportedFormat(PromptFormatVersion(2)!))
        }
        try library.put(future.source, at: "a.md")
        XCTAssertThrowsError(try service.save(PromptCodec.parse("Old format", filename: "a.md"), at: "a.md")) {
            XCTAssertEqual($0 as? PromptWriteError, .unsupportedFormat(PromptFormatVersion(2)!))
        }
        try library.delete(at: "a.md")
        let entry = try service.save(PromptCodec.parse("Body", filename: "a.md"), at: "a.md")
        let replacement = PromptCodec.parse("---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\nOther", filename: "a.md")
        XCTAssertThrowsError(try service.save(replacement, at: "a.md")) {
            XCTAssertEqual($0 as? LibraryError, .identityMismatch)
        }
        XCTAssertEqual(try service.load(at: "a.md").stamp, entry.stamp)
    }

    func testCorrectedDraftCanReplaceInvalidFileAndSnapshotOriginalBytes() throws {
        let invalid = Data([0xff, 0xfe])
        try library.write(invalid, at: "a.md")
        let entry = try service.save(PromptCodec.parse("Corrected", filename: "a.md"), at: "a.md")
        let revision = try XCTUnwrap(service.history(for: entry.identity).first)
        XCTAssertEqual(try data.read(at: historyPath(revision)), invalid)
        XCTAssertThrowsError(try service.restore(revision, at: "a.md")) {
            XCTAssertEqual($0 as? PromptWriteError, .invalidPrompt)
        }
        XCTAssertEqual(try service.load(at: "a.md").stamp, entry.stamp)
    }

    func testIgnoredAndUnsafePathsCannotBeMutationTargets() throws {
        let paths = ["", "/a.md", "../a.md", "./a.md", "a//b.md", "a/../b.md", "a/./b.md",
                     "a\\b.md", "a\0.md", "a\n.md", "README.md", "_a.md", "_dir/a.md",
                     ".git/a.md", "a.MD", "a.txt", String(repeating: "é", count: 511) + ".md"]
        for path in paths {
            XCTAssertThrowsError(try service.save(PromptCodec.parse("Body", filename: "a.md"), at: path))
            XCTAssertThrowsError(try service.availablePath(for: path))
            XCTAssertThrowsError(try service.delete(at: path))
            XCTAssertThrowsError(try service.move(from: "a.md", to: path))
        }
        XCTAssertTrue(try library.listFiles().isEmpty)
        XCTAssertTrue(entropy.requests.isEmpty)
    }

    func testFailedAtomicWriteRollsBackSnapshotAndKeyMigrations() throws {
        try library.put("Original", at: "a.md")
        let local = try service.load(at: "a.md")
        keyed.values[local.identity] = "state"
        _ = try HistoryStore(files: data).snapshot(Data("Older".utf8), for: local.identity, at: Date(timeIntervalSince1970: 0))
        let before = try data.listFiles().map(\.relativePath)
        library.failNextWrite = true
        XCTAssertThrowsError(try service.assignIdentity(to: "a.md")) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
        XCTAssertEqual(try library.text(at: "a.md"), "Original")
        XCTAssertEqual(try service.load(at: "a.md").identity, local.identity)
        XCTAssertEqual(try data.listFiles().map(\.relativePath), before)
        XCTAssertEqual(keyed.values, [local.identity: "state"])
        XCTAssertEqual(keyed.migrations.count, 2)
        XCTAssertEqual(keyed.migrations[1].1, local.identity)
    }

    func testSnapshotFailureAndLaterKeyStoreFailurePreventSave() throws {
        try library.put("Original", at: "a.md")
        let local = try service.load(at: "a.md")
        keyed.values[local.identity] = "state"
        data.failNextWrite = true
        XCTAssertThrowsError(try service.assignIdentity(to: "a.md"))
        XCTAssertEqual(try library.text(at: "a.md"), "Original")
        XCTAssertEqual(keyed.values, [local.identity: "state"])
        XCTAssertTrue(try data.listFiles().isEmpty)

        _ = try HistoryStore(files: data).snapshot(Data("Older".utf8), for: local.identity, at: clock.date)
        let before = try data.listFiles().map(\.relativePath)
        keyed.failNextMigration = true
        XCTAssertThrowsError(try service.assignIdentity(to: "a.md"))
        XCTAssertEqual(try data.listFiles().map(\.relativePath), before, "History migration is reversed if a later store fails.")
        XCTAssertEqual(try library.text(at: "a.md"), "Original")
    }

    func testExternalEditWhileStagingHistoryIsDetectedAndRolledBack() throws {
        try library.put("Original", at: "a.md")
        let loaded = try service.load(at: "a.md")
        keyed.values[loaded.identity] = "state"
        data.onWrite = { [library] _ in try! library!.put("External", at: "a.md") }
        XCTAssertThrowsError(try service.save(loaded.document, at: "a.md", expectedStamp: loaded.stamp)) {
            XCTAssertEqual($0 as? LibraryError, .conflict)
        }
        XCTAssertEqual(try library.text(at: "a.md"), "External")
        XCTAssertTrue(try data.listFiles().isEmpty)
        XCTAssertEqual(keyed.values, [loaded.identity: "state"])
    }

    func testMoveFailurePreservesFileAndStateAndNeverOverwritesDestination() throws {
        try library.put("Original", at: "a.md")
        let local = try service.load(at: "a.md").identity
        keyed.values[local] = "state"
        _ = try HistoryStore(files: data).snapshot(Data("Older".utf8), for: local, at: clock.date)
        library.failMoveNumber = 1
        XCTAssertThrowsError(try service.move(from: "a.md", to: "b.md"))
        XCTAssertEqual(try library.text(at: "a.md"), "Original")
        XCTAssertNil(try library.stamp(at: "b.md"))
        XCTAssertEqual(keyed.values, [local: "state"])
        XCTAssertEqual(try service.history(for: local).count, 1)
        try library.put("Destination", at: "b.md")
        XCTAssertThrowsError(try service.move(from: "a.md", to: "b.md")) {
            XCTAssertEqual($0 as? FileStoreError, .alreadyExists)
        }
        XCTAssertEqual(try library.text(at: "b.md"), "Destination")
    }

    func testHistoryMigrationCollisionAndPartialMoveFailurePreserveAllBytes() throws {
        let store = HistoryStore(files: data)
        let source = PromptIdentity(path: "a.md", id: nil)
        let target = PromptIdentity(path: "b.md", id: nil)
        _ = try store.snapshot(Data("Source".utf8), for: source, at: clock.date)
        _ = try store.snapshot(Data("Target".utf8), for: target, at: clock.date)
        let before = try data.listFiles()
        XCTAssertThrowsError(try store.migrateKey(from: source, to: target)) {
            XCTAssertEqual($0 as? LibraryError, .keyedStateConflict)
        }
        XCTAssertEqual(try data.listFiles(), before)
        for revision in try store.revisions(for: target) { try store.remove(revision) }
        _ = try store.snapshot(Data("Source 2".utf8), for: source, at: clock.date)
        let sourcePaths = try data.listFiles().map(\.relativePath)
        data.failMoveNumber = 2
        XCTAssertThrowsError(try store.migrateKey(from: source, to: target))
        XCTAssertEqual(try data.listFiles().map(\.relativePath), sourcePaths)
        XCTAssertEqual(try store.revisions(for: source).count, 2)
        XCTAssertTrue(try store.revisions(for: target).isEmpty)
    }

    func testFailedSnapshotCleanupAndFailedPruningAreExplicit() throws {
        try library.put("Original", at: "a.md")
        library.failNextWrite = true
        data.failNextDelete = true
        XCTAssertThrowsError(try service.assignIdentity(to: "a.md")) {
            XCTAssertEqual($0 as? LibraryError, .recoveryRequired)
        }
        XCTAssertEqual(try library.text(at: "a.md"), "Original")
        // Use fresh roots for the post-commit maintenance failure scenario.
        setUp()
        let entry = try service.save(PromptCodec.parse("0", filename: "a.md"), at: "a.md")
        for index in 1...50 { try service.save(PromptCodec.parse("\(index)", filename: "a.md"), at: "a.md") }
        data.failNextDelete = true
        XCTAssertThrowsError(try service.save(PromptCodec.parse("Saved", filename: "a.md"), at: "a.md")) {
            XCTAssertEqual($0 as? LibraryError, .historyMaintenanceFailed)
        }
        XCTAssertEqual(try service.load(at: "a.md").document.body, "Saved")
        XCTAssertEqual(try service.history(for: entry.identity).count, 51)
    }

    func testBoundedHistoryNamesAndUntrustedIdentity() throws {
        let store = HistoryStore(files: data)
        let identity = PromptIdentity(path: "a.md", id: nil)
        let directory = "history/" + (try identity.storageKey)
        try data.put("Last", at: directory + "/19700101T000001.234Z-999999.md")
        XCTAssertThrowsError(try store.snapshot(Data(), for: identity, at: clock.date)) {
            XCTAssertEqual($0 as? LibraryError, .historyCollisionLimitReached)
        }
        for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: -1),
                     Date(timeIntervalSince1970: Limits.historyMaxUnixSeconds)] {
            XCTAssertThrowsError(try store.snapshot(Data(), for: identity, at: date)) {
                XCTAssertEqual($0 as? LibraryError, .invalidTimestamp)
            }
        }
        XCTAssertThrowsError(try service.history(for: .local("../outside"))) {
            XCTAssertEqual($0 as? LibraryError, .invalidIdentity)
        }
    }

    func testNonRevisionAppDataIsPreservedAndRestoreToOtherIdentityIsRefused() throws {
        try data.put("Settings", at: "settings.json")
        let entry = try service.save(PromptCodec.parse("0", filename: "a.md"), at: "a.md")
        try service.save(PromptCodec.parse("1", filename: "a.md"), at: "a.md")
        let revision = try XCTUnwrap(service.history(for: entry.identity).first)
        try data.put("Other", at: "history/" + (try entry.identity.storageKey) + "/not-a-revision.md")
        XCTAssertEqual(try service.history(for: entry.identity).count, 1)
        try library.put("Unrelated", at: "b.md")
        XCTAssertThrowsError(try service.restore(revision, at: "b.md")) {
            XCTAssertEqual($0 as? LibraryError, .identityMismatch)
        }
        XCTAssertEqual(try data.text(at: "settings.json"), "Settings")
        XCTAssertEqual(try library.text(at: "b.md"), "Unrelated")
    }

    func testIdentityHeaderSizeAndGeneratorFailuresLeaveNoFileOrState() throws {
        let boundary = PromptCodec.parse(String(repeating: "x", count: Limits.maxPromptBytes), filename: "a.md")
        XCTAssertTrue(boundary.issues.isEmpty)
        XCTAssertThrowsError(try service.save(boundary, at: "a.md")) {
            XCTAssertEqual($0 as? PromptWriteError, .sourceTooLarge)
        }
        clock.date = Date(timeIntervalSince1970: -1)
        let draft = PromptCodec.parse("Body", filename: "a.md")
        XCTAssertThrowsError(try service.save(draft, at: "a.md")) {
            XCTAssertEqual($0 as? ULIDGenerationError, .invalidTimestamp)
        }
        clock.date = Date(timeIntervalSince1970: 1)
        entropy.value = [1]
        XCTAssertThrowsError(try service.save(draft, at: "a.md")) {
            XCTAssertEqual($0 as? ULIDGenerationError, .invalidEntropyLength)
        }
        XCTAssertTrue(try library.listFiles().isEmpty)
        XCTAssertTrue(try data.listFiles().isEmpty)
        XCTAssertTrue(keyed.migrations.isEmpty)
    }

    func testFailedResurrectionPreservesExistingAssignedHistory() throws {
        try library.put("Original", at: "a.md")
        let entry = try service.assignIdentity(to: "a.md")
        let revisions = try service.history(for: entry.identity)
        try service.delete(at: "a.md")
        library.failNextWrite = true
        XCTAssertThrowsError(try service.restore(revisions[0], at: "a.md")) {
            XCTAssertEqual($0 as? FileStoreError, .ioFailure)
        }
        XCTAssertNil(try library.stamp(at: "a.md"))
        XCTAssertEqual(try service.history(for: entry.identity), revisions)
    }

    private func historyPath(_ revision: HistoryRevision) throws -> String {
        "history/" + (try revision.identity.storageKey) + "/" + revision.filename
    }
}
