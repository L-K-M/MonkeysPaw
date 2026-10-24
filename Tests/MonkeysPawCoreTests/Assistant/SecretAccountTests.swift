import Foundation
import XCTest
@testable import MonkeysPawCore

final class SecretAccountTests: XCTestCase {
    func testDeviceAccountOnBackgroundTaskPreservesCanonicalUUID() async throws {
        let id = try XCTUnwrap(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        let account = await Task.detached { SecretAccount.device(id) }.value

        XCTAssertEqual(account.namespace, "device")
        XCTAssertEqual(account.name, "01234567-89ab-cdef-0123-456789abcdef")
        XCTAssertEqual(account.rawValue, "device:01234567-89ab-cdef-0123-456789abcdef")
        XCTAssertEqual(try roundTrip(account), account)
    }

    func testGeneratedUUIDAccountsRoundTripOnBackgroundTask() async throws {
        let accounts = await Task.detached {
            (0..<256).map { _ in SecretAccount.device(UUID()) }
        }.value

        for account in accounts {
            XCTAssertNotNil(UUID(uuidString: account.name))
            XCTAssertEqual(account.name, account.name.lowercased())
            XCTAssertEqual(try roundTrip(account), account)
        }
    }

    func testProviderAccountRetainsItsStoredReference() throws {
        let id = ProviderProfileID(try XCTUnwrap(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")))
        let account = SecretAccount.provider(id)

        XCTAssertEqual(account.rawValue, "provider:01234567-89ab-cdef-0123-456789abcdef")
        XCTAssertEqual(try roundTrip(account), account)
    }

    func testExternalAccountValidationPreservesTheASCIIGrammar() throws {
        XCTAssertEqual(try SecretAccount(namespace: "legacy-store", name: "Account_0.v1").rawValue,
                       "legacy-store:Account_0.v1")

        for (namespace, name) in [("", "name"), ("device", ""), ("device:", "name"),
                                  ("device", "a/b"), ("device", "two words"),
                                  ("device", "caf\u{00e9}"), ("device", "id\n"), ("device", "id\0")] {
            XCTAssertThrowsError(try SecretAccount(namespace: namespace, name: name)) {
                XCTAssertEqual($0 as? SecretStoreError, .invalidAccount)
            }
        }
    }

    func testRawAndDecodedAccountsValidateEveryASCIICharacter() throws {
        for scalar in UInt8.min...0x7f {
            let character = String(UnicodeScalar(scalar))
            let accepted = ("a"..."z").contains(character) || ("A"..."Z").contains(character)
                || ("0"..."9").contains(character) || ["-", "_", "."].contains(character)
            for (namespace, name) in [(character, "account"), ("provider", character)] {
                let context = "ASCII \(scalar): \(namespace.debugDescription):\(name.debugDescription)"
                let encoded = try JSONEncoder().encode(namespace + ":" + name)
                if accepted {
                    let account = try SecretAccount(namespace: namespace, name: name)
                    XCTAssertEqual(try JSONDecoder().decode(SecretAccount.self, from: encoded), account, context)
                    XCTAssertEqual(try SecretAccount(coding: namespace + ":" + name), account, context)
                    continue
                }

                XCTAssertThrowsError(try SecretAccount(namespace: namespace, name: name), context) {
                    XCTAssertEqual($0 as? SecretStoreError, .invalidAccount)
                }
                XCTAssertThrowsError(try JSONDecoder().decode(SecretAccount.self, from: encoded), context) {
                    XCTAssertEqual($0 as? SecretStoreError, .invalidAccount)
                }
                XCTAssertThrowsError(try SecretAccount(coding: namespace + ":" + name), context) {
                    XCTAssertEqual($0 as? SecretStoreError, .invalidAccount)
                }
            }
        }
    }

    func testUnicodeLookalikesAndInvisibleCharactersAreNotAccounts() throws {
        for value in ["caf\u{00e9}", "cafe\u{0301}", "\u{ff41}", "\u{212a}", "id\u{feff}", "id\u{200d}", "id\u{00a0}"] {
            for (namespace, name) in [(value, "account"), ("provider", value)] {
                let context = namespace.debugDescription + ":" + name.debugDescription
                XCTAssertThrowsError(try SecretAccount(namespace: namespace, name: name), context) {
                    XCTAssertEqual($0 as? SecretStoreError, .invalidAccount)
                }
                let encoded = try JSONEncoder().encode(namespace + ":" + name)
                XCTAssertThrowsError(try JSONDecoder().decode(SecretAccount.self, from: encoded), context) {
                    XCTAssertEqual($0 as? SecretStoreError, .invalidAccount)
                }
                XCTAssertThrowsError(try SecretAccount(coding: namespace + ":" + name), context) {
                    XCTAssertEqual($0 as? SecretStoreError, .invalidAccount)
                }
            }
        }
    }

    private func roundTrip(_ account: SecretAccount) throws -> SecretAccount {
        try JSONDecoder().decode(SecretAccount.self, from: JSONEncoder().encode(account))
    }
}
