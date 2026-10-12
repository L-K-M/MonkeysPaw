import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class WindowActivationCoordinatorTests: XCTestCase {
    func testOnlyVisibleRegisteredWindowsRequireRegularPolicy() {
        var policies: [NSApplication.ActivationPolicy] = []
        var activations = 0
        let coordinator = WindowActivationCoordinator(mainThread: DispatchMainThread(),
            setPolicy: { policies.append($0) }, activate: { activations += 1 })
        let settings = window()
        let library = window()
        let setup = window()
        defer { settings.close(); library.close(); setup.close() }

        setup.orderFrontRegardless()
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: setup)
        XCTAssertEqual(policies, [.accessory], "An unregistered Setup window keeps accessory policy")
        coordinator.show(settings)
        coordinator.show(library)
        XCTAssertEqual(policies, [.accessory, .regular])
        XCTAssertEqual(activations, 2)
        settings.close()
        XCTAssertTrue(library.isVisible)
        XCTAssertEqual(policies, [.accessory, .regular], "Closing Settings must keep a visible Library regular")
        library.orderOut(nil)
        // Deterministic delivery of the native visibility notification.
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: library)
        XCTAssertEqual(policies, [.accessory, .regular, .accessory])
        XCTAssertTrue(setup.isVisible)
        coordinator.show(library)
        XCTAssertEqual(policies, [.accessory, .regular, .accessory, .regular])
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
            weak var releasedWindow: NSWindow?
            autoreleasepool {
                let closing = window()
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

    private func window() -> NSWindow {
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
