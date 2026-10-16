import Foundation
import XCTest
@testable import MonkeysPawCore

final class GroupManagementModelTests: XCTestCase {
    func testOpeningReadsCachedAccountOffUIWithoutNetwork() async throws {
        let (model, fake, main) = try makeModel()
        await settle(model, main)
        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertTrue(model.state.canCreate)
        XCTAssertFalse(model.state.canManage)
        XCTAssertEqual(model.state.groups.count, 1)
        model.selectGroup(SyncTestValues.group)
        await settle(model, main)
        XCTAssertEqual(fake.calls, [.refresh(SyncTestValues.group)])
        XCTAssertEqual(model.state.members.count, 2)
        XCTAssertTrue(model.state.canManage)
    }

    func testOwnersManageWhileEditorAndViewerListsAreReadOnly() async throws {
        for role in SyncAPI.Role.allCases {
            let (model, fake, main) = try makeModel(role: role)
            await settle(model, main)
            model.selectGroup(SyncTestValues.group)
            await settle(model, main)
            XCTAssertEqual(model.state.members.count, 2)
            XCTAssertEqual(model.state.canManage, role == .owner)
            XCTAssertTrue(model.state.canCreate)
            if role != .owner {
                model.rename(name: "Denied")
                model.deleteGroup()
                model.setRole(userID: SyncTestValues.otherUser.rawValue, role: .owner)
                model.removeMember(userID: SyncTestValues.otherUser.rawValue)
                model.createInvite(role: .editor)
                main.flush()
                XCTAssertEqual(fake.calls.count, 1)
                XCTAssertEqual(model.state.error, .forbidden)
            }
        }
    }

    func testCreateRenameAddByIDSetRoleRemoveAndDeleteIntents() async throws {
        let (model, fake, main) = try makeModel()
        await settle(model, main)
        model.create(name: "New team")
        await settle(model, main)
        model.rename(name: "Renamed")
        await settle(model, main)
        model.setRole(userID: SyncTestValues.otherUser.rawValue, role: .owner)
        await settle(model, main)
        model.removeMember(userID: SyncTestValues.otherUser.rawValue)
        await settle(model, main)
        model.deleteGroup()
        await settle(model, main)
        XCTAssertEqual(fake.calls, [.create("New team"), .rename(SyncTestValues.group, "Renamed"),
            .setRole(SyncTestValues.group, SyncTestValues.otherUser, .owner),
            .removeMember(SyncTestValues.group, SyncTestValues.otherUser), .delete(SyncTestValues.group)])
        XCTAssertTrue(model.state.changeConfirmed)
        XCTAssertNil(model.state.selectedGroupID)
        XCTAssertTrue(model.state.groups.isEmpty)
    }

    func testInputAndSelectionValidationDoesNotReachService() async throws {
        let (model, fake, main) = try makeModel()
        await settle(model, main)
        model.create(name: "")
        main.flush()
        XCTAssertEqual(model.state.error, .invalidName)
        model.create(name: String(repeating: "a", count: 256))
        main.flush()
        XCTAssertEqual(model.state.error, .invalidName)
        model.selectGroup(SyncTestValues.otherUser)
        main.flush()
        XCTAssertEqual(model.state.error, .invalidSelection)
        XCTAssertTrue(fake.calls.isEmpty)
        model.selectGroup(SyncTestValues.group)
        await settle(model, main)
        model.setRole(userID: "not-an-id", role: .viewer)
        main.flush()
        XCTAssertEqual(model.state.error, .invalidUserID)
        model.removeMember(userID: SyncTestValues.personalPrompt.rawValue)
        main.flush()
        XCTAssertEqual(model.state.error, .invalidUserID)
        XCTAssertEqual(fake.calls.count, 1)
    }

    func testAdminControlsPreventSelfAddAndElevationButAllowIdempotentRole() async throws {
        let (model, fake, main) = try makeModel(role: .viewer, kind: .admin)
        await settle(model, main)
        model.selectGroup(SyncTestValues.group)
        await settle(model, main)
        XCTAssertTrue(model.state.canManage)
        XCTAssertFalse(model.state.canSetRole(userID: SyncTestValues.user.rawValue, role: .owner))
        model.setRole(userID: SyncTestValues.user.rawValue, role: .editor)
        main.flush()
        XCTAssertEqual(model.state.error, .forbidden)
        XCTAssertEqual(fake.calls.count, 1)
        model.setRole(userID: SyncTestValues.user.rawValue, role: .viewer)
        await settle(model, main)
        XCTAssertTrue(model.state.changeConfirmed)
        XCTAssertTrue(model.state.canSetRole(userID: SyncTestValues.otherUser.rawValue, role: .owner))
        fake.memberList = fake.memberList.filter { $0.userID != SyncTestValues.user.rawValue }
        model.refresh()
        await settle(model, main)
        XCTAssertFalse(model.state.canSetRole(userID: SyncTestValues.user.rawValue, role: .viewer))
    }

    func testLastOwnerRejectionRemainsVisibleAndPreservesMemberList() async throws {
        let (model, fake, main) = try makeModel()
        await settle(model, main)
        model.selectGroup(SyncTestValues.group)
        await settle(model, main)
        let members = model.state.members
        fake.issue = .forbidden
        model.removeMember(userID: SyncTestValues.user.rawValue)
        main.flush()
        XCTAssertEqual(model.state.members, members)
        await model.drain()
        main.flush()
        XCTAssertEqual(model.state.error, .forbidden)
        XCTAssertFalse(model.state.changeConfirmed)
        XCTAssertEqual(model.state.members, members)
        XCTAssertTrue(model.state.canManage)
        XCTAssertTrue(model.state.error?.message.contains("keep an owner") == true)
    }

    func testRoleDowngradeAndRemovalResetNativeDraftsAndInviteAccess() async throws {
        let (model, fake, main) = try makeModel()
        await settle(model, main)
        model.selectGroup(SyncTestValues.group)
        await settle(model, main)
        model.createInvite(role: .viewer)
        await settle(model, main)
        XCTAssertNotNil(model.state.createdInvite)
        let reset = model.state.inputReset
        fake.role = .viewer
        model.refresh()
        await settle(model, main)
        XCTAssertFalse(model.state.canManage)
        XCTAssertFalse(model.state.canCopyInvite)
        XCTAssertNil(model.state.createdInvite)
        XCTAssertNotEqual(model.state.inputReset, reset)
        let downgraded = model.state.inputReset
        fake.hasGroup = false
        model.refresh()
        await settle(model, main)
        XCTAssertNil(model.state.selectedGroupID)
        XCTAssertTrue(model.state.members.isEmpty)
        XCTAssertNotEqual(model.state.inputReset, downgraded)
    }

    func testRefreshFailureDistinguishesCommittedChangeAndDisablesControls() async throws {
        let (model, fake, main) = try makeModel()
        await settle(model, main)
        fake.issue = .refreshIncomplete(.offline)
        fake.confirmed = true
        fake.metadataAvailable = false
        model.create(name: "Team")
        await settle(model, main)
        XCTAssertEqual(model.state.error, .refreshIncomplete(.offline))
        XCTAssertTrue(model.state.changeConfirmed)
        XCTAssertFalse(model.state.canCreate)
        XCTAssertFalse(model.state.canManage)
        XCTAssertTrue(model.state.groups.isEmpty)
    }

    func testStaleAccountCannotSendMutationAndRefreshAdoptsCurrentConnection() async throws {
        let (model, fake, main) = try makeModel()
        await settle(model, main)
        let oldReset = model.state.inputReset
        fake.account = try XCTUnwrap(AccountPresentationFake.signedIn(user: SyncTestValues.otherUser).account)
        model.create(name: "Old intent")
        await settle(model, main)
        XCTAssertEqual(model.state.error, .accountChanged)
        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertNotEqual(model.state.inputReset, oldReset)
        model.refresh()
        await settle(model, main)
        XCTAssertEqual(model.state.connection?.userID, SyncTestValues.otherUser)
    }

    func testBusyCommandsDoNotOverlapAndServiceWorkFinishesAfterRetirement() async throws {
        let (model, fake, main) = try makeModel()
        await settle(model, main)
        let gate = SyncTransportGate()
        fake.gate = gate
        model.create(name: "Team")
        main.flush()
        model.create(name: "Other")
        model.refresh()
        main.flush()
        XCTAssertTrue(model.state.isBusy)
        model.retire()
        await gate.open()
        await model.drain()
        main.flush()
        XCTAssertEqual(fake.calls, [.create("Team")])
        XCTAssertNil(model.state.connection)
        XCTAssertFalse(model.state.isBusy)
    }

    func testOneTimeInviteCopyDismissAndLateCloseUseUIBoundary() async throws {
        let (model, fake, main) = try makeModel()
        await settle(model, main)
        model.selectGroup(SyncTestValues.group)
        await settle(model, main)
        model.createInvite(role: .editor)
        await settle(model, main)
        XCTAssertNotNil(model.state.createdInvite)
        XCTAssertTrue(fake.clipboard.writes.isEmpty)
        assertSyncPresentationRedacted(model, secrets: [fake.token])
        assertSyncPresentationRedacted(model.state, secrets: [fake.token])
        model.copyCreatedInvite()
        main.flush()
        XCTAssertEqual(fake.clipboard.writes.count, 1)
        model.dismiss()
        main.flush()
        XCTAssertNil(model.state.createdInvite)
        let gate = SyncTransportGate()
        fake.gate = gate
        model.createInvite(role: .viewer)
        main.flush()
        model.dismiss()
        main.flush()
        XCTAssertTrue(model.state.isBusy)
        await gate.open()
        await settle(model, main)
        XCTAssertNil(model.state.createdInvite)
        XCTAssertFalse(model.state.isBusy)
        XCTAssertEqual(fake.clipboard.writes.count, 1)
    }

    func testReentrantCloseCannotRestoreInviteAtFirstPublication() async throws {
        let main = SyncPresentationMain()
        let fake = try GroupManagementFake(main: main)
        let model = GroupManagementModel(service: fake, mainThread: GroupReentrantMain(queue: main))
        await settle(model, main)
        model.selectGroup(SyncTestValues.group)
        await settle(model, main)
        var closed = false
        model.onChange = { [weak model] in
            guard !closed else { return }
            closed = true
            model?.dismiss()
        }
        model.createInvite(role: .viewer)
        await settle(model, main)
        XCTAssertTrue(closed)
        XCTAssertNil(model.state.createdInvite)
        XCTAssertFalse(model.state.isBusy)
    }

    func testRoleLossWhileInviteIsInFlightDropsLinkAndResetsDrafts() async throws {
        let (model, fake, main) = try makeModel()
        await settle(model, main)
        model.selectGroup(SyncTestValues.group)
        await settle(model, main)
        let previous = model.state.inputReset
        let gate = SyncTransportGate()
        fake.gate = gate
        model.createInvite(role: .viewer)
        main.flush()
        fake.role = .viewer
        await gate.open()
        await settle(model, main)
        XCTAssertFalse(model.state.canManage)
        XCTAssertNil(model.state.createdInvite, "Lost management access retained an in-flight invite")
        XCTAssertNotEqual(model.state.inputReset, previous)
    }

    func testIndependentObserverRemovalAndReplayedCompletionAreFenced() async throws {
        let (model, _, main) = try makeModel()
        await settle(model, main)
        var first = 0, second = 0, native = 0
        let id = model.addObserver { _ in XCTAssertTrue(main.isUI); first += 1 }
        model.addObserver { _ in XCTAssertTrue(main.isUI); second += 1 }
        model.onChange = { XCTAssertTrue(main.isUI); native += 1 }
        model.create(name: "Team")
        main.flush()
        model.removeObserver(id)
        await model.drain()
        let completions = main.flush()
        main.flush()
        XCTAssertEqual(first, 0)
        XCTAssertGreaterThan(second, 0)
        XCTAssertGreaterThan(native, 0)
        let completed = model.state
        main.replay(completions)
        XCTAssertEqual(model.state, completed)
        model.retire()
        main.replay(completions)
        main.flush()
        XCTAssertNil(model.state.createdInvite)
        XCTAssertNil(model.state.connection)
    }

    private func makeModel(role: SyncAPI.Role = .owner, kind: SyncAPI.AccountKind = .member) throws
        -> (GroupManagementModel, GroupManagementFake, SyncPresentationMain) {
        let main = SyncPresentationMain()
        let fake = try GroupManagementFake(main: main, role: role, kind: kind)
        return (GroupManagementModel(service: fake, mainThread: main), fake, main)
    }

    private func settle(_ model: GroupManagementModel, _ main: SyncPresentationMain) async {
        main.flush(); await model.drain(); main.flush(); main.flush()
    }
}

private struct GroupReentrantMain: MainThread {
    let queue: SyncPresentationMain
    func run(_ work: @escaping () -> Void) { if queue.isUI { work() } else { queue.run(work) } }
}

private final class GroupManagementFake: GroupManagementProviding {
    let main: SyncPresentationMain
    let clipboard = InviteTestClipboard()
    let token = String(repeating: "a", count: 42) + "A"
    private let lock = NSLock()
    private var recorded: [SyncGroupCommand] = []
    var account: SyncAccount
    var role: SyncAPI.Role
    let kind: SyncAPI.AccountKind
    var hasGroup = true, metadataAvailable = true
    var name = "Team"
    var memberList: [SyncAPI.Member]
    var issue: GroupManagementIssue?
    var confirmed = false
    var gate: SyncTransportGate?
    var calls: [SyncGroupCommand] { locked { recorded } }

    init(main: SyncPresentationMain, role: SyncAPI.Role = .owner, kind: SyncAPI.AccountKind = .member) throws {
        self.main = main; self.role = role; self.kind = kind
        account = try XCTUnwrap(AccountPresentationFake.signedIn().account)
        memberList = [SyncAPI.Member(userID: SyncTestValues.user.rawValue, username: "person", displayName: nil,
            role: role, joinedAt: "2026-10-14T00:00:00.000Z"),
            SyncAPI.Member(userID: SyncTestValues.otherUser.rawValue, username: "other", displayName: nil,
                role: .viewer, joinedAt: "2026-10-14T00:00:00.000Z")]
    }

    var snapshot: SyncAccountSnapshot {
        XCTAssertFalse(main.isUI)
        let user = SyncAPI.User(id: account.identity.userID.rawValue, username: "person", displayName: nil,
            accountKind: kind, createdAt: "2026-10-14T00:00:00.000Z", disabledAt: nil)
        return SyncAccountSnapshot(account: account, me: metadataAvailable ? SyncAPI.MeResponse(user: user,
            groups: hasGroup ? [.init(groupID: SyncTestValues.group.rawValue, name: name, role: role)] : [],
            devices: [AccountPresentationFake.device(SyncTestValues.device, current: true)]) : nil, enabled: true)
    }

    func execute(_ command: SyncGroupCommand, expectedAccount: SyncAccount?) async -> SyncGroupResult {
        XCTAssertFalse(main.isUI)
        if command.isMutation && expectedAccount != account {
            return SyncGroupResult(snapshot: snapshot, issue: .accountChanged)
        }
        locked { recorded.append(command) }
        if let gate { await gate.wait() }
        var selected = command.groupID
        var created: SyncInviteCreation?
        if issue == nil {
            switch command {
            case .create(let name): self.name = name; hasGroup = true; role = .owner; selected = SyncTestValues.group
            case .rename(_, let name): self.name = name
            case .delete: hasGroup = false; selected = nil
            case .setRole(_, let id, let role):
                memberList.removeAll { $0.userID == id.rawValue }
                memberList.append(.init(userID: id.rawValue, username: "other", displayName: nil,
                    role: role, joinedAt: "2026-10-14T00:00:00.000Z"))
            case .removeMember(_, let id): memberList.removeAll { $0.userID == id.rawValue }
            case .createInvite(let group, let role):
                created = SyncInviteCreation(link: try! SyncInviteLink(token, server: account.identity.serverURL.absoluteString).text,
                    expiresAt: "2026-10-21T00:00:00.000Z", target: .group(groupID: group.rawValue, role: role), account: account)
            case .refresh: break
            }
        }
        if !hasGroup || !metadataAvailable { selected = nil }
        return SyncGroupResult(snapshot: snapshot, selectedGroupID: selected,
            members: selected == nil ? [] : memberList, createdInvite: created,
            changeConfirmed: confirmed || (command.isMutation && issue == nil), issue: issue)
    }

    func copy(_ created: SyncInviteCreation) throws { XCTAssertTrue(main.isUI); clipboard.writeText(created.link) }
    private func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
}
