#if os(Linux)
import Foundation
import MonkeysPawCore

/// File work is serial and off the GTK thread. Core returns through MainThread.
final class LinuxBackgroundWork: BackgroundWork {
    private let queue = DispatchQueue(label: "ch.lkmc.monkeyspaw.prompt-editing", qos: .userInitiated)

    func run(_ work: @escaping () -> Void) { queue.async(execute: DispatchWorkItem(block: work)) }
}
#endif
