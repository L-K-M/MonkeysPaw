import Foundation

/// Local app-data metadata only. Content, instructions and credentials never
/// belong in this value; sync revision origins are a separate contract.
public struct PromptProvenance: Equatable, Sendable {
    public enum Origin: String, Sendable { case llm }

    public let origin: Origin
    public let timestamp: Date
    public let providerHost: String
    public let model: String
    public let usage: AssistantTokenUsage?

    init(timestamp: Date, providerHost: String, model: String, usage: AssistantTokenUsage?) {
        origin = .llm
        self.timestamp = timestamp
        self.providerHost = providerHost
        self.model = model
        self.usage = usage
    }
}
