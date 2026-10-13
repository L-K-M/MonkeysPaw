import Logging
import ServiceLifecycle

/// The application owns this task and waits for it before the database closes.
struct RetentionScheduler: Service {
    private let maintenance: RetentionService
    private let logger: Logger
    private let interval: Duration

    init(maintenance: RetentionService, logger: Logger, interval: Duration = ServerLimits.retentionInterval) {
        self.maintenance = maintenance
        self.logger = logger
        self.interval = interval
    }

    func run() async throws {
        do {
            try await cancelWhenGracefulShutdown {
                while true {
                    try Task.checkCancellation()
                    do {
                        try await maintenance.run()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // A driver failure may contain prompt bytes; report no error text.
                        logger.error("Retention maintenance failed", metadata: ["failed_runs": "1"])
                    }
                    try await Task.sleep(for: interval)
                }
            }
        } catch is CancellationError {
            // Graceful shutdown and task cancellation both await the active batch.
        }
    }
}
