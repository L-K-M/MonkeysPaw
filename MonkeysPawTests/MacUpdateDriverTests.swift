import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacUpdateDriverTests: XCTestCase {
    private var directory: URL!
    private var services: [UpdateService] = []
    private var schedulers: [MacUpdateScheduler] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        for service in services { service.stop() }
        for scheduler in schedulers { scheduler.stop() }
        services = []
        schedulers = []
        try? FileManager.default.removeItem(at: directory)
    }

    func testRawBundleVersionWinsWithoutInventingLostSuffixes() {
        XCTAssertNil(MacReleaseVersion.read(from: [:]))
        XCTAssertEqual(MacReleaseVersion.read(from: ["CFBundleShortVersionString": "1.0.0"]), "1.0.0")
        XCTAssertEqual(MacReleaseVersion.read(from: ["MonkeysPawReleaseVersion": "1.0.0-beta.2",
            "CFBundleShortVersionString": "1.0.0"]), "1.0.0-beta.2")
        XCTAssertEqual(MacReleaseVersion.read(from: ["MonkeysPawReleaseVersion": "bad",
            "CFBundleShortVersionString": "1.0.0"]), "bad")
        XCTAssertNil(MacReleaseVersion.read(from: ["MonkeysPawReleaseVersion": 42,
            "CFBundleShortVersionString": "1.0.0"]))
    }

    func testWorkspaceDriverReportsSuccessAndFailureWithoutOpeningOnConstruction() throws {
        var urls: [URL] = []
        var succeeds = false
        let opener = WorkspaceReleasePageOpener { urls.append($0); return succeeds }
        let url = try XCTUnwrap(URL(string: "https://github.com/L-K-M/MonkeysPaw/releases/tag/v1.0.0"))
        XCTAssertTrue(urls.isEmpty)
        opener.openReleasePage(url) { XCTAssertEqual($0, .failed) }
        succeeds = true
        opener.openReleasePage(url) { XCTAssertEqual($0, .opened) }
        XCTAssertEqual(urls, [url, url])
    }

    func testUpdateTimersCancelSupersededDisabledAndStoppedWorkAndReleaseCaptures() {
        let timers = MacSettingsUpdateTimers()
        let scheduler = MacUpdateScheduler(mainThread: DispatchMainThread(), schedule: timers.schedule)
        var calls = 0
        scheduler.after(.seconds(1)) { calls += 1 }
        XCTAssertTrue(timers.jobs.isEmpty, "Hosted construction starts with timers disabled")
        scheduler.setEnabled(true)
        scheduler.after(.seconds(1)) { calls += 1 }
        scheduler.after(.seconds(2)) { calls += 10 }
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(timers.cancellations, 1)
        timers.fireAll()
        XCTAssertEqual(calls, 10)
        XCTAssertEqual(scheduler.pendingCount, 0)

        var marker: NSObject? = NSObject()
        weak var weakMarker = marker
        scheduler.after(.seconds(1)) { [marker] in _ = marker; calls += 100 }
        marker = nil
        XCTAssertNotNil(weakMarker)
        scheduler.setEnabled(false)
        XCTAssertNil(weakMarker, "Cancellation releases work even if a native callback arrives late")
        timers.fireAll()
        XCTAssertEqual(calls, 10)
        scheduler.setEnabled(true)
        scheduler.after(.seconds(1)) { calls += 1_000 }
        scheduler.stop()
        scheduler.setEnabled(true)
        scheduler.after(.seconds(1)) { calls += 10_000 }
        timers.fireAll()
        XCTAssertEqual(calls, 10)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testSchedulerReleaseCancelsTimerWithoutRetainingOwner() {
        let timers = MacSettingsUpdateTimers()
        var scheduler: MacUpdateScheduler? = MacUpdateScheduler(mainThread: DispatchMainThread(), schedule: timers.schedule)
        weak var weakScheduler = scheduler
        scheduler?.setEnabled(true)
        var calls = 0
        scheduler?.after(.seconds(1)) { calls += 1 }
        scheduler = nil
        XCTAssertNil(weakScheduler)
        XCTAssertEqual(timers.cancellations, 1)
        timers.fireAll()
        XCTAssertEqual(calls, 0)
    }

    func testReleaseFromWorkerCancelsOnTheInstallingUIThread() throws {
        let timers = MacSettingsUpdateTimers()
        var scheduler: MacUpdateScheduler? = MacUpdateScheduler(mainThread: DispatchMainThread(), schedule: timers.schedule)
        weak var weakScheduler = scheduler
        scheduler?.setEnabled(true)
        var calls = 0
        scheduler?.after(.seconds(1)) { calls += 1 }
        let owner = MacSettingsSchedulerOwner(try XCTUnwrap(scheduler))
        scheduler = nil
        let released = expectation(description: "Scheduler released on worker")
        DispatchQueue.global().async {
            owner.release()
            released.fulfill()
        }
        wait(for: [released], timeout: 5)
        waitFor { timers.cancellations == 1 }
        XCTAssertNil(weakScheduler)
        timers.fireAll()
        XCTAssertEqual(calls, 0)
    }

    func testAutomaticDailyAttemptSurvivesRestartAndUsesOnlyFakeTimers() throws {
        let clock = MacSettingsClock()
        let first = try harness(clock: clock)
        first.service.startAutomaticChecks()
        waitFor { first.http.count == 1 && first.page.state.update?.lastSuccessfulCheck != nil }
        waitFor { first.scheduler.pendingCount == 1 }
        XCTAssertEqual(first.page.state.update?.lastAutomaticAttempt, clock.now())
        first.scheduler.stop()
        first.service.stop()
        let restarted = try harness(clock: clock)
        restarted.service.startAutomaticChecks()
        waitFor { restarted.scheduler.pendingCount == 1 }
        XCTAssertEqual(restarted.http.count, 0)
        clock.advance(Limits.updateCheckInterval)
        restarted.timers.fireAll()
        waitFor { restarted.http.count == 1 && restarted.page.state.update?.lastAutomaticAttempt == clock.now() }
    }

    func testAutomaticOffAndDisableInFlightIgnoreLateReplyAndRetireTimer() throws {
        let h = try harness()
        h.settings.setAutomaticUpdateChecks(.disabled)
        h.scheduler.setEnabled(false)
        h.service.startAutomaticChecks()
        h.page.model.refresh()
        waitFor { h.page.state.update != nil }
        XCTAssertEqual(h.http.count, 0)
        XCTAssertEqual(h.scheduler.pendingCount, 0)
        h.http.hold = true
        h.scheduler.setEnabled(true)
        h.page.setAutomatic(true)
        waitFor { h.http.count == 1 && h.page.state.update?.isChecking == true }
        h.scheduler.setEnabled(false)
        h.page.setAutomatic(false)
        h.http.release()
        waitFor { h.page.state.update?.isChecking == false }
        XCTAssertEqual(h.page.state.update?.result, .notChecked)
        XCTAssertEqual(h.scheduler.pendingCount, 0)
        h.timers.fireAll()
        XCTAssertEqual(h.http.count, 1)
        h.http.reply = .success(HTTPResponse(statusCode: 404, body: Data()))
        h.page.checkNow()
        waitFor { h.http.count == 2 && h.page.state.update?.result == .noRelease }
        XCTAssertEqual(h.scheduler.pendingCount, 0)
    }

    private typealias Harness = (service: UpdateService, settings: SettingsModel, page: UpdateSettingsViewState,
        http: MacSettingsHTTP, scheduler: MacUpdateScheduler, timers: MacSettingsUpdateTimers)

    private func harness(clock: WallClock = MacSettingsClock()) throws -> Harness {
        let main = DispatchMainThread()
        let files = try RootedFileStore(root: directory)
        try files.createRoot()
        let settingsService = SettingsService(store: SettingsStore(files: files))
        let settings = SettingsModel(settings: settingsService)
        let http = MacSettingsHTTP()
        let timers = MacSettingsUpdateTimers()
        let scheduler = MacUpdateScheduler(mainThread: main, schedule: timers.schedule)
        scheduler.setEnabled(settings.allowsAutomaticUpdateChecks)
        let service = UpdateService(transport: http, currentVersion: "1.0.0-beta.2", settings: settingsService,
            stateStore: UpdateStateStore(files: files), clock: clock, scheduler: scheduler,
            mainThread: main, releasePage: WorkspaceReleasePageOpener(open: { _ in XCTFail("Unexpected browser"); return false }))
        let model = UpdateSettingsModel(settings: settings, updates: service, mainThread: main)
        let page = UpdateSettingsViewState(model: model, mainThread: main)
        page.show()
        services.append(service)
        schedulers.append(scheduler)
        return (service, settings, page, http, scheduler, timers)
    }

    private func waitFor(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
        }
        XCTAssertTrue(predicate(), "Update work did not settle", file: file, line: line)
    }
}

/// The worker only drops ownership; it never calls the UI-confined scheduler.
private final class MacSettingsSchedulerOwner: @unchecked Sendable {
    private var scheduler: MacUpdateScheduler?
    init(_ scheduler: MacUpdateScheduler) { self.scheduler = scheduler }
    func release() { scheduler = nil }
}
