import Foundation
import MonkeysPawCore

/// Chrome strings introduced by the native split-view Library redesign.
/// Existing copy stays in the feature Strings files it was shared with.
enum LibraryNativeStrings {
    static let newPromptToolbar = "New Prompt"
    static let noFields = "No Fields"
    static let noPromptSelected = "No Prompt Selected"
    static let compare = "Compare"
    static let assistantUnavailable = "Assistant is unavailable."
    static let promptInfo = "Prompt"
    static let titleLabel = "Title"
    static let fileLabel = "File"
    static let tagsLabel = "Tags"
    static let statusLabel = "Status"
    static let ready = "Ready"
    static let labelLabel = "Label"
    static let kindLabel = "Kind"
    static let descriptionLabel = "Description"
    static let none = "None"

    static func issueCount(_ count: Int) -> String {
        "\(count) " + (count == 1 ? "issue" : "issues")
    }

    static func errorCount(_ count: Int) -> String {
        "\(count) " + (count == 1 ? "error" : "errors")
    }
}
