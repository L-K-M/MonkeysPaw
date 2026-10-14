import Foundation

public enum UpdateStateError: Error, Equatable, Sendable {
    case corruptFile
    case futureVersion(Int)
    case readFailed(FileStoreError)
    case writeFailed(FileStoreError)
}

struct UpdateStateRecord: Equatable, Sendable {
    var lastAutomaticAttempt: Date?
    var lastSuccessfulCheck: Date?
    var rateLimit: UpdateRateLimit?

    var nextAutomaticCheck: Date? {
        [lastAutomaticAttempt, lastSuccessfulCheck].compactMap { $0 }
            .max()?.addingTimeInterval(Limits.updateCheckInterval)
    }
}

/// One instance per app-data root, shared across update-service lifetimes.
/// The lock owns each read/claim/private atomic replacement. Claiming the
/// attempt before HTTP preserves cadence even when the request/app fails.
public final class UpdateStateStore: @unchecked Sendable {
    private struct Payload: Codable {
        var version = 1
        var lastAutomaticAttempt: Double?
        var lastSuccessfulCheck: Double?
        var rateLimitUntil: Double?
        var rateLimitStatus: Int?
    }

    private let files: FileStore
    private let path = "update-state.json"
    private let lock = NSLock()
    private var readOnlyError: UpdateStateError?

    public init(files: FileStore) { self.files = files }

    func read(at now: Date) throws -> UpdateStateRecord {
        try locked { try load(at: now) }
    }

    /// Nil means another attempt or successful manual check already deferred it.
    func claimAutomaticAttempt(at now: Date) throws -> UpdateStateRecord? {
        try locked {
            var record = try load(at: now)
            if let next = record.nextAutomaticCheck, now < next { return nil }
            if let limit = record.rateLimit, now < limit.until { return nil }
            record.lastAutomaticAttempt = now
            try save(record)
            return record
        }
    }

    func recordSuccess(at now: Date) throws -> UpdateStateRecord {
        try locked {
            var record = try load(at: now)
            record.lastSuccessfulCheck = now
            try save(record)
            return record
        }
    }

    func recordRateLimit(_ limit: UpdateRateLimit, at now: Date) throws -> UpdateStateRecord {
        try locked {
            var record = try load(at: now)
            record.rateLimit = limit
            try save(record)
            return record
        }
    }

    private func load(at now: Date) throws -> UpdateStateRecord {
        if let readOnlyError { throw readOnlyError }
        do {
            let timestamp = now.timeIntervalSince1970
            guard timestamp.isFinite, timestamp >= 0, timestamp < Limits.historyMaxUnixSeconds else {
                throw UpdateStateError.corruptFile
            }
            let bytes: Data
            do { bytes = try files.read(at: path) }
            catch FileStoreError.notFound { return UpdateStateRecord() }
            guard bytes.count <= Limits.updateStateFileCap else { throw UpdateStateError.corruptFile }
            // Unset fields are omitted by our encoder. Present null must not
            // erase a throttle timestamp and authorize fresh automatic traffic.
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  !["lastAutomaticAttempt", "lastSuccessfulCheck", "rateLimitUntil", "rateLimitStatus"]
                    .contains(where: { object[$0] is NSNull }) else { throw UpdateStateError.corruptFile }
            let payload = try JSONDecoder().decode(Payload.self, from: bytes)
            if payload.version > 1 { throw UpdateStateError.futureVersion(payload.version) }
            guard payload.version == 1,
                  [payload.lastAutomaticAttempt, payload.lastSuccessfulCheck].compactMap({ $0 }).allSatisfy({
                      $0.isFinite && $0 >= 0 && $0 <= timestamp
                  }), (payload.rateLimitUntil == nil) == (payload.rateLimitStatus == nil) else {
                throw UpdateStateError.corruptFile
            }
            var limit: UpdateRateLimit?
            if let until = payload.rateLimitUntil, let status = payload.rateLimitStatus {
                guard until.isFinite, until >= 0, until < Limits.historyMaxUnixSeconds,
                      status == 403 || status == 429 else { throw UpdateStateError.corruptFile }
                limit = UpdateRateLimit(statusCode: status, until: Date(timeIntervalSince1970: until))
            }
            return UpdateStateRecord(lastAutomaticAttempt: payload.lastAutomaticAttempt.map(Date.init(timeIntervalSince1970:)),
                lastSuccessfulCheck: payload.lastSuccessfulCheck.map(Date.init(timeIntervalSince1970:)), rateLimit: limit)
        } catch {
            let sanitized: UpdateStateError
            if let failure = error as? UpdateStateError { sanitized = failure }
            else if let failure = error as? FileStoreError { sanitized = .readFailed(failure) }
            else { sanitized = .corruptFile }
            // Corruption/future clock state never becomes permission to overwrite.
            readOnlyError = sanitized
            throw sanitized
        }
    }

    private func save(_ record: UpdateStateRecord) throws {
        let payload = Payload(lastAutomaticAttempt: record.lastAutomaticAttempt?.timeIntervalSince1970,
            lastSuccessfulCheck: record.lastSuccessfulCheck?.timeIntervalSince1970,
            rateLimitUntil: record.rateLimit?.until.timeIntervalSince1970,
            rateLimitStatus: record.rateLimit?.statusCode)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try files.writePrivate(try encoder.encode(payload), at: path)
        } catch let failure as FileStoreError { throw UpdateStateError.writeFailed(failure) }
        catch { throw UpdateStateError.writeFailed(.ioFailure) }
    }

    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }
}
