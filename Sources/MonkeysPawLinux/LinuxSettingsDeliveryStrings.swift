#if os(Linux)
import MonkeysPawCore

enum LinuxSettingsDeliveryStrings {
    static let explicitChoices = "Ctrl+Shift+Return: Terminal (Ctrl+Shift+V). In Fill, Ctrl+Return: Standard (Ctrl+V). Alt+Return: Copy."
    static let restoreOwnership = "Restore skips newer clipboard copies, including identical text. A simultaneous external copy cannot be excluded by the operating system."

    static func status(_ snapshot: DeliveryStatusSnapshot?) -> String {
        guard let snapshot else { return "Reading delivery status…" }
        var rows = ["Paste order: " + snapshot.pasteLadder.map(\.rawValue).joined(separator: " → ") + " → Copy"]
        rows += snapshot.cachedFailures.map { "\($0.backend.rawValue): \($0.reason.rawValue) (unavailable until Test paste)" }
        if let receipt = snapshot.lastDelivery {
            switch receipt.outcome {
            case .pasted(let backend): rows.append("Last delivery: \(backend.rawValue) sent events; receipt is unconfirmed.")
            case .copiedOnly: rows.append("Last delivery: copied only.")
            }
        }
        return rows.joined(separator: "\n")
    }

    static func permission(_ row: SetupRow) -> String {
        let detail: String
        switch row.status {
        case .ok: detail = LinuxStrings.ready
        case .unknown: detail = LinuxStrings.unknown
        case .notApplicable: detail = LinuxStrings.notApplicable
        case .needsAction(let message): detail = message
        }
        return LinuxStrings.rowTitle(row.kind) + ": " + detail
    }

    static func report(_ report: SelfTestReport) -> String {
        report.results.map { item in
            let detail: String
            switch item.status {
            case .pasted: detail = "pasted (readback verified)"
            case .sentButNotReceived: detail = "sent, but text was not received"
            case .failed(let reason): detail = reason.rawValue
            }
            return item.backend.rawValue + ": " + detail
        }.joined(separator: "\n")
    }
}
#endif
