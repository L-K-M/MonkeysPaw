import Foundation

/// Shared assistant service. This slice owns only Test and model listing.
public final class AssistantService: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let providerSettings: ProviderSettingsService
    private let anthropic: AssistantClient
    private let openAICompatible: AssistantClient
    private let work: BackgroundWork
    private let main: MainThread
    private let timeout: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    public convenience init(providerSettings: ProviderSettingsService, anthropic: AssistantClient,
                            openAICompatible: AssistantClient, work: BackgroundWork, main: MainThread) {
        self.init(providerSettings: providerSettings, anthropic: anthropic, openAICompatible: openAICompatible,
                  work: work, main: main, timeout: Limits.modelListTimeout, now: { ContinuousClock.now })
    }

    // Short budgets and a monotonic test clock exercise races without a 15 s wait.
    init(providerSettings: ProviderSettingsService, anthropic: AssistantClient,
         openAICompatible: AssistantClient, work: BackgroundWork, main: MainThread,
         timeout: Duration, now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.providerSettings = providerSettings
        self.anthropic = anthropic
        self.openAICompatible = openAICompatible
        self.work = work
        self.main = main
        self.timeout = timeout
        self.now = now
    }

    /// Resolves only this immutable draft. No settings, secrets or capability
    /// state are written. Cancellation and timeout each complete once on MainThread.
    @discardableResult
    public func testConnection(draft: ProviderDraft,
                               completion: @escaping (ConnectionTestResult) -> Void) -> AssistantConnectionTest {
        let deadline = now().advanced(by: timeout)
        let test = AssistantConnectionTest(main: main, completion: completion)
        test.attach(Task.detached {
            do {
                try await ContinuousClock().sleep(until: deadline)
                test.finish(.timeout)
            } catch { /* A finished or cancelled test stops its timer. */ }
        })
        work.run { [self] in
            guard test.isActive else { return }
            do {
                try checkDeadline(deadline)
                let connection = try providerSettings.resolveForTesting(draft)
                try checkDeadline(deadline)
                guard test.isActive else { return }
                let client = connection.kind == .anthropic ? anthropic : openAICompatible
                test.attach(Task.detached {
                    do {
                        let models = try await self.models(using: connection, client: client, deadline: deadline)
                        test.finish(.ok(models: models))
                    } catch { test.finish(self.failure(error)) }
                })
            } catch { test.finish(failure(error)) }
        }
        return test
    }

    private func models(using connection: ProviderConnection, client: AssistantClient,
                        deadline: ContinuousClock.Instant) async throws -> [ModelDescriptor] {
        var models = [Data: ModelDescriptor]()
        var cursors = Set<Data>()
        var afterID: String?
        var count = 0
        var bytes = 0
        for _ in 0..<Limits.modelListPageCap {
            try Task.checkCancellation()
            try checkDeadline(deadline)
            let page = try await client.listModels(using: connection, afterID: afterID, deadline: deadline)
            try Task.checkCancellation()
            try checkDeadline(deadline)
            guard page.models.count <= Limits.modelListEntryCap - count else { throw AssistantError.invalidOutput }
            count += page.models.count
            let cursorBytes = [page.firstID, page.lastID].compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
            guard cursorBytes <= Limits.modelListByteCap - bytes else { throw AssistantError.invalidOutput }
            bytes += cursorBytes
            for model in page.models {
                guard AssistantModelList.validID(model.id) else { throw AssistantError.invalidOutput }
                let size = model.id.utf8.count + (model.displayName?.utf8.count ?? 0)
                guard size <= Limits.modelListByteCap - bytes else { throw AssistantError.invalidOutput }
                bytes += size
                let id = Data(model.id.utf8)
                // Prefer a name, then its UTF-8 order, independent of page order.
                let names = [models[id]?.displayName, model.displayName].compactMap { $0 }
                let name = names.min { $0.utf8.lexicographicallyPrecedes($1.utf8) }
                models[id] = ModelDescriptor(id: model.id, displayName: name)
            }
            guard page.hasMore else {
                let sorted = models.values.sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
                try Task.checkCancellation()
                try checkDeadline(deadline)
                return sorted
            }
            guard !page.models.isEmpty, let cursor = page.lastID, AssistantModelList.validID(cursor),
                  cursors.insert(Data(cursor.utf8)).inserted else { throw AssistantError.invalidOutput }
            afterID = cursor
        }
        throw AssistantError.invalidOutput
    }

    private func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
        guard now() < deadline else { throw AssistantError.transport(.deadlineExceeded) }
    }

    private func failure(_ error: Error) -> ConnectionTestResult {
        if let error = error as? ProviderSettingsError { return .settings(error) }
        if error is CancellationError { return .cancelled }
        guard let error = error as? AssistantError else { return .network }
        switch error {
        case .authentication: return .authentication
        case .modelNotFound: return .notFound
        case .rateLimited(let delay): return .rateLimited(retryAfter: delay)
        case .providerFailure(405), .providerFailure(501): return .unsupportedListing
        case .providerFailure(let status): return .providerFailure(statusCode: status)
        case .overloaded: return .providerFailure(statusCode: 529)
        case .transport(.cancelled): return .cancelled
        case .transport(.deadlineExceeded): return .timeout
        case .transport(.networkFailure), .transport(.redirectRefused): return .network
        default: return .invalidResponse
        }
    }

    public var description: String { "<assistant service>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["service": description]) }
}

/// The lock owns completion and task lifetimes; cancellation also works while
/// a secret-store read is queued or blocked. Such a read cannot itself be aborted.
public final class AssistantConnectionTest: @unchecked Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var completion: ((ConnectionTestResult) -> Void)?

    fileprivate init(main: MainThread, completion: @escaping (ConnectionTestResult) -> Void) {
        self.completion = { result in main.run { completion(result) } }
    }

    public func cancel() { finish(.cancelled) }

    fileprivate var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completion != nil
    }

    fileprivate func attach(_ task: Task<Void, Never>) {
        lock.lock()
        if completion != nil {
            tasks.append(task)
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    fileprivate func finish(_ result: ConnectionTestResult) {
        lock.lock()
        guard let completion else {
            lock.unlock()
            return
        }
        self.completion = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        completion(result)
    }

    public var description: String { "<assistant connection test>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["test": description]) }
}
