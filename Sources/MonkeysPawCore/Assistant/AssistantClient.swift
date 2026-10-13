import Foundation

/// User intent and its immutable template snapshot; never filled field values.
public enum AssistantAction: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    case write(brief: String)
    case review(source: String)
    case improve(source: String, instruction: String, selectedFindings: [LlmReview.Finding])

    public var description: String { "<assistant action redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["action": description]) }
}

public enum AssistantEffort: String, CaseIterable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max
}

public struct AssistantRequest: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let action: AssistantAction
    public let effort: AssistantEffort?

    public init(action: AssistantAction, effort: AssistantEffort? = nil) {
        self.action = action
        self.effort = effort
    }

    public var description: String { "<assistant request redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["request": description]) }
}

public enum AssistantOutput: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    case artifact(LlmArtifact)
    case review(LlmReview)

    public var description: String { "<assistant output redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["output": description]) }
}

public struct AssistantTokenUsage: Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct AssistantResponse: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let output: AssistantOutput
    public let usage: AssistantTokenUsage?

    public init(output: AssistantOutput, usage: AssistantTokenUsage? = nil) {
        self.output = output
        self.usage = usage
    }

    public var description: String { "<assistant response redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["response": description]) }
}

/// A8 owns pagination policy; a client decodes one model-list page per call.
public struct AssistantModelPage: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let models: [ModelDescriptor]
    public let hasMore: Bool
    public let firstID: String?
    public let lastID: String?

    public init(models: [ModelDescriptor], hasMore: Bool = false,
                firstID: String? = nil, lastID: String? = nil) {
        self.models = models
        self.hasMore = hasMore
        self.firstID = firstID
        self.lastID = lastID
    }

    public var description: String { "<assistant model page redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["page": description]) }
}

/// Protocol clients return strictly decoded values or body-free AssistantError.
/// Transport cancellation/deadlines apply to each single-shot operation.
public protocol AssistantClient: Sendable {
    func perform(_ request: AssistantRequest, using connection: ProviderConnection) async throws -> AssistantResponse
    func listModels(using connection: ProviderConnection) async throws -> AssistantModelPage
}
