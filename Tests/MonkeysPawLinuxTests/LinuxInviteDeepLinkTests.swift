#if os(Linux)
import CGtk
import Foundation
import Glibc
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawLinux

final class LinuxInviteDeepLinkTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var http: InviteHTTP!
    private var window: GTK.Widget!
    private var activation: InviteActivation!
    private let token = String(repeating: "b", count: 42) + "A"

    override func setUpWithError() throws {
        _ = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        http = InviteHTTP()
        environment = LinuxEnvironment(application: application, environment: tools.environment, syncTransport: http)
    }

    override func tearDown() {
        activation?.stop()
        activation = nil
        http?.release()
        if let environment {
            environment.shutdown()
            let done = InviteFlag()
            Task.detached { await environment.drainSync(); done.set() }
            XCTAssertTrue(GTKTestSupport.spin { done.value })
        }
        if let application { GTKTestSupport.destroy(application) }
        environment = nil
        application = nil
        tools = nil
        http = nil
        window = nil
    }

    func testOpeningStagesOnceWithoutHTTPAndRegistrationRequiresExplicitAccept() throws {
        try open(link(server: "https://example.test/paw%20base/a+b"))
        let model = try XCTUnwrap(environment.inviteModel)
        XCTAssertEqual(model.state.destination?.serverURL.absoluteString, "https://example.test/paw%20base/a+b")
        XCTAssertEqual(http.requests.count, 0)
        XCTAssertTrue(try label("destination").contains("https://example.test/paw%20base/a+b"))
        XCTAssertFalse(try sensitive("join"))
        XCTAssertTrue(try sensitive("register"))
        XCTAssertTrue(try text("input").isEmpty, "Invite input was not cleared")
        let password = "password-" + UUID().uuidString
        try input("username", "person")
        try input("password", password)
        try input("device", "Linux invite")
        try click("register")
        try click("register")
        XCTAssertTrue(try text("password").isEmpty, "Secure input was not cleared")
        XCTAssertTrue(GTKTestSupport.spin { model.state.accepted && !model.state.isBusy })
        let registrations = http.requests.filter { $0.url.path.hasSuffix("/register") }
        XCTAssertEqual(registrations.count, 1)
        let request = try XCTUnwrap(registrations.first)
        let body = try JSONDecoder().decode(SyncAPI.RegisterRequest.self, from: try XCTUnwrap(request.body))
        XCTAssertTrue(body.inviteToken == token, "Invite was not preserved")
        XCTAssertTrue(body.password == password, "Password was not preserved")
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertFalse(http.sentOnMain)
        XCTAssertFalse(model.state.canAccept)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.accountModel?.state.enabled == true })
        try assertNoPersistedInvite()
    }

    func testProductionAccountKeepsGroupsVisibleAndRequiresExplicitInviteAcceptance() throws {
        try open(link())
        let invite = try XCTUnwrap(environment.inviteModel)
        let groups = try XCTUnwrap(environment.groupManagementModel)
        let inviteSection = try settingsWidget("settings-invite", in: window)
        let groupsSection = try settingsWidget("settings-groups", in: window)
        let groupRefresh = try settingsWidget("settings-groups-refresh", in: window)
        let groupCreate = try settingsWidget("settings-groups-create", in: window)
        let copyInvite = try settingsWidget("settings-groups-copy-invite", in: window)
        XCTAssertTrue(GTKTestSupport.spin {
            gtk_widget_get_mapped(inviteSection) != 0 && gtk_widget_get_mapped(groupsSection) != 0
                && gtk_widget_is_sensitive(groupRefresh) != 0
        })
        XCTAssertEqual(gtk_widget_is_sensitive(groupCreate), 0)
        XCTAssertEqual(gtk_widget_is_sensitive(copyInvite), 0)
        XCTAssertTrue(invite.state.canAccept)
        XCTAssertTrue(http.requests.isEmpty, "Showing both Account sections must not redeem an invite")

        http.holdRegistration = true
        try input("username", "person")
        try input("password", "coexistence-" + UUID().uuidString)
        try click("register")
        XCTAssertTrue(GTKTestSupport.spin { self.http.isHeld })
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/register") }.count, 1)
        XCTAssertTrue(http.requests.filter { $0.url.path.hasSuffix("/groups/join") }.isEmpty)
        XCTAssertNotEqual(gtk_widget_get_mapped(groupsSection), 0)
        XCTAssertEqual(gtk_widget_is_sensitive(copyInvite), 0)
        http.release()
        XCTAssertTrue(GTKTestSupport.spin { invite.state.accepted && !invite.state.isBusy })
        XCTAssertTrue(GTKTestSupport.spin {
            self.environment.accountModel?.state.enabled == true && groups.state.canCreate
                && gtk_widget_is_sensitive(groupCreate) != 0
        })
        XCTAssertNotEqual(gtk_widget_get_mapped(inviteSection), 0)
        XCTAssertNotEqual(gtk_widget_get_mapped(groupsSection), 0)
        XCTAssertEqual(gtk_widget_is_sensitive(copyInvite), 0)
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/register") }.count, 1)
        XCTAssertTrue(http.requests.filter { $0.url.path.hasSuffix("/groups/join") }.isEmpty)
        try assertNoPersistedInvite()
    }

    func testExistingAccountJoinShowsBindingAndNeverRegistersAutomatically() throws {
        try signIn()
        let before = http.requests.count
        try open(link())
        let model = try XCTUnwrap(environment.inviteModel)
        XCTAssertEqual(http.requests.count, before)
        XCTAssertTrue(try label("destination").contains("person"))
        XCTAssertTrue(try label("destination").contains(InviteHTTP.user))
        XCTAssertTrue(try sensitive("join"))
        try click("join")
        try click("join")
        XCTAssertTrue(GTKTestSupport.spin { model.state.accepted && !model.state.isBusy })
        let joins = http.requests.filter { $0.url.path.hasSuffix("/groups/join") }
        XCTAssertEqual(joins.count, 1)
        let body = try JSONDecoder().decode(SyncAPI.JoinGroupRequest.self, from: try XCTUnwrap(joins.first?.body))
        XCTAssertTrue(body.inviteToken == token, "Invite was not preserved")
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/register") }.count, 0)
        XCTAssertNotNil(joins.first?.headers["Authorization"])
        try assertNoPersistedInvite()
    }

    func testWrongServerDisablesJoinAndAccountChangeRevokesStaging() throws {
        try signIn()
        try open(link(server: "https://other.test/paw"))
        XCTAssertFalse(try sensitive("join"))
        let before = http.requests.count
        try click("join")
        drainUI()
        XCTAssertEqual(http.requests.count, before)
        let account = try XCTUnwrap(environment.accountModel)
        account.signOut()
        XCTAssertTrue(GTKTestSupport.spin { !account.state.isBusy && account.state.connection == nil })
        XCTAssertTrue(GTKTestSupport.spin { self.environment.inviteModel?.state.destination == nil })
        XCTAssertFalse(try sensitive("register"))
        XCTAssertFalse(environment.inviteModel?.state.canAccept == true)
    }

    func testInviteReopensAccountAfterClosingOnGeneralTab() throws {
        try open(link())
        let first = try XCTUnwrap(window)
        let notebook = try settingsWidget("settings-tabs", in: first)
        let account = try settingsWidget("settings-account-page", in: first)
        let page = gtk_notebook_page_num(mp_notebook(notebook), account)
        XCTAssertGreaterThanOrEqual(page, 0)
        gtk_notebook_set_current_page(mp_notebook(notebook), 0)
        gtk_window_close(mp_window(first))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(first) == 0 })
        XCTAssertNotEqual(gtk_widget_get_visible(account), 0)

        try open(link())

        XCTAssertEqual(window, first)
        XCTAssertEqual(gtk_notebook_get_current_page(mp_notebook(notebook)), page)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_mapped(account) != 0 })
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testDestroyedAccountPageConsumesInviteWithoutStaging() throws {
        let model = try XCTUnwrap(environment.inviteModel)
        let page = LinuxAccountSettingsPage(makeModel: { self.environment.accountModel }, makeInvite: { model })
        let parent = try XCTUnwrap(gtk_application_window_new(application))
        gtk_window_set_child(mp_window(parent), page.widget)
        page.show()
        page.retire(.destroyed)
        gtk_window_destroy(mp_window(parent))

        var supplied = link()
        page.stageInvite(&supplied)
        drainUI()

        XCTAssertTrue(supplied.isEmpty, "Destroyed Account page did not consume invite input")
        XCTAssertNil(model.state.destination)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testBareTokenNeedsExplicitServerAndHTTPWarningIsVisible() throws {
        environment.showInviteSettings()
        try findWindow()
        try input("input", token)
        try click("stage")
        let model = try XCTUnwrap(environment.inviteModel)
        XCTAssertTrue(GTKTestSupport.spin { model.state.error == .serverRequired && !model.state.isBusy })
        XCTAssertTrue(try text("input").isEmpty, "Invite input was not cleared")
        drainUI()
        try input("input", token)
        try input("server", "http://192.168.1.2/paw")
        try click("stage")
        XCTAssertTrue(GTKTestSupport.spin { model.state.canAccept })
        drainUI()
        XCTAssertTrue(try label("warning").contains("unencrypted HTTP"))
        XCTAssertEqual(http.requests.count, 0)
    }

    func testHideTabCloseAndRetiredGraphClearInputsAndLateResults() throws {
        try open(link())
        let model = try XCTUnwrap(environment.inviteModel)
        try input("input", token)
        try input("password", "hidden-" + UUID().uuidString)
        let notebook = try settingsWidget("settings-tabs", in: window)
        gtk_notebook_set_current_page(mp_notebook(notebook), 0)
        XCTAssertTrue(GTKTestSupport.spin { model.state.destination == nil })
        XCTAssertTrue(try text("input").isEmpty, "Invite input was not cleared")
        XCTAssertTrue(try text("password").isEmpty, "Secure input was not cleared")
        try open(link())
        http.holdRegistration = true
        try input("username", "person")
        try input("password", "password-" + UUID().uuidString)
        try click("register")
        XCTAssertTrue(GTKTestSupport.spin { self.http.isHeld })
        var heartbeat = false
        GTK.onMainLoop { heartbeat = true }
        XCTAssertTrue(GTKTestSupport.spin { heartbeat })
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(self.window) == 0 })
        http.release()
        XCTAssertTrue(GTKTestSupport.spin { !model.state.isBusy })
        XCTAssertNil(model.state.destination)
        XCTAssertFalse(model.state.accepted)
        environment.showInviteSettings()
        drainUI()
        XCTAssertTrue(try text("password").isEmpty, "Secure input was not cleared")
        XCTAssertFalse(try sensitive("register"))
        let replacement = tools.directory.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let outcome = environment.switchLibrary(to: replacement)
        XCTAssertTrue(outcome == .switched || outcome == .syncDraining)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.inviteModel !== model && self.environment.syncReplacementIssue == nil })
        XCTAssertNil(environment.inviteModel?.state.destination)
    }

    func testInvalidAndDoubleEncodedLinksFailWithoutRequests() throws {
        for supplied in ["monkeyspaw://join?server=https%253A%252F%252Fexample.test&token=" + token,
                         "monkeyspaw://join?server=https%3A%2F%2Fexample.test&token=%2541" + String(token.dropFirst())] {
            var input = supplied
            environment.openInvite(&input)
            XCTAssertTrue(input.isEmpty, "Invite input was not consumed")
            try findWindow()
            XCTAssertTrue(GTKTestSupport.spin { self.environment.inviteModel?.state.error == .invalidLink })
            XCTAssertFalse(try sensitive("register"))
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testGApplicationOpenPreservesEscapingForCoresSingleDecode() throws {
        let flags = GApplicationFlags(rawValue: G_APPLICATION_NON_UNIQUE.rawValue | G_APPLICATION_HANDLES_OPEN.rawValue)
        let app = try XCTUnwrap(gtk_application_new("ch.lkmc.monkeyspaw.tests.inviteOpen", flags))
        defer { g_object_unref(app) }
        let supplied = link(server: "https://example.test/paw%20base/a+b")
        GTK.onOpen(app) { [weak self] uri in
            XCTAssertTrue(uri == supplied, "GApplication changed the URI's escaping")
            var input = uri
            self?.environment.openInvite(&input)
        }
        XCTAssertNotEqual(g_application_register(mp_gapp(app), nil, nil), 0)
        mp_application_open_uri(mp_gapp(app), supplied)
        try findWindow()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.inviteModel?.state.canAccept == true })
        XCTAssertEqual(environment.inviteModel?.state.destination?.serverURL.absoluteString, "https://example.test/paw%20base/a+b")
        XCTAssertTrue(http.requests.isEmpty)
        // Run performs GApplication's normal unregister cleanup.
        let stop: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gint = { _, _, _ in 0 }
        mp_connect(app, "handle-local-options", unsafeBitCast(stop, to: GCallback.self), nil, nil)
        XCTAssertEqual(g_application_run(mp_gapp(app), 0, nil), 0)
    }

    func testOnboardingInviteButtonReusesAccountAndDestroyClearsNativeSecrets() throws {
        environment.settingsModel.markSetupPresented()
        environment.presentFromLauncher(source: "invite-test")
        var onboarding: GTK.Widget?
        XCTAssertTrue(GTKTestSupport.spin {
            var node = gtk_application_get_windows(self.application)
            while let current = node {
                if let data = current.pointee.data {
                    let candidate = data.assumingMemoryBound(to: GtkWindow.self)
                    if let title = gtk_window_get_title(candidate), String(cString: title) == LinuxStrings.onboarding {
                        onboarding = mp_window_widget(candidate)
                        return true
                    }
                }
                node = current.pointee.next
            }
            return false
        })
        let button = try settingsWidget("onboarding-invite", in: XCTUnwrap(onboarding))
        emitClick(button)
        try findWindow()
        let first = try XCTUnwrap(window)
        XCTAssertEqual(gtk_widget_get_visible(try XCTUnwrap(onboarding)), 0)
        try open(link())
        XCTAssertEqual(window, first)
        let input = try control("input"), password = try control("password")
        for field in [input, password] {
            XCTAssertNotEqual(g_type_check_instance_is_a(UnsafeMutableRawPointer(field).assumingMemoryBound(to: GTypeInstance.self),
                gtk_password_entry_get_type()), 0)
            g_object_ref(field)
        }
        defer { for field in [input, password] { g_object_unref(field) } }
        mp_entry_set_text(input, token)
        mp_entry_set_text(password, "destroy-" + UUID().uuidString)
        gtk_window_destroy(mp_window(window))
        XCTAssertTrue(String(cString: mp_entry_text(input)).isEmpty, "Invite input was not cleared")
        XCTAssertTrue(String(cString: mp_entry_text(password)).isEmpty, "Secure input was not cleared")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.inviteModel?.state.destination == nil })
    }

    func testColdAndResidentDBusOpenUseOnePrimaryWithoutPickerToggleOrURILogging() throws {
        activation = try InviteActivation(root: tools.directory)
        XCTAssertNil(activation.ownerPID())
        try activation.open(link())
        let pid = try XCTUnwrap(activation.ownerPID())
        let first = try activation.waitForSettings(pid: pid)
        try activation.open(link(server: "https://example.test/other%20base/a+b"))
        XCTAssertEqual(activation.ownerPID(), pid)
        XCTAssertEqual(try activation.waitForSettings(pid: pid), first)
        try activation.assertNoPicker(pid: pid)
        try activation.assertPrivate(token: token, link: link())
        XCTAssertEqual(activation.trace.components(separatedBy: "application.startup").count - 1, 1)
        XCTAssertEqual(activation.trace.components(separatedBy: "source=open").count - 1, 2)
        XCTAssertFalse(activation.trace.contains("toggle.dispatch"))
    }

    func testPercentUCLIFallbackPreservesURIAndForwardsToServicePrimary() throws {
        activation = try InviteActivation(root: tools.directory)
        let child = try activation.launch(["--gapplication-service"])
        XCTAssertTrue(GTKTestSupport.spin { self.activation.ownerPID() != nil })
        let pid = try XCTUnwrap(activation.ownerPID())
        XCTAssertEqual(pid, child.processIdentifier)
        XCTAssertNil(try activation.visibleSettings(pid: pid))
        let remote = try activation.launch([link(server: "https://example.test/paw%20base/a+b")])
        XCTAssertTrue(GTKTestSupport.spin(until: { !remote.isRunning }, timeout: .seconds(15)))
        XCTAssertEqual(remote.terminationStatus, 0)
        _ = try activation.waitForSettings(pid: pid)
        XCTAssertEqual(activation.ownerPID(), pid)
        try activation.assertNoPicker(pid: pid)
        try activation.assertPrivate(token: token, link: link(server: "https://example.test/paw%20base/a+b"))
        XCTAssertEqual(activation.trace.components(separatedBy: "application.startup").count - 1, 1)
        XCTAssertFalse(activation.trace.contains("toggle.dispatch"))
    }

    func testColdCLIFallbackOpensAccountWithoutOnboardingOrPicker() throws {
        activation = try InviteActivation(root: tools.directory)
        let child = try activation.launch([link()])
        XCTAssertTrue(GTKTestSupport.spin { self.activation.ownerPID() != nil })
        XCTAssertEqual(activation.ownerPID(), child.processIdentifier)
        _ = try activation.waitForSettings(pid: child.processIdentifier)
        try activation.assertNoPicker(pid: child.processIdentifier)
        try activation.assertPrivate(token: token, link: link())
    }

    func testStoppingAfterPrimaryExitDoesNotReactivateService() throws {
        activation = try InviteActivation(root: tools.directory)
        let child = try activation.launch([link()])
        XCTAssertTrue(GTKTestSupport.spin { self.activation.ownerPID() == child.processIdentifier })
        _ = try activation.waitForSettings(pid: child.processIdentifier)
        kill(child.processIdentifier, SIGKILL)
        XCTAssertTrue(GTKTestSupport.spin { !child.isRunning && self.activation.ownerPID() == nil })

        activation.stop()

        XCTAssertEqual(activation.trace.components(separatedBy: "application.startup").count - 1, 1,
            "Teardown activated a replacement primary")
    }

    func testActivationUsesExecutableBesideCurrentTestBuild() throws {
        let build = tools.directory.appendingPathComponent("custom-build/release")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let binary = build.appendingPathComponent("monkeyspaw")
        try Data("#!/bin/sh\nexit 23\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        activation = try InviteActivation(root: tools.directory,
            testExecutable: build.appendingPathComponent("MonkeysPawPackageTests.xctest"))

        let child = try activation.launch(["--version"])
        XCTAssertTrue(GTKTestSupport.spin { !child.isRunning })

        XCTAssertEqual(child.terminationStatus, 23, "Activation launched a binary from another build")
        XCTAssertEqual(child.executableURL, binary)
    }

    func testMissingWindowInspectionToolFailsNegativeAssertion() throws {
        let daemon = try XCTUnwrap(LinuxToolRunner().executable("dbus-daemon"))
        try FileManager.default.createSymbolicLink(at: tools.directory.appendingPathComponent("dbus-daemon"),
            withDestinationURL: daemon)
        activation = try InviteActivation(root: tools.directory, toolRunner: tools.runner)

        XCTAssertThrowsError(try activation.assertNoPicker(pid: getpid()))
    }

    func testDesktopHandlerAndServiceKeepSharedIdentity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let desktop = try String(contentsOf: root.appendingPathComponent("packaging/linux/ch.lkmc.monkeyspaw.desktop"), encoding: .utf8)
        let service = try String(contentsOf: root.appendingPathComponent("packaging/linux/ch.lkmc.monkeyspaw.service"), encoding: .utf8)
        for line in ["Exec=monkeyspaw %u", "MimeType=x-scheme-handler/monkeyspaw;", "DBusActivatable=true",
                     "StartupWMClass=" + AppIdentity.linuxAppID] {
            XCTAssertTrue(desktop.split(separator: "\n").contains(Substring(line)))
        }
        XCTAssertTrue(service.contains("Name=" + AppIdentity.linuxAppID + "\n"))
        XCTAssertTrue(service.contains("Exec=/usr/bin/monkeyspaw --gapplication-service"))
    }

    private func link(server: String = "https://example.test/paw") -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return "monkeyspaw://join?server=" + server.addingPercentEncoding(withAllowedCharacters: allowed)! + "&token=" + token
    }

    private func open(_ uri: String) throws {
        var input = uri
        environment.openInvite(&input)
        XCTAssertTrue(input.isEmpty, "Invite input was not consumed")
        try findWindow()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.inviteModel?.state.canAccept == true })
        drainUI()
    }

    private func signIn() throws {
        let model = try XCTUnwrap(environment.accountModel)
        XCTAssertTrue(GTKTestSupport.spin { !model.state.isBusy })
        var password = "password-" + UUID().uuidString
        model.login(server: "https://example.test/paw", username: "person", password: &password, deviceName: "Linux")
        XCTAssertTrue(GTKTestSupport.spin { model.state.enabled && !model.state.isBusy })
        environment.syncService?.stop()
        let done = InviteFlag()
        let sync = environment.syncService
        Task.detached { await sync?.drain(); done.set() }
        XCTAssertTrue(GTKTestSupport.spin { done.value })
    }

    private func findWindow() throws {
        XCTAssertTrue(GTKTestSupport.spin {
            var node = gtk_application_get_windows(self.application)
            while let current = node {
                if let data = current.pointee.data {
                    let candidate = data.assumingMemoryBound(to: GtkWindow.self)
                    if let title = gtk_window_get_title(candidate), String(cString: title) == LinuxStrings.settings {
                        self.window = mp_window_widget(candidate)
                        return true
                    }
                }
                node = current.pointee.next
            }
            return false
        })
        _ = try XCTUnwrap(window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.accountModel?.state.isBusy == false })
        drainUI()
    }

    private func control(_ name: String) throws -> GTK.Widget { try settingsWidget("settings-invite-" + name, in: window) }
    private func input(_ name: String, _ value: String) throws { mp_entry_set_text(try control(name), value) }
    private func text(_ name: String) throws -> String { String(cString: mp_entry_text(try control(name))) }
    private func label(_ name: String) throws -> String { String(cString: gtk_label_get_text(mp_label(try control(name)))) }
    private func sensitive(_ name: String) throws -> Bool { gtk_widget_is_sensitive(try control(name)) != 0 }
    private func click(_ name: String) throws {
        emitClick(try control(name))
    }
    private func emitClick(_ button: GTK.Widget) {
        var value = GValue()
        g_value_init(&value, gtk_button_get_type())
        g_value_set_object(&value, button)
        g_signal_emitv(&value, g_signal_lookup("clicked", gtk_button_get_type()), 0, nil)
        g_value_unset(&value)
    }
    private func drainUI() {
        var done = false
        GTK.onMainLoop { done = true }
        XCTAssertTrue(GTKTestSupport.spin { done })
    }
    private func assertNoPersistedInvite() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: tools.directory, includingPropertiesForKeys: nil))
        for case let file as URL in enumerator {
            guard let bytes = try? Data(contentsOf: file) else { continue }
            XCTAssertFalse(bytes.range(of: Data(token.utf8)) != nil, "Invite was persisted")
            XCTAssertFalse(bytes.range(of: Data(link().utf8)) != nil, "Invite link was persisted")
        }
    }
}

private final class InviteFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}

private final class InviteHTTP: HTTPTransporting, @unchecked Sendable {
    static let user = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    static let device = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
    static let group = "01ARZ3NDEKTSV4RRFFQ69G5FAX"
    private let lock = NSLock()
    private var captured: [HTTPRequest] = []
    private var main = false
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var shouldHold = false
    var holdRegistration: Bool { get { locked { shouldHold } } set { locked { shouldHold = newValue } } }
    var requests: [HTTPRequest] { locked { captured } }
    var sentOnMain: Bool { locked { main } }
    var isHeld: Bool { locked { continuation != nil } }
    private let date = "2026-10-15T00:00:00.000Z"
    private var user: SyncAPI.User {
        .init(id: Self.user, username: "person", displayName: nil, accountKind: .member, createdAt: date, disabledAt: nil)
    }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        locked { captured.append(request); main = main || Thread.isMainThread }
        if request.url.path.hasSuffix("/register"), holdRegistration {
            return try await withCheckedThrowingContinuation { next in locked { continuation = next } }
        }
        if request.url.path.hasSuffix("/register") || request.url.path.hasSuffix("/login") { return try auth() }
        if request.url.path.hasSuffix("/me") {
            return try response(SyncAPI.MeResponse(user: user, groups: [], devices: [
                .init(id: Self.device, name: "Linux", createdAt: date, lastSeenAt: nil, revokedAt: nil, isCurrent: true)]))
        }
        if request.url.path.hasSuffix("/groups/join") {
            return try response(SyncAPI.GroupMembership(groupID: Self.group, name: "Team", role: .viewer))
        }
        if request.url.path.hasSuffix("/sync/pull") {
            return try response(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: [
                .init(identity: .user(userID: Self.user), mode: .snapshot, head: 0, cursor: "empty", hasMore: false, items: [])], removed: []))
        }
        return try response(SyncAPI.EmptyResponse())
    }
    func release() {
        let next = locked { let value = continuation; continuation = nil; return value }
        guard let next else { return }
        do { next.resume(returning: try auth()) }
        catch { next.resume(throwing: HTTPTransportError.invalidResponse) }
    }
    private func auth() throws -> HTTPResponse { try response(SyncAPI.AuthResponse(deviceToken: String(repeating: "a", count: 42) + "A", user: user)) }
    private func response<T: APIObjectDTO>(_ value: T) throws -> HTTPResponse { HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value)) }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

/// A separate private bus owns the real desktop identity and activates the
/// executable from an actual service file. All diagnostics stay in memory.
private final class InviteActivation {
    private let directory: URL
    private let daemon = Process()
    private let capture = InviteCapture()
    private var children: [Process] = []
    private let runner: LinuxToolRunner
    private let binary: URL
    private var environment: [String: String]
    var trace: String { capture.text }

    init(root: URL, testExecutable: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
         toolRunner: LinuxToolRunner? = nil) throws {
        directory = root.appendingPathComponent("activation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        binary = testExecutable.deletingLastPathComponent().appendingPathComponent("monkeyspaw")
        environment = ProcessInfo.processInfo.environment
        if let libraries = environment["MONKEYSPAW_HOST_X11_LIBRARIES"] { environment["LD_LIBRARY_PATH"] = libraries }
        runner = toolRunner ?? LinuxToolRunner(environment: environment)
        let address = "unix:path=" + directory.appendingPathComponent("socket").path
        environment["DBUS_SESSION_BUS_ADDRESS"] = address
        environment["HOME"] = directory.path
        environment["XDG_CONFIG_HOME"] = directory.appendingPathComponent("config").path
        environment["XDG_DATA_HOME"] = directory.appendingPathComponent("data").path
        environment["PATH"] = directory.path
        environment["XDG_CURRENT_DESKTOP"] = "sway"
        environment["XDG_SESSION_TYPE"] = "wayland"
        environment["GDK_BACKEND"] = "x11"
        environment["MONKEYSPAW_TEST_PICKER_TRACE"] = "1"
        let serviceDirectory = directory.appendingPathComponent("services")
        try FileManager.default.createDirectory(at: serviceDirectory, withIntermediateDirectories: true)
        let service = "[D-BUS Service]\nName=ch.lkmc.monkeyspaw\nExec=\(binary.path) --gapplication-service\n"
        try Data(service.utf8).write(to: serviceDirectory.appendingPathComponent("ch.lkmc.monkeyspaw.service"))
        let config = """
            <busconfig><type>session</type><listen>\(address)</listen>
            <servicedir>\(serviceDirectory.path)</servicedir>
            <policy context="default"><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/></policy></busconfig>
            """
        let configFile = directory.appendingPathComponent("bus.conf")
        try Data(config.utf8).write(to: configFile)
        daemon.executableURL = try XCTUnwrap(runner.executable("dbus-daemon"))
        daemon.arguments = ["--nofork", "--config-file=" + configFile.path]
        daemon.environment = environment
        daemon.standardInput = FileHandle.nullDevice
        daemon.standardOutput = capture.pipe.fileHandleForWriting
        daemon.standardError = capture.pipe.fileHandleForWriting
        do {
            try daemon.run()
            XCTAssertTrue(GTKTestSupport.spin { FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("socket").path) })
        } catch { stop(); throw error }
    }

    deinit { stop() }

    func launch(_ arguments: [String]) throws -> Process {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), "Build the Linux app before executable tests")
        let child = Process()
        child.executableURL = binary
        child.arguments = arguments
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = capture.pipe.fileHandleForWriting
        child.standardError = capture.pipe.fileHandleForWriting
        try child.run()
        children.append(child)
        return child
    }

    func open(_ uri: String) throws {
        _ = try call(["--dest", "ch.lkmc.monkeyspaw", "--object-path", "/ch/lkmc/monkeyspaw",
                      "--method", "org.freedesktop.Application.Open", "['" + uri + "']", "{}"])
    }

    func ownerPID(_ name: String = AppIdentity.linuxAppID) -> Int32? {
        guard let reply = try? call(["--dest", "org.freedesktop.DBus", "--object-path", "/org/freedesktop/DBus",
                                    "--method", "org.freedesktop.DBus.GetConnectionUnixProcessID", name]) else { return nil }
        return reply.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int32($0) }
    }

    func visibleSettings(pid: Int32) throws -> String? { try visible(title: LinuxStrings.settings, pid: pid).first }

    func waitForSettings(pid: Int32) throws -> String {
        XCTAssertTrue(GTKTestSupport.spin(until: { (try? self.visibleSettings(pid: pid)) != nil }, timeout: .seconds(15)))
        let windows = try visible(title: LinuxStrings.settings, pid: pid)
        XCTAssertEqual(windows.count, 1, "Invite activation created another Settings window")
        return try XCTUnwrap(windows.first)
    }

    func assertNoPicker(pid: Int32) throws {
        for title in [AppIdentity.displayName, LinuxStrings.onboarding, LinuxStrings.setup] {
            let windows = try visible(title: title, pid: pid)
            XCTAssertTrue(windows.isEmpty, "Invite activation opened another surface")
        }
    }

    func assertPrivate(token: String, link: String) throws {
        XCTAssertFalse(capture.truncated, "Diagnostic capture exceeded the privacy-check bound")
        XCTAssertFalse(trace.contains(token), "A diagnostic contains invite bearer bytes")
        XCTAssertFalse(trace.contains(link), "A diagnostic contains a full invite link")
        XCTAssertFalse(trace.contains("argv="), "Activation logged argv")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        for case let file as URL in files {
            guard let bytes = try? Data(contentsOf: file) else { continue }
            XCTAssertNil(bytes.range(of: Data(token.utf8)), "An invite was written to disk")
        }
    }

    func stop() {
        if daemon.isRunning,
           let reply = try? call(["--dest", "org.freedesktop.DBus", "--object-path", "/org/freedesktop/DBus",
                                  "--method", "org.freedesktop.DBus.GetNameOwner", AppIdentity.linuxAppID]),
           let name = reply.split(separator: "'").dropFirst().first, name.hasPrefix(":") {
            // A unique bus name cannot activate a replacement after its owner exits.
            let owner = String(name)
            let pid = ownerPID(owner)
            _ = try? call(["--dest", owner, "--object-path", "/ch/lkmc/monkeyspaw",
                           "--method", "org.gtk.Actions.Activate", "quit", "[]", "{}"])
            if let pid, !GTKTestSupport.spin(until: { self.ownerPID(owner) == nil }, timeout: .seconds(5)),
               ownerPID(owner) == pid { kill(pid, SIGKILL) }
        }
        for child in children {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            _ = GTKTestSupport.spin(until: { !child.isRunning }, timeout: .seconds(2))
        }
        children.removeAll()
        if daemon.isRunning { daemon.terminate() }
        _ = GTKTestSupport.spin(until: { !daemon.isRunning }, timeout: .seconds(2))
        if daemon.isRunning { kill(daemon.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func call(_ arguments: [String]) throws -> String {
        guard case .success(let output) = runner.run("gdbus", arguments: ["call", "--session"] + arguments,
            timeout: .seconds(15), environmentOverrides: ["DBUS_SESSION_BUS_ADDRESS": environment["DBUS_SESSION_BUS_ADDRESS"]!]) else {
            throw NSError(domain: "LinuxInviteActivation", code: 1)
        }
        return output.text
    }

    private func visible(title: String, pid: Int32) throws -> [String] {
        let output = try runner.run("xdotool", arguments: ["search", "--onlyvisible", "--all",
            "--pid", String(pid), "--name", "^" + NSRegularExpression.escapedPattern(for: title) + "$"],
            timeout: .seconds(1), acceptedStatuses: [0, 1]).get()
        return output.text.split(separator: "\n").map(String.init)
    }
}

private final class InviteCapture {
    let pipe = Pipe()
    private let lock = NSLock()
    private var bytes = Data()
    private var overflow = false
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard let self else { return }
            self.lock.lock()
            self.bytes.append(data)
            if self.bytes.count > 256 * 1_024 {
                self.overflow = true
                self.bytes.removeFirst(self.bytes.count - 256 * 1_024)
            }
            self.lock.unlock()
        }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    deinit {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
    }
}
#endif
