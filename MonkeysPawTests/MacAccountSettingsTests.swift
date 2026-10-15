import AppKit
import Foundation
import MonkeysPawCore
import SwiftUI
import XCTest
@testable import MonkeysPaw

/// Hosted native controls backed by the public Core graph, memory-only secrets
/// and stub HTTP. No test opts into the owner's Keychain or production roots.
final class MacAccountSettingsTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var delegate: AppDelegate!
    private var transport: AccountSettingsHTTP!
    private var secrets: AccountSettingsSecrets!
    private var originalWindows: Set<ObjectIdentifier> = []
    private var terminationReplies: [Bool] = []

    override func setUpWithError() throws {
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library", isDirectory: true)
        data = directory.appendingPathComponent("data", isDirectory: true)
        transport = AccountSettingsHTTP()
        secrets = AccountSettingsSecrets()
        delegate = AppDelegate(libraryRoot: root, dataRoot: data, httpTransport: transport, secrets: secrets,
            replyToTermination: { [weak self] in self?.terminationReplies.append($0) },
            setActivationPolicy: { _ in }, activateApplication: {}, makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in false }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, makeFileWatcher: { _, _ in AccountSettingsWatcher() })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    override func tearDown() {
        transport.release()
        if delegate.applicationShouldTerminate(NSApp) == .terminateLater {
            XCTAssertTrue(spin { self.terminationReplies.last == true }, "The isolated graph did not drain")
        }
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        delegate = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountTabIsLazyAndUsesTheSharedModelWithoutHTTPOnOpen() throws {
        let controller = try XCTUnwrap(delegate.settingsWindow)
        XCTAssertTrue(AppDelegate.isRunningTests)
        XCTAssertNil(controller.presentation.account.state)
        delegate.showSettings()
        XCTAssertEqual(controller.presentation.selectedTab, .general)
        XCTAssertNil(controller.presentation.account.state)
        XCTAssertEqual(secrets.readCount, 0)
        XCTAssertEqual(transport.requestCount, 0)

        let view = try openAccount()
        let model = try XCTUnwrap(delegate.accountModel)
        XCTAssertEqual(view.state, model.state)
        XCTAssertEqual(view.connectionMessage, SettingsAccountStrings.signedOut)
        XCTAssertEqual(view.deviceName, SettingsAccountStrings.defaultDeviceName)
        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertEqual(secrets.readCount, 0)
        XCTAssertTrue(view.canOperate)
        XCTAssertFalse(view.canSignOut)
        XCTAssertNotNil(try secureField())
    }

    func testNativePasswordIsConsumedBeforeAdmissionAndNeverRepopulated() throws {
        let view = try openAccount()
        let field = try secureField()
        let sentinel = "runtime-password-" + UUID().uuidString
        var published: [AccountState] = []
        let observation = view.$state.sink { if let state = $0 { published.append(state) } }
        defer { observation.cancel() }
        transport.holdSuffix = "/login"
        setLogin(view, field: field, password: sentinel)
        view.login()
        XCTAssertTrue(field.stringValue.isEmpty, "Submit must clear native text synchronously")
        XCTAssertTrue(field.currentEditor()?.string.isEmpty ?? true)
        XCTAssertTrue(spin { self.transport.heldCount == 1 })
        XCTAssertFalse(view.canOperate)
        field.stringValue = "rejected-input"
        view.login()
        view.refresh()
        view.signOut()
        XCTAssertTrue(field.stringValue.isEmpty)
        XCTAssertEqual(transport.loginCount, 1)
        transport.release()
        waitIdle(view)
        XCTAssertTrue(view.state?.enabled == true)
        XCTAssertTrue(field.stringValue.isEmpty)
        // A normal representable update has no value from which to refill text.
        view.passwordInput.update(field, reset: view.passwordInputReset, isEditable: view.canOperate)
        XCTAssertTrue(field.stringValue.isEmpty)
        XCTAssertTrue(transport.allWorkOffMain)
        XCTAssertTrue(secrets.allWorkOffMain)
        for state in published {
            XCTAssertFalse(String(reflecting: state).contains(sentinel))
            XCTAssertFalse(state.secretStorageMessage.contains(sentinel))
            XCTAssertFalse(state.error?.message.contains(sentinel) == true)
        }
        let files = try RootedFileStore(root: data)
        let metadata = try files.read(at: "sync/account.json")
        XCTAssertNil(metadata.range(of: Data(sentinel.utf8)))
        XCTAssertNil(metadata.range(of: Data(AccountSettingsHTTP.token.utf8)))
    }

    func testNativeResetsClearTheActiveEditorAndDismantlingDropsInput() throws {
        let view = try openAccount()
        let field = try secureField()
        let window = try XCTUnwrap(delegate.settingsWindow?.window)
        _ = window.makeFirstResponder(field)
        field.stringValue = "typed-input"
        field.currentEditor()?.string = "typed-input"
        view.passwordInput.clear()
        XCTAssertTrue(field.stringValue.isEmpty)
        XCTAssertTrue(field.currentEditor()?.string.isEmpty ?? true)
        field.stringValue = "discarded-input"
        view.passwordInput.update(field, reset: UUID(), isEditable: true)
        XCTAssertTrue(field.stringValue.isEmpty)
        field.stringValue = "discarded-input"
        SettingsAccountPasswordField.dismantleNSView(field, coordinator: view.passwordInput)
        XCTAssertTrue(field.stringValue.isEmpty)
        XCTAssertTrue(view.passwordInput.consume().isEmpty)
    }

    func testSecretSaveFailureIsVisibleAndRetryRequiresFreshPassword() throws {
        let view = try openAccount()
        let field = try secureField()
        secrets.writeError = .writeFailed
        setLogin(view, field: field, password: "test-password")
        view.login()
        waitIdle(view)
        XCTAssertEqual(view.state?.error, .secret(.writeFailed))
        XCTAssertFalse(view.state?.error?.message.isEmpty ?? true)
        XCTAssertFalse(view.state?.enabled == true)
        XCTAssertTrue(field.stringValue.isEmpty)
        XCTAssertTrue(view.canOperate)
        secrets.writeError = nil
        setLogin(view, field: field, password: "fresh-password")
        view.login()
        waitIdle(view)
        XCTAssertNil(view.state?.error)
        XCTAssertTrue(view.state?.enabled == true)
        XCTAssertTrue(field.stringValue.isEmpty)
    }

    func testMetadataSaveFailureIsVisibleWithoutClaimingSyncEnabled() throws {
        let view = try openAccount()
        let field = try secureField()
        let record = data.appendingPathComponent("sync/account.json")
        defer { try? FileManager.default.removeItem(at: record) }
        secrets.onNextWrite = {
            try FileManager.default.removeItem(at: record)
            try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        }
        setLogin(view, field: field, password: "test-password")
        view.login()
        waitIdle(view)
        XCTAssertEqual(view.state?.error, .storageWrite)
        XCTAssertEqual(view.state?.error?.message, "Sync metadata could not be saved.")
        XCTAssertFalse(view.state?.enabled == true)
        XCTAssertFalse(delegate.syncStatusModel?.state.enabled == true)
        XCTAssertTrue(field.stringValue.isEmpty)
    }

    func testDeviceRevocationCannotDuplicateAndCurrentDeviceDisablesSync() throws {
        let view = try openAccount()
        try login(view)
        let other = try XCTUnwrap(view.state?.devices.first { !$0.isCurrent })
        XCTAssertEqual(SettingsAccountStrings.device(other), "Laptop")
        transport.holdSuffix = other.id
        view.revoke(other)
        view.revoke(other)
        XCTAssertTrue(spin { self.transport.heldCount == 1 })
        XCTAssertEqual(transport.revokeCount, 1)
        XCTAssertFalse(view.canOperate)
        transport.release()
        waitIdle(view)
        XCTAssertTrue(view.state?.enabled == true)
        XCTAssertFalse(view.state?.devices.contains { $0.id == other.id } == true)
        let current = try XCTUnwrap(view.state?.devices.first(where: \.isCurrent))
        XCTAssertEqual(SettingsAccountStrings.device(current), "Mac (this device)")
        view.revoke(current)
        waitIdle(view)
        XCTAssertEqual(transport.revokeCount, 2)
        XCTAssertNil(view.state?.connection)
        XCTAssertTrue(view.state?.devices.isEmpty == true)
        XCTAssertFalse(view.state?.enabled == true)
        XCTAssertFalse(delegate.syncStatusModel?.state.enabled == true)
        XCTAssertFalse(view.canSignOut)
    }

    func testSignOutReportsUnconfirmedRemoteAndFailedSecretCleanup() throws {
        let view = try openAccount()
        try login(view)
        transport.failLogout = true
        secrets.deleteError = .deleteFailed
        transport.holdSuffix = "/logout"
        view.signOut()
        view.signOut()
        // Failed transport requests do not suspend, so this also exercises a
        // completion that can arrive before the next native view update.
        waitIdle(view)
        XCTAssertEqual(transport.logoutCount, 1)
        XCTAssertFalse(view.state?.enabled == true)
        XCTAssertFalse(view.state?.cleanup.isComplete == true)
        XCTAssertEqual(view.state?.cleanup.remoteRevocation, .unconfirmed)
        XCTAssertEqual(view.state?.cleanup.failedSecretDeletions, 1)
        let message = try XCTUnwrap(view.cleanupMessage)
        XCTAssertTrue(message.contains("revocation could not be confirmed"))
        XCTAssertTrue(message.contains("could not be removed"))
        XCTAssertNil(view.state?.connection)
    }

    func testReservedFoldersShowRenameGuidanceAndDoNotReplayCredentials() throws {
        let view = try openAccount()
        let field = try secureField()
        let groups = root.appendingPathComponent("Groups", isDirectory: true)
        try FileManager.default.createDirectory(at: groups, withIntermediateDirectories: false)
        setLogin(view, field: field, password: "test-password")
        view.login()
        waitIdle(view)
        XCTAssertEqual(view.state?.error, .reservedFolders)
        XCTAssertTrue(view.state?.reservedFolders.contains("Groups") == true)
        XCTAssertEqual(view.state?.error?.message, "Rename the existing Groups or Conflicts entries, then sign in again.")
        XCTAssertTrue(field.stringValue.isEmpty)
        let count = transport.loginCount
        try FileManager.default.moveItem(at: groups, to: root.appendingPathComponent("Archived groups"))
        view.refresh()
        waitIdle(view)
        XCTAssertEqual(transport.loginCount, count)
        setLogin(view, field: field, password: "fresh-password")
        view.login()
        waitIdle(view)
        XCTAssertTrue(view.state?.enabled == true)
        XCTAssertTrue(view.state?.reservedFolders.isEmpty == true)
    }

    func testAccountChangeHoldsFilesUntilExplicitSelectedInclusion() throws {
        let view = try openAccount()
        try login(view)
        view.signOut()
        waitIdle(view)
        let files = try RootedFileStore(root: root)
        try files.write(Data("Previous account one".utf8), at: "one.md")
        try files.write(Data("Previous account two".utf8), at: "two.md")
        transport.user = AccountSettingsHTTP.otherUser
        try login(view)
        XCTAssertEqual(view.state?.heldPrompts.count, 2)
        XCTAssertTrue(view.state?.needsHeldDecision == true)
        XCTAssertEqual(transport.putCount, 0)
        XCTAssertFalse(view.canDecideHeld)
        view.decideHeld(.include)
        XCTAssertEqual(transport.putCount, 0)

        let selected = try XCTUnwrap(view.state?.heldPrompts.first { $0.path == "one.md" })
        view.selectHeld(selected.identity, selected: true)
        view.decideHeld(.keepLocal)
        XCTAssertTrue(spin { view.state?.keptLocal.contains(selected.identity) == true })
        view.decideHeld(.keepLocal)
        XCTAssertTrue(view.canOperate, "A repeated Keep local must release its admission latch")
        XCTAssertTrue(view.canDecideHeld)
        XCTAssertEqual(view.state?.heldPrompts.count, 2)
        XCTAssertEqual(transport.putCount, 0)
        view.decideHeld(.include)
        waitIdle(view)
        XCTAssertEqual(view.state?.heldPrompts.map(\.path.string), ["two.md"])
        XCTAssertTrue(view.selectedHeld.isEmpty)
        XCTAssertFalse(view.canDecideHeld)
        XCTAssertTrue(spin { self.transport.putCount == 1 })
        XCTAssertEqual(transport.putPaths, ["one.md"])

        // Selection is consent for one account only, even for the same file.
        let remaining = try XCTUnwrap(view.state?.heldPrompts.first)
        view.selectHeld(remaining.identity, selected: true)
        view.signOut()
        waitIdle(view)
        transport.user = AccountSettingsHTTP.primaryUser
        try login(view)
        XCTAssertTrue(view.selectedHeld.isEmpty)
        XCTAssertFalse(view.canDecideHeld)
    }

    func testTierMessagesUseCoreReadOnlyAndUnencryptedDisclosures() throws {
        let view = try openAccount()
        for tier in [SecretTier.keychain, .secretService, .file] {
            secrets.tier = tier
            try login(view)
            XCTAssertEqual(view.state?.secretTier, tier)
            let message = try XCTUnwrap(view.state?.secretStorageMessage)
            if tier == .file { XCTAssertTrue(message.contains("unencrypted")) }
            if tier == .keychain { XCTAssertTrue(message.contains("Keychain")) }
            if tier == .secretService { XCTAssertTrue(message.contains("Secret Service")) }
            view.signOut()
            waitIdle(view)
        }
        secrets.tier = .environment
        let field = try secureField()
        setLogin(view, field: field, password: "test-password")
        view.login()
        waitIdle(view)
        XCTAssertEqual(view.state?.error, .secret(.readOnly))
        XCTAssertTrue(view.state?.error?.message.contains("read-only") == true)
        XCTAssertFalse(view.state?.enabled == true)
    }

    func testTabCloseAndHideClearInputWhileIndependentObserversSurvive() throws {
        let view = try openAccount()
        let controller = try XCTUnwrap(delegate.settingsWindow)
        let model = try XCTUnwrap(delegate.accountModel)
        var independent = 0
        var ownedHook = 0
        let observer = model.addObserver { _ in independent += 1 }
        model.onChange = { ownedHook += 1 }
        defer { model.removeObserver(observer); model.onChange = nil }
        let field = try secureField()
        field.stringValue = "tab-input"
        controller.presentation.selectedTab = .general
        XCTAssertTrue(field.stringValue.isEmpty)
        XCTAssertNil(view.state)
        model.clearPasswordInput()
        XCTAssertGreaterThan(independent, 0)
        XCTAssertGreaterThan(ownedHook, 0)
        XCTAssertNil(view.state, "Detached callbacks must not repopulate a hidden tab")
        controller.presentation.selectedTab = .account
        XCTAssertTrue(spin { view.canOperate })
        let reopenedField = try secureField()
        reopenedField.stringValue = "hide-input"
        controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
        XCTAssertTrue(reopenedField.stringValue.isEmpty)
        XCTAssertNil(view.state)
        delegate.showSettings()
        XCTAssertTrue(spin { view.canOperate })
        try secureField().stringValue = "close-input"
        try XCTUnwrap(controller.window).close()
        XCTAssertNil(view.state)
        XCTAssertFalse(view.canOperate)
        delegate.showSettings()
        XCTAssertTrue(spin { view.canOperate })
        XCTAssertTrue(try secureField().stringValue.isEmpty)
        XCTAssertTrue(delegate.accountModel === model)
    }

    func testClosingDuringLoginDropsLateViewCallbacksWithoutCancellingCleanup() throws {
        let view = try openAccount()
        let model = try XCTUnwrap(delegate.accountModel)
        let field = try secureField()
        transport.holdSuffix = "/login"
        setLogin(view, field: field, password: "test-password")
        view.login()
        XCTAssertTrue(spin { self.transport.heldCount == 1 })
        try XCTUnwrap(delegate.settingsWindow?.window).close()
        XCTAssertNil(view.state)
        XCTAssertTrue(field.stringValue.isEmpty)
        transport.release()
        XCTAssertTrue(spin { !model.state.isBusy && model.state.enabled })
        XCTAssertNil(view.state)
        delegate.showSettings()
        XCTAssertTrue(spin { view.state?.enabled == true })
        XCTAssertEqual(transport.loginCount, 1)
        XCTAssertTrue(try secureField().stringValue.isEmpty)
    }

    func testGeneralRefreshRebindsAccountAfterAnIdleLibrarySwitch() throws {
        let view = try openAccount()
        let old = try XCTUnwrap(delegate.accountModel)
        let field = try secureField()
        field.stringValue = "old-library-input"
        let other = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try XCTUnwrap(delegate.generalSettingsModel).chooseFolder(other.path)
        XCTAssertTrue(spin { self.delegate.libraryDirectory == other && view.canOperate })
        let next = try XCTUnwrap(delegate.accountModel)
        XCTAssertFalse(next === old)
        XCTAssertEqual(view.state, next.state)
        XCTAssertTrue(field.stringValue.isEmpty)
        let state = view.state
        old.clearPasswordInput()
        XCTAssertEqual(view.state, state)
        XCTAssertEqual(transport.loginCount, 0)
    }

    private func openAccount() throws -> AccountSettingsViewState {
        delegate.showSettings()
        let controller = try XCTUnwrap(delegate.settingsWindow)
        controller.presentation.selectedTab = .account
        let view = controller.presentation.account
        XCTAssertTrue(spin { view.canOperate })
        _ = try secureField()
        return view
    }

    private func secureField() throws -> NSSecureTextField {
        let content = try XCTUnwrap(delegate.settingsWindow?.window?.contentView)
        var found: NSSecureTextField?
        XCTAssertTrue(spin {
            content.layoutSubtreeIfNeeded()
            found = self.findPassword(in: content)
            return found != nil
        }, "The Account tab did not create its native secure field")
        return try XCTUnwrap(found)
    }

    private func findPassword(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField, field.placeholderString == SettingsAccountStrings.password { return field }
        for child in view.subviews {
            if let field = findPassword(in: child) { return field }
        }
        return nil
    }

    private func login(_ view: AccountSettingsViewState) throws {
        setLogin(view, field: try secureField(), password: "runtime-" + UUID().uuidString)
        view.login()
        waitIdle(view)
        XCTAssertNil(view.state?.error)
        XCTAssertTrue(view.state?.enabled == true)
        XCTAssertTrue(spin {
            self.delegate.syncStatusModel?.state.lastSuccess != nil
                && self.delegate.syncStatusModel?.state.phase == .idle
        })
    }

    private func setLogin(_ view: AccountSettingsViewState, field: NSSecureTextField, password: String) {
        view.server = "https://example.test/paw"
        view.username = "person"
        view.deviceName = "Mac"
        field.stringValue = password
    }

    private func waitIdle(_ view: AccountSettingsViewState) {
        XCTAssertTrue(spin { view.state?.isBusy == false && view.canOperate })
    }

    private func spin(_ predicate: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
}

private final class AccountSettingsWatcher: FileStoreWatcher {
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {}
    func stop() {}
}

private final class AccountSettingsSecrets: SecretStore {
    private let lock = NSLock()
    private var entries: [SecretAccount: SecretValue] = [:]
    private var reads = 0
    private var offMain = true
    private var storedTier = SecretTier.keychain
    private var writeFailure: SecretStoreError?
    private var deleteFailure: SecretStoreError?
    private var nextWrite: (() throws -> Void)?
    var tier: SecretTier { get { locked { storedTier } } set { locked { storedTier = newValue } } }
    var writeError: SecretStoreError? { get { locked { writeFailure } } set { locked { writeFailure = newValue } } }
    var deleteError: SecretStoreError? { get { locked { deleteFailure } } set { locked { deleteFailure = newValue } } }
    var onNextWrite: (() throws -> Void)? { get { locked { nextWrite } } set { locked { nextWrite = newValue } } }
    var readCount: Int { locked { reads } }
    var allWorkOffMain: Bool { locked { offMain } }

    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        locked {
            reads += 1
            offMain = offMain && !Thread.isMainThread
            return entries[account].map { StoredSecret(value: $0, tier: storedTier) }
        }
    }

    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        let hook = try locked { () throws -> (() throws -> Void)? in
            offMain = offMain && !Thread.isMainThread
            if let writeFailure { throw writeFailure }
            let hook = nextWrite
            nextWrite = nil
            return hook
        }
        try hook?()
        return locked { entries[account] = value; return storedTier }
    }

    func delete(account: SecretAccount) throws {
        try locked {
            offMain = offMain && !Thread.isMainThread
            if let deleteFailure { throw deleteFailure }
            entries[account] = nil
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}

private final class AccountSettingsHTTP: HTTPTransporting, @unchecked Sendable {
    static let primaryUser = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!
    static let otherUser = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAZ")!
    static let device = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAW")!
    static let otherDevice = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAX")!
    static let token = String(repeating: "a", count: 42) + "A"
    private let lock = NSLock()
    private var storedUser = AccountSettingsHTTP.primaryUser
    private var paths: [String] = []
    private var writes: [String] = []
    private var offMain = true
    private var otherRevoked = false
    private var heldSuffix: String?
    private var logoutFailure = false
    private var held: [(CheckedContinuation<HTTPResponse, Error>, HTTPResponse)] = []
    var user: ULID { get { locked { storedUser } } set { locked { storedUser = newValue } } }
    var holdSuffix: String? { get { locked { heldSuffix } } set { locked { heldSuffix = newValue } } }
    var failLogout: Bool { get { locked { logoutFailure } } set { locked { logoutFailure = newValue } } }
    var heldCount: Int { locked { held.count } }
    var requestCount: Int { locked { paths.count } }
    var loginCount: Int { locked { paths.filter { $0.hasSuffix("/login") }.count } }
    var logoutCount: Int { locked { paths.filter { $0.hasSuffix("/logout") }.count } }
    var revokeCount: Int { locked { paths.filter { $0.contains("/me/devices/") }.count } }
    var putCount: Int { locked { writes.count } }
    var putPaths: [String] { locked { writes } }
    var allWorkOffMain: Bool { locked { offMain } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try locked { () throws -> HTTPResponse in
            offMain = offMain && !Thread.isMainThread
            let path = request.url.path
            paths.append(path)
            let person = SyncAPI.User(id: storedUser.rawValue, username: "person", displayName: nil,
                accountKind: .member, createdAt: "2026-10-14T00:00:00.000Z", disabledAt: nil)
            if path.hasSuffix("/login") {
                return try http(SyncAPI.AuthResponse(deviceToken: Self.token, user: person))
            }
            if path.hasSuffix("/logout"), logoutFailure { throw HTTPTransportError.networkFailure }
            if path.contains("/me/devices/"), request.method == .delete {
                if path.hasSuffix(Self.otherDevice.rawValue) { otherRevoked = true }
                return try http(SyncAPI.EmptyResponse())
            }
            if path.hasSuffix("/me") {
                var devices = [Self.deviceDTO(Self.device, name: "Mac", current: true)]
                if !otherRevoked { devices.append(Self.deviceDTO(Self.otherDevice, name: "Laptop", current: false)) }
                return try http(SyncAPI.MeResponse(user: person, groups: [], devices: devices))
            }
            if path.hasSuffix("/sync/pull") {
                let scope = SyncAPI.SyncScope(identity: .user(userID: storedUser.rawValue), mode: .snapshot,
                    head: 0, cursor: "opaque-user", hasMore: false, items: [])
                return try http(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111",
                    scopes: [scope], removed: []))
            }
            if request.method == .put {
                let body = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self, from: request.body ?? Data())
                writes.append(body.path)
                return try http(SyncAPI.WriteResponse(rev: body.baseRev + 1, seq: Int64(writes.count)))
            }
            return try http(SyncAPI.EmptyResponse())
        }
        let shouldHold = locked { heldSuffix.map { request.url.path.hasSuffix($0) } ?? false }
        guard shouldHold else { return response }
        return try await withCheckedThrowingContinuation { continuation in
            locked { held.append((continuation, response)) }
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

    private static func deviceDTO(_ id: ULID, name: String, current: Bool) -> SyncAPI.Device {
        SyncAPI.Device(id: id.rawValue, name: name, createdAt: "2026-10-14T00:00:00.000Z",
            lastSeenAt: nil, revokedAt: nil, isCurrent: current)
    }

    private func http<T: Encodable>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value))
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}
