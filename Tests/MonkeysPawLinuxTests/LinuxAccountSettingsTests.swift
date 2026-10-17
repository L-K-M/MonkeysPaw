#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawLinux

final class LinuxAccountSettingsTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var account: AccountPageService!
    private var model: AccountModel!
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
        account = AccountPageService()
        model = AccountModel(account: account, mainThread: GLibMainThread())
    }

    override func tearDown() {
        account?.release()
        view?.hide()
        if let model {
            let drained = AccountPageFlag()
            Task.detached { await model.drain(); drained.set() }
            XCTAssertTrue(GTKTestSupport.spin { drained.value })
            model.retire()
        }
        view = nil
        if let environment {
            environment.shutdown()
            let drained = AccountPageFlag()
            Task.detached { await environment.drainSync(); drained.set() }
            XCTAssertTrue(GTKTestSupport.spin { drained.value })
        }
        if let application { GTKTestSupport.destroy(application) }
        environment = nil
        application = nil
        window = nil
        model = nil
        account = nil
        tools = nil
    }

    func testSecureLoginClearsImmediatelyAndOnCompletionWithoutBlockingGLibOrDuplicating() throws {
        try show()
        let password = try control("password")
        XCTAssertNotEqual(g_type_check_instance_is_a(UnsafeMutableRawPointer(password).assumingMemoryBound(to: GTypeInstance.self),
            gtk_password_entry_get_type()), 0)
        let supplied = "password-" + UUID().uuidString
        try loginInputs(password: supplied)
        XCTAssertNotEqual(gtk_widget_grab_focus(password), 0)
        account.blockNext = .login
        try click("sign-in")
        try click("sign-in")
        XCTAssertTrue(try inputText("password").isEmpty, "Secure input was not cleared")
        XCTAssertTrue(GTKTestSupport.spin { self.account.isBlocked && self.model.state.operation == .signingIn })
        drainUI()
        XCTAssertFalse(try sensitive("sign-in"))
        XCTAssertFalse(try sensitive("server"))
        XCTAssertEqual(try label("progress"), LinuxAccountSettingsStrings.progress(.signingIn))
        let heartbeat = AccountPageFlag()
        GTK.onMainLoop { heartbeat.set() }
        XCTAssertTrue(GTKTestSupport.spin { heartbeat.value })
        XCTAssertEqual(account.calls, [.login])
        XCTAssertTrue(account.receivedPassword { $0 == supplied })
        XCTAssertEqual(account.loginMetadata, ["https://example.test/paw", "person", "Linux test"])
        try input("password", "late-native-input")
        account.release()
        waitIdle()
        XCTAssertTrue(model.state.enabled)
        XCTAssertTrue(try inputText("password").isEmpty, "Secure input was not cleared")
        XCTAssertTrue(account.allWorkOffMain)
        XCTAssertFalse(try allLabels().contains(supplied))
    }

    func testReadOnlyEnvironmentAndUnencryptedFileLabelsUseCoreMessages() throws {
        for tier in [SecretTier.environment, .file, .secretService, .keychain] {
            view?.hide()
            account.snapshot = try AccountPageService.signedIn(tier: tier)
            model = AccountModel(account: account, mainThread: GLibMainThread())
            try show()
            XCTAssertEqual(try label("storage"), model.state.secretStorageMessage)
            if tier == .environment { XCTAssertTrue(try label("storage").contains("read-only")) }
            if tier == .file { XCTAssertTrue(try label("storage").contains("unencrypted")) }
            XCTAssertTrue(try inputText("password").isEmpty, "Secure input was not cleared")
        }
        XCTAssertTrue(account.calls.isEmpty, "Opening Account must not sign in or start network work")
    }

    func testReservedFoldersRequireRenameAndFreshLoginWithoutPasswordRetention() throws {
        try show()
        account.failure = .reservedFolders(["Groups", "Conflicts"])
        try loginInputs(password: "first-password")
        try click("sign-in")
        waitIdle()
        XCTAssertFalse(model.state.enabled)
        XCTAssertEqual(try label("error"), AccountIssue.reservedFolders.message)
        let guidance = try label("reserved")
        XCTAssertTrue(guidance.contains("Rename"))
        XCTAssertTrue(guidance.contains("Groups"))
        XCTAssertTrue(guidance.contains("Conflicts"))
        XCTAssertTrue(try inputText("password").isEmpty, "Secure input was not cleared")
        account.failure = nil
        try click("refresh")
        waitIdle()
        XCTAssertEqual(account.calls, [.login], "Refresh cannot replay a login")
        try loginInputs(password: "fresh-password")
        try click("sign-in")
        waitIdle()
        XCTAssertTrue(model.state.enabled)
        XCTAssertTrue(account.receivedPassword { $0 == "fresh-password" })
        XCTAssertEqual(try label("reserved"), "")
    }

    func testHeldFilesStayHeldUntilSelectedInclusionAndFailedInclusionStaysVisible() throws {
        account.snapshot = try AccountPageService.signedIn()
        account.holds = try [AccountPageService.hold(path: "a.md", id: AccountPageService.firstHeld),
                             AccountPageService.hold(path: "b.md", id: AccountPageService.secondHeld)]
        try show()
        XCTAssertFalse(try sensitive("include"))
        try selectHold(0)
        try click("keep-local")
        XCTAssertTrue(GTKTestSupport.spin { self.model.state.keptLocal.count == 1 })
        drainUI()
        XCTAssertEqual(account.holds.count, 2)
        XCTAssertTrue(account.calls.isEmpty)
        XCTAssertTrue(try holdLabel(0).contains("kept local"))
        account.failure = .metadata(.writeFailed(.ioFailure))
        try click("include")
        waitIdle()
        XCTAssertEqual(model.state.error, .storageWrite)
        XCTAssertEqual(try label("error"), AccountIssue.storageWrite.message)
        XCTAssertEqual(account.holds.count, 2)
        account.failure = nil
        try click("include")
        waitIdle()
        XCTAssertEqual(account.holds.map(\.identity), [.assigned(AccountPageService.secondHeld)])
        XCTAssertEqual(account.included, [[.assigned(AccountPageService.firstHeld)]])
        XCTAssertTrue(model.state.needsHeldDecision)
        XCTAssertTrue(try holdLabel(0).contains("b.md"))
        XCTAssertFalse(try sensitive("include"), "Removed selections must not carry over to another file")
        try selectHold(0)
        try click("keep-local")
        XCTAssertTrue(GTKTestSupport.spin { !self.model.state.needsHeldDecision })
        drainUI()
        account.snapshot = try AccountPageService.signedIn(user: AccountPageService.otherUser)
        try input("password", "previous-account-input")
        try click("refresh")
        waitIdle()
        XCTAssertTrue(model.state.keptLocal.isEmpty)
        XCTAssertTrue(model.state.needsHeldDecision)
        XCTAssertEqual(account.holds.count, 1)
        XCTAssertFalse(try sensitive("include"), "An account change requires a fresh file selection")
        XCTAssertTrue(try inputText("password").isEmpty)
    }

    func testDeviceListOtherAndCurrentRevocationAreSingleIntents() throws {
        account.snapshot = try AccountPageService.signedIn()
        try show()
        XCTAssertTrue(try allLabels().contains("Linux (this device)"))
        XCTAssertTrue(try allLabels().contains("Laptop"))
        account.blockNext = .revoke(AccountPageService.otherDevice)
        try click("revoke-" + AccountPageService.otherDevice.rawValue)
        try click("revoke-" + AccountPageService.otherDevice.rawValue)
        XCTAssertTrue(GTKTestSupport.spin { self.account.isBlocked })
        XCTAssertFalse(try sensitive("sign-out"))
        account.release()
        waitIdle()
        XCTAssertEqual(account.calls, [.revoke(AccountPageService.otherDevice), .refresh])
        XCTAssertTrue(model.state.enabled)
        XCTAssertFalse(try allLabels().contains("Laptop"))
        try click("revoke-" + AccountPageService.device.rawValue)
        waitIdle()
        XCTAssertEqual(account.calls.last, .revoke(AccountPageService.device))
        XCTAssertFalse(model.state.enabled)
        XCTAssertNil(model.state.connection)
        XCTAssertTrue(model.state.devices.isEmpty)
        XCTAssertFalse(try sensitive("sign-out"))
    }

    func testRepeatedKeepLocalDoesNotLeaveAccountControlsBusy() throws {
        account.snapshot = try AccountPageService.signedIn()
        account.holds = try [AccountPageService.hold(path: "a.md", id: AccountPageService.firstHeld)]
        try show()
        try selectHold(0)
        try click("keep-local")
        XCTAssertTrue(GTKTestSupport.spin { self.model.state.keptLocal.count == 1 })
        drainUI()
        try click("keep-local")
        drainUI()
        XCTAssertFalse(model.state.isBusy)
        XCTAssertTrue(try sensitive("refresh"))
        XCTAssertTrue(try sensitive("server"))
        XCTAssertTrue(try sensitive("include"))
        XCTAssertTrue(account.calls.isEmpty)
    }

    func testSignOutShowsPartialCleanupAndCannotRunTwice() throws {
        account.snapshot = try AccountPageService.signedIn()
        account.signOutCleanup = SyncAccountCleanup(remote: .unconfirmed, secretFailures: [UUID()],
            secretIssue: .deleteFailed, metadataIssue: .writeFailed(.ioFailure), recoveryRequired: true)
        try show()
        account.blockNext = .signOut
        try click("sign-out")
        try click("sign-out")
        XCTAssertTrue(GTKTestSupport.spin { self.account.isBlocked })
        account.release()
        waitIdle()
        XCTAssertFalse(model.state.cleanup.isComplete)
        let message = try label("cleanup")
        XCTAssertTrue(message.contains("revocation could not be confirmed"))
        XCTAssertTrue(message.contains("could not be removed"))
        XCTAssertTrue(message.contains(AccountIssue.storageWrite.message))
        XCTAssertTrue(message.contains(AccountIssue.recoveryRequired.message))
        XCTAssertEqual(account.calls, [.signOut])
        XCTAssertFalse(model.state.enabled)
    }

    func testSecretStorageFailureClearsPasswordAndUsesFixedError() throws {
        try show()
        account.failure = .secret(.locked)
        let supplied = "password-" + UUID().uuidString
        try loginInputs(password: supplied)
        try click("sign-in")
        waitIdle()
        XCTAssertEqual(model.state.error, .secret(.locked))
        XCTAssertEqual(try label("error"), AccountIssue.secret(.locked).message)
        XCTAssertTrue(try inputText("password").isEmpty, "Secure input was not cleared")
        XCTAssertFalse(try allLabels().contains(supplied))
        XCTAssertFalse(model.state.enabled)
    }

    func testNativeSecretStorageWaitKeepsTheGLibLoopResponsive() throws {
        try tools.install("secret-tool", script: #"""
        case "$1" in
        lookup) exit 1;;
        search) exit 0;;
        store)
            /bin/cat > /dev/null
            /usr/bin/touch "$FAKE_LOG.entered"
            while [ ! -e "$FAKE_LOG.release" ]; do /bin/sleep 0.01; done
            exit 0;;
        clear) exit 0;;
        esac
        """#)
        let entered = tools.directory.appendingPathComponent("argv.entered")
        let release = tools.directory.appendingPathComponent("argv.release")
        defer { _ = FileManager.default.createFile(atPath: release.path, contents: Data()) }
        environment.shutdown()
        environment = LinuxEnvironment(application: application, environment: tools.environment, syncTransport: AccountPageHTTP())
        let nativeModel = try XCTUnwrap(environment.accountModel)
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { self.settingsWindow() != nil })
        window = try firstWindow()
        try selectAccountTab()
        XCTAssertTrue(GTKTestSupport.spin { !nativeModel.state.isBusy })
        drainUI()
        try loginInputs(password: "runtime-" + UUID().uuidString)
        try click("sign-in")
        XCTAssertTrue(GTKTestSupport.spin { FileManager.default.fileExists(atPath: entered.path) })
        let heartbeat = AccountPageFlag()
        GTK.onMainLoop { heartbeat.set() }
        XCTAssertTrue(GTKTestSupport.spin { heartbeat.value })
        XCTAssertTrue(nativeModel.state.isBusy)
        XCTAssertTrue(try inputText("password").isEmpty, "Secure input was not cleared")
        XCTAssertFalse(try sensitive("sign-in"))
        XCTAssertTrue(FileManager.default.createFile(atPath: release.path, contents: Data()))
        XCTAssertTrue(GTKTestSupport.spin { !nativeModel.state.isBusy })
        XCTAssertTrue(nativeModel.state.enabled)
        XCTAssertEqual(nativeModel.state.secretTier, .secretService)
    }

    func testHideDetachesLateCompletionClearsPasswordAndReopensCurrentState() throws {
        try show()
        try loginInputs(password: "submitted")
        account.blockNext = .login
        try click("sign-in")
        XCTAssertTrue(GTKTestSupport.spin { self.account.isBlocked })
        view.hide()
        XCTAssertTrue(try inputText("password").isEmpty, "Secure input was not cleared")
        let hiddenText = try label("connection")
        account.release()
        waitIdle()
        XCTAssertTrue(model.state.enabled, "Hiding cannot cancel admitted credential cleanup")
        XCTAssertEqual(try label("connection"), hiddenText)
        try click("sign-out")
        drainUI()
        XCTAssertEqual(account.calls, [.login])
        try show()
        XCTAssertTrue(try label("connection").contains("person"))
        XCTAssertTrue(try inputText("password").isEmpty, "Secure input was not cleared")
        try input("password", "native-close-secret")
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { !self.view.isVisible })
        XCTAssertTrue(try inputText("password").isEmpty, "Secure input was not cleared")
    }

    func testDestroyClearsNativeSecretAndRejectsLateCallbacks() throws {
        try show()
        try loginInputs(password: "submitted")
        account.blockNext = .login
        try click("sign-in")
        XCTAssertTrue(GTKTestSupport.spin { self.account.isBlocked })
        let password = try control("password")
        g_object_ref(password)
        defer { g_object_unref(password) }
        mp_entry_set_text(password, "destroy-secret")
        gtk_window_destroy(mp_window(window))
        account.release()
        waitIdle()
        XCTAssertTrue(String(cString: mp_entry_text(password)).isEmpty, "Secure input was not cleared")
        XCTAssertFalse(view.isVisible)
        view.show()
        XCTAssertFalse(view.isVisible)
    }

    func testTabUnmapClearsPasswordAndIndependentObserversRemainAttached() throws {
        var notifications = 0
        model.onChange = { notifications += 1 }
        try show()
        try input("password", "tab-secret")
        gtk_notebook_set_current_page(mp_notebook(try settingsWidget("settings-tabs", in: window)), 0)
        XCTAssertTrue(GTKTestSupport.spin { (try? self.inputText("password")) == "" })
        let before = notifications
        view.hide()
        model.clearPasswordInput()
        drainUI()
        XCTAssertGreaterThan(notifications, before)
        XCTAssertNotNil(model.onChange)
    }

    func testAccountModelIsBoundOnlyWhileItsTabIsMapped() throws {
        var bindings = 0
        view = LinuxSettingsWindow(application: application, general: environment.generalSettingsModel,
            shortcuts: environment.shortcutsSettingsModel, rememberedValues: environment.rememberedValuesSettingsModel,
            delivery: environment.deliverySettingsModel, updates: environment.updateSettingsModel, session: .otherX11,
            makeAssistant: { nil }, chooser: SettingsFolderChooser(), openSetup: {},
            makeAccount: { [weak self] in bindings += 1; return self?.model })
        view.show()
        window = try firstWindow()
        drainUI()
        XCTAssertEqual(bindings, 0)
        try selectAccountTab()
        drainUI()
        XCTAssertEqual(bindings, 1)
        try input("password", "tab-input")
        gtk_notebook_set_current_page(mp_notebook(try settingsWidget("settings-tabs", in: window)), 0)
        drainUI()
        XCTAssertTrue(try inputText("password").isEmpty)
        try selectAccountTab()
        drainUI()
        XCTAssertEqual(bindings, 2)
    }

    func testCompositionSignsInRevokesCurrentAndRebindsAfterLibrarySwitch() throws {
        let http = AccountPageHTTP()
        environment.shutdown()
        environment = LinuxEnvironment(application: application, environment: tools.environment, syncTransport: http)
        let old = try XCTUnwrap(environment.accountModel)
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { self.settingsWindow() != nil })
        window = try firstWindow()
        try selectAccountTab()
        XCTAssertTrue(GTKTestSupport.spin { !old.state.isBusy })
        try loginInputs(password: "runtime-" + UUID().uuidString)
        try click("sign-in")
        XCTAssertTrue(GTKTestSupport.spin { !old.state.isBusy && old.state.enabled })
        drainUI()
        XCTAssertEqual(old.state.secretTier, .file)
        XCTAssertTrue(try label("storage").contains("unencrypted"))
        try click("revoke-" + AccountPageService.device.rawValue)
        XCTAssertTrue(GTKTestSupport.spin { !old.state.isBusy && old.state.connection == nil })
        drainUI()
        XCTAssertFalse(environment.syncService?.report.enabled == true)
        XCTAssertTrue(http.allWorkOffMain)
        XCTAssertEqual(http.loginCount, 1)
        XCTAssertEqual(http.revokeCount, 1)
        try input("password", "old-library-secret")
        let replacement = tools.directory.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let outcome = environment.switchLibrary(to: replacement)
        XCTAssertTrue(outcome == .switched || outcome == .syncDraining, "Unexpected switch result: \(outcome)")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.accountModel !== old && self.environment.syncReplacementIssue == nil })
        let next = try XCTUnwrap(environment.accountModel)
        XCTAssertTrue(GTKTestSupport.spin { !next.state.isBusy })
        drainUI()
        XCTAssertTrue(try inputText("password").isEmpty, "Secure input was not cleared")
        XCTAssertEqual(try label("connection"), LinuxAccountSettingsStrings.signedOut)
        next.clearPasswordInput()
        drainUI()
        XCTAssertEqual(try label("storage"), next.state.secretStorageMessage)
    }

    func testReopeningDuringLibraryDrainCannotBindTheRetiredAccount() throws {
        let http = AccountPageHTTP()
        http.holdLogin = true
        defer { http.releaseLogin() }
        environment.shutdown()
        environment = LinuxEnvironment(application: application, environment: tools.environment, syncTransport: http)
        let old = try XCTUnwrap(environment.accountModel)
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { self.settingsWindow() != nil })
        window = try firstWindow()
        try selectAccountTab()
        XCTAssertTrue(GTKTestSupport.spin { !old.state.isBusy })
        drainUI()
        try loginInputs(password: "runtime-" + UUID().uuidString)
        try click("sign-in")
        XCTAssertTrue(GTKTestSupport.spin { http.hasHeldLogin })
        let replacement = tools.directory.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        XCTAssertEqual(environment.switchLibrary(to: replacement), .syncDraining)
        gtk_window_close(mp_window(window))
        environment.showSettings()
        drainUI()
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(self.window) != 0 })
        XCTAssertEqual(try label("connection"), LinuxAccountSettingsStrings.unavailable)
        XCTAssertFalse(try sensitive("sign-in"))
        http.releaseLogin()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.accountModel !== old && self.environment.syncReplacementIssue == nil })
        let next = try XCTUnwrap(environment.accountModel)
        XCTAssertTrue(GTKTestSupport.spin { !next.state.isBusy })
        drainUI()
        XCTAssertTrue(try inputText("password").isEmpty)
        XCTAssertEqual(try label("storage"), next.state.secretStorageMessage)
        XCTAssertEqual(http.loginCount, 1)
    }

    private func show() throws {
        if view == nil {
            view = LinuxSettingsWindow(application: application, general: environment.generalSettingsModel,
                shortcuts: environment.shortcutsSettingsModel, rememberedValues: environment.rememberedValuesSettingsModel,
                delivery: environment.deliverySettingsModel, updates: environment.updateSettingsModel, session: .otherX11,
                makeAssistant: { nil }, chooser: SettingsFolderChooser(), openSetup: {},
                makeAccount: { [weak self] in self?.model })
        }
        view.show()
        window = try firstWindow()
        try selectAccountTab()
        XCTAssertTrue(GTKTestSupport.spin { !self.model.state.isBusy })
        drainUI()
    }

    private func firstWindow() throws -> GTK.Widget {
        try XCTUnwrap(settingsWindow())
    }

    private func settingsWindow() -> GTK.Widget? {
        var windows = gtk_application_get_windows(application)
        while let node = windows {
            if let data = node.pointee.data {
                let window = data.assumingMemoryBound(to: GtkWindow.self)
                if let title = gtk_window_get_title(window), String(cString: title) == LinuxStrings.settings {
                    return mp_window_widget(window)
                }
            }
            windows = node.pointee.next
        }
        return nil
    }

    private func selectAccountTab() throws {
        let notebook = try settingsWidget("settings-tabs", in: window)
        let page = try control("page")
        let index = gtk_notebook_page_num(mp_notebook(notebook), page)
        XCTAssertGreaterThanOrEqual(index, 0)
        gtk_notebook_set_current_page(mp_notebook(notebook), index)
    }

    private func loginInputs(password: String) throws {
        try input("server", "https://example.test/paw")
        try input("username", "person")
        try input("device-name", "Linux test")
        try input("password", password)
    }

    private func control(_ name: String) throws -> GTK.Widget { try settingsWidget("settings-account-" + name, in: window) }
    private func input(_ name: String, _ text: String) throws { mp_entry_set_text(try control(name), text) }
    private func inputText(_ name: String) throws -> String { String(cString: mp_entry_text(try control(name))) }
    private func label(_ name: String) throws -> String { String(cString: gtk_label_get_text(mp_label(try control(name)))) }
    private func sensitive(_ name: String) throws -> Bool { gtk_widget_is_sensitive(try control(name)) != 0 }
    private func holdLabel(_ index: Int) throws -> String {
        String(cString: gtk_check_button_get_label(mp_check_button(try control("held-\(index)"))))
    }
    private func selectHold(_ index: Int) throws { gtk_check_button_set_active(mp_check_button(try control("held-\(index)")), 1) }

    private func click(_ name: String) throws {
        let button = try control(name)
        var value = GValue()
        g_value_init(&value, gtk_button_get_type())
        g_value_set_object(&value, button)
        g_signal_emitv(&value, g_signal_lookup("clicked", gtk_button_get_type()), 0, nil)
        g_value_unset(&value)
    }

    private func waitIdle() {
        drainUI()
        XCTAssertTrue(GTKTestSupport.spin { !self.model.state.isBusy })
        drainUI()
    }

    private func drainUI() {
        var done = false
        GTK.onMainLoop { done = true }
        XCTAssertTrue(GTKTestSupport.spin { done })
    }

    private func allLabels() throws -> String {
        var labels: [String] = []
        func collect(_ widget: GTK.Widget) {
            if g_type_check_instance_is_a(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self), gtk_label_get_type()) != 0 {
                labels.append(String(cString: gtk_label_get_text(mp_label(widget))))
            }
            var child = gtk_widget_get_first_child(widget)
            while let current = child { collect(current); child = gtk_widget_get_next_sibling(current) }
        }
        collect(try control("page"))
        return labels.joined(separator: "\n")
    }
}

private final class AccountPageFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}

private final class AccountPageService: AccountProviding {
    enum Call: Equatable { case login, startup, refresh, signOut, revoke(ULID), include }
    static let user = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!
    static let otherUser = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAZ")!
    static let device = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAW")!
    static let otherDevice = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAX")!
    static let firstHeld = ULID("01ARZ3NDEKTSV4RRFFQ69G5FB0")!
    static let secondHeld = ULID("01ARZ3NDEKTSV4RRFFQ69G5FB1")!
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var cached = SyncAccountSnapshot()
    private var savedHolds: [SyncHeldPrompt] = []
    private var recorded: [Call] = []
    private var password: SecretValue?
    private var metadata: [String] = []
    private var includedSets: [Set<PromptIdentity>] = []
    private var offMain = true
    private var blocked = false
    var blockNext: Call?
    var failure: SyncAccountIssue?
    var signOutCleanup = SyncAccountCleanup()

    var snapshot: SyncAccountSnapshot {
        get { locked { offMain = offMain && !Thread.isMainThread; return cached } }
        set { locked { cached = newValue } }
    }
    var holds: [SyncHeldPrompt] { get { locked { savedHolds } } set { locked { savedHolds = newValue } } }
    var calls: [Call] { locked { recorded } }
    var included: [Set<PromptIdentity>] { locked { includedSets } }
    var loginMetadata: [String] { locked { metadata } }
    var allWorkOffMain: Bool { locked { offMain } }
    var isBlocked: Bool { locked { blocked } }
    func receivedPassword(_ check: (String) -> Bool) -> Bool { locked { password?.withValue(check) == true } }
    func release() { gate.signal() }

    func login(server: String, username: String, password: inout String, deviceName: String) async throws -> SyncAccountSnapshot {
        locked { self.password = SecretValue(password); metadata = [server, username, deviceName] }
        password = ""
        try perform(.login)
        snapshot = try Self.signedIn()
        return snapshot
    }
    func startup() async throws -> SyncAccountSnapshot { try perform(.startup); return snapshot }
    func refresh() async throws -> SyncAccountSnapshot { try perform(.refresh); return snapshot }
    func revokeDevice(_ id: ULID) async throws -> SyncAccountSnapshot {
        try perform(.revoke(id))
        if id == Self.device { snapshot = SyncAccountSnapshot() }
        else {
            var next = snapshot
            if let me = next.me {
                next.me = SyncAPI.MeResponse(user: me.user, groups: me.groups, devices: me.devices.filter { $0.id != id.rawValue })
            }
            snapshot = next
        }
        return snapshot
    }
    func signOut() async throws -> SyncAccountCleanup {
        try perform(.signOut)
        snapshot = SyncAccountSnapshot()
        return signOutCleanup
    }
    func heldPrompts() throws -> [SyncHeldPrompt] {
        locked { offMain = offMain && !Thread.isMainThread; return savedHolds }
    }
    func includeHeld(_ identities: Set<PromptIdentity>) async throws -> SyncAccountSnapshot {
        try perform(.include)
        locked { savedHolds.removeAll { identities.contains($0.identity) }; includedSets.append(identities) }
        return snapshot
    }
    private func perform(_ call: Call) throws {
        let shouldBlock = locked {
            offMain = offMain && !Thread.isMainThread
            recorded.append(call)
            return blockNext == call
        }
        if shouldBlock {
            locked { blocked = true }
            gate.wait()
            locked { blocked = false; blockNext = nil }
        }
        if let failure { throw SyncAccountServiceError(issue: failure) }
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    static func signedIn(user: ULID = user, tier: SecretTier = .file) throws -> SyncAccountSnapshot {
        let identity = try SyncAccountIdentity(serverURL: "https://example.test/paw", userID: user)
        let account = try SyncAccount(identity: identity, username: "person", deviceID: device,
            deviceName: "Linux", connectionID: UUID())
        let person = SyncAPI.User(id: user.rawValue, username: "person", displayName: nil,
            accountKind: .member, createdAt: "2026-10-14T00:00:00.000Z", disabledAt: nil)
        let devices = [(device, "Linux", true), (otherDevice, "Laptop", false)].map {
            SyncAPI.Device(id: $0.0.rawValue, name: $0.1, createdAt: "2026-10-14T00:00:00.000Z",
                lastSeenAt: nil, revokedAt: nil, isCurrent: $0.2)
        }
        return SyncAccountSnapshot(account: account, me: .init(user: person, groups: [], devices: devices), tier: tier, enabled: true)
    }
    static func hold(path: RelativePath, id: ULID) throws -> SyncHeldPrompt {
        try SyncHeldPrompt(identity: .assigned(id), path: path,
            sourceAccount: SyncAccountIdentity(serverURL: "https://previous.test", userID: otherUser),
            contentHash: SyncHash(bytes: Data("previous content".utf8)))
    }
}

private final class AccountPageHTTP: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var offMain = true
    private var logins = 0
    private var revokes = 0
    private var shouldHoldLogin = false
    private var heldLogin: CheckedContinuation<HTTPResponse, Error>?
    var holdLogin: Bool { get { locked { shouldHoldLogin } } set { locked { shouldHoldLogin = newValue } } }
    var hasHeldLogin: Bool { locked { heldLogin != nil } }
    var allWorkOffMain: Bool { locked { offMain } }
    var loginCount: Int { locked { logins } }
    var revokeCount: Int { locked { revokes } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        locked { offMain = offMain && !Thread.isMainThread }
        let fixture = try AccountPageService.signedIn()
        if request.url.path.hasSuffix("/login") {
            locked { logins += 1 }
            if holdLogin {
                return try await withCheckedThrowingContinuation { continuation in locked { heldLogin = continuation } }
            }
            return try response(SyncAPI.AuthResponse(deviceToken: String(repeating: "a", count: 42) + "A", user: fixture.me!.user))
        }
        if request.url.path.hasSuffix("/me") { return try response(fixture.me!) }
        if request.url.path.hasSuffix("/sync/pull") {
            return try response(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: [
                .init(identity: .user(userID: AccountPageService.user.rawValue), mode: .snapshot, head: 0,
                    cursor: "empty", hasMore: false, items: [])], removed: []))
        }
        if request.method == .delete {
            locked { revokes += 1 }
            return try response(SyncAPI.EmptyResponse())
        }
        throw HTTPTransportError.invalidResponse
    }
    func releaseLogin() {
        let continuation = locked { let value = heldLogin; heldLogin = nil; return value }
        guard let continuation else { return }
        do {
            let fixture = try AccountPageService.signedIn()
            continuation.resume(returning: try response(SyncAPI.AuthResponse(
                deviceToken: String(repeating: "a", count: 42) + "A", user: fixture.me!.user)))
        } catch { continuation.resume(throwing: HTTPTransportError.invalidResponse) }
    }
    private func response<T: APIObjectDTO>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value))
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}
#endif
