import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncCoordinatorTests: XCTestCase {
    func testCancelledStagingSweepDoesNotBecomeARecoveryFailure() async throws {
        let rig = try SyncServiceRig()
        let path = "sync/pull-a6025558-8a7b-4fe7-a7e1-69555d7a1304-0.json"
        try rig.base.data.put("stale", at: path)
        rig.base.data.onDelete = { _ in throw CancellationError() }
        defer { rig.base.data.onDelete = nil; rig.service.stop() }

        try rig.start()
        await rig.settle()
        XCTAssertNil(rig.service.report.blockingIssue)
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertFalse(rig.service.report.retrying)
        XCTAssertTrue(rig.transport.requests.isEmpty)
        XCTAssertNotNil(try rig.base.data.stamp(at: path))

        do {
            try await rig.service.recoverJournal()
            XCTFail("Expected sweep cancellation")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertNil(rig.service.report.blockingIssue)
        XCTAssertTrue(rig.transport.requests.isEmpty)

        rig.base.data.onDelete = nil
        try await rig.service.recoverJournal()
        XCTAssertNil(try rig.base.data.stamp(at: path))
        XCTAssertTrue(rig.transport.requests.isEmpty)
    }

    func testUnchangedOrphanPreparationDoesNotPublishJournals() async throws {
        let rig = try SyncServiceRig()
        let bytes = try CanonicalForm.group(SyncScanTestSupport.bytes(id: SyncTestValues.groupPrompt), filename: "a.md").bytes
        try rig.base.files.write(bytes, at: "Groups/Team/a.md")
        try SyncScanTestSupport.installState(rig.base, groups: SyncScanTestSupport.groups(),
            prompts: [.assigned(SyncTestValues.groupPrompt): SyncScanTestSupport.record(bytes, scope: SyncScanTestSupport.team)])
        let group = SyncAPI.SyncScope(identity: .group(groupID: SyncTestValues.group.rawValue, name: "Team", role: .editor),
            mode: .snapshot, head: 1, cursor: "group-cursor", hasMore: false,
            items: [.upsert(seq: 1, prompt: .init(id: SyncTestValues.groupPrompt.rawValue, rev: 1, path: "a.md",
                content: String(decoding: bytes, as: UTF8.self)))])
        rig.transport.handler = { _, request in
            XCTAssertEqual(request.method, .post)
            return try SyncServiceRig.pull(groups: [group])
        }
        let server = try SyncServerURL(rig.base.binding.account.serverURL.absoluteString)
        let client = SyncHTTPClient(server: server, transport: rig.transport,
            credential: .init(server: server, token: SecretValue(String(repeating: "a", count: 42) + "A")))
        let coordinator = try SyncCoordinator(binding: rig.base.binding, epoch: 1, client: client,
            files: rig.base.data, states: rig.base.states, accounts: rig.accounts, mutations: rig.base.mutations,
            journal: rig.journal, pending: rig.pending, device: "Desktop", freshID: { SyncTestValues.device },
            date: rig.clock.now, now: rig.clock.instant)
        var drifted = false
        var scans = 0
        var stateBytes: Data?
        var publications: [String] = []
        rig.base.data.onWrite = { if drifted { publications.append($0) } }
        defer { rig.base.data.onWrite = nil }
        do {
            _ = try await coordinator.run { phase in
                guard phase == .scanning else { return }
                scans += 1
                guard !drifted else { return }
                do {
                    try rig.base.libraryOperations.renameDirectory(from: "Groups/Team", to: "Groups/team")
                    stateBytes = try rig.base.data.read(at: "sync/state.json")
                    drifted = true
                } catch { XCTFail("Could not rename managed folder: \(error)") }
            }
            XCTFail("Expected bounded no progress")
        } catch SyncCoordinatorError.noProgress { }
        catch { XCTFail("Unexpected preparation failure: \(error)") }
        XCTAssertTrue(drifted)
        XCTAssertEqual(scans, Limits.syncPreparationLimit + 1)
        XCTAssertTrue(publications.isEmpty, "An unchanged plan published \(publications.count) journal/state records")
        XCTAssertEqual(try rig.base.data.read(at: "sync/state.json"), try XCTUnwrap(stateBytes))
        XCTAssertEqual(try rig.base.files.read(at: "Groups/team/a.md"), bytes)
        XCTAssertNil(rig.journal.pending)
        XCTAssertEqual(rig.transport.requests.map(\.method), [.post])
    }

    func testExplicitRecoveryReflushesUncertainPushPublicationOnSameGraph() async throws {
        let rig = try SyncServiceRig()
        let bytes = SyncScanTestSupport.bytes()
        try rig.base.files.write(bytes, at: "a.md")
        let operations = rig.base.dataOperations
        operations.onOperation = { operation in
            if operation == "file:sync/push.json" { operations.failFlushNumber = operations.flushCount + 1 }
        }
        defer { operations.onOperation = nil }
        try rig.start()
        await rig.settle()
        let exact = try rig.base.data.read(at: "sync/push.json")
        XCTAssertEqual(rig.pending.snapshot.error, .durabilityUncertain)
        XCTAssertEqual(rig.transport.requests.map(\.method), [.post])
        XCTAssertNil(rig.service.report.lastSuccess)

        do {
            try await rig.service.recoverJournal()
            XCTFail("Expected failed reflush")
        } catch { XCTAssertEqual(error as? SyncError, .durabilityUncertain) }
        XCTAssertEqual(rig.transport.requests.count, 1)

        operations.failFlushNumber = nil
        var reflush: [String] = []
        operations.onOperation = { reflush.append($0) }
        rig.transport.handler = { _, request in
            XCTAssertEqual(request.method, .get)
            XCTAssertEqual(try rig.base.data.read(at: "sync/push.json"), exact)
            XCTAssertEqual(reflush, ["file:sync/push.json", "directory:sync", "directory:/"])
            return try SyncServiceRig.failure(.notFound)
        }
        try await rig.service.recoverJournal()
        XCTAssertEqual(rig.transport.requests.map(\.method), [.post, .get])
        XCTAssertNil(try rig.pending.load(for: rig.base.binding))
        XCTAssertEqual(try rig.base.files.read(at: "a.md"), bytes)
        XCTAssertNil(rig.service.report.blockingIssue)
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertEqual(rig.service.stop(), .stopped)
    }

    func testExplicitRecoveryReflushesUncertainPushDeletionOnSameGraph() async throws {
        let rig = try SyncServiceRig()
        try rig.base.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        let operations = rig.base.dataOperations
        rig.base.data.onDelete = { path in
            if path == "sync/push.json" {
                operations.onOperation = { operation in
                    if operation == "directory:sync" { operations.failFlushNumber = operations.flushCount + 1 }
                }
            }
        }
        defer { rig.base.data.onDelete = nil; operations.onOperation = nil }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.pending.snapshot.error, .durabilityUncertain)
        XCTAssertNil(try rig.base.data.stamp(at: "sync/push.json"))
        XCTAssertEqual(rig.base.states.snapshot.value?.prompts[.assigned(SyncTestValues.personalPrompt)]?.rev, 1)
        XCTAssertEqual(rig.transport.requests.map(\.method), [.post, .put])
        XCTAssertNil(rig.service.report.lastSuccess)

        do {
            try await rig.service.recoverJournal()
            XCTFail("Expected failed deletion reflush")
        } catch { XCTAssertEqual(error as? SyncError, .durabilityUncertain) }
        XCTAssertEqual(rig.transport.requests.count, 2)

        rig.base.data.onDelete = nil
        operations.failFlushNumber = nil
        var reflush: [String] = []
        operations.onOperation = { reflush.append($0) }
        try await rig.service.recoverJournal()
        XCTAssertEqual(reflush, ["directory:sync", "directory:/"])
        XCTAssertEqual(rig.transport.requests.count, 2)
        XCTAssertNil(try rig.pending.load(for: rig.base.binding))
        XCTAssertNil(rig.service.report.blockingIssue)
        XCTAssertEqual(rig.service.stop(), .stopped)
    }

    func testExplicitRecoveryValidatesUncertainPushBindingBeforeReflush() async throws {
        for field in ["root", "account"] {
            let rig = try SyncServiceRig()
            try rig.base.files.write(SyncScanTestSupport.bytes(), at: "a.md")
            let operations = rig.base.dataOperations
            operations.onOperation = { operation in
                if operation == "file:sync/push.json" { operations.failFlushNumber = operations.flushCount + 1 }
            }
            defer { operations.onOperation = nil }
            try rig.start()
            await rig.settle()
            let exact = try rig.base.data.read(at: "sync/push.json")
            var rebound = try XCTUnwrap(JSONSerialization.jsonObject(with: exact) as? [String: Any])
            if field == "root" { rebound["root"] = "/another" }
            else {
                var account = try XCTUnwrap(rebound["account"] as? [String: Any])
                account["server_url"] = "https://another.example.test"
                rebound["account"] = account
            }
            let changed = try JSONSerialization.data(withJSONObject: rebound)
            _ = try JSONDecoder().decode(SyncPendingOperation.self, from: changed)
            try rig.base.data.writePrivate(changed, at: "sync/push.json")
            operations.failFlushNumber = nil
            var reflush: [String] = []
            operations.onOperation = { reflush.append($0) }
            do {
                try await rig.service.recoverJournal()
                XCTFail("Expected binding mismatch", file: #filePath, line: #line)
            } catch { XCTAssertEqual(error as? SyncError, .bindingMismatch, field) }
            XCTAssertEqual(rig.pending.snapshot.error, .durabilityUncertain)
            XCTAssertTrue(reflush.isEmpty)
            XCTAssertEqual(rig.transport.requests.count, 1)

            try rig.base.data.writePrivate(exact, at: "sync/push.json")
            rig.transport.handler = { _, request in
                XCTAssertEqual(request.method, .get)
                return try SyncServiceRig.failure(.notFound)
            }
            try await rig.service.recoverJournal()
            XCTAssertNil(try rig.pending.load(for: rig.base.binding))
            XCTAssertEqual(rig.service.stop(), .stopped)
        }
    }

    func testPullCleanupFailureBlocksSuccessAndRecoveryRetriesOnSameGraph() async throws {
        let rig = try SyncServiceRig()
        let bytes = SyncScanTestSupport.bytes("Downloaded head")
        rig.transport.handler = { _, request in
            XCTAssertEqual(request.method, .post)
            return try SyncServiceRig.pull(items: [.upsert(seq: 1,
                prompt: .init(id: SyncTestValues.personalPrompt.rawValue, rev: 1, path: "a.md",
                    content: String(decoding: bytes, as: UTF8.self)))])
        }
        var deletions = 0
        rig.base.data.onDelete = { path in
            if path.hasPrefix("sync/pull-") { deletions += 1; throw FileStoreError.ioFailure }
        }
        defer { rig.base.data.onDelete = nil }
        try rig.start()
        await rig.settle()
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertEqual(rig.service.report.counts.pulled, 1)
        XCTAssertEqual(try rig.base.files.read(at: "a.md"), bytes)
        XCTAssertEqual(rig.base.states.snapshot.value?.cursors[SyncScanTestSupport.personal], "cursor")
        XCTAssertGreaterThanOrEqual(deletions, 3, "Immediate, deferred and deinit cleanup all failed")
        let pages = try staged(rig)
        XCTAssertFalse(pages.isEmpty)
        XCTAssertEqual(rig.service.report.blockingIssue, .recoveryRequired)

        do {
            try await rig.service.recoverJournal()
            XCTFail("Expected persistent cleanup failure")
        } catch { XCTAssertEqual(error as? SyncPullCollectorError, .stagingFailed(.ioFailure)) }
        XCTAssertEqual(rig.transport.requests.count, 1)
        XCTAssertEqual(try staged(rig), pages)

        let collectionID = "a6025558-8a7b-4fe7-a7e1-69555d7a1304"
        let unrelated = [
            "sync/retained/canary.json",
            "sync/pull-other.json",
            "sync/pull-backup/pull-\(collectionID)-0.json",
            "sync/pull-\(collectionID)-x.json",
            "sync/pull-\(collectionID.uppercased())-0.json",
            "sync/pull-\(collectionID)--1.json",
            "sync/pull-\(collectionID)-0.json.bak"
        ]
        for path in unrelated { try rig.base.data.put("canary", at: path) }
        rig.base.data.onDelete = nil
        try await rig.service.recoverJournal()
        for page in pages { XCTAssertNil(try rig.base.data.stamp(at: page.relativePath)) }
        for path in unrelated { XCTAssertEqual(try rig.base.data.text(at: path), "canary", path) }
        XCTAssertEqual(rig.transport.requests.count, 1)
        XCTAssertNil(rig.service.report.blockingIssue)
        XCTAssertEqual(rig.service.stop(), .stopped)
    }

    func testLaterPassSweepsFailedCollectionCleanupBeforeCollectingMorePages() async throws {
        for storageRecovered in [true, false] {
            let rig = try SyncServiceRig()
            rig.base.data.onDelete = { path in
                if path.hasPrefix("sync/pull-") { throw FileStoreError.ioFailure }
            }
            defer { rig.base.data.onDelete = nil }
            rig.transport.handler = { index, _ in
                if index == 0 { return try SyncServiceRig.pull(more: true, cursor: "next-page") }
                throw HTTPTransportError.networkFailure
            }
            try rig.start()
            await rig.settle()
            XCTAssertEqual(rig.service.report.status, .offline)
            let pages = try staged(rig)
            XCTAssertFalse(pages.isEmpty)
            XCTAssertEqual(rig.transport.requests.count, 2)
            if storageRecovered { rig.base.data.onDelete = nil }
            rig.transport.handler = { _, request in
                XCTAssertEqual(request.method, .post)
                XCTAssertTrue(try self.staged(rig).isEmpty, "Sweep old pages before collecting again")
                return try SyncServiceRig.pull()
            }
            rig.service.syncNow()
            await rig.settle()
            if storageRecovered {
                XCTAssertEqual(rig.transport.requests.count, 3)
                XCTAssertNotNil(rig.service.report.lastSuccess)
                XCTAssertTrue(try staged(rig).isEmpty)
            } else {
                XCTAssertEqual(rig.transport.requests.count, 2)
                XCTAssertNil(rig.service.report.lastSuccess)
                XCTAssertEqual(rig.service.report.blockingIssue, .recoveryRequired)
                XCTAssertEqual(try staged(rig), pages)
            }
        }
    }

    private func staged(_ rig: SyncServiceRig) throws -> [StoredFile] {
        try rig.base.data.listFiles().filter { $0.relativePath.hasPrefix("sync/pull-") }
    }
}
