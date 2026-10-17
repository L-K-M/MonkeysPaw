import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncGroupServiceTests: XCTestCase {
    func testCreateRefreshesMeMembersAndPullUsingCatalogRequests() async throws {
        let rig = try SyncGroupTestRig()
        try await rig.base.login()
        let before = rig.requests.count
        let result = await rig.execute(.create("Team"))
        await rig.base.sync.settle()
        XCTAssertTrue(result.changeConfirmed)
        XCTAssertNil(result.issue)
        XCTAssertEqual(result.selectedGroupID, SyncTestValues.group)
        XCTAssertEqual(result.snapshot.me?.groups.first?.role, .owner)
        XCTAssertEqual(result.members.first?.userID, SyncTestValues.user.rawValue)
        let requests = Array(rig.requests.dropFirst(before))
        XCTAssertEqual(requests.prefix(3).map(\.url.path), ["/paw/api/v1/groups", "/paw/api/v1/me", "/paw/api/v1/groups/" + SyncTestValues.group.rawValue + "/members"])
        XCTAssertEqual(requests.first?.method, .post)
        XCTAssertTrue(requests.contains { $0.url.path.hasSuffix("/sync/pull") })
        let body = try JSONDecoder().decode(SyncAPI.CreateGroupRequest.self, from: XCTUnwrap(requests.first?.body))
        XCTAssertEqual(body.name, "Team")
        XCTAssertEqual(rig.base.sync.base.states.snapshot.value?.groups[SyncTestValues.group]?.role, .owner)
    }

    func testRenameSetRoleRemoveAndDeleteReloadAuthoritativeMetadata() async throws {
        let rig = try SyncGroupTestRig()
        try await rig.base.login()
        _ = await rig.execute(.create("Team"))
        await rig.base.sync.settle()
        let renamed = await rig.execute(.rename(SyncTestValues.group, "Renamed"))
        XCTAssertEqual(renamed.snapshot.me?.groups.first?.name, "Renamed")
        let promoted = await rig.execute(.setRole(SyncTestValues.group, SyncTestValues.otherUser, .owner))
        XCTAssertEqual(promoted.members.first { $0.userID == SyncTestValues.otherUser.rawValue }?.role, .owner)
        let removed = await rig.execute(.removeMember(SyncTestValues.group, SyncTestValues.otherUser))
        XCTAssertEqual(removed.members.count, 1)
        let deleted = await rig.execute(.delete(SyncTestValues.group))
        await rig.base.sync.settle()
        XCTAssertTrue(deleted.changeConfirmed)
        XCTAssertNil(deleted.selectedGroupID)
        XCTAssertTrue(deleted.snapshot.me?.groups.isEmpty == true)
        XCTAssertNil(rig.base.sync.base.states.snapshot.value?.groups[SyncTestValues.group])
    }

    func testForbiddenIsVisibleWithoutOptimisticChangeOrRetry() async throws {
        let rig = try SyncGroupTestRig()
        try await rig.base.login()
        _ = await rig.execute(.create("Team"))
        await rig.base.sync.settle()
        rig.failure = .forbidden
        let before = rig.requests.count
        let denied = await rig.execute(.setRole(SyncTestValues.group, SyncTestValues.user, .viewer))
        await rig.base.sync.settle()
        XCTAssertEqual(denied.issue, .forbidden)
        XCTAssertFalse(denied.changeConfirmed)
        XCTAssertEqual(denied.members.first?.role, .owner)
        XCTAssertEqual(denied.snapshot.me?.groups.first?.role, .owner)
        let requests = rig.requests.dropFirst(before)
        XCTAssertEqual(requests.filter { $0.method == .put }.count, 1)
        XCTAssertTrue(requests.contains { $0.url.path.hasSuffix("/me") })
        XCTAssertTrue(requests.contains { $0.url.path.hasSuffix("/sync/pull") })
    }

    func testConfirmedChangeAndFailedRefreshAreDistinctAndFailClosed() async throws {
        let rig = try SyncGroupTestRig()
        try await rig.base.login()
        rig.failMe = true
        let result = await rig.execute(.create("Team"))
        await rig.base.sync.settle()
        XCTAssertTrue(result.changeConfirmed)
        XCTAssertEqual(result.issue, .refreshIncomplete(.offline))
        XCTAssertNil(result.snapshot.me)
        XCTAssertFalse(result.state.canCreate)
        XCTAssertFalse(result.state.canManage)
        XCTAssertTrue(rig.requests.contains { $0.url.path.hasSuffix("/sync/pull") })
        rig.failMe = false
        let refreshed = await rig.execute(.refresh(nil))
        XCTAssertNil(refreshed.issue)
        XCTAssertEqual(refreshed.snapshot.me?.groups.count, 1)
        XCTAssertFalse(refreshed.changeConfirmed)
    }

    func testMemberReloadFailureDoesNotClaimMutationFailed() async throws {
        let rig = try SyncGroupTestRig()
        try await rig.base.login()
        rig.failMembers = true
        let result = await rig.execute(.create("Team"))
        XCTAssertTrue(result.changeConfirmed)
        XCTAssertEqual(result.issue, .membersUnavailable(.offline))
        XCTAssertTrue(result.members.isEmpty)
        XCTAssertEqual(result.snapshot.me?.groups.first?.role, .owner)
    }

    func testMemberRead404InvalidatesSelectionAfterMeRace() async throws {
        let rig = try SyncGroupTestRig()
        try await rig.base.login()
        _ = await rig.execute(.create("Team"))
        rig.memberFailure = .notFound
        let result = await rig.execute(.refresh(SyncTestValues.group))
        XCTAssertNil(result.selectedGroupID)
        XCTAssertNil(result.snapshot.me)
        XCTAssertTrue(result.members.isEmpty)
        XCTAssertFalse(result.state.canManage)
    }

    func testUnauthorizedRetiresCredentialAndAutomaticSync() async throws {
        let rig = try SyncGroupTestRig()
        try await rig.base.login()
        rig.failure = .unauthorized
        let result = await rig.execute(.create("Team"))
        await rig.base.sync.settle()
        XCTAssertEqual(result.issue, .account(.needsSignIn))
        XCTAssertFalse(result.snapshot.enabled)
        XCTAssertNil(result.snapshot.me)
        XCTAssertTrue(rig.base.sync.service.report.needsSignIn)
        let before = rig.requests.count
        _ = await rig.execute(.create("Other"))
        XCTAssertEqual(rig.requests.count, before)
    }

    func testAccountGateRejectsSignOutAndChangedConnectionWithoutHTTP() async throws {
        let rig = try SyncGroupTestRig()
        try await rig.base.login()
        let expected = try XCTUnwrap(rig.base.account.snapshot.account)
        let gate = SyncTransportGate()
        rig.mutationGate = gate
        let task = Task { await rig.service.execute(.create("Team"), expectedAccount: expected) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !rig.base.account.isBusy && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(rig.base.account.isBusy)
        do { _ = try await rig.base.account.signOut(); XCTFail("Sign-out overlapped group work") }
        catch { XCTAssertEqual((error as? SyncAccountServiceError)?.issue, .busy) }
        await gate.open()
        _ = await task.value
        await rig.base.sync.settle()
        rig.mutationGate = nil
        try await rig.base.login()
        let before = rig.requests.count
        let result = await rig.service.execute(.delete(SyncTestValues.group), expectedAccount: expected)
        XCTAssertEqual(result.issue, .accountChanged)
        XCTAssertEqual(rig.requests.count, before)
    }

    func testInvitesReuseBoundLinkCopyAndRedaction() async throws {
        let rig = try SyncGroupTestRig()
        try await rig.base.login()
        _ = await rig.execute(.create("Team"))
        let result = await rig.execute(.createInvite(SyncTestValues.group, .editor))
        let created = try XCTUnwrap(result.createdInvite)
        XCTAssertTrue(result.changeConfirmed)
        XCTAssertNil(result.issue)
        XCTAssertTrue(rig.base.clipboard.writes.isEmpty)
        try rig.service.copy(created)
        XCTAssertEqual(rig.base.clipboard.writes.count, 1)
        XCTAssertTrue(try SyncInviteLink(created.link).server == rig.base.link.server)
        try rig.base.assertNoInvitePersistence()
        assertSyncPresentationRedacted(rig.service, secrets: [rig.base.inviteToken, created.link])
        assertSyncPresentationRedacted(result.state, secrets: [rig.base.inviteToken, created.link])
        _ = try await rig.base.account.signOut()
        XCTAssertThrowsError(try rig.service.copy(created))
        XCTAssertEqual(rig.base.clipboard.writes.count, 1)
    }
}

/// Only HTTP-contract unit proof. Server authorization is exercised separately
/// through Y12's real router and SQLite, never through this fake.
final class SyncGroupTestRig {
    let base: SyncInviteRig
    let service: SyncGroupService
    private let lock = NSLock()
    private var name: String?
    private var members = [SyncAPI.Member(userID: SyncTestValues.user.rawValue, username: "person", displayName: nil,
        role: .owner, joinedAt: "2026-10-14T00:00:00.000Z")]
    private var _failure: SyncAPI.FailureCode?
    private var _memberFailure: SyncAPI.FailureCode?
    private var _failMe = false, _failMembers = false
    private var _mutationGate: SyncTransportGate?
    var failure: SyncAPI.FailureCode? {
        get { locked { _failure } }
        set { locked { _failure = newValue } }
    }
    var memberFailure: SyncAPI.FailureCode? {
        get { locked { _memberFailure } }
        set { locked { _memberFailure = newValue } }
    }
    var failMe: Bool {
        get { locked { _failMe } }
        set { locked { _failMe = newValue } }
    }
    var failMembers: Bool {
        get { locked { _failMembers } }
        set { locked { _failMembers = newValue } }
    }
    var mutationGate: SyncTransportGate? {
        get { locked { _mutationGate } }
        set { locked { _mutationGate = newValue } }
    }
    var requests: [HTTPRequest] { base.sync.transport.requests }

    init() throws {
        base = try SyncInviteRig()
        service = SyncGroupService(account: base.account, clipboard: base.clipboard)
        let original = base.sync.transport.handler
        base.sync.transport.handler = { [weak self] index, request in
            guard let self else { throw HTTPTransportError.networkFailure }
            let groupPath = "/paw/api/v1/groups/" + SyncTestValues.group.rawValue
            if request.url.path.hasPrefix("/paw/api/v1/groups"), request.method != .get {
                if let gate = self.mutationGate { await gate.wait() }
                if let failure = self.failure {
                    return try HTTPResponse(statusCode: failure == .unauthorized ? 401 : 403,
                        body: JSONEncoder().encode(SyncAPI.ErrorResponse.failure(failure)))
                }
            }
            if request.url.path.hasSuffix("/me") {
                if self.failMe { throw HTTPTransportError.networkFailure }
                let response = try await original(index, request)
                let me = try JSONDecoder().decode(SyncAPI.MeResponse.self, from: response.body)
                return try SyncServiceRig.http(SyncAPI.MeResponse(user: me.user, groups: self.groups, devices: me.devices))
            }
            if request.url.path.hasSuffix("/sync/pull") {
                let body = try JSONDecoder().decode(SyncAPI.PullRequest.self, from: XCTUnwrap(request.body))
                let groups = self.groups
                return try SyncServiceRig.http(SyncAPI.PullResponse(databaseID: SyncTestValues.uuid.uuidString.lowercased(),
                    scopes: [.init(identity: .user(userID: SyncTestValues.user.rawValue), mode: .snapshot, head: 0,
                        cursor: "user", hasMore: false, items: [])] + groups.map { group in
                        .init(identity: .group(groupID: group.groupID, name: group.name, role: group.role), mode: .snapshot,
                            head: 0, cursor: "group", hasMore: false, items: [])
                    }, removed: groups.isEmpty && body.cursors["group:" + SyncTestValues.group.rawValue] != nil
                        ? ["group:" + SyncTestValues.group.rawValue] : []))
            }
            if request.url.path == groupPath + "/members" {
                if self.failMembers { throw HTTPTransportError.networkFailure }
                if let failure = self.memberFailure {
                    return try HTTPResponse(statusCode: 404, body: JSONEncoder().encode(SyncAPI.ErrorResponse.failure(failure)))
                }
                return try SyncServiceRig.http(SyncAPI.MembersResponse(members: self.locked { self.members }))
            }
            if request.url.path.hasPrefix(groupPath + "/members/") {
                let id = request.url.lastPathComponent
                if request.method == .delete {
                    self.locked { self.members.removeAll { $0.userID == id } }
                    return try SyncServiceRig.http(SyncAPI.EmptyResponse())
                }
                let role = try JSONDecoder().decode(SyncAPI.MembershipRequest.self, from: XCTUnwrap(request.body)).role
                let member = SyncAPI.Member(userID: id, username: "other", displayName: nil, role: role, joinedAt: "2026-10-14T00:00:00.000Z")
                self.locked { self.members.removeAll { $0.userID == id }; self.members.append(member) }
                return try SyncServiceRig.http(member)
            }
            if request.url.path == "/paw/api/v1/groups" || request.url.path == groupPath {
                if request.method == .delete {
                    self.locked { self.name = nil }
                    return try SyncServiceRig.http(SyncAPI.EmptyResponse())
                }
                let name = try JSONDecoder().decode(SyncAPI.CreateGroupRequest.self, from: XCTUnwrap(request.body)).name
                self.locked { self.name = name }
                return try SyncServiceRig.http(SyncAPI.Group(id: SyncTestValues.group.rawValue, name: name,
                    createdBy: SyncTestValues.user.rawValue, createdAt: "2026-10-14T00:00:00.000Z"))
            }
            return try await original(index, request)
        }
    }

    func execute(_ command: SyncGroupCommand) async -> SyncGroupResult {
        await service.execute(command, expectedAccount: base.account.snapshot.account)
    }

    private var groups: [SyncAPI.GroupMembership] {
        locked { name.map { [.init(groupID: SyncTestValues.group.rawValue, name: $0,
            role: members.first { $0.userID == SyncTestValues.user.rawValue }?.role ?? .viewer)] } ?? [] }
    }
    private func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
}
