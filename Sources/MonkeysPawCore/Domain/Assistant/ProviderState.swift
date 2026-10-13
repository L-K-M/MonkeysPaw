import Foundation

/// Each transition consumes one probe; there are at most two in an action.
enum OpenAIResponseFormat: String, Codable, Sendable {
    case jsonSchema = "json_schema"
    case jsonObject = "json_object"
    case none

    var lower: OpenAIResponseFormat? {
        switch self {
        case .jsonSchema: return .jsonObject
        case .jsonObject: return OpenAIResponseFormat.none
        case .none: return nil
        }
    }
}
