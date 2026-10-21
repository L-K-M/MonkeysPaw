import MonkeysPawCore

enum SettingsDeliveryStrings {
    static let pasteChord = "⌘V"
    static let restoreOwnership = "Restore skips newer clipboard copies, including identical text. A simultaneous external copy cannot be excluded by the operating system."

    static func status(_ snapshot: DeliveryStatusSnapshot?) -> String {
        guard let snapshot else { return "Reading delivery status…" }
        let order = snapshot.pasteLadder.map(Strings.backend).joined(separator: " → ")
        var rows = ["Paste order: " + order + " → Copy"]
        rows += snapshot.cachedFailures.map {
            "\(Strings.backend($0.backend)): \($0.reason.rawValue) (unavailable until Test paste)"
        }
        if let receipt = snapshot.lastDelivery {
            switch receipt.outcome {
            case .pasted(let backend):
                rows.append("Last delivery: \(Strings.backend(backend)) sent events; receipt is unconfirmed.")
            case .copiedOnly: rows.append("Last delivery: copied only.")
            }
        }
        return rows.joined(separator: "\n")
    }

    static func permission(_ row: SetupRow) -> String {
        Strings.rowTitle(row.kind) + ": " + Strings.status(row.status)
    }

    static func automation(_ state: DeliverySettingsModel.State) -> String {
        let prefix = "Automation (System Events): "
        if let failure = state.delivery?.cachedFailures.first(where: { $0.backend == .appleScript }) {
            return prefix + Strings.selfTestStatus(.failed(failure.reason)) + " (unavailable until Test paste)"
        }
        if case .tested(let report) = state.test,
           let result = report.results.first(where: { $0.backend == .appleScript }) {
            return prefix + Strings.selfTestStatus(result.status)
        }
        return prefix + "unknown; permission is requested only when the fallback runs."
    }

    static func test(_ state: DeliverySettingsModel.TestState) -> String? {
        switch state {
        case .idle: return nil
        case .testing: return Strings.testing
        case .tested(let report):
            return report.results.map { item in
                let detail: String
                switch item.status {
                case .pasted: detail = "pasted (readback verified)"
                case .sentButNotReceived: detail = "sent, but text was not received"
                case .failed(let reason): detail = reason.rawValue
                }
                return Strings.backend(item.backend) + ": " + detail
            }.joined(separator: "\n")
        }
    }
}
