import Foundation
import XCTest
@testable import MonkeysPawCore

final class ProviderSyncKeyServiceTests: XCTestCase {
    private let userID = SyncTestValues.user
    private let otherUserID = SyncTestValues.otherUser

    private func harness(entropy: LibraryEntropy = LibraryEntropy()) -> (FakeProviderSecrets, ProviderSyncKeyService) {
        let secrets = FakeProviderSecrets()
        return (secrets, ProviderSyncKeyService(secrets: secrets, entropy: entropy))
    }

    func testGenerateStoresThirtyTwoBytesAndReportsTier() throws {
        let entropy = LibraryEntropy()
        entropy.value = Array(0..<32).map { UInt8($0) }
        let (secrets, keys) = harness(entropy: entropy)
        let text = try keys.generateKey(userID: userID)
        XCTAssertEqual(text.count, 43)
        XCTAssertEqual(Base64URL.decode(text), Array(0..<32).map { UInt8($0) })
        XCTAssertEqual(try keys.tier(userID: userID), .secretService)
        XCTAssertEqual(secrets.writes, [.providerSync(userID)])
        XCTAssertEqual(try keys.keyBytes(userID: userID), Data(Array(0..<32).map { UInt8($0) }))
        XCTAssertNil(try keys.tier(userID: otherUserID))
        XCTAssertNil(try keys.keyBytes(userID: otherUserID))
    }

    func testEnterKeyNormalizesAndRejectsAnythingNotThirtyTwoBytes() throws {
        let (secrets, keys) = harness()
        let raw = (0..<32).map { UInt8($0 + 100) }
        let returned = try keys.enterKey(userID: userID, text: Base64URL.encode(raw))
        XCTAssertEqual(returned, Base64URL.encode(raw))
        XCTAssertEqual(try keys.keyBytes(userID: userID), Data(raw))

        for text in ["", "AA", Base64URL.encode([UInt8](repeating: 0, count: 31)),
                     Base64URL.encode([UInt8](repeating: 0, count: 33)),
                     Base64URL.encode(raw) + "=", "not base64 url !!"] {
            XCTAssertThrowsError(try keys.enterKey(userID: userID, text: text), text) {
                XCTAssertEqual($0 as? ProviderSyncKeyError, .invalidKey)
            }
        }
        XCTAssertEqual(try keys.keyBytes(userID: userID), Data(raw))
        XCTAssertEqual(secrets.writes.count, 1)
    }

    func testRemovalAndFailuresMapToTypedErrors() throws {
        let (secrets, keys) = harness()
        _ = try keys.enterKey(userID: userID, text: Base64URL.encode([UInt8](repeating: 7, count: 32)))
        try keys.removeKey(userID: userID)
        XCTAssertNil(try keys.keyBytes(userID: userID))
        XCTAssertEqual(secrets.deletions, [.providerSync(userID)])

        secrets.readError = SecretStoreError.locked
        XCTAssertThrowsError(try keys.tier(userID: userID)) {
            XCTAssertEqual($0 as? ProviderSyncKeyError, .secret(.locked))
        }
        secrets.readError = nil
        secrets.writeError = SecretStoreError.readOnly
        XCTAssertThrowsError(try keys.enterKey(userID: userID,
            text: Base64URL.encode([UInt8](repeating: 1, count: 32)))) {
            XCTAssertEqual($0 as? ProviderSyncKeyError, .secret(.readOnly))
        }
        secrets.writeError = nil
        secrets.deleteError = SecretStoreError.deleteFailed
        XCTAssertThrowsError(try keys.removeKey(userID: userID)) {
            XCTAssertEqual($0 as? ProviderSyncKeyError, .secret(.deleteFailed))
        }
        secrets.deleteError = nil
        let entropy = LibraryEntropy()
        entropy.value = [UInt8](repeating: 0, count: 3)
        let failing = ProviderSyncKeyService(secrets: secrets, entropy: entropy)
        XCTAssertThrowsError(try failing.generateKey(userID: userID))
    }
}
