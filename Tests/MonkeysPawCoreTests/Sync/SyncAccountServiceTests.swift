import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncAccountServiceTests: XCTestCase {
    func testRefusedAccountRetirementPreservesBindingAndCredentialsBeforeAnyRequest() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        var admissions = 0
        var allowed = false
        let gated = rig.reopenAccount(beforeAccountChange: { admissions += 1; return allowed })
        _ = try await gated.startup()
        _ = try await gated.refresh()
        await rig.sync.settle()
        XCTAssertEqual(admissions, 0, "Startup and refresh must preserve repeat across restarts")
        let old = try rig.sync.accounts.loadAccount()
        let requests = rig.sync.transport.requests.count
        let secrets = Set(rig.secrets.persisted.keys)
        var password = rig.password
        let login = await failure {
            try await gated.login(server: rig.server, username: "person", password: &password, deviceName: "Desktop")
        }
        XCTAssertEqual(password, "")
        XCTAssertEqual(login.issue, .recoveryRequired)
        let invite = try SyncInviteLink(String(repeating: "a", count: 42) + "A", server: rig.server)
        password = rig.password
        let registration = await failure {
            try await gated.register(invite: invite, expectedAccount: old, username: "person",
                                     password: &password, deviceName: "Desktop")
        }
        XCTAssertEqual(registration.issue, .recoveryRequired)
        XCTAssertEqual(password, "")
        let signOut = await failure { try await gated.signOut() }
        let revoke = await failure { try await gated.revokeDevice(rig.device) }
        XCTAssertEqual(signOut.issue, .recoveryRequired)
        XCTAssertEqual(revoke.issue, .recoveryRequired)
        XCTAssertEqual(admissions, 4)
        XCTAssertEqual(rig.sync.transport.requests.count, requests)
        XCTAssertEqual(try rig.sync.accounts.loadAccount(), old)
        XCTAssertEqual(Set(rig.secrets.persisted.keys), secrets)
        XCTAssertTrue(gated.snapshot.enabled)

        allowed = true
        _ = try await gated.signOut()
        XCTAssertEqual(admissions, 5)
        XCTAssertNil(try rig.sync.accounts.loadAccount())
        XCTAssertTrue(rig.secrets.persisted.isEmpty)
    }

    func testReconstructedServiceExposesCachedMetadataWithoutResumingOrReadingSecrets() async throws {
        let rig = try SyncAccountRig()
        let signedIn = try await rig.login()
        await rig.sync.settle()
        let requests = rig.sync.transport.requests.count
        let reads = rig.secrets.reads.count
        let reconstructed = rig.reopenAccount()
        XCTAssertEqual(reconstructed.snapshot.account, signedIn.account)
        XCTAssertFalse(reconstructed.snapshot.enabled)
        XCTAssertNil(reconstructed.snapshot.me)
        XCTAssertNil(reconstructed.snapshot.tier)
        let native = try SyncAccountService(sync: rig.sync.service, accounts: rig.sync.accounts, secrets: rig.secrets,
            transport: rig.sync.transport, libraryRoot: rig.sync.base.binding.root.path)
        XCTAssertEqual(native.snapshot.account, signedIn.account)
        XCTAssertFalse(native.snapshot.enabled)
        XCTAssertEqual(rig.sync.transport.requests.count, requests)
        XCTAssertEqual(rig.secrets.reads.count, reads)
    }

    func testLoginConsumesPasswordAndPersistsOnlyBoundTokenAndMetadata() async throws {
        let rig = try SyncAccountRig()
        var password = rig.password
        let result = try await rig.account.login(server: "HTTPS://EXAMPLE.test:443/paw/api/v1/", username: "person",
            password: &password, deviceName: "Desktop")
        await rig.sync.settle()
        XCTAssertEqual(password, "")
        XCTAssertTrue(result.enabled)
        XCTAssertEqual(result.tier, .secretService)
        let account = try XCTUnwrap(result.account)
        XCTAssertEqual(account.identity.serverURL.absoluteString, "https://example.test/paw")
        XCTAssertEqual(account.deviceID, rig.device)
        XCTAssertEqual(account.secretAccount, .device(account.connectionID))
        XCTAssertNil(rig.sync.transport.requests[0].headers["Authorization"])
        let request = try JSONDecoder().decode(SyncAPI.LoginRequest.self, from: XCTUnwrap(rig.sync.transport.requests[0].body))
        XCTAssertEqual(request.password, rig.password)
        XCTAssertEqual(rig.sync.transport.requests[1].headers["Authorization"], "Bearer " + rig.token)
        let stored = try XCTUnwrap(rig.secrets.persisted[account.secretAccount])
        let envelope = try stored.value.withValue { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual(envelope["server_url"] as? String, account.identity.serverURL.absoluteString)
        XCTAssertEqual(envelope["user_id"] as? String, account.identity.userID.rawValue)
        XCTAssertEqual(envelope["token"] as? String, rig.token)
        XCTAssertFalse(stored.value.withValue { $0.contains(rig.password) })
        try rig.assertNoCredentialsInData()
        XCTAssertEqual(try rig.sync.accounts.loadConnection().activation, .enabled)
        XCTAssertEqual(try rig.sync.accounts.binding(for: rig.sync.base.binding.root)?.owner, account.identity)
    }

    func testBadLoginClearsPasswordAndCreatesNoConnectionOrSecret() async throws {
        let rig = try SyncAccountRig()
        rig.sync.transport.handler = { _, _ in try SyncServiceRig.failure(.unauthorized) }
        var password = rig.password
        let error = await failure { try await rig.account.login(server: rig.server, username: "person", password: &password, deviceName: "Desktop") }
        XCTAssertEqual(error.issue, .http(.unauthorized))
        XCTAssertEqual(password, "")
        XCTAssertEqual(rig.sync.transport.requests.count, 1)
        XCTAssertTrue(rig.secrets.writes.isEmpty)
        XCTAssertNil(try rig.sync.accounts.loadAccount())
        XCTAssertFalse(rig.sync.service.report.enabled)
    }

    func testInvalidInputClearsPasswordBeforeAnyHTTP() async throws {
        let rig = try SyncAccountRig()
        var password = rig.password
        _ = await failure { try await rig.account.login(server: "https://name:secret@example.test", username: "person", password: &password, deviceName: "Desktop") }
        XCTAssertEqual(password, "")
        XCTAssertTrue(rig.sync.transport.requests.isEmpty)
    }

    func testFailedMeRevokesNewSessionWithoutPersistingIt() async throws {
        let rig = try SyncAccountRig()
        let normal = rig.sync.transport.handler
        rig.sync.transport.handler = { index, request in
            if request.url.path.hasSuffix("/me") { return try SyncServiceRig.failure(.forbidden) }
            return try await normal(index, request)
        }
        let error = await failure { try await rig.login() }
        XCTAssertEqual(error.issue, .http(.forbidden))
        XCTAssertEqual(error.cleanup.remote, .revoked)
        XCTAssertEqual(rig.logouts.count, 1)
        XCTAssertTrue(rig.secrets.writes.isEmpty)
        XCTAssertNil(try rig.sync.accounts.loadAccount())
    }

    func testMalformedMeIdentityAndCurrentDevicesAreRejectedAndRevoked() async throws {
        for variant in 0..<4 {
            let rig = try SyncAccountRig()
            let normal = rig.sync.transport.handler
            rig.sync.transport.handler = { index, request in
                if request.url.path.hasSuffix("/me") {
                    let devices = variant == 1 ? [] : variant == 2 ? [rig.deviceDTO(), rig.deviceDTO()] : [rig.deviceDTO(revoked: variant == 3)]
                    return try SyncServiceRig.http(SyncAPI.MeResponse(user: rig.user(variant == 0 ? SyncTestValues.otherUser : rig.userID), groups: [], devices: devices))
                }
                return try await normal(index, request)
            }
            let error = await failure { try await rig.login() }
            XCTAssertEqual(error.issue, .invalidAccount, "variant \(variant)")
            XCTAssertEqual(error.cleanup.remote, .revoked)
            XCTAssertTrue(rig.secrets.writes.isEmpty)
        }
    }

    func testSecretSaveFailureRevokesCandidateAndDisablesStartup() async throws {
        let rig = try SyncAccountRig()
        rig.secrets.writeError = SecretStoreError.writeFailed
        let error = await failure { try await rig.login() }
        XCTAssertEqual(error.issue, .secret(.writeFailed))
        XCTAssertEqual(error.cleanup.remote, .revoked)
        XCTAssertEqual(rig.logouts.count, 1)
        XCTAssertTrue(rig.secrets.persisted.isEmpty)
        XCTAssertNil(try rig.sync.accounts.loadAccount())
        XCTAssertFalse(rig.sync.service.report.enabled)
        let requests = rig.sync.transport.requests.count
        let observed1 = try await rig.account.startup()
        XCTAssertFalse(observed1.enabled)
        XCTAssertEqual(rig.sync.transport.requests.count, requests)
    }

    func testCandidateAndActivationMetadataWriteFailuresCompensate() async throws {
        // In an empty graph: disable, candidate, ownership, state, enable.
        for failedWrite in [2, 5] {
            let rig = try SyncAccountRig()
            rig.sync.base.data.failWriteNumber = failedWrite
            let error = await failure { try await rig.login() }
            XCTAssertEqual(error.issue, .metadata(.writeFailed(.ioFailure)))
            XCTAssertEqual(error.cleanup.remote, .revoked)
            XCTAssertEqual(rig.secrets.writes.count, 1)
            XCTAssertTrue(rig.secrets.persisted.isEmpty)
            XCTAssertNil(try rig.sync.accounts.loadAccount())
            XCTAssertFalse(rig.sync.service.report.enabled)
            let observed2 = try await rig.account.startup()
            XCTAssertFalse(observed2.enabled)
            try rig.assertNoCredentialsInData()
        }
    }

    func testUncertainCandidateMetadataIsRecoveredBeforeCompensation() async throws {
        let rig = try SyncAccountRig()
        rig.sync.base.dataOperations.failFlushNumber = 5 // Candidate's directory flush, after disable's three.
        let error = await failure { try await rig.login() }
        XCTAssertEqual(error.issue, .metadata(.durabilityUncertain))
        XCTAssertEqual(error.cleanup.remote, .revoked)
        XCTAssertNil(error.cleanup.metadataIssue)
        XCTAssertNil(try rig.sync.accounts.loadAccount())
        XCTAssertEqual(try rig.sync.accounts.loadConnection().activation, .inactive)
        XCTAssertTrue(rig.secrets.persisted.isEmpty)
    }

    func testFailedCompensationReportsRemoteAndSecretCleanupAndCanRetry() async throws {
        let rig = try SyncAccountRig()
        rig.sync.base.data.failWriteNumber = 2
        rig.secrets.deleteError = SecretStoreError.deleteFailed
        let normal = rig.sync.transport.handler
        rig.sync.transport.handler = { index, request in
            if request.url.path.hasSuffix("/logout") { throw HTTPTransportError.networkFailure }
            return try await normal(index, request)
        }
        let error = await failure { try await rig.login() }
        XCTAssertEqual(error.cleanup.remote, .unconfirmed)
        XCTAssertEqual(error.cleanup.secretFailures, [rig.firstConnection])
        XCTAssertFalse(error.cleanup.isComplete)
        XCTAssertEqual(try rig.sync.accounts.loadConnection().cleanupConnections, [rig.firstConnection])
        let stored = try XCTUnwrap(rig.secrets.persisted[.device(rig.firstConnection)])
        rig.secrets.environment[.device(rig.firstConnection)] = stored.value
        let reads = rig.secrets.reads.count
        let observed3 = try await rig.account.startup()
        XCTAssertFalse(observed3.enabled)
        XCTAssertEqual(rig.secrets.reads.count, reads)
        rig.secrets.deleteError = nil
        let cleanup = try await rig.account.signOut()
        XCTAssertTrue(cleanup.secretFailures.isEmpty)
        XCTAssertTrue(rig.secrets.persisted.isEmpty)
        XCTAssertTrue(try rig.sync.accounts.loadConnection().cleanupConnections.isEmpty)
        XCTAssertNotNil(rig.secrets.environment[.device(rig.firstConnection)])
    }

    func testFailedLoginPreservesPendingSecretCleanupInErrorAndSnapshot() async throws {
        let rig = try SyncAccountRig()
        let pending = SyncTestValues.uuid
        try rig.sync.accounts.saveInactive(nil, retiring: [pending])
        rig.secrets.writeError = SecretStoreError.writeFailed
        rig.secrets.deleteError = SecretStoreError.locked

        let error = await failure { try await rig.login() }
        XCTAssertEqual(error.issue, .secret(.writeFailed))
        XCTAssertEqual(Set(error.cleanup.secretFailures), [pending, rig.firstConnection])
        XCTAssertEqual(error.cleanup.secretFailures.count, 2)
        XCTAssertEqual(rig.account.snapshot.cleanup, error.cleanup)
        XCTAssertEqual(Set(try rig.sync.accounts.loadConnection().cleanupConnections), [pending, rig.firstConnection])
    }

    func testReservedFolderGateCompensatesAndLeavesLibraryUntouched() async throws {
        for path in ["Groups", "Conflicts", "groups", "CONFLICTS"] {
            let rig = try SyncAccountRig()
            try rig.sync.base.libraryOperations.createDirectory(at: RelativePath(path))
            try rig.sync.base.files.put("keep", at: path + "/a.md")
            let error = await failure { try await rig.login() }
            XCTAssertEqual(error.issue, .reservedFolders([RelativePath(path)]))
            XCTAssertEqual(error.cleanup.remote, .revoked)
            XCTAssertEqual(try rig.sync.base.files.text(at: path + "/a.md"), "keep")
            XCTAssertNil(try rig.sync.accounts.binding(for: rig.sync.base.binding.root))
            XCTAssertFalse(rig.sync.service.report.enabled)
            XCTAssertTrue(rig.secrets.persisted.isEmpty)
        }
    }

    func testStartupUsesBoundEnvelopeAndSameAccountState() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let account = try XCTUnwrap(rig.account.snapshot.account)
        let state = try XCTUnwrap(rig.sync.base.states.load(for: rig.sync.base.binding))
        rig.sync.service.stop()
        await rig.sync.service.drain()
        let restarted = rig.reopenAccount()
        let result = try await restarted.startup()
        await rig.sync.settle()
        XCTAssertEqual(result.account, account)
        XCTAssertTrue(result.enabled)
        XCTAssertEqual(rig.sync.base.states.snapshot.value?.binding, state.binding)
        XCTAssertEqual(rig.secrets.writes.count, 1)
    }

    func testPersistedTokenCannotBeReboundToServerUserOrConnection() async throws {
        for mutation in 0..<4 {
            let rig = try SyncAccountRig()
            try await rig.login()
            await rig.sync.settle()
            rig.sync.service.stop()
            await rig.sync.service.drain()
            let original = try XCTUnwrap(rig.account.snapshot.account)
            var envelope = try XCTUnwrap(rig.secrets.persisted[original.secretAccount]).value.withValue {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
            switch mutation {
            case 0: envelope["server_url"] = "https://other.test"
            case 1: envelope["user_id"] = SyncTestValues.otherUser.rawValue
            case 2: envelope["connection_id"] = UUID().uuidString.lowercased()
            default: envelope["version"] = 9
            }
            rig.secrets.persisted[original.secretAccount] = StoredSecret(value: SecretValue(String(decoding:
                try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)), tier: .secretService)
            let count = rig.sync.transport.requests.count
            let error = await failure { try await rig.reopenAccount().startup() }
            XCTAssertEqual(error.issue, .tokenBindingMismatch)
            XCTAssertEqual(rig.sync.transport.requests.count, count)
            XCTAssertFalse(rig.sync.service.report.enabled)
        }
    }

    func testRawPersistedTokenRequiresReauthentication() async throws {
        let rig = try SyncAccountRig()
        let connection = try rig.connection()
        try rig.sync.accounts.setAccount(connection)
        rig.secrets.persisted[connection.secretAccount] = StoredSecret(value: SecretValue(rig.token), tier: .file)
        let error = await failure { try await rig.account.startup() }
        XCTAssertEqual(error.issue, .tokenBindingMismatch)
        XCTAssertTrue(rig.sync.transport.requests.isEmpty)
    }

    func testMissingOrLockedStartupTokenDoesNotEnable() async throws {
        for locked in [false, true] {
            let rig = try SyncAccountRig()
            try rig.sync.accounts.setAccount(rig.connection())
            if locked { rig.secrets.readError = SecretStoreError.locked }
            let error = await failure { try await rig.account.startup() }
            XCTAssertEqual(error.issue, locked ? .secret(.locked) : .credentialsRequired)
            XCTAssertFalse(rig.sync.service.report.enabled)
            XCTAssertTrue(rig.sync.transport.requests.isEmpty)
        }
    }

    func testEnvironmentStartupValidatesCurrentDeviceAndAccount() async throws {
        for changed in [false, true] {
            let rig = try SyncAccountRig()
            let connection = try rig.connection()
            try rig.sync.accounts.setAccount(connection)
            rig.secrets.environment[connection.secretAccount] = SecretValue(rig.token)
            if changed { rig.userID = SyncTestValues.otherUser }
            if changed {
                let error = await failure { try await rig.account.startup() }
                XCTAssertEqual(error.issue, .invalidAccount)
                XCTAssertFalse(rig.sync.service.report.enabled)
                XCTAssertNil(try rig.sync.accounts.binding(for: rig.sync.base.binding.root))
            } else {
                let result = try await rig.account.startup()
                await rig.sync.settle()
                XCTAssertEqual(result.tier, .environment)
                XCTAssertTrue(result.enabled)
                XCTAssertTrue(rig.secrets.writes.isEmpty)
            }
        }
    }

    func testEnvironmentCannotResumeChangedDeviceOrOwnedAccount() async throws {
        for changedOwner in [false, true] {
            let rig = try SyncAccountRig()
            let connection = try rig.connection()
            try rig.sync.accounts.setAccount(connection)
            rig.secrets.environment[connection.secretAccount] = SecretValue(rig.token)
            if changedOwner {
                try rig.sync.accounts.updateBinding(for: rig.sync.base.binding.root) { _ in
                    try SyncLibraryBinding(root: rig.sync.base.binding.root, owner: SyncTestValues.account(userID: SyncTestValues.otherUser))
                }
            } else { rig.device = SyncTestValues.group }
            _ = await failure { try await rig.account.startup() }
            XCTAssertFalse(rig.sync.service.report.enabled)
            XCTAssertTrue(rig.puts.isEmpty)
        }
    }

    func testSameAccountReauthenticationPreservesQueuedEditsAndCursors() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        rig.sync.service.stop()
        await rig.sync.service.drain()
        try rig.sync.base.files.write(SyncScanTestSupport.bytes("Queued", id: SyncTestValues.personalPrompt), at: "queued.md")
        let cursor = rig.sync.base.states.snapshot.value?.cursors
        let old = rig.account.snapshot.account
        let normal = rig.sync.transport.handler
        rig.sync.transport.handler = { index, request in
            if request.url.path.hasSuffix("/sync/pull") {
                let pull = try JSONDecoder().decode(SyncAPI.PullRequest.self, from: XCTUnwrap(request.body))
                XCTAssertEqual(pull.cursors["user:" + rig.userID.rawValue], cursor?[.user(rig.userID)])
                return try rig.pull(mode: .delta)
            }
            return try await normal(index, request)
        }
        try await rig.login()
        await rig.sync.settle()
        XCTAssertTrue(rig.account.snapshot.enabled)
        XCTAssertNotEqual(rig.account.snapshot.account?.connectionID, old?.connectionID)
        XCTAssertEqual(rig.puts.count, 1)
        XCTAssertEqual(try rig.sync.accounts.binding(for: rig.sync.base.binding.root)?.holds.count, 0)
        XCTAssertNil(rig.secrets.persisted[try XCTUnwrap(old).secretAccount])
    }

    func testDifferentUserHoldsAllOldPrivateAndRescuesGroupsBeforeEnable() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        rig.sync.service.stop()
        await rig.sync.service.drain()
        try rig.sync.base.files.write(SyncScanTestSupport.bytes("Private", id: nil), at: "old.md")
        try rig.sync.base.files.write(SyncScanTestSupport.bytes("Group", id: SyncTestValues.groupPrompt), at: "Groups/Team/shared.md")
        try rig.sync.base.files.write(Data([0xFF, 0x00]), at: "Groups/Team/raw.bin")
        try rig.sync.accounts.updateBinding(for: rig.sync.base.binding.root) { current in
            var owned = try XCTUnwrap(current)
            owned.managedFolders[SyncTestValues.group] = try SyncManagedFolder(owner: owned.owner, folder: "Team")
            return owned
        }
        try rig.sync.base.states.update(for: rig.sync.base.binding) {
            $0.groups[SyncTestValues.group] = try SyncGroupState(name: "Team", folder: "Team", role: .editor)
        }
        rig.userID = SyncTestValues.otherUser
        let count = rig.puts.count
        try await rig.login()
        await rig.sync.settle()
        let owned = try XCTUnwrap(rig.sync.accounts.binding(for: rig.sync.base.binding.root))
        XCTAssertEqual(owned.owner.userID, rig.userID)
        XCTAssertEqual(owned.holds.count, 3)
        XCTAssertEqual(rig.puts.count, count)
        XCTAssertNil(try rig.sync.base.files.stamp(at: "Groups/Team/shared.md"))
        let files = try rig.sync.base.files.listFiles()
        XCTAssertEqual(files.filter { $0.relativePath.hasPrefix("Conflicts/rescued-") }.count, 2)
        XCTAssertTrue(try rig.sync.base.files.text(at: "old.md").contains("id:"))
        XCTAssertEqual(rig.sync.base.states.snapshot.value?.binding.account.userID, rig.userID)
        XCTAssertTrue(owned.managedFolders.isEmpty)
    }

    func testSignOutThenDifferentUserUsesRetainedOwnershipAndHoldsIdlessFiles() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let cleanup = try await rig.account.signOut()
        XCTAssertTrue(cleanup.isComplete)
        try rig.sync.base.files.write(SyncScanTestSupport.bytes("Old account", id: nil), at: "old.md")
        rig.userID = SyncTestValues.otherUser
        try await rig.login()
        await rig.sync.settle()
        XCTAssertTrue(rig.puts.isEmpty)
        let owned = try XCTUnwrap(rig.sync.accounts.binding(for: rig.sync.base.binding.root))
        let held = try XCTUnwrap(owned.holds.first)
        XCTAssertEqual(held.sourceAccount.userID, SyncTestValues.user)
        XCTAssertEqual(owned.owner.userID, SyncTestValues.otherUser)
        if case .local = held.identity { XCTFail("Valid idless old file must acquire a durable identity") }
        try rig.sync.base.files.move(from: "old.md", to: "renamed.md")
        let bytes = try rig.sync.base.files.text(at: "renamed.md")
        try rig.sync.base.files.put(bytes + "\nEdited", at: "renamed.md")
        rig.sync.service.syncNow()
        await rig.sync.settle()
        XCTAssertTrue(rig.puts.isEmpty)
    }

    func testDifferentServerHoldsOldLibraryAndUsesOnlyNewServerCredential() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        rig.sync.service.stop()
        await rig.sync.service.drain()
        try rig.sync.base.files.write(SyncScanTestSupport.bytes("Private", id: nil), at: "old.md")
        rig.server = "https://other.test/deploy"
        rig.token = String(repeating: "b", count: 42) + "A"
        let before = rig.sync.transport.requests.count
        try await rig.login()
        await rig.sync.settle()
        XCTAssertTrue(rig.puts.isEmpty)
        let requests = Array(rig.sync.transport.requests.dropFirst(before)).filter { !$0.url.path.hasSuffix("/logout") }
        XCTAssertTrue(requests.allSatisfy { $0.url.host == "other.test" })
        XCTAssertNil(requests.first?.headers["Authorization"])
        XCTAssertTrue(requests.dropFirst().allSatisfy { $0.headers["Authorization"] == "Bearer " + rig.token })
        XCTAssertEqual(try rig.sync.accounts.binding(for: rig.sync.base.binding.root)?.holds.count, 1)
    }

    func testAccountChangeFailureKeepsRecoveryAndInactiveConnectionThenReplaysSafely() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        rig.sync.service.stop()
        await rig.sync.service.drain()
        try rig.sync.base.files.write(SyncScanTestSupport.bytes("Old", id: nil), at: "old.md")
        rig.userID = SyncTestValues.otherUser
        var flushes = 0
        rig.sync.base.dataOperations.onOperation = { operation in
            if operation == "file:sync/binding.json" {
                flushes += 1
                if flushes == 1 { rig.sync.base.dataOperations.failOperationNumber = rig.sync.base.dataOperations.operationCount }
            }
        }
        _ = await failure { try await rig.login() }
        XCTAssertFalse(rig.sync.service.report.enabled)
        XCTAssertNotNil(rig.sync.journal.pending)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: rig.sync.base.data.read(at: "sync/account.json")) as? [String: Any])
        XCTAssertEqual(document["activation"] as? String, "inactive")
        XCTAssertThrowsError(try rig.sync.base.library.entries()) { XCTAssertEqual($0 as? LibraryError, .recoveryRequired) }
        let count = rig.sync.transport.requests.count
        _ = await failure { try await rig.account.startup() }
        XCTAssertEqual(rig.sync.transport.requests.count, count)
        rig.sync.base.dataOperations.onOperation = nil
        try await rig.login()
        await rig.sync.settle()
        XCTAssertNil(rig.sync.journal.pending)
        XCTAssertTrue(rig.puts.isEmpty)
        XCTAssertEqual(try rig.sync.accounts.binding(for: rig.sync.base.binding.root)?.holds.count, 1)
    }

    func testDeviceListOwnRevokeAndForeign404KeepCurrentConnection() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let other = SyncTestValues.group
        let normal = rig.sync.transport.handler
        rig.sync.transport.handler = { index, request in
            if request.url.path.hasSuffix("/me") {
                return try SyncServiceRig.http(SyncAPI.MeResponse(user: rig.user(), groups: [],
                    devices: [rig.deviceDTO(), rig.deviceDTO(id: other, current: false, revoked: true)]))
            }
            if request.method == .delete, request.url.path.hasSuffix(SyncTestValues.otherUser.rawValue) {
                return try SyncServiceRig.failure(.notFound)
            }
            return try await normal(index, request)
        }
        let devices = try await rig.account.devices()
        XCTAssertEqual(devices.count, 2)
        let observed5 = try await rig.account.revokeDevice(other)
        XCTAssertTrue(observed5.enabled)
        XCTAssertTrue(rig.sync.service.report.enabled)
        let error = await failure { try await rig.account.revokeDevice(SyncTestValues.otherUser) }
        XCTAssertEqual(error.issue, .http(.notFound))
        XCTAssertTrue(rig.account.snapshot.enabled)
        XCTAssertNotNil(rig.secrets.persisted[try XCTUnwrap(rig.account.snapshot.account).secretAccount])
    }

    func testCurrentDeviceRevokeSignsOutAndClearsStateSecretsButKeepsFilesAndOwnership() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let owner = try rig.sync.accounts.binding(for: rig.sync.base.binding.root)
        try rig.sync.base.files.put("keep locally", at: "local.txt")
        let result = try await rig.account.revokeDevice(rig.device)
        XCTAssertEqual(result.cleanup.remote, .revoked)
        XCTAssertFalse(result.enabled)
        XCTAssertFalse(rig.sync.service.report.enabled)
        XCTAssertTrue(rig.secrets.persisted.isEmpty)
        XCTAssertNil(try rig.sync.accounts.loadAccount())
        XCTAssertNil(rig.sync.base.states.snapshot.value)
        XCTAssertEqual(try rig.sync.accounts.binding(for: rig.sync.base.binding.root), owner)
        XCTAssertEqual(try rig.sync.base.files.text(at: "local.txt"), "keep locally")
        XCTAssertEqual(rig.sync.transport.requests.last?.method, .delete)
    }

    func testOfflineLogoutStillSignsOutAndCannotResumeEnvironment() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let account = try XCTUnwrap(rig.account.snapshot.account)
        rig.secrets.environment[account.secretAccount] = SecretValue(rig.token)
        rig.sync.transport.handler = { _, request in
            if request.url.path.hasSuffix("/logout") {
                XCTAssertLessThanOrEqual(ContinuousClock.now.duration(to: request.deadline), Limits.syncLogoutTimeout)
            }
            throw HTTPTransportError.networkFailure
        }
        let cleanup = try await rig.account.signOut()
        XCTAssertEqual(cleanup.remote, .unconfirmed)
        XCTAssertFalse(cleanup.isComplete)
        XCTAssertFalse(rig.sync.service.report.enabled)
        XCTAssertNil(try rig.sync.accounts.loadAccount())
        XCTAssertTrue(rig.secrets.persisted.isEmpty)
        XCTAssertNotNil(rig.secrets.environment[account.secretAccount])
        let requests = rig.sync.transport.requests.count
        let reads = rig.secrets.reads.count
        let observed6 = try await rig.reopenAccount().startup()
        XCTAssertFalse(observed6.enabled)
        XCTAssertEqual(rig.sync.transport.requests.count, requests)
        XCTAssertEqual(rig.secrets.reads.count, reads)
    }

    func testLogoutSecretFailureIsRetriableAndEnvironmentNeverReenables() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let account = try XCTUnwrap(rig.account.snapshot.account)
        rig.secrets.environment[account.secretAccount] = SecretValue(rig.token)
        rig.secrets.deleteError = SecretStoreError.locked
        let cleanup = try await rig.account.signOut()
        XCTAssertEqual(cleanup.secretFailures, [account.connectionID])
        XCTAssertEqual(cleanup.remote, .revoked)
        XCTAssertFalse(cleanup.isComplete)
        let observed7 = try await rig.reopenAccount().startup()
        XCTAssertFalse(observed7.enabled)
        XCTAssertNotNil(rig.secrets.persisted[account.secretAccount])
        rig.secrets.deleteError = nil
        let retry = try await rig.account.signOut()
        XCTAssertTrue(retry.isComplete)
        XCTAssertNil(rig.secrets.persisted[account.secretAccount])
        XCTAssertNotNil(rig.secrets.environment[account.secretAccount])
    }

    func testLogoutMetadataClearFailureStillHasDurableInactiveGate() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let account = try XCTUnwrap(rig.account.snapshot.account)
        rig.secrets.environment[account.secretAccount] = SecretValue(rig.token)
        rig.sync.base.data.failWriteNumber = rig.sync.base.data.writeCount + 2
        let cleanup = try await rig.account.signOut()
        XCTAssertNotNil(cleanup.metadataIssue)
        XCTAssertEqual(try rig.sync.accounts.loadConnection().activation, .inactive)
        let observed8 = try await rig.reopenAccount().startup()
        XCTAssertFalse(observed8.enabled)
        XCTAssertFalse(rig.sync.service.report.enabled)
    }

    func testRecoveredMetadataClearCannotHideUnreadPendingSecretCleanup() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let account = try XCTUnwrap(rig.account.snapshot.account)
        let pending = SyncTestValues.uuid
        try rig.sync.accounts.setAccount(account, retiring: [pending])
        rig.secrets.persisted[.device(pending)] = StoredSecret(value: SecretValue("unused synthetic"), tier: .secretService)
        rig.sync.base.dataOperations.failFlushNumber = rig.sync.base.dataOperations.flushCount + 1
        XCTAssertThrowsError(try rig.sync.accounts.disableAutomaticResume()) {
            XCTAssertEqual($0 as? SyncError, .durabilityUncertain)
        }
        rig.sync.base.dataOperations.failFlushNumber = nil

        let cleanup = try await rig.account.signOut()
        XCTAssertEqual(cleanup.remote, .revoked)
        XCTAssertEqual(cleanup.metadataIssue, .durabilityUncertain)
        XCTAssertFalse(cleanup.isComplete)
        XCTAssertFalse(rig.account.snapshot.enabled)
        XCTAssertNil(rig.secrets.persisted[account.secretAccount])
        XCTAssertNotNil(rig.secrets.persisted[.device(pending)])
        XCTAssertEqual(try rig.sync.accounts.loadConnection().cleanupConnections, [pending])
        let retry = try await rig.account.signOut()
        XCTAssertTrue(retry.isComplete)
        XCTAssertTrue(rig.secrets.persisted.isEmpty)
        XCTAssertTrue(try rig.sync.accounts.loadConnection().cleanupConnections.isEmpty)
    }

    func testRecoveredResumeDisableFailureCompletesCleanupOfKnownSecrets() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        var failed = false
        rig.sync.base.dataOperations.onOperation = { operation in
            if operation == "file:sync/account.json", !failed {
                failed = true
                rig.sync.base.dataOperations.failOperationNumber = rig.sync.base.dataOperations.operationCount
            }
        }

        let cleanup = try await rig.account.signOut()
        rig.sync.base.dataOperations.onOperation = nil
        XCTAssertTrue(failed)
        XCTAssertTrue(cleanup.isComplete)
        XCTAssertNil(cleanup.metadataIssue)
        XCTAssertNil(try rig.sync.accounts.loadAccount())
        XCTAssertTrue(try rig.sync.accounts.loadConnection().cleanupConnections.isEmpty)
        XCTAssertTrue(rig.secrets.persisted.isEmpty)
    }

    func testBusyLoginAlsoConsumesPasswordAndMakesNoSecondRequest() async throws {
        let rig = try SyncAccountRig()
        let normal = rig.sync.transport.handler
        let entered = expectation(description: "one admitted login")
        let gate = SyncTransportGate()
        rig.sync.transport.handler = { index, request in
            if index == 0 { entered.fulfill(); await gate.wait() }
            return try await normal(index, request)
        }
        let first = Task { try await rig.login() }
        await fulfillment(of: [entered], timeout: 2)
        var password = rig.password
        let error = await failure { try await rig.account.login(server: rig.server, username: "person", password: &password, deviceName: "Desktop") }
        XCTAssertEqual(error.issue, .busy)
        XCTAssertEqual(password, "")
        XCTAssertEqual(rig.sync.transport.requests.count, 1)
        await gate.open()
        _ = try await first.value
        await rig.sync.settle()
    }

    func testFailedDisableCompensatesAndLeavesSnapshotAndStartupInactive() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        rig.userID = SyncTestValues.otherUser
        rig.sync.base.data.failNextWrite = true
        _ = await failure { try await rig.login() }
        XCTAssertFalse(rig.account.snapshot.enabled)
        XCTAssertEqual(try rig.sync.accounts.loadConnection().activation, .inactive)
        XCTAssertFalse(rig.sync.service.report.enabled)
    }

    func testSameAccountRecoversPendingRequestBeforeNewBinding() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let pending = try await rig.pendingCreate()
        let normal = rig.sync.transport.handler
        rig.sync.transport.handler = { index, request in
            if request.method == .get, request.url.path.hasSuffix(pending.intent.id.rawValue) {
                return try SyncServiceRig.failure(.notFound)
            }
            if request.url.path.hasSuffix("/sync/pull") { return try rig.pull(mode: .delta) }
            return try await normal(index, request)
        }
        try await rig.login()
        await rig.sync.settle()
        XCTAssertNil(try rig.sync.pending.load(for: pending.binding))
        XCTAssertEqual(rig.puts.count, 1)
        let requests = rig.sync.transport.requests
        let head = try XCTUnwrap(requests.firstIndex { $0.method == .get && $0.url.path.hasSuffix(pending.intent.id.rawValue) })
        let lastPull = try XCTUnwrap(requests.lastIndex { $0.url.path.hasSuffix("/sync/pull") })
        XCTAssertLessThan(head, lastPull)
    }

    func testDifferentAccountAndSignOutRetainPendingFactsWithoutSending() async throws {
        for logout in [false, true] {
            let rig = try SyncAccountRig()
            try await rig.login()
            await rig.sync.settle()
            let pending = try await rig.pendingCreate()
            let count = rig.sync.transport.requests.count
            if logout { _ = try await rig.account.signOut() }
            else {
                rig.userID = SyncTestValues.otherUser
                try await rig.login()
                await rig.sync.settle()
            }
            XCTAssertNil(rig.sync.pending.snapshot.value)
            XCTAssertTrue(rig.puts.isEmpty)
            XCTAssertFalse(rig.sync.transport.requests.dropFirst(count).contains { $0.url.path.hasSuffix(pending.intent.id.rawValue) })
            let retained = try XCTUnwrap(rig.sync.base.data.listFiles().first { $0.relativePath.hasPrefix("sync/retained/push-") })
            let facts = try JSONDecoder().decode(SyncPendingOperation.self, from: rig.sync.base.data.read(at: retained.relativePath))
            XCTAssertEqual(facts.binding, pending.binding)
            XCTAssertEqual(facts.intent.sentBytes, pending.intent.sentBytes)
            XCTAssertTrue(rig.sync.base.data.isPrivate(at: retained.relativePath))
        }
    }

    func testOnlyExplicitInclusionReleasesSelectedOldContent() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        _ = try await rig.account.signOut()
        try rig.sync.base.files.write(SyncScanTestSupport.bytes("Old one", id: nil), at: "one.md")
        try rig.sync.base.files.write(SyncScanTestSupport.bytes("Old two", id: nil), at: "two.md")
        rig.userID = SyncTestValues.otherUser
        try await rig.login()
        await rig.sync.settle()
        let holds = try rig.account.heldPrompts()
        XCTAssertEqual(holds.count, 2)
        XCTAssertTrue(rig.puts.isEmpty)
        let selected = try XCTUnwrap(holds.first { $0.path == "one.md" })
        _ = try await rig.account.includeHeld([selected.identity])
        await rig.sync.settle()
        XCTAssertEqual(try rig.account.heldPrompts().count, 1)
        XCTAssertEqual(rig.puts.count, 1)
        let put = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self, from: XCTUnwrap(rig.puts.first?.body))
        XCTAssertEqual(put.path, "one.md")
    }

    func testFailedInclusionRetiresAccountAndRecoveryCredentials() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let pending = try await rig.pendingCreate()
        let normal = rig.sync.transport.handler
        var gotHead = false
        rig.sync.transport.handler = { index, request in
            if request.method == .get, request.url.path.hasSuffix(pending.intent.id.rawValue) {
                gotHead = true
                return try SyncServiceRig.failure(.notFound)
            }
            return try await normal(index, request)
        }
        rig.sync.base.data.onRead = { path in
            if path == "sync/state.json", gotHead { throw FileStoreError.ioFailure }
        }

        let error = await failure { try await rig.account.includeHeld([]) }
        XCTAssertEqual(error.issue, .metadata(.readFailed(.ioFailure)))
        XCTAssertTrue(gotHead)
        XCTAssertFalse(rig.account.snapshot.enabled)
        XCTAssertFalse(rig.sync.service.report.enabled)
        XCTAssertEqual(try rig.sync.accounts.loadConnection().activation, .inactive)

        rig.sync.base.data.onRead = nil
        try rig.sync.base.states.reset(for: pending.binding)
        try rig.sync.pending.save(pending)
        let requests = rig.sync.transport.requests.count
        do { try await rig.sync.service.recoverJournal() }
        catch { /* Failed inclusion must retire its temporary recovery credential. */ }
        let refresh = await failure { try await rig.account.refresh() }
        let devices = await failure { try await rig.account.devices() }
        XCTAssertEqual(refresh.issue, .signedOut)
        XCTAssertEqual(devices.issue, .signedOut)
        XCTAssertEqual(rig.sync.transport.requests.count, requests)
    }

    func testAccountChangeWithoutStateDoesNotDeleteMissingState() async throws {
        let rig = try SyncAccountRig()
        try rig.sync.accounts.updateBinding(for: rig.sync.base.binding.root) { _ in
            try SyncLibraryBinding(root: rig.sync.base.binding.root, owner: rig.sync.base.binding.account)
        }
        rig.userID = SyncTestValues.otherUser
        rig.sync.base.data.failNextDelete = true
        rig.sync.base.data.onWrite = { path in
            // The account-change journal may be deleted after publication.
            if path == "sync/apply.json" { rig.sync.base.data.failNextDelete = false }
        }

        let result = try await rig.login()
        await rig.sync.settle()
        XCTAssertTrue(result.enabled)
        XCTAssertEqual(try rig.sync.accounts.binding(for: rig.sync.base.binding.root)?.owner.userID, rig.userID)
    }

    func testInactiveLogoutDoesNotRevokeAnEnvironmentTokenForAnotherUser() async throws {
        let rig = try SyncAccountRig()
        let account = try rig.connection()
        try rig.sync.accounts.setAccount(account)
        rig.secrets.environment[account.secretAccount] = SecretValue(rig.token)
        rig.userID = SyncTestValues.otherUser
        let cleanup = try await rig.account.signOut()
        XCTAssertEqual(cleanup.remote, .unconfirmed)
        XCTAssertTrue(rig.logouts.isEmpty)
        XCTAssertNotNil(rig.secrets.environment[account.secretAccount])
        XCTAssertFalse(rig.sync.service.report.enabled)
    }

    func testSignOutStillFindsAndDeletesTokenWhenOwnershipMetadataIsCorrupt() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        rig.sync.service.stop()
        await rig.sync.service.drain()
        let connection = try XCTUnwrap(rig.account.snapshot.account)
        try rig.sync.base.data.put("corrupt", at: "sync/binding.json")
        let result = try await rig.reopenAccount().signOut()
        XCTAssertEqual(result.remote, .revoked)
        XCTAssertNil(rig.secrets.persisted[connection.secretAccount])
        XCTAssertEqual(try rig.sync.base.data.text(at: "sync/binding.json"), "corrupt")
        XCTAssertFalse(rig.sync.service.report.enabled)
    }

    func testStartupFailureKeepsNonSecretMetadataForReauthentication() async throws {
        let rig = try SyncAccountRig()
        let connection = try rig.connection()
        try rig.sync.accounts.setAccount(connection)
        rig.secrets.readError = SecretStoreError.locked
        _ = await failure { try await rig.account.startup() }
        XCTAssertEqual(rig.account.snapshot.account, connection)
        XCTAssertFalse(rig.account.snapshot.enabled)
        XCTAssertNil(rig.account.snapshot.me)
        XCTAssertNil(rig.account.snapshot.tier)
    }

    func testFailedSignOutRecoveryCannotRetryNetworkWithRetiredCredential() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        _ = try await rig.pendingCreate()
        let old = try XCTUnwrap(rig.sync.base.states.snapshot.value)
        let edit = try rig.sync.base.mutations.publication(SyncScanTestSupport.bytes("Apply", id: SyncTestValues.groupPrompt),
            at: "apply.md", expecting: nil, transition: SyncIdentityTransition(from: nil, to: .assigned(SyncTestValues.groupPrompt)))
        let plan = SyncApplyPlan(expectedState: old, nextState: old, edits: [edit])
        rig.sync.base.dataOperations.onOperation = { operation in
            if operation == "file:sync/apply.json" { rig.sync.base.dataOperations.failOperationNumber = rig.sync.base.dataOperations.operationCount }
        }
        XCTAssertThrowsError(try rig.sync.journal.apply(plan))
        let normal = rig.sync.transport.handler
        rig.sync.transport.handler = { index, request in
            if request.url.path.hasSuffix("/logout") { throw HTTPTransportError.networkFailure }
            return try await normal(index, request)
        }
        let cleanup = try await rig.account.signOut()
        XCTAssertTrue(cleanup.recoveryRequired)
        XCTAssertEqual(cleanup.remote, .unconfirmed)
        rig.sync.base.dataOperations.onOperation = nil
        let requests = rig.sync.transport.requests.count
        do { try await rig.sync.service.recoverJournal() }
        catch { /* The signed-out graph has no authenticated recovery session. */ }
        XCTAssertEqual(rig.sync.transport.requests.count, requests)
        XCTAssertFalse(rig.sync.service.report.enabled)
    }

    func testOldSecretCleanupReferenceSurvivesMetadataAndDeleteFaultAcrossRestart() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let old = try XCTUnwrap(rig.account.snapshot.account)
        rig.token = String(repeating: "b", count: 42) + "A"
        rig.secrets.deleteError = SecretStoreError.locked
        rig.sync.base.data.onWrite = { path in
            guard path == "sync/account.json",
                  let document = try? JSONSerialization.jsonObject(with: rig.sync.base.data.read(at: path)) as? [String: Any],
                  document["activation"] as? String == "enabled",
                  let account = document["account"] as? [String: Any],
                  account["connection_id"] as? String != old.connectionID.uuidString.lowercased() else { return }
            rig.sync.base.data.onWrite = nil
            // Fail the cleanup metadata write following new-account enablement.
            rig.sync.base.data.failNextWrite = true
        }
        var password = rig.password
        let result = try await rig.reopenAccount().login(server: rig.server, username: "person", password: &password, deviceName: "Desktop")
        await rig.sync.settle()
        XCTAssertEqual(result.cleanup.secretFailures, [old.connectionID])
        XCTAssertEqual(result.cleanup.remote, .unconfirmed)
        XCTAssertTrue(try rig.sync.accounts.loadConnection().cleanupConnections.contains(old.connectionID))
        rig.secrets.deleteError = nil
        _ = try await rig.reopenAccount().signOut()
        XCTAssertTrue(rig.secrets.persisted.isEmpty)
    }

    func testFailedStartupRetiresResumeCredentialBeforeDeferredRecovery() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let pending = try await rig.pendingCreate()
        let normal = rig.sync.transport.handler
        var gotHead = false
        var reads = 0
        rig.sync.transport.handler = { index, request in
            if request.method == .get, request.url.path.hasSuffix(pending.intent.id.rawValue) {
                gotHead = true
                return try SyncServiceRig.failure(.notFound)
            }
            return try await normal(index, request)
        }
        rig.sync.base.data.onRead = { path in
            if path == "sync/state.json", gotHead {
                reads += 1
                if reads == 1 { throw FileStoreError.ioFailure }
            }
        }
        _ = await failure { try await rig.reopenAccount().startup() }
        XCTAssertTrue(gotHead)
        rig.sync.base.data.onRead = nil
        try rig.sync.base.states.reset(for: pending.binding)
        try rig.sync.pending.save(pending)
        let requests = rig.sync.transport.requests.count
        do { try await rig.sync.service.recoverJournal() }
        catch { /* A failed startup has no authenticated recovery session. */ }
        XCTAssertEqual(rig.sync.transport.requests.count, requests)
        XCTAssertFalse(rig.sync.service.report.enabled)
    }

    func testUnreadableSignOutMetadataReportsUnconfirmedRemoteRevocation() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        rig.sync.service.stop()
        await rig.sync.service.drain()
        try rig.sync.base.data.put("corrupt", at: "sync/account.json")
        let cleanup = try await rig.reopenAccount().signOut()
        XCTAssertEqual(cleanup.remote, .unconfirmed)
        XCTAssertEqual(cleanup.metadataIssue, .corruptFile)
        XCTAssertFalse(cleanup.isComplete)
        XCTAssertFalse(rig.sync.service.report.enabled)
    }

    func testMeUnauthorizedImmediatelyStopsCurrentWork() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let normal = rig.sync.transport.handler
        rig.sync.transport.handler = { index, request in
            if request.url.path.hasSuffix("/me") { return try SyncServiceRig.failure(.unauthorized) }
            return try await normal(index, request)
        }
        _ = await failure { try await rig.account.refresh() }
        XCTAssertFalse(rig.sync.service.report.enabled)
        XCTAssertFalse(rig.account.snapshot.enabled)
    }

    func testCanceledCandidateStillGetsIndependentRevocationAttempt() async throws {
        let rig = try SyncAccountRig()
        let entered = expectation(description: "one candidate me request")
        let gate = SyncTransportGate()
        let normal = rig.sync.transport.handler
        rig.sync.transport.handler = { index, request in
            if index == 1 { entered.fulfill(); await gate.wait() }
            return try await normal(index, request)
        }
        let task = Task { await self.failure { try await rig.login() } }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await gate.open()
        let error = await task.value
        XCTAssertEqual(error.cleanup.remote, .revoked)
        XCTAssertEqual(rig.logouts.count, 1)
        XCTAssertTrue(rig.secrets.persisted.isEmpty)
    }

    func testInactiveStartupStopsAnyPreviouslyRunningSession() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        try rig.sync.accounts.disableAutomaticResume()
        let result = try await rig.account.startup()
        XCTAssertFalse(result.enabled)
        XCTAssertFalse(rig.sync.service.report.enabled)
        let count = rig.sync.transport.requests.count
        rig.sync.scheduler.advance(.seconds(600))
        await rig.sync.service.drain()
        XCTAssertEqual(rig.sync.transport.requests.count, count)
    }

    func testServiceAndFailuresRedactDescriptionsAndReflection() async throws {
        let rig = try SyncAccountRig()
        try await rig.login()
        await rig.sync.settle()
        let error = SyncAccountServiceError(issue: .http(.validation(issues: [.init(code: rig.token, severity: .error)])))
        for value in [String(describing: rig.account), String(reflecting: rig.account), String(describing: error), String(reflecting: error),
                      String(describing: Array(Mirror(reflecting: rig.account).children)), String(describing: Array(Mirror(reflecting: error).children)),
                      String(reflecting: rig.account.snapshot)] {
            XCTAssertFalse(value.contains(rig.token))
            XCTAssertFalse(value.contains(rig.password))
        }
    }

    private func failure<Value>(_ work: () async throws -> Value, file: StaticString = #filePath, line: UInt = #line) async -> SyncAccountServiceError {
        do { _ = try await work(); XCTFail("Expected failure", file: file, line: line) }
        catch let error as SyncAccountServiceError { return error }
        catch { XCTFail("Unexpected error type", file: file, line: line) }
        return SyncAccountServiceError(issue: .invalidInput)
    }
}

private final class SyncAccountRig {
    let sync: SyncServiceRig
    let secrets = FakeProviderSecrets()
    let account: SyncAccountService
    let firstConnection = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let password = "Runtime-password-" + UUID().uuidString
    var token = String(repeating: "a", count: 42) + "A"
    var userID = SyncTestValues.user
    var device = SyncTestValues.device
    var server = "https://example.test/paw"

    var logouts: [HTTPRequest] { sync.transport.requests.filter { $0.url.path.hasSuffix("/logout") } }
    var puts: [HTTPRequest] { sync.transport.requests.filter { $0.method == .put } }

    init() throws {
        sync = try SyncServiceRig()
        var number: UInt64 = 0
        let first = firstConnection
        account = SyncAccountService(sync: sync.service, accounts: sync.accounts, secrets: secrets, transport: sync.transport,
            root: sync.base.binding.root, connectionID: {
                number += 1
                if number == 1 { return first }
                return UUID()
            })
        sync.transport.handler = { [weak self] _, request in
            guard let self else { throw HTTPTransportError.networkFailure }
            switch request.url.path {
            case let path where path.hasSuffix("/login"):
                return try SyncServiceRig.http(SyncAPI.AuthResponse(deviceToken: self.token, user: self.user()))
            case let path where path.hasSuffix("/me"):
                return try SyncServiceRig.http(SyncAPI.MeResponse(user: self.user(), groups: [], devices: [self.deviceDTO()]))
            case let path where path.hasSuffix("/sync/pull"):
                return try self.pull()
            default:
                if request.method == .put { return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: 1, seq: 1)) }
                return try SyncServiceRig.http(SyncAPI.EmptyResponse())
            }
        }
    }

    @discardableResult func login() async throws -> SyncAccountSnapshot {
        var password = password
        let result = try await account.login(server: server, username: "person", password: &password, deviceName: "Desktop")
        XCTAssertEqual(password, "")
        return result
    }

    func reopenAccount(beforeAccountChange: @escaping () async -> Bool = { true }) -> SyncAccountService {
        SyncAccountService(sync: sync.service, accounts: sync.accounts, secrets: secrets, transport: sync.transport,
            root: sync.base.binding.root, connectionID: UUID.init, beforeAccountChange: beforeAccountChange)
    }

    func user(_ id: ULID? = nil) -> SyncAPI.User {
        .init(id: (id ?? userID).rawValue, username: "person", displayName: nil, accountKind: .member,
            createdAt: "2026-10-14T00:00:00.000Z", disabledAt: nil)
    }

    func deviceDTO(id: ULID? = nil, current: Bool = true, revoked: Bool = false) -> SyncAPI.Device {
        .init(id: (id ?? device).rawValue, name: "Desktop", createdAt: "2026-10-14T00:00:00.000Z", lastSeenAt: nil,
            revokedAt: revoked ? "2026-10-14T01:00:00.000Z" : nil, isCurrent: current)
    }

    func connection() throws -> SyncAccount {
        try SyncAccount(identity: SyncAccountIdentity(serverURL: server, userID: userID), username: "person",
            deviceID: device, deviceName: "Desktop", connectionID: firstConnection)
    }

    func pendingCreate() async throws -> SyncPendingOperation {
        sync.service.stop()
        await sync.service.drain()
        try sync.base.files.write(SyncScanTestSupport.bytes("Uncertain request", id: SyncTestValues.personalPrompt), at: "pending.md")
        let file = try XCTUnwrap(sync.base.mutations.read(at: "pending.md"))
        let scope = SyncScopeKey.user(userID)
        let sent = try SyncLocalScanner.canonical(file.bytes, path: "pending.md", scope: scope).bytes
        let intent = try SyncConflictIntent(id: SyncTestValues.personalPrompt, operation: .put, baseRev: 0,
            scope: scope, path: "pending.md", sentBytes: sent, inputBytes: file.bytes, accessGeneration: 0)
        let request = try SyncPendingOperation(binding: XCTUnwrap(sync.base.states.snapshot.value).binding,
            intent: intent, libraryPath: "pending.md", file: file, recorded: nil)
        try sync.pending.save(request)
        return request
    }

    func pull(mode: SyncAPI.Mode = .snapshot) throws -> HTTPResponse {
        try SyncServiceRig.http(SyncAPI.PullResponse(databaseID: SyncTestValues.uuid.uuidString.lowercased(),
            scopes: [.init(identity: .user(userID: userID.rawValue), mode: mode, head: 1, cursor: "opaque", hasMore: false, items: [])], removed: []))
    }

    func assertNoCredentialsInData(file: StaticString = #filePath, line: UInt = #line) throws {
        for entry in try sync.base.data.listFiles() {
            let text = try sync.base.data.text(at: entry.relativePath)
            XCTAssertFalse(text.contains(token), entry.relativePath, file: file, line: line)
            XCTAssertFalse(text.contains(password), entry.relativePath, file: file, line: line)
        }
    }
}
