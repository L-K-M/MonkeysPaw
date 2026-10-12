import AppKit
import MonkeysPawCore

/// Settings and, later, Library share this policy. Setup is never registered.
final class WindowActivationCoordinator {
    private final class WindowReference {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    private let mainThread: MainThread
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void
    private let activate: () -> Void
    private var windows: [ObjectIdentifier: WindowReference] = [:]
    private var observers: [NSObjectProtocol] = []
    private var appliedPolicy: NSApplication.ActivationPolicy?

    init(mainThread: MainThread,
         setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void,
         activate: @escaping () -> Void) {
        self.mainThread = mainThread
        self.setPolicy = setPolicy
        self.activate = activate
        for name in [NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                // Copy only the name: retaining Notification across a deferred
                // MainThread hop would also retain its window object.
                let name = notification.name
                self?.mainThread.run { [weak self, weak window] in
                    guard let self else { return }
                    // willClose precedes orderOut, so exclude the closing window
                    // before inspecting visibility. Reopening registers it again.
                    if name == NSWindow.willCloseNotification, let window {
                        self.windows.removeValue(forKey: ObjectIdentifier(window))
                    }
                    // A closed window may have died before this hop. Always
                    // prune weak registrations and recompute the shared policy.
                    self.updatePolicy()
                }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func show(_ window: NSWindow) {
        mainThread.run { [weak self, weak window] in
            guard let self, let window else { return }
            self.windows[ObjectIdentifier(window)] = WindowReference(window)
            // Ordering front does not restore a window you minimized to the Dock.
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            self.updatePolicy()
            self.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func updatePolicy() {
        windows = windows.filter { $0.value.window != nil }
        let policy: NSApplication.ActivationPolicy = windows.values.contains { $0.window?.isVisible == true }
            ? .regular : .accessory
        guard policy != appliedPolicy else { return }
        appliedPolicy = policy
        setPolicy(policy)
    }
}
