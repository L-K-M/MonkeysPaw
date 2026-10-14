import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncSchedulingTests: XCTestCase {
    func testSchedulerDrainsDueTimersInDeadlineOrderAndOnlyOnce() {
        let scheduler = SyncTestScheduler(clock: SyncTestClock())
        var fired: [String] = []
        scheduler.after(.seconds(2)) { fired.append("later") }
        scheduler.after(.seconds(1)) {
            fired.append("earlier")
            scheduler.after(.zero) { fired.append("chained") }
            scheduler.after(.seconds(1)) { fired.append("future") }
        }
        scheduler.advance(.seconds(3))
        XCTAssertEqual(fired, ["earlier", "later", "chained"])
        scheduler.advance(.zero)
        XCTAssertEqual(fired, ["earlier", "later", "chained"])
        scheduler.advance(.seconds(1))
        XCTAssertEqual(fired, ["earlier", "later", "chained", "future"])
        scheduler.advance(.seconds(10))
        XCTAssertEqual(fired, ["earlier", "later", "chained", "future"])
    }

    func testOverlappingTriggersCoalesceIntoOneSerialRerun() async throws {
        let rig = try SyncServiceRig()
        let gate = SyncTransportGate()
        rig.transport.handler = { index, _ in
            if index == 0 { await gate.wait() }
            return try SyncServiceRig.pull()
        }
        try rig.start()
        await rig.waitRequests(1)
        for _ in 0..<10 { rig.service.syncNow() }
        XCTAssertEqual(rig.transport.requests.count, 1)
        await gate.open()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
        XCTAssertEqual(rig.service.report.status, .idle)
    }

    func testPollingFiresAtSixtySecondsAndRepeats() async throws {
        let rig = try SyncServiceRig()
        try rig.start()
        await rig.settle()
        rig.scheduler.advance(.seconds(59))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 1)
        rig.scheduler.advance(.seconds(1))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
        rig.scheduler.advance(.seconds(60))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 3)
    }

    func testSaveDebounceUsesLastSaveAndInvalidatesUncancelableTimers() async throws {
        let rig = try SyncServiceRig()
        try rig.start()
        await rig.settle()
        rig.service.localSave()
        rig.scheduler.advance(.seconds(2))
        rig.service.localSave()
        rig.scheduler.advance(.seconds(1))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 1)
        rig.scheduler.advance(.seconds(1))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 1)
        rig.scheduler.advance(.seconds(1))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
    }

    func testExponentialBackoffBoundariesAndPollsCannotBypassIt() async throws {
        let rig = try SyncServiceRig()
        rig.transport.handler = { _, _ in throw HTTPTransportError.networkFailure }
        try rig.start()
        await rig.settle()
        for delay: Int64 in [5, 10, 20, 40, 80, 160, 320, 600, 600] {
            let count = rig.transport.requests.count
            XCTAssertEqual(rig.scheduler.timers.last?.delay, .seconds(delay))
            rig.scheduler.advance(.seconds(delay - 1))
            await rig.settle()
            XCTAssertEqual(rig.transport.requests.count, count)
            rig.scheduler.advance(.seconds(1))
            await rig.settle()
            XCTAssertEqual(rig.transport.requests.count, count + 1)
            XCTAssertEqual(rig.service.report.status, .offline)
            XCTAssertNil(rig.service.report.lastSuccess)
        }
    }

    func testExplicitSyncBypassesTransientBackoffAndSuccessResetsIt() async throws {
        let rig = try SyncServiceRig()
        rig.transport.handler = { _, _ in throw HTTPTransportError.networkFailure }
        try rig.start()
        await rig.settle()
        rig.transport.handler = { _, _ in try SyncServiceRig.pull() }
        rig.service.syncNow()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
        XCTAssertEqual(rig.service.report.status, .idle)
        XCTAssertNotNil(rig.service.report.lastSuccess)
        rig.scheduler.advance(.seconds(5))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2, "The invalidated retry must not fire")
        rig.transport.handler = { _, _ in throw HTTPTransportError.networkFailure }
        rig.service.syncNow()
        await rig.settle()
        XCTAssertEqual(rig.scheduler.timers.last?.delay, .seconds(5))
    }

    func test401StopsEveryTriggerUntilReauthentication() async throws {
        let rig = try SyncServiceRig()
        rig.transport.handler = { _, _ in try SyncServiceRig.failure(.unauthorized) }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.service.report.status, .needsSignIn)
        rig.service.syncNow()
        rig.service.localSave()
        rig.scheduler.advance(.seconds(600))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 1)
        XCTAssertNil(rig.service.report.lastSuccess)
        rig.transport.handler = { _, _ in try SyncServiceRig.pull() }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
        XCTAssertEqual(rig.service.report.status, .idle)
    }

    func testUnchangedFileErrorDoesNotLoopAndRepairsRetry() async throws {
        let rig = try SyncServiceRig()
        try rig.base.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        rig.transport.handler = { _, request in
            if request.method == .post { return try SyncServiceRig.pull() }
            if request.method == .get { return try SyncServiceRig.failure(.notFound) }
            return try SyncServiceRig.failure(.notFound)
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.service.report.status, .syncError)
        XCTAssertEqual(rig.service.report.counts.fileErrors, 1)
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertEqual(rig.transport.requests.filter { $0.method == .put }.count, 1)
        rig.scheduler.advance(.seconds(3))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
        rig.service.syncNow()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.filter { $0.method == .put }.count, 1)
        try rig.base.files.write(SyncScanTestSupport.bytes("Repair"), at: "a.md")
        rig.transport.handler = { _, request in
            if request.method == .post { return try SyncServiceRig.pull() }
            return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: 1, seq: 1))
        }
        rig.service.localSave()
        rig.scheduler.advance(.seconds(3))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.filter { $0.method == .put }.count, 2)
        XCTAssertEqual(rig.service.report.status, .idle)
        XCTAssertNotNil(rig.service.report.lastSuccess)
    }

    func testOldEpochTimersCannotStartWorkAfterReauthentication() async throws {
        let rig = try SyncServiceRig()
        try rig.start()
        await rig.settle()
        rig.service.localSave()
        let oldTimers = rig.scheduler.timers
        XCTAssertEqual(rig.service.stop(), .stopped)
        try rig.start()
        await rig.settle()
        for timer in oldTimers { rig.scheduler.fire(timer.id) }
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
    }

    func testCollectionSharesFiveMinuteBudgetAcrossImmediateRestart() async throws {
        let rig = try SyncServiceRig()
        rig.transport.handler = { index, _ in
            if index == 0 {
                rig.clock.advance(.seconds(150))
                return try SyncServiceRig.pull(more: true, cursor: "page-one")
            }
            if index == 1 {
                rig.clock.advance(.seconds(100))
                let other = UUID(uuidString: "1a2b3c4d-0000-4000-8000-000000000002")!
                return try SyncServiceRig.pull(database: other)
            }
            rig.clock.advance(.seconds(50))
            return try SyncServiceRig.pull()
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 3)
        let request = try XCTUnwrap(rig.transport.requests.dropFirst(2).first)
        let restart = try JSONDecoder().decode(SyncAPI.PullRequest.self, from: XCTUnwrap(request.body))
        XCTAssertNil(restart.databaseID)
        XCTAssertTrue(restart.cursors.isEmpty)
        XCTAssertNil(rig.base.states.snapshot.value)
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertEqual(rig.scheduler.timers.last?.delay, .seconds(5))
    }

    func testOnlyOneCollectionRestartAndNoPartialAcknowledgement() async throws {
        let rig = try SyncServiceRig()
        rig.transport.handler = { index, _ in
            let database = index < 1 || index == 2 ? SyncTestValues.uuid
                : UUID(uuidString: "1a2b3c4d-0000-4000-8000-000000000002")!
            return try SyncServiceRig.pull(more: true, cursor: "page-\(index)", database: database)
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 4)
        XCTAssertNil(rig.base.states.snapshot.value)
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertEqual(rig.base.files.writeCount, 0)
        XCTAssertEqual(rig.scheduler.timers.last?.delay, .seconds(5))
    }

    func testUnchangedErrorsSurviveSameAccountReauthentication() async throws {
        let rig = try SyncServiceRig()
        try rig.base.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        rig.transport.handler = { _, request in
            request.method == .post ? try SyncServiceRig.pull() : try SyncServiceRig.failure(.notFound)
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.filter { $0.method == .put }.count, 1)
        XCTAssertEqual(rig.service.stop(), .stopped)
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.filter { $0.method == .put }.count, 1)
        XCTAssertEqual(rig.service.report.status, .syncError)
    }

    func testRepeatedReplansBackOffInsteadOfLooping() async throws {
        let rig = try SyncServiceRig()
        try rig.base.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        rig.transport.handler = { index, request in
            if request.method == .post { return try SyncServiceRig.pull(mode: index == 0 ? .snapshot : .delta) }
            // Every in-flight edit leaves another saved version to sync.
            try rig.base.files.write(SyncScanTestSupport.bytes("Edit \(index)"), at: "a.md")
            return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: Int64(index + 1), seq: Int64(index + 1)))
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.filter { $0.method == .put }.count, 2)
        XCTAssertEqual(rig.scheduler.timers.last?.delay, .seconds(5))
        XCTAssertEqual(rig.service.report.status, .syncError)
        XCTAssertEqual(rig.service.report.counts.pending, 1)
        XCTAssertNil(rig.service.report.lastSuccess)
    }

    func testDirtyTriggerRerunsEvenWithUnchangedFileErrors() async throws {
        let rig = try SyncServiceRig()
        try rig.base.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        let gate = SyncTransportGate()
        rig.transport.handler = { index, request in
            if index == 0 { await gate.wait() }
            if request.method == .post { return try SyncServiceRig.pull() }
            return try SyncServiceRig.failure(.notFound)
        }
        try rig.start()
        await rig.waitRequests(1)
        rig.service.localSave()
        rig.scheduler.advance(.seconds(3))
        await gate.open()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.filter { $0.method == .post }.count, 2)
        XCTAssertEqual(rig.transport.requests.filter { $0.method == .put }.count, 1)
        XCTAssertEqual(rig.service.report.status, .syncError)
    }
}
