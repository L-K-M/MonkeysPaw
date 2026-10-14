import Foundation

protocol ConflictResolving {
    func preview(_ copy: LibraryPromptSelection) async throws -> ConflictPreview
    func resolve(_ action: ConflictResolutionAction, preview: ConflictPreview) async throws -> ConflictResolutionResult
}

extension ConflictResolutionService: ConflictResolving {}

/// UI-thread state/intents. All loading, comparison and mutation runs off UI;
/// all publications use MainThread, including queued and retired-session guards.
public final class ConflictModel {
    public private(set) var state = ConflictState()
    public var onChange: (() -> Void)?
    private let service: ConflictResolving
    private let main: MainThread
    private var active = true
    private var selection: LibraryPromptSelection?
    private var request = UUID()
    private var observers: [UUID: (ConflictState) -> Void] = [:]
    private var publication: UInt64 = 0
    private let taskLock = NSLock()
    private var task: Task<Void, Never>?

    public convenience init(service: ConflictResolutionService, mainThread: MainThread) {
        self.init(service: service as ConflictResolving, mainThread: mainThread)
    }

    init(service: ConflictResolving, mainThread: MainThread) {
        self.service = service
        main = mainThread
    }

    deinit { state.preview?.validity.invalidate() }

    @discardableResult public func addObserver(_ observer: @escaping (ConflictState) -> Void) -> UUID {
        let id = UUID()
        if active { observers[id] = observer }
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    /// Call after the native unsaved-editor guard allows changing selection.
    /// A fresh load follows a uniquely identified renamed copy.
    public func open(_ copy: LibraryPromptSelection) {
        main.run { [weak self] in
            guard let self, self.active else { return }
            self.invalidate()
            self.selection = copy
            self.state = ConflictState()
            self.load(copy)
        }
    }

    public func refresh() {
        main.run { [weak self] in
            guard let self, self.active, !self.state.isBusy, let selection = self.selection else { return }
            self.invalidate()
            self.load(selection)
        }
    }

    public func resolve(_ action: ConflictResolutionAction) {
        main.run { [weak self] in
            guard let self, self.active, !self.state.isBusy, let preview = self.state.preview else { return }
            self.perform(.resolving) { service in try await service.resolve(action, preview: preview) }
        }
    }

    /// Hiding the reusable view revokes its preview as well as queued replies.
    public func close() {
        main.run { [weak self] in
            guard let self, self.active else { return }
            self.invalidate()
            self.selection = nil
            self.state = ConflictState()
            self.publish()
        }
    }

    public func retire() {
        invalidate()
        active = false
        observers.removeAll()
        onChange = nil
    }

    public func drain() async {
        let accepted = acceptedTask()
        await accepted?.value
    }

    private func acceptedTask() -> Task<Void, Never>? {
        taskLock.lock()
        defer { taskLock.unlock() }
        return task
    }

    private func invalidate() {
        state.preview?.validity.invalidate()
        request = UUID()
    }

    private func load(_ copy: LibraryPromptSelection) {
        perform(.loading) { service in .refreshed(try await service.preview(copy)) }
    }

    private func perform(_ operation: ConflictState.Operation,
                         intent: @escaping (ConflictResolving) async throws -> ConflictResolutionResult) {
        let id = UUID()
        request = id
        state.operation = operation
        state.error = nil
        state.resolved = nil
        let nextTask = Task.detached { [service, main, weak self] in
            let result: Result<ConflictResolutionResult, ConflictResolutionFailure>
            do { result = .success(try await intent(service)) }
            catch { result = .failure(ConflictResolutionService.failure(error)) }
            main.run { [weak self] in
                guard let self, self.active, self.request == id else {
                    if case .success(.refreshed(let preview)) = result, self?.state.preview?.id != preview.id {
                        preview.validity.invalidate()
                    }
                    return
                }
                self.request = UUID()
                self.state.operation = .idle
                switch result {
                case .success(.refreshed(let preview)):
                    self.state.preview?.validity.invalidate()
                    self.state.preview = preview
                    self.selection = preview.copy
                    self.state.error = operation == .resolving ? .headChanged : nil
                case .success(.resolved(let action)):
                    self.invalidate()
                    self.state.preview = nil
                    self.state.resolved = action
                case .failure(let failure): self.state.error = failure
                }
                self.publish()
            }
        }
        taskLock.lock(); task = nextTask; taskLock.unlock()
        publish()
    }

    private func publish() {
        publication &+= 1
        let version = publication
        let snapshot = state
        main.run { [weak self] in
            guard let self, self.active, self.publication == version else { return }
            self.onChange?()
            for id in Array(self.observers.keys) {
                guard self.active, self.publication == version else { break }
                self.observers[id]?(snapshot)
            }
        }
    }
}
