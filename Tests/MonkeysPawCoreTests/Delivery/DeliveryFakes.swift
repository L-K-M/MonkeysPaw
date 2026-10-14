import Foundation
import MonkeysPawCore

enum DeliveryEvent: Equatable {
    case capture, show, hide, hideForDelivery
    case write(String), wait(Duration), restore(DeliveryTarget)
    case paste(PasteBackend, PasteChord)
    case copied, pressPaste(PasteChord, CopyReason), done(DeliveryOutcome)
    case testPresent(String), testReadBack, testClose
    case snapshotClipboard, restoreClipboard
}

final class DeliveryRecorder {
    var events: [DeliveryEvent] = []
}

enum FakeCompletionMode {
    case immediate, deferred
}

final class FakeMainThread: MainThread {
    var mode: FakeCompletionMode = .immediate
    private(set) var hops = 0
    private(set) var isRunning = false
    private var pending: [() -> Void] = []

    func run(_ work: @escaping () -> Void) {
        hops += 1
        switch mode {
        case .immediate: execute(work)
        case .deferred: pending.append(work)
        }
    }

    func drain() {
        while !pending.isEmpty { execute(pending.removeFirst()) }
    }

    @discardableResult
    func drainOne() -> Bool {
        guard !pending.isEmpty else { return false }
        execute(pending.removeFirst())
        return true
    }

    private func execute(_ work: () -> Void) {
        let previous = isRunning
        isRunning = true
        work()
        isRunning = previous
    }
}

/// Advances scheduled work chronologically, including timers added by timers.
final class FakeScheduler: Scheduler {
    private struct Task {
        let deadline: Duration
        let sequence: Int
        let work: () -> Void
    }

    private let recorder: DeliveryRecorder
    private var tasks: [Task] = []
    private var lastCallback: (() -> Void)?
    private var sequence = 0
    private(set) var now: Duration = .zero
    private(set) var delays: [Duration] = []

    init(_ recorder: DeliveryRecorder) { self.recorder = recorder }

    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        delays.append(delay)
        recorder.events.append(.wait(delay))
        tasks.append(Task(deadline: now + delay, sequence: sequence, work: work))
        sequence += 1
    }

    func advance(by duration: Duration) {
        let until = now + duration
        while let next = tasks.indices.min(by: {
            let lhs = tasks[$0]
            let rhs = tasks[$1]
            return lhs.deadline == rhs.deadline
                ? lhs.sequence < rhs.sequence : lhs.deadline < rhs.deadline
        }), tasks[next].deadline <= until {
            let task = tasks.remove(at: next)
            now = task.deadline
            lastCallback = task.work
            task.work()
        }
        now = until
    }

    func repeatLastCallback() { lastCallback?() }
}

final class FakePanel: PanelWindow {
    private let recorder: DeliveryRecorder
    init(_ recorder: DeliveryRecorder) { self.recorder = recorder }
    func show() { recorder.events.append(.show) }
    func hideForDelivery() { recorder.events.append(.hideForDelivery) }
    func hide() { recorder.events.append(.hide) }
}

final class FakeFocus: FocusTracker {
    var target: DeliveryTarget? = .macOS(processID: 42, bundleID: "test.target")
    var confirmation: FocusConfirmation = .confirmed
    var mode: FakeCompletionMode = .immediate
    private let recorder: DeliveryRecorder
    private var completions: [(FocusConfirmation) -> Void] = []

    init(_ recorder: DeliveryRecorder) { self.recorder = recorder }

    func captureTarget() -> DeliveryTarget? {
        recorder.events.append(.capture)
        return target
    }

    func restore(_ target: DeliveryTarget, completion: @escaping (FocusConfirmation) -> Void) {
        recorder.events.append(.restore(target))
        switch mode {
        case .immediate: completion(confirmation)
        case .deferred: completions.append(completion)
        }
    }

    func complete(_ confirmation: FocusConfirmation) { complete([confirmation]) }

    func complete(_ confirmations: [FocusConfirmation]) {
        let completion = completions.removeFirst()
        confirmations.forEach(completion)
    }
}

final class FakeClipboard: ClipboardRestoring, @unchecked Sendable {
    private final class Revision: ClipboardRevision {
        weak var clipboard: FakeClipboard?
        let value: Int
        init(_ clipboard: FakeClipboard, value: Int) {
            self.clipboard = clipboard
            self.value = value
        }
    }

    private final class Ownership: ClipboardWriteOwnership {
        weak var clipboard: FakeClipboard?
        let value: Int
        init(_ clipboard: FakeClipboard, value: Int) {
            self.clipboard = clipboard
            self.value = value
        }
    }

    private final class SnapshotRead: ClipboardSnapshotRead {
        weak var clipboard: FakeClipboard?
        private var snapshot: ClipboardTextSnapshot?
        private let lock = NSLock()
        private let completion: (ClipboardTextSnapshot?) -> Void
        private var didCancel = false

        init(_ clipboard: FakeClipboard, snapshot: ClipboardTextSnapshot?,
             completion: @escaping (ClipboardTextSnapshot?) -> Void) {
            self.clipboard = clipboard
            self.snapshot = snapshot
            self.completion = completion
        }

        func cancel() {
            let cancelled = lock.withLock {
                guard !didCancel else { return false }
                didCancel = true
                snapshot = nil
                return true
            }
            guard cancelled, let clipboard else { return }
            clipboard.locked { clipboard.numberOfSnapshotCancellations += 1 }
        }

        func complete(repeating count: Int) {
            // Deliberately send late nil/duplicate callbacks to exercise Core's guards.
            let value = lock.withLock {
                let value = snapshot
                snapshot = nil
                return value
            }
            for _ in 0..<count { completion(value) }
        }
    }

    private let lock = NSLock()
    private var storedText: String?
    private var revision = 0
    private var numberOfReads = 0
    private var mode: FakeCompletionMode = .immediate
    private var reads: [@Sendable (String?) -> Void] = []
    private let recorder: DeliveryRecorder
    private var snapshots: [SnapshotRead] = []
    private var snapshotCompletionMode: FakeCompletionMode = .immediate
    private var snapshotIsUnavailable = false
    private var canOwnClipboardWrite = true
    private var snapshotHook: (() -> Void)?
    private var clipboardRestoreHook: (() -> Void)?
    private var recordedSnapshotBudgets: [Duration] = []
    private var recordedSnapshotByteLimits: [Int] = []
    private var numberOfSnapshotCancellations = 0
    private var numberOfOwnershipWrites = 0
    private var numberOfRestoreCalls = 0
    private var numberOfRestorationWrites = 0
    private weak var previousSnapshot: ClipboardTextSnapshot?

    var snapshotMode: FakeCompletionMode {
        get { locked { snapshotCompletionMode } }
        set { locked { snapshotCompletionMode = newValue } }
    }
    var snapshotUnavailable: Bool {
        get { locked { snapshotIsUnavailable } }
        set { locked { snapshotIsUnavailable = newValue } }
    }
    var canOwnWrite: Bool {
        get { locked { canOwnClipboardWrite } }
        set { locked { canOwnClipboardWrite = newValue } }
    }
    var onSnapshot: (() -> Void)? {
        get { locked { snapshotHook } }
        set { locked { snapshotHook = newValue } }
    }
    var onClipboardRestore: (() -> Void)? {
        get { locked { clipboardRestoreHook } }
        set { locked { clipboardRestoreHook = newValue } }
    }
    var snapshotBudgets: [Duration] { locked { recordedSnapshotBudgets } }
    var snapshotByteLimits: [Int] { locked { recordedSnapshotByteLimits } }
    var snapshotCancellations: Int { locked { numberOfSnapshotCancellations } }
    var ownershipWrites: Int { locked { numberOfOwnershipWrites } }
    var restoreCalls: Int { locked { numberOfRestoreCalls } }
    var restorationWrites: Int { locked { numberOfRestorationWrites } }
    var lastSnapshot: ClipboardTextSnapshot? { locked { previousSnapshot } }

    var text: String? { locked { storedText } }
    var readCount: Int { locked { numberOfReads } }
    var readMode: FakeCompletionMode {
        get { locked { mode } }
        set { locked { mode = newValue } }
    }

    init(_ recorder: DeliveryRecorder) { self.recorder = recorder }

    // Synchronous test helper returns raw text, including empty strings.
    func readText() -> String? { text }

    // The port read models nil-for-empty pasteboard semantics.
    func readText(_ completion: @escaping @Sendable (String?) -> Void) {
        lock.lock()
        numberOfReads += 1
        switch mode {
        case .immediate:
            let value = storedText.flatMap { $0.isEmpty ? nil : $0 }
            lock.unlock()
            completion(value)
        case .deferred:
            reads.append(completion)
            lock.unlock()
        }
    }

    func completeRead(_ text: String?) {
        let completion = locked {
            precondition(!reads.isEmpty, "No pending clipboard read to complete.")
            return reads.removeFirst()
        }
        completion(text)
    }

    func writeText(_ text: String) {
        replaceText(text)
        recorder.events.append(.write(text))
    }

    /// Set initial text or model a competing copy, including identical bytes.
    /// No previous clipboard text enters the event recorder.
    func replaceText(_ text: String?) {
        locked {
            revision += 1
            storedText = text
        }
    }

    func snapshotText(budget: Duration, byteLimit: Int,
                      completion: @escaping (ClipboardTextSnapshot?) -> Void) -> ClipboardSnapshotRead {
        locked {
            recordedSnapshotBudgets.append(budget)
            recordedSnapshotByteLimits.append(byteLimit)
        }
        recorder.events.append(.snapshotClipboard)
        let snapshot: ClipboardTextSnapshot? = locked {
            numberOfReads += 1
            guard !snapshotIsUnavailable, let storedText else { return nil }
            return ClipboardTextSnapshot(text: storedText, revision: Revision(self, value: revision))
        }
        locked { previousSnapshot = snapshot }
        let read = SnapshotRead(self, snapshot: snapshot, completion: completion)
        switch snapshotMode {
        case .immediate:
            onSnapshot?()
            read.complete(repeating: 1)
        case .deferred:
            locked { snapshots.append(read) }
            onSnapshot?()
        }
        return read
    }

    func completeSnapshot(repeating count: Int = 1) {
        let read = locked {
            precondition(!snapshots.isEmpty, "No pending clipboard snapshot read to complete.")
            return snapshots.removeFirst()
        }
        read.complete(repeating: count)
    }

    func writeTextOwning(_ text: String, after snapshotRevision: ClipboardRevision) -> ClipboardWriteOwnership? {
        let ownership: ClipboardWriteOwnership? = locked {
            numberOfOwnershipWrites += 1
            let token = snapshotRevision as? Revision
            let unchanged = token?.clipboard === self && token?.value == revision
            revision += 1
            storedText = text
            return unchanged && canOwnClipboardWrite ? Ownership(self, value: revision) : nil
        }
        recorder.events.append(.write(text))
        return ownership
    }

    func restore(_ snapshot: ClipboardTextSnapshot, ifOwnedBy ownership: ClipboardWriteOwnership) {
        locked { numberOfRestoreCalls += 1 }
        onClipboardRestore?()
        let restored: Bool = locked {
            guard let token = ownership as? Ownership,
                  token.clipboard === self, token.value == revision else { return false }
            storedText = snapshot.withText { $0 }
            revision += 1
            numberOfRestorationWrites += 1
            return true
        }
        if restored {
            recorder.events.append(.restoreClipboard)
        }
    }

    private func locked<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}

final class FakeInjector: PasteInjector {
    let backend: PasteBackend
    var result: PasteAttemptResult = .sent
    var mode: FakeCompletionMode = .immediate
    var onPaste: (() -> Void)?
    private(set) var chords: [PasteChord] = []
    private(set) var consents: [PasteConsent] = []
    private let recorder: DeliveryRecorder
    private var completions: [(PasteAttemptResult) -> Void] = []

    init(_ backend: PasteBackend, recorder: DeliveryRecorder) {
        self.backend = backend
        self.recorder = recorder
    }

    func paste(chord: PasteChord, consent: PasteConsent, completion: @escaping (PasteAttemptResult) -> Void) {
        consents.append(consent)
        paste(chord: chord, completion: completion)
    }

    func paste(chord: PasteChord, completion: @escaping (PasteAttemptResult) -> Void) {
        chords.append(chord)
        recorder.events.append(.paste(backend, chord))
        onPaste?()
        switch mode {
        case .immediate: completion(result)
        case .deferred: completions.append(completion)
        }
    }

    func complete(_ result: PasteAttemptResult) { complete([result]) }

    func complete(_ results: [PasteAttemptResult]) {
        let completion = completions.removeFirst()
        results.forEach(completion)
    }
}

final class FakeNotifier: Notifier {
    private let recorder: DeliveryRecorder
    init(_ recorder: DeliveryRecorder) { self.recorder = recorder }
    func copied() { recorder.events.append(.copied) }
    func pressPaste(chord: PasteChord, reason: CopyReason) {
        recorder.events.append(.pressPaste(chord, reason))
    }
}

final class FakeSession: SessionProbe {
    var session: DesktopSession
    init(_ session: DesktopSession) { self.session = session }
    func currentSession() -> DesktopSession { session }
}

final class FakeFailureCache: PasteFailureCache {
    private(set) var failures: [PasteBackend: PasteFailure] = [:]
    private(set) var resets = 0
    func failure(for backend: PasteBackend) -> PasteFailure? { failures[backend] }
    func record(_ reason: PasteFailure, for backend: PasteBackend) { failures[backend] = reason }
    func reset() {
        resets += 1
        failures.removeAll()
    }
}

final class FakeSelfTestTarget: SelfTestTarget {
    var received: [String?] = []
    private let recorder: DeliveryRecorder
    init(_ recorder: DeliveryRecorder) { self.recorder = recorder }
    func present(fieldExpecting text: String) { recorder.events.append(.testPresent(text)) }
    func readBack() -> String? {
        recorder.events.append(.testReadBack)
        return received.isEmpty ? nil : received.removeFirst()
    }
    func close() { recorder.events.append(.testClose) }
}

final class DeliveryHarness {
    let recorder = DeliveryRecorder()
    let main = FakeMainThread()
    let cache = FakeFailureCache()
    let session: FakeSession
    let scheduler: FakeScheduler
    let focus: FakeFocus
    let clipboard: FakeClipboard
    let injectors: [PasteBackend: FakeInjector]
    let target: FakeSelfTestTarget
    let service: DeliveryService

    init(session: DesktopSession = .macOS, available: [PasteBackend] = PasteBackend.allCases,
         clipboardRestore: ClipboardRestoreMode = .off) {
        let recorder = self.recorder
        self.session = FakeSession(session)
        scheduler = FakeScheduler(recorder)
        focus = FakeFocus(recorder)
        clipboard = FakeClipboard(recorder)
        target = FakeSelfTestTarget(recorder)
        injectors = Dictionary(uniqueKeysWithValues: available.map {
            ($0, FakeInjector($0, recorder: recorder))
        })
        service = DeliveryService(
            panel: FakePanel(recorder), focus: focus, clipboard: clipboard,
            injectors: Array(injectors.values), notifier: FakeNotifier(recorder),
            session: self.session, scheduler: scheduler, mainThread: main, failureCache: cache,
            clipboardRestore: clipboardRestore
        )
    }

    func arm() {
        service.arm()
        main.drain()
        recorder.events.removeAll()
    }

    func deliver(_ text: String = "test", mode: DeliveryMode = .paste(.standard)) {
        service.deliver(text, mode: mode) { self.recorder.events.append(.done($0)) }
    }

    func settle() {
        scheduler.advance(by: session.session == .macOS ? Limits.settleDelayMacOS : Limits.settleDelayLinux)
    }
}
