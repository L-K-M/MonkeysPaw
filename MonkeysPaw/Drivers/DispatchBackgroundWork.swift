import Foundation
import MonkeysPawCore

/// One serial worker per library graph; Core returns replies through MainThread.
final class DispatchBackgroundWork: BackgroundWork {
    private let queue = DispatchQueue(label: "ch.lkmc.monkeyspaw.prompt-editing", qos: .userInitiated)

    func run(_ work: @escaping () -> Void) { queue.async(execute: work) }
}
