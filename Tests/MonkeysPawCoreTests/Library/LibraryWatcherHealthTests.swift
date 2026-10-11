import Foundation
import XCTest
@testable import MonkeysPawCore

final class LibraryWatcherHealthTests: XCTestCase {
    func testHealthFlushesEarlierChangesBeforeUnavailableWithoutWaitingForDebounce() throws {
        let raw = HealthWatcher()
        let scheduler = HealthScheduler()
        let received = HealthDeliveries()
        let service = LibraryWatcher(watcher: raw, scheduler: scheduler)
        try service.start { received.record($0) }
        defer { service.stop() }
        raw.file("earlier.md")
        raw.unavailable()
        // Health must flush earlier observations immediately on the driver's
        // thread, then invalidate their outstanding quiet-window timers.
        XCTAssertEqual(received.values, ["changes", "unavailable"])
        XCTAssertEqual(received.paths, ["earlier.md"])
        scheduler.fireAll()
        XCTAssertEqual(received.values, ["changes", "unavailable"])
    }
}

private final class HealthWatcher: FileStoreWatcher {
    var callback: (@Sendable (FileStoreWatchEvent) -> Void)?
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws { callback = onEvent }
    func stop() { callback = nil }
    func file(_ path: String) { callback?(.file(FileStoreEvent(relativePath: path, kind: .created))) }
    func unavailable() { callback?(.rootUnavailable(.notFound)) }
}

private final class HealthScheduler: Scheduler {
    var callbacks = [() -> Void]()
    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        if delay == .zero { work() } else { callbacks.append(work) }
    }
    func fireAll() { for work in callbacks { work() } }
}

private final class HealthDeliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [String]()
    private var storedPaths = [String]()
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return storedPaths }
    func record(_ update: LibraryWatchUpdate) {
        lock.lock()
        defer { lock.unlock() }
        switch update {
        case .changes(let change):
            stored.append("changes")
            storedPaths.append(contentsOf: change.created.sorted().map { $0.string })
        case .rootUnavailable:
            stored.append("unavailable")
        }
    }
}
