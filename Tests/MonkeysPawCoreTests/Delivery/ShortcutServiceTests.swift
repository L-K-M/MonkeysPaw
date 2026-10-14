import MonkeysPawCore
import XCTest

final class ShortcutServiceTests: XCTestCase {
    func testReentrantConfigurationFromReplacementCompletionIsApplied() throws {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let h = DeliveryHarness()
            h.main.mode = mode
            let backend = FakeHotkeyBackend()
            backend.mechanism = .carbon
            let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
            var oldFires: [HotkeyAction] = []
            var newFires: [HotkeyAction] = []
            service.configure([.togglePicker: try Accelerator("Alt+P")]) { oldFires.append($0) }
            h.main.drain()
            let next: [HotkeyAction: Accelerator] = [.togglePicker: try Accelerator("Alt+F8"), .repeatLast: try Accelerator("Alt+F9")]
            var completions = 0

            service.setPickerAccelerator("Alt+E") { result in
                completions += 1
                if case .failure = result { XCTFail("Replacement failed") }
                service.configure(next) { newFires.append($0) }
            }
            h.main.drain()

            XCTAssertEqual(completions, 1)
            XCTAssertEqual(backend.registered.suffix(2).map(\.1), [next[.togglePicker], next[.repeatLast]])
            backend.fire()
            backend.fire(.repeatLast)
            h.main.drain()
            XCTAssertTrue(oldFires.isEmpty)
            XCTAssertEqual(newFires, [.togglePicker, .repeatLast])
        }
    }

    func testConfigurationsDuringNativeReplacementCoalesceToLastRequest() throws {
        let h = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        backend.mechanism = .carbon
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        var oldFires = 0
        var supersededFires = 0
        var latestFires: [HotkeyAction] = []
        service.configure([.togglePicker: try Accelerator("Alt+P")]) { _ in oldFires += 1 }
        let superseded: [HotkeyAction: Accelerator] = [.togglePicker: try Accelerator("Alt+F7")]
        let latest: [HotkeyAction: Accelerator] = [.togglePicker: try Accelerator("Alt+F8"), .repeatLast: try Accelerator("Alt+F9")]
        let registrations = backend.registered.count
        backend.onRegister = {
            backend.onRegister = nil
            service.configure(superseded) { _ in supersededFires += 1 }
            service.configure(latest) { latestFires.append($0) }
            XCTAssertEqual(backend.registered.count, registrations + 1)
        }
        var completions = 0

        service.setPickerAccelerator("Alt+E") { result in
            completions += 1
            if case .failure = result { XCTFail("Replacement failed") }
        }

        XCTAssertEqual(completions, 1)
        XCTAssertEqual(backend.registered.count, registrations + 3)
        XCTAssertEqual(backend.registered.suffix(2).map(\.1), [latest[.togglePicker], latest[.repeatLast]])
        backend.fire()
        backend.fire(.repeatLast)
        XCTAssertEqual(oldFires, 0)
        XCTAssertEqual(supersededFires, 0)
        XCTAssertEqual(latestFires, [.togglePicker, .repeatLast])
    }

    func testReentrantConfigurationFromObserverAndRejectedReplacementIsApplied() throws {
        for reject in [false, true] {
            let h = DeliveryHarness()
            let backend = FakeHotkeyBackend()
            backend.mechanism = .carbon
            let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
            var oldFires = 0
            var newFires = 0
            service.configure([.togglePicker: try Accelerator("Alt+P"), .repeatLast: try Accelerator("Alt+R")]) { _ in oldFires += 1 }
            let next: [HotkeyAction: Accelerator] = [.togglePicker: try Accelerator("Alt+F8")]
            var requested = false
            if !reject {
                service.addObserver {
                    guard !requested else { return }
                    requested = true
                    service.configure(next) { _ in newFires += 1 }
                }
            }
            var completions = 0

            service.setPickerAccelerator(reject ? "Alt+R" : "Alt+E") { result in
                completions += 1
                if reject {
                    XCTAssertEqual(result, .failure(.collision(.repeatLast)))
                    service.configure(next) { _ in newFires += 1 }
                } else if case .failure = result { XCTFail("Replacement failed") }
            }

            XCTAssertEqual(completions, 1)
            XCTAssertEqual(backend.registered.suffix(2).map(\.1), [next[.togglePicker], nil])
            backend.fire()
            XCTAssertEqual(oldFires, 0)
            XCTAssertEqual(newFires, 1)
        }
    }

    func testUnboundRepeatStillHasABackendCallbackCatalogueEntry() throws {
        let h = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in }

        XCTAssertEqual(backend.registered.map(\.0), HotkeyAction.allCases)
        XCTAssertNotNil(backend.callbacks[.repeatLast])
        XCTAssertEqual(service.registrations[.repeatLast]?.status, .unbound)
        XCTAssertNotEqual(service.registrations[.repeatLast]?.id, service.registrations[.togglePicker]?.id)
    }

    func testRebindingPickerPreservesRepeatIdentityProofAndCallback() throws {
        let h = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        backend.mechanism = .carbon
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        var fires: [HotkeyAction] = []
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P"),
                           .repeatLast: try Accelerator("Ctrl+Alt+R")]) { fires.append($0) }
        let repeatRegistration = service.registrations[.repeatLast]
        let repeatFire = try XCTUnwrap(backend.callbacks[.repeatLast])
        service.beginVerification(.repeatLast)
        repeatFire()
        h.scheduler.advance(by: Limits.toggleDebounce)

        service.setPickerAccelerator("Ctrl+Alt+E") { _ in }

        XCTAssertEqual(service.registrations[.repeatLast], repeatRegistration)
        XCTAssertEqual(service.verification(for: .repeatLast), .verified)
        repeatFire()
        XCTAssertEqual(fires, [.repeatLast, .repeatLast])
    }

    func testFailedNativeReplacementRecoversPreviousCarbonBinding() throws {
        let h = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        backend.mechanism = .carbon
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        let previous = try Accelerator("Ctrl+Alt+P")
        service.configure([.togglePicker: previous]) { _ in }
        backend.registrationOutcomes = [.failed, .registered]
        var result: Result<HotkeyRegistration, ShortcutRebindError>?

        service.setPickerAccelerator("Alt+F8") { result = $0 }

        XCTAssertEqual(backend.registered.count, 4)
        XCTAssertEqual(backend.unregistered.count, 2)
        XCTAssertTrue(backend.registrationOutcomes.isEmpty)
        XCTAssertEqual(result, .failure(.registrationFailed))
        XCTAssertEqual(service.registrations[.togglePicker]?.status, .registered)
        XCTAssertEqual(backend.registered.last?.1, previous)
    }
    func testFailedRegistrationCannotBeginVerification() throws {
        let h = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        backend.status = .failed
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in }
        var changes = 0
        service.addObserver { changes += 1 }

        service.beginVerification()

        XCTAssertEqual(service.verification(for: .togglePicker), .notStarted)
        XCTAssertEqual(changes, 0)
    }

    func testCarbonRebindWithoutConfiguredActivationHandlerReportsUnavailable() {
        let h = DeliveryHarness()
        h.main.mode = .deferred
        let backend = FakeHotkeyBackend()
        backend.mechanism = .carbon
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        var results: [Result<HotkeyRegistration, ShortcutRebindError>] = []

        service.setPickerAccelerator("Ctrl+Alt+P") {
            results.append($0)
            XCTAssertTrue(h.main.isRunning)
        }
        XCTAssertTrue(results.isEmpty)
        h.main.drain()

        XCTAssertEqual(results, [.failure(.unavailable)])
        XCTAssertTrue(backend.registered.isEmpty)
    }

    func testObserverRemovalLeavesOtherSubscriptionsActiveOnMainThread() throws {
        let h = DeliveryHarness()
        h.main.mode = .deferred
        let backend = FakeHotkeyBackend()
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        var firstChanges = 0
        var secondChanges = 0
        let first = service.addObserver { firstChanges += 1; XCTAssertTrue(h.main.isRunning) }
        let second = service.addObserver { secondChanges += 1; XCTAssertTrue(h.main.isRunning) }
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in }
        XCTAssertEqual(firstChanges, 0)
        XCTAssertEqual(secondChanges, 0)
        h.main.drain()
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 1)

        service.removeObserver(first)
        service.beginVerification()
        h.main.drain()
        backend.fire()
        h.main.drain()
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 3)

        service.configure([:]) { _ in }
        h.main.drain()
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 4)
        XCTAssertEqual(backend.currentRegistrations.count, 2)
        XCTAssertTrue(backend.currentRegistrations.values.allSatisfy { $0.status == .unbound })
        service.removeObserver(second)
        h.main.drain()
    }

    func testRemovingAnAlreadyRemovedObserverIsANoOp() throws {
        let h = DeliveryHarness()
        h.main.mode = .deferred
        let backend = FakeHotkeyBackend()
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        var firstChanges = 0
        var secondChanges = 0
        let first = service.addObserver { firstChanges += 1; XCTAssertTrue(h.main.isRunning) }
        service.addObserver { secondChanges += 1; XCTAssertTrue(h.main.isRunning) }
        service.removeObserver(first)
        h.main.drain()

        service.removeObserver(first)
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in }
        h.main.drain()

        XCTAssertEqual(firstChanges, 0)
        XCTAssertEqual(secondChanges, 1)
    }

    func testObserverCanRemoveItselfDuringNotification() throws {
        let h = DeliveryHarness()
        let backend = FakeHotkeyBackend()
        let service = ShortcutService(backend: backend, scheduler: h.scheduler, mainThread: h.main)
        var changes = 0
        var token: UUID?
        token = service.addObserver {
            changes += 1
            if let token { service.removeObserver(token) }
        }
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+P")]) { _ in }
        service.beginVerification()
        backend.fire()
        XCTAssertEqual(changes, 1)
    }

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

        XCTAssertEqual(backend.registered.count, 2)
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
        service.addObserver { changes += 1; XCTAssertTrue(h.main.isRunning) }
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
        let unboundRepeat = try XCTUnwrap(service.registrations[.repeatLast])
        let staleFire = try XCTUnwrap(backend.callbacks[.togglePicker])
        service.beginVerification()
        backend.fire()
        service.configure([.togglePicker: try Accelerator("Ctrl+Alt+E")]) { _ in fires += 1 }
        XCTAssertEqual(backend.unregistered, [first, unboundRepeat])
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
        XCTAssertEqual(fires, [.togglePicker, .repeatLast])
        h.scheduler.advance(by: .milliseconds(1))
        backend.fire()
        XCTAssertEqual(fires.last, .togglePicker)
        XCTAssertEqual(fires.count, 3)
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
