import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacSettingsHTTP: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private var pending: CheckedContinuation<HTTPResponse, Error>?
    private var held = false
    private var storedReply: Result<HTTPResponse, HTTPTransportError> = .success(HTTPResponse(statusCode: 200,
        body: Data("{\"tag_name\":\"v1.0.0\",\"draft\":false,\"prerelease\":false,\"html_url\":\"https://evil.example\"}".utf8)))

    var count: Int { lock.withLock { recorded.count } }
    var requests: [HTTPRequest] { lock.withLock { recorded } }
    var hold: Bool {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
    var reply: Result<HTTPResponse, HTTPTransportError> {
        get { lock.withLock { storedReply } }
        set { lock.withLock { storedReply = newValue } }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        XCTAssertFalse(Thread.isMainThread)
        return try await withCheckedThrowingContinuation { continuation in
            let reply: Result<HTTPResponse, HTTPTransportError>? = lock.withLock {
                recorded.append(request)
                if held {
                    precondition(pending == nil, "UpdateService must remain single-flight")
                    pending = continuation
                    return nil
                }
                return storedReply
            }
            if let reply { continuation.resume(with: reply.mapError { $0 as Error }) }
        }
    }

    func release() {
        let (continuation, reply) = lock.withLock {
            let continuation = pending
            pending = nil
            held = false
            return (continuation, storedReply)
        }
        continuation?.resume(with: reply.mapError { $0 as Error })
    }
}

final class MacSettingsTimers: MonkeysPawCore.Scheduler {
    private var jobs: [() -> Void] = []
    private(set) var restores: [() -> Void] = []

    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        if delay == Limits.clipboardRestoreDelay { restores.append(work) }
        else { jobs.append(work) }
    }

    func drain() {
        var count = 0
        while !jobs.isEmpty {
            guard count < 1_000 else { XCTFail("Delivery timers did not settle"); return }
            count += 1
            jobs.removeFirst()()
        }
    }

    func fireRestores() {
        let work = restores
        restores.removeAll()
        work.forEach { $0() }
    }
}

/// No native timer is registered, including when tests explicitly start policy.
final class MacSettingsUpdateTimers {
    private(set) var jobs: [() -> Void] = []
    private(set) var cancellations = 0
    func schedule(_ delay: Duration, _ work: @escaping () -> Void) -> (() -> Void) {
        XCTAssertTrue(Thread.isMainThread)
        jobs.append(work)
        return { [weak self] in
            XCTAssertTrue(Thread.isMainThread)
            self?.cancellations += 1
        }
    }
    func fireAll() { let work = jobs; jobs.removeAll(); work.forEach { $0() } }
}

final class MacSettingsSelfTestTarget: SelfTestTarget {
    private(set) var presentations = 0
    private(set) var closes = 0
    func present(fieldExpecting text: String) { presentations += 1 }
    func readBack() -> String? { DeliveryStrings.testPrompt }
    func close() { closes += 1 }
}

final class MacSettingsClock: WallClock {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}
