import Foundation
import MonkeysPawCore

struct DispatchScheduler: Scheduler {
    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay.timeInterval, execute: work)
    }
}
