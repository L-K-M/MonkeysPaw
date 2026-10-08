/// §6.5 readback distinguishes a sent chord from text actually reaching a field.
public final class SelfTest {
    private let target: SelfTestTarget
    private let delivery: DeliveryService
    private let session: SessionProbe
    private let scheduler: Scheduler
    private let mainThread: MainThread
    private var isRunning = false
    private var completions: [(SelfTestReport) -> Void] = []

    public init(
        target: SelfTestTarget, delivery: DeliveryService, session: SessionProbe,
        scheduler: Scheduler, mainThread: MainThread
    ) {
        self.target = target
        self.delivery = delivery
        self.session = session
        self.scheduler = scheduler
        self.mainThread = mainThread
    }

    public func run(done: @escaping (SelfTestReport) -> Void) {
        mainThread.run {
            // Concurrent callers share a report rather than competing for focus.
            self.completions.append(done)
            guard !self.isRunning else { return }
            self.isRunning = true
            self.delivery.performSelfTest { finished in
                let session = self.session.currentSession()
                self.delivery.resetFailures()
                self.test(PasteLadder.backends(for: session)[...], session: session,
                          results: [], finished: finished)
            }
        }
    }

    private func test(
        _ remaining: ArraySlice<PasteBackend>, session: DesktopSession,
        results: [SelfTestResult], finished: @escaping () -> Void
    ) {
        guard let backend = remaining.first else {
            let report = SelfTestReport(session: session, results: results)
            isRunning = false
            let callbacks = completions
            completions.removeAll()
            callbacks.forEach { $0(report) }
            finished()
            return
        }

        target.present(fieldExpecting: DeliveryStrings.testPrompt)
        delivery.deliverForSelfTest(DeliveryStrings.testPrompt, through: backend) { outcome in
            var didReadBack = false
            self.scheduler.after(Limits.selfTestReadBackDelay) {
                self.mainThread.run {
                    guard !didReadBack else { return }
                    didReadBack = true
                    let received = self.target.readBack()
                    let status = self.status(for: outcome, received: received)
                    if status == .sentButNotReceived { self.delivery.recordUnreceived(backend) }
                    self.target.close()
                    self.test(remaining.dropFirst(), session: session,
                              results: results + [SelfTestResult(backend: backend, status: status)],
                              finished: finished)
                }
            }
        }
    }

    private func status(for outcome: DeliveryOutcome, received: String?) -> SelfTestStatus {
        switch outcome {
        case .pasted:
            return received == DeliveryStrings.testPrompt ? .pasted : .sentButNotReceived
        case .copiedOnly(.backendsFailed(let failures)):
            return .failed(failures.first?.reason ?? .unknown)
        case .copiedOnly(.requested):
            return .failed(.unknown)
        }
    }
}
