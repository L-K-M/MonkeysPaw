import AppKit
import Combine
import MonkeysPawCore
import SwiftUI
import XCTest
@testable import MonkeysPaw

/// Hosted native composition with real files and Core resolution; no paid keys.
final class MacConflictViewTests: XCTestCase {
    func testKeepMineDisplaysAndSendsExactCandidateBytes() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        let view = try h.open()
        let preview = try XCTUnwrap(view.state?.preview)
        let candidate = try XCTUnwrap(preview.candidateBytes)
        let diff = try XCTUnwrap(view.diff)
        let candidateRows = (diff.frontMatter + diff.body).filter { $0.kind != .removed }
        let displayed = candidateRows.reduce(into: Data()) { $0.append($1.bytes) }
        XCTAssertEqual(displayed, candidate)
        let serverRows = (diff.frontMatter + diff.body).filter { $0.kind != .added }
        XCTAssertEqual(serverRows.reduce(into: Data()) { $0.append($1.bytes) }, preview.serverBytes)
        XCTAssertFalse(String(decoding: candidate, as: UTF8.self).contains("x-monkeyspaw-conflict-of"))
        XCTAssertEqual(PromptCodec.parseFile(candidate, filename: "original.md").frontMatter.id?.rawValue,
            MacConflictTransport.original)
        XCTAssertTrue(diff.body.contains { $0.bytes.last != 10 })
        XCTAssertFalse(diff.placeholderWarnings.isEmpty)
        let renderer = LibraryDiffView(diff: diff)
        XCTAssertEqual(renderer.title, "Merged diff")
        XCTAssertEqual(renderer.originalTitle, "Current")
        XCTAssertEqual(renderer.candidateTitle, "Candidate")
        XCTAssertEqual(renderer.accessibilityID, "library-assistant-diff")
        let host = NSHostingView(rootView: LibraryConflictView(presentation: view))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 640)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(h.transport.originalPuts.isEmpty)
        view.requestResolution(.keepMine)
        h.drainResolver()
        let sent = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self,
            from: XCTUnwrap(h.transport.originalPuts.first?.body))
        XCTAssertEqual(Data(sent.content.utf8), candidate)
        XCTAssertEqual(sent.baseRev, 1)
        XCTAssertNil(try h.files.stamp(at: MacConflictTransport.copyPath))
        XCTAssertFalse(h.transport.sentOnMain)
    }

    func testKeepServerTrashesOnlyThePrivateCopy() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        let view = try h.open()
        let original = try h.files.read(at: "original.md")
        view.requestResolution(.keepServer)
        h.drainResolver()
        XCTAssertNil(try h.files.stamp(at: MacConflictTransport.copyPath))
        XCTAssertEqual(try h.files.read(at: "original.md"), original)
        XCTAssertTrue(h.transport.originalPuts.isEmpty)
    }

    func testKeepBothPreservesIdentityAndBodyAndClearsTheMarker() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        let view = try h.open()
        let before = PromptCodec.parseFile(try h.files.read(at: MacConflictTransport.copyPath), filename: "copy.md")
        view.requestResolution(.keepBoth)
        h.drainResolver()
        let bytes = try h.files.read(at: MacConflictTransport.copyPath)
        let after = PromptCodec.parseFile(bytes, filename: "copy.md")
        XCTAssertEqual(after.frontMatter.id, before.frontMatter.id)
        XCTAssertEqual(Data(after.body.utf8), Data(before.body.utf8))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("x-monkeyspaw-conflict-of"))
        XCTAssertTrue(h.transport.originalPuts.isEmpty)
        XCTAssertTrue(h.spin { h.presentation.snapshot.rows.allSatisfy { $0.conflictOrigin == nil } })
    }

    func testStaleHeadForMineAndServerRequiresAnotherExplicitChoice() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        let view = try h.open()
        for action in [ConflictResolutionAction.keepMine, .keepServer] {
            h.transport.advanceHead()
            view.requestResolution(action)
            XCTAssertTrue(h.spin { view.state?.error == .headChanged && view.canResolve(action) })
            XCTAssertTrue(view.message.contains("choose again"))
            XCTAssertTrue(String(decoding: try XCTUnwrap(view.state?.preview?.serverBytes), as: UTF8.self)
                .contains("Updated server"))
            XCTAssertEqual(try h.files.read(at: MacConflictTransport.copyPath), h.transport.copyBytes)
            XCTAssertTrue(h.transport.originalPuts.isEmpty)
        }
        let candidate = try XCTUnwrap(view.state?.preview?.candidateBytes)
        view.requestResolution(.keepMine)
        h.drainResolver()
        let sent = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self,
            from: XCTUnwrap(h.transport.originalPuts.first?.body))
        XCTAssertEqual(sent.baseRev, 3)
        XCTAssertEqual(Data(sent.content.utf8), candidate)
    }

    func testViewerCannotKeepMineAndCanKeepBoth() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        h.transport.groupRole = .viewer
        let view = try h.open()
        XCTAssertEqual(view.state?.preview?.mineRefusal, .accessDenied)
        XCTAssertFalse(view.canResolve(.keepMine))
        XCTAssertTrue(view.canResolve(.keepBoth))
        view.requestResolution(.keepMine)
        XCTAssertTrue(h.transport.originalPuts.isEmpty)
        XCTAssertEqual(try h.files.read(at: MacConflictTransport.copyPath), h.transport.copyBytes)
        view.requestResolution(.keepBoth)
        h.drainResolver()
        XCTAssertNotNil(try h.files.stamp(at: MacConflictTransport.copyPath))
    }

    func testDeniedAndOfflineWritesPreserveThePrivateCopy() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        let view = try h.open()
        for failure in [SyncAPI.FailureCode.forbidden, .internalError] {
            h.transport.putFailure = failure
            view.requestResolution(.keepMine)
            let expected: ConflictResolutionFailure = failure == .forbidden ? .accessDenied : .offline
            XCTAssertTrue(h.spin { view.state?.error == expected })
            XCTAssertEqual(try h.files.read(at: MacConflictTransport.copyPath), h.transport.copyBytes)
            XCTAssertTrue(view.canResolve(.keepBoth))
            if failure == .forbidden {
                XCTAssertFalse(view.canResolve(.keepMine))
                view.refreshComparison()
                _ = try h.ready()
            }
        }
    }

    func testMissingOriginalAndRescuedCopyOfferOnlyKeepBoth() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        h.transport.getFailure = .notFound
        var view = try h.open()
        XCTAssertFalse(view.canResolve(.keepMine))
        XCTAssertFalse(view.canResolve(.keepServer))
        XCTAssertTrue(view.canResolve(.keepBoth))
        let rescued = "---\nid: " + MacConflictTransport.copyID + "\nx-monkeyspaw-rescued: true\n---\nRescued"
        try h.files.write(Data(rescued.utf8), at: MacConflictTransport.copyPath)
        h.watcher.emit(.file(FileStoreEvent(relativePath: MacConflictTransport.copyPath, kind: .modified)))
        XCTAssertTrue(h.spin { h.presentation.snapshot.selectedPrompt?.conflictOrigin == .rescued
            && h.presentation.conflict?.state?.preview?.originalID == nil })
        view = try h.ready()
        XCTAssertFalse(view.canResolve(.keepMine))
        XCTAssertFalse(view.canResolve(.keepServer))
        view.requestResolution(.keepBoth)
        h.drainResolver()
        XCTAssertEqual(PromptCodec.parseFile(try h.files.read(at: MacConflictTransport.copyPath), filename: "copy.md").body, "Rescued")
    }

    func testSelectionAndRenameUseOriginRatherThanFilename() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        _ = try h.open()
        let ordinary = "Conflicts/Personal/name (conflict Mac 2026-10-15 1200).md"
        try h.files.write(Data("Ordinary".utf8), at: ordinary)
        h.watcher.emit(.file(FileStoreEvent(relativePath: ordinary, kind: .created)))
        XCTAssertTrue(h.spin { h.presentation.snapshot.sections.first { $0.id == .all }?.count == 3 })
        h.presentation.selectSection(.conflicts)
        XCTAssertEqual(h.presentation.snapshot.rows.map(\.relativePath.string), [MacConflictTransport.copyPath])
        XCTAssertNotNil(h.presentation.snapshot.selectedPrompt?.conflictOrigin)
        h.presentation.requestFileCommand(.rename)
        let request = try XCTUnwrap(h.presentation.fileCommandRequest)
        h.presentation.resolveFileCommand(.rename("renamed.md"), id: request.id)
        XCTAssertTrue(h.spin { h.presentation.snapshot.selection?.relativePath == "Elsewhere/renamed.md"
            && h.presentation.conflict?.state?.preview?.copy.relativePath == "Elsewhere/renamed.md" })
        let view = try h.ready()
        XCTAssertTrue(view.canResolve(.keepBoth))
        XCTAssertNil(try h.files.stamp(at: MacConflictTransport.copyPath))
        h.presentation.selectSection(.all)
        h.presentation.selectPath("original.md")
        XCTAssertTrue(h.spin { h.presentation.editorState.prompt?.relativePath == "original.md" && h.presentation.conflict == nil })
        XCTAssertNil(h.delegate.conflictModel?.state.preview)
        XCTAssertNotNil(try h.files.stamp(at: ordinary))
    }

    func testUnsavedGuardCancelAndSaveRequireAFreshChoice() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        let view = try h.open()
        let draft = try XCTUnwrap(h.presentation.editorState.source) + "\nNew unsaved edit"
        h.presentation.edit(draft)
        view.requestResolution(.keepMine)
        XCTAssertEqual(h.presentation.editorState.pendingDecision?.action, .revert)
        try h.dialogs.respond(.decision(.cancel))
        XCTAssertEqual(h.presentation.editorState.source, draft)
        XCTAssertTrue(h.presentation.editorState.isDirty)
        XCTAssertTrue(h.transport.originalPuts.isEmpty)
        view.requestResolution(.keepMine)
        try h.dialogs.respond(.decision(.save))
        XCTAssertTrue(h.spin { h.presentation.editorState.pendingDecision == nil
            && h.presentation.editorState.status != .loading && view.canResolve(.keepMine) })
        XCTAssertTrue(h.transport.originalPuts.isEmpty)
        let bytes = try XCTUnwrap(view.state?.preview?.candidateBytes)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("New unsaved edit"))
        view.requestResolution(.keepMine)
        h.drainResolver()
        let sent = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self,
            from: XCTUnwrap(h.transport.originalPuts.first?.body))
        XCTAssertEqual(Data(sent.content.utf8), bytes)
    }

    func testDirtySelectionGuardOpensComparisonOnlyAfterApproval() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        _ = try h.open()
        h.presentation.selectSection(.all)
        h.presentation.selectPath("original.md")
        XCTAssertTrue(h.spin { h.presentation.editorState.prompt?.relativePath == "original.md"
            && h.presentation.editorState.source != nil })
        h.presentation.edit("Unsaved original")
        h.presentation.selectPath(RelativePath(MacConflictTransport.copyPath))
        XCTAssertNotNil(h.presentation.editorState.pendingDecision)
        XCTAssertNil(h.presentation.conflict)
        XCTAssertEqual(h.presentation.snapshot.selection?.relativePath, "original.md")
        try h.dialogs.respond(.decision(.cancel))
        XCTAssertEqual(h.presentation.editorState.source, "Unsaved original")
        h.presentation.selectPath(RelativePath(MacConflictTransport.copyPath))
        try h.dialogs.respond(.decision(.discard))
        let view = try h.ready()
        h.presentation.edit(try XCTUnwrap(h.presentation.editorState.source) + "\nDiscard this draft")
        view.requestResolution(.keepBoth)
        try h.dialogs.respond(.decision(.discard))
        XCTAssertTrue(h.spin { view.canResolve(.keepBoth) && !h.presentation.editorState.isDirty })
        XCTAssertEqual(try h.files.read(at: MacConflictTransport.copyPath), h.transport.copyBytes)
        view.requestResolution(.keepBoth)
        h.drainResolver()
        XCTAssertFalse(String(decoding: try h.files.read(at: MacConflictTransport.copyPath), as: UTF8.self)
            .contains("Discard this draft"))
    }

    func testCloseCancelPreservesDraftAndApprovedCloseRevokesPreview() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        let view = try h.open()
        h.presentation.edit(try XCTUnwrap(h.presentation.editorState.source) + "\nDraft")
        h.delegate.libraryWindow?.requestClose()
        try h.dialogs.respond(.decision(.cancel))
        XCTAssertTrue(h.delegate.libraryWindow?.window?.isVisible == true)
        XCTAssertTrue(h.presentation.editorState.isDirty)
        XCTAssertTrue(h.presentation.conflict === view)
        h.delegate.libraryWindow?.requestClose()
        try h.dialogs.respond(.decision(.discard))
        XCTAssertFalse(h.delegate.libraryWindow?.window?.isVisible == true)
        XCTAssertNil(h.presentation.conflict)
        XCTAssertNil(h.delegate.conflictModel?.state.preview)
        XCTAssertFalse(view.canResolve(.keepBoth))
        XCTAssertEqual(try h.files.read(at: MacConflictTransport.copyPath), h.transport.copyBytes)
        h.delegate.showLibrary()
        _ = try h.ready()
    }

    func testResolvingDisablesEditsAndClosedLateAcknowledgementKeepsCopy() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        let view = try h.open()
        let source = h.presentation.editorState.source
        h.transport.holdNext = .put
        view.requestResolution(.keepMine)
        XCTAssertTrue(h.spin { h.transport.hasHeld && view.isResolving })
        XCTAssertFalse(h.presentation.canEditSource)
        XCTAssertFalse(h.presentation.canSave)
        XCTAssertFalse(h.presentation.canSaveAsCopy)
        XCTAssertFalse(h.presentation.canRunFileCommand)
        XCTAssertFalse(h.presentation.canToggleFavorite)
        XCTAssertFalse(view.canResolve(.keepBoth))
        h.presentation.edit("Must not replace the editor")
        h.presentation.requestFileCommand(.delete)
        XCTAssertEqual(h.presentation.editorState.source, source)
        XCTAssertNil(h.presentation.fileCommandRequest)
        h.delegate.libraryWindow?.requestClose()
        XCTAssertNil(h.presentation.conflict)
        h.transport.releaseHeld()
        h.drainResolver()
        XCTAssertEqual(try h.files.read(at: MacConflictTransport.copyPath), h.transport.copyBytes)
        XCTAssertNil(view.state)
    }

    func testRebindDropsHeldPreviewAndAllPublicationsStayOnMainThread() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        let view = try h.open()
        let observation = view.$state.sink { _ in XCTAssertTrue(Thread.isMainThread) }
        defer { observation.cancel() }
        h.transport.holdNext = .get
        view.refreshComparison()
        XCTAssertTrue(h.spin { h.transport.hasHeld })
        h.delegate.libraryWindow?.rebind(to: try XCTUnwrap(h.delegate.libraryBrowserModel),
            editor: try XCTUnwrap(h.delegate.editorModel), libraryPath: h.root.path, available: true)
        XCTAssertFalse(h.presentation.conflict === view)
        h.transport.releaseHeld()
        h.drainResolver()
        XCTAssertNil(view.state)
        XCTAssertNil(h.presentation.conflict?.state?.preview)
        XCTAssertFalse(view.canResolve(.keepBoth))
        XCTAssertEqual(try h.files.read(at: MacConflictTransport.copyPath), h.transport.copyBytes)
    }

    func testLibraryOpenedBeforeLoginUsesTheComposedConflictProvider() throws {
        let h = try MacConflictHarness()
        defer { h.close() }
        h.start()
        h.delegate.showLibrary()
        let window = try XCTUnwrap(h.delegate.libraryWindow?.window)
        XCTAssertNil(h.presentation.conflict)
        let view = try h.signInAndSelect()
        XCTAssertTrue(h.delegate.libraryWindow?.window === window)
        XCTAssertTrue(view.canResolve(.keepBoth))
    }
}

private final class MacConflictHarness {
    let directory: URL
    let root: URL
    let files: RootedFileStore
    let transport = MacConflictTransport()
    let watcher: MacConflictWatcher
    let dialogs: MacConflictDialogs
    let delegate: AppDelegate
    private var started = false
    var presentation: LibraryViewState { delegate.libraryWindow!.presentation }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library", isDirectory: true)
        files = try RootedFileStore(root: root)
        try files.createRoot()
        let dialogs = MacConflictDialogs()
        self.dialogs = dialogs
        let watcher = MacConflictWatcher()
        self.watcher = watcher
        delegate = AppDelegate(libraryRoot: root, dataRoot: directory.appendingPathComponent("data"),
            httpTransport: transport, secrets: MacConflictSecrets(), editorDialog: { _, dialog, respond in
                dialogs.present(dialog, respond: respond)
            }, setActivationPolicy: { _ in }, activateApplication: {}, makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in false }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, makeFileWatcher: { _, _ in watcher })
    }

    func start() {
        guard !started else { return }
        started = true
        XCTAssertTrue(AppDelegate.isRunningTests)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    func open() throws -> LibraryConflictViewState { start(); return try signInAndSelect() }

    func signInAndSelect() throws -> LibraryConflictViewState {
        let account = try XCTUnwrap(delegate.accountModel)
        XCTAssertTrue(spin { !account.state.isBusy })
        var password = "test-password"
        account.login(server: "https://sync.example.test", username: "person", password: &password, deviceName: "Mac")
        XCTAssertTrue(spin { account.state.enabled && self.delegate.syncStatusModel?.state.lastSuccess != nil })
        delegate.showLibrary()
        XCTAssertTrue(spin { self.presentation.snapshot.rows.contains { $0.relativePath.string == MacConflictTransport.copyPath } })
        presentation.selectSection(.conflicts)
        presentation.selectPath(RelativePath(MacConflictTransport.copyPath))
        return try ready()
    }

    func ready() throws -> LibraryConflictViewState {
        XCTAssertTrue(spin { self.presentation.conflict?.canResolve(.keepBoth) == true })
        return try XCTUnwrap(presentation.conflict)
    }

    func drainResolver() {
        guard let model = delegate.conflictModel else { return }
        let done = MacConflictFlag()
        Task.detached { await model.drain(); done.set() }
        XCTAssertTrue(spin { done.value })
    }

    func close() {
        transport.releaseHeld()
        if let graph = delegate.syncComposition {
            graph.retireModels()
            let done = MacConflictFlag()
            Task.detached { _ = await graph.drainAndRetire(); done.set() }
            XCTAssertTrue(spin { done.value })
        }
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try? FileManager.default.removeItem(at: directory)
    }

    func spin(_ predicate: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
}

private final class MacConflictDialogs {
    private var response: ((LibraryEditorResponse) -> Void)?
    private var dialog: LibraryEditorDialog?
    func present(_ dialog: LibraryEditorDialog, respond: @escaping (LibraryEditorResponse) -> Void) -> () -> Void {
        self.dialog = dialog
        response = respond
        return { [weak self] in self?.response = nil; self?.dialog = nil }
    }
    func respond(_ value: LibraryEditorResponse) throws {
        let dialog = try XCTUnwrap(dialog)
        XCTAssertTrue(dialog.accepts(value))
        let reply = try XCTUnwrap(response)
        response = nil
        self.dialog = nil
        reply(value)
    }
}

private final class MacConflictWatcher: FileStoreWatcher {
    private var callback: (@Sendable (FileStoreWatchEvent) -> Void)?
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws { callback = onEvent }
    func stop() { callback = nil }
    func emit(_ event: FileStoreWatchEvent) { callback?(event) }
}

private final class MacConflictSecrets: SecretStore {
    private let lock = NSLock()
    private var values: [SecretAccount: SecretValue] = [:]
    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        lock.lock(); defer { lock.unlock() }
        return values[account].map { StoredSecret(value: $0, tier: .keychain) }
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        lock.lock(); defer { lock.unlock() }
        values[account] = value
        return .keychain
    }
    func delete(account: SecretAccount) throws { lock.lock(); defer { lock.unlock() }; values[account] = nil }
}

private final class MacConflictFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}

/// Real account/sync/resolution models and native files; only HTTP is stubbed.
private final class MacConflictTransport: HTTPTransporting, @unchecked Sendable {
    static let user = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    static let device = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
    static let group = "01ARZ3NDEKTSV4RRFFQ69G5FAX"
    static let original = "01ARZ3NDEKTSV4RRFFQ69G5FAY"
    static let copyID = "01ARZ3NDEKTSV4RRFFQ69G5FAZ"
    static let copyPath = "Elsewhere/copy.md"
    let copyBytes = Data(("---\nid: " + copyID + "\nx-monkeyspaw-conflict-of: " + original
        + "\n---\nMine Cafe\u{301}\n{{new}}").utf8)
    private let lock = NSRecursiveLock()
    private var requests: [HTTPRequest] = []
    private var held: (HTTPRequest, CheckedContinuation<HTTPResponse, Error>)?
    private var storedHold: HTTPMethod?
    private var storedGetFailure: SyncAPI.FailureCode?
    private var storedPutFailure: SyncAPI.FailureCode?
    private var storedRole: SyncAPI.Role?
    private var server = "---\nid: " + original + "\n---\nServer Café\n{{old}}\n"
    private var rev: Int64 = 1
    private var mainRequest = false
    var groupRole: SyncAPI.Role? { get { locked { storedRole } } set { locked { storedRole = newValue } } }
    var getFailure: SyncAPI.FailureCode? { get { locked { storedGetFailure } } set { locked { storedGetFailure = newValue } } }
    var putFailure: SyncAPI.FailureCode? { get { locked { storedPutFailure } } set { locked { storedPutFailure = newValue } } }
    var holdNext: HTTPMethod? { get { locked { storedHold } } set { locked { storedHold = newValue } } }
    var hasHeld: Bool { locked { held != nil } }
    var sentOnMain: Bool { locked { mainRequest } }
    var revision: Int64 { locked { rev } }
    var originalPuts: [HTTPRequest] { locked { requests.filter { $0.method == .put && $0.url.lastPathComponent == Self.original } } }

    func advanceHead() { locked { rev += 1; server = "---\nid: " + Self.original + "\n---\nUpdated server \(rev)\n" } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let hold = locked {
            requests.append(request)
            mainRequest = mainRequest || Thread.isMainThread
            guard storedHold == request.method, request.url.lastPathComponent == Self.original else { return false }
            storedHold = nil
            return true
        }
        if hold {
            return try await withCheckedThrowingContinuation { continuation in locked { held = (request, continuation) } }
        }
        return try response(to: request)
    }

    func releaseHeld() {
        let pending = locked { let value = held; held = nil; return value }
        guard let (request, continuation) = pending else { return }
        do { continuation.resume(returning: try response(to: request)) }
        catch { continuation.resume(throwing: HTTPTransportError.invalidResponse) }
    }

    private func response(to request: HTTPRequest) throws -> HTTPResponse {
        try locked {
            if request.url.path.hasSuffix("/login") {
                return try http(SyncAPI.AuthResponse(deviceToken: String(repeating: "a", count: 42) + "A", user: user))
            }
            if request.url.path.hasSuffix("/me") {
                return try http(SyncAPI.MeResponse(user: user,
                    groups: storedRole.map { [.init(groupID: Self.group, name: "Team", role: $0)] } ?? [],
                    devices: [.init(id: Self.device, name: "Mac", createdAt: timestamp, lastSeenAt: nil, revokedAt: nil, isCurrent: true)]))
            }
            if request.url.lastPathComponent == Self.original {
                if request.method == .get {
                    if let failure = storedGetFailure { return try failed(failure) }
                    return try http(SyncAPI.Prompt(id: Self.original, rev: rev, scope: scope, path: "original.md", content: server))
                }
                if request.method == .put {
                    if let failure = storedPutFailure { return try failed(failure) }
                    let put = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self, from: request.body ?? Data())
                    guard put.baseRev == rev else {
                        let conflict = SyncAPI.ErrorResponse.conflict(head: .init(rev: rev, scope: scope, path: "original.md", content: server))
                        return HTTPResponse(statusCode: 409, body: try JSONEncoder().encode(conflict))
                    }
                    rev += 1
                    server = put.content
                    return try http(SyncAPI.WriteResponse(rev: rev, seq: rev))
                }
            }
            if request.url.path.hasSuffix("/sync/pull") {
                let original = SyncAPI.FeedItem.upsert(seq: rev, prompt: .init(id: Self.original, rev: rev, path: "original.md", content: server))
                let copy = SyncAPI.FeedItem.upsert(seq: 1, prompt: .init(id: Self.copyID, rev: 1, path: Self.copyPath,
                    content: String(decoding: copyBytes, as: UTF8.self)))
                var scopes: [SyncAPI.SyncScope] = [.init(identity: .user(userID: Self.user), mode: .snapshot, head: rev,
                    cursor: "private-\(rev)", hasMore: false, items: storedRole == nil ? [original, copy] : [copy])]
                if let role = storedRole {
                    scopes.append(.init(identity: .group(groupID: Self.group, name: "Team", role: role), mode: .snapshot,
                        head: rev, cursor: "team-\(rev)", hasMore: false, items: [original]))
                }
                return try http(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: scopes, removed: []))
            }
            throw HTTPTransportError.invalidRequest
        }
    }

    private var scope: SyncAPI.PromptScope { storedRole == nil ? .user : .group(groupID: Self.group) }
    private let timestamp = "2026-10-15T00:00:00.000Z"
    private var user: SyncAPI.User {
        .init(id: Self.user, username: "person", displayName: nil, accountKind: .member, createdAt: timestamp, disabledAt: nil)
    }
    private func failed(_ code: SyncAPI.FailureCode) throws -> HTTPResponse {
        let error = SyncAPI.ErrorResponse.failure(code)
        return HTTPResponse(statusCode: error.httpStatus, body: try JSONEncoder().encode(error))
    }
    private func http<T: Encodable>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value))
    }
    private func locked<T>(_ work: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try work() }
}
