import Foundation
import XCTest
@testable import MonkeysPawCore

final class ProviderSyncCipherTests: XCTestCase {
    private let userID = SyncTestValues.user
    private let key = Data(hex:
        "feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308")
    private let nonce = Data(hex: "cafebabefacedbaddecaf888")

    func testAES256GCMSealsTheNISTVector() throws {
        // McGrew–Viega AES-256-GCM test case 16 verbatim: K, IV, P, A, C and T.
        let aad = Array(Data(hex: "feedfacedeadbeeffeedfacedeadbeefabaddad2"))
        let plaintext = Array(Data(hex:
            "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72" +
            "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39"))
        let sealed = AES256GCM.seal(key: Array(key), nonce: Array(nonce), aad: aad, plaintext: plaintext)
        XCTAssertEqual(Data(sealed.dropLast(16)).map { String(format: "%02x", $0) }.joined(),
            "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa" +
            "8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662")
        XCTAssertEqual(sealed.suffix(16).map { String(format: "%02x", $0) }.joined(),
            "76fc6ece0f4e1768cddf8853bb2d551b")
        XCTAssertEqual(AES256GCM.open(key: Array(key), nonce: Array(nonce), aad: aad, sealed: sealed), plaintext)
    }

    func testAES256GCMEmptyPlaintextAndAADIndependent() throws {
        let sealed = AES256GCM.seal(key: [UInt8](repeating: 0, count: 32),
            nonce: [UInt8](repeating: 0, count: 12), aad: [], plaintext: [])
        XCTAssertEqual(sealed.map { String(format: "%02x", $0) }.joined(), "530f8afbc74536b9a963b4f1c4cb738b")
        let withAAD = AES256GCM.seal(key: [UInt8](repeating: 0, count: 32),
            nonce: [UInt8](repeating: 0, count: 12), aad: Array("bound".utf8), plaintext: [])
        XCTAssertNotEqual(withAAD, sealed)
    }

    func testCipherDocumentRoundTripsWithVersionByteAndNonce() throws {
        let plaintext = Data("{\"secrets\":{},\"settings\":{},\"version\":1}".utf8)
        let document = try ProviderSyncCipher.seal(key: key, userID: userID, plaintext: plaintext) { nonce }
        let bytes = try XCTUnwrap(Base64URL.decode(document))
        XCTAssertEqual(bytes[0], 0x01)
        XCTAssertEqual(Data(bytes[1..<13]), nonce)
        XCTAssertEqual(bytes.count, 1 + 12 + plaintext.count + 16)
        XCTAssertEqual(try ProviderSyncCipher.open(document, key: key, userID: userID), plaintext)
    }

    func testOpenRejectsEveryTamperedByte() throws {
        let plaintext = Data("payload".utf8)
        let document = try ProviderSyncCipher.seal(key: key, userID: userID, plaintext: plaintext) { nonce }
        var bytes = try XCTUnwrap(Base64URL.decode(document))
        for index in [bytes.count - 1, bytes.count - 16, bytes.count - 17, 14] {
            var copy = bytes
            copy[index] ^= 0x40
            XCTAssertThrowsError(try ProviderSyncCipher.open(Base64URL.encode(copy), key: key, userID: userID)) {
                XCTAssertEqual($0 as? ProviderSyncError, .authentication)
            }
        }
        bytes[0] = 0x02
        XCTAssertThrowsError(try ProviderSyncCipher.open(Base64URL.encode(bytes), key: key, userID: userID)) {
            XCTAssertEqual($0 as? ProviderSyncError, .invalidDocument)
        }
    }

    func testWrongKeyAndWrongAccountFailAuthentication() throws {
        let document = try ProviderSyncCipher.seal(key: key, userID: userID,
            plaintext: Data("payload".utf8)) { nonce }
        var other = key
        other[0] ^= 1
        XCTAssertThrowsError(try ProviderSyncCipher.open(document, key: other, userID: userID)) {
            XCTAssertEqual($0 as? ProviderSyncError, .authentication)
        }
        XCTAssertThrowsError(try ProviderSyncCipher.open(document, key: key, userID: SyncTestValues.otherUser)) {
            XCTAssertEqual($0 as? ProviderSyncError, .authentication)
        }
    }

    func testMalformedKeyAndNonceLengthsFailClosed() throws {
        let sealed = [UInt8](repeating: 0, count: 20)
        XCTAssertNil(AES256GCM.open(key: Array(key.dropLast()), nonce: Array(nonce), aad: [], sealed: sealed))
        XCTAssertNil(AES256GCM.open(key: Array(key), nonce: Array(nonce.dropLast()), aad: [], sealed: sealed))
        XCTAssertNil(AES256GCM.open(key: Array(key), nonce: Array(nonce), aad: [], sealed: [0x01]))
    }

    func testMalformedDocumentsAndKeysAreTyped() throws {
        for document in ["", "!!!", "AQAB", Base64URL.encode([0x01, 0x02]),
                         "AA==", "a"] {
            XCTAssertThrowsError(try ProviderSyncCipher.open(document, key: key, userID: userID),
                                 "document \(document)") {
                XCTAssertEqual($0 as? ProviderSyncError, .invalidDocument)
            }
        }
        // An empty-plaintext envelope is valid wire format; it fails at the tag.
        XCTAssertThrowsError(try ProviderSyncCipher.open(
            Base64URL.encode([0x01] + [UInt8](repeating: 0, count: 12 + 16)), key: key, userID: userID)) {
            XCTAssertEqual($0 as? ProviderSyncError, .authentication)
        }
        XCTAssertThrowsError(try ProviderSyncCipher.seal(key: Data([0x01]), userID: userID,
            plaintext: Data("x".utf8)) { nonce }) {
            XCTAssertEqual($0 as? ProviderSyncError, .invalidKey)
        }
        XCTAssertThrowsError(try ProviderSyncCipher.seal(key: key, userID: userID,
            plaintext: Data("x".utf8)) { Data([0x01]) }) {
            XCTAssertEqual($0 as? ProviderSyncError, .invalidKey)
        }
        XCTAssertThrowsError(try ProviderSyncCipher.open("AA", key: Data([0x01]), userID: userID)) {
            XCTAssertEqual($0 as? ProviderSyncError, .invalidKey)
        }
    }

    func testPayloadBounds() throws {
        let oversized = Data(repeating: 65, count: Limits.providerSyncPayloadMaxBytes + 1)
        XCTAssertThrowsError(try ProviderSyncCipher.seal(key: key, userID: userID, plaintext: oversized) { nonce }) {
            XCTAssertEqual($0 as? ProviderSyncError, .oversized)
        }
        XCTAssertThrowsError(try ProviderSyncPayload(plaintext: oversized)) {
            XCTAssertEqual($0 as? ProviderSyncError, .invalidDocument)
        }
    }

    func testPayloadRoundTripAndStrictShape() throws {
        let settings: [String: Any] = ["version": 1, "profiles": [["id": "x"]],
            "selectedProfileID": NSNull(), "future": ["nested": [1, "a"]]]
        let payload = ProviderSyncPayload(settings: settings, secrets: ["provider:550e8400-e29b-41d4-a716-446655440000": "envelope"])
        let decoded = try ProviderSyncPayload(plaintext: payload.encode())
        XCTAssertEqual(decoded, payload)

        let rejections: [String] = [
            #"{"version":1,"settings":{}}"#,                                  // missing secrets
            #"{"version":1,"settings":{},"secrets":{},"extra":0}"#,           // extra key
            #"{"version":2,"settings":{},"secrets":{}}"#,                     // wrong version
            #"{"version":true,"settings":{},"secrets":{}}"#,                  // bool version
            #"{"version":1.5,"settings":{},"secrets":{}}"#,                   // non-int version
            #"{"version":1,"settings":[],"secrets":{}}"#,                     // settings not object
            #"{"version":1,"settings":{},"secrets":{"provider:x":5}}"#,       // envelope not string
            #"{"version":1,"settings":{},"secrets":{"not-an-account":"e"}}"#, // invalid account
        ]
        for text in rejections {
            XCTAssertThrowsError(try ProviderSyncPayload(plaintext: Data(text.utf8)), text) {
                XCTAssertEqual($0 as? ProviderSyncError, .invalidDocument)
            }
        }
        var tooMany: [String: String] = [:]
        for index in 0...Limits.providerSyncSecretEntries { tooMany["provider:\(index)"] = "e" }
        XCTAssertThrowsError(try ProviderSyncPayload(plaintext: ProviderSyncPayload(settings: [:], secrets: tooMany).encode())) {
            XCTAssertEqual($0 as? ProviderSyncError, .invalidDocument)
        }
    }

    func testBase64URLRejectsPaddingTailBitsAndNonAlphabet() throws {
        XCTAssertNil(Base64URL.decode(""))
        XCTAssertNil(Base64URL.decode("a"))
        XCTAssertNil(Base64URL.decode("AA=="))
        XCTAssertNil(Base64URL.decode("ab"))
        XCTAssertNil(Base64URL.decode("abd"))
        XCTAssertNil(Base64URL.decode("A A"))
        XCTAssertNil(Base64URL.decode("AA=A"))
        XCTAssertEqual(Base64URL.decode("AQ"), [0x01])
        XCTAssertEqual(Base64URL.decode("AQA"), [0x01, 0x00])
        XCTAssertEqual(Base64URL.encode(Base64URL.decode("AAECAwQ")!), "AAECAwQ")
        // Only the canonical encoding of a byte string is accepted back.
        for count in 1...64 {
            let bytes = (0..<count).map { UInt8(truncatingIfNeeded: $0 * 37) }
            XCTAssertEqual(Base64URL.decode(Base64URL.encode(bytes)), bytes)
        }
    }
}

extension Data {
    init(hex text: String) {
        var bytes: [UInt8] = []
        var scalars = Array(text.utf8)
        while scalars.count >= 2 {
            bytes.append(UInt8(strtoul(String(decoding: Array(scalars[0..<2]), as: UTF8.self), nil, 16)))
            scalars.removeFirst(2)
        }
        self.init(bytes)
    }
}
