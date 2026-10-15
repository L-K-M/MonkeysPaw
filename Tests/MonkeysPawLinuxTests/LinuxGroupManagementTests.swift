#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawLinux

final class LinuxGroupManagementTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var backend: GroupPageBackend!
    private var account: AccountModel!
    private var model: GroupManagementModel!
    private var view: LinuxSettingsWindow!
    private var window: GTK.Widget!

    override func setUpWithError() throws {
        _ = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        environment = LinuxEnvironment(application: application, environment: tools.environment)
        backend = try GroupPageBackend()
        account = AccountModel(account: backend, mainThread: GLibMainThread())
        model = GroupManagementModel(service: backend, mainThread: GLibMainThread())
    }

    override func tearDown() {
        backend?.release()
        view?.hide()
        if let model, let account {
            let done = GroupPageFlag()
            Task.detached { await model.drain(); await account.drain(); done.set() }
            XCTAssertTrue(GTKTestSupport.spin { done.value })
            model.retire()
            account.retire()
        }
        view = nil
        if let environment {
            environment.shutdown()
            let done = GroupPageFlag()
            Task.detached { await environment.drainSync(); done.set() }
            XCTAssertTrue(GTKTestSupport.spin { done.value })
        }
        if let application { GTKTestSupport.destroy(application) }
        environment = nil
        application = nil
        window = nil
        model = nil
        account = nil
        backend = nil
        tools = nil
    }

    func testOwnerCreatesRenamesUpsertsRemovesAndConfirmsDeletion() throws {
        backend.configure { $0.hasGroup = false }
        try show()
        XCTAssertTrue(try sensitive("create"))
        try input("create-name", "Writers")
        try click("create")
        try click("create")
        waitIdle()
        XCTAssertEqual(model.state.selectedGroup?.name, "Writers")
        XCTAssertTrue(model.state.canManage)
        XCTAssertTrue(try label("id").contains(GroupPageBackend.group.rawValue))
        XCTAssertTrue(try label("member-" + GroupPageBackend.user.rawValue).contains(GroupPageBackend.user.rawValue))
        try input("name", "Editors")
        try click("rename")
        waitIdle()
        XCTAssertEqual(model.state.selectedGroup?.name, "Editors")
        try input("user-id", GroupPageBackend.other.rawValue)
        try role("member-role", .editor)
        try click("set-role")
        waitIdle()
        XCTAssertEqual(model.state.members.first { $0.userID == GroupPageBackend.other.rawValue }?.role, .editor)
        try role("role-" + GroupPageBackend.other.rawValue, .owner)
        try click("set-role-" + GroupPageBackend.other.rawValue)
        waitIdle()
        XCTAssertEqual(model.state.members.first { $0.userID == GroupPageBackend.other.rawValue }?.role, .owner)
        try click("remove-" + GroupPageBackend.other.rawValue)
        waitIdle()
        XCTAssertEqual(model.state.members.map(\.userID), [GroupPageBackend.user.rawValue])
        let beforeDelete = backend.calls
        try click("delete")
        XCTAssertTrue(try visible("delete-confirmation"))
        XCTAssertEqual(backend.calls, beforeDelete)
        try click("cancel-delete")
        XCTAssertFalse(try visible("delete-confirmation"))
        XCTAssertEqual(backend.calls, beforeDelete)
        try click("delete")
        try click("confirm-delete")
        try click("confirm-delete")
        waitIdle()
        XCTAssertTrue(model.state.groups.isEmpty)
        XCTAssertTrue(model.state.members.isEmpty)
        XCTAssertEqual(backend.calls.filter(\.isMutation), [.create("Writers"), .rename(GroupPageBackend.group, "Editors"),
            .setRole(GroupPageBackend.group, GroupPageBackend.other, .editor),
            .setRole(GroupPageBackend.group, GroupPageBackend.other, .owner),
            .removeMember(GroupPageBackend.group, GroupPageBackend.other), .delete(GroupPageBackend.group)])
    }

    func testEditorsSeeMembershipIDsAndReadOnlyMemberList() throws { try assertReadOnly(.editor) }
    func testViewersSeeMembershipIDsAndReadOnlyMemberList() throws { try assertReadOnly(.viewer) }

    func testLastOwnerRemovalAndDemotionKeepTheListAndFixedFailureVisible() throws {
        try showSelected()
        let original = model.state.members
        try input("name", "Unsubmitted rename")
        try click("remove-" + GroupPageBackend.user.rawValue)
        waitIdle()
        XCTAssertEqual(model.state.members, original)
        XCTAssertEqual(try label("error"), GroupManagementIssue.forbidden.message)
        XCTAssertFalse(model.state.changeConfirmed)
        XCTAssertEqual(try inputText("name"), "Unsubmitted rename")
        try role("role-" + GroupPageBackend.user.rawValue, .viewer)
        try click("set-role-" + GroupPageBackend.user.rawValue)
        waitIdle()
        XCTAssertEqual(model.state.members, original)
        XCTAssertTrue(try label("error").contains("keep an owner"))
        XCTAssertTrue(try sensitive("refresh"))
        XCTAssertTrue(try sensitive("rename"))
    }

    func testDeniedRenamePreservesNameAndMemberDraftsUntilExplicitRetry() throws {
        try showSelected()
        try input("name", "Rejected name")
        try input("user-id", GroupPageBackend.other.rawValue)
        try role("member-role", .owner)
        backend.configure { $0.nextIssue = .forbidden }
        try click("rename")
        waitIdle()
        XCTAssertEqual(model.state.selectedGroup?.name, "Team")
        XCTAssertEqual(try inputText("name"), "Rejected name")
        XCTAssertEqual(try inputText("user-id"), GroupPageBackend.other.rawValue)
        XCTAssertEqual(try selectedRole("member-role"), .owner)
        XCTAssertEqual(try label("error"), GroupManagementIssue.forbidden.message)
        drainUI()
        XCTAssertEqual(backend.calls.filter(\.isMutation).count, 1, "Denied operations must not retry automatically")
        XCTAssertEqual(try label("error"), GroupManagementIssue.forbidden.message)
        try click("rename")
        waitIdle()
        XCTAssertEqual(model.state.selectedGroup?.name, "Rejected name")
        XCTAssertTrue(try label("error").isEmpty)
    }

    func testLiveRoleChangesAndRemovalClearDraftsLinksAndConfirmation() throws {
        try showSelected()
        try click("create-invite")
        waitIdle()
        XCTAssertFalse(try label("invite-link").isEmpty, "The created invitation was not displayed")
        try input("create-name", "Draft new group")
        try input("name", "Draft rename")
        try input("user-id", GroupPageBackend.other.rawValue)
        try role("member-role", .owner)
        try role("invite-role", .editor)
        try click("delete")
        backend.configure { $0.role = .viewer }
        // Account refresh also refreshes groups without a recursive observer loop.
        try accountClick("refresh")
        waitIdle()
        XCTAssertEqual(model.state.selectedGroup?.role, .viewer)
        XCTAssertFalse(model.state.canManage)
        XCTAssertTrue(try inputText("create-name").isEmpty)
        XCTAssertEqual(try inputText("name"), "Team")
        XCTAssertTrue(try inputText("user-id").isEmpty)
        XCTAssertEqual(try selectedRole("member-role"), .editor)
        XCTAssertEqual(try selectedRole("invite-role"), .viewer)
        XCTAssertTrue(try label("invite-link").isEmpty, "Role loss retained invitation text")
        XCTAssertFalse(try visible("delete-confirmation"))
        XCTAssertFalse(try sensitive("rename"))
        let calls = backend.calls.count
        drainUI()
        drainUI()
        XCTAssertEqual(backend.calls.count, calls)
        backend.configure { $0.role = .owner; $0.name = "Renamed remotely" }
        try click("refresh")
        waitIdle()
        XCTAssertEqual(try inputText("name"), "Renamed remotely")
        XCTAssertTrue(try sensitive("rename"))
        backend.configure { $0.hasGroup = false }
        try click("refresh")
        waitIdle()
        XCTAssertNil(model.state.selectedGroupID)
        XCTAssertTrue(model.state.members.isEmpty)
        XCTAssertTrue(try label("id").isEmpty)
    }

    func testRemoteRenameUpdatesPristineNameButKeepsEditedName() throws {
        try showSelected()
        backend.configure { $0.name = "First remote rename" }
        try click("refresh")
        waitIdle()
        XCTAssertEqual(try inputText("name"), "First remote rename")
        try input("name", "My draft")
        backend.configure { $0.name = "Second remote rename" }
        try click("refresh")
        waitIdle()
        XCTAssertEqual(try inputText("name"), "My draft")
        XCTAssertEqual(model.state.selectedGroup?.name, "Second remote rename")
    }

    func testRefreshRestoresKeyboardFocusWithoutTakingItFromAnotherControl() throws {
        try showSelected()
        let refresh = try control("refresh")
        XCTAssertNotEqual(gtk_widget_grab_focus(refresh), 0)
        backend.configure { $0.blockNext = .refresh(GroupPageBackend.group) }
        try click("refresh")
        XCTAssertTrue(GTKTestSupport.spin { self.backend.isBlocked })
        backend.release()
        waitIdle()
        XCTAssertEqual(gtk_root_get_focus(gtk_widget_get_root(window)), refresh,
            "Refresh lost keyboard focus after completing")

        backend.configure { $0.blockNext = .refresh(GroupPageBackend.group) }
        try click("refresh")
        XCTAssertTrue(GTKTestSupport.spin { self.backend.isBlocked })
        let notebook = try settingsWidget("settings-tabs", in: window)
        XCTAssertNotEqual(gtk_widget_grab_focus(notebook), 0)
        let movedFocus = gtk_root_get_focus(gtk_widget_get_root(window))
        XCTAssertNotNil(movedFocus)
        backend.release()
        waitIdle()
        XCTAssertEqual(gtk_root_get_focus(gtk_widget_get_root(window)), movedFocus,
            "Refresh took focus after the user moved it")

        let memberAction = "set-role-" + GroupPageBackend.user.rawValue
        let oldAction = try control(memberAction)
        XCTAssertNotEqual(gtk_widget_grab_focus(oldAction), 0)
        backend.configure { $0.blockNext = .refresh(GroupPageBackend.group) }
        try click("refresh")
        XCTAssertTrue(GTKTestSupport.spin { self.backend.isBlocked })
        backend.configure { $0.role = .viewer }
        backend.release()
        waitIdle()
        XCTAssertFalse(try sensitive(memberAction))
        XCTAssertNotEqual(gtk_root_get_focus(gtk_widget_get_root(window)), oldAction,
            "Refresh restored focus to a replaced member control after role loss")
    }

    func testReauthenticationResetsMemberRowRoleDraftsEvenWhenMembersAreUnchanged() throws {
        try showSelected()
        try role("role-" + GroupPageBackend.user.rawValue, .editor)
        backend.configure { $0.account = try! GroupPageBackend.connection() }
        try accountClick("refresh")
        waitIdle()
        XCTAssertEqual(try selectedRole("role-" + GroupPageBackend.user.rawValue), .owner,
            "A connection reset retained a member-role draft")
    }

    func testInviteRequiresExplicitCopyAndClearsOnTabHideAndNativeCloseWithoutLogging() throws {
        environment.log.write(.warning, "Group invitation lifecycle log scan")
        try showSelected()
        try role("invite-role", .editor)
        try click("create-invite")
        waitIdle()
        XCTAssertTrue(model.state.createdInvite?.target == .group(groupID: GroupPageBackend.group.rawValue, role: .editor))
        XCTAssertFalse(try label("invite-link").isEmpty, "The created invitation was not displayed")
        XCTAssertEqual(backend.copyCount, 0)
        try click("copy-invite")
        drainUI()
        XCTAssertEqual(backend.copyCount, 1)
        XCTAssertTrue(backend.copyMatchesCreatedLink, "Copy did not forward the created invitation")
        let notebook = try settingsWidget("settings-tabs", in: window)
        gtk_notebook_set_current_page(mp_notebook(notebook), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.model.state.createdInvite == nil })
        XCTAssertTrue(try label("invite-link").isEmpty, "Tab hide retained invitation text")
        try selectAccount()
        waitIdle()
        XCTAssertTrue(try label("invite-link").isEmpty, "Reopening restored invitation text")
        try click("create-invite")
        waitIdle()
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { self.model.state.createdInvite == nil })
        XCTAssertTrue(try label("invite-link").isEmpty, "Native close retained invitation text")
        try show()
        XCTAssertTrue(try label("invite-link").isEmpty, "Reopening restored invitation text")
        XCTAssertEqual(backend.copyCount, 1)
        var scannedLogs = 0
        if let files = FileManager.default.enumerator(at: tools.directory, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "log" {
                let data = try Data(contentsOf: url)
                scannedLogs += 1
                XCTAssertFalse(data.range(of: Data(backend.token.utf8)) != nil, "An invitation secret reached a log")
            }
        }
        XCTAssertGreaterThan(scannedLogs, 0, "The invitation-secret scan did not inspect any log files")
    }

    func testCancelledBlockedBackendCompletesWithoutRelease() throws {
        backend.configure { $0.blockNext = .refresh(nil) }
        let done = GroupPageFlag()
        let work = Task.detached { [backend = backend!] in
            _ = await backend.execute(.refresh(nil), expectedAccount: nil)
            done.set()
        }
        defer {
            backend.release()
            XCTAssertTrue(GTKTestSupport.spin { done.value })
        }
        XCTAssertTrue(GTKTestSupport.spin { self.backend.isBlocked })
        work.cancel()
        XCTAssertTrue(GTKTestSupport.spin { done.value }, "Cancellation left the fake's worker blocked")
    }

    func testBusyInviteKeepsGLibResponsiveAndAllWidgetNotificationsOnUI() throws {
        try showSelected()
        var notifications = 0
        for name in ["progress", "error", "invite-link", "invite-expiry"] {
            GTK.onNotify(UnsafeMutableRawPointer(try control(name)), "label") {
                XCTAssertTrue(Thread.isMainThread, "A worker touched GTK")
                notifications += 1
            }
        }
        backend.configure { $0.blockNext = .createInvite(GroupPageBackend.group, .viewer) }
        try click("create-invite")
        try click("create-invite")
        XCTAssertTrue(GTKTestSupport.spin { self.backend.isBlocked })
        drainUI()
        XCTAssertFalse(try sensitive("create-invite"))
        XCTAssertFalse(try sensitive("refresh"))
        let heartbeat = GroupPageFlag()
        GTK.onMainLoop { heartbeat.set() }
        XCTAssertTrue(GTKTestSupport.spin { heartbeat.value })
        backend.release()
        waitIdle()
        XCTAssertGreaterThan(notifications, 0)
        XCTAssertTrue(backend.allWorkOffMain)
        XCTAssertEqual(backend.calls.filter { if case .createInvite = $0 { return true }; return false }.count, 1)
        try click("copy-invite")
        drainUI()
        XCTAssertTrue(backend.copyOnMain)
    }

    func testGroupWorkDisablesAccountMutationsAndQueuedAccountIntentDisablesGroups() throws {
        try showSelected()
        backend.configure { $0.blockNext = .createInvite(GroupPageBackend.group, .viewer) }
        try click("create-invite")
        XCTAssertTrue(GTKTestSupport.spin { self.backend.isBlocked })
        drainUI()
        for name in ["sign-in", "sign-out", "refresh"] {
            let button = try settingsWidget("settings-account-" + name, in: window)
            XCTAssertEqual(gtk_widget_is_sensitive(button), 0, "Account could overlap a group operation")
        }
        backend.release()
        waitIdle()
        try accountClick("refresh")
        XCTAssertFalse(try sensitive("create"), "A queued Account intent left group mutations enabled")
        waitIdle()
        XCTAssertTrue(try sensitive("create"))
    }

    func testLateInviteAfterHideNeverRepopulatesOrCopies() throws {
        try showSelected()
        backend.configure { $0.blockNext = .createInvite(GroupPageBackend.group, .viewer) }
        try click("create-invite")
        XCTAssertTrue(GTKTestSupport.spin { self.backend.isBlocked })
        view.hide()
        drainUI()
        XCTAssertTrue(model.state.isBusy)
        XCTAssertTrue(try label("invite-link").isEmpty, "Hide retained invitation text")
        backend.release()
        waitIdle(whileShown: false)
        XCTAssertNil(model.state.createdInvite)
        XCTAssertTrue(try label("invite-link").isEmpty, "A hidden completion restored invitation text")
        XCTAssertEqual(backend.copyCount, 0)
        try show()
        XCTAssertTrue(try label("invite-link").isEmpty, "Reopening restored invitation text")
    }

    func testLateCompletionAfterDestroyCannotTouchBorrowedWidgets() throws {
        try showSelected()
        let link = try control("invite-link")
        g_object_ref(link)
        defer { g_object_unref(link) }
        var destroyed = false, lateWrites = 0
        GTK.onNotify(UnsafeMutableRawPointer(link), "label") { if destroyed { lateWrites += 1 } }
        backend.configure { $0.blockNext = .createInvite(GroupPageBackend.group, .viewer) }
        try click("create-invite")
        XCTAssertTrue(GTKTestSupport.spin { self.backend.isBlocked })
        gtk_window_destroy(mp_window(window))
        destroyed = true
        drainUI()
        backend.release()
        waitIdle(whileShown: false)
        XCTAssertEqual(lateWrites, 0)
        XCTAssertNil(model.state.createdInvite)
        view = nil
        window = nil
    }

    func testAccountChangeWhileBusyClearsLinkAndRetriesOnlyRefreshWhenIdle() throws {
        try showSelected()
        backend.configure { $0.blockNext = .createInvite(GroupPageBackend.group, .viewer) }
        try click("create-invite")
        XCTAssertTrue(GTKTestSupport.spin { self.backend.isBlocked })
        backend.configure { $0.account = try! GroupPageBackend.connection(user: GroupPageBackend.other) }
        account.refresh()
        XCTAssertTrue(GTKTestSupport.spin { !self.account.state.isBusy && self.account.state.connection?.userID == GroupPageBackend.other })
        drainUI()
        XCTAssertTrue(try label("invite-link").isEmpty, "An account change retained invitation text")
        XCTAssertFalse(try sensitive("create"))
        backend.release()
        waitIdle()
        XCTAssertEqual(model.state.connection?.userID, GroupPageBackend.other)
        XCTAssertNil(model.state.createdInvite)
        XCTAssertTrue(try label("invite-link").isEmpty, "An old account completion restored invitation text")
        XCTAssertEqual(backend.calls.filter { if case .createInvite = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(try sensitive("refresh"))
    }

    func testConfirmedChangeWithFailedRefreshShowsBothFactsAndDisablesManagement() throws {
        try showSelected()
        backend.configure { $0.failMetadataAfterMutation = true }
        try input("name", "Committed name")
        try click("rename")
        waitIdle()
        XCTAssertTrue(model.state.changeConfirmed)
        XCTAssertEqual(try label("confirmed"), LinuxGroupManagementStrings.confirmed)
        XCTAssertEqual(try label("error"), GroupManagementIssue.refreshIncomplete(.offline).message)
        XCTAssertFalse(try sensitive("create"))
        XCTAssertFalse(try sensitive("rename"))
        XCTAssertTrue(try sensitive("refresh"))
        backend.configure { $0.metadataAvailable = true }
        try click("refresh")
        waitIdle()
        XCTAssertEqual(model.state.groups.first?.name, "Committed name")
        XCTAssertTrue(try sensitive("create"))
    }

    func testAdminSelfElevationIsDisabledByPresentationPolicy() throws {
        backend.configure { $0.role = .viewer; $0.kind = .admin }
        try showSelected()
        XCTAssertTrue(model.state.canManage)
        try input("user-id", GroupPageBackend.user.rawValue)
        try role("member-role", .owner)
        XCTAssertFalse(try sensitive("set-role"))
        try role("role-" + GroupPageBackend.user.rawValue, .editor)
        XCTAssertFalse(try sensitive("set-role-" + GroupPageBackend.user.rawValue))
        try click("set-role-" + GroupPageBackend.user.rawValue)
        drainUI()
        XCTAssertTrue(backend.calls.filter(\.isMutation).isEmpty)
        try role("role-" + GroupPageBackend.user.rawValue, .viewer)
        XCTAssertTrue(try sensitive("set-role-" + GroupPageBackend.user.rawValue))
    }

    func testGroupObserversRemainIndependentAndDetachOnHide() throws {
        var other = 0, hook = 0
        model.addObserver { _ in other += 1 }
        model.onChange = { hook += 1 }
        try showSelected()
        view.hide()
        drainUI()
        let before = other
        model.refresh()
        waitIdle(whileShown: false)
        XCTAssertGreaterThan(other, before)
        XCTAssertGreaterThan(hook, 0)
        XCTAssertTrue(try label("id").isEmpty)
    }

    func testProductionAccountComposesSharedGroupModelAndRebindsAfterLibrarySwitch() throws {
        let old = try XCTUnwrap(environment.groupManagementModel)
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { self.findWindow() != nil })
        window = try XCTUnwrap(findWindow())
        try selectAccount()
        XCTAssertTrue(GTKTestSupport.spin { !old.state.isBusy })
        drainUI()
        XCTAssertTrue(GTKTestSupport.spin { (try? self.sensitive("refresh")) == true })
        XCTAssertEqual(try label("message"), LinuxGroupManagementStrings.unavailable)
        XCTAssertFalse(try sensitive("create"))
        let replacement = tools.directory.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        XCTAssertEqual(environment.switchLibrary(to: replacement), .switched)
        let next = try XCTUnwrap(environment.groupManagementModel)
        XCTAssertFalse(next === old)
        XCTAssertTrue(GTKTestSupport.spin { !next.state.isBusy })
        drainUI()
        XCTAssertEqual(try label("message"), LinuxGroupManagementStrings.unavailable)
        XCTAssertTrue(try label("invite-link").isEmpty)
    }

    private func assertReadOnly(_ role: SyncAPI.Role) throws {
        backend.configure { $0.role = role }
        try showSelected()
        XCTAssertTrue(try label("member-" + GroupPageBackend.user.rawValue).contains(GroupPageBackend.user.rawValue))
        XCTAssertTrue(try label("read-only").contains("Only owners or admins"))
        XCTAssertTrue(try sensitive("create"), "Members can create a separate group")
        for name in ["rename", "delete", "set-role", "create-invite", "copy-invite", "remove-" + GroupPageBackend.user.rawValue] {
            XCTAssertFalse(try sensitive(name))
            try click(name)
        }
        drainUI()
        XCTAssertTrue(backend.calls.filter(\.isMutation).isEmpty)
        XCTAssertTrue(model.state.error == nil)
    }

    private func showSelected() throws {
        try show()
        try click("select-" + GroupPageBackend.group.rawValue)
        waitIdle()
        XCTAssertEqual(model.state.selectedGroupID, GroupPageBackend.group)
        XCTAssertFalse(model.state.members.isEmpty)
    }

    private func show() throws {
        if view == nil {
            view = LinuxSettingsWindow(application: application, general: environment.generalSettingsModel,
                shortcuts: environment.shortcutsSettingsModel, rememberedValues: environment.rememberedValuesSettingsModel,
                delivery: environment.deliverySettingsModel, updates: environment.updateSettingsModel, session: .otherX11,
                makeAssistant: { nil }, chooser: SettingsFolderChooser(), openSetup: {},
                makeAccount: { [weak self] in self?.account }, makeGroups: { [weak self] in self?.model })
        }
        view.show()
        window = try XCTUnwrap(findWindow())
        try selectAccount()
        waitIdle()
    }

    private func selectAccount() throws {
        let notebook = try settingsWidget("settings-tabs", in: window)
        let page = try settingsWidget("settings-account-page", in: window)
        gtk_notebook_set_current_page(mp_notebook(notebook), gtk_notebook_page_num(mp_notebook(notebook), page))
    }
    private func findWindow() -> GTK.Widget? {
        var windows = gtk_application_get_windows(application)
        while let node = windows {
            if let data = node.pointee.data {
                let window = data.assumingMemoryBound(to: GtkWindow.self)
                if gtk_window_get_title(window).map({ String(cString: $0) }) == LinuxStrings.settings { return mp_window_widget(window) }
            }
            windows = node.pointee.next
        }
        return nil
    }
    private func control(_ name: String) throws -> GTK.Widget { try settingsWidget("settings-groups-" + name, in: window) }
    private func input(_ name: String, _ value: String) throws { mp_entry_set_text(try control(name), value) }
    private func inputText(_ name: String) throws -> String { String(cString: mp_entry_text(try control(name))) }
    private func label(_ name: String) throws -> String { String(cString: gtk_label_get_text(mp_label(try control(name)))) }
    private func sensitive(_ name: String) throws -> Bool { gtk_widget_is_sensitive(try control(name)) != 0 }
    private func visible(_ name: String) throws -> Bool { gtk_widget_get_visible(try control(name)) != 0 }
    private func role(_ name: String, _ role: SyncAPI.Role) throws {
        gtk_combo_box_set_active_id(mp_combo_box(try control(name)), role.rawValue)
    }
    private func selectedRole(_ name: String) throws -> SyncAPI.Role? {
        gtk_combo_box_get_active_id(mp_combo_box(try control(name))).flatMap { SyncAPI.Role(rawValue: String(cString: $0)) }
    }
    private func click(_ name: String) throws { try emitClick(control(name)) }
    private func accountClick(_ name: String) throws { try emitClick(settingsWidget("settings-account-" + name, in: window)) }
    private func emitClick(_ button: GTK.Widget) {
        var value = GValue()
        g_value_init(&value, gtk_button_get_type())
        g_value_set_object(&value, button)
        g_signal_emitv(&value, g_signal_lookup("clicked", gtk_button_get_type()), 0, nil)
        g_value_unset(&value)
    }
    private func waitIdle(whileShown: Bool = true) {
        drainUI()
        let refresh = whileShown ? try? control("refresh") : nil
        // Readiness includes native admission and the refresh queued after
        // Account loading. An idle model alone can precede either GLib callback.
        XCTAssertTrue(GTKTestSupport.spin {
            !self.model.state.isBusy && !self.account.state.isBusy && !self.backend.isBlocked
                && (refresh.map { gtk_widget_is_sensitive($0) != 0 } ?? true)
        })
        drainUI()
    }
    private func drainUI() {
        var done = false
        GTK.onMainLoop { done = true }
        XCTAssertTrue(GTKTestSupport.spin { done })
    }
}

private final class GroupPageFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}

/// The native tests inject presentation's service boundary. Real transactional
/// server behavior is covered by Y31; this fake supplies its result contracts.
private final class GroupPageBackend: GroupManagementProviding, AccountProviding {
    static let group = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAT")!
    static let user = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!
    static let other = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAZ")!
    static let device = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAW")!
    struct Configuration {
        var account: SyncAccount?
        var role: SyncAPI.Role = .owner
        var kind: SyncAPI.AccountKind = .member
        var hasGroup = true
        var name = "Team"
        var metadataAvailable = true
        var nextIssue: GroupManagementIssue?
        var blockNext: SyncGroupCommand?
        var failMetadataAfterMutation = false
    }
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + "AAAAAAAAAAA"
    private let lock = NSLock()
    private var config: Configuration
    private var recorded: [SyncGroupCommand] = []
    private var otherMembers: [SyncAPI.Member] = []
    private var blocked = false
    private var offMain = true
    private var copies: [String] = []
    private var copiedOnMain = true
    var calls: [SyncGroupCommand] { locked { recorded } }
    var isBlocked: Bool { locked { blocked } }
    var allWorkOffMain: Bool { locked { offMain } }
    var copyCount: Int { locked { copies.count } }
    var copyOnMain: Bool { locked { copiedOnMain } }
    var copyMatchesCreatedLink: Bool { locked { copies.last?.contains(token) == true } }

    init() throws { config = Configuration(account: try Self.connection()) }
    func configure(_ edit: (inout Configuration) -> Void) { locked { edit(&config) } }
    func release() { locked { blocked = false } }
    static func connection(user: ULID = user) throws -> SyncAccount {
        try SyncAccount(identity: SyncAccountIdentity(serverURL: "https://example.test/paw", userID: user),
            username: "person", deviceID: device, deviceName: "Linux", connectionID: UUID())
    }
    var snapshot: SyncAccountSnapshot {
        locked { offMain = offMain && !Thread.isMainThread; return snapshotLocked() }
    }
    private func snapshotLocked() -> SyncAccountSnapshot {
        guard let account = config.account else { return SyncAccountSnapshot() }
        let person = SyncAPI.User(id: account.identity.userID.rawValue, username: account.username, displayName: nil,
            accountKind: config.kind, createdAt: "2026-10-14T00:00:00.000Z", disabledAt: nil)
        let groups: [SyncAPI.GroupMembership] = config.hasGroup ? [.init(groupID: Self.group.rawValue, name: config.name, role: config.role)] : []
        return SyncAccountSnapshot(account: account, me: config.metadataAvailable ? .init(user: person, groups: groups, devices: []) : nil,
            tier: .file, enabled: true)
    }
    private func membersLocked() -> [SyncAPI.Member] {
        guard let account = config.account else { return [] }
        return [.init(userID: account.identity.userID.rawValue, username: account.username, displayName: "Person",
            role: config.role, joinedAt: "2026-10-14T00:00:00.000Z")] + otherMembers
    }
    func execute(_ command: SyncGroupCommand, expectedAccount: SyncAccount?) async -> SyncGroupResult {
        let shouldBlock = locked {
            offMain = offMain && !Thread.isMainThread
            recorded.append(command)
            blocked = config.blockNext == command
            return blocked
        }
        if shouldBlock {
            // Yield so Account completions can run even on a small cooperative pool.
            let deadline = ContinuousClock().now.advanced(by: .seconds(30))
            while isBlocked && !Task.isCancelled, ContinuousClock().now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            if isBlocked && !Task.isCancelled { XCTFail("A blocked group command was never released") }
            locked { blocked = false; config.blockNext = nil }
        }
        return locked {
            var selected = command.groupID
            var issue = config.nextIssue
            config.nextIssue = nil
            var created: SyncInviteCreation?
            if command.isMutation && expectedAccount != config.account { issue = .accountChanged }
            if command.isMutation && config.role != .owner && config.kind != .admin { issue = .forbidden }
            if case .removeMember(_, let user) = command, user == config.account?.identity.userID,
               config.role == .owner, !otherMembers.contains(where: { $0.role == .owner }) { issue = .forbidden }
            if case .setRole(_, let user, let role) = command, user == config.account?.identity.userID,
               config.role == .owner, role != .owner, !otherMembers.contains(where: { $0.role == .owner }) { issue = .forbidden }
            if issue == nil {
                switch command {
                case .refresh: break
                case .create(let name): config.name = name; config.hasGroup = true; config.role = .owner; selected = Self.group
                case .rename(_, let name): config.name = name
                case .delete: config.hasGroup = false; selected = nil
                case .setRole(_, let user, let role):
                    if user == config.account?.identity.userID { config.role = role }
                    else {
                        otherMembers.removeAll { $0.userID == user.rawValue }
                        otherMembers.append(.init(userID: user.rawValue, username: "other", displayName: nil,
                            role: role, joinedAt: "2026-10-14T00:00:00.000Z"))
                    }
                case .removeMember(_, let user): otherMembers.removeAll { $0.userID == user.rawValue }
                case .createInvite(let group, let role):
                    if let account = config.account {
                        created = SyncInviteCreation(link: try! SyncInviteLink(token, server: account.identity.serverURL.absoluteString).text,
                            expiresAt: "2026-10-21T00:00:00.000Z", target: .group(groupID: group.rawValue, role: role), account: account)
                    }
                }
            }
            let confirmed = command.isMutation && issue == nil
            if confirmed && config.failMetadataAfterMutation {
                config.failMetadataAfterMutation = false
                config.metadataAvailable = false
                issue = .refreshIncomplete(.offline)
            }
            if !config.hasGroup || !config.metadataAvailable { selected = nil }
            return SyncGroupResult(snapshot: snapshotLocked(), selectedGroupID: selected,
                members: selected == nil ? [] : membersLocked(), createdInvite: created, changeConfirmed: confirmed, issue: issue)
        }
    }
    func copy(_ created: SyncInviteCreation) throws {
        try locked {
            guard created.account == config.account else { throw InviteIssue.accountChanged }
            copiedOnMain = copiedOnMain && Thread.isMainThread
            copies.append(created.link)
        }
    }
    func login(server: String, username: String, password: inout String, deviceName: String) async throws -> SyncAccountSnapshot {
        password = ""
        return snapshot
    }
    func startup() async throws -> SyncAccountSnapshot { snapshot }
    func refresh() async throws -> SyncAccountSnapshot { snapshot }
    func revokeDevice(_ id: ULID) async throws -> SyncAccountSnapshot { configure { $0.account = nil }; return snapshot }
    func signOut() async throws -> SyncAccountCleanup { configure { $0.account = nil }; return SyncAccountCleanup() }
    func heldPrompts() throws -> [SyncHeldPrompt] { [] }
    func includeHeld(_ identities: Set<PromptIdentity>) async throws -> SyncAccountSnapshot { snapshot }
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
}
#endif
