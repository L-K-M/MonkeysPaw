import Foundation

/// One private, versioned record per app-data root, separate from frecency and
/// values.json. Share this instance across graph lifetimes. Clear replaces even
/// unreadable/corrupt state with a tombstone without first reading it.
public final class LastDeliveryStore: @unchecked Sendable {
    private struct Payload: Codable {
        let version: Int
        let record: LastDeliveryRecord?

        private enum CodingKeys: String, CodingKey { case version, record }

        init(record: LastDeliveryRecord?) { version = 1; self.record = record }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            guard version <= 1 else { throw RepeatFailure.futureRecord }
            guard version == 1, container.contains(.record) else { throw RepeatFailure.corruptRecord }
            record = try container.decodeIfPresent(LastDeliveryRecord.self, forKey: .record)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(record, forKey: .record)
        }
    }

    private let files: FileStore
    private let lock = NSLock()
    private let path = "last-delivery.json"
    // A failed clear must survive fresh services sharing this store. Only a
    // durable tombstone can reopen recording and repeat.
    private var invalidationFailed = false

    var requiresInvalidation: Bool { lock.withLock { invalidationFailed } }

    public init(files: FileStore) { self.files = files }

    func load() throws -> LastDeliveryRecord? {
        try lock.withLock {
            do {
                let bytes: Data
                do { bytes = try files.read(at: path) }
                catch FileStoreError.notFound { return nil }
                catch { throw RepeatFailure.readFailed }
                guard bytes.count <= Limits.lastDeliveryFileCapBytes else { throw RepeatFailure.recordTooLarge }
                let payload = try JSONDecoder().decode(Payload.self, from: bytes)
                try payload.record?.validate()
                return payload.record
            } catch let error as RepeatFailure { throw error }
            catch { throw RepeatFailure.corruptRecord }
        }
    }

    func save(_ record: LastDeliveryRecord?) throws {
        try lock.withLock {
            guard record == nil || !invalidationFailed else { throw RepeatFailure.invalidationFailed }
            do {
                try record?.validate()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let bytes = try encoder.encode(Payload(record: record))
                guard bytes.count <= Limits.lastDeliveryFileCapBytes else { throw RepeatFailure.recordTooLarge }
                try files.writePrivate(bytes, at: path)
                if record == nil { invalidationFailed = false }
            } catch {
                if record == nil { invalidationFailed = true }
                throw error as? RepeatFailure ?? .writeFailed
            }
        }
    }
}
