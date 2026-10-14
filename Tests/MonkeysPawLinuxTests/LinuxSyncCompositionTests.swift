#if os(Linux)
import CGtk
import Foundation
import Glibc
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawLinux

final class LinuxSyncCompositionTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var paths: LinuxPaths!
    private var transport: LinuxSyncTestTransport!
    private var notifications: FakePortal!

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        tools.environment["XDG_CURRENT_DESKTOP"] = "sway"
        tools.environment["DBUS_SESSION_BUS_ADDRESS"] = address
        paths = LinuxPaths(environment: tools.environment)
        transport = LinuxSyncTestTransport()
        notifications = try FakePortal(address: address)
        try notifications.ownNotifications()
    }

    override func tearDown() {
        transport?.releaseHeld()
        if let environment {
            environment.shutdown()
            let done = LinuxSyncTestFlag()
            Task.detached { await environment.drainSync(); done.set() }
            XCTAssertTrue(GTKTestSupport.spin(until: { done.value }))
        }
        environment = nil
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        notifications?.shutdown()
        notifications = nil
        transport = nil
        tools = nil
    }

    func testGLibTimersSendWorkToTheSharedWorkerAndRevokeQueuedCallbacks() throws {
        let worker = LinuxBackgroundWork()
        let timer = LinuxSyncScheduler(worker: worker)
        let entered = LinuxSyncTestFlag()
        let finished = LinuxSyncTestFlag()
        let release = DispatchSemaphore(value: 0)
        timer.after(.milliseconds(10)) {
            XCTAssertFalse(Thread.isMainThread)
            entered.set()
            release.wait()
            finished.set()
        }
        defer { release.signal(); timer.retire() }
        XCTAssertTrue(GTKTestSupport.spin { entered.value })
        let heartbeat = LinuxSyncTestFlag()
        GTK.onMainLoop { heartbeat.set() }
        XCTAssertTrue(GTKTestSupport.spin { heartbeat.value })
        let stale = LinuxSyncTestFlag()
        timer.after(.milliseconds(10)) { stale.set() }
        waitForGLib(.milliseconds(40))
        timer.retire()
        release.signal()
        XCTAssertTrue(GTKTestSupport.spin { finished.value })
        waitForGLib(.milliseconds(40))
        XCTAssertFalse(stale.value)
        let never = LinuxSyncTestFlag()
        timer.after(.milliseconds(1)) { never.set() }
        waitForGLib(.milliseconds(20))
        XCTAssertFalse(never.value)
    }

    func testDeviceEnvironmentIsReadOnlyAndPersistedReadsUseTheFileTier() throws {
        let id = UUID()
        let account = SecretAccount.device(id)
        let variable = Self.deviceVariable(id)
        let token = UUID().uuidString
        tools.environment[variable] = token
        let store = LinuxSecretStore(paths: paths, runner: tools.runner)
        XCTAssertEqual(try store.read(account: account, source: .effective)?.tier, .environment)
        onWorker {
            XCTAssertNil(try store.read(account: account, source: .persisted))
            XCTAssertEqual(try store.write(SecretValue("persisted-envelope"), account: account), .file)
            let persisted = try XCTUnwrap(store.read(account: account, source: .persisted))
            XCTAssertEqual(persisted.tier, .file)
            XCTAssertTrue(persisted.value.withValue { $0 == "persisted-envelope" })
            try store.delete(account: account)
            XCTAssertNil(try store.read(account: account, source: .persisted))
            XCTAssertEqual(try store.read(account: account, source: .effective)?.tier, .environment)
        }
        XCTAssertTrue(tools.runner.environment[variable] == token)
    }

    func testEveryToolStripsDeviceOverridesIncludingExplicitEnvironmentOverrides() throws {
        let variable = Self.deviceVariable(UUID())
        let token = UUID().uuidString
        tools.environment[variable] = token
        try tools.install("inspect", script: FakeLinuxTools.recordArguments + "\n/usr/bin/env")
        let output = try tools.runner.run("inspect", arguments: ["separate", "arguments"],
            environmentOverrides: [variable: token]).get()
        XCTAssertFalse(output.text.contains(token), "Device token must stay in the parent")
        XCTAssertFalse(output.text.contains(variable))
        XCTAssertTrue(output.text.contains("DBUS_SESSION_BUS_ADDRESS="))
        XCTAssertEqual(tools.arguments, [["separate", "arguments"]])
    }

    func testDeviceSecretToolReceivesOnlyStdinAndLockedServiceHasNoPlaintextFallback() throws {
        let account = SecretAccount.device(UUID())
        try tools.install("secret-tool", script: FakeLinuxTools.recordArguments + #"""

        case "$1" in
        lookup) exit 1;;
        search) exit 0;;
        store) bytes=$(/bin/cat); test -n "$bytes";;
        clear) exit 0;;
        esac
        """#)
        let token = UUID().uuidString
        let store = LinuxSecretStore(paths: paths, runner: tools.runner)
        onWorker { XCTAssertEqual(try store.write(SecretValue(token), account: account), .secretService) }
        XCTAssertFalse(tools.log.joined().contains(token), "Secret must never enter argv")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configDirectory.appendingPathComponent("secrets-unencrypted.json").path))
        try tools.install("secret-tool", script: #"if [ "$1" = search ]; then printf '[locked item]'; exit 0; fi; exit 1"#)
        onWorker {
            XCTAssertThrowsError(try store.read(account: account, source: .effective)) { XCTAssertEqual($0 as? SecretStoreError, .locked) }
            XCTAssertThrowsError(try store.write(SecretValue(token), account: account)) { XCTAssertEqual($0 as? SecretStoreError, .locked) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configDirectory.appendingPathComponent("secrets-unencrypted.json").path))
    }

    func testStartupVerifiesBoundEnvironmentAndSignOutCannotResumeIt() throws {
        let connection = try seedConnection()
        tools.environment[Self.deviceVariable(connection.connectionID)] = transport.token
        compose()
        environment.start()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.accountModel?.state.enabled == true && self.environment.syncService?.report.lastSuccess != nil })
        XCTAssertEqual(environment.accountModel?.state.secretTier, .environment)
        XCTAssertTrue(environment.accountModel?.state.secretStorageMessage.contains("read-only") == true)
        XCTAssertFalse(transport.sentOnMain)
        let model = try XCTUnwrap(environment.accountModel)
        model.signOut()
        XCTAssertTrue(GTKTestSupport.spin { !model.state.isBusy && model.state.connection == nil })
        XCTAssertFalse(environment.syncService?.report.enabled == true)
        let requestCount = transport.requests.count
        model.startup()
        XCTAssertTrue(GTKTestSupport.spin { !model.state.isBusy })
        XCTAssertEqual(transport.requests.count, requestCount)
        XCTAssertTrue(tools.environment[Self.deviceVariable(connection.connectionID)] == transport.token)
    }

    func testLockedConfiguredAccountSuppressesSeedsAndDoesNotSendHTTP() throws {
        _ = try seedConnection()
        try tools.install("secret-tool", script: #"if [ "$1" = search ]; then printf '[locked item]'; exit 0; fi; exit 1"#)
        compose()
        environment.start()
        environment.settingsModel.markSetupPresented()
        environment.onboardingModel.useDefaultFolder()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.accountModel?.state.error == .secret(.locked) })
        XCTAssertNotNil(environment.accountModel?.state.connection)
        environment.onboardingModel.refresh()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.step == .tour })
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(try files().listFiles().isEmpty)
    }

    func testEnvironmentTokenForAnotherDeviceNeverEnablesSync() throws {
        let connection = try seedConnection()
        tools.environment[Self.deviceVariable(connection.connectionID)] = transport.token
        transport.wrongDevice = true
        compose()
        environment.start()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.accountModel?.state.error == .needsSignIn })
        XCTAssertFalse(environment.syncService?.report.enabled == true)
        XCTAssertEqual(transport.requests.map { $0.url.lastPathComponent }, ["me"])
    }

    func testLoginComposesViewerModesStatusAndDirtyEditorPrivateCopy() throws {
        transport.role = .editor
        compose()
        try login()
        XCTAssertTrue(GTKTestSupport.spin(until: { self.environment.syncService?.report.lastSuccess != nil }, timeout: .seconds(10)), String(describing: environment.syncService?.report))
        environment.showLibrary()
        let selection = LibraryPromptSelection(identity: .assigned(try XCTUnwrap(ULID(LinuxSyncTestTransport.groupPrompt))), relativePath: "Groups/Team/a.md")
        environment.editorModel.open(selection)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.editorModel.state.source != nil })
        environment.editorModel.edit("unsaved local draft")
        let generation = environment.editorModel.assistantSnapshot?.accessGeneration
        transport.role = .viewer
        environment.syncService?.syncNow()
        XCTAssertTrue(GTKTestSupport.spin(until: { !self.environment.editorModel.state.canEdit }, timeout: .seconds(10)), String(describing: environment.syncService?.report))
        XCTAssertEqual(environment.editorModel.state.source, "unsaved local draft")
        XCTAssertTrue(environment.editorModel.state.isDirty)
        XCTAssertTrue(environment.editorModel.state.canSaveAsCopy)
        XCTAssertNotEqual(environment.editorModel.assistantSnapshot?.accessGeneration, generation)
        XCTAssertEqual(try permissions("Groups/Team/a.md"), 0o444)
        XCTAssertTrue(environment.syncStatusModel?.state.enabled == true)
        XCTAssertTrue(GTKTestSupport.spin {
            guard let button = self.findWidget("library-save-copy") else { return false }
            return gtk_widget_get_sensitive(button) != 0
        })
    }

    func testFileCredentialRestartsThroughTheBoundAccountAndNeverEntersAppData() throws {
        compose()
        try login()
        XCTAssertTrue(GTKTestSupport.spin(until: { self.environment.syncService?.report.lastSuccess != nil }, timeout: .seconds(10)))
        let data = try RootedFileStore(root: paths.dataDirectory)
        for file in try data.listFiles() {
            XCTAssertNil(try data.read(at: file.relativePath).range(of: Data(transport.token.utf8)), "App data must be credential-free")
        }
        environment.shutdown()
        let previous = environment!
        let done = LinuxSyncTestFlag()
        Task.detached { await previous.drainSync(); done.set() }
        XCTAssertTrue(GTKTestSupport.spin { done.value })
        environment = nil
        compose()
        let model = try XCTUnwrap(environment.accountModel)
        XCTAssertTrue(GTKTestSupport.spin { !model.state.isBusy })
        model.startup()
        XCTAssertTrue(GTKTestSupport.spin(until: { !model.state.isBusy && model.state.enabled }, timeout: .seconds(10)))
        XCTAssertEqual(model.state.secretTier, .file)
        XCTAssertFalse(transport.sentOnMain)
        XCTAssertFalse(tools.log.joined().contains(transport.token), "Device token must not enter argv")
    }

    func testOwnWatcherWritesNeverLoopAndLaterExternalEditStillPushes() throws {
        compose()
        try login()
        XCTAssertTrue(GTKTestSupport.spin(until: { self.environment.syncService?.report.lastSuccess != nil }, timeout: .seconds(10)))
        let pulls = transport.pullCount
        waitForGLib(.seconds(4))
        XCTAssertEqual(transport.pullCount, pulls)
        XCTAssertEqual(transport.requests.filter { $0.method == .put }.count, 0)
        let source = "---\nid: " + LinuxSyncTestTransport.personalPrompt + "\n---\nExternal edit\n"
        try files().write(Data(source.utf8), at: "a.md")
        XCTAssertTrue(GTKTestSupport.spin(until: { self.transport.requests.contains { $0.method == .put } }, timeout: .seconds(6)))
        XCTAssertEqual(transport.requests.filter { $0.method == .put }.count, 1)
        let afterEdit = transport.pullCount
        waitForGLib(.seconds(4))
        XCTAssertEqual(transport.pullCount, afterEdit)
        XCTAssertEqual(transport.requests.filter { $0.method == .put }.count, 1)
    }

    func testRootReplacementDrainsHeldNetworkAndRejectsOldRepliesAndTimers() throws {
        let timer = LinuxSyncTestTimer()
        compose(timer: timer)
        transport.holdPull = true
        try login()
        XCTAssertTrue(GTKTestSupport.spin { self.transport.hasHeld })
        let oldAccount = try XCTUnwrap(environment.accountModel)
        let oldSync = try XCTUnwrap(environment.syncService)
        let oldTimers = timer.take(.seconds(60))
        let oldRoot = libraryRoot
        let target = tools.directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertEqual(environment.switchLibrary(to: target), .syncDraining)
        let heartbeat = LinuxSyncTestFlag()
        GTK.onMainLoop { heartbeat.set() }
        XCTAssertTrue(GTKTestSupport.spin { heartbeat.value })
        XCTAssertTrue(environment.syncService === oldSync)
        transport.releaseHeld()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.syncService !== oldSync && self.environment.syncService?.report.lastSuccess != nil })
        let requestCount = transport.requests.count
        oldTimers.forEach { $0() }
        oldAccount.startup()
        oldSync.syncNow()
        waitForGLib(.milliseconds(100))
        XCTAssertEqual(transport.requests.count, requestCount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent("late.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("late.md").path))
        XCTAssertEqual(environment.settingsModel.libraryFolderPath, target.path)
    }

    func testQuitWaitsForTheOldRequestAndCannotApplyItsLateResult() throws {
        compose()
        transport.holdPull = true
        try login()
        XCTAssertTrue(GTKTestSupport.spin { self.transport.hasHeld })
        var approved = false
        environment.requestQuit { approved = true }
        waitForGLib(.milliseconds(50))
        XCTAssertFalse(approved)
        transport.releaseHeld()
        XCTAssertTrue(GTKTestSupport.spin { approved })
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent("late.md").path))
        let count = transport.requests.count
        environment.syncService?.syncNow()
        waitForGLib(.milliseconds(50))
        XCTAssertEqual(transport.requests.count, count)
    }

    func testLostRootPreservesStateAndNeverSendsDeletes() throws {
        compose()
        try login()
        XCTAssertTrue(GTKTestSupport.spin(until: { self.environment.syncService?.report.lastSuccess != nil }, timeout: .seconds(10)))
        let state = paths.dataDirectory.appendingPathComponent("sync/state.json")
        let before = try Data(contentsOf: state)
        try FileManager.default.moveItem(at: libraryRoot, to: tools.directory.appendingPathComponent("old-library"))
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        // An immediate replacement can evade GIO's root-loss event. The pass
        // also checks the pinned incarnation, as the periodic fallback does.
        environment.syncService?.syncNow()
        XCTAssertTrue(GTKTestSupport.spin(until: {
            !self.environment.pickerModel.libraryAvailable && self.environment.syncService?.report.blockingIssue == .rootUnavailable
        }, timeout: .seconds(10)))
        XCTAssertFalse(transport.requests.contains { $0.method == .delete })
        XCTAssertEqual(try Data(contentsOf: state), before)
        XCTAssertEqual(environment.syncService?.report.blockingIssue, .rootUnavailable)
    }

    private var libraryRoot: URL { paths.documentsDirectory.appendingPathComponent("MonkeysPaw") }
    private func files() throws -> RootedFileStore { try RootedFileStore(root: libraryRoot, trashRoot: tools.directory.appendingPathComponent("Trash")) }
    private func permissions(_ path: String) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: libraryRoot.appendingPathComponent(path).path)[.posixPermissions] as? Int
    }
    private static func deviceVariable(_ id: UUID) -> String {
        "MONKEYSPAW_DEVICE_" + id.uuidString.replacingOccurrences(of: "-", with: "") + "_TOKEN"
    }
    private func compose(timer: Scheduler? = nil) {
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            scheduler: timer, syncTransport: transport)
        // Exercise the primary's watcher/index startup before account intents.
        _ = environment.libraryStatusModel
    }
    private func login() throws {
        let model = try XCTUnwrap(environment.accountModel)
        XCTAssertTrue(GTKTestSupport.spin { !model.state.isBusy })
        var password = "transient-password-" + UUID().uuidString
        model.login(server: "https://sync.example.test", username: "person", password: &password, deviceName: "Linux")
        XCTAssertTrue(password.isEmpty, "Login consumes secure input")
        XCTAssertTrue(GTKTestSupport.spin { !model.state.isBusy && model.state.enabled })
        XCTAssertEqual(model.state.secretTier, .file)
        XCTAssertTrue(model.state.secretStorageMessage.contains("unencrypted"))
    }
    private func seedConnection() throws -> SyncAccount {
        let data = try RootedFileStore(root: paths.dataDirectory)
        let account = try SyncAccount(identity: SyncAccountIdentity(serverURL: "https://sync.example.test", userID: XCTUnwrap(ULID(LinuxSyncTestTransport.user))),
            username: "person", deviceID: XCTUnwrap(ULID(LinuxSyncTestTransport.device)), deviceName: "Linux", connectionID: UUID())
        try SyncAccountStore(files: data, operations: data).setAccount(account)
        return account
    }
    private func waitForGLib(_ delay: Duration) {
        var elapsed = false
        GTK.after(delay.timeInterval) { elapsed = true }
        XCTAssertTrue(GTKTestSupport.spin(until: { elapsed }, timeout: delay + .seconds(2)))
    }
    private func onWorker(_ operation: @escaping () throws -> Void) {
        let done = LinuxSyncTestFlag()
        Task.detached {
            do { try operation() }
            catch { XCTFail("Worker returned an unexpected typed failure") }
            done.set()
        }
        XCTAssertTrue(GTKTestSupport.spin(until: { done.value }, timeout: .seconds(6)))
    }

    private func findWidget(_ name: String) -> GTK.Widget? {
        func find(_ widget: GTK.Widget) -> GTK.Widget? {
            if String(cString: gtk_widget_get_name(widget)) == name { return widget }
            var child = gtk_widget_get_first_child(widget)
            while let current = child {
                if let match = find(current) { return match }
                child = gtk_widget_get_next_sibling(current)
            }
            return nil
        }
        var windows = gtk_application_get_windows(application)
        while let node = windows {
            if let data = node.pointee.data, let match = find(mp_window_widget(data.assumingMemoryBound(to: GtkWindow.self))) { return match }
            windows = node.pointee.next
        }
        return nil
    }
}

private final class LinuxSyncTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}

private final class LinuxSyncTestTimer: Scheduler {
    private let lock = NSLock()
    private var pending: [(Duration, () -> Void)] = []
    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        lock.lock(); pending.append((delay, work)); lock.unlock()
    }
    func take(_ delay: Duration) -> [() -> Void] {
        lock.lock()
        let ready = pending.filter { $0.0 == delay }
        pending.removeAll { $0.0 == delay }
        lock.unlock()
        return ready.map { $0.1 }
    }
}

private final class LinuxSyncTestTransport: HTTPTransporting, @unchecked Sendable {
    static let user = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    static let device = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
    static let group = "01ARZ3NDEKTSV4RRFFQ69G5FAX"
    static let personalPrompt = "01ARZ3NDEKTSV4RRFFQ69G5FAY"
    static let groupPrompt = "01ARZ3NDEKTSV4RRFFQ69G5FAZ"
    let token = String(repeating: "a", count: 42) + "A"
    private let lock = NSLock()
    private var captured: [HTTPRequest] = []
    private var held: CheckedContinuation<HTTPResponse, Error>?
    private var mainRequest = false
    private var storedRole: SyncAPI.Role = .viewer
    private var shouldHold = false
    private var wrong = false
    private var privateContent = "---\nid: " + LinuxSyncTestTransport.personalPrompt + "\n---\nServer personal\n"
    private var privateRevision: Int64 = 1
    var role: SyncAPI.Role { get { locked { storedRole } } set { locked { storedRole = newValue } } }
    var holdPull: Bool { get { locked { shouldHold } } set { locked { shouldHold = newValue } } }
    var wrongDevice: Bool { get { locked { wrong } } set { locked { wrong = newValue } } }
    var requests: [HTTPRequest] { locked { captured } }
    var pullCount: Int { requests.filter { $0.url.path.hasSuffix("/sync/pull") }.count }
    var hasHeld: Bool { locked { held != nil } }
    var sentOnMain: Bool { locked { mainRequest } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        locked { captured.append(request); mainRequest = mainRequest || Thread.isMainThread }
        if request.url.path.hasSuffix("/login") { return try response(SyncAPI.AuthResponse(deviceToken: token, user: userDTO)) }
        if request.url.path.hasSuffix("/me") {
            let device = SyncAPI.Device(id: wrongDevice ? Self.group : Self.device, name: "Linux", createdAt: timestamp,
                lastSeenAt: nil, revokedAt: nil, isCurrent: true)
            return try response(SyncAPI.MeResponse(user: userDTO,
                groups: [.init(groupID: Self.group, name: "Team", role: role)], devices: [device]))
        }
        if request.url.path.hasSuffix("/sync/pull") {
            if locked({ let result = shouldHold; shouldHold = false; return result }) {
                return try await withCheckedThrowingContinuation { continuation in locked { held = continuation } }
            }
            return try pull()
        }
        if request.method == .put {
            let put = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self, from: request.body ?? Data())
            let revision = locked { privateContent = put.content; privateRevision += 1; return privateRevision }
            return try response(SyncAPI.WriteResponse(rev: revision, seq: revision))
        }
        return try response(SyncAPI.EmptyResponse())
    }

    func releaseHeld() {
        let continuation = locked { let value = held; held = nil; return value }
        guard let continuation else { return }
        do { continuation.resume(returning: try pull(path: "late.md")) }
        catch { continuation.resume(throwing: HTTPTransportError.invalidResponse) }
    }

    private let timestamp = "2026-10-14T00:00:00.000Z"
    private var userDTO: SyncAPI.User {
        .init(id: Self.user, username: "person", displayName: nil, accountKind: .member, createdAt: timestamp, disabledAt: nil)
    }
    private func pull(path: String = "a.md") throws -> HTTPResponse {
        let (privateBytes, revision) = locked { (privateContent, privateRevision) }
        let groupBytes = try CanonicalForm.group(Data(("---\nid: " + Self.groupPrompt + "\n---\nServer group\n").utf8), filename: "a.md").bytes
        return try response(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: [
            .init(identity: .user(userID: Self.user), mode: .snapshot, head: revision, cursor: "personal-\(revision)", hasMore: false,
                items: [.upsert(seq: revision, prompt: .init(id: Self.personalPrompt, rev: revision, path: path, content: privateBytes))]),
            .init(identity: .group(groupID: Self.group, name: "Team", role: role), mode: .snapshot, head: 1, cursor: "team", hasMore: false,
                items: [.upsert(seq: 1, prompt: .init(id: Self.groupPrompt, rev: 1, path: "a.md", content: String(decoding: groupBytes, as: UTF8.self)))])
        ], removed: []))
    }
    private func response<T: APIObjectDTO>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value))
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}
#endif
