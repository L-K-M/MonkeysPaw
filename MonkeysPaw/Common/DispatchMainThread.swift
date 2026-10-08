import Foundation
import MonkeysPawCore

/// AppKit drains the dispatch main queue; GLib requires its own Core port driver.
struct DispatchMainThread: MainThread {
    func run(_ work: @escaping () -> Void) {
        guard !Thread.isMainThread else {
            work()
            return
        }

        DispatchQueue.main.async(execute: work)
    }
}
