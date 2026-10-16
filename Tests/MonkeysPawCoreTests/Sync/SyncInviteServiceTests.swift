import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncInviteServiceTests: XCTestCase {
    func testConcurrentPullAndAccountFilesDoNotRaceInMemoryStore() throws {
        let files = MemoryFileStore()
        let bytes = Data("state".utf8)
        let failuresLock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 512) { index in
            do { try files.writePrivate(bytes, at: "sync/concurrent-\(index).json") }
            catch { failuresLock.lock(); failures += 1; failuresLock.unlock() }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(try files.listFiles().count, 512)
        for index in 0..<512 {
            XCTAssertEqual(try files.read(at: "sync/concurrent-\(index).json"), bytes)
        }
    }

    func testStagingDoesNoHTTPClipboardOrPersistence() throws {
        let rig = try SyncInviteRig()
        let writes = rig.sync.base.data.writeCount
        let stage = try rig.invites.stage(rig.link.text)
        XCTAssertEqual(stage.destination.serverURL, rig.link.server.baseURL)
        XCTAssertFalse(stage.destination.canJoin)
        XCTAssertTrue(rig.sync.transport.requests.isEmpty)
        XCTAssertTrue(rig.clipboard.writes.isEmpty)
        XCTAssertEqual(rig.sync.base.data.writeCount, writes)
        assertSyncPresentationRedacted(stage, secrets: [rig.inviteToken, rig.link.text])
    }

    func testExistingAccountJoinRefreshesMeAndTriggersPull() async throws {
        let rig = try SyncInviteRig()
        try await rig.login()
        let staged = try rig.invites.stage(rig.link.text)
        XCTAssertTrue(staged.destination.canJoin)
        let requestsBefore = rig.sync.transport.requests.count
        var password = "unused"
        let result = try await rig.invites.accept(staged, as: .existingAccount, username: "", password: &password, deviceName: "")
        await rig.sync.settle()
        XCTAssertTrue(password.isEmpty, "Password input was not consumed")
        XCTAssertNil(result.issue)
        XCTAssertEqual(result.snapshot.me?.groups.count, 1)
        let paths = rig.sync.transport.requests.dropFirst(requestsBefore).map { $0.url.path }
        XCTAssertEqual(paths.first, "/paw/api/v1/groups/join")
        XCTAssertEqual(paths.dropFirst().first, "/paw/api/v1/me")
        XCTAssertTrue(paths.contains("/paw/api/v1/sync/pull"))
        try rig.assertNoInvitePersistence()
    }

    func testCrossServerJoinNeverSendsExistingCredentialOrReadsSecret() async throws {
        let rig = try SyncInviteRig()
        try await rig.login()
        let staged = try rig.invites.stage(rig.inviteToken, server: "https://other.test/paw")
        XCTAssertFalse(staged.destination.canJoin)
        let requestsBefore = rig.sync.transport.requests.count
        let reads = rig.secrets.reads.count
        var password = "unused"
        await assertIssue(.wrongServer) {
            try await rig.invites.accept(staged, as: .existingAccount, username: "", password: &password, deviceName: "")
        }
        XCTAssertEqual(rig.sync.transport.requests.count, requestsBefore)
        XCTAssertEqual(rig.secrets.reads.count, reads)
        XCTAssertTrue(password.isEmpty, "Password input was not consumed")
    }

    func testChangedUserOrSameUserReauthenticationInvalidatesStagedInvite() async throws {
        for changeUser in [false, true] {
            let rig = try SyncInviteRig()
            try await rig.login()
            let staged = try rig.invites.stage(rig.link.text)
            if changeUser { rig.userID = SyncTestValues.otherUser }
            try await rig.login()
            let requestsBefore = rig.sync.transport.requests.count
            var password = ""
            await assertIssue(.accountChanged) {
                try await rig.invites.accept(staged, as: .existingAccount, username: "", password: &password, deviceName: "")
            }
            XCTAssertEqual(rig.sync.transport.requests.count, requestsBefore)
        }
    }

    func testSignOutInvalidatesStagingAndRegistrationExpectation() async throws {
        let rig = try SyncInviteRig()
        try await rig.login()
        let staged = try rig.invites.stage(rig.link.text)
        _ = try await rig.account.signOut()
        let requestsBefore = rig.sync.transport.requests.count
        for mode in [InviteAcceptance.existingAccount, .newAccount] {
            var password = rig.password
            await assertIssue(.accountChanged) {
                try await rig.invites.accept(staged, as: mode, username: "person", password: &password, deviceName: "Desktop")
            }
            XCTAssertTrue(password.isEmpty, "Password input was not consumed")
        }
        XCTAssertEqual(rig.sync.transport.requests.count, requestsBefore)
    }

    func testRegistrationOnAnotherServerUsesNoExistingBearerAndBindsNewToken() async throws {
        let rig = try SyncInviteRig()
        try await rig.login()
        let staged = try rig.invites.stage(rig.inviteToken, server: "https://other.test/paw")
        rig.userID = SyncTestValues.otherUser
        rig.deviceToken = String(repeating: "c", count: 42) + "A"
        let requestsBefore = rig.sync.transport.requests.count
        var password = rig.password
        let result = try await rig.invites.accept(staged, as: .newAccount, username: "person", password: &password, deviceName: "Desktop")
        await rig.sync.settle()
        XCTAssertTrue(password.isEmpty, "Password input was not consumed")
        XCTAssertTrue(result.snapshot.enabled)
        XCTAssertEqual(result.snapshot.account?.identity.serverURL.host, "other.test")
        XCTAssertEqual(result.snapshot.account?.identity.userID, SyncTestValues.otherUser)
        let registration = try XCTUnwrap(rig.sync.transport.requests.dropFirst(requestsBefore).first)
        XCTAssertTrue(registration.url.path.hasSuffix("/register"))
        XCTAssertNil(registration.headers["Authorization"])
        for request in rig.sync.transport.requests.dropFirst(requestsBefore) where request.url.host == "other.test" {
            XCTAssertFalse(request.headers.values.contains { $0.contains(String(repeating: "b", count: 42)) })
        }
        try rig.assertNoInvitePersistence()
    }

    func testCreationShowsOnceWithoutAutomaticClipboardAndCopyUsesService() async throws {
        let rig = try SyncInviteRig()
        try await rig.login()
        let result = try await rig.invites.create(groupID: SyncTestValues.group, role: .viewer)
        XCTAssertTrue(rig.clipboard.writes.isEmpty)
        XCTAssertTrue(try SyncInviteLink(result.link).server == rig.link.server)
        XCTAssertEqual(result.target, .group(groupID: SyncTestValues.group.rawValue, role: .viewer))
        try rig.invites.copy(result)
        XCTAssertEqual(rig.clipboard.writes.count, 1)
        XCTAssertTrue(rig.clipboard.writes[0] == result.link)
        try rig.assertNoInvitePersistence()
        assertSyncPresentationRedacted(result, secrets: [rig.inviteToken, result.link])
        assertSyncPresentationRedacted(rig.invites, secrets: [rig.inviteToken, result.link])
    }

    func testStaleCreationCannotCopyAfterAccountChange() async throws {
        let rig = try SyncInviteRig()
        try await rig.login()
        let result = try await rig.invites.create(groupID: SyncTestValues.group, role: .editor)
        _ = try await rig.account.signOut()
        XCTAssertThrowsError(try rig.invites.copy(result)) { XCTAssertTrue($0 as? InviteIssue == .accountChanged) }
        XCTAssertTrue(rig.clipboard.writes.isEmpty)
    }

    func testConsumedExpiredAndUnknownAreGenericAndUnauthorizedStopsSync() async throws {
        for error in [SyncAPI.FailureCode.malformedRequest, .unauthorized] {
            let rig = try SyncInviteRig()
            try await rig.login()
            let normal = rig.sync.transport.handler
            rig.sync.transport.handler = { index, request in
                if request.url.path.hasSuffix("/groups/join") { return try SyncServiceRig.failure(error) }
                return try await normal(index, request)
            }
            let staged = try rig.invites.stage(rig.link.text)
            var password = ""
            await assertIssue(error == .unauthorized ? .account(.needsSignIn) : .unavailableInvite) {
                try await rig.invites.accept(staged, as: .existingAccount, username: "", password: &password, deviceName: "")
            }
            if error == .unauthorized { XCTAssertFalse(rig.account.snapshot.enabled); XCTAssertFalse(rig.sync.service.report.enabled) }
        }
    }

    func testMalformedRequestHasEndpointSpecificAcceptanceIssue() async throws {
        let cases: [(InviteAcceptance, InviteIssue, String)] = [
            (.existingAccount, .unavailableInvite, "/paw/api/v1/groups/join"),
            (.newAccount, .account(.invalidInput), "/paw/api/v1/auth/register")
        ]
        for (mode, expected, path) in cases {
            let rig = try SyncInviteRig()
            if case .existingAccount = mode { try await rig.login() }
            let staged = try rig.invites.stage(rig.link.text)
            let previous = rig.account.snapshot
            let requestsBefore = rig.sync.transport.requests.count
            let normal = rig.sync.transport.handler
            rig.sync.transport.handler = { index, request in
                if request.url.path == path { return try SyncServiceRig.failure(.malformedRequest) }
                return try await normal(index, request)
            }
            var password = rig.password
            do {
                _ = try await rig.invites.accept(staged, as: mode, username: "person", password: &password, deviceName: "Desktop")
                XCTFail("Expected acceptance refusal for \(mode)")
            } catch {
                XCTAssertEqual(error as? InviteIssue, expected, "Unexpected issue for \(mode)")
            }
            XCTAssertTrue(password.isEmpty, "Password input was not consumed")
            XCTAssertEqual(rig.sync.transport.requests.dropFirst(requestsBefore).map { $0.url.path }, [path])
            XCTAssertEqual(rig.account.snapshot.account, previous.account)
            XCTAssertEqual(rig.account.snapshot.enabled, previous.enabled)
            try rig.assertNoInvitePersistence()
        }
    }

    func testCreationMalformedRequestPreservesAccountIssue() async throws {
        let rig = try SyncInviteRig()
        try await rig.login()
        let normal = rig.sync.transport.handler
        rig.sync.transport.handler = { index, request in
            if request.url.path.hasSuffix("/invites") { return try SyncServiceRig.failure(.malformedRequest) }
            return try await normal(index, request)
        }
        await assertIssue(.account(.invalidInput)) {
            try await rig.invites.create(groupID: SyncTestValues.group, role: .viewer)
        }
        XCTAssertTrue(rig.clipboard.writes.isEmpty)
        try rig.assertNoInvitePersistence()
    }

    func testRefreshFailureReportsAcceptedAndClearsStaleMemberships() async throws {
        let rig = try SyncInviteRig()
        try await rig.login()
        rig.failJoinedMe = true
        let staged = try rig.invites.stage(rig.link.text)
        var password = ""
        let result = try await rig.invites.accept(staged, as: .existingAccount, username: "", password: &password, deviceName: "")
        await rig.sync.settle()
        XCTAssertEqual(result.issue, .refreshIncomplete(.offline))
        XCTAssertNil(result.snapshot.me)
        XCTAssertEqual(rig.joinCalls, 1)
    }

    func testRegistrationLocalFailureReportsConsumedAndCompensatesDevice() async throws {
        let rig = try SyncInviteRig()
        rig.secrets.writeError = SecretStoreError.writeFailed
        let staged = try rig.invites.stage(rig.link.text)
        var password = rig.password
        let result = try await rig.invites.accept(staged, as: .newAccount, username: "person", password: &password, deviceName: "Desktop")
        XCTAssertTrue(password.isEmpty, "Password input was not consumed")
        XCTAssertEqual(result.issue, .registrationIncomplete(.secret(.writeFailed)))
        XCTAssertEqual(result.cleanup.remote, .revoked)
        XCTAssertFalse(result.snapshot.enabled)
        XCTAssertEqual(rig.registerCalls, 1)
        XCTAssertTrue(rig.secrets.persisted.isEmpty)
        try rig.assertNoInvitePersistence()
    }

    private func assertIssue<T>(_ expected: InviteIssue, _ work: () async throws -> T) async {
        do { _ = try await work(); XCTFail("Expected invite refusal") }
        catch { XCTAssertTrue(error as? InviteIssue == expected, "Unexpected invite issue") }
    }
}

final class InviteTestClipboard: Clipboard {
    var writes: [String] = []
    func writeText(_ text: String) { writes.append(text) }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { completion(writes.last) }
}

final class SyncInviteRig {
    let sync: SyncServiceRig
    let secrets = FakeProviderSecrets()
    let clipboard = InviteTestClipboard()
    let account: SyncAccountService
    let invites: SyncInviteService
    let inviteToken = String(repeating: "a", count: 42) + "A"
    var deviceToken = String(repeating: "b", count: 42) + "A"
    let password = "Runtime-password-" + UUID().uuidString
    var userID = SyncTestValues.user
    var joined = false
    var failJoinedMe = false
    var joinCalls = 0
    var registerCalls = 0
    var link: SyncInviteLink { try! SyncInviteLink(inviteToken, server: "https://example.test/paw") }

    init() throws {
        sync = try SyncServiceRig()
        account = SyncAccountService(sync: sync.service, accounts: sync.accounts, secrets: secrets, transport: sync.transport,
            root: sync.base.binding.root, connectionID: UUID.init)
        invites = SyncInviteService(account: account, clipboard: clipboard)
        sync.transport.handler = { [weak self] _, request in
            guard let self else { throw HTTPTransportError.networkFailure }
            let user = SyncAPI.User(id: self.userID.rawValue, username: "person", displayName: nil,
                accountKind: .member, createdAt: "2026-10-14T00:00:00.000Z", disabledAt: nil)
            let group = SyncAPI.GroupMembership(groupID: SyncTestValues.group.rawValue, name: "Team", role: .viewer)
            switch request.url.path {
            case let path where path.hasSuffix("/login") || path.hasSuffix("/register"):
                if path.hasSuffix("/register") { self.registerCalls += 1 }
                return try SyncServiceRig.http(SyncAPI.AuthResponse(deviceToken: self.deviceToken, user: user))
            case let path where path.hasSuffix("/me"):
                if self.joined && self.failJoinedMe { throw HTTPTransportError.networkFailure }
                return try SyncServiceRig.http(SyncAPI.MeResponse(user: user, groups: self.joined ? [group] : [],
                    devices: [AccountPresentationFake.device(SyncTestValues.device, current: true)]))
            case let path where path.hasSuffix("/groups/join"):
                self.joined = true; self.joinCalls += 1
                return try SyncServiceRig.http(group)
            case let path where path.hasSuffix("/invites"):
                let body = try JSONDecoder().decode(SyncAPI.GroupInviteRequest.self, from: XCTUnwrap(request.body))
                return try SyncServiceRig.http(SyncAPI.InviteResponse(inviteToken: self.inviteToken,
                    expiresAt: "2026-10-21T00:00:00.000Z", target: .group(groupID: SyncTestValues.group.rawValue, role: body.role)))
            case let path where path.hasSuffix("/sync/pull"):
                return try SyncServiceRig.http(SyncAPI.PullResponse(databaseID: SyncTestValues.uuid.uuidString.lowercased(),
                    scopes: [.init(identity: .user(userID: self.userID.rawValue), mode: .snapshot, head: 0, cursor: "user",
                        hasMore: false, items: [])] + (self.joined ? [.init(identity: .group(groupID: SyncTestValues.group.rawValue,
                            name: "Team", role: .viewer), mode: .snapshot, head: 0, cursor: "group", hasMore: false, items: [])] : []), removed: []))
            default: return try SyncServiceRig.http(SyncAPI.EmptyResponse())
            }
        }
    }

    func login() async throws {
        var password = password
        _ = try await account.login(server: link.server.baseURL.absoluteString, username: "person", password: &password, deviceName: "Desktop")
        await sync.settle()
    }

    func assertNoInvitePersistence(file: StaticString = #filePath, line: UInt = #line) throws {
        for entry in try sync.base.data.listFiles() {
            // Background sync may delete a transient pull page between listing and reading.
            let bytes: Data
            do { bytes = try sync.base.data.read(at: entry.relativePath) }
            catch FileStoreError.notFound { continue }
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(text.contains(inviteToken) || text.contains(link.text) || text.contains(password), "Invite or password persisted", file: file, line: line)
        }
        for secret in secrets.persisted.values {
            XCTAssertFalse(secret.value.withValue { $0.contains(inviteToken) || $0.contains(link.text) }, "Invite persisted in SecretStore", file: file, line: line)
        }
    }
}
