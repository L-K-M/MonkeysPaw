import MonkeysPawCore
import XCTest

final class ShortcutServiceTests: XCTestCase {
    func testNewSessionRevisionRejectsQueuedProofFromTheSameMechanism() throws {
        let h = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        backend.activationRevision = UUID()
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        var fires = 0
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in fires += 1 }
        service.beginVerification()
        h.main.mode = .deferred
        backend.fire()
        backend.activationRevision = UUID()
        h.main.drain()
        XCTAssertEqual(fires, 0)
        XCTAssertEqual(service.verification(for: .togglePicker), .notStarted)
        service.beginVerification()
        h.main.drain()
        backend.fire()
        h.main.drain()
        XCTAssertEqual(fires, 1)
        XCTAssertEqual(service.verification(for: .togglePicker), .verified)
    }

    func testMechanismChangeInvalidatesVerificationAndQueuedActivation() throws {
        let h = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        backend.mechanism = .kglobalaccel
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        var fires = 0
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in fires += 1 }
        service.beginVerification()
        backend.fire()
        XCTAssertEqual(service.verification(for: .togglePicker), .verified)
        h.scheduler.advance(by: .milliseconds(100))
        h.main.mode = .deferred
        backend.fire()
        backend.mechanism = .globalShortcutsPortal
        XCTAssertEqual(service.verification(for: .togglePicker), .notStarted)
        h.main.drain()
        XCTAssertEqual(fires, 1)
    }

    func testRegistersConfiguredAcceleratorsAndExposesMechanismAndDetails() throws {
        let h = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        let accelerator = try Accelerator("Ctrl+Alt+P")
        service.configure([.togglePicker: accelerator]) { _ in }

        XCTAssertEqual(backend.registered.count, 1)
        XCTAssertEqual(backend.registered.first?.0, .togglePicker)
        XCTAssertEqual(backend.registered.first?.1, accelerator)
        XCTAssertEqual(service.registrations[.togglePicker]?.mechanism, .globalShortcutsPortal)
        XCTAssertEqual(service.registrations[.togglePicker]?.status, .registered)
        XCTAssertEqual(service.registrations[.togglePicker]?.detail, backend.detail)
        XCTAssertEqual(service.registrations[.repeatLast]?.status, .unbound)
    }

    func testOnlyAnActivationAfterBeginVerificationVerifiesTheAction() throws {
        let h = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        var changes = 0
        service.onChange = { changes += 1; XCTAssertTrue(h.main.isRunning) }
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in }
        backend.fire()
        XCTAssertEqual(service.verification(for: .togglePicker), .notStarted)
        service.beginVerification()
        XCTAssertEqual(service.verification(for: .togglePicker), .waiting)
        backend.fire()
        XCTAssertEqual(service.verification(for: .togglePicker), .verified)
        XCTAssertEqual(service.verification(for: .repeatLast), .notStarted)
        XCTAssertEqual(changes, 3)
    }

    func testVerificationIsPerActionAndDoesNotVerifyUnboundActions() throws {
        let h = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in }
        service.beginVerification(.repeatLast)
        XCTAssertEqual(service.verification(for: .repeatLast), .notStarted)
        service.beginVerification()
        backend.fire(.repeatLast)
        XCTAssertEqual(service.verification(for: .togglePicker), .waiting)
    }

    func testReconfigurationUnregistersAndInvalidatesOldCallbacksAndVerification() throws {
        let h = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        var fires = 0
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in fires += 1 }
        let first = try XCTUnwrap(service.registrations[.togglePicker])
        let staleFire = try XCTUnwrap(backend.callbacks[.togglePicker])
        service.beginVerification()
        backend.fire()
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+E")]) { _ in fires += 1 }
        XCTAssertEqual(backend.unregistered, [first])
        XCTAssertEqual(service.verification(for: .togglePicker), .notStarted)
        service.beginVerification()
        staleFire()
        XCTAssertEqual(service.verification(for: .togglePicker), .waiting)
        XCTAssertEqual(fires, 1)
        backend.fire()
        XCTAssertEqual(service.verification(for: .togglePicker), .verified)
        XCTAssertEqual(fires, 2)
    }

    func testToggleDebounceUses100MillisecondsWhileRepeatIsIndependent() throws {
        let h = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        var fires: [HotkeyAction] = []
        service.configure([
            .togglePicker: try Accelerator("Ctrl+Alt+P"), .repeatLast: try Accelerator("Ctrl+Alt+R"),
        ]) { fires.append($0) }
        backend.fire()
        backend.fire()
        backend.fire(.repeatLast)
        backend.fire(.repeatLast)
        h.scheduler.advance(by: .milliseconds(99))
        backend.fire()
        XCTAssertEqual(fires, [.togglePicker, .repeatLast, .repeatLast])
        h.scheduler.advance(by: .milliseconds(1))
        backend.fire()
        XCTAssertEqual(fires.last, .togglePicker)
        XCTAssertEqual(fires.count, 4)
    }

    func testWorkerActivationIsMarshalledOntoMainThread() throws {
        let h = DeliveryHarness()
        h.main.mode = .deferred
        let backend = FakeHotkeyBackend()
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        var fired = false
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in
            XCTAssertTrue(h.main.isRunning)
            fired = true
        }
        h.main.drain()
        service.beginVerification()
        h.main.drain()
        backend.fire()
        XCTAssertFalse(fired)
        XCTAssertEqual(service.verification(for: .togglePicker), .waiting)
        h.main.drain()
        XCTAssertTrue(fired)
        XCTAssertEqual(service.verification(for: .togglePicker), .verified)
    }
}
