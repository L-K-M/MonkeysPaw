import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class AppDelegateTests: XCTestCase {
    func testHostedLaunchBuildsGraphWithoutWindowsOrNativeHotkeys() throws {
        XCTAssertTrue(AppDelegate.isRunningTests)
        let windows = NSApp.windows.map(ObjectIdentifier.init)
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

        XCTAssertNotNil(delegate.panelModel)
        let model = try XCTUnwrap(delegate.setupModel)
        XCTAssertEqual(model.session, .macOS)
        XCTAssertEqual(model.rows.first(where: { $0.kind == .hotkey })?.registration?.status, .unbound)
        XCTAssertEqual(NSApp.windows.map(ObjectIdentifier.init), windows)
    }

    func testAutomationFallbackHasUsageDescriptionInHostedApp() {
        let description = Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String
        XCTAssertFalse(description?.isEmpty ?? true)
    }

    func testOpeningSetupDoesNotActivateTheCapturedApp() throws {
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        }
        let ownPID = NSRunningApplication.current.processIdentifier
        let target = DeliveryTarget.macOS(processID: ownPID + 1, bundleID: "test.external")
        let scheduler = SetupScheduler()
        var frontmost: DeliveryTarget? = target
        var activations: [DeliveryTarget] = []
        var panelController: PanelController?
        var keyWindowReads = 0
        let delegate = AppDelegate(makeFocusTracker: { mainThread, scheduler in
            WorkspaceFocusTracker(
                source: .init(frontmost: { frontmost }, activate: {
                    activations.append($0)
                    frontmost = $0
                    return true
                }),
                ownPID: ownPID, mainThread: mainThread, scheduler: scheduler,
                isTrusted: { false }, deactivateIfUnused: {})
        }, scheduler: scheduler, makePanelController: { mainThread, scheduler, log in
            let controller = PanelController(mainThread: mainThread, scheduler: scheduler, log: log,
                                             keyWindow: {
                // Native focus has not settled. The cancellation must honor the
                // Setup intent even when no key window can be observed.
                keyWindowReads += 1
                return nil
            })
            panelController = controller
            return controller
        })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let model = try XCTUnwrap(delegate.panelModel)
        model.show()
        let controller = try XCTUnwrap(panelController)
        XCTAssertTrue(controller.isVisible)
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? PromptPanel }.first {
            !originalWindows.contains(ObjectIdentifier($0))
        })
        frontmost = .macOS(processID: ownPID, bundleID: "test.own")

        // A native blur has queued work, but its callback has not run yet.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        XCTAssertTrue(scheduler.pending.contains { $0.0 == Limits.blurHideDelay })

        // Invoke the status-menu action without a real event or external app.
        _ = delegate.perform(Selector(("showSetup")))
        XCTAssertGreaterThan(keyWindowReads, 0)
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(activations.isEmpty, "Opening Setup must never activate the captured app")

        let mainLoopDrained = expectation(description: "Deferred native window work completes")
        DispatchQueue.main.async { mainLoopDrained.fulfill() }
        wait(for: [mainLoopDrained], timeout: 2)
        scheduler.drain()
        XCTAssertTrue(activations.isEmpty, "Deferred blur and restoration work must not activate either")

        // A second cancellation proves DeliveryService cleared the armed target.
        model.cancel()
        scheduler.drain()
        XCTAssertTrue(activations.isEmpty)

        // A fresh summon resets the owned-window intent. Ordinary Escape still
        // restores through PanelModel and DeliveryService without real keys.
        frontmost = target
        model.show()
        frontmost = .macOS(processID: ownPID, bundleID: "test.own")
        panel.cancelOperation(nil)
        scheduler.drain()
        XCTAssertEqual(activations, [target])
    }

    func testOpeningSetupPresentsNativeWindow() throws {
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        }
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        _ = delegate.perform(Selector(("showSetup")))

        // Ordering the window in is synchronous; native key status is not.
        let setup = try XCTUnwrap(NSApp.windows.first {
            !originalWindows.contains(ObjectIdentifier($0)) && $0.title == Strings.setupTitle
        })
        XCTAssertTrue(setup.isVisible)
    }
}

private final class SetupScheduler: Scheduler {
    private(set) var pending: [(Duration, () -> Void)] = []

    func after(_ delay: Duration, _ work: @escaping () -> Void) { pending.append((delay, work)) }

    func drain() {
        while !pending.isEmpty { pending.removeFirst().1() }
    }
}
