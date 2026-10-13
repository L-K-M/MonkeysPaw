#if os(Linux)
import CGtk
import Foundation
import Glibc
import MonkeysPawCore

/// Test diagnostics only. Call on the GLib thread with fixed labels and safe
/// lifecycle metadata, never model descriptions (which can contain user text).
enum LinuxPickerTrace {
    static let isEnabled = ProcessInfo.processInfo.environment["MONKEYSPAW_TEST_PICKER_TRACE"] == "1"
    private static var sequence = 0

    static func record(_ event: StaticString, _ details: @autoclosure () -> String = "") {
        guard isEnabled else { return }
        sequence += 1
        let line = "[picker-trace] pid=\(getpid()) seq=\(sequence) us=\(g_get_monotonic_time()) \(event) \(details())\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }

    static func pickerState(_ state: PickerModel.State?) -> String {
        switch state {
        case .picker: return "picker"
        case .fill: return "fill"
        case .delivering: return "delivering"
        case .done: return "done"
        case .closed: return "closed"
        case nil: return "unbound"
        }
    }
}
#endif
