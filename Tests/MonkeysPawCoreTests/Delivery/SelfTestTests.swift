import Foundation
import MonkeysPawCore
import XCTest

final class SelfTestTests: XCTestCase {
    private func runner(_ h: DeliveryHarness) -> SelfTest {
        SelfTest(target: h.target, delivery: h.service, session: h.session,
                 scheduler: h.scheduler, mainThread: h.main)
    }

    func testTestsEachBackendInLadderOrderAndRequiresExactReadback() {
        let h = DeliveryHarness(session: .gnomeWayland)
        h.target.received = [DeliveryStrings.testPrompt, ""]
        let test = runner(h)
        var report: SelfTestReport?
        test.run { report = $0; XCTAssertTrue(h.main.isRunning) }
        XCTAssertNil(report)
        h.scheduler.advance(by: Limits.settleDelayLinux + Limits.selfTestReadBackDelay)
        XCTAssertNil(report)
        h.scheduler.advance(by: Limits.settleDelayLinux + Limits.selfTestReadBackDelay)
        XCTAssertEqual(report, SelfTestReport(session: .gnomeWayland, results: [
            SelfTestResult(backend: .remoteDesktopPortal, status: .pasted),
            SelfTestResult(backend: .ydotool, status: .sentButNotReceived),
        ]))
        XCTAssertEqual(h.injectors[.remoteDesktopPortal]?.chords, [.standard])
        XCTAssertEqual(h.injectors[.ydotool]?.chords, [.standard])
        XCTAssertEqual(h.cache.failure(for: .ydotool), .notReceived)
        XCTAssertEqual(h.recorder.events.filter { if case .testClose = $0 { return true }; return false }.count, 2)
    }

    func testReadbackWaits500MillisecondsAfterInjectionCompletion() throws {
        let h = DeliveryHarness(session: .wlroots)
        h.injectors[.ydotool]?.mode = .deferred
        h.target.received = [DeliveryStrings.testPrompt]
        let test = runner(h)
        var report: SelfTestReport?
        test.run { report = $0 }
        h.settle()
        h.scheduler.advance(by: .seconds(1))
        XCTAssertFalse(h.recorder.events.contains(.testReadBack))
        h.injectors[.ydotool]?.complete(.sent)
        h.scheduler.advance(by: .milliseconds(499))
        XCTAssertNil(report)
        XCTAssertFalse(h.recorder.events.contains(.testReadBack))
        h.scheduler.advance(by: .milliseconds(1))
        XCTAssertEqual(report?.results, [SelfTestResult(backend: .ydotool, status: .pasted)])

        XCTAssertEqual(h.recorder.events, [
            .testPresent(DeliveryStrings.testPrompt), .capture, .write(DeliveryStrings.testPrompt),
            .hideForDelivery, .wait(Limits.settleDelayLinux), .restore(try XCTUnwrap(h.focus.target)),
            .paste(.ydotool, .standard), .wait(.milliseconds(500)), .testReadBack, .testClose,
        ])
    }

    func testFailedBackendIsReportedWithoutLadderFallthrough() {
        let h = DeliveryHarness()
        h.injectors[.cgEvent]?.result = .failed(.permissionDenied)
        h.target.received = [nil, DeliveryStrings.testPrompt]
        let test = runner(h)
        var report: SelfTestReport?
        test.run { report = $0 }
        h.scheduler.advance(by: .milliseconds(600))
        XCTAssertEqual(h.injectors[.appleScript]?.chords, [])
        h.scheduler.advance(by: .milliseconds(600))
        XCTAssertEqual(report?.results, [
            SelfTestResult(backend: .cgEvent, status: .failed(.permissionDenied)),
            SelfTestResult(backend: .appleScript, status: .pasted),
        ])
    }

    func testMissingOrDifferentReadbackIsNotReportedAsPasted() {
        for received: String? in [nil, "wrong text", DeliveryStrings.testPrompt + "extra"] {
            let h = DeliveryHarness(session: .flatpak(host: .gnomeWayland))
            h.target.received = [received]
            let test = runner(h)
            var report: SelfTestReport?
            test.run { report = $0 }
            h.scheduler.advance(by: .milliseconds(640))
            XCTAssertEqual(report?.results, [
                SelfTestResult(backend: .remoteDesktopPortal, status: .sentButNotReceived),
            ])
        }
    }

    func testSelfTestResetsCachedFailuresAndPreservesTheArmedPickerTarget() throws {
        let h = DeliveryHarness(session: .wlroots)
        let pickerTarget = try XCTUnwrap(h.focus.target)
        h.arm()
        h.focus.target = .linux(session: .wlroots, x11WindowClass: nil)
        h.cache.record(.timeout, for: .ydotool)
        h.target.received = [DeliveryStrings.testPrompt]
        let test = runner(h)
        test.run { _ in }
        h.scheduler.advance(by: .milliseconds(640))
        XCTAssertEqual(h.cache.resets, 1)
        XCTAssertNil(h.cache.failure(for: .ydotool))

        h.recorder.events.removeAll()
        h.deliver()
        h.settle()
        XCTAssertTrue(h.recorder.events.contains(.restore(pickerTarget)))
    }

    func testConcurrentRunsShareOneReportAndOneTestWindow() {
        let h = DeliveryHarness(session: .wlroots)
        h.target.received = [DeliveryStrings.testPrompt]
        let test = runner(h)
        var reports: [SelfTestReport] = []
        test.run { reports.append($0) }
        test.run { reports.append($0) }
        h.scheduler.advance(by: .milliseconds(640))
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.first, reports.last)
        XCTAssertEqual(h.injectors[.ydotool]?.chords.count, 1)
    }

    func testReportRoundTripsAllStatusesAndFlatpakHostAsJSON() throws {
        let report = SelfTestReport(session: .flatpak(host: .kdeWayland), results: [
            SelfTestResult(backend: .remoteDesktopPortal, status: .pasted),
            SelfTestResult(backend: .ydotool, status: .sentButNotReceived),
            SelfTestResult(backend: .xdotool, status: .failed(.toolMissing)),
        ])
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(SelfTestReport.self, from: data), report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(DeliveryStrings.testPrompt))
    }
}
