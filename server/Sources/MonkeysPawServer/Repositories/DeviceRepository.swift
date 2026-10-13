import MonkeysPawCore
import SQLKit

struct DeviceRecord: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: String
    let userID: String
    let name: String
    let tokenHash: String
    let createdAt: String
    let lastSeenAt: String?
    let revokedAt: String?

    var description: String { "DeviceRecord(<redacted>)" }
    var debugDescription: String { description }

    func metadata(currentDeviceID: String) -> SyncAPI.Device {
        .init(id: id, name: name, createdAt: createdAt, lastSeenAt: lastSeenAt,
              revokedAt: revokedAt, isCurrent: id == currentDeviceID)
    }
}

private extension DeviceRecord {
    init(row: any SQLRow) throws {
        id = try row.decode(column: "id", as: String.self)
        userID = try row.decode(column: "user_id", as: String.self)
        name = try row.decode(column: "name", as: String.self)
        tokenHash = try row.decode(column: "token_hash", as: String.self)
        createdAt = try row.decode(column: "created_at", as: String.self)
        lastSeenAt = try row.decode(column: "last_seen_at", as: String?.self)
        revokedAt = try row.decode(column: "revoked_at", as: String?.self)
    }
}

struct DeviceRepository: Sendable {
    let sql: any SQLDatabase

    func device(id: String) async throws -> DeviceRecord? {
        try await sql.raw("SELECT * FROM devices WHERE id = \(bind: id)").first().map(DeviceRecord.init(row:))
    }

    func device(tokenHash: String) async throws -> DeviceRecord? {
        try await sql.raw("SELECT * FROM devices WHERE token_hash = \(bind: tokenHash)").first().map(DeviceRecord.init(row:))
    }

    func list(userID: String) async throws -> [DeviceRecord] {
        try await sql.raw("SELECT * FROM devices WHERE user_id = \(bind: userID) ORDER BY created_at, id")
            .all().map(DeviceRecord.init(row:))
    }

    func insert(_ device: DeviceRecord) async throws {
        try await sql.raw("""
            INSERT INTO devices (id, user_id, name, token_hash, created_at, last_seen_at, revoked_at)
            VALUES (\(bind: device.id), \(bind: device.userID), \(bind: device.name), \(bind: device.tokenHash),
                    \(bind: device.createdAt), \(bind: device.lastSeenAt), \(bind: device.revokedAt))
            """).run()
    }

    func markSeen(id: String, at: String, cutoff: String) async throws {
        try await sql.raw("""
            UPDATE devices SET last_seen_at = \(bind: at) WHERE id = \(bind: id) AND revoked_at IS NULL
                AND (last_seen_at IS NULL OR last_seen_at <= \(bind: cutoff))
            """).run()
    }

    func revoke(id: String, userID: String, at: String) async throws {
        try await sql.raw("""
            UPDATE devices SET revoked_at = \(bind: at)
            WHERE id = \(bind: id) AND user_id = \(bind: userID) AND revoked_at IS NULL
            """).run()
    }

    func revokeOthers(userID: String, keeping deviceID: String, at: String) async throws {
        try await sql.raw("""
            UPDATE devices SET revoked_at = \(bind: at)
            WHERE user_id = \(bind: userID) AND id != \(bind: deviceID) AND revoked_at IS NULL
            """).run()
    }

    func revokeAll(userID: String, at: String) async throws {
        try await sql.raw("""
            UPDATE devices SET revoked_at = \(bind: at)
            WHERE user_id = \(bind: userID) AND revoked_at IS NULL
            """).run()
    }
}
