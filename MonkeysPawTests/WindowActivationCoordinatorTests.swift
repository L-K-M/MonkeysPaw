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
        XCTAssertTrue(policies.isEmpty, "An unregistered Setup window cannot change policy")
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

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
