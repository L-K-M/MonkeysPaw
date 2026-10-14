import Foundation

/// One service per library/account graph, sharing its private store across
/// graphs. Intents and publication belong to MainThread; source reads and load/
/// recording use serial BackgroundWork. The lock orders epoch checks and disk
/// replacement against synchronous Forget/retirement, so late work cannot save.
public final class RepeatService: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    private struct Snapshot {
        let record: LastDeliveryRecord
        let values: [String: String]?
        let entry: LibraryEntry?

        init(record: LastDeliveryRecord, values: [String: String]?, entry: LibraryEntry? = nil) {
            self.record = record
            self.values = values
            self.entry = entry
        }
    }

    private struct Resolved {
        let entry: LibraryEntry
        let values: [String: String]
    }

    private struct Refusal: Error { let result: RepeatResult }

    private final class Operation {
        let ticket: RepeatRecording
        let done: (RepeatResult) -> Void
        var invocation: DeliveryInvocation?
        var entry: LibraryEntry?
        var refusal: RepeatResult?
        var didComplete = false
        var snapshot: Snapshot?
        var resolved: Resolved?
        var builtins: PromptBuiltinValues?
        var requestedBuiltins = false
        var didEnqueue = false

        init(ticket: RepeatRecording, done: @escaping (RepeatResult) -> Void) {
            self.ticket = ticket
            self.done = done
        }
    }

    public private(set) var availability = RepeatAvailability.nothingToRepeat
    public var isBusy: Bool { operation != nil }
    public var description: String { "<repeat service>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    private let binding: RepeatBinding
    private let store: LastDeliveryStore
    private let library: LibraryService
    private let index: PromptIndex
    private let fill: FillService
    private let delivery: DeliveryService
    private let work: BackgroundWork
    private let main: MainThread
    private let canAccess: (LibraryEntry) -> Bool
    private let isOwnWindowActive: () -> Bool
    private let pasteChord: (DeliveryInvocation) -> PasteChord
    private let observers = ChangeObservers<RepeatAvailability>()
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var active = true
    private var blocked: RepeatFailure?
    private var revision: UInt64 = 0
    private var loaded = false
    private var snapshot: Snapshot?
    private var operation: Operation?

    /// Access/own-window gates run only on the UI thread. Native composition
    /// must supply its live Settings/Library gate, including on Wayland where
    /// FocusTracker deliberately cannot identify the active window.
    public init(binding: RepeatBinding, store: LastDeliveryStore, library: LibraryService,
                index: PromptIndex, fill: FillService, delivery: DeliveryService,
                work: BackgroundWork, main: MainThread,
                canAccess: @escaping (LibraryEntry) -> Bool = { _ in true },
                isOwnWindowActive: @escaping () -> Bool,
                pasteChord: @escaping (DeliveryInvocation) -> PasteChord = { _ in .standard }) {
        self.binding = binding
        self.store = store
        self.library = library
        self.index = index
        self.fill = fill
        self.delivery = delivery
        self.work = work
        self.main = main
        self.canAccess = canAccess
        self.isOwnWindowActive = isOwnWindowActive
        self.pasteChord = pasteChord
    }

    func addObserver(_ observer: @escaping @Sendable (RepeatAvailability) -> Void) -> UUID { observers.add(observer) }
    func removeObserver(_ token: UUID) { observers.remove(token) }

    public func load(done: @escaping (RepeatAvailability) -> Void = { _ in }) {
        main.run {
            let ticket = self.beginRecording()
            guard self.isCurrent(ticket) else { done(.unavailable(.inactive)); return }
            if let blocked = self.lock.withLock({ self.blocked }) { done(.unavailable(blocked)); return }
            let revision = self.revision
            let memory = self.snapshot
            let loaded = self.loaded
            self.work.run {
                let result = Result { loaded ? memory : try self.readSnapshot(ticket) }
                let validation = result.map { self.availability(for: $0) }
                self.main.run {
                    guard self.isCurrent(ticket), revision == self.revision else { done(self.availability); return }
                    self.loaded = true
                    switch validation {
                    case .success(let value):
                        if let snapshot = try? result.get() {
                            self.snapshot = Snapshot(record: snapshot.record, values: snapshot.values,
                                entry: value.1 ?? snapshot.entry)
                        } else { self.snapshot = nil }
                        self.publish(self.checkedAccess(value))
                    case .failure(let error):
                        let failure = error as? RepeatFailure ?? .readFailed
                        self.lock.withLock { self.blocked = failure }
                        self.publish(.unavailable(failure))
                    }
                    done(self.availability)
                }
            }
        }
    }

    /// Returns false for an overlapping invocation; it gets no second callback
    /// or queued paste. Capture target and date/time before file/builtin work.
    @discardableResult
    public func repeatLast(done: @escaping (RepeatResult) -> Void) -> Bool {
        guard !isBusy else { return false }
        let ticket = beginRecording()
        guard isCurrent(ticket) else { done(.unavailable(.inactive)); return true }
        if let blocked = lock.withLock({ blocked }) { done(.unavailable(blocked)); return true }
        guard !isOwnWindowActive() else { done(.unavailable(.ownWindow)); return true }
        let operation = Operation(ticket: ticket, done: done)
        self.operation = operation
        let moment = fill.builtinMoment()
        delivery.captureInvocation(source: .currentTarget) { invocation in
            guard self.current(operation) else { invocation.cancel(); return }
            operation.invocation = invocation
            let memory = self.snapshot
            let loaded = self.loaded
            if let entry = memory?.entry {
                guard self.canAccess(entry) else { self.finish(operation, self.review(entry, .sourceUnavailable)); return }
                self.requestBuiltins(for: entry, moment: moment, operation: operation)
            }
            self.work.run {
                do {
                    let snapshot = loaded ? memory : try self.readSnapshot(ticket)
                    guard let snapshot else {
                        self.main.run { self.finish(operation, .nothingToRepeat) }
                        return
                    }
                    let resolved = try self.resolve(snapshot)
                    self.main.run {
                        guard self.current(operation) else { return }
                        guard self.canAccess(resolved.entry) else {
                            self.finish(operation, self.review(resolved.entry, .sourceUnavailable)); return
                        }
                        guard !self.isOwnWindowActive() else { self.finish(operation, .unavailable(.ownWindow)); return }
                        let snapshot = Snapshot(record: snapshot.record, values: snapshot.values, entry: resolved.entry)
                        self.snapshot = snapshot
                        self.loaded = true
                        operation.entry = resolved.entry
                        operation.snapshot = snapshot
                        operation.resolved = resolved
                        self.requestBuiltins(for: resolved.entry, moment: moment, operation: operation)
                        self.deliverIfReady(operation)
                    }
                } catch {
                    let result = (error as? Refusal)?.result ?? .unavailable(error as? RepeatFailure ?? .readFailed)
                    self.main.run { self.finish(operation, result) }
                }
            }
        }
        return true
    }

    /// Cancels pending repeat work but leaves the completed delivery record.
    /// No side effect already submitted to a native injector can be unsent.
    public func cancel() {
        guard let operation else { return }
        operation.invocation?.cancel()
        finish(operation, .cancelled)
    }

    func beginRecording() -> RepeatRecording { lock.withLock { RepeatRecording(epoch: epoch) } }

    func isCurrent(_ ticket: RepeatRecording) -> Bool { lock.withLock { active && ticket.epoch == epoch } }

    /// Only the completed picker/fill/repeat path calls this. Self-test and
    /// previews cannot reach it. Full values stay in memory; projection failures
    /// replace older disk state with a tombstone, or disable repeat if that fails.
    func recordCompleted(entry: LibraryEntry, values: [String: String], mode: DeliveryMode,
                         ticket: RepeatRecording, done: @escaping ([PromptPersistenceWarning]) -> Void) {
        record(entry: entry, values: values, mode: mode, ticket: ticket, completing: nil, done: done)
    }

    private func record(entry: LibraryEntry, values: [String: String], mode: DeliveryMode,
                        ticket: RepeatRecording, completing: Operation?,
                        done: @escaping ([PromptPersistenceWarning]) -> Void) {
        guard isCurrent(ticket) else { done([]); return }
        revision &+= 1
        let revision = revision
        let record: LastDeliveryRecord
        do { record = try LastDeliveryRecord(binding: binding, entry: entry, values: values, mode: mode) }
        catch { done([.lastDeliveryNotSaved]); return }
        snapshot = Snapshot(record: record, values: values, entry: entry)
        loaded = true
        // A cancelled operation's completion can immediately invoke repeat.
        // Publish the new in-memory snapshot before releasing that callback.
        if operation !== completing { cancel() }
        work.run {
            var warnings: [PromptPersistenceWarning] = []
            let saved = self.lock.withLock { () -> Bool in
                guard self.active, self.epoch == ticket.epoch else { return false }
                do { try self.store.save(record); self.blocked = nil }
                catch {
                    warnings.append(.lastDeliveryNotSaved)
                    do { try self.store.save(nil); self.blocked = nil }
                    catch { self.blocked = .invalidationFailed }
                }
                return true
            }
            self.main.run {
                guard saved, self.isCurrent(ticket) else { done([]); return }
                if self.revision == revision {
                    if let blocked = self.lock.withLock({ self.blocked }) { self.publish(.unavailable(blocked)) }
                    else { self.publish(.ready) }
                }
                done(warnings)
            }
        }
    }

    /// UI-thread Forget boundary. Clear repeat before touching values/drafts.
    /// Failure leaves those untouched and disables repeat until a successful
    /// retry. A nonmatching record is retained; all older recording tickets end.
    func forgetValues(for identity: PromptIdentity? = nil) throws {
        revision &+= 1
        // Close the gate before any completion/observer can re-enter repeat.
        let needsRepair = lock.withLock { () -> Bool in
            let needsRepair = blocked == .invalidationFailed
            epoch &+= 1
            blocked = .invalidationFailed
            return needsRepair
        }
        cancel()
        var retained: LastDeliveryRecord?
        do {
            try lock.withLock {
                if identity == nil || needsRepair {
                    try store.save(nil)
                    blocked = nil
                    return
                }
                let read = Result { try store.load() }
                let disk = try? read.get()
                let matches = (try? snapshot?.record.identity) == identity
                    || (try? disk?.identity) == identity
                // Unknown durable state could belong to the forgotten identity.
                // Do not report a clear while leaving that record behind.
                if case .failure = read { try store.save(nil) }
                else if matches || (disk == nil && snapshot == nil) {
                    try store.save(nil)
                } else { retained = snapshot?.record ?? disk }
                blocked = nil
            }
        } catch {
            snapshot = nil
            loaded = true
            lock.withLock { blocked = .invalidationFailed }
            publish(.unavailable(.invalidationFailed))
            throw RepeatFailure.invalidationFailed
        }
        if retained == nil { snapshot = nil }
        else if snapshot == nil, let retained { snapshot = Snapshot(record: retained, values: nil) }
        loaded = true
        if let snapshot, snapshot.values == nil, snapshot.record.requiresSessionValues {
            publish(.reviewRequired(try snapshot.record.reference, .sessionOnlyValues))
        } else { publish(snapshot == nil ? .nothingToRepeat : .ready) }
    }

    /// Composition calls before switching root/account or signing out. Only a
    /// successful return authorizes retirement. Retry on failure before replacing
    /// the graph; a restart after a failed clear still has the uncommitted record.
    public func retire() throws {
        lock.withLock { active = false }
        do { try forgetValues() }
        catch { lock.withLock { active = true }; throw error }
        publish(.unavailable(.inactive))
    }

    private func readSnapshot(_ ticket: RepeatRecording) throws -> Snapshot? {
        try lock.withLock {
            guard active, epoch == ticket.epoch else { throw RepeatFailure.inactive }
            guard let record = try store.load() else { return nil }
            guard record.binding == binding else {
                do { try store.save(nil) }
                catch { blocked = .invalidationFailed; throw RepeatFailure.invalidationFailed }
                return nil
            }
            return Snapshot(record: record, values: nil)
        }
    }

    private func resolve(_ snapshot: Snapshot) throws -> Resolved {
        let record = snapshot.record
        let identity = try record.identity
        let entry: LibraryEntry
        do {
            if case .local = identity {
                entry = try library.load(at: record.relativePath)
            } else {
                // Resolve assigned IDs from current disk, never the cached index
                // or a reused hint. Duplicate IDs also fail closed.
                let matches = try library.entries().filter { $0.identity == identity }
                guard matches.count == 1 else { throw FileStoreError.notFound }
                entry = matches[0]
            }
        } catch { throw Refusal(result: .reviewRequired(try record.reference, .sourceUnavailable)) }
        guard entry.identity == identity, entry.document.canRender,
              SHA256.hexDigest(Data(entry.document.source.utf8)) == record.sourceFingerprint,
              record.idlessStamp.map({ $0 == entry.stamp }) ?? true else {
            throw Refusal(result: review(entry, .sourceChanged))
        }
        let fields = entry.document.effectiveFields
        let rememberedNames = Set(fields.filter(\.remember).map(\.name))
        guard Set(record.rememberedValues.keys) == rememberedNames,
              record.requiresSessionValues == fields.contains(where: { !$0.remember }) else {
            throw Refusal(result: review(entry, .sourceChanged))
        }
        if snapshot.values == nil, record.requiresSessionValues {
            throw Refusal(result: review(entry, .sessionOnlyValues))
        }
        let values = snapshot.values ?? record.rememberedValues
        guard Set(values.keys) == Set(fields.map(\.name)) else { throw Refusal(result: review(entry, .sourceChanged)) }
        return Resolved(entry: entry, values: values)
    }

    private func availability(for snapshot: Snapshot?) -> (RepeatAvailability, LibraryEntry?) {
        guard let snapshot else { return (.nothingToRepeat, nil) }
        do { return (.ready, try resolve(snapshot).entry) }
        catch let refusal as Refusal {
            if case .reviewRequired(let reference, let reason) = refusal.result {
                return (.reviewRequired(reference, reason), nil)
            }
            return (.unavailable(.readFailed), nil)
        } catch { return (.unavailable(.readFailed), nil) }
    }

    private func checkedAccess(_ value: (RepeatAvailability, LibraryEntry?)) -> RepeatAvailability {
        if let entry = value.1, !canAccess(entry) {
            return .reviewRequired(RepeatPromptReference(identity: entry.identity, relativePath: entry.relativePath), .sourceUnavailable)
        }
        return value.0
    }

    private func requestBuiltins(for entry: LibraryEntry, moment: PromptBuiltinValues, operation: Operation) {
        guard !operation.requestedBuiltins else { return }
        operation.requestedBuiltins = true
        fill.builtinSnapshot(for: entry.document, moment: moment) { builtins in
            self.main.run {
                guard self.current(operation), operation.builtins == nil else { return }
                operation.builtins = builtins
                self.deliverIfReady(operation)
            }
        }
    }

    private func deliverIfReady(_ operation: Operation) {
        guard current(operation), !operation.didEnqueue, let snapshot = operation.snapshot,
              let resolved = operation.resolved, let builtins = operation.builtins else { return }
        operation.didEnqueue = true
        deliver(snapshot, resolved: resolved, builtins: builtins, operation: operation)
    }

    private func deliver(_ snapshot: Snapshot, resolved: Resolved, builtins: PromptBuiltinValues, operation: Operation) {
        guard let invocation = operation.invocation else { return }
        let text: String
        do { text = try fill.render(resolved.entry.document, values: resolved.values, builtins: builtins) }
        catch { finish(operation, review(resolved.entry, .sourceChanged)); return }
        let mode: DeliveryMode = snapshot.record.copyOnly ? .copyOnly : .paste(pasteChord(invocation))
        delivery.deliver(text, mode: mode, invocation: invocation, isValid: {
            self.current(operation) && !self.isOwnWindowActive()
        }, validate: { ready in
            self.work.run {
                let result = Result { try self.resolve(snapshot) }
                self.main.run {
                    guard self.current(operation) else { ready(false); return }
                    switch result {
                    case .success(let current):
                        guard self.canAccess(current.entry), !self.isOwnWindowActive() else {
                            operation.refusal = self.isOwnWindowActive() ? .unavailable(.ownWindow)
                                : self.review(current.entry, .sourceUnavailable)
                            ready(false); return
                        }
                        operation.entry = current.entry
                        ready(true)
                    case .failure(let error):
                        operation.refusal = (error as? Refusal)?.result ?? .unavailable(.readFailed)
                        ready(false)
                    }
                }
            }
        }) { outcome in
            guard self.current(operation) else { return }
            guard let outcome, let entry = operation.entry else {
                self.finish(operation, operation.refusal ?? .cancelled); return
            }
            var warnings: [PromptPersistenceWarning] = []
            do { try self.index.recordUse(of: entry.identity) }
            catch { warnings.append(.usageNotSaved) }
            self.record(entry: entry, values: resolved.values, mode: mode, ticket: operation.ticket,
                        completing: operation) { saved in
                guard self.isCurrent(operation.ticket) else { self.finish(operation, .cancelled); return }
                self.finish(operation, .delivered(outcome, warnings + saved))
            }
        }
    }

    private func current(_ operation: Operation) -> Bool {
        !operation.didComplete && self.operation === operation && isCurrent(operation.ticket)
    }

    private func finish(_ operation: Operation, _ result: RepeatResult) {
        guard !operation.didComplete else { return }
        operation.didComplete = true
        if self.operation === operation { self.operation = nil }
        switch result {
        case .nothingToRepeat: publish(.nothingToRepeat)
        case .reviewRequired(let reference, let reason): publish(.reviewRequired(reference, reason))
        case .unavailable(let error): publish(.unavailable(error))
        case .delivered, .cancelled: break
        }
        operation.done(result)
    }

    private func review(_ entry: LibraryEntry, _ reason: RepeatReviewReason) -> RepeatResult {
        .reviewRequired(RepeatPromptReference(identity: entry.identity, relativePath: entry.relativePath), reason)
    }

    private func publish(_ availability: RepeatAvailability) {
        self.availability = availability
        observers.publish(observers.capture(), event: availability)
    }
}
