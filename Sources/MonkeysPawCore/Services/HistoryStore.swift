import Foundation

/// All I/O goes through the app-data FileStore. LibraryService serializes calls.
final class HistoryStore: PromptKeyedStore {
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
        return try files.read(at: path)
    }

    func remove(_ revision: HistoryRevision) throws {
        guard parts(of: revision.filename) != nil else { throw LibraryError.revisionNotFound }
        try files.delete(at: path(for: revision))
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
