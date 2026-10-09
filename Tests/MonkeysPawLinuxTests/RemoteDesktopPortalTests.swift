#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class RemoteDesktopPortalTests: XCTestCase {
    private var portal: FakePortal!
    private var transport: LinuxPortalTransport!
    private var injector: RemoteDesktopPasteInjector!
    private var tools: FakeLinuxTools!
    private var store: PortalTokenStore!
    private var parentCloses = 0

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        portal = try FakePortal(address: address)
        portal.behavior = .sessions
        try portal.ownName()
        transport = LinuxPortalTransport(busAddress: address)
        tools = try PortalSessionTestSupport.tools()
        store = PortalTokenStore(paths: LinuxPaths(environment: tools.environment))
        injector = makeInjector()
    }

    private func makeInjector(session: DesktopSession = .gnomeWayland,
                              callBudget: Duration = Limits.portalCallTimeout,
                              consentBudget: Duration = Limits.portalConsentTimeout) -> RemoteDesktopPasteInjector {
        RemoteDesktopPasteInjector(transport: transport, tokens: store, session: session,
            mainThread: GLibMainThread(), parent: { completion in
                completion(PortalParent("x11:5678") { [weak self] in self?.parentCloses += 1 })
            }, callBudget: callBudget, consentBudget: consentBudget)
    }

    override func tearDown() {
        injector?.shutdown()
        injector = nil
        transport?.shutdown()
        transport = nil
        portal?.shutdown()
        portal = nil
        tools = nil
    }

    private func allow() {
        var done = false
        injector.allow { done = true }
        XCTAssertTrue(GTKTestSupport.spin { done })
    }

    @discardableResult
    private func paste(_ chord: PasteChord = .standard, consent: PasteConsent = .existingSession) -> PasteAttemptResult? {
        var result: PasteAttemptResult?
        injector.paste(chord: chord, consent: consent) { result = $0 }
        XCTAssertTrue(GTKTestSupport.spin { result != nil })
        return result
    }

    private var notify: [FakePortal.Call] { portal.ordinaryCalls.filter { $0.method == "NotifyKeyboardKeysym" } }
    private var keys: [Int32] { notify.map { portal.keys($0).0 } }
    private var states: [UInt32] { notify.map { portal.keys($0).1 } }
    private func session() throws -> String { try XCTUnwrap(portal.sessionOwners.keys.first) }

    func testLazySetupGrantTokenRotationSameConnectionAndSessionReuse() throws {
        XCTAssertTrue(portal.calls.isEmpty)
        let original = try XCTUnwrap(PortalRestoreToken("saved-fixture"))
        try store.save(original)
        XCTAssertEqual(paste(consent: .userInitiated), .sent)
        XCTAssertEqual(portal.calls.map(\.method), ["CreateSession", "SelectDevices", "Start"])
        let select = portal.calls[1]
        XCTAssertEqual(select.signature, "(oa{sv})")
        XCTAssertEqual(try PortalSessionTestSupport.uintOption(select, "types"), 1)
        XCTAssertEqual(try PortalSessionTestSupport.uintOption(select, "persist_mode"), 2)
        XCTAssertTrue(try PortalSessionTestSupport.stringOption(select, "restore_token") == original.value)
        XCTAssertEqual(portal.calls[2].signature, "(osa{sv})")
        XCTAssertEqual(portal.text(portal.calls[2], index: 1), "x11:5678")
        XCTAssertEqual(parentCloses, 1)
        guard case .loaded(let replacement) = store.load() else { return XCTFail("Replacement token missing") }
        XCTAssertTrue(replacement.value == "rotation-one")
        XCTAssertEqual(injector.status, .ok)
        XCTAssertTrue(notify.allSatisfy { $0.signature == "(oa{sv}iu)" })
        XCTAssertEqual(Set((portal.calls + notify).map(\.sender)).count, 1)
        XCTAssertEqual(portal.propertyCalls.first?.sender, select.sender)
        XCTAssertEqual(keys, [0xffe3, 0x76, 0x76, 0xffe3])
        XCTAssertEqual(states, [1, 1, 0, 0])
        XCTAssertEqual(paste(.terminal), .sent)
        XCTAssertEqual(portal.calls.filter { $0.method == "CreateSession" }.count, 1)
        XCTAssertEqual(Array(keys.suffix(6)), [0xffe3, 0xffe1, 0x76, 0x76, 0xffe1, 0xffe3])
        XCTAssertEqual(Array(states.suffix(6)), [1, 1, 1, 0, 0, 0])
        XCTAssertFalse((portal.calls + portal.ordinaryCalls).contains { $0.method == "ConnectToEIS" })
        injector.shutdown()
        let session = try session()
        XCTAssertTrue(GTKTestSupport.spin { self.portal.closedPaths.contains(session) })
        injector = makeInjector()
        allow()
        let lastSelect = try XCTUnwrap(portal.calls.last { $0.method == "SelectDevices" })
        XCTAssertTrue(try PortalSessionTestSupport.stringOption(lastSelect, "restore_token") == replacement.value)
        guard case .loaded(let rotated) = store.load() else { return XCTFail("Rotated token missing") }
        XCTAssertTrue(rotated.value == "rotation-two")
    }

    func testAllowRecoversTokenWriteFailureWithFreshSession() throws {
        let file = LinuxPaths(environment: tools.environment).dataDirectory.appendingPathComponent("portal.json")
        // A directory blocks atomic replacement even when tests run as root.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        allow()
        let firstSession = try session()
        XCTAssertEqual(injector.status, .needsAction(fix: LinuxStrings.portalTokenWriteFailed))
        XCTAssertEqual(store.load(), .corrupt)
        XCTAssertEqual(paste(), .sent)

        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(store.load(), .absent)
        injector.probe()
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(paste(), .sent)
        XCTAssertEqual(paste(consent: .userInitiated), .sent)
        XCTAssertEqual(portal.calls.filter { $0.method == "Start" }.count, 1)
        XCTAssertFalse(portal.closedPaths.contains(firstSession))
        XCTAssertEqual(injector.status, .needsAction(fix: LinuxStrings.portalTokenWriteFailed))

        portal.handleCall = { call in
            if call.method == "CreateSession" {
                XCTAssertTrue(self.portal.closedPaths.contains(firstSession), "Close must precede replacement setup")
            }
            return false
        }
        var completions = 0
        injector.allow { completions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { completions == 1 })
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(portal.calls.map(\.method), ["CreateSession", "SelectDevices", "Start",
                                                   "CreateSession", "SelectDevices", "Start"])
        XCTAssertEqual(portal.closedPaths.filter { $0 == firstSession }.count, 1)
        XCTAssertEqual(injector.status, .ok)
        guard case .loaded(let token) = store.load() else { return XCTFail("Fresh replacement token missing") }
        XCTAssertTrue(token.value == "rotation-two")
        let select = try XCTUnwrap(portal.calls.last { $0.method == "SelectDevices" })
        XCTAssertNil(select.option("restore_token"))
        let start = try XCTUnwrap(portal.calls.last { $0.method == "Start" })
        let freshSession = portal.text(start, index: 0)
        XCTAssertNotEqual(freshSession, firstSession)
        XCTAssertEqual(paste(.terminal), .sent)
        XCTAssertTrue(notify.suffix(6).allSatisfy { portal.text($0, index: 0) == freshSession })
        XCTAssertEqual(Set((portal.calls + notify).map(\.sender)).count, 1)
        XCTAssertEqual(parentCloses, 2)

        let calls = portal.calls.count
        let closes = portal.closedPaths
        allow()
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(portal.calls.count, calls)
        XCTAssertEqual(portal.closedPaths, closes)
        XCTAssertEqual(injector.status, .ok)
    }

    func testRepeatedTokenWriteFailureStaysActionableAndUsable() throws {
        let file = LinuxPaths(environment: tools.environment).dataDirectory.appendingPathComponent("portal.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        allow()
        let firstSession = try session()
        allow()
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(portal.calls.filter { $0.method == "Start" }.count, 2)
        XCTAssertEqual(portal.closedPaths.filter { $0 == firstSession }.count, 1)
        let start = try XCTUnwrap(portal.calls.last { $0.method == "Start" })
        let freshSession = portal.text(start, index: 0)
        XCTAssertNotEqual(freshSession, firstSession)
        XCTAssertEqual(injector.status, .needsAction(fix: LinuxStrings.portalTokenWriteFailed))
        XCTAssertEqual(store.load(), .corrupt)
        XCTAssertEqual(paste(), .sent)
        XCTAssertTrue(notify.allSatisfy { portal.text($0, index: 0) == freshSession })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path),
                       ["portal.json"])
    }

    func testRecoveryAllowDoesNotInterruptPasteOrPendingSetup() throws {
        let file = LinuxPaths(environment: tools.environment).dataDirectory.appendingPathComponent("portal.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        allow()
        let firstSession = try session()
        try FileManager.default.removeItem(at: file)
        var heldKey: FakePortal.Call?
        portal.handleCall = { call in
            guard call.method == "NotifyKeyboardKeysym", self.portal.keys(call) == (0xffe3, 1) else { return false }
            heldKey = call
            return true
        }
        var results: [PasteAttemptResult] = []
        injector.paste(chord: .terminal) { results.append($0) }
        XCTAssertTrue(GTKTestSupport.spin { heldKey != nil })
        var busyCompletions = 0
        injector.allow { busyCompletions += 1 }
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(busyCompletions, 1)
        XCTAssertTrue(results.isEmpty)
        XCTAssertFalse(portal.closedPaths.contains(firstSession))
        XCTAssertEqual(portal.calls.filter { $0.method == "Start" }.count, 1)
        XCTAssertEqual(injector.status, .needsAction(fix: LinuxStrings.portalTokenWriteFailed))
        portal.reply(try XCTUnwrap(heldKey))
        XCTAssertTrue(GTKTestSupport.spin { !results.isEmpty })
        XCTAssertEqual(results, [.sent])
        XCTAssertEqual(keys, [0xffe3, 0xffe1, 0x76, 0x76, 0xffe1, 0xffe3])
        XCTAssertEqual(states, [1, 1, 1, 0, 0, 0])

        var heldStart: FakePortal.Call?
        portal.handleCall = { call in
            guard call.method == "Start" else { return false }
            heldStart = call
            return true
        }
        var recoveryCompletions = 0
        injector.allow { recoveryCompletions += 1 }
        XCTAssertTrue(GTKTestSupport.spin { heldStart != nil || recoveryCompletions > 0 })
        let start = try XCTUnwrap(heldStart, "Idle Allow must obtain a fresh token")
        let freshSession = portal.text(start, index: 0)
        XCTAssertTrue(portal.closedPaths.contains(firstSession))
        XCTAssertEqual(injector.status, .unknown)
        allow()
        XCTAssertEqual(paste(), .failed(.backendUnavailable))
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(recoveryCompletions, 0)
        XCTAssertEqual(portal.calls.filter { $0.method == "Start" }.count, 2)
        XCTAssertFalse(portal.closedPaths.contains(freshSession))
        portal.reply(start)
        portal.respond(start)
        XCTAssertTrue(GTKTestSupport.spin { recoveryCompletions == 1 })
        XCTAssertEqual(injector.status, .ok)
        XCTAssertEqual(paste(), .sent)
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(recoveryCompletions, 1)
        XCTAssertEqual(results, [.sent])
    }

    func testVersionOneOmitsPersistenceAndUnavailableKeyboardNeverCreatesSession() throws {
        portal.versions[PortalInterface.remoteDesktop.rawValue] = 1
        try store.save(XCTUnwrap(PortalRestoreToken("ignored-v1")))
        allow()
        let select = try XCTUnwrap(portal.calls.first { $0.method == "SelectDevices" })
        XCTAssertNil(select.option("persist_mode"))
        XCTAssertNil(select.option("restore_token"))
        XCTAssertEqual(paste(), .sent)
        injector.shutdown()
        injector = makeInjector()
        portal.availableDevices = 2
        let before = portal.calls.count
        allow()
        XCTAssertEqual(portal.calls.count, before)
        XCTAssertNotEqual(injector.status, .ok)
        XCTAssertEqual(paste(consent: .userInitiated), .failed(.backendUnavailable))
    }

    func testSuccessfulStartRequiresActualKeyboardAndStillSavesReplacementToken() throws {
        portal.grantedDevices = 2
        allow()
        XCTAssertNotEqual(injector.status, .ok)
        XCTAssertEqual(paste(consent: .userInitiated), .failed(.portalDenied))
        XCTAssertTrue(notify.isEmpty)
        guard case .loaded(let token) = store.load() else { return XCTFail("Replacement token missing") }
        XCTAssertTrue(token.value == "rotation-one")
        let session = try session()
        XCTAssertTrue(GTKTestSupport.spin { self.portal.closedPaths.contains(session) })
    }

    func testDeniedCancelledAndMalformedGrantCloseSessionAndCacheFailure() throws {
        for body in ["(uint32 1, @a{sv} {})", "(uint32 2, @a{sv} {})", "(uint32 0, @a{sv} {})"] {
            injector.shutdown()
            injector = makeInjector()
            portal.responses["Start"] = body
            XCTAssertNotEqual(paste(consent: .userInitiated), .sent)
            let creates = portal.calls.filter { $0.method == "CreateSession" }.count
            XCTAssertNotEqual(paste(consent: .userInitiated), .sent)
            XCTAssertEqual(portal.calls.filter { $0.method == "CreateSession" }.count, creates)
            XCTAssertTrue(notify.isEmpty)
        }
    }

    func testQuietProbeAndDiagnosticNeverStartConsentEvenWithRestoreToken() throws {
        try store.save(XCTUnwrap(PortalRestoreToken("revoked-fixture")))
        injector.probe()
        PortalSessionTestSupport.barrier(transport)
        XCTAssertNotEqual(injector.status, .ok)
        XCTAssertEqual(paste(), .failed(.backendUnavailable))
        XCTAssertTrue(portal.calls.isEmpty)
        XCTAssertTrue(notify.isEmpty)
        allow()
        XCTAssertEqual(injector.status, .ok)
    }

    func testMissingAndZeroVersionAreUnavailableWithoutConsent() throws {
        portal.versions[PortalInterface.remoteDesktop.rawValue] = 0
        allow()
        XCTAssertTrue(portal.calls.isEmpty)
        XCTAssertEqual(paste(consent: .userInitiated), .failed(.backendUnavailable))
        portal.shutdown()
        portal = try FakePortal(address: FakePortal.requirePrivateBus(), remoteDesktop: nil)
        portal.behavior = .sessions
        try portal.ownName()
        injector.shutdown()
        injector = makeInjector()
        allow()
        XCTAssertTrue(portal.calls.isEmpty)
    }

    func testSessionClosedAndPortalOwnerLossDisableReuseUntilExplicitAllow() throws {
        allow()
        let first = try session()
        portal.emit(member: "Closed", body: "(@a{sv} {},)", path: "/unrelated/session")
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(injector.status, .ok)
        portal.emit(member: "Closed", body: "(@a{sv} {},)", path: first)
        XCTAssertTrue(GTKTestSupport.spin { self.injector.status != .ok })
        XCTAssertEqual(paste(consent: .userInitiated), .failed(.backendUnavailable))
        allow()
        XCTAssertEqual(injector.status, .ok)
        portal.dropName()
        XCTAssertTrue(GTKTestSupport.spin { self.injector.status != .ok })
        XCTAssertEqual(paste(), .failed(.backendUnavailable))
    }

    func testBusLossInvalidatesAnEstablishedSession() throws {
        let daemon = try PrivatePortalDaemon()
        defer { daemon.stop() }
        let mock = try FakePortal(address: daemon.address)
        mock.behavior = .sessions
        try mock.ownName()
        defer { mock.shutdown() }
        let client = LinuxPortalTransport(busAddress: daemon.address)
        defer { client.shutdown() }
        let remote = RemoteDesktopPasteInjector(transport: client, tokens: store, session: .gnomeWayland,
            mainThread: GLibMainThread(), parent: { $0(PortalParent()) })
        defer { remote.shutdown() }
        var done = false
        remote.allow { done = true }
        XCTAssertTrue(GTKTestSupport.spin { done })
        XCTAssertEqual(remote.status, .ok)
        daemon.stop()
        XCTAssertTrue(GTKTestSupport.spin { remote.status != .ok })
        var result: PasteAttemptResult?
        remote.paste(chord: .standard) { result = $0 }
        XCTAssertTrue(GTKTestSupport.spin { result != nil })
        XCTAssertEqual(result, .failed(.backendUnavailable))
    }

    func testPartialFailureReleasesPotentiallyPressedKeysBeforeClosingAndNoLateChord() throws {
        allow()
        var held: FakePortal.Call?
        portal.handleCall = { call in
            guard call.method == "NotifyKeyboardKeysym" else { return false }
            if self.portal.keys(call) == (0x76, 1) {
                held = call
                self.portal.methodError = "org.freedesktop.portal.Error.Failed"
                self.portal.reply(call)
                self.portal.methodError = nil
                return true
            }
            return false
        }
        XCTAssertEqual(paste(.terminal), .failed(.unknown))
        XCTAssertNotNil(held)
        XCTAssertEqual(keys, [0xffe3, 0xffe1, 0x76, 0x76, 0xffe1, 0xffe3])
        XCTAssertEqual(states, [1, 1, 1, 0, 0, 0])
        let session = try session()
        XCTAssertTrue(GTKTestSupport.spin { self.portal.closedPaths.contains(session) })
        let count = notify.count
        XCTAssertEqual(paste(.terminal, consent: .userInitiated), .failed(.unknown))
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(notify.count, count)
    }

    func testChordUsesOneDeadlineAndLateReplyCannotSendRemainingDowns() throws {
        injector.shutdown()
        injector = makeInjector(callBudget: .milliseconds(100))
        allow()
        var held: FakePortal.Call?
        portal.handleCall = { call in
            guard call.method == "NotifyKeyboardKeysym", self.portal.keys(call).1 == 1 else { return false }
            if self.portal.keys(call).0 == 0xffe3 {
                self.portal.deferReply(call, kind: .method, after: 0.07)
            } else { held = call }
            return true
        }
        let began = ContinuousClock.now
        XCTAssertEqual(paste(), .failed(.timeout))
        XCTAssertLessThan(began.duration(to: .now).timeInterval, 0.3)
        let call = try XCTUnwrap(held)
        XCTAssertEqual(keys, [0xffe3, 0x76, 0x76, 0xffe3])
        XCTAssertEqual(states, [1, 1, 0, 0])
        portal.reply(call)
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(notify.count, 4)
    }

    func testSetupConsentGetsLongerTotalBudgetAndKdeLazyPathStaysShort() throws {
        injector.shutdown()
        injector = makeInjector(callBudget: .milliseconds(70), consentBudget: .milliseconds(300))
        portal.handleCall = { call in
            guard call.method == "Start" else { return false }
            self.portal.reply(call)
            self.portal.deferReply(call, kind: .response, after: 0.12)
            return true
        }
        allow()
        XCTAssertEqual(injector.status, .ok)
        injector.shutdown()
        injector = makeInjector(session: .kdeWayland, callBudget: .milliseconds(70), consentBudget: .milliseconds(300))
        XCTAssertEqual(paste(consent: .userInitiated), .failed(.timeout))
        PortalSessionTestSupport.barrier(transport)
        XCTAssertTrue(notify.isEmpty)
    }

    func testCleanupClosesSessionBeforeFallbackWhenReleaseRepliesStall() throws {
        injector.shutdown()
        injector = makeInjector(callBudget: .milliseconds(100))
        allow()
        let session = try session()
        var delayed: [FakePortal.Call] = []
        portal.handleCall = { call in
            guard call.method == "NotifyKeyboardKeysym" else { return false }
            if self.portal.keys(call) == (0x76, 1) {
                self.portal.methodError = "org.freedesktop.portal.Error.Failed"
                self.portal.reply(call)
                self.portal.methodError = nil
                return true
            }
            if self.portal.keys(call).1 == 0 { delayed.append(call); return true }
            return false
        }
        var results: [PasteAttemptResult] = []
        injector.paste(chord: .standard) { result in
            XCTAssertTrue(self.portal.closedPaths.contains(session), "Close must precede fallback")
            results.append(result)
        }
        XCTAssertTrue(GTKTestSupport.spin { !results.isEmpty })
        XCTAssertEqual(results, [.failed(.unknown)])
        XCTAssertEqual(keys, [0xffe3, 0x76, 0x76, 0xffe3])
        for call in delayed { portal.reply(call) }
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(notify.count, 4)
    }

    func testLateSuccessfulStartAfterTimeoutCannotInjectAfterFallback() throws {
        injector.shutdown()
        injector = makeInjector(session: .kdeWayland, callBudget: .milliseconds(150))
        var held: FakePortal.Call?
        portal.handleCall = { call in
            guard call.method == "Start" else { return false }
            held = call
            self.portal.reply(call)
            return true
        }
        XCTAssertEqual(paste(consent: .userInitiated), .failed(.timeout))
        let call = try XCTUnwrap(held)
        portal.respond(call)
        PortalSessionTestSupport.barrier(transport)
        XCTAssertTrue(notify.isEmpty)
        XCTAssertNotEqual(injector.status, .ok)
    }

    func testShutdownDuringPendingNotifyOnlyReleasesAndCompletesOnce() throws {
        allow()
        var held: FakePortal.Call?
        portal.handleCall = { call in
            guard call.method == "NotifyKeyboardKeysym", self.portal.keys(call).1 == 1 else { return false }
            held = call
            return true
        }
        var results: [PasteAttemptResult] = []
        injector.paste(chord: .terminal) { results.append($0) }
        XCTAssertTrue(GTKTestSupport.spin { held != nil })
        injector.shutdown()
        XCTAssertEqual(results, [.failed(.backendUnavailable)])
        portal.reply(try XCTUnwrap(held))
        PortalSessionTestSupport.barrier(transport)
        XCTAssertEqual(keys, [0xffe3, 0xffe3])
        XCTAssertEqual(states, [1, 0])
        XCTAssertEqual(results.count, 1)
    }
}
#endif
