import Foundation
import XCTest
@testable import MonkeysPawCore

final class UpdateClock: WallClock {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        date.addTimeInterval(seconds)
        lock.unlock()
    }
}

final class UpdateMainThread: MainThread {
    private let lock = NSLock()
    private var jobs: [() -> Void] = []
    var deferred = false
    var isRunning: Bool { Thread.current.threadDictionary["update-test-main"] as? Bool == true }

    func run(_ work: @escaping () -> Void) {
        lock.lock()
        if deferred { jobs.append(work); lock.unlock(); return }
        lock.unlock()
        execute(work)
    }

    func drain() {
        while true {
            lock.lock()
            if jobs.isEmpty { lock.unlock(); return }
            let job = jobs.removeFirst()
            lock.unlock()
            execute(job)
        }
    }

    private func execute(_ work: () -> Void) {
        let previous = isRunning
        Thread.current.threadDictionary["update-test-main"] = true
        work()
        Thread.current.threadDictionary["update-test-main"] = previous
    }
}

final class UpdateScheduler: Scheduler {
    private let lock = NSLock()
    private var jobs: [(Duration, () -> Void)] = []

    var delays: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return jobs.map { $0.0 }
    }

    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        lock.lock()
        jobs.append((delay, work))
        lock.unlock()
    }

    func fireNext() {
        lock.lock()
        guard !jobs.isEmpty else { lock.unlock(); return }
        let work = jobs.removeFirst().1
        lock.unlock()
        work()
    }
}

final class UpdatePageOpener: ReleasePageOpening {
    let main: UpdateMainThread
    private(set) var urls: [URL] = []
    var outcome = ReleasePageOpenOutcome.opened

    init(main: UpdateMainThread) { self.main = main }

    func openReleasePage(_ url: URL, completion: @escaping (ReleasePageOpenOutcome) -> Void) {
        XCTAssertTrue(main.isRunning)
        urls.append(url)
        completion(outcome)
    }
}

final class UpdateHarness {
    let files: MemoryFileStore
    let settingsFiles: MemoryFileStore
    let settingsService: SettingsService
    let settings: SettingsModel
    let clock: UpdateClock
    let main = UpdateMainThread()
    let scheduler = UpdateScheduler()
    let opener: UpdatePageOpener
    let transport: ConnectionTransport
    let service: UpdateService

    init(_ replies: [ConnectionTransport.Reply] = [.response(updateResponse())],
         files: MemoryFileStore = MemoryFileStore(), settingsFiles: MemoryFileStore = MemoryFileStore(),
         clock: UpdateClock = UpdateClock(), version: String? = "1.0.0") {
        self.files = files
        self.settingsFiles = settingsFiles
        self.clock = clock
        settingsService = SettingsService(store: SettingsStore(files: settingsFiles))
        settings = SettingsModel(settings: settingsService)
        transport = ConnectionTransport(replies)
        opener = UpdatePageOpener(main: main)
        service = UpdateService(transport: transport, currentVersion: version, settings: settingsService,
            stateStore: UpdateStateStore(files: files), clock: clock, scheduler: scheduler,
            mainThread: main, releasePage: opener)
    }

    func model() -> UpdateSettingsModel {
        UpdateSettingsModel(settings: settings, updates: service, mainThread: main)
    }

    func status() async -> UpdateSnapshot {
        await withCheckedContinuation { continuation in
            service.readStatus { continuation.resume(returning: $0) }
        }
    }

    func completed(in test: XCTestCase, matching predicate: @escaping (UpdateSnapshot) -> Bool = {
        !$0.isChecking && $0.result != .notChecked
    }) async -> UpdateSnapshot {
        let done = test.expectation(description: "Update outcome")
        let token = service.addObserver { snapshot in
            if predicate(snapshot) { done.fulfill() }
        }
        service.readStatus { if predicate($0) { done.fulfill() } }
        await test.fulfillment(of: [done], timeout: 5)
        service.removeObserver(token)
        return await status()
    }
}

func updateResponse(tag: String = "v2.0.0", draft: Bool = false, prerelease: Bool = false,
                    htmlURL: String = "https://github.com/L-K-M/MonkeysPaw/releases/tag/v2.0.0") -> HTTPResponse {
    let bytes = try! JSONSerialization.data(withJSONObject: [
        "tag_name": tag, "draft": draft, "prerelease": prerelease, "html_url": htmlURL,
        "body": "Untrusted release notes", "assets": [["browser_download_url": "https://evil.example/install"]]
    ])
    return HTTPResponse(statusCode: 200, body: bytes)
}
