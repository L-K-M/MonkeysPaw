import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class WindowActivationCoordinatorTests: XCTestCase {
    private var coordinators: [WindowActivationCoordinator] = []
    private var windows: [NSWindow] = []

    override func tearDown() {
        for coordinator in coordinators { coordinator.tearDown() }
        for window in windows { window.close() }
        coordinators = []
        windows = []
    }

    func testOnlyVisibleRegisteredWindowsRequireRegularPolicy() {
        var policies: [NSApplication.ActivationPolicy] = []
        var activations = 0
        let coordinator = WindowActivationCoordinator(mainThread: DispatchMainThread(),
            setPolicy: { policies.append($0) }, activate: { activations += 1 })
        coordinators.append(coordinator)
        let settings = window()
        let library = window()
        let setup = window()

        setup.orderFrontRegardless()
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: setup)
        XCTAssertEqual(policies, [], "An unregistered Setup window does not request a policy change")
        coordinator.show(settings)
        coordinator.show(library)
        XCTAssertEqual(policies, [.regular])
        XCTAssertEqual(activations, 2)
        settings.close()
        XCTAssertTrue(library.isVisible)
        XCTAssertEqual(policies, [.regular], "Closing Settings must keep a visible Library regular")
        library.orderOut(nil)
        // Deterministic delivery of the native visibility notification.
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: library)
        XCTAssertEqual(policies, [.regular, .accessory])
        XCTAssertTrue(setup.isVisible)
        coordinator.show(library)
        XCTAssertEqual(policies, [.regular, .accessory, .regular])
        library.close()
        XCTAssertEqual(policies.last, .accessory)
        coordinator.show(settings)
        XCTAssertTrue(settings.isVisible)
        XCTAssertEqual(policies.last, .regular)
        settings.close()
        XCTAssertEqual(policies.last, .accessory)
    }

    func testDeferredWindowNotificationsPruneReleasedWindowsAndRestoreAccessoryPolicy() {
        for name in [NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification] {
            let main = DeferredWindowMainThread()
            var policies: [NSApplication.ActivationPolicy] = []
            let coordinator = WindowActivationCoordinator(mainThread: main,
                setPolicy: { policies.append($0) }, activate: {})
            coordinators.append(coordinator)
            defer { coordinator.tearDown() }
            weak var releasedWindow: NSWindow?
            autoreleasepool {
                // Do not retain this window in the test fixture: this regression
                // checks that it dies before the deferred MainThread hop.
                let closing = makeWindow()
                releasedWindow = closing
                coordinator.show(closing)
                main.drain()
                XCTAssertEqual(policies.last, .regular)
                closing.close()
                NotificationCenter.default.post(name: name, object: closing)
            }
            XCTAssertNil(releasedWindow, "A queued notification must not retain its window")
            main.drain()
            XCTAssertEqual(policies, [.regular, .accessory])
        }
    }

    func testTearDownPreventsQueuedAndLaterPolicyChanges() {
        let main = DeferredWindowMainThread()
        var policies: [NSApplication.ActivationPolicy] = []
        let coordinator = WindowActivationCoordinator(mainThread: main,
            setPolicy: { policies.append($0) }, activate: {})
        coordinators.append(coordinator)
        let settings = window()
        coordinator.show(settings)
        main.drain()
        XCTAssertEqual(policies, [.regular])

        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: settings)
        coordinator.tearDown()
        settings.close()
        coordinator.tearDown()
        main.drain()
        XCTAssertEqual(policies, [.regular], "A retained coordinator must ignore notifications after teardown")
    }

    private func window() -> NSWindow {
        let window = makeWindow()
        windows.append(window)
        return window
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

private final class DeferredWindowMainThread: MainThread {
    private var pending: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { pending.append(work) }
    func drain() { while !pending.isEmpty { pending.removeFirst()() } }
}
