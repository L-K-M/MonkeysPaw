import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncPullCollectorTests: XCTestCase {
    private let user = SyncTestValues.user
    private let group = SyncTestValues.group
    private let prompt = SyncTestValues.personalPrompt
    private let shared = SyncTestValues.groupPrompt
    private let another = SyncTestValues.device
    private let database = SyncTestValues.uuid.uuidString.lowercased()
    private let restored = "22222222-2222-4222-8222-222222222222"
    private var userKey: String { SyncScopeKey.user(user).rawValue }
    private var groupKey: String { SyncScopeKey.group(group).rawValue }
    private var initial: SyncAPI.PullRequest {
        .init(databaseID: database, cursors: [userKey: "original user / Ω +=", groupKey: "original group"])
    }

    func testStagingPreservesCancellationFromEveryFileOperation() throws {
        enum Operation: CaseIterable { case write, read, delete }
        let page = response([personal(.snapshot, head: 0, cursor: "0")])
        for operation in Operation.allCases {
            let files = MemoryFileStore()
            let staging = SyncPullStaging(files: files)
            if operation != .write { try staging.append(page) }
            files.onPrivateWrite = { _ in if operation == .write { throw CancellationError() } }
            files.onRead = { _ in if operation == .read { throw CancellationError() } }
            files.onDelete = { _ in if operation == .delete { throw CancellationError() } }
            do {
                switch operation {
                case .write: try staging.append(page)
                case .read: _ = try staging.read(0)
                case .delete: try staging.discard()
                }
                XCTFail("Expected cancellation from \(operation)")
            } catch { XCTAssertTrue(error is CancellationError, "\(operation): \(error)") }
            files.onPrivateWrite = nil
            files.onRead = nil
            files.onDelete = nil
            try staging.discard()
            XCTAssertTrue(try staged(files).isEmpty)
        }
    }

    func testMovePairSplitAcrossPagesRetainsSourceScopesAndOpaqueCursors() async throws {
        let transport = try script([
            response([personal(head: 10, cursor: "advanced user", items: [.moveOut(seq: 10, id: prompt.rawValue)]),
                      team(head: 11, cursor: "original group", more: true)]),
            response([team(head: 11, cursor: "finished group", items: [upsert(11)]),
                      personal(head: 10, cursor: "advanced user")])
        ])
        let files = MemoryFileStore()
        let pull = try await collector(transport, files).collect(initial)
        XCTAssertEqual(try items(pull, .delta), [
            .init(scope: .user(user), item: .moveOut(seq: 10, id: prompt.rawValue)),
            .init(scope: .group(group), item: upsert(11))
        ])
        XCTAssertEqual(transport.requests[1].cursors[userKey], "advanced user")
        XCTAssertEqual(transport.requests[1].cursors[groupKey], "original group")
        XCTAssertEqual(pull.cursors[.group(group)], "finished group")
        XCTAssertTrue(try items(pull, .snapshot).isEmpty)
        XCTAssertEqual(try staged(files).count, 2)
        XCTAssertTrue(try staged(files).allSatisfy { files.isPrivate(at: $0.relativePath) })
        try pull.discard()
        XCTAssertTrue(try staged(files).isEmpty)
    }

    func testCompleteSnapshotsRemainSeparateFromSubsequentDeltas() async throws {
        let transport = try script([
            response([personal(.snapshot, head: 20, cursor: "user snapshot done", items: [upsert(20)]),
                      team(.snapshot, head: 21, cursor: "manifest / + = Ω", more: true, items: [upsert(21, id: shared)])]),
            response([personal(head: 23, cursor: "user tail done", items: [upsert(22, rev: 2)]),
                      team(.snapshot, head: 21, cursor: "group snapshot done", items: [upsert(21, id: another)])])
        ])
        let pull = try await collector(transport).collect(.init(databaseID: nil, cursors: [:]))
        XCTAssertEqual(try items(pull, .snapshot).map(\.seq), [20, 21, 21])
        XCTAssertEqual(try items(pull, .delta), [.init(scope: .user(user), item: upsert(22, rev: 2))])
        XCTAssertEqual(pull.scopes[.user(user)]?.snapshotHead, 20)
        XCTAssertEqual(pull.scopes[.user(user)]?.head, 23)
        XCTAssertEqual(pull.scopes[.group(group)]?.snapshotHead, 21)
        XCTAssertEqual(transport.requests[1].databaseID, database)
        XCTAssertEqual(transport.requests[1].cursors[groupKey], "manifest / + = Ω")
    }

    func testEmptyZeroHeadScopeBesidePagedSnapshotAndFairlySkippedScope() async throws {
        let transport = try script([
            response([personal(.snapshot, head: 0, cursor: "0"),
                      team(.snapshot, head: 7, cursor: "manifest", more: true, items: [upsert(7, id: shared)])]),
            response([personal(.snapshot, head: 0, cursor: "0"),
                      team(.snapshot, head: 7, cursor: "done", items: [upsert(7, id: another)])])
        ])
        let pull = try await collector(transport).collect(.init(databaseID: database, cursors: [userKey: "0", groupKey: "0"]))
        XCTAssertEqual(pull.scopes[.user(user)]?.snapshotHead, 0)
        XCTAssertEqual(try items(pull, .snapshot).count, 2)

        let fair = try script([
            response([personal(head: 10, cursor: "u10", more: true, items: [upsert(10)]),
                      team(.snapshot, head: 11, cursor: "original group", more: true)]),
            response([personal(head: 12, cursor: "u12", items: [upsert(12, rev: 2)]),
                      team(.snapshot, head: 11, cursor: "g11", items: [upsert(11)])])
        ])
        let fairPull = try await collector(fair).collect(initial)
        XCTAssertEqual(try items(fairPull, .snapshot).count, 1)
        XCTAssertEqual(try items(fairPull, .delta).map(\.seq), [10, 12])
    }

    func testLatestRenameDowngradeAndRemovalOverrideEarlierScopePages() async throws {
        for remove in [false, true] {
            var pages = [
                response([personal(head: 10, cursor: "u10", more: true, items: [upsert(10)]),
                          team(.snapshot, head: 11, cursor: "g11", name: "Old", role: .editor, items: [upsert(11)])]),
                response([personal(head: 12, cursor: "u12", more: remove, items: [upsert(12, rev: 2)]),
                          team(head: 13, cursor: "g13", name: "Renamed", role: .viewer, items: [upsert(13, rev: 2)])])
            ]
            if remove { pages.append(response([personal(head: 14, cursor: "u14")], removed: [groupKey])) }
            let pull = try await collector(script(pages)).collect(initial)
            if remove {
                XCTAssertEqual(pull.removed, [.group(group)])
                XCTAssertNil(pull.cursors[.group(group)])
                XCTAssertNil(pull.scopes[.group(group)])
                XCTAssertFalse(try items(pull, .snapshot).contains { $0.scope == .group(group) })
                XCTAssertFalse(try items(pull, .delta).contains { $0.scope == .group(group) })
            } else {
                XCTAssertEqual(pull.scopes[.group(group)]?.identity, .group(groupID: group.rawValue, name: "Renamed", role: .viewer))
                XCTAssertEqual(try items(pull, .snapshot).count, 1)
                XCTAssertEqual(try items(pull, .delta).filter { $0.scope == .group(group) }.map(\.seq), [13])
            }
        }
    }

    func testRemovedAndRejoinedScopeKeepsOnlyItsNewSnapshot() async throws {
        let transport = try script([
            response([personal(head: 10, cursor: "u10", more: true),
                      team(.snapshot, head: 11, cursor: "g11", items: [upsert(11, id: shared)])]),
            response([personal(head: 12, cursor: "u12", more: true)], removed: [groupKey]),
            response([personal(head: 14, cursor: "u14"),
                      team(.snapshot, head: 13, cursor: "g13", items: [upsert(13, id: another)])])
        ])
        let pull = try await collector(transport).collect(initial)
        XCTAssertEqual(try items(pull, .snapshot), [.init(scope: .group(group), item: upsert(13, id: another))])
        XCTAssertTrue(pull.removed.isEmpty)
        XCTAssertNil(transport.requests[2].cursors[groupKey])
    }

    func testNewSnapshotAfterDeltaOrCompleteSnapshotSupersedesEarlierSegment() async throws {
        for firstMode in [SyncAPI.Mode.delta, .snapshot] {
            let transport = try script([
                response([personal(head: 10, cursor: "u10", more: true),
                          team(firstMode, head: 11, cursor: "g11", items: [upsert(11, id: shared)])]),
                response([personal(head: 12, cursor: "u12", more: true),
                          team(.snapshot, head: 13, cursor: "new manifest", more: true, items: [upsert(13, id: prompt)])]),
                response([personal(head: 14, cursor: "u14"),
                          team(.snapshot, head: 13, cursor: "g13", items: [upsert(13, id: another)])])
            ])
            let pull = try await collector(transport).collect(initial)
            XCTAssertEqual(try items(pull, .snapshot).map(\.item), [upsert(13, id: prompt), upsert(13, id: another)])
            XCTAssertTrue(try items(pull, .delta).isEmpty)
            XCTAssertEqual(pull.scopes[.group(group)]?.snapshotHead, 13)
        }
    }

    func testDatabaseChangeDiscardsEntireAttemptAndRestartsAllScopes() async throws {
        let files = MemoryFileStore()
        let transport = try script([
            response([personal(.snapshot, head: 10, cursor: "old manifest", more: true, items: [upsert(10)]), team(head: 4, cursor: "g4")]),
            response([personal(.snapshot, head: 2, cursor: "ignored", items: [upsert(2)]),
                      team(.snapshot, head: 0, cursor: "0")], database: restored),
            response([personal(.snapshot, head: 3, cursor: "new database done", items: [upsert(3)])], database: restored)
        ])
        let pull = try await collector(transport, files).collect(initial)
        XCTAssertEqual(pull.databaseID.uuidString.lowercased(), restored)
        XCTAssertEqual(try items(pull, .snapshot).map(\.seq), [3])
        XCTAssertEqual(transport.requests[2], .init(databaseID: nil, cursors: [:]))
        XCTAssertEqual(pull.removed, [.group(group)])
        XCTAssertEqual(try staged(files).count, 1)
    }

    func testSnapshotExpiryRewindsUnaffectedCursorsAndResetsOnlyNamedScopes() async throws {
        let files = MemoryFileStore()
        let transport = PullScriptTransport(try [
            http(response([personal(head: 10, cursor: "u10", more: true, items: [upsert(10)]),
                           team(.snapshot, head: 11, cursor: "expired manifest", more: true, items: [upsert(11, id: shared)])])),
            http(SyncAPI.ErrorResponse.snapshotExpired(scopes: [groupKey]), status: 409),
            http(response([personal(head: 10, cursor: "u10", items: [upsert(10)]),
                           team(.snapshot, head: 12, cursor: "g12", items: [upsert(12, id: another)])]))
        ])
        let pull = try await collector(transport, files).collect(initial)
        XCTAssertEqual(transport.requests[2], .init(databaseID: database, cursors: [userKey: initial.cursors[userKey]!]))
        XCTAssertEqual(try items(pull, .delta).map(\.seq), [10])
        XCTAssertEqual(try items(pull, .snapshot).map(\.seq), [12])
        XCTAssertEqual(try staged(files).count, 1)
    }

    func testRepeatedExpiryDatabaseChangeAndMixedRestartsReturnTypedNoProgress() async throws {
        let expired = try http(SyncAPI.ErrorResponse.snapshotExpired(scopes: [groupKey]), status: 409)
        let oldPage = response([personal(head: 10, cursor: "u10", more: true),
                                team(.snapshot, head: 11, cursor: "manifest", more: true)])
        let newPage = response([personal(.snapshot, head: 5, cursor: "new manifest", more: true),
                                team(.snapshot, head: 0, cursor: "0")], database: restored)
        let changedAgain = response([personal(.snapshot, head: 6, cursor: "another manifest", more: true),
                                     team(.snapshot, head: 0, cursor: "0")], database: database)
        let cases: [([HTTPResponse], SyncPullCollectorError)] = try [
            ([http(oldPage), expired, http(oldPage), expired], .noProgress(.snapshotExpired)),
            ([http(oldPage), http(newPage), http(newPage), http(changedAgain)], .noProgress(.databaseChanged)),
            ([http(oldPage), expired, http(oldPage), http(newPage)], .noProgress(.databaseChanged))
        ]
        for (pages, expected) in cases {
            let files = MemoryFileStore()
            await assertError(expected) { _ = try await self.collector(PullScriptTransport(pages), files).collect(self.initial) }
            XCTAssertTrue(try staged(files).isEmpty)
        }
    }

    func testInvalidPathsAndAuthenticatedUserFailBeforeStaging() async throws {
        for path in ["../evil.md", "/evil.md", "Groups/evil.md", ".hidden/evil.md", "a\\b.md", "a.md\u{0000}", "Cafe\u{0301}.md"] {
            let files = MemoryFileStore()
            let pages = try script([response([personal(head: 10, cursor: "u10", items: [upsert(10, path: path)]),
                                              team(head: 0, cursor: "original group")])])
            await assertError(.invalidResponse) { _ = try await self.collector(pages, files).collect(self.initial) }
            XCTAssertEqual(files.writeCount, 0, path)
        }
        let foreign = SyncAPI.SyncScope(identity: .user(userID: SyncTestValues.otherUser.rawValue), mode: .snapshot,
                                       head: 1, cursor: "1", hasMore: false, items: [upsert(1)])
        await assertError(.invalidResponse) {
            _ = try await self.collector(self.script([self.response([foreign])])).collect(.init(databaseID: nil, cursors: [:]))
        }
        let transport = PullScriptTransport([])
        await assertError(.invalidRequest) {
            _ = try await self.collector(transport).collect(.init(databaseID: self.database,
                cursors: [SyncScopeKey.user(SyncTestValues.otherUser).rawValue: "opaque"]))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMalformedIDsAndScopeMetadataFailAfterEarlierPageWithoutLeakingStaging() async throws {
        let good = response([personal(head: 10, cursor: "u10", more: true, items: [upsert(10)]), team(head: 0, cursor: "original group")])
        let mutations: [(inout [String: Any]) -> Void] = [
            { object in self.mutateScope(&object, 0) { scope in
                var item = (scope["items"] as! [[String: Any]])[0]
                var prompt = item["prompt"] as! [String: Any]; prompt["id"] = "invalid-id"; item["prompt"] = prompt; scope["items"] = [item]
            } },
            { object in self.mutateScope(&object, 0) { $0["items"] = [["seq": 10, "kind": "delete", "id": "invalid-id"]] } },
            { object in self.mutateScope(&object, 0) { $0["items"] = [["seq": 10, "kind": "move_out", "id": "invalid-id"]] } },
            { object in self.mutateScope(&object, 0) { $0["key"] = "user:invalid-id" } },
            { object in self.mutateScope(&object, 1) { $0["group_id"] = self.user.rawValue } },
            { object in self.mutateScope(&object, 1) { $0["role"] = "invalid-role" } },
            { object in object["removed"] = ["group:invalid-id"] },
            { object in object["scopes"] = [] }
        ]
        for mutate in mutations {
            let files = MemoryFileStore()
            var object = try SyncTestValues.object(good)
            mutate(&object)
            let invalid = HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: object))
            let transport = PullScriptTransport(try [http(good), invalid])
            do {
                _ = try await collector(transport, files).collect(initial)
                XCTFail("Accepted malformed feed")
            } catch { XCTAssertEqual(error as? SyncHTTPClientError, .malformedResponse) }
            XCTAssertTrue(try staged(files).isEmpty)
        }
    }

    func testStalledContinuationFailsButOpaqueCursorComparisonUsesExactBytes() async throws {
        let page = response([personal(head: 10, cursor: "next", more: true), team(head: 0, cursor: "original group")])
        let files = MemoryFileStore()
        await assertError(.noProgress(.stalledContinuation)) {
            _ = try await self.collector(self.script([page, page]), files).collect(self.initial)
        }
        XCTAssertTrue(try staged(files).isEmpty)

        let opaque = try script([
            response([personal(.snapshot, head: 10, cursor: "opaque-é", more: true, items: [upsert(10)]), team(head: 0, cursor: "original group")]),
            response([personal(.snapshot, head: 10, cursor: "opaque-e\u{0301}", more: true, items: [upsert(10, id: shared)]), team(head: 0, cursor: "original group")]),
            response([personal(.snapshot, head: 10, cursor: "done", items: [upsert(10, id: another)]), team(head: 0, cursor: "original group")])
        ])
        let pull = try await collector(opaque).collect(initial)
        XCTAssertEqual(try items(pull, .snapshot).count, 3)
        XCTAssertTrue(opaque.requests[2].cursors[userKey]!.utf8.elementsEqual("opaque-e\u{0301}".utf8))
    }

    func testIncompleteSnapshotCannotChangeHeadOrTurnIntoDeltas() async throws {
        let first = response([personal(.snapshot, head: 10, cursor: "manifest", more: true, items: [upsert(10)]), team(head: 0, cursor: "original group")])
        for next in [personal(head: 11, cursor: "done", items: [upsert(11)]), personal(.snapshot, head: 11, cursor: "done", items: [upsert(11)])] {
            let files = MemoryFileStore()
            await assertError(.invalidResponse) {
                _ = try await self.collector(self.script([first, self.response([next, self.team(head: 0, cursor: "original group")])]), files).collect(self.initial)
            }
            XCTAssertTrue(try staged(files).isEmpty)
        }
    }

    func testCollectionDeadlineSharesFiveMinuteBudgetAcrossRestart() async throws {
        XCTAssertEqual(Limits.syncRequestTimeout, .seconds(60))
        XCTAssertEqual(Limits.syncCollectionBudget, .seconds(300))
        XCTAssertEqual(Limits.syncCollectionRestartLimit, 1)
        let clock = PullTestClock()
        let files = MemoryFileStore()
        let transport = PullScriptTransport(try [
            http(response([personal(head: 10, cursor: "u10", more: true), team(.snapshot, head: 11, cursor: "manifest", more: true)])),
            http(SyncAPI.ErrorResponse.snapshotExpired(scopes: [groupKey]), status: 409),
            http(response([personal(head: 10, cursor: "u10"), team(.snapshot, head: 11, cursor: "done")]))
        ])
        transport.onSend = { index, _ in clock.advance(.seconds(index == 2 ? 151 : 75)) }
        await assertError(.noProgress(.collectionDeadline)) {
            _ = try await self.collector(transport, files, now: { clock.now }).collect(self.initial)
        }
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertTrue(try staged(files).isEmpty)
        let empty = PullScriptTransport([])
        await assertError(.noProgress(.collectionDeadline)) {
            _ = try await self.collector(empty).collect(self.initial, deadline: ContinuousClock.now.advanced(by: .seconds(-1)))
        }
        XCTAssertTrue(empty.requests.isEmpty)
    }

    func testDeadlineInFlightAndCancellationDiscardIncompletePages() async throws {
        let files = MemoryFileStore()
        let transport = try script([response([personal(head: 10, cursor: "u10"), team(head: 0, cursor: "original group")])])
        transport.delay = .milliseconds(50)
        await assertError(.noProgress(.collectionDeadline)) {
            _ = try await self.collector(transport, files).collect(self.initial, deadline: ContinuousClock.now.advanced(by: .milliseconds(20)))
        }
        XCTAssertTrue(try staged(files).isEmpty)

        let cancelled = try script([
            response([personal(head: 10, cursor: "u10", more: true), team(head: 0, cursor: "original group")]),
            response([personal(head: 11, cursor: "u11"), team(head: 0, cursor: "original group")])
        ])
        cancelled.onSend = { index, _ in if index == 1 { withUnsafeCurrentTask { $0?.cancel() } } }
        let clientCollector = try collector(cancelled, files)
        let task = Task { try await clientCollector.collect(self.initial) }
        do { _ = try await task.value; XCTFail("Accepted cancellation") }
        catch { XCTAssertEqual(error as? SyncHTTPClientError, .transport(.cancelled)) }
        XCTAssertTrue(try staged(files).isEmpty)
    }

    func testNoLibraryFileCursorOrStateMutationBeforeOrAfterCompleteCollection() async throws {
        let rig = try SyncApplyTestRig()
        try rig.states.update(for: rig.binding) { $0 = try SyncTestValues.state() }
        try rig.files.put("local bytes", at: "local.md")
        try rig.data.put("unrelated canary", at: "other.json")
        let originalState = try rig.data.read(at: "sync/state.json")
        let stateStamp = try rig.data.stamp(at: "sync/state.json")
        let libraryAccesses = rig.files.accessCount
        let transport = try script([
            response([personal(head: 10, cursor: "u10", more: true, items: [upsert(10)]), team(head: 0, cursor: "original group")]),
            response([personal(head: 11, cursor: "u11", items: [upsert(11, rev: 2)]), team(head: 0, cursor: "original group")])
        ])
        transport.onSend = { index, request in
            XCTAssertEqual(try rig.data.read(at: "sync/state.json"), originalState)
            XCTAssertEqual(try rig.data.stamp(at: "sync/state.json"), stateStamp)
            XCTAssertEqual(try rig.data.text(at: "other.json"), "unrelated canary")
            XCTAssertEqual(rig.files.accessCount, libraryAccesses)
            XCTAssertLessThanOrEqual(ContinuousClock.now.duration(to: request.deadline), .seconds(60))
            XCTAssertEqual(try self.staged(rig.data).count, index)
        }
        var writes = [String]()
        rig.data.onWrite = { writes.append($0) }
        let pull = try await collector(transport, rig.data).collect(initial)
        XCTAssertEqual(try rig.states.load(for: rig.binding), try SyncTestValues.state())
        XCTAssertEqual(try rig.data.read(at: "sync/state.json"), originalState)
        XCTAssertEqual(rig.files.accessCount, libraryAccesses)
        XCTAssertTrue(writes.allSatisfy { $0.hasPrefix("sync/pull-") })
        XCTAssertEqual(try items(pull, .delta).count, 2)
        try pull.discard()
        XCTAssertEqual(try rig.data.text(at: "other.json"), "unrelated canary")
        XCTAssertEqual(try rig.data.read(at: "sync/state.json"), originalState)
        XCTAssertEqual(rig.files.accessCount, libraryAccesses)
    }

    func testStagingFailureAndDroppedHandleCleanOnlyOwnedFiles() async throws {
        let files = MemoryFileStore()
        try files.put("canary", at: "sync/pull-other.json")
        let page = response([personal(head: 10, cursor: "u10"), team(head: 0, cursor: "original group")])
        files.failNextWrite = true
        await assertError(.stagingFailed(.ioFailure)) { _ = try await self.collector(self.script([page]), files).collect(self.initial) }
        XCTAssertEqual(try files.text(at: "sync/pull-other.json"), "canary")
        var pull: SyncCollectedPull? = try await collector(script([page]), files).collect(initial)
        XCTAssertEqual(try files.listFiles().count, 2)
        XCTAssertNotNil(pull)
        pull = nil
        XCTAssertEqual(try files.listFiles().map(\.relativePath), ["sync/pull-other.json"])
    }

    private func collector(_ transport: HTTPTransporting, _ files: FileStore = MemoryFileStore(),
                           now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) throws -> SyncPullCollector {
        let server = try SyncServerURL("https://example.test/paw")
        let client = SyncHTTPClient(server: server, transport: transport,
            credential: .init(server: server, token: SecretValue(String(repeating: "a", count: 42) + "A")))
        return SyncPullCollector(client: client, files: files, userID: user, now: now)
    }

    private func personal(_ mode: SyncAPI.Mode = .delta, head: Int64, cursor: String, more: Bool = false,
                          items: [SyncAPI.FeedItem] = []) -> SyncAPI.SyncScope {
        .init(identity: .user(userID: user.rawValue), mode: mode, head: head, cursor: cursor, hasMore: more, items: items)
    }

    private func team(_ mode: SyncAPI.Mode = .delta, head: Int64, cursor: String, more: Bool = false,
                      name: String = "Team", role: SyncAPI.Role = .editor, items: [SyncAPI.FeedItem] = []) -> SyncAPI.SyncScope {
        .init(identity: .group(groupID: group.rawValue, name: name, role: role), mode: mode, head: head, cursor: cursor, hasMore: more, items: items)
    }

    private func upsert(_ seq: Int64, id: ULID? = nil, path: String = "a.md", rev: Int64 = 1) -> SyncAPI.FeedItem {
        .upsert(seq: seq, prompt: .init(id: (id ?? prompt).rawValue, rev: rev, path: path, content: "server bytes\r\n"))
    }

    private func response(_ scopes: [SyncAPI.SyncScope], removed: [String] = [], database: String? = nil) -> SyncAPI.PullResponse {
        .init(databaseID: database ?? self.database, scopes: scopes, removed: removed)
    }

    private func http(_ dto: some SyncAPIDTO, status: Int = 200) throws -> HTTPResponse {
        .init(statusCode: status, body: try JSONEncoder().encode(dto))
    }

    private func script(_ responses: [SyncAPI.PullResponse]) throws -> PullScriptTransport {
        PullScriptTransport(try responses.map { try http($0) })
    }

    private func items(_ pull: SyncCollectedPull, _ mode: SyncAPI.Mode) throws -> [SyncCollectedItem] {
        var items = [SyncCollectedItem]()
        try pull.forEachPage(mode: mode) { items.append(contentsOf: $0.items) }
        return items
    }

    private func staged(_ files: FileStore) throws -> [StoredFile] {
        try files.listFiles().filter { $0.relativePath.hasPrefix("sync/pull-") }
    }

    private func mutateScope(_ object: inout [String: Any], _ index: Int, _ mutate: (inout [String: Any]) -> Void) {
        var scopes = object["scopes"] as! [[String: Any]]
        mutate(&scopes[index])
        object["scopes"] = scopes
    }

    private func assertError(_ expected: SyncPullCollectorError, _ body: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected collector failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? SyncPullCollectorError, expected, file: file, line: line) }
    }
}

private final class PullScriptTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [HTTPResponse]
    private var recorded = [HTTPRequest]()
    var onSend: ((Int, HTTPRequest) throws -> Void)?
    var delay: Duration?
    var requests: [SyncAPI.PullRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.map { try! JSONDecoder().decode(SyncAPI.PullRequest.self, from: $0.body!) }
    }

    init(_ responses: [HTTPResponse]) { self.responses = responses }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let index = record(request)
        try onSend?(index, request)
        if let delay { try await Task.sleep(for: delay) }
        guard index < responses.count else { throw HTTPTransportError.networkFailure }
        return responses[index]
    }

    private func record(_ request: HTTPRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let index = recorded.count
        recorded.append(request)
        return index
    }
}

private final class PullTestClock {
    private(set) var now = ContinuousClock.now
    func advance(_ duration: Duration) { now = now.advanced(by: duration) }
}
