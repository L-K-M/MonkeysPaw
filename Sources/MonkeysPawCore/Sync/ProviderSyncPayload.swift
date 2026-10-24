import Foundation

/// §26 S4/S5: typed failures only; payloads, keys and ciphertext never enter
/// error values or diagnostics.
enum ProviderSyncError: Error, Equatable {
    case invalidKey
    case invalidDocument
    case authentication
    case unsupportedVersion
    case oversized
}

/// `document` is unpadded base64url of `0x01 ‖ IV(12) ‖ ciphertext ‖ tag(16)`
/// sealed with AES-256-GCM; AAD binds the ciphertext to the sync account.
enum ProviderSyncCipher {
    static let aadPrefix = "monkeyspaw/provider-settings/v1:"

    static func seal(key: Data, userID: ULID, plaintext: Data, nonce: () throws -> Data) throws -> String {
        guard key.count == AES256GCM.keyBytes else { throw ProviderSyncError.invalidKey }
        guard plaintext.count <= Limits.providerSyncPayloadMaxBytes else { throw ProviderSyncError.oversized }
        let iv = try nonce()
        guard iv.count == AES256GCM.nonceBytes else { throw ProviderSyncError.invalidKey }
        let aad = Array((aadPrefix + userID.rawValue).utf8)
        let sealed = AES256GCM.seal(key: Array(key), nonce: Array(iv), aad: aad, plaintext: Array(plaintext))
        return Base64URL.encode([0x01] + Array(iv) + sealed)
    }

    static func open(_ document: String, key: Data, userID: ULID) throws -> Data {
        guard key.count == AES256GCM.keyBytes else { throw ProviderSyncError.invalidKey }
        // Accept every document seal can produce, including an empty plaintext.
        guard let bytes = Base64URL.decode(document), bytes.count >= 1 + AES256GCM.nonceBytes + AES256GCM.tagBytes,
              bytes[0] == 0x01 else { throw ProviderSyncError.invalidDocument }
        let nonce = Array(bytes[1..<1 + AES256GCM.nonceBytes])
        let sealed = Array(bytes.dropFirst(1 + AES256GCM.nonceBytes))
        let aad = Array((aadPrefix + userID.rawValue).utf8)
        guard let plaintext = AES256GCM.open(key: Array(key), nonce: nonce, aad: aad, sealed: sealed) else {
            throw ProviderSyncError.authentication
        }
        // No size check here: open is the authentication boundary and every
        // throw above it means "not sealed under this key". The payload
        // parser bounds the plaintext so oversized documents fail closed.
        return Data(plaintext)
    }
}

/// Strict unpadded base64url, used by both the wire document and the key text.
enum Base64URL {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var result = ""
        result.reserveCapacity((bytes.count + 2) / 3 * 4)
        var index = 0
        while index < bytes.count {
            let b0 = bytes[index]
            let b1 = index + 1 < bytes.count ? bytes[index + 1] : 0
            let b2 = index + 2 < bytes.count ? bytes[index + 2] : 0
            result.append(Character(UnicodeScalar(alphabet[Int(b0 >> 2)])))
            result.append(Character(UnicodeScalar(alphabet[Int((b0 & 0x03) << 4 | b1 >> 4)])))
            if index + 1 < bytes.count {
                result.append(Character(UnicodeScalar(alphabet[Int((b1 & 0x0f) << 2 | b2 >> 6)])))
            }
            if index + 2 < bytes.count {
                result.append(Character(UnicodeScalar(alphabet[Int(b2 & 0x3f)])))
            }
            index += 3
        }
        return result
    }

    static func decode(_ text: String) -> [UInt8]? {
        var table = [UInt8](repeating: 0xff, count: 128)
        for (value, byte) in alphabet.enumerated() { table[Int(byte)] = UInt8(value) }
        let scalars = Array(text.utf8)
        guard !scalars.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(scalars.count * 3 / 4)
        var index = 0
        while index < scalars.count {
            let remaining = scalars.count - index
            guard remaining >= 2 else { return nil }
            var digits = [UInt8](repeating: 0, count: 4)
            let count = min(4, remaining)
            for offset in 0..<count {
                let byte = scalars[index + offset]
                guard byte < 128, table[Int(byte)] != 0xff else { return nil }
                digits[offset] = table[Int(byte)]
            }
            // A partial final group must not carry nonzero tail bits.
            if count == 2 && digits[1] & 0x0f != 0 { return nil }
            if count == 3 && digits[2] & 0x03 != 0 { return nil }
            bytes.append(digits[0] << 2 | digits[1] >> 4)
            if count >= 3 { bytes.append(digits[1] << 4 | digits[2] >> 2) }
            if count == 4 { bytes.append(digits[2] << 6 | digits[3]) }
            index += 4
        }
        return bytes
    }
}

/// §26 S4: `{"version":1,"settings":<stored object verbatim>,"secrets":{account:envelope}}`.
/// The whole stored settings object survives, including unknown fields.
struct ProviderSyncPayload: Equatable {
    static let version = 1
    let settings: [String: Any]
    let secrets: [String: String]

    static func == (lhs: Self, rhs: Self) -> Bool {
        canonical(lhs.settings) == canonical(rhs.settings) && lhs.secrets == rhs.secrets
    }

    /// Number-form differences collapse through sorted-key serialization.
    private static func canonical(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Canonical sorted-key JSON, capped by the §26 payload bound.
    func encode() throws -> Data {
        let object: [String: Any] = ["version": Self.version, "settings": settings, "secrets": secrets]
        guard JSONSerialization.isValidJSONObject(object),
              let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              bytes.count <= Limits.providerSyncPayloadMaxBytes else { throw ProviderSyncError.oversized }
        return bytes
    }

    init(settings: [String: Any], secrets: [String: String]) {
        self.settings = settings
        self.secrets = secrets
    }

    init(plaintext: Data) throws {
        guard plaintext.count <= Limits.providerSyncPayloadMaxBytes,
              let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              object.keys.sorted() == ["secrets", "settings", "version"],
              Self.isPayloadVersion(object["version"]),
              let settings = object["settings"] as? [String: Any],
              let secrets = object["secrets"] as? [String: Any],
              secrets.count <= Limits.providerSyncSecretEntries else { throw ProviderSyncError.invalidDocument }
        var values: [String: String] = [:]
        for (account, value) in secrets {
            guard let envelope = value as? String, envelope.utf8.count <= Limits.providerSyncSecretBytes,
                  (try? SecretAccount(coding: account)) != nil else { throw ProviderSyncError.invalidDocument }
            values[account] = envelope
        }
        self.init(settings: settings, secrets: values)
    }

    /// JSON booleans arrive as NSCFBoolean (objCType "c"); doubles and floats
    /// as "d"/"f". Any other numeric objCType is an integer, so only those may
    /// equal the expected payload version.
    private static func isPayloadVersion(_ value: Any?) -> Bool {
        guard let version = value as? NSNumber,
              !["c", "d", "f"].contains(String(cString: version.objCType)) else { return false }
        return version.int64Value == Int64(Self.version)
    }
}

extension SecretAccount {
    /// Split validation for the "namespace:name" payload/spelling form.
    init(coding rawValue: String) throws {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw SecretStoreError.invalidAccount }
        try self.init(namespace: String(parts[0]), name: String(parts[1]))
    }
}
