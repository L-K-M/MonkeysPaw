import Foundation
import XCTest
@testable import MonkeysPawCore

final class UpdateServiceTests: XCTestCase {
    func testConstructionRefreshAndUnversionedOrMalformedBuildsSendNothing() async {
        for version in [nil, "invalid", "1.2", "v1.0.0+build"] as [String?] {
            let h = UpdateHarness(version: version)
            h.service.startAutomaticChecks()
            h.service.checkNow()
            h.service.refreshAutomaticPolicy()
            let state = await h.status()
            XCTAssertEqual(state.result, .unavailable(version == nil ? .unversionedBuild : .invalidCurrentVersion))
            let requests = await h.transport.snapshot()
            XCTAssertTrue(requests.isEmpty)
            XCTAssertTrue(h.scheduler.delays.isEmpty)
            XCTAssertThrowsError(try h.files.read(at: "update-state.json"))
        }
        let h = UpdateHarness()
        h.service.refreshAutomaticPolicy()
        _ = await h.status()
        let requests = await h.transport.snapshot()
        XCTAssertTrue(requests.isEmpty, "Only explicit runtime startup enables monitoring")
    }

    func testAutomaticFailureRetainsDailyAttemptAcrossRestartAndAtBoundary() async throws {
        let h = UpdateHarness([.failure(.networkFailure)])
        let before = h.clock.now()
        h.service.startAutomaticChecks()
        let failed = await h.completed(in: self)
        XCTAssertEqual(failed.result, .unavailable(.offline))
        XCTAssertEqual(failed.lastAutomaticAttempt, before)
        XCTAssertNil(failed.lastSuccessfulCheck)
        XCTAssertEqual(h.scheduler.delays, [.seconds(86_400)])
        let restarted = UpdateHarness(files: h.files, settingsFiles: h.settingsFiles, clock: h.clock)
        restarted.service.startAutomaticChecks()
        _ = await restarted.status()
        h.clock.advance(86_399)
        restarted.scheduler.fireNext()
        _ = await restarted.status()
        let beforeDue = await restarted.transport.snapshot()
        XCTAssertTrue(beforeDue.isEmpty)
        h.clock.advance(1)
        restarted.scheduler.fireNext()
        let checked = await restarted.completed(in: self)
        XCTAssertEqual(checked.result, .updateAvailable(ReleaseVersion("2.0.0")!))
        XCTAssertEqual(checked.lastAutomaticAttempt, before.addingTimeInterval(86_400))
        XCTAssertEqual(checked.lastSuccessfulCheck, h.clock.now())
        let requests = await restarted.transport.snapshot()
        XCTAssertEqual(requests.count, 1)
    }

    func testAttemptIsPersistedBeforeHTTPReturnsAndRestartCannotRetryIt() async throws {
        let h = UpdateHarness([.held])
        h.service.startAutomaticChecks()
        await h.transport.waitUntilSent()
        let record = try UpdateStateStore(files: h.files).read(at: h.clock.now())
        XCTAssertEqual(record.lastAutomaticAttempt, h.clock.now())
        XCTAssertNil(record.lastSuccessfulCheck)
        let restarted = UpdateHarness(files: h.files, clock: h.clock)
        restarted.service.startAutomaticChecks()
        _ = await restarted.status()
        let requests = await restarted.transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
        await h.transport.release(updateResponse())
        _ = await h.completed(in: self)
    }

    func testManualWorksWhileOffAndDoesNotChangeThePreferenceOrAutomaticAttempt() async throws {
        let h = UpdateHarness()
        h.settings.setAutomaticUpdateChecks(.disabled)
        h.service.startAutomaticChecks()
        _ = await h.status()
        XCTAssertTrue(h.scheduler.delays.isEmpty)
        h.service.checkNow()
        let checked = await h.completed(in: self)
        XCTAssertEqual(checked.result, .updateAvailable(ReleaseVersion("2.0.0")!))
        XCTAssertNil(checked.lastAutomaticAttempt)
        XCTAssertEqual(checked.lastSuccessfulCheck, h.clock.now())
        XCTAssertEqual(h.settingsService.snapshot.document.automaticUpdateChecks, .disabled)
        XCTAssertTrue(h.scheduler.delays.isEmpty)
        XCTAssertTrue(h.opener.urls.isEmpty, "Availability never opens a page automatically")
        h.service.openReleasePage()
        _ = await h.status()
        XCTAssertEqual(h.opener.urls.map(\.absoluteString), ["https://github.com/L-K-M/MonkeysPaw/releases/tag/v2.0.0"])
    }

    func testManualBypassesDailyCadenceAndDuplicateRequestsAreIgnored() async {
        let h = UpdateHarness([.response(updateResponse()), .held])
        h.service.startAutomaticChecks()
        _ = await h.completed(in: self)
        h.service.checkNow()
        await h.transport.waitUntilSent(2)
        h.service.checkNow()
        h.service.startAutomaticChecks()
        h.service.refreshAutomaticPolicy()
        let inFlight = await h.status()
        XCTAssertTrue(inFlight.isChecking)
        let requests = await h.transport.snapshot()
        XCTAssertEqual(requests.count, 2)
        await h.transport.release(updateResponse(tag: "v1.0.0"))
        let result = await h.completed(in: self)
        XCTAssertEqual(result.result, .upToDate)
        XCTAssertFalse(result.canOpenRelease)
    }

    func testCorruptOrFutureStateBlocksAutomaticButManualReportsWithoutRewrite() async throws {
        for source in ["corrupt", #"{"version":2}"#, #"{"version":1,"lastAutomaticAttempt":1700000001}"#] {
            let files = MemoryFileStore()
            try files.put(source, at: "update-state.json")
            let h = UpdateHarness(files: files)
            h.service.startAutomaticChecks()
            let before = await h.status()
            XCTAssertNotNil(before.stateError)
            let automatic = await h.transport.snapshot()
            XCTAssertTrue(automatic.isEmpty)
            XCTAssertTrue(h.scheduler.delays.isEmpty)
            h.service.checkNow()
            let result = await h.completed(in: self)
            XCTAssertEqual(result.result, .updateAvailable(ReleaseVersion("2.0.0")!))
            XCTAssertNotNil(result.stateError)
            XCTAssertNil(result.lastSuccessfulCheck, "A successful manual response is not a durable result")
            XCTAssertEqual(try files.text(at: "update-state.json"), source)
        }
    }

    func testReadOnlySettingsNeverAuthorizeAutomaticTrafficButManualIsAllowed() async throws {
        for source in ["corrupt", #"{"version":99}"#] {
            let files = MemoryFileStore()
            try files.put(source, at: "settings.json")
            let h = UpdateHarness(settingsFiles: files)
            h.service.startAutomaticChecks()
            _ = await h.status()
            let automatic = await h.transport.snapshot()
            XCTAssertTrue(automatic.isEmpty)
            h.service.checkNow()
            let result = await h.completed(in: self)
            XCTAssertEqual(result.result, .updateAvailable(ReleaseVersion("2.0.0")!))
            XCTAssertEqual(try files.text(at: "settings.json"), source)
        }
    }

    func testFailedAttemptPersistencePreventsTraffic() async {
        let h = UpdateHarness()
        h.files.failNextWrite = true
        let done = UpdateExpectation(in: self, description: "Persistence failure")
        let token = h.service.addObserver { if $0.stateError == .writeFailed(.ioFailure) { done.fulfill() } }
        h.service.startAutomaticChecks()
        await fulfillment(of: [done.expectation], timeout: 5)
        h.service.removeObserver(token)
        XCTAssertEqual(done.callCount, 1)
        let requests = await h.transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testRateLimitsBlockManualAcrossRestartAndRemainDistinct() async {
        for code in [403, 429] {
            let response = HTTPResponse(statusCode: code, headers: ["Retry-After": "120"], body: Data("secret".utf8))
            let h = UpdateHarness([.response(response)])
            h.service.checkNow()
            let first = await h.completed(in: self)
            XCTAssertEqual(first.result, .unavailable(.rateLimited(UpdateRateLimit(statusCode: code,
                until: h.clock.now().addingTimeInterval(120)))))
            let restarted = UpdateHarness(files: h.files, clock: h.clock)
            restarted.service.checkNow()
            let limited = await restarted.status()
            XCTAssertEqual(limited.result, first.result)
            var requests = await restarted.transport.snapshot()
            XCTAssertTrue(requests.isEmpty)
            h.clock.advance(120)
            restarted.service.checkNow()
            _ = await restarted.completed(in: self)
            requests = await restarted.transport.snapshot()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testRateLimitDelayStartsWhenTheResponseArrives() async {
        let h = UpdateHarness([.held])
        h.service.checkNow()
        await h.transport.waitUntilSent()
        h.clock.advance(10)
        await h.transport.release(HTTPResponse(statusCode: 429, headers: ["Retry-After": "120"], body: Data()))
        let limited = await h.completed(in: self)
        XCTAssertEqual(limited.rateLimit?.until, h.clock.now().addingTimeInterval(120))
    }

    func testAttemptPersistenceFailureRemainsVisibleAcrossPassiveReads() async {
        let h = UpdateHarness()
        let failed = UpdateExpectation(in: self, description: "Attempt persistence failure")
        let token = h.service.addObserver { if $0.stateError == .writeFailed(.ioFailure) { failed.fulfill() } }
        h.files.failNextWrite = true
        h.service.startAutomaticChecks()
        await fulfillment(of: [failed.expectation], timeout: 5)
        h.service.removeObserver(token)
        XCTAssertEqual(failed.callCount, 1)
        let status = await h.status()
        XCTAssertEqual(status.stateError, .writeFailed(.ioFailure))
        let requests = await h.transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDisableCancelsAutomaticTaskAndRetiresTimers() async {
        let h = UpdateHarness([.waiting])
        h.service.startAutomaticChecks()
        await h.transport.waitUntilSent()
        h.settings.setAutomaticUpdateChecks(.disabled)
        h.service.refreshAutomaticPolicy()
        await h.transport.waitUntilCancelled()
        let final = await h.completed(in: self, matching: { !$0.isChecking })
        XCTAssertEqual(final.result, .notChecked)
        XCTAssertNil(final.lastSuccessfulCheck)
        XCTAssertTrue(h.scheduler.delays.isEmpty)
        XCTAssertEqual(h.scheduler.scheduledCount, 0)
        let cancelledRequests = await h.transport.snapshot()
        let cancellations = await h.transport.cancellationCount
        XCTAssertEqual(cancelledRequests.count, 1)
        XCTAssertEqual(cancellations, 1)

        let later = UpdateHarness([.failure(.networkFailure)])
        later.service.startAutomaticChecks()
        _ = await later.completed(in: self)
        XCTAssertEqual(later.scheduler.scheduledCount, 1)
        later.settings.setAutomaticUpdateChecks(.disabled)
        later.service.refreshAutomaticPolicy()
        _ = await later.status()
        later.clock.advance(86_400)
        later.scheduler.fireNext()
        _ = await later.status()
        let requests = await later.transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(later.scheduler.delays.isEmpty, "The retired timer never rearms")
        XCTAssertEqual(later.scheduler.scheduledCount, 1)
    }

    func testCompletionSignalHandlesObserverAndStatusRead() async {
        let h = UpdateHarness([.waiting])
        h.service.startAutomaticChecks()
        await h.transport.waitUntilSent()
        let done = UpdateExpectation(in: self, description: "Cancelled update")
        let token = h.service.addObserver { if !$0.isChecking { done.fulfill() } }
        h.settings.setAutomaticUpdateChecks(.disabled)
        h.service.refreshAutomaticPolicy()
        await fulfillment(of: [done.expectation], timeout: 5)

        let final = await withCheckedContinuation { continuation in
            h.service.readStatus { snapshot in
                if !snapshot.isChecking { done.fulfill() }
                continuation.resume(returning: snapshot)
            }
        }
        h.service.removeObserver(token)
        XCTAssertEqual(done.callCount, 2, "The observer and passive read each report the same completed state")
        XCTAssertEqual(final.result, .notChecked)
        XCTAssertNil(final.lastSuccessfulCheck)
        let requests = await h.transport.snapshot()
        let cancellations = await h.transport.cancellationCount
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(h.scheduler.scheduledCount, 0)
    }

    func testCompletionSignalCountsConcurrentCallsAndFulfillsOnce() async {
        let done = UpdateExpectation(in: self, description: "Concurrent update reports")
        DispatchQueue.concurrentPerform(iterations: 16) { _ in done.fulfill() }
        await fulfillment(of: [done.expectation], timeout: 5)
        XCTAssertEqual(done.callCount, 16)
    }

    func testDisableIgnoresANoncooperativeResultAndKeepsTheSingleFlightSlot() async {
        let h = UpdateHarness([.held, .response(updateResponse())])
        h.service.startAutomaticChecks()
        await h.transport.waitUntilSent()
        h.settings.setAutomaticUpdateChecks(.disabled)
        h.service.refreshAutomaticPolicy()
        h.service.checkNow()
        _ = await h.status()
        let held = await h.transport.snapshot()
        XCTAssertEqual(held.count, 1)
        await h.transport.release(updateResponse())
        let cancelled = await h.completed(in: self, matching: { !$0.isChecking })
        XCTAssertEqual(cancelled.result, .notChecked)
        XCTAssertNil(cancelled.lastSuccessfulCheck)
        h.service.checkNow()
        _ = await h.completed(in: self)
        let requests = await h.transport.snapshot()
        XCTAssertEqual(requests.count, 2)
    }

    func testDisablingAutomaticChecksDoesNotCancelAManualRequest() async {
        let h = UpdateHarness([.held])
        h.service.checkNow()
        await h.transport.waitUntilSent()
        h.settings.setAutomaticUpdateChecks(.disabled)
        h.service.refreshAutomaticPolicy()
        _ = await h.status()
        await h.transport.release(updateResponse())
        let final = await h.completed(in: self)
        XCTAssertEqual(final.result, .updateAvailable(ReleaseVersion("2.0.0")!))
    }

    func testStableAboveSameBetaAndNoReleaseMalformedOfflineStayDifferent() async {
        let cases: [(HTTPResponse, UpdateCheckResult)] = [
            (updateResponse(tag: "v1.0.0"), .updateAvailable(ReleaseVersion("1.0.0")!)),
            (HTTPResponse(statusCode: 404, body: Data()), .noRelease),
            (HTTPResponse(statusCode: 200, body: Data("bad".utf8)), .unavailable(.malformedResponse)),
            (HTTPResponse(statusCode: 503, body: Data()), .unavailable(.httpStatus(503)))
        ]
        for (response, expected) in cases {
            let h = UpdateHarness([.response(response)], version: "1.0.0-beta.10")
            h.service.checkNow()
            let result = await h.completed(in: self)
            XCTAssertEqual(result.result, expected)
            if case .unavailable = expected { XCTAssertNil(result.lastSuccessfulCheck) }
            else { XCTAssertNotNil(result.lastSuccessfulCheck) }
        }
    }

    func testStopCancelsNetworkAndPreventsFurtherTrafficOrTimers() async {
        let h = UpdateHarness([.waiting])
        h.service.startAutomaticChecks()
        await h.transport.waitUntilSent()
        h.service.stop()
        await h.transport.waitUntilCancelled()
        h.service.checkNow()
        h.service.startAutomaticChecks()
        h.service.refreshAutomaticPolicy()
        _ = await h.status()
        let requests = await h.transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(h.scheduler.delays.isEmpty)
    }
}
