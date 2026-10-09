#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxPortalTransportTests: XCTestCase {
    private final class Receipt {
        var outcomes: [PortalRequestOutcome] = []
        func receive(_ outcome: PortalRequestOutcome) {
            XCTAssertTrue(Thread.isMainThread)
            outcomes.append(outcome)
        }
    }

    private var portal: FakePortal!
    private var transport: LinuxPortalTransport!
    private let success = PortalRequestOutcome.success(PortalResponse(
        sessionHandle: "/org/freedesktop/portal/desktop/session/mock", devices: 1,
        restoreToken: PortalRestoreToken("fixture-restore"),
        shortcuts: [PortalShortcut(id: "toggle", properties: [
            "description": "Open picker", "trigger_description": "Ctrl+Alt+P",
        ])]))

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        portal = try FakePortal(address: address)
        try portal.ownName()
        transport = LinuxPortalTransport(busAddress: address)
    }

    override func tearDown() {
        transport?.shutdown()
        transport = nil
        portal?.shutdown()
        portal = nil
        drain(for: .milliseconds(20))
    }

    @discardableResult
    private func send(_ receipt: Receipt, timeout: Duration = .seconds(1),
                      interface: PortalInterface = .globalShortcuts, method: String = "CreateSession",
                      arguments: [PortalArgument] = [], options: [String: PortalOption] = [:]) -> UUID {
        transport.request(interface: interface, method: method, arguments: arguments, options: options,
            deadline: ContinuousClock.now.advanced(by: timeout), completion: receipt.receive)
    }

    private func wait(_ receipt: Receipt, _ expected: PortalRequestOutcome,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(GTKTestSupport.spin { !receipt.outcomes.isEmpty }, file: file, line: line)
        XCTAssertEqual(receipt.outcomes, [expected], file: file, line: line)
    }

    private func firstCall() throws -> FakePortal.Call {
        XCTAssertTrue(GTKTestSupport.spin { !self.portal.calls.isEmpty })
        return try XCTUnwrap(portal.calls.first)
    }

    private func drain(for duration: Duration) {
        let deadline = ContinuousClock.now.advanced(by: duration)
        _ = GTKTestSupport.spin(until: { ContinuousClock.now >= deadline })
    }

    func testNormalSuccessReturnsImmediatelyAndUsesSenderPath() throws {
        let receipt = Receipt()
        send(receipt, options: ["session_handle_token": .string("stable_session")])
        XCTAssertTrue(receipt.outcomes.isEmpty)
        wait(receipt, success)
        let call = try firstCall()
        XCTAssertTrue(call.path == call.expectedPath)
        XCTAssertTrue(call.token.hasPrefix("monkeyspaw_"))
        XCTAssertEqual(call.token.count, "monkeyspaw_".count + 32)
        let sessionToken = try XCTUnwrap(call.option("session_handle_token"))
        defer { g_variant_unref(sessionToken) }
        XCTAssertTrue(String(cString: g_variant_get_string(sessionToken, nil)) == "stable_session")
        XCTAssertTrue(portal.closedPaths.isEmpty)
    }

    func testImmediateResponseBeforeMethodReply() {
        portal.timing = .beforeReply
        let receipt = Receipt()
        send(receipt)
        wait(receipt, success)
    }

    func testDifferentHandleResponseBeforeReplyIsBufferedAndValidated() throws {
        portal.timing = .manual
        portal.handle = .different
        let receipt = Receipt()
        send(receipt)
        let call = try firstCall()
        portal.respond(call)
        drain(for: .milliseconds(30))
        XCTAssertTrue(receipt.outcomes.isEmpty)
        portal.reply(call)
        wait(receipt, success)
    }

    func testDifferentHandleIgnoresPredictedPathAndClosesActualOnCancellation() throws {
        portal.timing = .manual
        portal.handle = .different
        let receipt = Receipt()
        let id = send(receipt)
        let call = try firstCall()
        portal.reply(call)
        portal.respond(call, path: call.expectedPath)
        drain(for: .milliseconds(30))
        XCTAssertTrue(receipt.outcomes.isEmpty)
        transport.cancel(id)
        wait(receipt, .cancelled)
        XCTAssertTrue(GTKTestSupport.spin { self.portal.closedPaths.contains(call.path) })
        XCTAssertFalse(portal.closedPaths.contains(call.expectedPath))
    }

    func testCancelBeforeMethodReplyClosesReturnedLegacyHandle() throws {
        portal.timing = .manual
        portal.handle = .different
        let receipt = Receipt()
        let id = send(receipt)
        let call = try firstCall()
        transport.cancel(id)
        wait(receipt, .cancelled)
        portal.reply(call)
        XCTAssertTrue(GTKTestSupport.spin { self.portal.closedPaths.contains(call.path) })
        portal.respond(call)
        drain(for: .milliseconds(20))
        XCTAssertEqual(receipt.outcomes, [.cancelled])
    }

    func testDeniedAndCancelledResponseCodes() {
        for (code, expected) in [(2, PortalRequestOutcome.denied), (1, .cancelled)] {
            portal.responseBody = "(uint32 \(code), @a{sv} {})"
            let receipt = Receipt()
            send(receipt)
            wait(receipt, expected)
        }
        XCTAssertTrue(portal.closedPaths.isEmpty)
    }

    func testMalformedResponsesFailClosed() {
        let bodies = [
            "('wrong signature',)",
            "(uint32 3, @a{sv} {})",
            "(uint32 0, {'session_handle': <objectpath '/valid/but/wrong/type'>})",
            "(uint32 0, {'session_handle': <'not/a/path'>})",
            "(uint32 0, {'devices': <'not uint32'>})",
            "(uint32 0, {'restore_token': <''>})",
            "(uint32 0, {'shortcuts': <'not an array'>})",
            "(uint32 0, {'shortcuts': <[('toggle', {'description': <uint32 7>})]>})",
            "(uint32 0, {'devices': <uint32 1>, 'devices': <uint32 2>})",
        ]
        for body in bodies {
            portal.responseBody = body
            let receipt = Receipt()
            send(receipt)
            wait(receipt, .malformedResponse)
        }
    }

    func testOversizedResponseIsRejected() {
        portal.responseBody = "(uint32 0, {'extra': <'" + String(repeating: "x",
            count: Limits.portalResponseMaxBytes) + "'>})"
        let receipt = Receipt()
        send(receipt)
        wait(receipt, .malformedResponse)
    }

    func testMalformedMethodRepliesCannotCompleteBufferedSuccess() {
        portal.timing = .beforeReply
        for body in ["('/org/freedesktop/portal/desktop/request/wrong_type',)",
                     "(objectpath '/outside/request/namespace',)", "()"] {
            portal.replyBody = body
            let receipt = Receipt()
            send(receipt)
            wait(receipt, .malformedResponse)
        }
        XCTAssertTrue(portal.closedPaths.allSatisfy {
            $0.hasPrefix("/org/freedesktop/portal/desktop/request/")
        })
    }

    func testMethodErrorWinsOverEarlyResponse() {
        portal.timing = .beforeReply
        portal.methodError = "org.freedesktop.portal.Error.Failed"
        let receipt = Receipt()
        send(receipt)
        wait(receipt, .methodError)
    }

    func testAbsentPortalAndOwnerDisappearance() throws {
        portal.dropName()
        drain(for: .milliseconds(30))
        let absent = Receipt()
        send(absent)
        wait(absent, .unavailable)

        try portal.ownName()
        portal.timing = .manual
        let waiting = Receipt()
        send(waiting)
        let call = try firstCall()
        portal.reply(call)
        drain(for: .milliseconds(20))
        portal.dropName()
        wait(waiting, .unavailable)
    }

    func testBusConnectionFailureIsTyped() {
        let failed = LinuxPortalTransport(busAddress: "unix:path=/nonexistent/monkeyspaw-test-bus")
        defer { failed.shutdown() }
        let receipt = Receipt()
        failed.request(interface: .remoteDesktop, method: "CreateSession",
            deadline: ContinuousClock.now.advanced(by: .seconds(1)), completion: receipt.receive)
        wait(receipt, .busFailure)
    }

    func testBusDisconnectCompletesPendingMethodAndResponseWaitsOnce() throws {
        enum WaitingFor { case methodReply, response }
        for phase in [WaitingFor.methodReply, .response] {
            let daemon = try PrivatePortalDaemon()
            defer { daemon.stop() }
            let mock = try FakePortal(address: daemon.address)
            defer { mock.shutdown() }
            try mock.ownName()
            mock.timing = .manual
            let client = LinuxPortalTransport(busAddress: daemon.address)
            defer { client.shutdown() }
            let receipt = Receipt()
            let id = client.request(interface: .globalShortcuts, method: "CreateSession",
                deadline: ContinuousClock.now.advanced(by: .seconds(1)), completion: receipt.receive)
            XCTAssertTrue(GTKTestSupport.spin { !mock.calls.isEmpty })
            let call = try XCTUnwrap(mock.calls.first)
            if phase == .response { mock.reply(call); drain(for: .milliseconds(20)) }
            daemon.stop()
            wait(receipt, .busFailure)
            client.cancel(id)
            client.shutdown()
            drain(for: .milliseconds(20))
            XCTAssertEqual(receipt.outcomes, [.busFailure])
        }
    }

    func testUnrelatedSenderCannotCompleteRequest() throws {
        portal.timing = .manual
        let receipt = Receipt()
        send(receipt)
        let call = try firstCall()
        portal.reply(call)
        let unrelated = try FakePortal(address: FakePortal.requirePrivateBus())
        defer { unrelated.shutdown() }
        unrelated.respond(call, body: "(uint32 2, @a{sv} {})")
        drain(for: .milliseconds(30))
        XCTAssertTrue(receipt.outcomes.isEmpty)
        portal.respond(call)
        wait(receipt, success)
    }

    func testTimeoutWhileMethodReplyIsPendingClosesRequestAndIgnoresLateReply() throws {
        portal.timing = .manual
        let receipt = Receipt()
        send(receipt, timeout: .milliseconds(100))
        let call = try firstCall()
        wait(receipt, .timedOut)
        XCTAssertTrue(GTKTestSupport.spin { self.portal.closedPaths.contains(call.path) })
        portal.reply(call)
        portal.respond(call)
        drain(for: .milliseconds(30))
        XCTAssertEqual(receipt.outcomes, [.timedOut])
    }

    func testResponseWaitUsesRemainingDeadline() throws {
        portal.timing = .manual
        let receipt = Receipt()
        send(receipt, timeout: .milliseconds(140))
        let call = try firstCall()
        drain(for: .milliseconds(80))
        portal.reply(call)
        // A fresh response budget would accept this late success.
        drain(for: .milliseconds(80))
        portal.respond(call)
        wait(receipt, .timedOut)
        drain(for: .milliseconds(20))
        XCTAssertEqual(receipt.outcomes, [.timedOut])
    }

    func testDuplicateAndLateResponsesCompleteOnceAndDoNotAffectAnotherRequest() throws {
        portal.timing = .manual
        let first = Receipt()
        send(first)
        let call = try firstCall()
        portal.respond(call)
        portal.respond(call, body: "(uint32 2, @a{sv} {})")
        portal.reply(call)
        wait(first, success)

        let second = Receipt()
        send(second)
        XCTAssertTrue(GTKTestSupport.spin { self.portal.calls.count == 2 })
        let next = portal.calls[1]
        XCTAssertFalse(call.token == next.token)
        portal.respond(call, body: "(uint32 2, @a{sv} {})")
        portal.reply(next)
        portal.respond(next)
        wait(second, success)
        XCTAssertEqual(first.outcomes, [success])
    }

    func testCancelBeforeConnectionCompletesAndExpiredDeadline() {
        let receipt = Receipt()
        let id = send(receipt)
        transport.cancel(id)
        transport.cancel(id)
        wait(receipt, .cancelled)
        drain(for: .milliseconds(20))
        XCTAssertTrue(portal.calls.isEmpty)

        let expired = Receipt()
        send(expired, timeout: .zero)
        wait(expired, .timedOut)
        XCTAssertTrue(portal.calls.isEmpty)
    }

    func testTeardownWithPendingRequestReleasesClosureAndConnection() throws {
        portal.timing = .manual
        let receipt = Receipt()
        var retained: NSObject? = NSObject()
        weak let released = retained
        transport.request(interface: .remoteDesktop, method: "CreateSession",
            deadline: ContinuousClock.now.advanced(by: .seconds(1))) { [retained] outcome in
                _ = retained
                receipt.receive(outcome)
            }
        retained = nil
        XCTAssertNotNil(released)
        let call = try firstCall()
        weak let releasedTransport = transport
        transport = nil
        wait(receipt, .tornDown)
        XCTAssertNil(releasedTransport)
        XCTAssertNil(released)
        XCTAssertTrue(GTKTestSupport.spin { self.portal.closedPaths.contains(call.path) })
        XCTAssertTrue(GTKTestSupport.spin { self.portal.departedNames.contains(call.sender) })
        portal.reply(call)
        portal.respond(call)
        drain(for: .milliseconds(30))
        XCTAssertEqual(receipt.outcomes, [.tornDown])
    }

    func testShutdownCancelsAllRequestsAndIsIdempotent() throws {
        portal.timing = .manual
        let receipts = (0..<3).map { _ in Receipt() }
        for receipt in receipts { send(receipt) }
        XCTAssertTrue(GTKTestSupport.spin { self.portal.calls.count == 3 })
        transport.shutdown()
        transport.shutdown()
        for receipt in receipts { wait(receipt, .tornDown) }
        XCTAssertTrue(GTKTestSupport.spin { self.portal.closedPaths.count == 3 })
        let later = Receipt()
        send(later)
        wait(later, .tornDown)
    }

    func testPortalWireArgumentShapesMatchBothInterfaces() {
        let session = "/org/freedesktop/portal/desktop/session/fixture"
        let shapes: [(PortalInterface, String, [PortalArgument], [String: PortalOption], String)] = [
            (.globalShortcuts, "BindShortcuts", [.objectPath(session), .shortcuts([
                PortalShortcut(id: "toggle", properties: ["description": "Open picker",
                    "preferred_trigger": "CTRL+ALT+p"]),
            ]), .string("")], [:], "(oa(sa{sv})sa{sv})"),
            (.globalShortcuts, "ListShortcuts", [.objectPath(session)], [:], "(oa{sv})"),
            (.remoteDesktop, "CreateSession", [], ["session_handle_token": .string("fixture")], "(a{sv})"),
            (.remoteDesktop, "SelectDevices", [.objectPath(session)], ["types": .uint32(1),
                "persist_mode": .uint32(2), "restore_token": .string("fixture")], "(oa{sv})"),
            (.remoteDesktop, "Start", [.objectPath(session), .string("")], [:], "(osa{sv})"),
        ]
        for (interface, method, arguments, options, signature) in shapes {
            let receipt = Receipt()
            send(receipt, interface: interface, method: method, arguments: arguments, options: options)
            wait(receipt, success)
            XCTAssertEqual(portal.calls.last?.signature, signature)
            XCTAssertEqual(portal.calls.last?.interface, interface.rawValue)
        }
    }

    func testInvalidArgumentsNeverReachBus() {
        let cases: [(String, [PortalArgument], [String: PortalOption])] = [
            ("not.a.member", [], [:]), ("CreateSession", [.objectPath("not/a/path")], [:]),
            ("CreateSession", [.string("bad\0string")], [:]),
            ("CreateSession", [], ["handle_token": .string("stable_is_not_a_request_token")]),
            ("CreateSession", [], ["restore_token": .string("bad\0string")]),
        ]
        for (method, arguments, options) in cases {
            let receipt = Receipt()
            send(receipt, method: method, arguments: arguments, options: options)
            wait(receipt, .invalidArguments)
        }
        XCTAssertTrue(portal.calls.isEmpty)
    }

    func testSharedGioConnectionSurvivesTransportShutdown() throws {
        final class ConnectionReceipt { var connection: OpaquePointer?; var done = false }
        let receipt = ConnectionReceipt()
        g_bus_get(G_BUS_TYPE_SESSION, nil, { _, result, data in
            guard let result, let data else { return }
            let receipt = Unmanaged<ConnectionReceipt>.fromOpaque(data).takeRetainedValue()
            receipt.connection = g_bus_get_finish(result, nil)
            receipt.done = true
        }, Unmanaged.passRetained(receipt).toOpaque())
        XCTAssertTrue(GTKTestSupport.spin { receipt.done })
        let shared = try XCTUnwrap(receipt.connection)
        defer { g_object_unref(UnsafeMutableRawPointer(shared)) }
        let client = LinuxPortalTransport(busAddress: nil)
        let response = Receipt()
        client.request(interface: .globalShortcuts, method: "CreateSession",
            deadline: ContinuousClock.now.advanced(by: .seconds(1)), completion: response.receive)
        wait(response, success)
        let sender = try XCTUnwrap(portal.calls.last?.sender)
        XCTAssertTrue(sender == String(cString: g_dbus_connection_get_unique_name(shared)))
        client.shutdown()
        XCTAssertEqual(g_dbus_connection_is_closed(shared), 0)
        final class ReplyReceipt { var done = false }
        let reply = ReplyReceipt()
        g_dbus_connection_call(shared, "org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus", "ListNames", nil, nil, G_DBUS_CALL_FLAGS_NONE, 1_000, nil,
            { source, result, data in
                guard let source, let result, let data else { return }
                let reply = Unmanaged<ReplyReceipt>.fromOpaque(data).takeRetainedValue()
                let value = g_dbus_connection_call_finish(mp_dbus_connection(source), result, nil)
                XCTAssertNotNil(value)
                if let value { g_variant_unref(value) }
                reply.done = true
            }, Unmanaged.passRetained(reply).toOpaque())
        XCTAssertTrue(GTKTestSupport.spin { reply.done })
        XCTAssertFalse(portal.departedNames.contains(sender))
    }
}
#endif
