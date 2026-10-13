import Foundation

/// All I/O goes through the app-data FileStore. LibraryService serializes calls.
final class HistoryStore: PromptKeyedStore, SyncKeyedStore {
    private let files: FileStore
    private let formatter: DateFormatter

    init(files: FileStore) {
        self.files = files
        formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        formatter.isLenient = false
    }

    func revisions(for identity: PromptIdentity) throws -> [HistoryRevision] {
        let prefix = try directory(for: identity) + "/"
        return try files.listFiles().compactMap { file in
            guard file.relativePath.hasPrefix(prefix) else { return nil }
            let filename = String(file.relativePath.dropFirst(prefix.count))
            guard let parts = parts(of: filename) else { return nil }
            return HistoryRevision(identity: identity, filename: filename, timestamp: parts.timestamp)
        }.sorted { $0.filename > $1.filename }
    }

    func snapshot(_ data: Data, for identity: PromptIdentity, at date: Date) throws -> HistoryRevision {
        guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0,
              date.timeIntervalSince1970 < Limits.historyMaxUnixSeconds else {
            throw LibraryError.invalidTimestamp
        }
        let timestamp = formatter.string(from: date)
        guard timestamp.utf8.count == 20, let roundedDate = formatter.date(from: timestamp) else {
            throw LibraryError.invalidTimestamp
        }
        let matching = try revisions(for: identity).filter { $0.filename.hasPrefix(timestamp + "-") }
        let sequence = (matching.compactMap { parts(of: $0.filename)?.sequence }.max() ?? -1) + 1
        guard sequence <= Limits.historySequenceMax else { throw LibraryError.historyCollisionLimitReached }
        let filename = timestamp + "-" + String(format: "%06d", sequence) + ".md"
        let path = try directory(for: identity) + "/" + filename
        guard try files.stamp(at: path) == nil else { throw LibraryError.historyCollisionLimitReached }
        try files.write(data, at: path)
        return HistoryRevision(identity: identity, filename: filename, timestamp: roundedDate)
    }

    func read(_ revision: HistoryRevision) throws -> Data {
        guard parts(of: revision.filename) != nil else { throw LibraryError.revisionNotFound }
        let path = try path(for: revision)
        guard try files.stamp(at: path) != nil else {
            throw LibraryError.revisionNotFound
        }
        do { return try files.read(at: path) }
        catch FileStoreError.notFound { throw LibraryError.revisionNotFound }
    }

    func remove(_ revision: HistoryRevision) throws {
        guard parts(of: revision.filename) != nil else { throw LibraryError.revisionNotFound }
        // A failed revision deletion must leave its attribution intact.
        do { try files.delete(at: path(for: revision)) }
        catch FileStoreError.notFound { throw LibraryError.revisionNotFound }
        try removeProvenance(at: path(for: revision) + ".json")
    }

    func headProvenance(for identity: PromptIdentity, bytes: Data) throws -> PromptProvenance? {
        try provenance(at: directory(for: identity) + "/head.json", bytes: bytes)
    }

    func provenance(for revision: HistoryRevision, bytes: Data) throws -> PromptProvenance? {
        guard parts(of: revision.filename) != nil else { throw LibraryError.revisionNotFound }
        return try provenance(at: path(for: revision) + ".json", bytes: bytes)
    }

    func setHeadProvenance(_ provenance: PromptProvenance?, for identity: PromptIdentity, bytes: Data) throws {
        try setProvenance(provenance, at: directory(for: identity) + "/head.json", bytes: bytes)
    }

    func archiveProvenance(_ provenance: PromptProvenance?, for revision: HistoryRevision, bytes: Data) throws {
        try setProvenance(provenance, at: path(for: revision) + ".json", bytes: bytes)
    }

    private struct ProvenanceRecord: Codable {
        struct Usage: Codable { let inputTokens: Int; let outputTokens: Int }
        let version: Int
        let contentSHA256: String
        let origin: String
        let timestamp: String
        let providerHost: String
        let model: String
        let usage: Usage?
    }

    private func provenance(at path: String, bytes: Data) throws -> PromptProvenance? {
        guard try files.stamp(at: path) != nil else { return nil }
        let record: ProvenanceRecord
        do { record = try JSONDecoder().decode(ProvenanceRecord.self, from: files.read(at: path)) }
        catch let error as FileStoreError { throw error }
        catch { throw LibraryError.invalidProvenance }
        let formatter = provenanceFormatter()
        guard record.version == 1, record.origin == PromptProvenance.Origin.llm.rawValue,
              let date = formatter.date(from: record.timestamp), formatter.string(from: date) == record.timestamp,
              !record.providerHost.isEmpty, !record.model.isEmpty,
              record.usage.map({ $0.inputTokens >= 0 && $0.outputTokens >= 0 }) ?? true else {
            throw LibraryError.invalidProvenance
        }
        guard record.contentSHA256 == SHA256.hexDigest(bytes) else { return nil }
        return PromptProvenance(timestamp: date, providerHost: record.providerHost, model: record.model,
            usage: record.usage.map { AssistantTokenUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens) })
    }

    private func setProvenance(_ provenance: PromptProvenance?, at path: String, bytes: Data) throws {
        guard let provenance else { return try removeProvenance(at: path) }
        guard provenance.timestamp.timeIntervalSince1970.isFinite,
              provenance.timestamp.timeIntervalSince1970 >= 0,
              provenance.timestamp.timeIntervalSince1970 < Limits.historyMaxUnixSeconds,
              !provenance.providerHost.isEmpty, !provenance.model.isEmpty,
              provenance.usage.map({ $0.inputTokens >= 0 && $0.outputTokens >= 0 }) ?? true else {
            throw LibraryError.invalidProvenance
        }
        let record = ProvenanceRecord(version: 1, contentSHA256: SHA256.hexDigest(bytes), origin: provenance.origin.rawValue,
            timestamp: provenanceFormatter().string(from: provenance.timestamp), providerHost: provenance.providerHost,
            model: provenance.model, usage: provenance.usage.map {
                ProvenanceRecord.Usage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try files.writePrivate(encoder.encode(record), at: path)
    }

    private func removeProvenance(at path: String) throws {
        guard try files.stamp(at: path) != nil else { return }
        do { try files.delete(at: path) }
        catch FileStoreError.notFound { /* Another cleanup already removed it. */ }
    }

    private func provenanceFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    func prune(for identity: PromptIdentity) throws {
        // Delete oldest first. Unexpected files are never considered revisions.
        let oldest = try revisions(for: identity).dropFirst(Limits.historyCapPerPrompt).reversed()
        for revision in oldest { try remove(revision) }
    }

    @discardableResult
    func migrateKey(from source: PromptIdentity, to destination: PromptIdentity) throws -> PromptKeyMigration {
        let sourceDirectory = try directory(for: source) + "/"
        let destinationDirectory = try directory(for: destination) + "/"
        guard source != destination else { return .unchanged }
        let allFiles = try files.listFiles()
        let sourceFiles = allFiles.filter { $0.relativePath.hasPrefix(sourceDirectory) }
            .sorted { $0.relativePath < $1.relativePath }
        guard !sourceFiles.isEmpty else { return .unchanged }
        guard !allFiles.contains(where: { $0.relativePath.hasPrefix(destinationDirectory) }) else {
            throw LibraryError.keyedStateConflict
        }

        var completed = [(source: String, destination: String)]()
        do {
            for file in sourceFiles {
                let target = destinationDirectory + file.relativePath.dropFirst(sourceDirectory.count)
                try files.move(from: file.relativePath, to: target)
                completed.append((file.relativePath, target))
            }
        } catch {
            var recovered = true
            for move in completed.reversed() {
                do { try files.move(from: move.destination, to: move.source) }
                catch { recovered = false }
            }
            guard recovered else { throw LibraryError.recoveryRequired }
            throw error
        }
        return .migrated
    }

    private func directory(for identity: PromptIdentity) throws -> String {
        "history/" + (try identity.storageKey)
    }

    var syncKind: SyncKeyedStoreKind { .history }

    // All ordinary history mutations already enter through LibraryService.
    func bindSyncWriteGate(_ gate: SyncLibraryWriteGate) {}

    func isSyncMigrationUnstarted(_ migration: SyncKeyedMigration) throws -> Bool {
        guard case .file(let move) = migration.change else { return false }
        return try move.isUnstarted(files: files)
    }

    func prepareSyncMigration(from source: PromptIdentity, to destination: PromptIdentity,
                              rebindingHeadTo bytes: Data?, originalBytes: Data?) throws -> [SyncKeyedMigration] {
        let prefix = try directory(for: source) + "/"
        let target = try directory(for: destination) + "/"
        let all = try files.listFiles()
        let originals = all.filter { $0.relativePath.utf8.starts(with: prefix.utf8) }
        guard !originals.isEmpty else { return [] }
        guard !all.contains(where: {
            RelativePath($0.relativePath) == RelativePath(String(target.dropLast()))
                || $0.relativePath.utf8.starts(with: target.utf8)
        }) else {
            throw LibraryError.keyedStateConflict
        }
        return try originals.sorted { RelativePath($0.relativePath) < RelativePath($1.relativePath) }.map { file in
            let original = try files.read(at: file.relativePath)
            guard try files.stamp(at: file.relativePath) == file.stamp else { throw LibraryError.conflict }
            let suffix = String(decoding: file.relativePath.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
            var replacement = original
            if suffix == "head.json", let bytes, let originalBytes,
               try provenance(at: file.relativePath, bytes: originalBytes) != nil {
                // Adoption changes the ID/representation of the same prompt.
                // Rebind only attribution still bound to the original bytes;
                // external edits never inherit it and revision hashes stay exact.
                let record = try JSONDecoder().decode(ProvenanceRecord.self, from: original)
                replacement = try JSONEncoder().encode(ProvenanceRecord(version: record.version,
                    contentSHA256: SHA256.hexDigest(bytes), origin: record.origin, timestamp: record.timestamp,
                    providerHost: record.providerHost, model: record.model, usage: record.usage))
            }
            return SyncKeyedMigration(store: .history, change: .file(SyncKeyedFileMove(
                source: file.relativePath, destination: target + suffix, bytes: original, destinationBytes: replacement)))
        }
    }

    func applySyncMigration(_ migration: SyncKeyedMigration, operations: SyncFileOperations) throws {
        guard case .file(let move) = migration.change else { throw SyncError.invalidState }
        try move.apply(files: files, operations: operations)
    }

    private func path(for revision: HistoryRevision) throws -> String {
        try directory(for: revision.identity) + "/" + revision.filename
    }

    private func parts(of filename: String) -> (timestamp: Date, sequence: Int)? {
        let bytes = Array(filename.utf8)
        guard bytes.count == 30, bytes[20] == 45, bytes[27...].elementsEqual(Array(".md".utf8)),
              bytes[21..<27].allSatisfy({ (48...57).contains($0) }) else { return nil }
        let prefix = String(decoding: bytes[..<20], as: UTF8.self)
        guard let date = formatter.date(from: prefix), formatter.string(from: date) == prefix else { return nil }
        let sequence = Int(String(decoding: bytes[21..<27], as: UTF8.self))!
        return (date, sequence)
    }
}
