import AppKit
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

/// Exercises Settings' real public Core graph without Keychain, network or the owner's files.
final class MacGroupManagementTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var delegate: AppDelegate!
    private var http: MacGroupHTTP!
    private var clipboard: MacGroupClipboard!
    private var originalWindows: Set<ObjectIdentifier> = []
    private var terminationReplies: [Bool] = []

    override func setUpWithError() throws {
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library", isDirectory: true)
        http = MacGroupHTTP()
        clipboard = MacGroupClipboard()
        delegate = AppDelegate(libraryRoot: root, dataRoot: directory.appendingPathComponent("data"),
            httpTransport: http, secrets: MacGroupSecrets(), clipboard: clipboard,
            replyToTermination: { [weak self] in self?.terminationReplies.append($0) },
            setActivationPolicy: { _ in }, activateApplication: {}, makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in false }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, makeFileWatcher: { _, _ in MacGroupWatcher() })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    override func tearDown() {
        http.release()
        if delegate.applicationShouldTerminate(NSApp) == .terminateLater {
            XCTAssertTrue(spin { self.terminationReplies.last == true }, "The isolated graph did not drain")
        }
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        delegate = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testGroupSectionBindsLazilyWithoutHTTPOrClipboardOnSignedOutOpen() throws {
        let controller = try XCTUnwrap(delegate.settingsWindow)
        XCTAssertTrue(AppDelegate.isRunningTests)
        XCTAssertNil(controller.presentation.account.groups.state)
        delegate.showSettings()
        XCTAssertNil(controller.presentation.account.groups.state)
        let groups = try openAccount().groups
        XCTAssertEqual(groups.message, GroupManagementStrings.unavailable)
        XCTAssertFalse(groups.canCreate)
        XCTAssertFalse(groups.canManage)
        XCTAssertEqual(groups.state, delegate.groupManagementModel?.state)
        XCTAssertEqual(http.requestCount, 0)
        XCTAssertEqual(clipboard.writes, 0)
        XCTAssertEqual(clipboard.reads, 0)
    }

    func testOwnerCreatesManagesMembersRenamesAndDeletesWithConfirmation() throws {
        let account = try login()
        let groups = account.groups
        XCTAssertEqual(groups.message, GroupManagementStrings.noGroups)
        groups.createName = "Team"
        groups.create()
        waitIdle(account)
        XCTAssertEqual(groups.state?.selectedGroup?.role, .owner)
        XCTAssertEqual(groups.state?.selectedGroupID, MacGroupHTTP.group)
        XCTAssertTrue(groups.canManage)
        XCTAssertTrue(groups.state?.changeConfirmed == true)
        let selected = try XCTUnwrap(groups.state?.selectedGroup)
        XCTAssertTrue(GroupManagementStrings.groupID(selected).contains(MacGroupHTTP.group.rawValue))

        groups.userID = MacGroupHTTP.other.rawValue
        groups.memberRole = .editor
        groups.setRole(userID: groups.userID, role: groups.memberRole)
        waitIdle(account)
        let added = try XCTUnwrap(groups.state?.members.first { $0.userID == MacGroupHTTP.other.rawValue })
        XCTAssertEqual(added.role, .editor)
        XCTAssertTrue(GroupManagementStrings.member(added).contains("@colleague"))
        XCTAssertTrue(GroupManagementStrings.member(added).contains(added.userID))
        groups.setDraftRole(.owner, for: added)
        groups.setRole(userID: added.userID, role: groups.role(for: added))
        waitIdle(account)
        XCTAssertEqual(groups.state?.members.first { $0.userID == added.userID }?.role, .owner)
        groups.removeMember(added)
        waitIdle(account)
        XCTAssertFalse(groups.state?.members.contains { $0.userID == added.userID } == true)

        groups.name = "Renamed"
        let before = http.groupMutationCount
        groups.requestRename()
        XCTAssertNotNil(groups.confirmation)
        XCTAssertEqual(http.groupMutationCount, before)
        groups.cancelConfirmation()
        groups.confirm()
        XCTAssertEqual(http.groupMutationCount, before)
        groups.requestRename()
        groups.confirm()
        waitIdle(account)
        XCTAssertEqual(groups.state?.selectedGroup?.name, "Renamed")
        groups.requestDelete()
        groups.cancelConfirmation()
        groups.confirm()
        XCTAssertEqual(groups.state?.groups.count, 1)
        groups.requestDelete()
        groups.confirm()
        waitIdle(account)
        XCTAssertTrue(groups.state?.groups.isEmpty == true)
        XCTAssertNil(groups.state?.selectedGroup)
        XCTAssertTrue(groups.state?.changeConfirmed == true)
        XCTAssertTrue(http.allWorkOffMain)
    }

    func testEditorsAndViewersHaveReadOnlyMembersAndCanCreateTheirOwnGroup() throws {
        let account = try login(role: .editor)
        let groups = account.groups
        for role in [SyncAPI.Role.editor, .viewer] {
            http.role = role
            account.refresh()
            waitIdle(account)
            try selectGroup(account)
            XCTAssertTrue(groups.canCreate)
            XCTAssertFalse(groups.canManage)
            XCTAssertFalse(groups.showsManagement)
            XCTAssertEqual(groups.state?.members.first?.userID, MacGroupHTTP.user.rawValue)
            let before = http.groupMutationCount
            groups.name = "Forbidden"
            groups.requestRename()
            groups.requestDelete()
            groups.confirm()
            groups.setRole(userID: MacGroupHTTP.other.rawValue, role: .owner)
            if let member = groups.state?.members.first { groups.removeMember(member) }
            groups.createInvite()
            groups.copyInvite()
            XCTAssertNil(groups.confirmation)
            XCTAssertEqual(http.groupMutationCount, before)
            XCTAssertEqual(clipboard.writes, 0)
        }
        groups.createName = "My group"
        groups.create()
        waitIdle(account)
        XCTAssertEqual(groups.state?.selectedGroup?.role, .owner)
        XCTAssertEqual(groups.state?.selectedGroup?.name, "My group")
    }

    func testLastOwnerRejectionsRemainVisibleWithoutOptimisticMembershipEdits() throws {
        let account = try login(role: .owner)
        try selectGroup(account)
        let groups = account.groups
        let owner = try XCTUnwrap(groups.state?.members.first)
        groups.setDraftRole(.viewer, for: owner)
        groups.setRole(userID: owner.userID, role: groups.role(for: owner))
        waitIdle(account)
        XCTAssertEqual(groups.state?.error, .forbidden)
        XCTAssertTrue(groups.state?.error?.message.contains("keep an owner") == true)
        XCTAssertFalse(groups.state?.changeConfirmed == true)
        XCTAssertEqual(groups.state?.members.first?.role, .owner)
        XCTAssertEqual(groups.role(for: owner), .viewer)
        groups.removeMember(owner)
        waitIdle(account)
        XCTAssertEqual(groups.state?.error, .forbidden)
        XCTAssertEqual(groups.state?.members.map(\.userID), [owner.userID])
        XCTAssertTrue(groups.canManage)
    }

    func testDeniedRenameKeepsTheDraftAndServerErrorUntilAnExplicitRefresh() throws {
        let account = try login(role: .owner)
        try selectGroup(account)
        let groups = account.groups
        http.denyRename = true
        groups.name = "Keep this draft"
        groups.userID = MacGroupHTTP.other.rawValue
        groups.requestRename()
        groups.confirm()
        waitIdle(account)
        XCTAssertEqual(groups.state?.error, .forbidden)
        XCTAssertEqual(groups.state?.selectedGroup?.name, "Team")
        XCTAssertEqual(groups.name, "Keep this draft")
        XCTAssertEqual(groups.userID, MacGroupHTTP.other.rawValue)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(groups.state?.error, .forbidden, "No automatic retry or refresh may hide the failure")
        http.denyRename = false
        groups.refresh()
        waitIdle(account)
        XCTAssertNil(groups.state?.error)
        XCTAssertEqual(groups.name, "Keep this draft")
    }

    func testInviteIsShownOnceAndOnlyExplicitCopyUsesTheClipboardBoundary() throws {
        let account = try login(role: .owner)
        try selectGroup(account)
        let groups = account.groups
        for role in [SyncAPI.InviteRole.viewer, .editor] {
            groups.inviteRole = role
            groups.createInvite()
            waitIdle(account)
            let created = try XCTUnwrap(groups.createdInvite)
            XCTAssertEqual(created.target, .group(groupID: MacGroupHTTP.group.rawValue, role: role))
            XCTAssertEqual(clipboard.writes, role == .viewer ? 0 : 1)
            groups.copyInvite()
            XCTAssertTrue(clipboard.text == created.link, "Copy must use the service's one-use link")
            XCTAssertTrue(clipboard.allWorkOnMain)
        }
        XCTAssertEqual(http.inviteRoles, [.viewer, .editor])
        XCTAssertTrue(http.invitesUseDefaultTTL)
        XCTAssertEqual(clipboard.reads, 0)
        let copied = clipboard.text
        let controller = try XCTUnwrap(delegate.settingsWindow)
        controller.presentation.selectedTab = .general
        XCTAssertNil(groups.createdInvite)
        XCTAssertNil(groups.state)
        XCTAssertNil(delegate.groupManagementModel?.state.createdInvite)
        controller.presentation.selectedTab = .account
        waitIdle(account)
        XCTAssertNil(groups.createdInvite)
        XCTAssertFalse(groups.canCopyInvite)
        XCTAssertTrue(clipboard.text == copied, "Closing Account clears its link, not the user's explicit clipboard copy")
    }

    func testWindowHideMinimizeAndCloseClearInvitesAndNativeDrafts() throws {
        let account = try login(role: .owner)
        let controller = try XCTUnwrap(delegate.settingsWindow)
        let groups = account.groups
        for event in 0..<3 {
            try selectGroup(account)
            groups.createInvite()
            waitIdle(account)
            XCTAssertNotNil(groups.createdInvite)
            groups.userID = MacGroupHTTP.other.rawValue
            groups.requestDelete()
            switch event {
            case 0: controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
            case 1: controller.presentation.windowHidden()
            default: try XCTUnwrap(controller.window).close()
            }
            XCTAssertNil(groups.createdInvite)
            XCTAssertNil(groups.confirmation)
            XCTAssertTrue(groups.userID.isEmpty)
            XCTAssertNil(groups.state)
            delegate.showSettings()
            waitIdle(account)
            XCTAssertNil(groups.createdInvite)
        }
    }

    func testLateInviteReplyCannotRepopulateAClosedAccount() throws {
        let account = try login(role: .owner)
        try selectGroup(account)
        let groups = account.groups
        let model = try XCTUnwrap(delegate.groupManagementModel)
        http.holdSuffix = "/invites"
        groups.createInvite()
        XCTAssertTrue(spin { self.http.heldCount == 1 })
        try XCTUnwrap(delegate.settingsWindow?.window).close()
        XCTAssertNil(groups.state)
        http.release()
        XCTAssertTrue(spin { !model.state.isBusy })
        XCTAssertNil(model.state.createdInvite)
        XCTAssertNil(groups.createdInvite)
        delegate.showSettings()
        waitIdle(account)
        XCTAssertNil(groups.createdInvite)
        XCTAssertEqual(http.inviteRoles.count, 1)
    }

    func testAccountRefreshAdoptsRoleLossRemovalAndResetsEveryDraft() throws {
        let account = try login(role: .owner)
        try selectGroup(account)
        let groups = account.groups
        groups.createInvite()
        waitIdle(account)
        let owner = try XCTUnwrap(groups.state?.members.first)
        groups.setDraftRole(.viewer, for: owner)
        groups.createName = "New draft"
        groups.name = "Rename draft"
        groups.userID = MacGroupHTTP.other.rawValue
        groups.memberRole = .owner
        groups.inviteRole = .editor
        groups.requestDelete()
        http.role = .viewer
        account.refresh()
        waitIdle(account)
        XCTAssertEqual(groups.state?.selectedGroup?.role, .viewer)
        XCTAssertFalse(groups.showsManagement)
        XCTAssertFalse(groups.canManage)
        XCTAssertNil(groups.createdInvite)
        XCTAssertNil(groups.confirmation)
        XCTAssertTrue(groups.createName.isEmpty)
        XCTAssertEqual(groups.name, "Team")
        XCTAssertTrue(groups.userID.isEmpty)
        XCTAssertEqual(groups.memberRole, .editor)
        XCTAssertEqual(groups.inviteRole, .viewer)
        XCTAssertTrue(groups.memberRoles.isEmpty)
        http.role = .owner
        account.refresh()
        waitIdle(account)
        XCTAssertTrue(groups.canManage)
        http.role = nil
        account.refresh()
        waitIdle(account)
        XCTAssertNil(groups.state?.selectedGroup)
        XCTAssertTrue(groups.state?.members.isEmpty == true)
        XCTAssertFalse(groups.canManage)
    }

    func testPristineNamesFollowRefreshButEditedNamesAndBoundConfirmationsArePreservedSafely() throws {
        let account = try login(role: .owner)
        try selectGroup(account)
        let groups = account.groups
        http.name = "Remote rename"
        groups.refresh()
        waitIdle(account)
        XCTAssertEqual(groups.name, "Remote rename")
        groups.name = "Local draft"
        groups.requestRename()
        http.name = "Another remote name"
        groups.refresh()
        waitIdle(account)
        XCTAssertEqual(groups.name, "Local draft")
        XCTAssertNil(groups.confirmation)
        let before = http.groupMutationCount
        groups.confirm()
        XCTAssertEqual(http.groupMutationCount, before)
    }

    func testModelResetClearsRoleDraftsEvenWhenTheMembersAreUnchanged() throws {
        let account = try login(role: .owner)
        try selectGroup(account)
        let groups = account.groups
        let member = try XCTUnwrap(groups.state?.members.first)
        let before = groups.state?.members
        groups.setDraftRole(.viewer, for: member)
        groups.requestDelete()
        try XCTUnwrap(delegate.groupManagementModel).dismiss()
        XCTAssertEqual(groups.state?.members, before)
        XCTAssertEqual(groups.role(for: member), .owner)
        XCTAssertTrue(groups.memberRoles.isEmpty)
        XCTAssertNil(groups.confirmation)
    }

    func testAdminMemberCannotUseNativeControlsToElevateTheirOwnRole() throws {
        http.accountKind = .admin
        let account = try login(role: .viewer)
        try selectGroup(account)
        let groups = account.groups
        XCTAssertTrue(groups.canManage)
        XCTAssertFalse(groups.canSetRole(userID: MacGroupHTTP.user.rawValue, role: .owner))
        XCTAssertFalse(groups.canSetRole(userID: MacGroupHTTP.user.rawValue, role: .editor))
        let before = http.groupMutationCount
        groups.setRole(userID: MacGroupHTTP.user.rawValue, role: .owner)
        XCTAssertEqual(http.groupMutationCount, before)
        XCTAssertTrue(groups.canSetRole(userID: MacGroupHTTP.other.rawValue, role: .owner))
    }

    func testAccountAndGroupsDisableEachOtherWhileAnOperationIsAdmitted() throws {
        let account = try login(role: .owner)
        try selectGroup(account)
        let groups = account.groups
        http.holdSuffix = "/invites"
        groups.createInvite()
        groups.createInvite()
        XCTAssertFalse(account.canOperate)
        account.signOut()
        XCTAssertTrue(spin { self.http.heldCount == 1 })
        XCTAssertEqual(http.inviteRoles.count, 1)
        XCTAssertTrue(account.state?.enabled == true)
        http.release()
        waitIdle(account)
        http.holdSuffix = "/me"
        account.refresh()
        XCTAssertFalse(groups.canRefresh)
        XCTAssertFalse(groups.canManage)
        let before = http.groupMutationCount
        groups.createInvite()
        XCTAssertTrue(spin { self.http.heldCount == 1 })
        http.release()
        waitIdle(account)
        XCTAssertEqual(http.groupMutationCount, before)
        XCTAssertTrue(groups.canManage)
    }

    func testConfirmedRenameWithFailedMetadataRefreshShowsBothOutcomes() throws {
        let account = try login(role: .owner)
        try selectGroup(account)
        let groups = account.groups
        http.failMeAfterRename = true
        groups.name = "Committed"
        groups.requestRename()
        groups.confirm()
        waitIdle(account)
        XCTAssertTrue(groups.state?.changeConfirmed == true)
        XCTAssertEqual(groups.state?.error, .refreshIncomplete(.offline))
        XCTAssertFalse(groups.canManage)
        XCTAssertFalse(groups.canCreate)
        http.failMe = false
        groups.refresh()
        waitIdle(account)
        XCTAssertNil(groups.state?.error)
        try selectGroup(account)
        XCTAssertEqual(groups.state?.selectedGroup?.name, "Committed")
    }

    func testRenameAndDeletionReachLibraryStateWithoutAnyPromptWritesOrMoves() throws {
        let account = try login(role: .owner)
        try selectGroup(account)
        let groups = account.groups
        XCTAssertTrue(spin { self.hasGroupRow("Groups/Team/shared.md") })
        let files = try RootedFileStore(root: root)
        let before = try files.read(at: "Groups/Team/shared.md")
        groups.name = "Renamed"
        groups.requestRename()
        groups.confirm()
        waitIdle(account)
        XCTAssertTrue(spin { self.hasGroupRow("Groups/Renamed/shared.md") })
        let section = delegate.libraryBrowserModel?.state.sections.first { $0.id == .group(MacGroupHTTP.group) }
        XCTAssertEqual(section?.title, "Renamed")
        XCTAssertEqual(try files.read(at: "Groups/Renamed/shared.md"), before)
        XCTAssertNil(try files.stamp(at: "Groups/Team/shared.md"))
        groups.requestDelete()
        groups.confirm()
        waitIdle(account)
        XCTAssertTrue(spin {
            self.delegate.libraryBrowserModel?.state.sections.contains { $0.id == .group(MacGroupHTTP.group) } == false
                && self.delegate.libraryBrowserModel?.state.rows.isEmpty == true
                && self.delegate.syncStatusModel?.state.phase == .idle
        })
        XCTAssertNil(try files.stamp(at: "Groups/Renamed/shared.md"))
        XCTAssertEqual(http.promptMutationCount, 0)
        XCTAssertGreaterThan(http.pullCount, 1)
    }

    func testTabDetachmentPreservesIndependentObserversAndRebindClearsOldActions() throws {
        let account = try login(role: .owner)
        try selectGroup(account)
        let groups = account.groups
        let old = try XCTUnwrap(delegate.groupManagementModel)
        var observed = 0
        var hook = 0
        let observer = old.addObserver { _ in observed += 1 }
        old.onChange = { hook += 1 }
        defer { old.removeObserver(observer); old.onChange = nil }
        let controller = try XCTUnwrap(delegate.settingsWindow)
        controller.presentation.selectedTab = .general
        old.dismiss()
        XCTAssertGreaterThan(observed, 0)
        XCTAssertGreaterThan(hook, 0)
        XCTAssertNil(groups.state)
        controller.presentation.selectedTab = .account
        waitIdle(account)
        try selectGroup(account)
        groups.name = "Stale rename"
        groups.requestRename()
        let nextRoot = directory.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: false)
        try XCTUnwrap(delegate.generalSettingsModel).chooseFolder(nextRoot.path)
        XCTAssertTrue(spin { self.delegate.libraryDirectory == nextRoot && account.canOperate })
        XCTAssertFalse(delegate.groupManagementModel === old)
        XCTAssertNil(groups.confirmation)
        let before = http.groupMutationCount
        groups.confirm()
        XCTAssertEqual(http.groupMutationCount, before)
        XCTAssertTrue(groups.createName.isEmpty)
        XCTAssertTrue(groups.userID.isEmpty)
    }

    private func openAccount() throws -> AccountSettingsViewState {
        delegate.showSettings()
        let controller = try XCTUnwrap(delegate.settingsWindow)
        controller.presentation.selectedTab = .account
        let account = controller.presentation.account
        XCTAssertTrue(spin { account.canOperate && account.groups.canRefresh })
        return account
    }

    private func login(role: SyncAPI.Role? = nil) throws -> AccountSettingsViewState {
        http.role = role
        let account = try openAccount()
        let model = try XCTUnwrap(delegate.accountModel)
        var password = "runtime-" + UUID().uuidString
        model.login(server: "https://example.test/paw", username: "person", password: &password, deviceName: "Mac")
        waitIdle(account)
        XCTAssertTrue(account.state?.enabled == true)
        XCTAssertNil(account.state?.error)
        XCTAssertTrue(spin {
            self.delegate.syncStatusModel?.state.lastSuccess != nil && self.delegate.syncStatusModel?.state.phase == .idle
        })
        return account
    }

    private func selectGroup(_ account: AccountSettingsViewState) throws {
        let selected = try XCTUnwrap(account.groups.state?.groups.first)
        account.groups.selectGroup(selected)
        waitIdle(account)
        XCTAssertEqual(account.groups.state?.selectedGroupID, MacGroupHTTP.group)
    }

    private func hasGroupRow(_ path: String) -> Bool {
        delegate.libraryBrowserModel?.state.rows.contains { $0.relativePath.string == path } == true
    }

    private func waitIdle(_ account: AccountSettingsViewState) {
        XCTAssertTrue(spin { account.canOperate && account.groups.canOperate })
    }

    private func spin(_ predicate: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
}

private final class MacGroupWatcher: FileStoreWatcher {
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {}
    func stop() {}
}

private final class MacGroupClipboard: Clipboard {
    private(set) var text: String?
    private(set) var writes = 0
    private(set) var reads = 0
    private(set) var allWorkOnMain = true
    func writeText(_ text: String) {
        allWorkOnMain = allWorkOnMain && Thread.isMainThread
        self.text = text
        writes += 1
    }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) {
        reads += 1
        completion(nil)
    }
}

private final class MacGroupSecrets: SecretStore {
    private let lock = NSLock()
    private var entries: [SecretAccount: SecretValue] = [:]
    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        lock.lock(); defer { lock.unlock() }
        return entries[account].map { StoredSecret(value: $0, tier: .keychain) }
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        lock.lock(); defer { lock.unlock() }
        entries[account] = value
        return .keychain
    }
    func delete(account: SecretAccount) throws {
        lock.lock(); defer { lock.unlock() }
        entries[account] = nil
    }
}

/// Only records paths, methods and roles. Credentials, invite links and request bodies are not diagnostic state.
private final class MacGroupHTTP: HTTPTransporting, @unchecked Sendable {
    static let user = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!
    static let other = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAZ")!
    static let device = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAW")!
    static let group = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAY")!
    static let prompt = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAX")!
    private static let timestamp = "2026-10-15T00:00:00.000Z"
    private let lock = NSLock()
    private var records: [(HTTPMethod, String)] = []
    private var currentRole: SyncAPI.Role?
    private var groupName = "Team"
    private var kind: SyncAPI.AccountKind = .member
    private var otherRole: SyncAPI.Role?
    private var hadGroup = false
    private var deniedRename = false
    private var meFailure = false
    private var meFailureAfterRename = false
    private var offMain = true
    private var issuedRoles: [SyncAPI.InviteRole] = []
    private var defaultTTL = true
    private var heldSuffix: String?
    private var held: [(CheckedContinuation<HTTPResponse, Error>, HTTPResponse)] = []
    var role: SyncAPI.Role? {
        get { locked { currentRole } }
        set { locked { currentRole = newValue; if newValue != nil { hadGroup = true } } }
    }
    var name: String { get { locked { groupName } } set { locked { groupName = newValue } } }
    var accountKind: SyncAPI.AccountKind { get { locked { kind } } set { locked { kind = newValue } } }
    var denyRename: Bool { get { locked { deniedRename } } set { locked { deniedRename = newValue } } }
    var failMe: Bool { get { locked { meFailure } } set { locked { meFailure = newValue } } }
    var failMeAfterRename: Bool { get { locked { meFailureAfterRename } } set { locked { meFailureAfterRename = newValue } } }
    var holdSuffix: String? { get { locked { heldSuffix } } set { locked { heldSuffix = newValue } } }
    var heldCount: Int { locked { held.count } }
    var requestCount: Int { locked { records.count } }
    var pullCount: Int { locked { records.filter { $0.1.hasSuffix("/sync/pull") }.count } }
    var groupMutationCount: Int { locked { records.filter { $0.0 != .get && $0.1.contains("/groups") }.count } }
    var promptMutationCount: Int { locked { records.filter { $0.0 != .get && $0.1.contains("/prompts/") }.count } }
    var allWorkOffMain: Bool { locked { offMain } }
    var inviteRoles: [SyncAPI.InviteRole] { locked { issuedRoles } }
    var invitesUseDefaultTTL: Bool { locked { defaultTTL } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try locked { () throws -> HTTPResponse in
            offMain = offMain && !Thread.isMainThread
            let path = request.url.path
            records.append((request.method, path))
            let user = SyncAPI.User(id: Self.user.rawValue, username: "person", displayName: nil, accountKind: kind,
                createdAt: Self.timestamp, disabledAt: nil)
            if path.hasSuffix("/login") {
                return try http(SyncAPI.AuthResponse(deviceToken: String(repeating: "a", count: 42) + "A", user: user))
            }
            if path.hasSuffix("/logout") { return try http(SyncAPI.EmptyResponse()) }
            if path.hasSuffix("/me") {
                if meFailure { throw HTTPTransportError.networkFailure }
                let groups = currentRole.map { [SyncAPI.GroupMembership(groupID: Self.group.rawValue, name: groupName, role: $0)] } ?? []
                let device = SyncAPI.Device(id: Self.device.rawValue, name: "Mac", createdAt: Self.timestamp,
                    lastSeenAt: nil, revokedAt: nil, isCurrent: true)
                return try http(SyncAPI.MeResponse(user: user, groups: groups, devices: [device]))
            }
            if path.hasSuffix("/sync/pull") { return try pull() }
            if path.hasSuffix("/groups"), request.method == .post {
                groupName = try decode(SyncAPI.CreateGroupRequest.self, request).name
                currentRole = .owner
                otherRole = nil
                hadGroup = true
                return try http(groupDTO())
            }
            if path.hasSuffix("/groups/" + Self.group.rawValue) {
                if request.method == .patch {
                    if deniedRename { return try forbidden() }
                    groupName = try decode(SyncAPI.RenameGroupRequest.self, request).name
                    if meFailureAfterRename { meFailure = true; meFailureAfterRename = false }
                    return try http(groupDTO())
                }
                if request.method == .delete {
                    currentRole = nil
                    otherRole = nil
                    return try http(SyncAPI.EmptyResponse())
                }
            }
            if path.hasSuffix("/members") { return try http(SyncAPI.MembersResponse(members: members())) }
            if path.contains("/members/") {
                let isSelf = path.hasSuffix(Self.user.rawValue)
                if request.method == .put {
                    let role = try decode(SyncAPI.MembershipRequest.self, request).role
                    if isSelf, currentRole == .owner, role != .owner, otherRole != .owner { return try forbidden() }
                    if isSelf { currentRole = role } else { otherRole = role }
                    return try http(member(isSelf ? Self.user : Self.other, role: role))
                }
                if isSelf, currentRole == .owner, otherRole != .owner { return try forbidden() }
                if isSelf { currentRole = nil } else { otherRole = nil }
                return try http(SyncAPI.EmptyResponse())
            }
            if path.hasSuffix("/invites") {
                let invite = try decode(SyncAPI.GroupInviteRequest.self, request)
                issuedRoles.append(invite.role)
                defaultTTL = defaultTTL && invite.expiresIn == nil
                return try http(SyncAPI.InviteResponse(inviteToken: String(repeating: "b", count: 42) + "A",
                    expiresAt: "2026-10-22T00:00:00.000Z", target: .group(groupID: Self.group.rawValue, role: invite.role)))
            }
            return try http(SyncAPI.ErrorResponse.failure(.notFound), status: 404)
        }
        guard locked({ heldSuffix.map { request.url.path.hasSuffix($0) } ?? false }) else { return response }
        return try await withCheckedThrowingContinuation { reply in locked { held.append((reply, response)) } }
    }

    func release() {
        let replies = locked { () -> [(CheckedContinuation<HTTPResponse, Error>, HTTPResponse)] in
            heldSuffix = nil
            let replies = held
            held.removeAll()
            return replies
        }
        for (reply, response) in replies { reply.resume(returning: response) }
    }

    private func groupDTO() -> SyncAPI.Group {
        SyncAPI.Group(id: Self.group.rawValue, name: groupName, createdBy: Self.user.rawValue, createdAt: Self.timestamp)
    }
    private func member(_ id: ULID, role: SyncAPI.Role) -> SyncAPI.Member {
        SyncAPI.Member(userID: id.rawValue, username: id == Self.user ? "person" : "colleague",
            displayName: id == Self.user ? "Person" : nil, role: role, joinedAt: Self.timestamp)
    }
    private func members() -> [SyncAPI.Member] {
        var result = currentRole.map { [member(Self.user, role: $0)] } ?? []
        if let otherRole { result.append(member(Self.other, role: otherRole)) }
        return result
    }
    private func pull() throws -> HTTPResponse {
        var scopes = [SyncAPI.SyncScope(identity: .user(userID: Self.user.rawValue), mode: .snapshot,
            head: 0, cursor: "opaque-user", hasMore: false, items: [])]
        if let role = currentRole {
            let text = "---\nformat: 1\nid: \(Self.prompt.rawValue)\ntitle: Shared\n---\nShared prompt\n"
            let bytes = try CanonicalForm.group(Data(text.utf8), filename: "shared.md").bytes
            let item = SyncAPI.FeedItem.upsert(seq: 1, prompt: .init(id: Self.prompt.rawValue, rev: 1,
                path: "shared.md", content: String(decoding: bytes, as: UTF8.self)))
            scopes.append(.init(identity: .group(groupID: Self.group.rawValue, name: groupName, role: role), mode: .snapshot,
                head: 1, cursor: "opaque-group", hasMore: false, items: [item]))
        }
        let removed = currentRole == nil && hadGroup ? ["group:" + Self.group.rawValue] : []
        return try http(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: scopes, removed: removed))
    }
    private func forbidden() throws -> HTTPResponse { try http(SyncAPI.ErrorResponse.failure(.forbidden), status: 403) }
    private func http<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(statusCode: status, body: try JSONEncoder().encode(value))
    }
    private func decode<T: Decodable>(_ type: T.Type, _ request: HTTPRequest) throws -> T {
        try JSONDecoder().decode(type, from: request.body ?? Data())
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}
