import MonkeysPawCore
import XCTest

final class DeliveryStatusSnapshotTests: XCTestCase {
    func testReadStatusRunsOnMainThreadAndHasOnlyLadderFailuresAndSanitizedLastReceipt() {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let h = DeliveryHarness(session: .macOS)
            h.focus.target = .macOS(processID: 999, bundleID: "PRIVATE_TARGET_IDENTITY")
            h.injectors[.cgEvent]?.result = .failed(.permissionDenied)
            h.arm()
            h.deliver("PRIVATE_DELIVERED_CONTENT")
            h.settle()
            h.cache.record(.timeout, for: .xdotool)
            h.recorder.events.removeAll()
            h.main.mode = mode
            var snapshots: [DeliveryStatusSnapshot] = []
            h.service.readStatus {
                XCTAssertTrue(h.main.isRunning)
                snapshots.append($0)
            }
            if mode == .deferred { XCTAssertTrue(snapshots.isEmpty) }
            h.main.drain()
            XCTAssertEqual(snapshots.count, 1)
            XCTAssertEqual(snapshots[0].session, .macOS)
            XCTAssertEqual(snapshots[0].pasteLadder, [.cgEvent, .appleScript])
            XCTAssertEqual(snapshots[0].cachedFailures, [.init(backend: .cgEvent, reason: .permissionDenied)])
            XCTAssertEqual(snapshots[0].lastDelivery, DeliveryReceipt(outcome: .pasted(.appleScript), focus: .confirmed))
            XCTAssertFalse(String(describing: snapshots[0]).contains("PRIVATE_TARGET_IDENTITY"))
            XCTAssertFalse(String(describing: snapshots[0]).contains("PRIVATE_DELIVERED_CONTENT"))
            XCTAssertTrue(h.recorder.events.isEmpty)
            XCTAssertEqual(h.clipboard.readCount, 0)
            XCTAssertEqual(h.cache.resets, 0)
        }
    }
}
