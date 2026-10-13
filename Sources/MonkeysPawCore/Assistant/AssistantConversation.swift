import Foundation

/// Session-only conversation data. Never persisted or included in diagnostics.
public struct AssistantMessage: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let content: String

    init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    var wireValue: [String: String] { ["role": role.rawValue, "content": content] }
    public var description: String { "<assistant message redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["message": description]) }
}

extension AssistantRequest {
    var userMessage: AssistantMessage {
        var content: String
        switch action {
        case .write(let brief): content = AssistantPrompts.writeData(brief: brief)
        case .review(let source): content = AssistantPrompts.reviewData(source: source)
        case .improve(let source, let instruction, let findings):
            content = AssistantPrompts.improveData(source: source, instruction: instruction, selectedFindings: findings)
        }
        if let feedback { content += "\n" + AssistantPrompts.data(feedback, tag: "feedback") }
        return AssistantMessage(role: .user, content: content)
    }

    var messages: [AssistantMessage] { transcript + [userMessage] }

    /// Some compatible chat templates require alternating roles. Keep the
    /// session transcript intact and combine adjacent turns only for transport.
    var wireMessages: [AssistantMessage] {
        var turns: [AssistantMessage] = []
        for message in messages {
            if let last = turns.last, last.role == message.role {
                turns[turns.count - 1] = AssistantMessage(role: message.role,
                    content: last.content + "\n\n" + message.content)
            } else { turns.append(message) }
        }
        return turns
    }
}

extension AssistantResponse {
    /// Reconstruct the strict output shape, including notes but no quote ranges.
    /// Retry retains the complete conversation, rather than replacing the brief.
    func transcriptMessage() throws -> AssistantMessage {
        let object: [String: Any]
        switch output {
        case .artifact(let artifact):
            object = ["title": artifact.title, "description": artifact.description, "tags": artifact.tags,
                "body": artifact.body, "notes": artifact.notes, "fields": artifact.fields.map {
                    ["name": $0.name, "type": $0.type.rawValue, "label": $0.label,
                     "description": $0.description, "default": $0.defaultValue,
                     "optional": $0.optional, "remember": $0.remember,
                     "options": $0.options.map { ["label": $0.label, "value": $0.value] }] as [String: Any]
                }]
        case .review(let review):
            object = ["summary": review.summary, "findings": review.findings.map {
                ["severity": $0.severity.rawValue, "criterion": $0.criterion.rawValue,
                 "quote": $0.quote, "problem": $0.problem, "suggestion": $0.suggestion]
            }]
        }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return AssistantMessage(role: .assistant, content: String(decoding: bytes, as: UTF8.self))
    }
}
