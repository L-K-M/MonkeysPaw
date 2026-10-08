#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawLinux

final class GTKMainLoopTests: XCTestCase {
    private final class Lifetime {}

    func testIdleReleasesItsClosureAfterRunningOnce() {
        weak var lifetime: Lifetime?
        var callCount = 0
        do {
            let captured = Lifetime()
            lifetime = captured
            GTK.onMainLoop {
                withExtendedLifetime(captured) { callCount += 1 }
            }
        }

        XCTAssertNotNil(lifetime)
        XCTAssertNotEqual(g_main_context_iteration(nil, 0), 0)
        XCTAssertEqual(callCount, 1)
        XCTAssertNil(lifetime)

        _ = g_main_context_iteration(nil, 0)
        XCTAssertEqual(callCount, 1)
    }

    func testRemovingPendingIdleReleasesItsClosure() {
        weak var lifetime: Lifetime?
        var sourceID: guint = 0
        do {
            let captured = Lifetime()
            lifetime = captured
            sourceID = GTK.onMainLoop {
                withExtendedLifetime(captured) { XCTFail("A removed idle must not run.") }
            }
        }

        XCTAssertNotNil(lifetime)
        XCTAssertNotEqual(g_source_remove(sourceID), 0)
        XCTAssertNil(lifetime)
    }

    func testNegativeDelayRunsImmediately() {
        var callCount = 0
        GTK.after(-1) { callCount += 1 }

        XCTAssertEqual(callCount, 0)
        XCTAssertNotEqual(g_main_context_iteration(nil, 0), 0)
        XCTAssertEqual(callCount, 1)
    }

    func testOversizedDelayIsCappedAtTheGLibMaximum() throws {
        let before = g_get_monotonic_time()
        let sourceID = GTK.after(.greatestFiniteMagnitude) {
            XCTFail("A maximum-delay timer must not run immediately.")
        }
        defer { g_source_remove(sourceID) }

        let source = try XCTUnwrap(g_main_context_find_source_by_id(nil, sourceID))
        let maximumDelayMicroseconds = gint64(guint.max) * 1_000
        let readyTime = g_source_get_ready_time(source)
        XCTAssertGreaterThanOrEqual(readyTime, before + maximumDelayMicroseconds)
        XCTAssertLessThanOrEqual(readyTime, g_get_monotonic_time() + maximumDelayMicroseconds)
    }
}
#endif
