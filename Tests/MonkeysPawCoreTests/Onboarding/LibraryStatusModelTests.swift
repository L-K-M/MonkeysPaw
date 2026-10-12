import Foundation
import XCTest
import MonkeysPawCore

final class LibraryStatusModelTests: XCTestCase {
    func testStartupNotificationIsRequestedOnceUnderInlineAndQueuedDelivery() {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let main = FakeMainThread()
            main.mode = mode
            let notifier = FakeLibraryAvailabilityNotifier(main: main)
            let model = LibraryStatusModel(initialState: .unavailableAtStartup, mainThread: main,
                notifyStartupUnavailable: notifier.libraryUnavailable)
            XCTAssertEqual(model.menuLabel, "Library unavailable")
            XCTAssertTrue(model.needsLibraryFolderStep)
            XCTAssertFalse(model.libraryAvailable)
            if mode == .deferred { XCTAssertEqual(notifier.requests, 0) }
            main.drain()
            XCTAssertEqual(notifier.requests, 1)
            model.update(.unavailableAtStartup)
            model.update(.available)
            model.update(.unavailableAtStartup)
            main.drain()
            XCTAssertEqual(notifier.requests, 1)
        }
    }

    func testStartupRecoveryCanBecomeAvailableWhileRuntimeLossRequiresNewProcess() {
        let main = FakeMainThread()
        let notifier = FakeLibraryAvailabilityNotifier(main: main)
        let model = LibraryStatusModel(initialState: .unavailableAtStartup, mainThread: main,
            notifyStartupUnavailable: notifier.libraryUnavailable)
        model.update(.available)
        XCTAssertTrue(model.libraryAvailable)
        XCTAssertFalse(model.needsLibraryFolderStep)
        XCTAssertEqual(model.menuLabel, "Open Library")
        model.update(.lostWhileRunning)
        XCTAssertFalse(model.libraryAvailable)
        XCTAssertFalse(model.needsLibraryFolderStep)
        model.update(.available)
        model.update(.unavailableAtStartup)
        XCTAssertEqual(model.state, .lostWhileRunning)
        XCTAssertEqual(model.menuLabel, "Library unavailable")
        XCTAssertEqual(notifier.requests, 1)
        let restarted = LibraryStatusModel(initialState: .available, mainThread: main,
            notifyStartupUnavailable: notifier.libraryUnavailable)
        XCTAssertTrue(restarted.libraryAvailable)
    }

    func testIndependentObserversCanRemoveThemselvesAndEachOtherOutsideNotification() {
        for mode in [FakeCompletionMode.immediate, .deferred] {
            let main = FakeMainThread()
            main.mode = mode
            let model = LibraryStatusModel(initialState: .available, mainThread: main,
                notifyStartupUnavailable: {})
            var onceToken: UUID?
            var onceChanges = 0
            var menuStates: [LibraryStatusModel.State] = []
            var settingsStates: [LibraryStatusModel.State] = []
            onceToken = model.addObserver { _ in
                XCTAssertTrue(main.isRunning)
                onceChanges += 1
                if let onceToken { model.removeObserver(onceToken) }
            }
            let menuToken = model.addObserver { state in
                XCTAssertTrue(main.isRunning)
                menuStates.append(state)
            }
            let settingsToken = model.addObserver { state in
                XCTAssertTrue(main.isRunning)
                settingsStates.append(state)
            }
            model.update(.unavailableAtStartup)
            model.update(.unavailableAtStartup)
            if mode == .deferred {
                XCTAssertEqual(model.state, .available)
                XCTAssertTrue(menuStates.isEmpty)
            }
            main.drain()
            model.removeObserver(menuToken)
            model.update(.available)
            main.drain()
            model.removeObserver(settingsToken)
            model.update(.lostWhileRunning)
            main.drain()
            XCTAssertEqual(onceChanges, 1)
            XCTAssertEqual(menuStates, [.unavailableAtStartup])
            XCTAssertEqual(settingsStates, [.unavailableAtStartup, .available])
        }
    }

    func testRemovedObserverReceivesNoQueuedNotification() {
        let main = FakeMainThread()
        main.mode = .deferred
        let model = LibraryStatusModel(initialState: .available, mainThread: main,
            notifyStartupUnavailable: {})
        var changes = 0
        let token = model.addObserver { _ in changes += 1 }
        model.update(.unavailableAtStartup)
        model.removeObserver(token)
        main.drain()
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(model.state, .unavailableAtStartup)
    }

    func testRuntimeLossDoesNotRequestStartupNotificationEvenAfterLaterUpdates() {
        let main = FakeMainThread()
        let notifier = FakeLibraryAvailabilityNotifier(main: main)
        let model = LibraryStatusModel(initialState: .available, mainThread: main,
            notifyStartupUnavailable: notifier.libraryUnavailable)
        model.update(.lostWhileRunning)
        model.update(.unavailableAtStartup)
        model.update(.available)
        XCTAssertEqual(notifier.requests, 0)
        XCTAssertEqual(model.state, .lostWhileRunning)
    }

    func testNotificationRequestObservesPublishedStateAndCanReenterWithoutRepeating() {
        let main = FakeMainThread()
        var model: LibraryStatusModel?
        var requests = 0
        model = LibraryStatusModel(initialState: .available, mainThread: main,
            notifyStartupUnavailable: {
                XCTAssertTrue(main.isRunning)
                requests += 1
                model?.update(.available)
            })
        var states: [LibraryStatusModel.State] = []
        let token = model?.addObserver { health in
            XCTAssertEqual(model?.state, health)
            states.append(health)
        }
        model?.update(.unavailableAtStartup)
        model?.update(.unavailableAtStartup)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(states, [.unavailableAtStartup, .available, .unavailableAtStartup])
        if let token { model?.removeObserver(token) }
        model = nil
    }
}
