import Foundation
import MonkeysPawCore
import XCTest

final class DeliveryClipboardFakeTests: XCTestCase {
    func testDeferredSnapshotHookCanCompleteRegisteredRead() {
        let clipboard = FakeClipboard(DeliveryRecorder())
        clipboard.replaceText("previous")
        clipboard.snapshotMode = .deferred
        clipboard.onSnapshot = { clipboard.completeSnapshot() }
        defer { clipboard.onSnapshot = nil }
        var snapshots: [ClipboardTextSnapshot?] = []
        let read = clipboard.snapshotText(budget: Limits.clipboardSnapshotBudget,
            byteLimit: Limits.clipboardSnapshotMaxBytes) { snapshots.append($0) }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first.flatMap { $0?.withText { $0 } }, "previous")
        read.cancel()
    }

    func testCancelIsIdempotentAndLateCallbacksContainNoText() {
        let clipboard = FakeClipboard(DeliveryRecorder())
        clipboard.replaceText("previous")
        clipboard.snapshotMode = .deferred
        var values: [String?] = []
        let read = clipboard.snapshotText(budget: Limits.clipboardSnapshotBudget,
            byteLimit: Limits.clipboardSnapshotMaxBytes) { values.append($0?.withText { $0 }) }
        read.cancel()
        read.cancel()
        XCTAssertEqual(clipboard.snapshotCancellations, 1)
        XCTAssertNil(clipboard.lastSnapshot)
        clipboard.completeSnapshot(repeating: 2)
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.allSatisfy { $0 == nil })
    }

    func testDiagnosticsCanBeReadWhileOwningThreadCapturesAndRestores() throws {
        let clipboard = FakeClipboard(DeliveryRecorder())
        clipboard.replaceText("previous")
        let observer = DispatchGroup()
        observer.enter()
        DispatchQueue.global().async {
            defer { observer.leave() }
            for _ in 0..<2_000 {
                _ = clipboard.snapshotBudgets
                _ = clipboard.snapshotByteLimits
                _ = clipboard.snapshotCancellations
                _ = clipboard.ownershipWrites
                _ = clipboard.restoreCalls
                _ = clipboard.restorationWrites
            }
        }
        defer { observer.wait() }
        for _ in 0..<200 {
            var captured: ClipboardTextSnapshot?
            let read = clipboard.snapshotText(budget: Limits.clipboardSnapshotBudget,
                byteLimit: Limits.clipboardSnapshotMaxBytes) { captured = $0 }
            let snapshot = try XCTUnwrap(captured)
            let ownership = try XCTUnwrap(clipboard.writeTextOwning("delivery", after: snapshot.revision))
            clipboard.restore(snapshot, ifOwnedBy: ownership)
            read.cancel()
        }
        XCTAssertEqual(clipboard.snapshotBudgets.count, 200)
        XCTAssertEqual(clipboard.snapshotByteLimits.count, 200)
        XCTAssertEqual(clipboard.snapshotCancellations, 200)
        XCTAssertEqual(clipboard.ownershipWrites, 200)
        XCTAssertEqual(clipboard.restoreCalls, 200)
        XCTAssertEqual(clipboard.restorationWrites, 200)
        XCTAssertEqual(clipboard.text, "previous")
    }
}
