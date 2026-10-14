import AppKit
import Darwin
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacSyncCompositionTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var delegate: AppDelegate!
    private var watchers: [MacSyncWatcher] = []
    private var originalWindows: Set<ObjectIdentifier> = []
    private var transport: MacSyncTransport!
    private var secrets: MacSyncSecrets!
    private var terminationReplies: [Bool] = []

    override func setUpWithError() throws {
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library", isDirectory: true)
        data = directory.appendingPathComponent("data", isDirectory: true)
        transport = MacSyncTransport()
        secrets = MacSyncSecrets()
    }

    override func tearDown() {
        transport.releaseHeldRequests()
        if let delegate, delegate.applicationShouldTerminate(NSApp) == .terminateLater {
            _ = spin { self.terminationReplies.last == true }
        }
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        delegate = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func start(work: BackgroundWork = DispatchBackgroundWork()) throws {
        delegate = AppDelegate(libraryRoot: root, dataRoot: data, backgroundWork: work,
            httpTransport: transport, secrets: secrets, replyToTermination: { [weak self] in self?.terminationReplies.append($0) },
            setActivationPolicy: { _ in }, activateApplication: {}, makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in false }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, makeFileWatcher: { [weak self] _, _ in
                let watcher = MacSyncWatcher()
                self?.watchers.append(watcher)
                return watcher
            })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertNotNil(delegate.syncComposition)
    }

    private func spin(_ predicate: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }

    private func login() throws {
        let account = try XCTUnwrap(delegate.accountModel)
        XCTAssertTrue(spin { !account.state.isBusy })
        var password = "Runtime-password-" + UUID().uuidString
        account.login(server: "https://example.test/paw", username: "person", password: &password, deviceName: "Mac")
        XCTAssertTrue(password.isEmpty, "The secure input was consumed")
        XCTAssertTrue(spin { !account.state.isBusy && account.state.enabled })
        XCTAssertTrue(spin { self.delegate.syncStatusModel?.state.lastSuccess != nil })
        // Explicit hosted opt-in also authorizes resuming after a root switch.
        delegate.startSync()
        XCTAssertTrue(spin { !account.state.isBusy && self.delegate.syncStatusModel?.state.phase == .idle })
    }

    private func otherRoot() throws -> URL {
        let other = directory.appendingPathComponent("other", isDirectory: true)
        let files = try RootedFileStore(root: other)
        try files.createRoot()
        try files.write(Data("Beta".utf8), at: "beta.md")
        return other
    }

    func testHostedLaunchConstructsSyncWithoutHTTPSecretsWindowsOrAccountAdmissions() throws {
        try start()
        XCTAssertTrue(AppDelegate.isRunningTests)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(secrets.readCount, 0)
        XCTAssertEqual(delegate.syncStatusModel?.state.footer, .disabled)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), originalWindows)
        let account = try XCTUnwrap(delegate.accountModel)
        XCTAssertTrue(spin { !account.state.isBusy })
        XCTAssertNil(account.state.connection)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(secrets.readCount, 0)
    }

    func testNativeLoginWritesOnlyBoundMetadataAndRealOnboardingPredicate() throws {
        try start()
        try login()
        XCTAssertTrue(try XCTUnwrap(delegate.syncComposition).accounts.hasConfiguredAccount)
        let account = try XCTUnwrap(delegate.accountModel)
        XCTAssertEqual(account.state.secretTier, .keychain)
        let files = try RootedFileStore(root: data)
        let accountBytes = try files.read(at: "sync/account.json")
        XCTAssertFalse(String(decoding: accountBytes, as: UTF8.self).contains(transport.token), "No token in account metadata")
        let settings = try XCTUnwrap(delegate.settingsModel)
        settings.markSetupPresented()
        settings.completeLibraryFolderStep()
        delegate.onboardingModel?.refresh()
        XCTAssertNotEqual(delegate.onboardingModel?.state.step, .seedOffer)
        account.signOut()
        XCTAssertTrue(spin { !account.state.isBusy && account.state.connection == nil })
        XCTAssertFalse(try XCTUnwrap(delegate.syncComposition).accounts.hasConfiguredAccount)
        delegate.onboardingModel?.refresh()
        XCTAssertEqual(delegate.onboardingModel?.state.step, .seedOffer)
    }

    func testGroupViewerModesAndPrivateCopyPolicyReachTheRealEditorAndAssistantContext() throws {
        transport.role = .viewer
        try start()
        try login()
        XCTAssertTrue(spin { self.delegate.libraryBrowserModel?.state.sections.contains { $0.id == .group(MacSyncTransport.group) } == true })
        let row = try XCTUnwrap(delegate.libraryBrowserModel?.state.rows.first { $0.relativePath == "Groups/Team/group.md" })
        let editor = try XCTUnwrap(delegate.editorModel)
        let presentation = try XCTUnwrap(delegate.libraryWindow?.presentation)
        presentation.openPrompt(row.selection)
        XCTAssertTrue(spin { editor.state.status != .loading && presentation.snapshot.selection == row.selection })
        XCTAssertEqual(editor.state.readOnlyReason, .groupViewer)
        XCTAssertTrue(editor.state.canSaveAsCopy)
        XCTAssertTrue(presentation.canSaveAsCopy)
        XCTAssertFalse(presentation.canSave)
        XCTAssertEqual(editor.assistantAccess, .group(.viewer))
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Groups/Team/group.md").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o444)
        let files = try RootedFileStore(root: root)
        let before = try files.read(at: "Groups/Team/group.md")
        XCTAssertTrue(presentation.canToggleFavorite)
        presentation.toggleFavorite()
        XCTAssertTrue(spin { presentation.snapshot.selectedPrompt?.favorite == true })
        XCTAssertEqual(try files.read(at: "Groups/Team/group.md"), before)
        transport.role = .editor
        delegate.syncComposition?.sync.syncNow()
        XCTAssertTrue(spin { editor.state.readOnlyReason == nil })
        XCTAssertEqual(editor.assistantAccess, .group(.editor))
        XCTAssertTrue(editor.state.canEdit)
    }

    func testInFlightPullDrainsBeforeReplacementAndLateOldEventsCannotWriteEitherRoot() throws {
        try start()
        try login()
        let oldGraph = try XCTUnwrap(delegate.syncComposition)
        let oldWatcher = try XCTUnwrap(watchers.first)
        transport.includePersonalPrompt = true
        transport.holdPull = true
        oldGraph.sync.syncNow()
        XCTAssertTrue(spin { self.transport.heldCount == 1 })
        let other = try otherRoot()
        XCTAssertEqual(delegate.switchLibrary(to: other), .syncBusy)
        XCTAssertEqual(delegate.libraryDirectory, root, "The original capabilities stay installed until drain completes")
        // The held reply contains an incoming prompt. A fresh root's later
        // legitimate snapshot is empty, isolating that retired reply.
        transport.includePersonalPrompt = false
        transport.releaseHeldRequests()
        XCTAssertTrue(spin { self.delegate.libraryDirectory == other && self.delegate.pickerModel?.libraryAvailable == true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("incoming.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("incoming.md").path))
        XCTAssertTrue(oldWatcher.stopped)
        oldWatcher.emit(.rootUnavailable(.notFound))
        oldWatcher.emit(.file(FileStoreEvent(relativePath: "incoming.md", kind: .created)))
        XCTAssertTrue(spin { self.delegate.syncStatusModel?.state.phase == .idle })
        XCTAssertTrue(delegate.pickerModel?.libraryAvailable == true)
        XCTAssertFalse(delegate.syncComposition === oldGraph)
        let bytes = try RootedFileStore(root: data).read(at: "sync/state.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(state["library_root"] as? String, other.path)
    }

    func testRetiredAccountAdmissionFinishesBeforeNewRootMetadataCanBeWritten() throws {
        try start()
        let old = try XCTUnwrap(delegate.accountModel)
        XCTAssertTrue(spin { !old.state.isBusy })
        delegate.startSync()
        XCTAssertTrue(spin { !old.state.isBusy })
        transport.holdLogin = true
        var password = "Runtime-password-" + UUID().uuidString
        old.login(server: "https://example.test/paw", username: "person", password: &password, deviceName: "Mac")
        XCTAssertTrue(spin { self.transport.heldCount == 1 })
        let other = try otherRoot()
        XCTAssertEqual(delegate.switchLibrary(to: other), .syncBusy)
        XCTAssertEqual(delegate.libraryDirectory, root)
        transport.releaseHeldRequests()
        XCTAssertTrue(spin { self.delegate.libraryDirectory == other && self.delegate.pickerModel?.libraryAvailable == true })
        XCTAssertNil(old.state.connection, "The retired model cannot publish the admitted login's result")
        let account = try XCTUnwrap(delegate.accountModel)
        XCTAssertTrue(spin { !account.state.isBusy && account.state.enabled })
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: RootedFileStore(root: data).read(at: "sync/state.json")) as? [String: Any])
        XCTAssertEqual(state["library_root"] as? String, other.path)
    }

    func testPhysicallyLostRootCannotInferDeleteEvenBeforeWatcherPublication() throws {
        transport.includePersonalPrompt = true
        try start()
        try login()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("incoming.md").path))
        try FileManager.default.moveItem(at: root, to: directory.appendingPathComponent("detached"))
        let count = transport.requests.count
        delegate.syncComposition?.sync.syncNow()
        XCTAssertTrue(spin { self.transport.requests.count > count && self.delegate.syncStatusModel?.state.phase == .idle })
        XCTAssertFalse(transport.requests.contains { $0.method == .delete })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        watchers[0].emit(.rootUnavailable(.notFound))
        XCTAssertTrue(spin { self.delegate.pickerModel?.libraryAvailable == false })
        XCTAssertEqual(delegate.syncStatusModel?.state.blockingIssue, .rootUnavailable)
    }

    func testColdStartupRefusesARecreatedRootWithRecordedCursors() throws {
        transport.includePersonalPrompt = true
        try start()
        try login()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try FileManager.default.moveItem(at: root, to: directory.appendingPathComponent("original"))
        let replacement = try RootedFileStore(root: root)
        try replacement.createRoot()
        let before = transport.requests.count
        try start()
        XCTAssertEqual(delegate.syncComposition?.rootIssue, .changed)
        XCTAssertFalse(delegate.pickerModel?.libraryAvailable == true)
        delegate.startSync()
        delegate.syncComposition?.sync.syncNow()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(transport.requests.count, before)
        XCTAssertFalse(transport.requests.contains { $0.method == .delete })
        XCTAssertEqual(try replacement.listFiles(), [])
    }

    func testColdConfiguredDefaultRootIsNeverAutomaticallyRecreated() throws {
        transport.includePersonalPrompt = true
        try start()
        try login()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try FileManager.default.moveItem(at: root, to: directory.appendingPathComponent("original"))
        let before = transport.requests.count
        try start()
        delegate.startSync()
        XCTAssertNotNil(delegate.syncComposition)
        XCTAssertFalse(delegate.pickerModel?.libraryAvailable == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(transport.requests.count, before)
        XCTAssertFalse(transport.requests.contains { $0.method == .delete })
    }

    func testNativeOwnWriteStampAndRawHashSuppressOnlyTheCommittedVersion() throws {
        transport.includePersonalPrompt = true
        try start()
        let account = try XCTUnwrap(delegate.accountModel)
        XCTAssertTrue(spin { !account.state.isBusy })
        var password = "Runtime-password-" + UUID().uuidString
        account.login(server: "https://example.test/paw", username: "person", password: &password, deviceName: "Mac")
        XCTAssertTrue(spin { !account.state.isBusy && self.delegate.syncStatusModel?.state.lastSuccess != nil })
        let before = transport.requests.count
        watchers[0].emit(.file(FileStoreEvent(relativePath: "incoming.md", kind: .modified)))
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertEqual(transport.requests.count, before, "Native stamp/raw hash must match the committed receipt")
        let files = try RootedFileStore(root: root)
        var edited = try files.read(at: "incoming.md")
        edited.append(Data("\nExternal change".utf8))
        try files.write(edited, at: "incoming.md")
        watchers[0].emit(.file(FileStoreEvent(relativePath: "incoming.md", kind: .modified)))
        XCTAssertTrue(spin { self.transport.requests.count > before })
    }

    func testNativeAppliedButUnflushedJournalRecoversExactServerAndLosingBytes() throws {
        let fault = MacSyncPublicationFault()
        let files = try RootedFileStore(root: root, syncIO: .init(flush: { fault.flush($0) }, rename: {
            fault.rename(from: $0, name: $1, to: $2, name: $3)
        }))
        try files.createRoot()
        try files.pinRoot()
        let losing = Data(("---\nid: " + MacSyncTransport.prompt.rawValue + "\n---\nLocal losing version").utf8)
        try files.write(losing, at: "incoming.md")
        let appData = try RootedFileStore(root: data)
        let library = LibraryService(library: files, data: appData, clock: SystemClock(), entropy: SystemEntropy())
        let states = SyncStateStore(files: appData, operations: appData)
        let accounts = SyncAccountStore(files: appData, operations: appData)
        let scheduler = DispatchSyncScheduler()
        let main = DispatchMainThread()
        let sync = try SyncService(library: library, libraryOperations: files, dataFiles: appData, dataOperations: appData,
            states: states, accounts: accounts, scheduler: scheduler, mainThread: main, clock: SystemClock(), entropy: SystemEntropy())
        let service = try SyncAccountService(sync: sync, accounts: accounts, secrets: secrets, transport: transport, libraryRoot: root.path)
        let account = AccountModel(account: service, mainThread: main)
        transport.includePersonalPrompt = true
        XCTAssertTrue(spin { !account.state.isBusy })
        var password = "Runtime-password-" + UUID().uuidString
        account.login(server: "https://example.test/paw", username: "person", password: &password, deviceName: "Mac")
        XCTAssertTrue(spin { !account.state.isBusy && sync.report.blockingIssue == .recoveryRequired })
        XCTAssertNotNil(try appData.stamp(at: "sync/apply.json"))
        XCTAssertThrowsError(try library.entries(), "Ordinary reads remain blocked until the apply journal settles")
        fault.disable()
        account.retire()
        let recovered = expectation(description: "The original journal drains and replays")
        Task.detached {
            await account.drain()
            sync.stop()
            await sync.drain()
            do { try await sync.recoverJournal() }
            catch { XCTFail("Native journal recovery failed") }
            XCTAssertEqual(sync.retire(), .stopped)
            scheduler.tearDown()
            main.run { recovered.fulfill() }
        }
        wait(for: [recovered], timeout: 5)
        XCTAssertNil(try appData.stamp(at: "sync/apply.json"))
        XCTAssertEqual(try files.read(at: "incoming.md"), MacSyncTransport.incomingBytes)
        let copies = try library.entries().filter { $0.relativePath.hasPrefix("Conflicts/") }
        XCTAssertEqual(copies.count, 1)
        XCTAssertTrue(copies.first?.document.body.contains("Local losing version") == true)
        let retained = try appData.listFiles().filter { $0.relativePath.hasPrefix("sync/retained/") && $0.relativePath.hasSuffix(".bin") }
        XCTAssertTrue(try retained.contains { try appData.read(at: $0.relativePath) == losing })
    }

    func testQuitWaitsForAnAdmittedPullAndRepliesExactlyOnce() throws {
        try start()
        try login()
        transport.holdPull = true
        delegate.syncComposition?.sync.syncNow()
        XCTAssertTrue(spin { self.transport.heldCount == 1 })
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        XCTAssertTrue(terminationReplies.isEmpty)
        transport.releaseHeldRequests()
        XCTAssertTrue(spin { self.terminationReplies.count == 1 })
        XCTAssertEqual(terminationReplies, [true])
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
    }

    func testQueuedOldEditorReadAndWatcherCallbackCannotReviveTheNewGraph() throws {
        let work = MacSyncHeldWork()
        try start(work: work)
        let files = try RootedFileStore(root: root)
        try files.write(Data("Alpha".utf8), at: "alpha.md")
        watchers[0].emit(.file(FileStoreEvent(relativePath: "alpha.md", kind: .created)))
        // The delivery scheduler debounces native changes. Read through the
        // already composed picker after its index notification arrives.
        XCTAssertTrue(spin { self.delegate.pickerModel?.results.contains { $0.relativePath == "alpha.md" } == true })
        let row = try XCTUnwrap(delegate.pickerModel?.results.first { $0.relativePath == "alpha.md" })
        let old = try XCTUnwrap(delegate.editorModel)
        old.open(LibraryPromptSelection(identity: row.identity, relativePath: "alpha.md"))
        XCTAssertEqual(old.state.status, .loading)
        let other = try otherRoot()
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        work.drain()
        XCTAssertTrue(spin { self.delegate.pickerModel?.results.map(\.relativePath) == ["beta.md"] })
        XCTAssertNil(delegate.editorModel?.state.prompt)
        XCTAssertEqual(try RootedFileStore(root: other).listFiles().map(\.relativePath), ["beta.md"])
    }

    func testSyncSchedulerFiresOffUIOnceAndTeardownReleasesPendingCaptures() {
        let scheduler = DispatchSyncScheduler()
        let fired = expectation(description: "A sync timer fires off UI")
        scheduler.after(.zero) {
            XCTAssertFalse(Thread.isMainThread)
            fired.fulfill()
        }
        wait(for: [fired], timeout: 3)
        weak var capture: MacSyncTimerCapture?
        do {
            let owned = MacSyncTimerCapture()
            capture = owned
            scheduler.after(.seconds(60)) { _ = owned; XCTFail("A retired timer must not fire") }
        }
        scheduler.tearDown()
        XCTAssertNil(capture)
        scheduler.after(.zero) { XCTFail("A retired scheduler cannot admit a callback") }
        scheduler.tearDown()
    }
}

private final class MacSyncTimerCapture {}

private final class MacSyncPublicationFault {
    private let lock = NSLock()
    private var armed = true
    private var applied = false
    func flush(_ descriptor: Int32) -> Bool {
        lock.lock(); let reject = armed && applied; lock.unlock()
        return !reject && fsync(descriptor) == 0
    }
    func rename(from source: Int32, name sourceName: String, to destination: Int32, name destinationName: String) -> Bool {
        let result = renameat(source, sourceName, destination, destinationName) == 0
        lock.lock()
        if result && destinationName == "incoming.md" { applied = true }
        lock.unlock()
        return result
    }
    func disable() { lock.lock(); armed = false; lock.unlock() }
}

private final class MacSyncWatcher: FileStoreWatcher {
    private var callback: (@Sendable (FileStoreWatchEvent) -> Void)?
    private(set) var stopped = false
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws { callback = onEvent; stopped = false }
    func stop() { stopped = true }
    // Retain the callback deliberately, like a native event already enqueued.
    func emit(_ event: FileStoreWatchEvent) { callback?(event) }
}

private final class MacSyncHeldWork: BackgroundWork {
    private let lock = NSLock()
    private var pending: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { lock.lock(); pending.append(work); lock.unlock() }
    func drain() {
        DispatchQueue.global().sync {
            while true {
                self.lock.lock()
                let next = self.pending.isEmpty ? nil : self.pending.removeFirst()
                self.lock.unlock()
                guard let next else { return }
                next()
            }
        }
    }
}

private final class MacSyncSecrets: SecretStore {
    private let lock = NSLock()
    private var entries: [SecretAccount: SecretValue] = [:]
    private var reads = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return entries[account].map { StoredSecret(value: $0, tier: .keychain) }
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        lock.lock(); defer { lock.unlock() }
        entries[account] = value
        return .keychain
    }
    func delete(account: SecretAccount) throws { lock.lock(); defer { lock.unlock() }; entries[account] = nil }
}

private final class MacSyncTransport: HTTPTransporting, @unchecked Sendable {
    static let user = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!
    static let device = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAW")!
    static let prompt = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAX")!
    static let group = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAY")!
    static var incomingBytes: Data { Data(("---\nid: " + prompt.rawValue + "\n---\nIncoming").utf8) }
    let token = String(repeating: "a", count: 42) + "A"
    private let lock = NSLock()
    private var stored: [HTTPRequest] = []
    private var held: [(CheckedContinuation<HTTPResponse, Error>, HTTPResponse)] = []
    private var storedRole: SyncAPI.Role?
    private var personal = false
    private var pullHeld = false
    private var loginHeld = false
    var requests: [HTTPRequest] { locked { stored } }
    var heldCount: Int { locked { held.count } }
    var role: SyncAPI.Role? { get { locked { storedRole } } set { locked { storedRole = newValue } } }
    var includePersonalPrompt: Bool { get { locked { personal } } set { locked { personal = newValue } } }
    var holdPull: Bool { get { locked { pullHeld } } set { locked { pullHeld = newValue } } }
    var holdLogin: Bool { get { locked { loginHeld } } set { locked { loginHeld = newValue } } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try locked { () throws -> HTTPResponse in
            stored.append(request)
            let user = SyncAPI.User(id: Self.user.rawValue, username: "person", displayName: nil, accountKind: .member,
                createdAt: "2026-10-14T00:00:00.000Z", disabledAt: nil)
            if request.url.path.hasSuffix("/login") { return try http(SyncAPI.AuthResponse(deviceToken: token, user: user)) }
            if request.url.path.hasSuffix("/me") {
                return try http(SyncAPI.MeResponse(user: user, groups: storedRole.map {
                    [SyncAPI.GroupMembership(groupID: Self.group.rawValue, name: "Team", role: $0)]
                } ?? [], devices: [SyncAPI.Device(id: Self.device.rawValue, name: "Mac", createdAt: "2026-10-14T00:00:00.000Z",
                    lastSeenAt: nil, revokedAt: nil, isCurrent: true)]))
            }
            if request.url.path.hasSuffix("/sync/pull") {
                let personalItems: [SyncAPI.FeedItem] = personal ? [.upsert(seq: 1, prompt: .init(id: Self.prompt.rawValue,
                    rev: 1, path: "incoming.md", content: String(decoding: Self.incomingBytes, as: UTF8.self)))] : []
                var scopes = [SyncAPI.SyncScope(identity: .user(userID: Self.user.rawValue), mode: .snapshot, head: personal ? 1 : 0,
                    cursor: "opaque-user", hasMore: false, items: personalItems)]
                if let role = storedRole {
                    let content = "---\nformat: 1\nid: " + Self.prompt.rawValue + "\ntitle: Group\n---\nShared"
                    let canonical = try CanonicalForm.group(Data(content.utf8), filename: "group.md").bytes
                    scopes.append(.init(identity: .group(groupID: Self.group.rawValue, name: "Team", role: role), mode: .snapshot,
                        head: 1, cursor: "opaque-group", hasMore: false, items: [.upsert(seq: 1, prompt: .init(id: Self.prompt.rawValue,
                            rev: 1, path: "group.md", content: String(decoding: canonical, as: UTF8.self)))]))
                }
                return try http(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: scopes, removed: []))
            }
            if request.method == .put {
                let object: [String: Any]
                if let bytes = request.body, let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] { object = body }
                else { object = [:] }
                let base = (object["base_rev"] as? NSNumber)?.int64Value ?? 0
                return try http(SyncAPI.WriteResponse(rev: base + 1, seq: 2))
            }
            return try http(SyncAPI.EmptyResponse())
        }
        let shouldHold = locked { request.url.path.hasSuffix("/sync/pull") && pullHeld || request.url.path.hasSuffix("/login") && loginHeld }
        if !shouldHold { return response }
        // Ignore cancellation deliberately: composition must drain even a
        // transport callback that arrives after its graph has been stopped.
        return try await withCheckedThrowingContinuation { reply in locked { held.append((reply, response)) } }
    }

    func releaseHeldRequests() {
        let replies = locked { () -> [(CheckedContinuation<HTTPResponse, Error>, HTTPResponse)] in
            pullHeld = false; loginHeld = false
            let result = held; held.removeAll()
            return result
        }
        for (reply, response) in replies { reply.resume(returning: response) }
    }

    private func http<T: Encodable>(_ value: T) throws -> HTTPResponse { HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value)) }
    private func locked<T>(_ work: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try work() }
}
