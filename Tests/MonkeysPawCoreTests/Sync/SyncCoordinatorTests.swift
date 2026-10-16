import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncCoordinatorTests: XCTestCase {
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

        try rig.base.data.put("canary", at: "sync/retained/canary.json")
        rig.base.data.onDelete = nil
        try await rig.service.recoverJournal()
        XCTAssertTrue(try staged(rig).isEmpty)
        XCTAssertEqual(try rig.base.data.text(at: "sync/retained/canary.json"), "canary")
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
