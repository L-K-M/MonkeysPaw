import Foundation
import ServiceLifecycle
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerRetentionSchedulerTests {
    @Test func databaseApplicationRegistersOneMaintenanceTask() async throws {
        try await withPersistenceDatabase { repository in
            let configuration = try ServerConfiguration(environment: [:])
            let app = buildApplication(configuration: configuration, database: repository.database)
            #expect(app.services.count == 1 && app.services[0] is RetentionScheduler)
            #expect(buildApplication(configuration: configuration).services.isEmpty)
        }
    }

    @Test func schedulerRunsAtStartupAndPeriodicallyThenStopsOnGracefulShutdown() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            try await repository.execute(PersistenceTestRepository.change())
            let logs = CapturedServerLogs()
            let logger = ServerLogging.makeLogger(level: .info, sink: logs.write)
            let now = try #require(ServerTimestamp.date(PersistenceTestRepository.purgeCutoff))
            let maintenance = RetentionService(database: repository.database, clock: { now }, logger: logger)
            let scheduler = RetentionScheduler(maintenance: maintenance, logger: logger, interval: .milliseconds(30))
            let group = ServiceGroup(services: [scheduler], logger: logger)
            let running = Task { try await group.run() }
            do {
                try await waitForRetention { try logs.events().filter { $0.message == "Retention batch committed" }.count >= 1 }
                #expect(try await repository.count("changes") == 0)
                try await repository.execute(PersistenceTestRepository.change())
                try await waitForRetention { try logs.events().filter { $0.message == "Retention batch committed" }.count >= 2 }
                #expect(try await repository.count("changes") == 0)
                await group.triggerGracefulShutdown()
                try await running.value
            } catch {
                await group.triggerGracefulShutdown()
                _ = await running.result
                throw error
            }
            try await repository.execute(PersistenceTestRepository.change())
            try await Task.sleep(for: .milliseconds(100))
            #expect(try await repository.count("changes") == 1)
            #expect(try logs.events().filter { $0.message == "Retention batch committed" }.count == 2)
        }
    }

    @Test func failedRunsLogOnlyCountsAndRetryAtTheNextInterval() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            try await repository.execute(PersistenceTestRepository.change(content: "s15-content-sentinel"))
            try await repository.execute("""
                CREATE TRIGGER retention_scheduler_failure BEFORE DELETE ON changes
                BEGIN SELECT RAISE(ABORT, 's15-error-body-sentinel'); END
                """)
            let logs = CapturedServerLogs()
            let logger = ServerLogging.makeLogger(level: .trace, sink: logs.write)
            let now = try #require(ServerTimestamp.date(PersistenceTestRepository.purgeCutoff))
            let maintenance = RetentionService(database: repository.database, clock: { now }, logger: logger)
            let scheduler = RetentionScheduler(maintenance: maintenance, logger: logger, interval: .milliseconds(30))
            let running = Task { try await scheduler.run() }
            do {
                try await waitForRetention { try logs.events().filter { $0.message == "Retention maintenance failed" }.count >= 2 }
                #expect(try await repository.count("changes") == 1)
                #expect(try await repository.count("scope_floors") == 0)
                try await repository.execute("DROP TRIGGER retention_scheduler_failure")
                try await waitForRetention { try logs.events().contains { $0.message == "Retention batch committed" } }
                running.cancel()
                try await running.value
            } catch {
                running.cancel()
                _ = await running.result
                throw error
            }
            let events = try logs.events()
            let failures = events.filter { $0.message == "Retention maintenance failed" }
            #expect(failures.count >= 2)
            #expect(failures.first?.fields == ["failed_runs": "1"])
            // Each failed attempt reports its own count, including retries before the trigger is dropped.
            #expect(failures.allSatisfy { $0.fields == ["failed_runs": "1"] })
            let committed = events.filter { $0.message == "Retention batch committed" }
            #expect(committed.count == 1)
            #expect(committed.first?.fields == ["changes_purged": "1", "floors_raised": "1", "revisions_pruned": "0", "tombstones_purged": "0"])
            let text = String(decoding: logs.snapshot(), as: UTF8.self)
            #expect(!text.contains("s15-content-sentinel") && !text.contains("s15-error-body-sentinel"))
            #expect(!text.contains(PersistenceTestRepository.user) && !text.contains(PersistenceTestRepository.prompt))
            #expect(try await repository.count("changes") == 0)
        }
    }

    @Test func cancellationWhileWaitingForTheWriterLeavesNoBackgroundMaintenance() async throws {
        try await withPersistenceDatabase { repository in
            try await repository.seed()
            try await repository.execute(PersistenceTestRepository.change())
            let gate = try #require(Mirror(reflecting: repository.database).children
                .first { $0.label == "gate" }?.value as? WriterGate)
            let logs = CapturedServerLogs()
            let logger = ServerLogging.makeLogger(level: .trace, sink: logs.write)
            let now = try #require(ServerTimestamp.date(PersistenceTestRepository.purgeCutoff))
            let scheduler = RetentionScheduler(maintenance: .init(database: repository.database, clock: { now }, logger: logger), logger: logger)
            let entered = RetentionTestLatch()
            let release = RetentionTestLatch()
            let writer = Task {
                try await repository.database.write { _ in
                    await entered.open()
                    await release.wait()
                }
            }
            await entered.wait()
            let running = Task { try await scheduler.run() }
            do {
                // Only the startup pass can enter this queue while the writer's latch is held.
                try await waitForRetention { try await gate.queuedWriterCount() == 1 }
                running.cancel()
                await release.open()
                try await writer.value
                try await running.value
            } catch {
                running.cancel()
                await release.open()
                _ = await writer.result
                _ = await running.result
                throw error
            }
            #expect(try await repository.count("changes") == 1)
            #expect(try await repository.count("scope_floors") == 0)
            #expect(try logs.events().isEmpty)
        }
    }

    @Test func countLogFieldsRejectNegativeNoncanonicalAndSecretValues() throws {
        let logs = CapturedServerLogs()
        let logger = ServerLogging.makeLogger(level: .trace, sink: logs.write)
        logger.info("Retention batch committed", metadata: [
            "changes_purged": "100", "floors_raised": "-1", "revisions_pruned": "+1",
            "tombstones_purged": "s15-secret-sentinel", "failed_runs": "01"
        ])
        #expect(try logs.events().first?.fields == ["changes_purged": "100"])
        #expect(!String(decoding: logs.snapshot(), as: UTF8.self).contains("s15-secret-sentinel"))
    }
}

private func waitForRetention(_ condition: @Sendable () async throws -> Bool) async throws {
    for _ in 0..<1_000 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw RetentionTestTimeout()
}

private struct RetentionTestTimeout: Error {}

private extension WriterGate {
    // Reflect under actor isolation so queue observation needs no production test hook.
    func queuedWriterCount() throws -> Int {
        let waiters = try #require(Mirror(reflecting: self).children
            .first { $0.label == "waiters" }?.value as? [CheckedContinuation<Void, Never>])
        return waiters.count
    }
}

private actor RetentionTestLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
