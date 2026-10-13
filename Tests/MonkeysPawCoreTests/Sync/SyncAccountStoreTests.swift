import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncAccountStoreTests: XCTestCase {
    private let accountPath = "sync/account.json"
    private let bindingPath = "sync/binding.json"

    func testRoundTripNonSecretConnectionAndDeviceSecretAccount() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let store = SyncAccountStore(files: files, operations: operations)
        XCTAssertNil(try store.loadAccount())
        let account = try connection()
        try store.setAccount(account)
        XCTAssertEqual(store.cachedAccount, account)
        XCTAssertEqual(try SyncAccountStore(files: files, operations: operations).loadAccount(), account)
        XCTAssertTrue(files.isPrivate(at: accountPath))
        XCTAssertEqual(account.secretAccount.rawValue, "device:" + SyncTestValues.uuid.uuidString.lowercased())
        XCTAssertNotEqual(account.secretAccount, .provider(ProviderProfileID(SyncTestValues.uuid)))
        XCTAssertEqual(operations.flushedFiles, [RelativePath(accountPath)])
        XCTAssertEqual(operations.flushedDirectories, [RelativePath("sync"), nil])
    }

    func testInvalidConnectionIdentifiersNamesAndURLsFailClosed() throws {
        let account = try connection()
        let original = try accountDocument(account)
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["user_id"] = "bad" },
            { $0["device_id"] = "bad" },
            { $0["connection_id"] = SyncTestValues.uuid.uuidString },
            { $0["username"] = "UPPER" },
            { $0["username"] = "" },
            { $0["device_name"] = "" },
            { $0["server_url"] = "https://username:password@example.test" },
            { $0["server_url"] = "https://example.test?device_token=secret" },
            { $0["server_url"] = "https://example.test#secret" },
            { $0["server_url"] = "https://EXAMPLE.test" },
            { $0["server_url"] = "https://example.test:443" },
            { $0["server_url"] = "https://example.test/" },
            { $0["server_url"] = "https://example.test/a/../b" },
            { $0["server_url"] = "https://example.test/a%2fb" },
            { $0["server_url"] = "https://example.test/api/v1" },
            { $0["server_url"] = "https://example.test/%00" }
        ]
        for change in changes {
            let files = MemoryFileStore()
            let operations = MemorySyncFileOperations(files: files)
            var document = original
            var value = document["account"] as! [String: Any]
            change(&value)
            document["account"] = value
            try SyncTestValues.write(document, to: files, path: accountPath)
            let bytes = try files.read(at: accountPath)
            let store = SyncAccountStore(files: files, operations: operations)
            XCTAssertEqual(store.readOnlyError, .corruptFile)
            XCTAssertNil(store.cachedAccount)
            XCTAssertThrowsError(try store.setAccount(account)) { XCTAssertEqual($0 as? SyncError, .corruptFile) }
            XCTAssertEqual(try files.read(at: accountPath), bytes)
        }
    }

    func testCorruptFutureAndUnsupportedAccountAndBindingFailClosed() throws {
        for path in [accountPath, bindingPath] {
            for (source, error) in [("bad", SyncError.corruptFile), ("{\"version\":8}", .futureVersion(8)),
                                    ("{\"version\":0}", .unsupportedVersion(0))] {
                let files = MemoryFileStore()
                let operations = MemorySyncFileOperations(files: files)
                try files.put(source, at: path)
                let store = SyncAccountStore(files: files, operations: operations)
                XCTAssertEqual(store.readOnlyError, error)
                XCTAssertThrowsError(try store.loadAccount()) { XCTAssertEqual($0 as? SyncError, error) }
                XCTAssertThrowsError(try store.setAccount(connection())) { XCTAssertEqual($0 as? SyncError, error) }
                XCTAssertEqual(try files.text(at: path), source)
                if path == accountPath { try store.resetAccount() }
                else { try store.resetBindings() }
                XCTAssertNil(store.readOnlyError)
                XCTAssertNil(try store.loadAccount())
            }
        }
    }

    func testFailedAccountAndBindingWriteKeepPreviousCaches() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let store = SyncAccountStore(files: files, operations: operations)
        let account = try connection()
        let binding = try ownership()
        try store.setAccount(account)
        try store.updateBinding(for: binding.root) { _ in binding }
        let originalAccount = try files.read(at: accountPath)
        let originalBinding = try files.read(at: bindingPath)
        files.failNextWrite = true
        XCTAssertThrowsError(try store.setAccount(nil)) { XCTAssertEqual($0 as? SyncError, .writeFailed(.ioFailure)) }
        XCTAssertEqual(store.cachedAccount, account)
        XCTAssertEqual(try files.read(at: accountPath), originalAccount)
        files.failNextWrite = true
        XCTAssertThrowsError(try store.updateBinding(for: binding.root) { previous in
            var next = previous!
            next.holds = []
            return next
        }) { XCTAssertEqual($0 as? SyncError, .writeFailed(.ioFailure)) }
        XCTAssertEqual(store.cachedBindings, [binding])
        XCTAssertEqual(try files.read(at: bindingPath), originalBinding)
        XCTAssertNil(store.readOnlyError)
    }

    func testUncertainAccountOrBindingDurabilityBlocksConnectionChanges() throws {
        for bindingWrite in [false, true] {
            let files = MemoryFileStore()
            let operations = MemorySyncFileOperations(files: files)
            let store = SyncAccountStore(files: files, operations: operations)
            let account = try connection()
            let binding = try ownership()
            try store.setAccount(account)
            try store.updateBinding(for: binding.root) { _ in binding }
            operations.failFlushNumber = operations.flushCount + 2
            if bindingWrite {
                XCTAssertThrowsError(try store.updateBinding(for: binding.root) { previous in
                    var next = previous!
                    next.holds = []
                    return next
                }) { XCTAssertEqual($0 as? SyncError, .durabilityUncertain) }
            } else {
                XCTAssertThrowsError(try store.setAccount(nil)) { XCTAssertEqual($0 as? SyncError, .durabilityUncertain) }
            }
            XCTAssertEqual(store.cachedAccount, account)
            XCTAssertEqual(store.cachedBindings, [binding])
            XCTAssertEqual(store.readOnlyError, .durabilityUncertain)
            XCTAssertThrowsError(try store.loadAccount())
            XCTAssertThrowsError(try store.setAccount(connection(userID: SyncTestValues.otherUser)))
        }
    }

    func testHoldSetAndFolderOwnershipPersistAcrossSignOutAndAccountChange() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let store = SyncAccountStore(files: files, operations: operations)
        let account = try connection()
        let binding = try ownership()
        try store.setAccount(account)
        try store.updateBinding(for: binding.root) { _ in binding }
        try store.setAccount(nil)
        let signedOut = SyncAccountStore(files: files, operations: operations)
        XCTAssertNil(try signedOut.loadAccount())
        XCTAssertEqual(try signedOut.binding(for: binding.root), binding)
        XCTAssertTrue(files.isPrivate(at: bindingPath))

        let other = try connection(userID: SyncTestValues.otherUser)
        try signedOut.setAccount(other)
        let held = try XCTUnwrap(signedOut.binding(for: binding.root))
        XCTAssertEqual(held.owner, account.identity)
        XCTAssertEqual(held.managedFolders[SyncTestValues.group]?.owner, account.identity)
        for prompt in held.holds {
            XCTAssertTrue(held.isHeld(identity: prompt.identity, path: prompt.path))
            XCTAssertTrue(held.isHeld(identity: prompt.identity, path: "Renamed.md"))
            XCTAssertTrue(held.isHeld(identity: .assigned(SyncTestValues.device), path: prompt.path))
        }
        // Explicit inclusion can release a held record; a login cannot.
        try signedOut.updateBinding(for: binding.root) { previous in
            var next = previous!
            next.owner = other.identity
            next.holds.removeFirst()
            return next
        }
        XCTAssertEqual(try SyncAccountStore(files: files, operations: operations).binding(for: binding.root)?.holds,
                       Array(binding.holds.dropFirst()))
    }

    func testRootIsolationIncludingByteDistinctUnicodeRootsAndHeldPaths() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let store = SyncAccountStore(files: files, operations: operations)
        let first = try ownership(root: "/Caf\u{e9}")
        let second = try ownership(root: "/Cafe\u{301}", userID: SyncTestValues.otherUser)
        XCTAssertNotEqual(first.root, second.root)
        try store.updateBinding(for: first.root) { _ in first }
        try store.updateBinding(for: second.root) { _ in second }
        let reloaded = SyncAccountStore(files: files, operations: operations)
        XCTAssertEqual(try reloaded.binding(for: first.root), first)
        XCTAssertEqual(try reloaded.binding(for: second.root), second)
        XCTAssertNil(try reloaded.binding(for: SyncLibraryRoot("/unbound")))
        XCTAssertThrowsError(try reloaded.updateBinding(for: first.root) { _ in second }) {
            XCTAssertEqual($0 as? SyncError, .bindingMismatch)
        }
        XCTAssertEqual(try reloaded.binding(for: first.root), first)
    }

    func testUnknownFieldsFollowAccountRootAndHoldRecordsAcrossReordering() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let account = try connection()
        let first = try ownership()
        let second = try ownership(root: "/other", userID: SyncTestValues.otherUser)
        var accountJSON = try accountDocument(account)
        accountJSON["future"] = ["v": 1.25]
        var record = accountJSON["account"] as! [String: Any]
        record["future_connection"] = "kept"
        accountJSON["account"] = record
        try SyncTestValues.write(accountJSON, to: files, path: accountPath)
        var firstJSON = try SyncTestValues.object(first)
        firstJSON["future_root"] = 1
        var holds = firstJSON["holds"] as! [[String: Any]]
        holds[0]["future_hold"] = "kept"
        firstJSON["holds"] = holds
        var folders = firstJSON["managed_folders"] as! [String: [String: Any]]
        folders[SyncTestValues.group.rawValue]!["future_folder"] = true
        firstJSON["managed_folders"] = folders
        let document: [String: Any] = ["version": 1, "future_binding": true,
                                       "libraries": [try SyncTestValues.object(second), firstJSON]]
        try SyncTestValues.write(document, to: files, path: bindingPath)
        let store = SyncAccountStore(files: files, operations: operations)
        try store.setAccount(account)
        try store.updateBinding(for: first.root) { previous in
            var next = previous!
            next.holds.reverse()
            return next
        }
        let savedAccount = try JSONSerialization.jsonObject(with: files.read(at: accountPath)) as! [String: Any]
        XCTAssertEqual((savedAccount["account"] as! [String: Any])["future_connection"] as? String, "kept")
        XCTAssertEqual((savedAccount["future"] as! [String: Double])["v"], 1.25)
        let saved = try JSONSerialization.jsonObject(with: files.read(at: bindingPath)) as! [String: Any]
        XCTAssertEqual(saved["future_binding"] as? Bool, true)
        let libraries = saved["libraries"] as! [[String: Any]]
        let root = libraries.first { $0["library_root"] as? String == first.root.path }!
        XCTAssertEqual(root["future_root"] as? Int, 1)
        let savedHolds = root["holds"] as! [[String: Any]]
        XCTAssertEqual(savedHolds[1]["future_hold"] as? String, "kept")
        let savedFolders = root["managed_folders"] as! [String: [String: Any]]
        XCTAssertEqual(savedFolders[SyncTestValues.group.rawValue]!["future_folder"] as? Bool, true)
        XCTAssertEqual(try store.binding(for: second.root), second)
    }

    func testMalformedBindingIDsFoldersHoldsAndDuplicateRootsAreRejected() throws {
        let valid = try SyncTestValues.object(ownership())
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["library_root"] = "relative/root" },
            { $0["managed_folders"] = ["invalid": ["owner": $0["owner"]!, "folder": "Team"]] },
            { $0["managed_folders"] = [SyncTestValues.group.rawValue: ["owner": $0["owner"]!, "folder": "../Team"]] },
            { value in
                var holds = value["holds"] as! [[String: Any]]
                holds[0]["identity"] = "not-an-id"
                value["holds"] = holds
            },
            { value in
                var holds = value["holds"] as! [[String: Any]]
                holds[0]["content_hash"] = "invalid"
                value["holds"] = holds
            },
            { value in
                var holds = value["holds"] as! [[String: Any]]
                holds[0]["path"] = "../elsewhere.md"
                value["holds"] = holds
            },
            { value in
                var holds = value["holds"] as! [[String: Any]]
                holds.append(holds[0])
                value["holds"] = holds
            }
        ]
        for change in changes {
            let files = MemoryFileStore()
            let operations = MemorySyncFileOperations(files: files)
            var invalid = valid
            change(&invalid)
            try SyncTestValues.write(["version": 1, "libraries": [invalid]], to: files, path: bindingPath)
            let store = SyncAccountStore(files: files, operations: operations)
            XCTAssertEqual(store.readOnlyError, .corruptFile)
            XCTAssertThrowsError(try store.binding(for: SyncLibraryRoot("/library")))
            XCTAssertThrowsError(try store.setAccount(connection()))
        }
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        try SyncTestValues.write(["version": 1, "libraries": [valid, valid]], to: files, path: bindingPath)
        XCTAssertEqual(SyncAccountStore(files: files, operations: operations).readOnlyError, .corruptFile)
    }

    func testNoSecretValuesEnterAnyClientRecord() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let store = SyncAccountStore(files: files, operations: operations)
        let secret = SecretValue(UUID().uuidString + "-device-token-sentinel")
        let password = SecretValue(UUID().uuidString + "-password-sentinel")
        let invite = SecretValue(UUID().uuidString + "-invite-sentinel")
        // These are deliberately not accepted by either store's typed API.
        try store.setAccount(connection())
        let binding = try ownership()
        try store.updateBinding(for: binding.root) { _ in binding }
        let state = try SyncTestValues.state()
        try SyncStateStore(files: files, operations: operations).update(for: state.binding) { $0 = state }
        for file in try files.listFiles() {
            let bytes = try files.read(at: file.relativePath)
            for value in [secret, password, invite] {
                value.withValue { XCTAssertNil(bytes.range(of: Data($0.utf8))) }
            }
            XCTAssertTrue(files.isPrivate(at: file.relativePath))
            let text = String(decoding: bytes, as: UTF8.self)
            for key in ["device_token", "invite_token", "password"] { XCTAssertFalse(text.contains(key)) }
        }
    }

    private func connection(userID: ULID = SyncTestValues.user) throws -> SyncAccount {
        try SyncAccount(identity: SyncTestValues.account(userID: userID), username: "user_1",
                        deviceID: SyncTestValues.device, deviceName: "Linux", connectionID: SyncTestValues.uuid)
    }

    private func ownership(root: String = "/library", userID: ULID = SyncTestValues.user) throws -> SyncLibraryBinding {
        let account = try SyncTestValues.account(userID: userID)
        let idless = PromptIdentity(path: "Idless.md", id: nil)
        let holds = [try SyncHeldPrompt(identity: .assigned(SyncTestValues.personalPrompt), path: "Private.md",
                                       sourceAccount: account, contentHash: SyncHash(bytes: Data("private bytes".utf8))),
                     try SyncHeldPrompt(identity: idless, path: "Idless.md", sourceAccount: account,
                                        contentHash: SyncHash(bytes: Data([0xff, 0x00])))]
        return try SyncLibraryBinding(root: SyncLibraryRoot(root), owner: account,
                                      managedFolders: [SyncTestValues.group: SyncManagedFolder(owner: account, folder: "Team")],
                                      holds: holds)
    }

    private func accountDocument(_ account: SyncAccount) throws -> [String: Any] {
        ["version": 1, "account": try SyncTestValues.object(account)]
    }
}
