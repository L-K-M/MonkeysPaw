import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncStateStoreTests: XCTestCase {
    private let path = "sync/state.json"

    func testRootProofRequiresTheRecordedLexicalRootAndFailsClosedForUnreadableState() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let store = SyncStateStore(files: files, operations: operations)
        let state = try SyncTestValues.state()
        XCTAssertFalse(store.requiresRootProof(for: state.binding.root.path))
        try store.update(for: state.binding) { $0 = state }
        XCTAssertTrue(store.requiresRootProof(for: state.binding.root.path))
        XCTAssertFalse(store.requiresRootProof(for: "/different-library"))
        XCTAssertTrue(store.requiresRootProof(for: "/library/../escape"))
        XCTAssertTrue(SyncStateStore(files: files, operations: operations).requiresRootProof(for: state.binding.root.path))
        try files.put("broken", at: path)
        let corrupt = SyncStateStore(files: files, operations: operations)
        XCTAssertTrue(corrupt.requiresRootProof(for: "/different-library"))
        XCTAssertEqual(try files.text(at: path), "broken")
    }

    func testRoundTripUsesPrivateWriteAndCheckedFlushes() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let store = SyncStateStore(files: files, operations: operations)
        let state = try SyncTestValues.state()
        XCTAssertNil(try store.load(for: state.binding))
        XCTAssertEqual(operations.flushCount, 0)
        try store.update(for: state.binding) { $0 = state }
        XCTAssertEqual(store.snapshot.value, state)
        XCTAssertEqual(try SyncStateStore(files: files, operations: operations).load(for: state.binding), state)
        XCTAssertTrue(files.isPrivate(at: path))
        XCTAssertEqual(operations.flushedFiles, [RelativePath(path)])
        XCTAssertEqual(operations.flushedDirectories, [RelativePath("sync"), nil])
        XCTAssertEqual(state.prompts[.assigned(SyncTestValues.groupPrompt)]?.rev, .max)
        XCTAssertEqual(try files.listFiles().map(\.relativePath), [path])
    }

    func testCursorsAreOpaqueAndPreserveExactStringBytes() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let store = SyncStateStore(files: files, operations: operations)
        let binding = try SyncTestValues.binding()
        let cursor = "future:%not-a-sequence / \u{0} e\u{301} :☃\r\n"
        try store.update(for: binding) { $0.cursors[.user(SyncTestValues.user)] = cursor }
        let decoded = try XCTUnwrap(SyncStateStore(files: files, operations: operations).load(for: binding))
        XCTAssertTrue(try XCTUnwrap(decoded.cursors[.user(SyncTestValues.user)]).utf8.elementsEqual(cursor.utf8))
    }

    func testInvalidIDsScopesPathsRevisionsHashesOriginsAndIssuesFailClosed() throws {
        let state = try SyncTestValues.state()
        let object = try SyncTestValues.object(state)
        let user = SyncTestValues.user.rawValue
        let personalID = SyncTestValues.personalPrompt.rawValue
        let groupID = SyncTestValues.group.rawValue
        let changes: [(inout [String: Any]) throws -> Void] = [
            { $0["user_id"] = "invalid" },
            { $0["database_id"] = SyncTestValues.uuid.uuidString },
            { $0["library_root"] = "/library/../other" },
            { $0["server_url"] = "https://name:secret@example.test" },
            { $0["cursors"] = ["private:\(user)": "opaque"] },
            { $0["cursors"] = ["user:\(SyncTestValues.otherUser.rawValue)": "opaque"] },
            { $0["cursors"] = ["user:\(user)": ""] },
            { $0["groups"] = ["invalid": ($0["groups"] as! [String: Any])[groupID]!] },
            { value in
                var prompts = value["prompts"] as! [String: Any]
                prompts["not-a-ulid"] = prompts.removeValue(forKey: personalID)
                value["prompts"] = prompts
            },
            { value in try Self.editPrompt(&value, id: personalID) { $0["canonical_hash"] = String(repeating: "A", count: 64) } },
            { value in try Self.editPrompt(&value, id: personalID) { $0["canonical_hash"] = "short" } },
            { value in try Self.editPrompt(&value, id: personalID) { $0["canonical_hash"] = NSNull() } },
            { value in try Self.editPrompt(&value, id: personalID) { $0["scope_key"] = "group:\(SyncTestValues.device.rawValue)" } },
            { value in try Self.editPrompt(&value, id: personalID) { $0["path"] = "../escape.md" } },
            { value in try Self.editPrompt(&value, id: personalID) { $0["path"] = "Cafe\u{301}.md" } },
            { value in try Self.editPrompt(&value, id: personalID) { $0["rev"] = -1 } },
            { value in try Self.editPrompt(&value, id: personalID) { $0["rev"] = 0 } },
            { value in try Self.editPrompt(&value, id: personalID) { $0["origin"] = ["kind": "conflict_of", "prompt_id": "secret"] } },
            { value in try Self.editPrompt(&value, id: personalID) {
                var error = $0["last_error"] as! [String: Any]
                error["code"] = "arbitrary server body"
                $0["last_error"] = error
            } },
            { $0["favorites"] = [personalID: true] },
            { $0["favorites"] = [SyncTestValues.groupPrompt.rawValue: false] }
        ]
        for change in changes {
            let files = MemoryFileStore()
            let operations = MemorySyncFileOperations(files: files)
            var changed = object
            try change(&changed)
            try SyncTestValues.write(changed, to: files, path: path)
            let original = try files.read(at: path)
            let store = SyncStateStore(files: files, operations: operations)
            XCTAssertEqual(store.snapshot.error, .corruptFile)
            XCTAssertNil(store.snapshot.value)
            XCTAssertThrowsError(try store.update(for: state.binding) { $0.databaseID = nil }) {
                XCTAssertEqual($0 as? SyncError, .corruptFile)
            }
            XCTAssertEqual(try files.read(at: path), original)
            XCTAssertEqual(operations.flushCount, 0)
        }
    }

    func testCorruptAndUnsupportedFilesRequireExplicitResetAndPreserveLibrary() throws {
        let binding = try SyncTestValues.binding()
        for (source, error) in [("{bad", SyncError.corruptFile), ("{\"version\":2}", .futureVersion(2)),
                                ("{\"version\":0}", .unsupportedVersion(0))] {
            let files = MemoryFileStore()
            let library = MemoryFileStore()
            try library.put("local edits", at: "Keep.md")
            try files.put("app-data canary", at: "Keep.md")
            try files.put(source, at: path)
            let operations = MemorySyncFileOperations(files: files)
            let store = SyncStateStore(files: files, operations: operations)
            XCTAssertEqual(store.snapshot.error, error)
            XCTAssertThrowsError(try store.load(for: binding)) { XCTAssertEqual($0 as? SyncError, error) }
            XCTAssertEqual(try files.text(at: path), source)
            try store.reset(for: binding)
            XCTAssertNil(store.snapshot.error)
            XCTAssertEqual(try store.load(for: binding), try SyncState(binding: binding))
            XCTAssertEqual(try library.text(at: "Keep.md"), "local edits")
            XCTAssertEqual(library.listCount, 0)
            XCTAssertEqual(try files.text(at: "Keep.md"), "app-data canary")
        }
    }

    func testUnknownFieldsSurviveNestedEditsWhileRemovedRecordsStayRemoved() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let state = try SyncTestValues.state()
        var object = try SyncTestValues.object(state)
        object["future"] = ["nested": [1.25, NSNull(), "value"]] as [String: Any]
        var groups = object["groups"] as! [String: [String: Any]]
        groups[SyncTestValues.group.rawValue]!["future_group"] = true
        object["groups"] = groups
        try Self.editPrompt(&object, id: SyncTestValues.personalPrompt.rawValue) {
            $0["future_prompt"] = ["extra": 123]
            var origin = $0["origin"] as! [String: Any]
            origin["future_origin"] = "kept"
            $0["origin"] = origin
            var error = $0["last_error"] as! [String: Any]
            var fingerprint = error["fingerprint"] as! [String: Any]
            fingerprint["future_fingerprint"] = "kept"
            error["fingerprint"] = fingerprint
            $0["last_error"] = error
        }
        try SyncTestValues.write(object, to: files, path: path)
        let store = SyncStateStore(files: files, operations: operations)
        try store.update(for: state.binding) { $0.cursors[.user(SyncTestValues.user)] = "new opaque cursor" }
        let updated = try JSONSerialization.jsonObject(with: files.read(at: path)) as! [String: Any]
        XCTAssertTrue(NSDictionary(dictionary: updated["future"] as! [String: Any])
            .isEqual(to: object["future"] as! [String: Any]))
        let prompt = (updated["prompts"] as! [String: [String: Any]])[SyncTestValues.personalPrompt.rawValue]!
        XCTAssertEqual((prompt["future_prompt"] as! [String: Int])["extra"], 123)
        XCTAssertEqual((prompt["origin"] as! [String: String])["future_origin"], "kept")
        let fingerprint = (prompt["last_error"] as! [String: Any])["fingerprint"] as! [String: Any]
        XCTAssertEqual(fingerprint["future_fingerprint"] as? String, "kept")
        XCTAssertEqual((updated["groups"] as! [String: [String: Any]])[SyncTestValues.group.rawValue]!["future_group"] as? Bool, true)

        try store.update(for: state.binding) {
            $0.prompts.removeValue(forKey: .assigned(SyncTestValues.personalPrompt))
            try $0.applyGroupFavorite(false, for: .assigned(SyncTestValues.groupPrompt))
        }
        let pruned = try JSONSerialization.jsonObject(with: files.read(at: path)) as! [String: Any]
        XCTAssertNil((pruned["prompts"] as! [String: Any])[SyncTestValues.personalPrompt.rawValue])
        XCTAssertTrue((pruned["favorites"] as! [String: Any]).isEmpty)
    }

    func testClearedErrorAndChangedOriginDoNotResurrectKnownFields() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let state = try SyncTestValues.state()
        let store = SyncStateStore(files: files, operations: operations)
        try store.update(for: state.binding) { $0 = state }
        try store.update(for: state.binding) {
            let previous = $0.prompts[.assigned(SyncTestValues.personalPrompt)]!
            $0.prompts[.assigned(SyncTestValues.personalPrompt)] = try SyncPromptState(scope: previous.scope,
                path: previous.path, rev: previous.rev, canonicalHash: previous.canonicalHash, origin: .rescued)
        }
        let reloaded = try XCTUnwrap(store.load(for: state.binding))
        XCTAssertEqual(reloaded.prompts[.assigned(SyncTestValues.personalPrompt)]?.origin, .rescued)
        XCTAssertNil(reloaded.prompts[.assigned(SyncTestValues.personalPrompt)]?.lastError)
    }

    func testFailedWriteRetainsCacheAndRetryCommits() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let state = try SyncTestValues.state()
        let store = SyncStateStore(files: files, operations: operations)
        try store.update(for: state.binding) { $0 = state }
        let original = try files.read(at: path)
        files.failNextWrite = true
        XCTAssertThrowsError(try store.update(for: state.binding) { $0.databaseID = nil }) {
            XCTAssertEqual($0 as? SyncError, .writeFailed(.ioFailure))
        }
        XCTAssertEqual(store.snapshot.value, state)
        XCTAssertNil(store.snapshot.error)
        XCTAssertEqual(try files.read(at: path), original)
        try store.update(for: state.binding) { $0.databaseID = nil }
        XCTAssertNil(store.snapshot.value?.databaseID)
        XCTAssertNil(try SyncStateStore(files: files, operations: operations).load(for: state.binding)?.databaseID)
    }

    func testClearingMissingStateIsIdempotentWithoutCreatingDirectories() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let store = SyncStateStore(files: files, operations: operations)
        try store.clear()
        try store.clear()
        XCTAssertNil(store.snapshot.value)
        XCTAssertNil(store.snapshot.error)
        XCTAssertTrue(try files.listFiles().isEmpty)
        XCTAssertEqual(operations.flushCount, 0)
    }

    func testEveryFlushFailureRetainsCacheAndBlocksFurtherAcknowledgment() throws {
        for offset in 1...3 {
            let files = MemoryFileStore()
            let operations = MemorySyncFileOperations(files: files)
            let state = try SyncTestValues.state()
            let store = SyncStateStore(files: files, operations: operations)
            try store.update(for: state.binding) { $0 = state }
            operations.failFlushNumber = operations.flushCount + offset
            XCTAssertThrowsError(try store.update(for: state.binding) { $0.cursors[.user(SyncTestValues.user)] = "unacknowledged" }) {
                XCTAssertEqual($0 as? SyncError, .durabilityUncertain)
            }
            XCTAssertEqual(store.snapshot.value, state)
            XCTAssertEqual(store.snapshot.error, .durabilityUncertain)
            XCTAssertThrowsError(try store.load(for: state.binding)) {
                XCTAssertEqual($0 as? SyncError, .durabilityUncertain)
            }
            XCTAssertThrowsError(try store.update(for: state.binding) { $0.databaseID = nil }) {
                XCTAssertEqual($0 as? SyncError, .durabilityUncertain)
            }
        }
    }

    func testRecoveryReadFailureKeepsDurabilityLatchAndRetriesFlush() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let store = SyncStateStore(files: files, operations: operations)
        let state = try SyncTestValues.state()
        try store.update(for: state.binding) { $0 = state }
        store.blockForRecovery(retaining: nil)
        let flushCount = operations.flushCount
        files.onRead = { _ in throw FileStoreError.ioFailure }
        for _ in 0..<2 {
            XCTAssertThrowsError(try store.recover(for: state.binding)) {
                XCTAssertEqual($0 as? SyncError, .readFailed(.ioFailure))
            }
            XCTAssertEqual(store.snapshot.error, .durabilityUncertain)
            XCTAssertNil(store.snapshot.value)
            XCTAssertThrowsError(try store.load(for: state.binding)) {
                XCTAssertEqual($0 as? SyncError, .durabilityUncertain)
            }
        }
        XCTAssertEqual(operations.flushCount, flushCount)
        files.onRead = nil
        XCTAssertEqual(try store.recover(for: state.binding), state)
        XCTAssertEqual(operations.flushCount, flushCount + 3)
        XCTAssertNil(store.snapshot.error)
    }

    func testMissingUncertainPublicationCannotRecoverAsAnEmptyDocument() throws {
        for acknowledged in [false, true] {
            let files = MemoryFileStore()
            let operations = MemorySyncFileOperations(files: files)
            let store = SyncStateStore(files: files, operations: operations)
            let state = try SyncTestValues.state()
            if acknowledged { try store.update(for: state.binding) { $0 = state } }
            operations.failFlushNumber = operations.flushCount + 1
            XCTAssertThrowsError(try store.update(for: state.binding) { $0 = state }) {
                XCTAssertEqual($0 as? SyncError, .durabilityUncertain)
            }
            let published = try files.read(at: path)
            try files.delete(at: path)
            operations.failFlushNumber = nil
            let flushCount = operations.flushCount
            for _ in 0..<2 {
                XCTAssertThrowsError(try store.recover(for: state.binding)) {
                    XCTAssertEqual($0 as? SyncError, .readFailed(.notFound))
                }
                XCTAssertEqual(store.snapshot.error, .durabilityUncertain)
                XCTAssertEqual(store.snapshot.value, acknowledged ? state : nil)
                XCTAssertThrowsError(try store.update(for: state.binding) { $0 = state }) {
                    XCTAssertEqual($0 as? SyncError, .durabilityUncertain)
                }
            }
            XCTAssertEqual(operations.flushCount, flushCount)
            try files.writePrivate(published, at: path)
            XCTAssertEqual(try store.recover(for: state.binding), state)
            XCTAssertEqual(operations.flushCount, flushCount + 3)
            XCTAssertNil(store.snapshot.error)
        }
    }

    func testClearRetryMustFlushAnAlreadyDeletedDocumentBeforeRecovery() throws {
        for acknowledged in [false, true] {
            for offset in 1...2 {
                let files = MemoryFileStore()
                let operations = MemorySyncFileOperations(files: files)
                try operations.createDirectory(at: "sync")
                let state = try SyncTestValues.state()
                let store = SyncStateStore(files: files, operations: operations)
                if acknowledged {
                    try store.update(for: state.binding) { $0 = state }
                } else {
                    operations.failFlushNumber = operations.flushCount + 1
                    XCTAssertThrowsError(try store.update(for: state.binding) { $0 = state }) {
                        XCTAssertEqual($0 as? SyncError, .durabilityUncertain)
                    }
                }
                operations.failFlushNumber = operations.flushCount + offset
                XCTAssertThrowsError(try store.clear()) {
                    XCTAssertEqual($0 as? SyncError, .durabilityUncertain)
                }
                XCTAssertNil(try files.stamp(at: path))
                let failedFlushCount = operations.flushCount
                operations.failFlushNumber = failedFlushCount + 1
                XCTAssertThrowsError(try store.clear()) {
                    XCTAssertEqual($0 as? SyncError, .durabilityUncertain)
                }
                XCTAssertEqual(operations.flushCount, failedFlushCount + 1)
                XCTAssertEqual(store.snapshot.error, .durabilityUncertain)

                operations.failFlushNumber = nil
                let retryFlushCount = operations.flushCount
                try store.clear()
                XCTAssertEqual(operations.flushCount, retryFlushCount + 2)
                XCTAssertEqual(Array(operations.flushedDirectories.suffix(2)), [RelativePath("sync"), nil])
                XCTAssertNil(store.snapshot.error)
                XCTAssertNil(store.snapshot.value)
                XCTAssertNil(try store.load(for: state.binding))
                try store.clear()
                XCTAssertEqual(operations.flushCount, retryFlushCount + 2)
            }
        }
    }

    func testExternalCorruptionOrRemovalBlocksEditsWithoutReset() throws {
        for remove in [false, true] {
            let files = MemoryFileStore()
            let operations = MemorySyncFileOperations(files: files)
            let state = try SyncTestValues.state()
            let store = SyncStateStore(files: files, operations: operations)
            try store.update(for: state.binding) { $0 = state }
            if remove { try files.delete(at: path) }
            else { try files.put("{\"version\":99}", at: path) }
            let error: SyncError = remove ? .readFailed(.notFound) : .futureVersion(99)
            XCTAssertThrowsError(try store.update(for: state.binding) { $0.databaseID = nil }) {
                XCTAssertEqual($0 as? SyncError, error)
            }
            XCTAssertNil(store.snapshot.value)
            XCTAssertEqual(store.snapshot.error, error)
            XCTAssertThrowsError(try store.update(for: state.binding) { $0.databaseID = nil }) {
                XCTAssertEqual($0 as? SyncError, error)
            }
            try store.reset(for: state.binding)
            XCTAssertNil(store.snapshot.error)
            XCTAssertEqual(try store.load(for: state.binding), try SyncState(binding: state.binding))
        }
    }

    func testAccountServerAndRootMismatchNeverReuseOrOverwriteState() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let state = try SyncTestValues.state()
        let store = SyncStateStore(files: files, operations: operations)
        try store.update(for: state.binding) { $0 = state }
        let original = try files.read(at: path)
        for binding in [try SyncTestValues.binding(root: "/another"),
                        try SyncTestValues.binding(userID: SyncTestValues.otherUser),
                        try SyncTestValues.binding(server: "https://other.test/paw")] {
            XCTAssertThrowsError(try store.load(for: binding)) { XCTAssertEqual($0 as? SyncError, .bindingMismatch) }
            XCTAssertThrowsError(try store.update(for: binding) { $0.databaseID = nil }) {
                XCTAssertEqual($0 as? SyncError, .bindingMismatch)
            }
            XCTAssertEqual(try files.read(at: path), original)
        }
        XCTAssertEqual(try store.load(for: state.binding), state)
    }

    func testFavoriteTrueFalseAbsentSemanticsSurviveRestart() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let state = try SyncTestValues.state()
        let store = SyncStateStore(files: files, operations: operations)
        try store.update(for: state.binding) { $0 = state }
        for input in [nil, false, nil, true, nil] as [Bool?] {
            let previous = store.snapshot.value!.favorites[.assigned(SyncTestValues.groupPrompt)]
            try store.update(for: state.binding) { try $0.applyGroupFavorite(input, for: .assigned(SyncTestValues.groupPrompt)) }
            let expected = input.map { $0 ? true : nil } ?? previous
            let reloaded = try XCTUnwrap(SyncStateStore(files: files, operations: operations).load(for: state.binding))
            XCTAssertEqual(reloaded.favorites[.assigned(SyncTestValues.groupPrompt)], expected)
            XCTAssertEqual(reloaded.prompts, state.prompts)
        }
        XCTAssertThrowsError(try store.update(for: state.binding) {
            try $0.applyGroupFavorite(true, for: .assigned(SyncTestValues.personalPrompt))
        })
    }

    func testPendingLocalPromptErrorAndFavoriteSurviveIdentityAssignment() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let store = SyncStateStore(files: files, operations: operations)
        let state = try SyncTestValues.state()
        let path = RelativePath("Cafe\u{301}.md")
        let local = PromptIdentity(path: path.string, id: nil)
        let fingerprint = try SyncInputFingerprint(bytes: Data([0xff]), path: path,
            scope: .group(SyncTestValues.group), accessGeneration: 17, operation: .put)
        let pending = try SyncPromptState(scope: .group(SyncTestValues.group), path: path, rev: 0,
            lastError: SyncPromptError(code: .content(.invalidUTF8), fingerprint: fingerprint))
        try store.update(for: state.binding) {
            $0 = state
            $0.prompts[local] = pending
            try $0.applyGroupFavorite(true, for: local)
        }
        let loaded = try XCTUnwrap(SyncStateStore(files: files, operations: operations).load(for: state.binding))
        XCTAssertEqual(loaded.prompts[local], pending)
        XCTAssertEqual(loaded.favorites[local], true)
        XCTAssertNil(loaded.prompts[local]?.canonicalHash)
        let assigned = PromptIdentity.assigned(SyncTestValues.device)
        try store.update(for: state.binding) {
            let favorite = $0.favorites[local]
            try $0.applyGroupFavorite(false, for: local)
            $0.prompts[assigned] = $0.prompts.removeValue(forKey: local)
            try $0.applyGroupFavorite(favorite, for: assigned)
        }
        let migrated = try XCTUnwrap(store.load(for: state.binding))
        XCTAssertNil(migrated.prompts[local])
        XCTAssertNil(migrated.favorites[local])
        XCTAssertEqual(migrated.prompts[assigned], pending)
        XCTAssertEqual(migrated.favorites[assigned], true)
    }

    func testPendingCreateCannotClaimCanonicalBaseline() throws {
        let scope = SyncScopeKey.user(SyncTestValues.user)
        let hash = SyncHash(bytes: Data("sent bytes".utf8))
        let pending = try SyncPromptState(scope: scope, path: "Pending.md", rev: 0)
        XCTAssertNil(pending.canonicalHash)
        XCTAssertEqual(try JSONDecoder().decode(SyncPromptState.self, from: JSONEncoder().encode(pending)), pending)
        XCTAssertThrowsError(try SyncPromptState(scope: scope, path: pending.path, rev: 0, canonicalHash: hash)) {
            XCTAssertEqual($0 as? SyncError, .invalidState)
        }
        var invalid = try SyncTestValues.object(pending)
        invalid["canonical_hash"] = hash.rawValue
        XCTAssertThrowsError(try JSONDecoder().decode(SyncPromptState.self,
            from: JSONSerialization.data(withJSONObject: invalid))) {
            XCTAssertEqual($0 as? SyncError, .invalidState)
        }
        XCTAssertThrowsError(try SyncPromptState(scope: scope, path: pending.path, rev: 1)) {
            XCTAssertEqual($0 as? SyncError, .invalidState)
        }
        XCTAssertEqual(try SyncPromptState(scope: scope, path: pending.path, rev: 1, canonicalHash: hash).canonicalHash, hash)
    }

    func testAbsentGroupFavoritePreservesAnyTarget() throws {
        var state = try SyncTestValues.state()
        let original = state
        let targets = [PromptIdentity.assigned(SyncTestValues.groupPrompt),
                       .assigned(SyncTestValues.personalPrompt), .assigned(SyncTestValues.device), .local("invalid")]
        for target in targets {
            XCTAssertNoThrow(try state.applyGroupFavorite(nil, for: target))
            XCTAssertEqual(state, original)
        }
        for target in targets.dropFirst() {
            for favorite in [false, true] {
                XCTAssertThrowsError(try state.applyGroupFavorite(favorite, for: target)) {
                    XCTAssertEqual($0 as? SyncError, .invalidState)
                }
                XCTAssertEqual(state, original)
            }
        }
    }

    func testStateDomainValidationUsesSyncError() throws {
        let scope = SyncScopeKey.user(SyncTestValues.user)
        let pending = try SyncPromptState(scope: scope, path: "Pending.md", rev: 0)
        let binding = try SyncTestValues.binding()
        let invalid: [(String, () throws -> Void)] = [
            ("scope", { _ = try SyncScopeKey("private:" + SyncTestValues.user.rawValue) }),
            ("group name", { _ = try SyncGroupState(name: "", folder: "Team", role: .viewer) }),
            ("folder", { try SyncIdentifiers.folder(String(repeating: "a", count: 256)) }),
            ("pending path", { _ = try SyncPromptState(scope: scope, path: "../validation-sentinel.md", rev: 0) }),
            ("acknowledged path", { _ = try SyncPromptState(scope: scope, path: "validation-sentinel.txt", rev: 1,
                canonicalHash: SyncHash(bytes: Data())) }),
            ("identity", { _ = try SyncState(binding: binding, prompts: [.local("validation-sentinel"): pending]) })
        ]
        for (name, validate) in invalid {
            XCTAssertThrowsError(try validate(), name) {
                XCTAssertEqual($0 as? SyncError, .invalidState, name)
                XCTAssertFalse(String(reflecting: $0).contains("validation-sentinel"), name)
            }
        }
    }

    func testLocalIdentityCannotClaimAnAcknowledgedServerRevision() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let state = try SyncTestValues.state()
        let store = SyncStateStore(files: files, operations: operations)
        try store.update(for: state.binding) { $0 = state }
        let original = try files.read(at: path)
        XCTAssertThrowsError(try store.update(for: state.binding) {
            let local = PromptIdentity(path: "Local.md", id: nil)
            $0.prompts[local] = try SyncPromptState(scope: .user(SyncTestValues.user), path: "Local.md", rev: 1,
                canonicalHash: SyncHash(bytes: Data("local bytes".utf8)))
        }) { XCTAssertEqual($0 as? SyncError, .invalidState) }
        XCTAssertEqual(try files.read(at: path), original)
        XCTAssertEqual(store.snapshot.value, state)
    }

    func testFingerprintChangesWithEveryOffendingInput() throws {
        let scope = SyncScopeKey.user(SyncTestValues.user)
        let original = try SyncInputFingerprint(bytes: Data("a".utf8), path: "A.md", scope: scope,
                                                accessGeneration: 0, operation: .put)
        for changed in [try SyncInputFingerprint(bytes: Data("b".utf8), path: "A.md", scope: scope, accessGeneration: 0, operation: .put),
                        try SyncInputFingerprint(bytes: Data("a".utf8), path: "B.md", scope: scope, accessGeneration: 0, operation: .put),
                        try SyncInputFingerprint(bytes: Data("a".utf8), path: "A.md", scope: .group(SyncTestValues.group), accessGeneration: 0, operation: .put),
                        try SyncInputFingerprint(bytes: Data("a".utf8), path: "A.md", scope: scope, accessGeneration: 1, operation: .put),
                        try SyncInputFingerprint(bytes: Data("a".utf8), path: "A.md", scope: scope, accessGeneration: 0, operation: .move)] {
            XCTAssertNotEqual(original, changed)
        }
        XCTAssertThrowsError(try SyncInputFingerprint(bytes: Data(), path: "A.md", scope: scope,
                                                     accessGeneration: -1, operation: .put))
    }

    func testFileCapabilityRetainsDisplacedBytesOnUncertainPublication() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let old = Data("old bytes".utf8)
        let new = Data("new bytes".utf8)
        try files.write(old, at: "File.md")
        let stamp = try XCTUnwrap(files.stamp(at: "File.md"))
        XCTAssertThrowsError(try operations.publish(new, at: "File.md", expecting: .absent, mode: .normal)) {
            XCTAssertEqual(($0 as? SyncFileOperationError)?.code, .occupied)
        }
        XCTAssertThrowsError(try operations.publish(new, at: "File.md",
            expecting: .matching(stamp: stamp, bytes: new), mode: .normal)) {
            XCTAssertEqual(($0 as? SyncFileOperationError)?.effect, .unchanged)
        }
        XCTAssertEqual(try files.read(at: "File.md"), old)
        operations.failFlushNumber = 1
        XCTAssertThrowsError(try operations.publish(new, at: "File.md",
            expecting: .matching(stamp: stamp, bytes: old), mode: .readOnly)) {
            let error = $0 as? SyncFileOperationError
            XCTAssertEqual(error?.code, .durabilityFailed)
            XCTAssertEqual(error?.effect, .applied)
            XCTAssertEqual(error?.displacedBytes, old)
            XCTAssertFalse(String(reflecting: $0).contains("old bytes"))
        }
        XCTAssertEqual(try files.read(at: "File.md"), new)
        XCTAssertEqual(operations.modes["File.md"], .readOnly)
        let current = try XCTUnwrap(files.stamp(at: "File.md"))
        try operations.trash(at: "File.md", expecting: .matching(stamp: current, bytes: new))
        XCTAssertNil(try files.stamp(at: "File.md"))
        XCTAssertEqual(operations.trashed["File.md"], new)
        try operations.createDirectory(at: "Groups")
        try operations.createDirectory(at: "Groups/Empty")
        XCTAssertEqual(try operations.directories(at: "Groups"), [RelativePath("Groups/Empty")])
        XCTAssertThrowsError(try operations.createDirectory(at: "Groups/Empty")) {
            XCTAssertEqual(($0 as? SyncFileOperationError)?.code, .occupied)
            XCTAssertEqual(($0 as? SyncFileOperationError)?.effect, .unchanged)
        }
        try operations.renameDirectory(from: "Groups/Empty", to: "Groups/Renamed")
        XCTAssertEqual(try operations.directories(at: "Groups"), [RelativePath("Groups/Renamed")])
        try files.put("unowned", at: "Groups/Occupied/File.md")
        XCTAssertEqual(try operations.directories(at: "Groups"), [RelativePath("Groups/Occupied"), "Groups/Renamed"])
        XCTAssertThrowsError(try operations.createDirectory(at: "Groups/Occupied")) {
            XCTAssertEqual(($0 as? SyncFileOperationError)?.code, .occupied)
            XCTAssertEqual(($0 as? SyncFileOperationError)?.effect, .unchanged)
        }
        XCTAssertThrowsError(try operations.renameDirectory(from: "Groups/Renamed", to: "Groups/Occupied")) {
            XCTAssertEqual(($0 as? SyncFileOperationError)?.code, .occupied)
            XCTAssertEqual(($0 as? SyncFileOperationError)?.effect, .unchanged)
        }
        XCTAssertEqual(try operations.directories(at: "Groups"), [RelativePath("Groups/Occupied"), "Groups/Renamed"])
        XCTAssertEqual(try files.text(at: "Groups/Occupied/File.md"), "unowned")
        try operations.renameDirectory(from: "Groups/Occupied", to: "Groups/Moved")
        XCTAssertEqual(try files.text(at: "Groups/Moved/File.md"), "unowned")
        XCTAssertEqual(try operations.directories(at: "Groups"), [RelativePath("Groups/Moved"), "Groups/Renamed"])
    }

    private static func editPrompt(_ object: inout [String: Any], id: String,
                                   _ change: (inout [String: Any]) throws -> Void) throws {
        var prompts = try XCTUnwrap(object["prompts"] as? [String: [String: Any]])
        var prompt = try XCTUnwrap(prompts[id])
        try change(&prompt)
        prompts[id] = prompt
        object["prompts"] = prompts
    }
}
