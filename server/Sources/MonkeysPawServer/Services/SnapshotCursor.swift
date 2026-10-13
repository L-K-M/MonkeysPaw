import Crypto
import Foundation
import MonkeysPawCore

/// Authenticated independently of the manifest, so missing/restarted manifests
/// can be distinguished from altered cursors after expiry or a process restart.
struct SnapshotCursor: Sendable {
    let databaseID: String
    let scopeKey: String
    let head: Int64
    let generation: String
    let position: Int
    private let signature: Data

    init(databaseID: String, scopeKey: String, head: Int64, generation: String, position: Int) {
        self.databaseID = databaseID
        self.scopeKey = scopeKey
        self.head = head
        self.generation = generation
        self.position = position
        signature = Data()
    }

    init(_ value: String) throws {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 9, fields[0] == "snap", fields[1] == "1",
              let database = UUID(uuidString: fields[2]), database.uuidString.lowercased() == fields[2],
              ["user", "group"].contains(fields[3]), ULID(fields[4])?.rawValue == fields[4],
              let head = Int64(fields[5]), head > 0, String(head) == fields[5],
              let generation = UUID(uuidString: fields[6]), generation.uuidString.lowercased() == fields[6],
              let position = Int(fields[7]), position >= 0, String(position) == fields[7],
              fields[8].utf8.count == SHA256.byteCount * 2,
              fields[8].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AccountError.malformedRequest
        }
        databaseID = fields[2]
        scopeKey = fields[3] + ":" + fields[4]
        self.head = head
        self.generation = fields[6]
        self.position = position
        let hex = Array(fields[8].utf8)
        signature = Data(stride(from: 0, to: hex.count, by: 2).map {
            func nibble(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : byte - 87 }
            return nibble(hex[$0]) * 16 + nibble(hex[$0 + 1])
        })
    }

    func validate(using key: SymmetricKey) throws {
        guard HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data(payload.utf8), using: key) else {
            throw AccountError.malformedRequest
        }
    }

    func value(using key: SymmetricKey) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        return payload + ":" + code.map { String(format: "%02x", $0) }.joined()
    }

    private var payload: String { "snap:1:\(databaseID):\(scopeKey):\(head):\(generation):\(position)" }
}
