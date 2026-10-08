import AppKit
import ApplicationServices
import MonkeysPawCore

/// Activation runs on AppKit's thread; AX polling runs on a worker (§4.6).
final class WorkspaceFocusTracker: FocusTracker {
    enum RestorationMode { case dismissal, delivery }

    /// The workspace seam carries identities, never retained native applications.
    struct Source {
        let frontmost: () -> DeliveryTarget?
        let activate: (DeliveryTarget) -> Bool

        static var live: Source {
            Source(frontmost: {
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                return .macOS(processID: app.processIdentifier, bundleID: app.bundleIdentifier)
            }, activate: { target in
                guard case .macOS(let pid, let bundleID) = target,
                      let app = NSRunningApplication(processIdentifier: pid),
                      !app.isTerminated,
                      app.bundleIdentifier == bundleID else { return false }

                // Cooperative activation on macOS 14+, as in Invoque's AppActivator.
                NSApp.yieldActivation(to: app)
                return app.activate(options: [])
            })
        }
    }

    private let source: Source
    private let ownPID: Int32
    private let mainThread: MainThread
    private let scheduler: Scheduler
    private let isTrusted: () -> Bool
    private let waitForFocus: (Int32, TimeInterval) -> FocusConfirmation
    private let worker = DispatchQueue(label: "ch.lkmc.MonkeysPaw.focus", qos: .userInitiated)
    private var mode = RestorationMode.dismissal
    private var generation = 0
    private var activationObserver: NSObjectProtocol?
    private var activeRestorePID: Int32?

    init(source: Source = .live,
         ownPID: Int32 = NSRunningApplication.current.processIdentifier,
         mainThread: MainThread, scheduler: Scheduler,
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         waitForFocus: @escaping (Int32, TimeInterval) -> FocusConfirmation = {
             AccessibilityFocusWait.wait(for: $0, timeout: $1)
         }) {
        self.source = source
        self.ownPID = ownPID
        self.mainThread = mainThread
        self.scheduler = scheduler
        self.isTrusted = isTrusted
        self.waitForFocus = waitForFocus
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func startTrackingActivations() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let requestedPID = self.activeRestorePID,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != requestedPID else { return }
            self.cancelPendingRestoration()
        }
    }

    func cancelPendingRestoration() {
        generation &+= 1
        activeRestorePID = nil
    }

    func captureTarget() -> DeliveryTarget? {
        // A new summon supersedes an older activation retry, like Invoque's generation.
        cancelPendingRestoration()
        guard let target = source.frontmost(),
              case .macOS(let pid, _) = target, pid != ownPID else { return nil }
        return target
    }

    /// AppDelegate connects these modes to the panel's two hide paths.
    func prepareForRestore(_ mode: RestorationMode) {
        self.mode = mode
    }

    func restore(_ target: DeliveryTarget, completion: @escaping (FocusConfirmation) -> Void) {
        mainThread.run { [self] in
            let mode = self.mode
            self.mode = .dismissal
            guard case .macOS(let pid, _) = target, pid != ownPID else {
                completion(.unconfirmed)
                return
            }

            let origin = source.frontmost()
            if mode == .dismissal, Self.processID(of: origin) != ownPID {
                // Clicking another app is a newer choice, not a request to refocus.
                completion(.unconfirmed)
                return
            }

            generation &+= 1
            let requestGeneration = generation
            activeRestorePID = pid
            let deadline = ProcessInfo.processInfo.systemUptime + Limits.accessibilityFocusWait.timeInterval
            let trusted = isTrusted()
            // This gate and all continuations are confined to MainThread. A timeout
            // and a late AX answer cannot both complete the request.
            var didComplete = false
            let finish: (FocusConfirmation) -> Void = { confirmation in
                guard !didComplete else { return }
                didComplete = true
                if requestGeneration == self.generation { self.activeRestorePID = nil }
                completion(confirmation)
            }

            scheduler.after(Limits.accessibilityFocusWait) { finish(.unconfirmed) }
            _ = source.activate(target)

            func verifyActivation(remaining: Int) {
                scheduler.after(Limits.activationRetryDelay) {
                    guard !didComplete else { return }
                    guard requestGeneration == self.generation else {
                        finish(.unconfirmed)
                        return
                    }

                    let frontmost = self.source.frontmost()
                    if Self.processID(of: frontmost) == pid {
                        if !trusted { finish(.unconfirmed) }
                        return
                    }
                    // Never retry over a third app the user chose while activation
                    // was settling. Invoque uses the same origin check.
                    guard frontmost == origin, remaining > 0 else {
                        if !trusted { finish(.unconfirmed) }
                        return
                    }
                    _ = self.source.activate(target)
                    verifyActivation(remaining: remaining - 1)
                }
            }
            verifyActivation(remaining: Limits.activationRetryCount)

            guard trusted else { return }
            worker.async {
                let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                let result = self.waitForFocus(pid, remaining)
                self.mainThread.run {
                    guard requestGeneration == self.generation else {
                        finish(.unconfirmed)
                        return
                    }
                    finish(result)
                }
            }
        }
    }

    private static func processID(of target: DeliveryTarget?) -> Int32? {
        guard let target, case .macOS(let pid, _) = target else { return nil }
        return pid
    }
}

/// The clock/query seam tests the bounded AX wait without AX access or real sleeps.
enum AccessibilityFocusWait {
    static func wait(
        for pid: Int32, timeout: TimeInterval,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        focusedPID: (TimeInterval) -> Int32? = readFocusedPID
    ) -> FocusConfirmation {
        let deadline = now() + timeout
        while now() < deadline {
            let remaining = deadline - now()
            if focusedPID(remaining) == pid, now() < deadline { return .confirmed }
            let delay = min(Limits.accessibilityFocusPoll.timeInterval, max(0, deadline - now()))
            if delay > 0 { pause(delay) }
        }
        return .unconfirmed
    }

    private static func readFocusedPID(timeout: TimeInterval) -> Int32? {
        let systemWide = AXUIElementCreateSystemWide()
        // AX calls have their own IPC timeout; a dead target must not stall this worker.
        guard AXUIElementSetMessagingTimeout(systemWide, Float(timeout)) == .success else { return nil }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }

        var pid: pid_t = 0
        guard AXUIElementGetPid(focused as! AXUIElement, &pid) == .success else { return nil }
        return pid
    }
}
