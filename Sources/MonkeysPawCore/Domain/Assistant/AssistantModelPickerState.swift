import Foundation

/// Opaque generation: switching away and back cannot revive an earlier test.
public struct ConnectionTestRequestID: Equatable, Sendable {
    private let generation = UUID()
    fileprivate init() {}
}

/// Values only. The settings model supplies every draft edit before accepting
/// a callback; available models are suggestions, never a model-ID allowlist.
public struct AssistantModelPickerState: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private var draft: ProviderDraft
    private var pending: ConnectionTestRequestID?
    public private(set) var availableModels: [ModelDescriptor] = []
    public private(set) var lastResult: ConnectionTestResult?
    public var manualModelID: String { draft.modelID }
    public var isTesting: Bool { pending != nil }

    public init(draft: ProviderDraft) { self.draft = draft }

    public mutating func update(draft: ProviderDraft) {
        guard !sameDraft(draft) else { return }
        self.draft = draft
        pending = nil
        availableModels = []
        lastResult = nil
    }

    @discardableResult
    public mutating func beginTest() -> ConnectionTestRequestID {
        let request = ConnectionTestRequestID()
        pending = request
        return request
    }

    /// Call on the settings model's UI thread, after applying any draft edits.
    @discardableResult
    public mutating func receive(_ result: ConnectionTestResult, for request: ConnectionTestRequestID) -> Bool {
        guard pending == request else { return false }
        pending = nil
        lastResult = result
        if case .ok(let models) = result { availableModels = models }
        return true
    }

    public mutating func cancelTest() {
        guard pending != nil else { return }
        pending = nil
        lastResult = .cancelled
    }

    private func sameDraft(_ other: ProviderDraft) -> Bool {
        // Swift String equality folds canonical Unicode spellings; opaque IDs,
        // URLs and typed credentials can distinguish their actual bytes.
        guard draft.id == other.id, draft.kind == other.kind,
              draft.displayName.utf8.elementsEqual(other.displayName.utf8),
              draft.baseURL.utf8.elementsEqual(other.baseURL.utf8),
              draft.modelID.utf8.elementsEqual(other.modelID.utf8) else { return false }
        switch (draft.key, other.key) {
        case (.keep, .keep), (.clear, .clear): return true
        case (.replace(let key), .replace(let otherKey)):
            return key.withValue { value in otherKey.withValue { value.utf8.elementsEqual($0.utf8) } }
        default: return false
        }
    }

    public var description: String { "<assistant model picker redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["picker": description]) }
}
