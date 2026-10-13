import Foundation
import Logging

struct RetentionCounts: Sendable, Equatable {
    var changes = 0
    var floors = 0
    var tombstones = 0
    var revisions = 0
}

struct RetentionService: Sendable {
    private let repository: RetentionRepository
    private let clock: @Sendable () -> Date
    private let logger: Logger

    init(database: ServerDatabase, clock: @escaping @Sendable () -> Date = { Date() },
         logger: Logger = ServerLogging.logger()) {
        repository = RetentionRepository(database: database)
        self.clock = clock
        self.logger = logger
    }

    @discardableResult
    func run() async throws -> RetentionCounts {
        let cutoff = ServerTimestamp.string(clock().addingTimeInterval(-TimeInterval(ServerLimits.changeRetentionDays * 24 * 60 * 60)))
        var total = RetentionCounts()
        while true {
            try Task.checkCancellation()
            let batch = try await repository.purgeChanges(before: cutoff)
            record(batch, total: &total)
            if batch.changes < ServerLimits.retentionBatchSize { break }
            await Task.yield()
        }

        while true {
            try Task.checkCancellation()
            let batch = try await repository.purgeTombstone(before: cutoff)
            if batch == RetentionCounts() { break }
            record(batch, total: &total)
            await Task.yield()
        }

        var after = ""
        while true {
            try Task.checkCancellation()
            let ids = try await repository.revisionPromptIDs(after: after)
            if ids.isEmpty { break }
            for id in ids {
                while true {
                    try Task.checkCancellation()
                    let batch = try await repository.pruneRevisions(id: id)
                    record(batch, total: &total)
                    await Task.yield()
                    if batch.revisions < ServerLimits.retentionBatchSize { break }
                }
            }
            after = ids[ids.count - 1]
        }
        return total
    }

    private func record(_ batch: RetentionCounts, total: inout RetentionCounts) {
        total.changes += batch.changes
        total.floors += batch.floors
        total.tombstones += batch.tombstones
        total.revisions += batch.revisions
        guard batch != RetentionCounts() else { return }
        logger.info("Retention batch committed", metadata: [
            "changes_purged": .string(String(batch.changes)), "floors_raised": .string(String(batch.floors)),
            "tombstones_purged": .string(String(batch.tombstones)), "revisions_pruned": .string(String(batch.revisions))
        ])
    }
}
