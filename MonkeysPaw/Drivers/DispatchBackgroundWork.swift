import Foundation
import MonkeysPawCore

/// Serial file work; each library service returns replies through MainThread.
final class DispatchBackgroundWork: BackgroundWork {
    private let queue = DispatchQueue(label: "ch.lkmc.monkeyspaw.prompt-editing", qos: .userInitiated)

    func run(_ work: @escaping () -> Void) { queue.async(execute: DispatchWorkItem(block: work)) }
}
