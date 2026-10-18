import Foundation
import MonkeysPawCore
import XCTest

final class BackgroundWorkTests: XCTestCase {
    func testDrainWaitsForEarlierWorkAndItsBarrier() async {
        let queued = expectation(description: "Work and barrier submitted")
        queued.expectedFulfillmentCount = 2
        let work = DrainTestWork { queued.fulfill() }
        let earlier = expectation(description: "Earlier work ran")
        let drained = expectation(description: "Barrier ran")
        work.run { earlier.fulfill() }
        Task.detached {
            do { try await work.drainSubmittedWork() }
            catch { XCTFail("A running barrier must not be cancelled") }
            XCTAssertEqual(work.count, 0)
            drained.fulfill()
        }
        await fulfillment(of: [queued], timeout: 5)
        work.takeNext()?()
        await fulfillment(of: [earlier], timeout: 5)
        XCTAssertEqual(work.count, 1)
        // Retaining an executed closure must not defer completion until release.
        let barrier = work.takeNext()
        barrier?()
        await fulfillment(of: [drained], timeout: 5)
        withExtendedLifetime(barrier) {}
    }

    func testRejectedSubmissionResumesWithCancellation() async {
        let done = expectation(description: "Rejected barrier cancelled")
        Task.detached {
            do {
                try await RejectingDrainTestWork().drainSubmittedWork()
                XCTFail("Discarded work cannot prove the queue drained")
            } catch { XCTAssertTrue(error is CancellationError) }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
    }

    func testDiscardedQueuedBarrierCancelsWithoutRunningEarlierWork() async {
        let queued = expectation(description: "Work and barrier submitted")
        queued.expectedFulfillmentCount = 2
        let work = DrainTestWork { queued.fulfill() }
        let done = expectation(description: "Discarded barrier cancelled")
        work.run { XCTFail("Earlier work is still held") }
        Task.detached {
            do {
                try await work.drainSubmittedWork()
                XCTFail("Discarded work cannot prove the queue drained")
            } catch { XCTAssertTrue(error is CancellationError) }
            done.fulfill()
        }
        await fulfillment(of: [queued], timeout: 5)
        work.discardLast()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(work.count, 1)
    }
}

private struct RejectingDrainTestWork: BackgroundWork {
    func run(_ work: @escaping () -> Void) {}
}

private final class DrainTestWork: BackgroundWork {
    private let lock = NSLock()
    private var pending: [() -> Void] = []
    private let onEnqueue: () -> Void

    init(onEnqueue: @escaping () -> Void) { self.onEnqueue = onEnqueue }

    var count: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

    func run(_ work: @escaping () -> Void) {
        lock.lock()
        pending.append(work)
        lock.unlock()
        onEnqueue()
    }

    func takeNext() -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    func discardLast() {
        lock.lock()
        pending.removeLast()
        lock.unlock()
    }
}
