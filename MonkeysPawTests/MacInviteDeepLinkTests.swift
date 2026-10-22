import AppKit
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

/// Hosted routing and native secure controls, with isolated roots and no real
/// server, Keychain access, paste injection or LaunchServices registration.
final class MacInviteDeepLinkTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var delegate: AppDelegate!
    private var transport: MacInviteHTTP!
    private var secrets: MacInviteSecrets!
    private var clipboard: MacInviteClipboard!
    private var token = ""
    private var originalWindows: Set<ObjectIdentifier> = []
    private var terminationReplies: [Bool] = []

    override func setUpWithError() throws {
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library", isDirectory: true)
        data = directory.appendingPathComponent("data", isDirectory: true)
        transport = MacInviteHTTP()
        secrets = MacInviteSecrets()
        clipboard = MacInviteClipboard()
        token = Data(try SystemEntropy().bytes(count: 32)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        makeDelegate()
    }

    override func tearDown() {
        stopDelegate()
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        delegate = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testBuiltDebugPlistKeepsSchemeAccessoryAndVersionKeys() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let types = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        XCTAssertTrue(types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("monkeyspaw") == true })
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
        for key in ["CFBundleVersion", "CFBundleShortVersionString"] {
            let value = try XCTUnwrap(info[key] as? String)
            XCTAssertFalse(value.isEmpty)
            XCTAssertFalse(value.contains("$("), "Built versions must resolve build settings")
        }
    }

    func testURLBeforeStartupWaitsForCompositionAndOnlyStages() throws {
        route(link())
        XCTAssertNil(delegate.settingsWindow)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), originalWindows)
        start()
        let view = try stagedView()
        XCTAssertEqual(delegate.settingsWindow?.presentation.selectedTab, .account)
        XCTAssertTrue(view.state?.destination?.serverURL.absoluteString == "https://example.test/paw")
        XCTAssertNil(view.state?.destination?.currentAccount)
        XCTAssertFalse(view.canJoin)
        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertEqual(secrets.readCount, 0)
        XCTAssertEqual(delegate.pickerModel?.state, .closed)
        XCTAssertEqual(clipboard.writes, 0)
    }

    func testResidentURLsReuseAccountWindowAndReopenTheClosedWindow() throws {
        start()
        delegate.showSettings()
        let controller = try XCTUnwrap(delegate.settingsWindow)
        let window = try XCTUnwrap(controller.window)
        route(link())
        let original = try stagedView()
        route(link(server: "https://resident.test/paw"))
        XCTAssertFalse(original.canAccept, "A replacement URL must revoke the old invitation before the queued stage")
        let replacement = try stagedView()
        XCTAssertTrue(replacement.state?.destination?.serverURL.absoluteString == "https://resident.test/paw")
        XCTAssertTrue(controller.window === window)
        window.close()
        route(link(server: "https://other.test/team"))
        let view = try stagedView()
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(view.state?.destination?.serverURL.absoluteString == "https://other.test/team")
        XCTAssertEqual(transport.redemptions, 0)
        XCTAssertEqual(window.title, SettingsAccountStrings.tab)
        XCTAssertEqual(NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) && $0 === window }.count, 1)
    }

    func testColdLinkWithSavedAccountSurvivesInitialConnectionPublication() throws {
        start()
        try login()
        stopDelegate()
        delegate.settingsWindow?.window?.close()
        makeDelegate()
        route(link())
        start()
        delegate.startSync() // Preserve the failing hosted route-before-startup order.
        let view = try stagedView()
        XCTAssertTrue(Thread.isMainThread, "Capture cold invite readiness in one UI turn")
        let diagnostic = coldInviteDiagnostic(view)
        XCTAssertTrue(view.state?.destination?.currentAccount?.userID == MacInviteHTTP.userID)
        XCTAssertTrue(view.canJoin, diagnostic)
        XCTAssertEqual(transport.redemptions, 0)
        let attachment = XCTAttachment(string: diagnostic)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testURLTextReachesCoreWithoutAnExtraPercentDecode() throws {
        start()
        let server = "https://example.test/paw%20space/a+b"
        route(link(server: server))
        let view = try stagedView()
        XCTAssertTrue(view.state?.destination?.serverURL.absoluteString == server)
        route("monkeyspaw://join?server=https%253A%252F%252Fexample.test&token=" + token)
        XCTAssertTrue(spin { view.state?.error == .invalidLink })
        XCTAssertFalse(view.canAccept)
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testPastedBareTokenRequiresExplicitServerAndShowsHTTPWarning() throws {
        start()
        let view = try openAccount()
        let field = try secureField(SettingsInviteStrings.input)
        field.stringValue = token
        view.reviewInput()
        XCTAssertTrue(field.stringValue.isEmpty)
        XCTAssertTrue(spin { view.state?.error == .serverRequired })
        view.server = "http://127.0.0.1:8080/paw"
        field.stringValue = token
        view.reviewInput()
        XCTAssertTrue(spin { view.canAccept })
        XCTAssertTrue(view.state?.destination?.usesHTTP == true)
        XCTAssertTrue(view.state?.destination?.serverURL.absoluteString == view.server)
        // A full link always binds its own server, ignoring the bare-token field.
        field.stringValue = link()
        view.reviewInput()
        XCTAssertTrue(spin { view.canAccept })
        XCTAssertTrue(view.state?.destination?.serverURL.absoluteString == "https://example.test/paw")
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testExplicitRegistrationConsumesSecureInputAndCannotDuplicate() throws {
        start()
        let uri = link()
        route(uri)
        let view = try stagedView()
        let field = try secureField(SettingsInviteStrings.password)
        let password = "Runtime-password-" + UUID().uuidString
        view.username = "person"
        field.stringValue = password
        transport.holdSuffix = "/register"
        view.register()
        XCTAssertTrue(field.stringValue.isEmpty)
        XCTAssertTrue(field.currentEditor()?.string.isEmpty ?? true)
        XCTAssertTrue(spin { self.transport.heldCount == 1 })
        XCTAssertFalse(view.canAccept)
        field.stringValue = "rejected-input"
        view.register()
        view.join()
        XCTAssertTrue(field.stringValue.isEmpty)
        XCTAssertEqual(transport.registerCount, 1)
        transport.release()
        XCTAssertTrue(spin { view.state?.accepted == true && view.canOperate })
        XCTAssertTrue(delegate.accountModel?.state.enabled == true)
        XCTAssertFalse(view.canAccept)
        XCTAssertFalse(transport.registerHadAuthorization)
        XCTAssertTrue(transport.allWorkOffMain)
        XCTAssertTrue(secrets.allWorkOffMain)
        XCTAssertEqual(clipboard.writes, 0)
        try assertPrivate([token, uri, password])
    }

    func testCurrentAccountJoinRequiresExplicitAcceptanceAndUsesItsServer() throws {
        start()
        try login()
        route(link())
        let view = try stagedView()
        XCTAssertTrue(view.canJoin)
        XCTAssertTrue(view.state?.destination?.currentAccount?.userID == MacInviteHTTP.userID)
        XCTAssertEqual(transport.redemptions, 0)
        transport.holdSuffix = "/groups/join"
        view.join()
        view.join()
        XCTAssertTrue(spin { self.transport.heldCount == 1 })
        XCTAssertEqual(transport.joinCount, 1)
        transport.release()
        XCTAssertTrue(spin { view.state?.accepted == true && view.canOperate })
        XCTAssertTrue(transport.joinHadAuthorization)
        XCTAssertFalse(transport.foreignAuthorization)
        XCTAssertTrue(delegate.accountModel?.state.groups.contains { $0.groupID == MacInviteHTTP.groupID.rawValue } == true)
        XCTAssertFalse(view.canAccept)
    }

    func testWrongServerIsDisabledAndCoreRefusesWithoutSendingCredentials() throws {
        start()
        try login()
        route(link(server: "https://other.test/paw"))
        let view = try stagedView()
        XCTAssertFalse(view.canJoin)
        view.join()
        XCTAssertEqual(transport.redemptions, 0)
        // Exercise the service guard as well as the native disabled control.
        var password = ""
        delegate.inviteModel?.accept(as: .existingAccount, password: &password)
        XCTAssertTrue(spin { view.state?.error == .wrongServer })
        XCTAssertEqual(transport.redemptions, 0)
        XCTAssertFalse(transport.foreignAuthorization)
    }

    func testAccountChangeClearsStagedInviteAndNativeDrafts() throws {
        start()
        try login()
        route(link())
        let view = try stagedView()
        let field = try secureField(SettingsInviteStrings.password)
        field.stringValue = "discarded-input"
        transport.user = MacInviteHTTP.otherUserID
        try login()
        XCTAssertTrue(spin { !view.canAccept && view.state?.isBusy == false })
        XCTAssertTrue(field.stringValue.isEmpty)
        view.join()
        XCTAssertEqual(transport.redemptions, 0)
    }

    func testSameUserReauthenticationStillRejectsTheOldConnection() throws {
        start()
        try login()
        route(link())
        let view = try stagedView()
        try login()
        view.join()
        XCTAssertTrue(spin { view.state?.error == .accountChanged })
        XCTAssertEqual(transport.redemptions, 0)
    }

    func testCrossServerRegistrationHoldsOldFilesAndDoesNotForwardTheOldBearer() throws {
        start()
        try login()
        let files = try RootedFileStore(root: root)
        try files.write(Data("Prior account bytes".utf8), at: "prior.md")
        route(link(server: "https://other.test/paw"))
        let view = try stagedView()
        XCTAssertFalse(view.canJoin)
        view.username = "person"
        let password = "Runtime-password-" + UUID().uuidString
        try secureField(SettingsInviteStrings.password).stringValue = password
        view.register()
        XCTAssertTrue(spin { view.state?.accepted == true && view.canOperate })
        let account = try XCTUnwrap(delegate.accountModel)
        XCTAssertTrue(account.state.connection?.serverURL.absoluteString == "https://other.test/paw")
        XCTAssertTrue(account.state.heldPrompts.contains { $0.path.string == "prior.md" })
        XCTAssertTrue(String(decoding: try files.read(at: "prior.md"), as: UTF8.self).contains("Prior account bytes"))
        XCTAssertFalse(transport.registerHadAuthorization)
        XCTAssertFalse(transport.foreignAuthorization)
        XCTAssertEqual(transport.putCount, 0, "Unexpected PUT hosts: \(transport.putHosts)")
        try assertPrivate([token, password])
    }

    func testTabHideMinimizeAndCloseClearInputsWithoutRetiringTheSharedModel() throws {
        start()
        route(link())
        let view = try stagedView()
        let model = try XCTUnwrap(delegate.inviteModel)
        let controller = try XCTUnwrap(delegate.settingsWindow)
        let field = try secureField(SettingsInviteStrings.input)
        field.stringValue = token
        controller.presentation.selectedTab = .general
        XCTAssertNil(view.state)
        XCTAssertTrue(field.stringValue.isEmpty)
        XCTAssertFalse(model.state.canAccept)
        delegate.showAccount()
        XCTAssertTrue(spin { view.canOperate })
        XCTAssertFalse(view.canAccept)
        route(link())
        _ = try stagedView()
        controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
        XCTAssertNil(view.state)
        XCTAssertFalse(model.state.canAccept)
        delegate.showAccount()
        route(link())
        _ = try stagedView()
        let window = try XCTUnwrap(controller.window)
        window.orderOut(nil)
        controller.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification))
        XCTAssertNil(view.state)
        delegate.showAccount()
        window.close()
        XCTAssertNil(view.state)
        XCTAssertTrue(delegate.inviteModel === model)
        XCTAssertEqual(transport.redemptions, 0)
    }

    func testInviteAndGroupSectionsBindHideAndRebindTogether() throws {
        start()
        let controller = try XCTUnwrap(delegate.settingsWindow)
        let account = controller.presentation.account
        let invites = account.invites
        let groups = account.groups
        XCTAssertNil(invites.state)
        XCTAssertNil(groups.state)

        route(link())
        _ = try stagedView()
        let oldInvite = try XCTUnwrap(delegate.inviteModel)
        let oldGroups = try XCTUnwrap(delegate.groupManagementModel)
        XCTAssertEqual(try XCTUnwrap(invites.state), oldInvite.state)
        XCTAssertEqual(try XCTUnwrap(groups.state), oldGroups.state)
        XCTAssertTrue(groups.canRefresh)
        let linkField = try secureField(SettingsInviteStrings.input)
        let passwordField = try secureField(SettingsInviteStrings.password)
        linkField.stringValue = token
        passwordField.stringValue = "discarded-input"
        groups.createName = "Discarded group draft"

        controller.presentation.selectedTab = .general
        XCTAssertNil(invites.state)
        XCTAssertNil(groups.state)
        XCTAssertFalse(oldInvite.state.canAccept)
        XCTAssertTrue(linkField.stringValue.isEmpty)
        XCTAssertTrue(passwordField.stringValue.isEmpty)
        XCTAssertTrue(groups.createName.isEmpty)

        delegate.showAccount()
        XCTAssertTrue(spin { invites.canOperate && groups.canRefresh })
        XCTAssertEqual(try XCTUnwrap(invites.state), oldInvite.state)
        XCTAssertEqual(try XCTUnwrap(groups.state), oldGroups.state)
        XCTAssertFalse(invites.canAccept)
        route(link())
        _ = try stagedView()
        groups.createName = "Stale group draft"

        let nextRoot = directory.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: false)
        try XCTUnwrap(delegate.generalSettingsModel).chooseFolder(nextRoot.path)
        XCTAssertTrue(spin { self.delegate.libraryDirectory == nextRoot && invites.canOperate && groups.canRefresh })
        let nextInvite = try XCTUnwrap(delegate.inviteModel)
        let nextGroups = try XCTUnwrap(delegate.groupManagementModel)
        XCTAssertFalse(nextInvite === oldInvite)
        XCTAssertFalse(nextGroups === oldGroups)
        XCTAssertEqual(try XCTUnwrap(invites.state), nextInvite.state)
        XCTAssertEqual(try XCTUnwrap(groups.state), nextGroups.state)
        XCTAssertFalse(invites.canAccept)
        XCTAssertTrue(groups.createName.isEmpty)
        var supplied = link()
        oldInvite.stage(&supplied)
        oldGroups.refresh()
        XCTAssertTrue(supplied.isEmpty)
        XCTAssertEqual(try XCTUnwrap(invites.state), nextInvite.state)
        XCTAssertEqual(try XCTUnwrap(groups.state), nextGroups.state)

        try XCTUnwrap(controller.window).close()
        XCTAssertNil(invites.state)
        XCTAssertNil(groups.state)
        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertEqual(clipboard.writes, 0)
    }

    func testClosedAcceptanceFinishesButDoesNotReviveTheHiddenPrompt() throws {
        start()
        route(link())
        let view = try stagedView()
        let model = try XCTUnwrap(delegate.inviteModel)
        view.username = "person"
        let field = try secureField(SettingsInviteStrings.password)
        field.stringValue = "Runtime-password-" + UUID().uuidString
        transport.holdSuffix = "/register"
        view.register()
        XCTAssertTrue(spin { self.transport.heldCount == 1 })
        let window = try XCTUnwrap(delegate.settingsWindow?.window)
        window.close()
        XCTAssertNil(view.state)
        XCTAssertTrue(field.stringValue.isEmpty)
        transport.release()
        XCTAssertTrue(spin { !model.state.isBusy && self.delegate.accountModel?.state.enabled == true })
        XCTAssertNil(view.state)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(model.state.canAccept)
        XCTAssertFalse(model.state.accepted)
        delegate.showAccount()
        XCTAssertTrue(spin { view.canOperate })
        XCTAssertFalse(view.canAccept)
        XCTAssertEqual(transport.registerCount, 1)
    }

    func testCloseBeforeQueuedStagingCannotRestoreTheLink() throws {
        start()
        route(link())
        let controller = try XCTUnwrap(delegate.settingsWindow)
        let view = controller.presentation.account.invites
        let model = try XCTUnwrap(delegate.inviteModel)
        try XCTUnwrap(controller.window).close()
        let end = Date().addingTimeInterval(0.1)
        RunLoop.current.run(until: end)
        XCTAssertNil(view.state)
        XCTAssertFalse(model.state.canAccept)
        delegate.showAccount()
        XCTAssertTrue(spin { view.canOperate })
        XCTAssertFalse(view.canAccept)
        route(link())
        _ = try stagedView()
        var closeOnReset = true
        let observer = model.addObserver { state in
            if closeOnReset, !state.hasStagedInvite, !state.isBusy {
                closeOnReset = false
                controller.window?.close()
            }
        }
        route(link(server: "https://replacement.test/paw"))
        model.removeObserver(observer)
        XCTAssertNil(view.state, "A reentrant close must revoke the pending replacement too")
        delegate.showAccount()
        XCTAssertTrue(spin { view.canOperate })
        XCTAssertFalse(view.canAccept)
        XCTAssertEqual(transport.redemptions, 0)
    }

    func testRegistrationFailureKeepsTheAcceptedReceiptAndCleanupVisible() throws {
        start()
        route(link())
        let view = try stagedView()
        secrets.failWrite = true
        transport.failLogout = true
        view.username = "person"
        let password = "Runtime-password-" + UUID().uuidString
        try secureField(SettingsInviteStrings.password).stringValue = password
        view.register()
        XCTAssertTrue(spin { view.state?.accepted == true && view.canOperate })
        XCTAssertTrue(view.state?.error?.message.contains("The account was created.") == true)
        XCTAssertTrue(view.state?.cleanup.isComplete == false)
        XCTAssertFalse(view.canAccept)
        XCTAssertTrue(delegate.accountModel?.state.enabled == false)
        XCTAssertEqual(transport.registerCount, 1)
        try assertPrivate([token, password])
    }

    func testLibraryReplacementRevokesTheOldInviteAndItsCallbacks() throws {
        start()
        route(link())
        let view = try stagedView()
        let old = try XCTUnwrap(delegate.inviteModel)
        let other = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        delegate.generalSettingsModel?.chooseFolder(other.path)
        XCTAssertTrue(spin { self.delegate.libraryDirectory == other && view.canOperate })
        XCTAssertFalse(delegate.inviteModel === old)
        XCTAssertFalse(view.canAccept)
        var input = link()
        old.stage(&input)
        XCTAssertTrue(input.isEmpty, "Retired models must consume supplied links")
        XCTAssertFalse(view.canAccept)
        XCTAssertEqual(transport.redemptions, 0)
    }

    func testInviteDismissalPreservesFillDraftAndOnboardingReusesAccount() throws {
        let files = try RootedFileStore(root: root)
        try files.createRoot()
        try files.write(Data("{{topic}}".utf8), at: "draft.md")
        start()
        let picker = try XCTUnwrap(delegate.pickerModel)
        picker.open()
        picker.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        fill.setValue("Retained draft", name: "topic")
        route(link())
        _ = try stagedView()
        XCTAssertEqual(picker.state, .closed)
        picker.open()
        picker.use(mode: .copyOnly)
        XCTAssertEqual(picker.fillModel?.values["topic"], "Retained draft")
        let window = try XCTUnwrap(delegate.settingsWindow?.window)
        delegate.onboardingWindow?.presentation.showInvite()
        XCTAssertTrue(delegate.settingsWindow?.window === window)
        XCTAssertEqual(delegate.settingsWindow?.presentation.selectedTab, .account)
        XCTAssertEqual(picker.state, .closed)
        XCTAssertEqual(clipboard.writes, 0)
        XCTAssertEqual(transport.redemptions, 0)
    }

    func testHTTPReleaseBeforeHoldAdmissionCannotStrandARequest() throws {
        let transport = MacInviteHTTP()
        transport.holdSuffix = "/register"
        // Reproduce release between response preparation and hold admission.
        transport.beforeHoldAdmission = { [weak transport] in transport?.release() }
        defer { transport.release() }
        let request = try HTTPRequest(url: URL(string: "https://example.test/paw/api/v1/register")!,
            method: .post, deadline: ContinuousClock().now.advanced(by: .seconds(5)))
        let finished = expectation(description: "A released request completes without another release")
        Task.detached {
            do {
                let response = try await transport.send(request)
                XCTAssertEqual(response.statusCode, 200)
            } catch { XCTFail("The stub registration should succeed") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(transport.heldCount, 0)
    }

    func testPrivacyScanRepeatsBothRootsAfterAListedFileDisappears() throws {
        let files = try makePrivacyFiles()
        try files.write(Data("clean".utf8), at: ".monkeyspaw-sync-transient")
        try files.write(Data("clean".utf8), at: "library.md")
        try RootedFileStore(root: data).write(Data("clean".utf8), at: "state.json")
        var reads: [String] = []
        try assertPrivate([token]) { store, path in
            reads.append(path)
            if path == ".monkeyspaw-sync-transient" { try store.move(from: path, to: "published.json") }
            return try store.read(at: path)
        }
        XCTAssertEqual(reads.filter { $0 == "library.md" }.count, 2)
        XCTAssertEqual(reads.filter { $0 == "state.json" }.count, 2)
        XCTAssertTrue(reads.contains("published.json"))
    }

    func testPrivacyScanFailsImmediatelyOnALeakBeforeDisappearance() throws {
        let files = try makePrivacyFiles()
        try files.write(Data(token.utf8), at: "a-leak.md")
        try files.write(Data("clean".utf8), at: "z-transient")
        var reads: [String] = []
        XCTAssertThrowsError(try assertPrivate([token]) { store, path in
            reads.append(path)
            if path == "z-transient" { try store.delete(at: path) }
            return try store.read(at: path)
        }) { XCTAssertEqual($0 as? PrivacyScanError, .persistedBytes) }
        XCTAssertEqual(reads, ["a-leak.md"])
    }

    func testPrivacyScanFindsALeakAfterDisappearanceInTheSamePass() throws {
        let files = try makePrivacyFiles()
        try files.write(Data("clean".utf8), at: ".monkeyspaw-sync-transient")
        try files.write(Data(token.utf8), at: "leak.md")
        var reads: [String] = []
        XCTAssertThrowsError(try assertPrivate([token]) { store, path in
            reads.append(path)
            if path == ".monkeyspaw-sync-transient" { try store.delete(at: path) }
            return try store.read(at: path)
        }) { XCTAssertEqual($0 as? PrivacyScanError, .persistedBytes) }
        XCTAssertEqual(reads, [".monkeyspaw-sync-transient", "leak.md"])
    }

    func testPrivacyScanFindsALeakPublishedDuringAnUnstablePass() throws {
        let files = try makePrivacyFiles()
        try files.write(Data(token.utf8), at: ".monkeyspaw-sync-transient")
        XCTAssertThrowsError(try assertPrivate([token]) { store, path in
            if path == ".monkeyspaw-sync-transient" { try store.move(from: path, to: "persisted.json") }
            return try store.read(at: path)
        }) { XCTAssertEqual($0 as? PrivacyScanError, .persistedBytes) }
    }

    func testPrivacyScanChecksSecretsDuringAnUnstablePass() throws {
        let files = try makePrivacyFiles()
        try files.write(Data("clean".utf8), at: "transient")
        try secrets.write(SecretValue(token), account: .device(UUID()))
        var reads = 0
        XCTAssertThrowsError(try assertPrivate([token]) { store, path in
            reads += 1
            try store.delete(at: path)
            return try store.read(at: path)
        }) { XCTAssertEqual($0 as? PrivacyScanError, .secretStoreBytes) }
        XCTAssertEqual(reads, 1)
    }

    func testPrivacyScanPropagatesOtherReadErrorsWithoutRetrying() throws {
        let files = try makePrivacyFiles()
        try files.write(Data("clean".utf8), at: "library.md")
        for error in [FileStoreError.ioFailure, .outsideRoot, .notRegularFile] {
            var reads = 0
            XCTAssertThrowsError(try assertPrivate([token]) { _, _ in
                reads += 1
                throw error
            }) { XCTAssertEqual($0 as? FileStoreError, error) }
            XCTAssertEqual(reads, 1)
        }
    }

    func testPrivacyScanFailsAfterBoundedPersistentDisappearance() throws {
        let files = try makePrivacyFiles()
        try files.write(Data("clean".utf8), at: "library.md")
        var reads = 0
        XCTAssertThrowsError(try assertPrivate([token]) { _, _ in
            reads += 1
            throw FileStoreError.notFound
        }) { XCTAssertEqual($0 as? PrivacyScanError, .unstableFiles) }
        XCTAssertEqual(reads, 3)
    }

    func testPrivacyScanRefusesMissingRootsBeforeAndDuringScanning() throws {
        let files = try makePrivacyFiles()
        try files.write(Data("clean".utf8), at: "library.md")
        try FileManager.default.removeItem(at: data)
        XCTAssertThrowsError(try assertPrivate([token])) { XCTAssertEqual($0 as? FileStoreError, .notFound) }
        try RootedFileStore(root: data).createRoot()
        var reads = 0
        XCTAssertThrowsError(try assertPrivate([token]) { store, path in
            reads += 1
            try FileManager.default.removeItem(at: self.root)
            return try store.read(at: path)
        }) { XCTAssertEqual($0 as? FileStoreError, .notFound) }
        XCTAssertEqual(reads, 1)
    }

    private func makePrivacyFiles() throws -> RootedFileStore {
        let files = try RootedFileStore(root: root)
        try files.createRoot()
        try RootedFileStore(root: data).createRoot()
        return files
    }

    private enum PrivacyScanError: Error, Equatable { case persistedBytes, secretStoreBytes, unstableFiles }

    private func makeDelegate() {
        delegate = AppDelegate(libraryRoot: root, dataRoot: data, httpTransport: transport, secrets: secrets,
            clipboard: clipboard, replyToTermination: { [weak self] in self?.terminationReplies.append($0) },
            setActivationPolicy: { _ in }, activateApplication: {}, makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in false }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, makeFileWatcher: { _, _ in MacInviteWatcher() })
    }

    private func start() {
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    private func stopDelegate() {
        transport.release()
        if delegate.applicationShouldTerminate(NSApp) == .terminateLater {
            XCTAssertTrue(spin { self.terminationReplies.last == true }, "The isolated graph did not drain")
        }
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        terminationReplies.removeAll()
    }

    private func route(_ text: String) {
        guard let url = URL(string: text) else { XCTFail("Invalid URL test fixture"); return }
        delegate.application(NSApp, open: [url])
    }

    private func link(server: String = "https://example.test/paw") -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return "monkeyspaw://join?server=" + server.addingPercentEncoding(withAllowedCharacters: unreserved)! + "&token=" + token
    }

    private func openAccount() throws -> InviteViewState {
        delegate.showAccount()
        let view = try XCTUnwrap(delegate.settingsWindow?.presentation.account.invites)
        XCTAssertTrue(spin { view.canOperate })
        return view
    }

    private func stagedView() throws -> InviteViewState {
        let view = try XCTUnwrap(delegate.settingsWindow?.presentation.account.invites)
        XCTAssertTrue(spin { view.canAccept }, "The native invite did not finish staging")
        XCTAssertTrue(spin { self.delegate.groupManagementModel?.state.isBusy != true })
        return view
    }

    /// Read without a UI hop or wait. Only fixed labels and booleans may escape.
    private func coldInviteDiagnostic(_ view: InviteViewState) -> String {
        let canAccept = view.canAccept
        let canJoin = view.canJoin
        let destination = view.state?.destination
        let account = delegate.accountModel?.state
        let connection = account?.connection
        let graph = delegate.syncComposition
        let groupBusy = delegate.groupManagementModel?.state.isBusy == true
        let renderedAccountBusy = delegate.settingsWindow?.presentation.account.state?.isBusy == true
        let operation: String
        switch account?.operation {
        case nil: operation = "none"
        case .loading: operation = "loading"
        case .signingIn: operation = "signingIn"
        case .refreshing: operation = "refreshing"
        case .revokingDevice: operation = "revokingDevice"
        case .signingOut: operation = "signingOut"
        case .includingHeld: operation = "includingHeld"
        }
        let issue: String
        switch account?.error {
        case nil: issue = "none"
        case .busy: issue = "busy"
        default: issue = "other"
        }
        let destinationServer = destination.flatMap { try? SyncServerURL($0.serverURL.absoluteString) }
        let accountServer = connection.flatMap { try? SyncServerURL($0.serverURL.absoluteString) }
        let serversEqual = destinationServer != nil && accountServer != nil && destinationServer == accountServer
        // This compares public connection metadata, not the private credential binding.
        let connectionsEqual = connection != nil && destination?.currentAccount == connection
        let fields: [String] = [
            "coldInviteReadiness",
            "canAccept=\(canAccept)", "canJoin=\(canJoin)",
            "destinationPresent=\(destination != nil)", "capturedCanJoin=\(destination?.canJoin == true)",
            "accountPresent=\(connection != nil)", "accountEnabled=\(account?.enabled == true)",
            "accountBusy=\(account?.isBusy == true)", "accountOperation=\(operation)", "accountIssue=\(issue)",
            "renderedAccountBusy=\(renderedAccountBusy)", "groupBusy=\(groupBusy)",
            "graphPresent=\(graph != nil)", "rootIssuePresent=\(graph?.rootIssue != nil)",
            "blockingIssuePresent=\(graph?.sync.report.blockingIssue != nil)",
            "destinationServerValid=\(destinationServer != nil)", "accountServerValid=\(accountServer != nil)",
            "normalizedServersEqual=\(serversEqual)", "connectionMetadataEqual=\(connectionsEqual)"
        ]
        return fields.joined(separator: " ")
    }

    private func secureField(_ title: String) throws -> NSSecureTextField {
        let content = try XCTUnwrap(delegate.settingsWindow?.window?.contentView)
        func find(_ view: NSView) -> NSSecureTextField? {
            if let field = view as? NSSecureTextField, field.placeholderString == title { return field }
            for child in view.subviews { if let field = find(child) { return field } }
            return nil
        }
        var field: NSSecureTextField?
        XCTAssertTrue(spin { content.layoutSubtreeIfNeeded(); field = find(content); return field != nil })
        return try XCTUnwrap(field)
    }

    private func login() throws {
        let account = try XCTUnwrap(delegate.accountModel)
        XCTAssertTrue(spin { !account.state.isBusy })
        var password = "Runtime-password-" + UUID().uuidString
        account.login(server: "https://example.test/paw", username: "person", password: &password, deviceName: "Mac")
        XCTAssertTrue(spin { account.state.enabled && !account.state.isBusy })
        XCTAssertTrue(spin {
            self.delegate.syncStatusModel?.state.phase == .idle && self.delegate.syncStatusModel?.state.lastSuccess != nil
        })
    }

    private func assertPrivate(_ values: [String],
        read: (RootedFileStore, String) throws -> Data = { try $0.read(at: $1) }) throws {
        let stores = try [root!, data!].map { try RootedFileStore(root: $0) }
        for files in stores { try files.pinRoot() }
        // Live atomic writers can rename a listed temporary. Retry both roots,
        // retaining every readable-file and secret-store check in unstable passes.
        for _ in 0..<3 {
            var disappeared = false
            for files in stores {
                for entry in try files.listFiles() {
                    let bytes: Data
                    do { bytes = try read(files, entry.relativePath) }
                    catch FileStoreError.notFound {
                        try files.requireRoot()
                        disappeared = true
                        continue
                    }
                    if values.contains(where: { bytes.range(of: Data($0.utf8)) != nil }) {
                        throw PrivacyScanError.persistedBytes
                    }
                }
            }
            if secrets.containsAny(values) { throw PrivacyScanError.secretStoreBytes }
            for files in stores { try files.requireRoot() }
            if !disappeared { return }
        }
        throw PrivacyScanError.unstableFiles
    }

    private func spin(_ predicate: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
}

private final class MacInviteWatcher: FileStoreWatcher {
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {}
    func stop() {}
}

private final class MacInviteClipboard: Clipboard {
    var writes = 0
    func writeText(_ text: String) { writes += 1 }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { completion(nil) }
}

private final class MacInviteSecrets: SecretStore {
    private let lock = NSLock()
    private var entries: [SecretAccount: SecretValue] = [:]
    private var reads = 0
    private var offMain = true
    var failWrite = false
    var readCount: Int { locked { reads } }
    var allWorkOffMain: Bool { locked { offMain } }

    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        locked {
            reads += 1
            offMain = offMain && !Thread.isMainThread
            return entries[account].map { StoredSecret(value: $0, tier: .keychain) }
        }
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        try locked {
            offMain = offMain && !Thread.isMainThread
            if failWrite { throw SecretStoreError.writeFailed }
            entries[account] = value
            return .keychain
        }
    }
    func delete(account: SecretAccount) throws { locked { entries[account] = nil } }
    func containsAny(_ values: [String]) -> Bool {
        locked { entries.values.contains { entry in entry.withValue { text in values.contains { text.contains($0) } } } }
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}

private final class MacInviteHTTP: HTTPTransporting, @unchecked Sendable {
    static let userID = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!
    static let otherUserID = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAZ")!
    static let deviceID = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAW")!
    static let groupID = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAX")!
    private let deviceToken = String(repeating: "b", count: 42) + "A"
    private let lock = NSLock()
    private var storedUser = MacInviteHTTP.userID
    private var paths: [String] = []
    private var puts = 0
    private var putDestinations: [String] = []
    private var joined = false
    private var offMain = true
    private var registerAuth = false
    private var joinAuth = false
    private var foreignAuth = false
    private var heldSuffix: String?
    private var holdAdmission: (() -> Void)?
    private var logoutFailure = false
    private var held: [(CheckedContinuation<HTTPResponse, Error>, HTTPResponse)] = []
    var user: ULID { get { locked { storedUser } } set { locked { storedUser = newValue } } }
    var holdSuffix: String? { get { locked { heldSuffix } } set { locked { heldSuffix = newValue } } }
    var beforeHoldAdmission: (() -> Void)? { get { locked { holdAdmission } } set { locked { holdAdmission = newValue } } }
    var failLogout: Bool { get { locked { logoutFailure } } set { locked { logoutFailure = newValue } } }
    var requestCount: Int { locked { paths.count } }
    var registerCount: Int { locked { paths.filter { $0.hasSuffix("/register") }.count } }
    var joinCount: Int { locked { paths.filter { $0.hasSuffix("/groups/join") }.count } }
    var redemptions: Int { registerCount + joinCount }
    var putCount: Int { locked { puts } }
    var putHosts: [String] { locked { putDestinations } }
    var heldCount: Int { locked { held.count } }
    var registerHadAuthorization: Bool { locked { registerAuth } }
    var joinHadAuthorization: Bool { locked { joinAuth } }
    var foreignAuthorization: Bool { locked { foreignAuth } }
    var allWorkOffMain: Bool { locked { offMain } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try locked { () throws -> HTTPResponse in
            offMain = offMain && !Thread.isMainThread
            let path = request.url.path
            paths.append(path)
            if request.method == .put {
                puts += 1
                putDestinations.append(request.url.host ?? "<no host>")
            }
            let authorized = request.headers.keys.contains { $0.lowercased() == "authorization" }
            let bearer = request.headers.first { $0.key.lowercased() == "authorization" }?.value
            foreignAuth = foreignAuth || (bearer == "Bearer " + deviceToken && request.url.host != "example.test")
            let responseToken = request.url.host == "example.test" ? deviceToken : String(repeating: "c", count: 42) + "A"
            let person = SyncAPI.User(id: storedUser.rawValue, username: "person", displayName: nil,
                accountKind: .member, createdAt: "2026-10-14T00:00:00.000Z", disabledAt: nil)
            let group = SyncAPI.GroupMembership(groupID: Self.groupID.rawValue, name: "Team", role: .viewer)
            if path.hasSuffix("/register") {
                registerAuth = authorized
                return try http(SyncAPI.AuthResponse(deviceToken: responseToken, user: person))
            }
            if path.hasSuffix("/login") { return try http(SyncAPI.AuthResponse(deviceToken: responseToken, user: person)) }
            if path.hasSuffix("/logout"), logoutFailure { throw HTTPTransportError.networkFailure }
            if path.hasSuffix("/groups/join") {
                joinAuth = authorized
                joined = true
                return try http(group)
            }
            if path.hasSuffix("/me") {
                let device = SyncAPI.Device(id: Self.deviceID.rawValue, name: "Mac", createdAt: "2026-10-14T00:00:00.000Z",
                    lastSeenAt: nil, revokedAt: nil, isCurrent: true)
                return try http(SyncAPI.MeResponse(user: person, groups: joined ? [group] : [], devices: [device]))
            }
            if path.hasSuffix("/sync/pull") {
                var scopes = [SyncAPI.SyncScope(identity: .user(userID: storedUser.rawValue), mode: .snapshot,
                    head: 0, cursor: "user", hasMore: false, items: [])]
                if joined {
                    scopes.append(SyncAPI.SyncScope(identity: .group(groupID: Self.groupID.rawValue, name: "Team", role: .viewer),
                        mode: .snapshot, head: 0, cursor: "group", hasMore: false, items: []))
                }
                return try http(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: scopes, removed: []))
            }
            return try http(SyncAPI.EmptyResponse())
        }
        beforeHoldAdmission?()
        return try await withCheckedThrowingContinuation { continuation in
            let enqueued = locked {
                guard let suffix = heldSuffix, request.url.path.hasSuffix(suffix) else { return false }
                held.append((continuation, response))
                return true
            }
            if !enqueued { continuation.resume(returning: response) }
        }
    }

    func release() {
        let replies = locked { () -> [(CheckedContinuation<HTTPResponse, Error>, HTTPResponse)] in
            heldSuffix = nil
            let replies = held
            held.removeAll()
            return replies
        }
        for (continuation, response) in replies { continuation.resume(returning: response) }
    }
    private func http<T: Encodable>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value))
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}
