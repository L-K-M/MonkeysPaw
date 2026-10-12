import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class KeychainSecretStoreTests: XCTestCase {
    private let first = SecretAccount.provider(ProviderProfileID())
    private let second = SecretAccount.provider(ProviderProfileID())

    func testMissingItemReturnsNilAndDeleteIsIdempotent() throws {
        let keychain = MemoryKeychain()
        let store = KeychainSecretStore(keychain: keychain)
        XCTAssertNil(try store.read(account: first, source: .effective))
        XCTAssertNil(try store.read(account: first, source: .persisted))
        try store.delete(account: first)
        XCTAssertTrue(keychain.mutations.isEmpty)
    }

    func testVersionedMapRoundTripsIsolatedAccountsInOneItem() throws {
        let keychain = MemoryKeychain()
        let store = KeychainSecretStore(keychain: keychain)
        let token = try SecretAccount(namespace: "device-token", name: first.name)
        let value = SecretValue("κλειδί 🔐\n\"\\\u{0000}")
        XCTAssertEqual(try store.write(value, account: first), .keychain)
        try store.write(SecretValue("second"), account: second)
        try store.write(SecretValue("token"), account: token)
        try store.write(value, account: first)

        let reloaded = KeychainSecretStore(keychain: keychain)
        XCTAssertEqual(try reloaded.read(account: first, source: .persisted),
                       StoredSecret(value: value, tier: .keychain))
        XCTAssertEqual(try reloaded.read(account: second, source: .effective)?.value, SecretValue("second"))
        XCTAssertEqual(try reloaded.read(account: token, source: .persisted)?.value, SecretValue("token"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(keychain.data)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let entries = try XCTUnwrap(object["entries"] as? [String: String])
        XCTAssertEqual(Set(entries.keys), Set([first.rawValue, second.rawValue, token.rawValue]))
        XCTAssertEqual(keychain.mutations, [.add, .update, .update, .update])
        XCTAssertTrue(keychain.addresses.allSatisfy { $0 == ["ch.lkmc.monkeyspaw", "secret-map"] })
    }

    func testDeletePreservesOtherAccountsThenRemovesEmptyItem() throws {
        let keychain = MemoryKeychain()
        let store = KeychainSecretStore(keychain: keychain)
        try store.write(SecretValue("first"), account: first)
        try store.write(SecretValue("second"), account: second)
        try store.delete(account: first)
        XCTAssertNil(try store.read(account: first, source: .persisted))
        XCTAssertEqual(try store.read(account: second, source: .persisted)?.value, SecretValue("second"))
        let before = keychain.mutations
        try store.delete(account: first)
        XCTAssertEqual(keychain.mutations, before)
        try store.delete(account: second)
        XCTAssertNil(keychain.data)
        XCTAssertEqual(keychain.mutations, [.add, .update, .update, .delete])
    }

    func testDeleteAlsoRemovesAnAlreadyEmptyMap() throws {
        let keychain = MemoryKeychain()
        keychain.data = Data(#"{"version":1,"entries":{}}"#.utf8)
        try KeychainSecretStore(keychain: keychain).delete(account: first)
        XCTAssertNil(keychain.data)
        XCTAssertEqual(keychain.mutations, [.delete])
    }

    func testCorruptAndUnsupportedPayloadsFailClosedForEveryOperation() throws {
        let payloads = [
            "invalid", #"{"entries":{}}"#, #"{"version":1}"#,
            #"{"version":true,"entries":{}}"#, #"{"version":1,"entries":[]}"#,
            #"{"version":0,"entries":{}}"#, #"{"version":2,"entries":{}}"#,
            #"{"version":1,"entries":{"provider:one":42}}"#,
            #"{"version":1,"entries":{"one":"value"}}"#,
            #"{"version":1,"entries":{"provider:":"value"}}"#,
            #"{"version":1,"entries":{"provider:bad:name":"value"}}"#,
            #"{"version":1,"entries":{"provider:bad/name":"value"}}"#
        ].map { Data($0.utf8) } + [Data([0xff])]
        for original in payloads {
            let keychain = MemoryKeychain()
            keychain.data = original
            let store = KeychainSecretStore(keychain: keychain)
            assertFailure(.readFailed) { _ = try store.read(account: first, source: .effective) }
            assertFailure(.readFailed) { try store.write(SecretValue("replacement"), account: first) }
            assertFailure(.readFailed) { try store.delete(account: first) }
            XCTAssertTrue(keychain.data == original)
            XCTAssertTrue(keychain.mutations.isEmpty)
        }
    }

    func testReadFailuresAbortMutationsAndReportSanitizedErrors() {
        let cases: [(Error, SecretStoreError)] = [
            (KeychainAccessError.locked, .locked), (KeychainAccessError.unavailable, .unavailable),
            (KeychainAccessError.failure, .readFailed), (SensitiveFailure(), .readFailed)
        ]
        for (failure, expected) in cases {
            let keychain = MemoryKeychain()
            keychain.failures[.read] = failure
            let store = KeychainSecretStore(keychain: keychain)
            assertFailure(expected) { _ = try store.read(account: first, source: .persisted) }
            assertFailure(expected) { try store.write(SecretValue("replacement"), account: first) }
            assertFailure(expected) { try store.delete(account: first) }
            XCTAssertTrue(keychain.mutations.isEmpty)
        }
    }

    func testFailedAddUpdateAndDeleteLeaveOldDataIntact() throws {
        let cases: [(KeychainAccessError, SecretStoreError?)] = [(.failure, nil), (.locked, .locked), (.unavailable, .unavailable)]
        for (failure, expected) in cases {
            let keychain = MemoryKeychain()
            let store = KeychainSecretStore(keychain: keychain)
            keychain.failures[.add] = failure
            assertFailure(expected ?? .writeFailed) { try store.write(SecretValue("first"), account: first) }
            XCTAssertNil(keychain.data)

            keychain.failures = [:]
            try store.write(SecretValue("first"), account: first)
            let original = keychain.data
            keychain.failures[.update] = failure
            assertFailure(expected ?? .writeFailed) { try store.write(SecretValue("changed"), account: first) }
            XCTAssertTrue(keychain.data == original)

            keychain.failures = [.delete: failure]
            assertFailure(expected ?? .deleteFailed) { try store.delete(account: first) }
            XCTAssertTrue(keychain.data == original)

            keychain.failures = [:]
            try store.write(SecretValue("second"), account: second)
            let multiple = keychain.data
            keychain.failures[.update] = failure
            assertFailure(expected ?? .deleteFailed) { try store.delete(account: first) }
            XCTAssertTrue(keychain.data == multiple)
        }
    }

    func testDuplicateAddReloadsAndPreservesTheNewItemsAccounts() throws {
        let keychain = MemoryKeychain()
        let original = try payload([second.rawValue: "other writer"])
        keychain.beforeAdd = { [weak keychain] in keychain?.data = original }
        let store = KeychainSecretStore(keychain: keychain)
        try store.write(SecretValue("first"), account: first)
        XCTAssertEqual(try store.read(account: first, source: .persisted)?.value, SecretValue("first"))
        XCTAssertEqual(try store.read(account: second, source: .persisted)?.value, SecretValue("other writer"))
        XCTAssertEqual(keychain.mutations, [.add, .update])
    }

    func testDuplicateAddNeverOverwritesCorruptOrUnreadableData() throws {
        let corrupt = Data("invalid".utf8)
        let keychain = MemoryKeychain()
        keychain.beforeAdd = { [weak keychain] in keychain?.data = corrupt }
        let store = KeychainSecretStore(keychain: keychain)
        assertFailure(.readFailed) { try store.write(SecretValue("first"), account: first) }
        XCTAssertTrue(keychain.data == corrupt)
        XCTAssertEqual(keychain.mutations, [.add])

        let original = try payload([second.rawValue: "other writer"])
        keychain.beforeAdd = { [weak keychain] in
            keychain?.data = original
            keychain?.failures[.read] = KeychainAccessError.locked
        }
        keychain.data = nil
        assertFailure(.locked) { try store.write(SecretValue("first"), account: first) }
        XCTAssertTrue(keychain.data == original)
        XCTAssertEqual(keychain.mutations, [.add, .add])
    }

    func testDuplicateAddUpdateFailurePreservesTheOtherWritersMap() throws {
        let keychain = MemoryKeychain()
        let original = try payload([second.rawValue: "other writer"])
        keychain.beforeAdd = { [weak keychain] in keychain?.data = original }
        keychain.failures[.update] = KeychainAccessError.failure
        assertFailure(.writeFailed) {
            try KeychainSecretStore(keychain: keychain).write(SecretValue("first"), account: first)
        }
        XCTAssertTrue(keychain.data == original)
    }

    func testDisappearingItemFailsUpdateAndMakesDeleteIdempotent() throws {
        let keychain = MemoryKeychain()
        let store = KeychainSecretStore(keychain: keychain)
        try store.write(SecretValue("first"), account: first)
        keychain.beforeUpdate = { [weak keychain] in keychain?.data = nil }
        assertFailure(.writeFailed) { try store.write(SecretValue("changed"), account: first) }
        XCTAssertNil(keychain.data)
        XCTAssertEqual(keychain.mutations, [.add, .update])

        keychain.data = try payload([first.rawValue: "first"])
        keychain.beforeDelete = { [weak keychain] in keychain?.data = nil }
        try store.delete(account: first)
        XCTAssertNil(keychain.data)
    }

    func testConcurrentInstancesCannotLoseAccountsDuringReadModifyWrite() throws {
        let keychain = MemoryKeychain()
        let stores = [KeychainSecretStore(keychain: keychain), KeychainSecretStore(keychain: keychain)]
        let accounts = (0..<40).map { _ in SecretAccount.provider(ProviderProfileID()) }
        DispatchQueue.concurrentPerform(iterations: accounts.count) { index in
            do { try stores[index % stores.count].write(SecretValue("value"), account: accounts[index]) }
            catch { XCTFail("Concurrent write failed") }
        }
        for account in accounts {
            XCTAssertEqual(try stores[0].read(account: account, source: .persisted)?.value, SecretValue("value"))
        }
        XCTAssertEqual(keychain.mutations.filter { $0 == .add }.count, 1)
    }

    func testNativeInteractionStatusesAreReportedAsLocked() {
        // Apple SecBase.h: errSecInteractionNotAllowed and the legacy
        // errSecInteractionRequired. Keep Security imports in the driver.
        let statuses: [Int32] = [-25308, -25315]
        for status in statuses {
            XCTAssertThrowsError(try SystemKeychainAccess.check(status)) {
                XCTAssertEqual($0 as? KeychainAccessError, .locked)
            }
        }
    }

    func testRealLoginKeychainRoundTripWithoutPrompts() throws {
        let service = "ch.lkmc.monkeyspaw.tests." + UUID().uuidString
        let store = KeychainSecretStore(service: service)
        do {
            try SystemKeychainAccess.withoutUserInteraction {
                do { try store.write(SecretValue("test value"), account: first) }
                catch let error as SecretStoreError where error == .locked || error == .unavailable {
                    throw XCTSkip("Login keychain unavailable or requires interaction; no prompts allowed in hosted tests")
                }
                defer {
                    do { try store.delete(account: first) }
                    catch { XCTFail("Could not clean up the uniquely named test Keychain item") }
                }
                XCTAssertEqual(try store.read(account: first, source: .persisted),
                               StoredSecret(value: SecretValue("test value"), tier: .keychain))
                try store.write(SecretValue("updated"), account: first)
                XCTAssertEqual(try store.read(account: first, source: .effective)?.value, SecretValue("updated"))
                try store.delete(account: first)
                XCTAssertNil(try store.read(account: first, source: .persisted))
            }
        } catch KeychainAccessError.unavailable {
            throw XCTSkip("Cannot disable login-keychain interaction; hosted test must not show dialogs")
        }
    }

    private func payload(_ entries: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "entries": entries])
    }

    private func assertFailure(_ expected: SecretStoreError, file: StaticString = #filePath, line: UInt = #line,
                               _ work: () throws -> Void) {
        XCTAssertThrowsError(try work(), file: file, line: line) {
            XCTAssertEqual($0 as? SecretStoreError, expected, file: file, line: line)
        }
    }
}

private struct SensitiveFailure: Error {
    let description = "underlying secret error text"
}

private final class MemoryKeychain: KeychainAccess {
    enum Operation: Hashable { case read, add, update, delete }
    private let lock = NSLock()
    var data: Data?
    var failures: [Operation: Error] = [:]
    var beforeAdd: (() -> Void)?
    var beforeUpdate: (() -> Void)?
    var beforeDelete: (() -> Void)?
    private(set) var operations: [Operation] = []
    private(set) var addresses: [[String]] = []
    var mutations: [Operation] { operations.filter { $0 != .read } }

    func copyMatching(service: String, account: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try record(.read, service: service, account: account)
        guard let data else { throw KeychainAccessError.notFound }
        return data
    }

    func add(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try record(.add, service: service, account: account)
        beforeAdd?()
        guard self.data == nil else { throw KeychainAccessError.duplicateItem }
        self.data = data
    }

    func update(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try record(.update, service: service, account: account)
        beforeUpdate?()
        guard self.data != nil else { throw KeychainAccessError.notFound }
        self.data = data
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try record(.delete, service: service, account: account)
        beforeDelete?()
        guard data != nil else { throw KeychainAccessError.notFound }
        data = nil
    }

    private func record(_ operation: Operation, service: String, account: String) throws {
        operations.append(operation)
        addresses.append([service, account])
        if let failure = failures[operation] { throw failure }
    }
}
