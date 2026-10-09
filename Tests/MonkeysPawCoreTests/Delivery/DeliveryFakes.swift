import MonkeysPawCore

enum DeliveryEvent: Equatable {
    case capture, show, hide, hideForDelivery
    case write(String), wait(Duration), restore(DeliveryTarget)
    case paste(PasteBackend, PasteChord)
    case copied, pressPaste(PasteChord, CopyReason), done(DeliveryOutcome)
    case testPresent(String), testReadBack, testClose
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

final class FakeClipboard: Clipboard {
    private(set) var text: String?
    private let recorder: DeliveryRecorder
    init(_ recorder: DeliveryRecorder) { self.recorder = recorder }
    func readText() -> String? { text }
    func writeText(_ text: String) {
        self.text = text
        recorder.events.append(.write(text))
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

    init(session: DesktopSession = .macOS, available: [PasteBackend] = PasteBackend.allCases) {
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
            session: self.session, scheduler: scheduler, mainThread: main, failureCache: cache
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
