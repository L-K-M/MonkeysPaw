import AppKit
import Combine
import MonkeysPawCore
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import MonkeysPaw

/// Exercise the real item-provider bridge, editor guard and native sync graph.
/// Pointer dragging and AppKit's drag image still require the owner check.
final class MacScopeDragTests: XCTestCase {
    func testEveryScopeDirectionAndFolderKeepsIdentityBytesAndHistory() throws {
        let h = try MacScopeDragHarness()
        defer { h.close() }
        let identity = h.view.editorState.prompt?.identity
        let history = try h.historyFiles()
        XCTAssertFalse(history.isEmpty)
        let host = NSHostingView(rootView: LibraryView(presentation: h.view))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 640)
        host.layoutSubtreeIfNeeded()
        for (section, path) in [(LibrarySectionID.group(h.team), "Groups/Team/a.md"),
                                (.group(h.other), "Groups/Other/a.md"), (.all, "a.md"),
                                (.folder("Folder"), "Folder/a.md")] {
            let previous = try XCTUnwrap(h.view.editorState.prompt?.relativePath.string)
            let bytes = try h.files.read(at: previous)
            XCTAssertTrue(try h.drop(onto: section))
            try h.waitForPath(path)
            XCTAssertNil(try h.files.stamp(at: previous))
            XCTAssertEqual(try h.files.read(at: path), bytes)
            XCTAssertEqual(h.view.editorState.prompt?.identity, identity)
            XCTAssertEqual(try h.historyFiles(), history)
            XCTAssertEqual(h.view.snapshot.selection, h.view.editorState.prompt)
            XCTAssertEqual(h.view.commandMessage, LibraryCommandStrings.moved)
        }
        XCTAssertEqual(h.view.model.moveDestination(for: .group(h.team)), "Groups/Team")
    }

    func testDirtyMoveCancelDiscardAndSaveUseTheExistingGuard() throws {
        let h = try MacScopeDragHarness()
        defer { h.close() }
        let before = try h.files.read(at: "a.md")
        h.view.edit(try XCTUnwrap(h.view.editorState.source) + "\nDraft")
        let cancelled = try h.provider()
        XCTAssertTrue(h.drop(cancelled, onto: .group(h.team)))
        try h.decide(.cancel, action: .move)
        XCTAssertTrue(h.view.editorState.isDirty)
        XCTAssertTrue(h.view.editorState.source?.contains("Draft") == true)
        XCTAssertEqual(try h.files.read(at: "a.md"), before)
        XCTAssertNil(try h.files.stamp(at: "Groups/Team/a.md"))
        XCTAssertTrue(h.drop(cancelled, onto: .group(h.team)))
        XCTAssertTrue(h.spin { !h.view.isScopeDropPending })
        XCTAssertNil(h.view.editorState.pendingDecision, "A spent payload cannot replay")
        XCTAssertTrue(try h.drop(onto: .group(h.team)))
        try h.decide(.discard, action: .move)
        try h.waitForPath("Groups/Team/a.md")
        XCTAssertEqual(try h.files.read(at: "Groups/Team/a.md"), before)
        h.view.edit(try XCTUnwrap(h.view.editorState.source) + "\nSaved draft")
        XCTAssertTrue(try h.drop(onto: .all))
        try h.decide(.save, action: .move)
        try h.waitForPath("a.md")
        XCTAssertTrue(String(decoding: try h.files.read(at: "a.md"), as: UTF8.self).contains("Saved draft"))
        XCTAssertFalse(h.view.editorState.isDirty)
    }

    func testDraggingAnotherRowGuardsTheCurrentDraftBeforeLoadingAndMoving() throws {
        let h = try MacScopeDragHarness()
        defer { h.close() }
        h.view.edit(try XCTUnwrap(h.view.editorState.source) + "\nKeep current")
        let provider = try h.provider(path: "Folder/seed.md")
        XCTAssertEqual(h.view.editorState.prompt?.relativePath, "a.md")
        XCTAssertNil(h.view.editorState.pendingDecision, "A drag source does not activate its row")
        XCTAssertTrue(h.drop(provider, onto: .group(h.team)))
        let seed = try XCTUnwrap(h.view.model.rows.first { $0.relativePath == "Folder/seed.md" }?.selection)
        try h.decide(.cancel, action: .open(seed))
        XCTAssertTrue(h.view.editorState.source?.contains("Keep current") == true)
        XCTAssertEqual(h.view.editorState.prompt?.relativePath, "a.md")
        XCTAssertTrue(try h.drop(path: "Folder/seed.md", onto: .group(h.team)))
        try h.decide(.discard, action: .open(seed))
        try h.waitForPath("Groups/Team/seed.md")
        XCTAssertNotNil(try h.files.stamp(at: "a.md"))
        XCTAssertNil(try h.files.stamp(at: "Folder/seed.md"))
    }

    func testOccupiedDestinationPreservesBothFilesAndReportsFailure() throws {
        let h = try MacScopeDragHarness()
        defer { h.close() }
        let original = try h.files.read(at: "a.md")
        try h.files.write(Data("Occupied".utf8), at: "Groups/Team/a.md")
        XCTAssertTrue(try h.drop(onto: .group(h.team)))
        XCTAssertTrue(h.spin { if case .failed = h.view.editorState.status { return true }; return false })
        XCTAssertEqual(try h.files.read(at: "a.md"), original)
        XCTAssertEqual(try h.files.read(at: "Groups/Team/a.md"), Data("Occupied".utf8))
        XCTAssertEqual(h.view.editorState.prompt?.relativePath, "a.md")
        XCTAssertNotNil(h.view.commandMessage)
    }

    func testViewerSourceAndDestinationRefuseMovesAndKeepPrivateCopyAction() throws {
        let destination = try MacScopeDragHarness(role: .viewer)
        defer { destination.close() }
        XCTAssertNil(destination.view.model.moveDestination(for: .group(destination.team)))
        XCTAssertFalse(destination.drop(try destination.provider(), onto: .group(destination.team)))
        XCTAssertNotNil(try destination.files.stamp(at: "a.md"))
        let source = try MacScopeDragHarness(role: .viewer, sourceInGroup: true)
        defer { source.close() }
        XCTAssertFalse(source.view.canDragScopeRow(try XCTUnwrap(source.view.editorState.prompt)))
        XCTAssertNil(source.view.scopeDragProvider(for: try XCTUnwrap(source.view.editorState.prompt), epoch: source.view.scopeDragEpoch))
        XCTAssertEqual(source.view.editorState.readOnlyReason, .groupViewer)
        XCTAssertTrue(source.view.canSaveAsCopy)
        XCTAssertNotNil(try source.files.stamp(at: "Groups/Team/a.md"))
    }

    func testUntrustedTypesBytesAndNonDestinationsNeverBecomePathsOrImports() throws {
        let h = try MacScopeDragHarness()
        defer { h.close() }
        let provider = try h.provider()
        let payload = try h.bytes(from: provider)
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        for bytes in [Data(), Data([0xff]), Data("a.md".utf8), Data("../a.md".utf8),
                      Data("file:///tmp/a.md".utf8), payload + Data("/../b.md".utf8)] {
            XCTAssertTrue(h.drop(MacScopeDragHarness.provider(bytes), onto: .group(h.team)))
            XCTAssertTrue(h.spin { !h.view.isScopeDropPending })
            XCTAssertEqual(h.view.editorState.prompt?.relativePath, "a.md")
        }
        for section in [LibrarySectionID.favourites, .recent, .conflicts, .tag("tag"), .folder("../outside")] {
            XCTAssertFalse(h.drop(try h.provider(), onto: section))
        }
        XCTAssertFalse(h.view.acceptScopeDrop([provider, provider], onto: .all, epoch: h.view.scopeDragEpoch))
        let external = NSItemProvider()
        external.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in
            done(h.root.appendingPathComponent("a.md").dataRepresentation, nil)
            return nil
        }
        XCTAssertFalse(h.drop(external, onto: .group(h.team)))
        XCTAssertNil(try h.files.stamp(at: "Groups/Team/a.md"))
        XCTAssertTrue(h.view.imports?.reports.isEmpty == true)
    }

    func testOldGraphEpochAndRetainedCallbacksCannotMintOrMoveRows() throws {
        let h = try MacScopeDragHarness()
        defer { h.close() }
        let oldEpoch = h.view.scopeDragEpoch
        let selection = try XCTUnwrap(h.view.editorState.prompt)
        let provider = try h.provider()
        h.view.rebind(to: h.view.model, editor: h.view.editor, libraryPath: h.root.path, available: true)
        XCTAssertNotEqual(h.view.scopeDragEpoch, oldEpoch)
        XCTAssertNil(h.view.scopeDragProvider(for: selection, epoch: oldEpoch))
        XCTAssertFalse(h.view.acceptScopeDrop([provider], onto: .group(h.team), epoch: oldEpoch))
        XCTAssertTrue(h.drop(provider, onto: .group(h.team)))
        XCTAssertTrue(h.spin { !h.view.isScopeDropPending })
        XCTAssertNil(try h.files.stamp(at: "Groups/Team/a.md"))
        h.view.deactivate()
        XCTAssertNil(h.view.scopeDragProvider(for: selection, epoch: h.view.scopeDragEpoch))
        XCTAssertFalse(h.drop(provider, onto: .all))
    }

    func testHeldProviderCannotMoveAfterRebindHideOrAvailabilityLoss() throws {
        let h = try MacScopeDragHarness()
        defer { h.close() }
        for retirement in 0..<3 {
            let held = MacScopeHeldProvider(bytes: try h.bytes(from: h.provider()))
            XCTAssertTrue(h.drop(held.provider, onto: .group(h.team)))
            XCTAssertTrue(h.spin { held.isRequested })
            XCTAssertFalse(h.view.canRunFileCommand)
            switch retirement {
            case 0: h.view.rebind(to: h.view.model, editor: h.view.editor, libraryPath: h.root.path, available: true)
            case 1: h.view.didHide(); h.view.didShow()
            default: h.view.setLibraryAvailable(false); h.view.setLibraryAvailable(true)
            }
            held.release()
            XCTAssertTrue(h.spin { !h.view.isScopeDropPending })
            XCTAssertNil(try h.files.stamp(at: "Groups/Team/a.md"))
            XCTAssertEqual(h.view.editorState.prompt?.relativePath, "a.md")
        }
        h.view.didHide()
        XCTAssertNil(h.view.scopeDragProvider(for: try XCTUnwrap(h.view.editorState.prompt), epoch: h.view.scopeDragEpoch))
    }

    func testQueuedNavigationAndNativeFileMenuCannotRaceProviderLoading() throws {
        let h = try MacScopeDragHarness()
        defer { h.close() }
        let provider = try h.provider()
        let seed = try XCTUnwrap(h.view.model.rows.first { $0.relativePath == "Folder/seed.md" }?.selection)
        h.view.editor.request(.open(seed))
        XCTAssertFalse(h.drop(provider, onto: .group(h.team)))
        XCTAssertTrue(h.spin { h.view.editorState.prompt == seed && h.view.editorState.source != nil })
        let held = MacScopeHeldProvider(bytes: try h.bytes(from: h.provider()))
        XCTAssertTrue(h.drop(held.provider, onto: .group(h.team)))
        XCTAssertTrue(h.spin { held.isRequested })
        let item = NSMenuItem(title: "Move", action: #selector(AppDelegate.moveLibraryPrompt), keyEquivalent: "")
        XCTAssertFalse(h.delegate.validateLibraryFileMenuItem(item, in: h.delegate.libraryWindow?.window))
        h.view.selectPath("a.md")
        held.release()
        try h.waitForPath("a.md")
        XCTAssertNil(try h.files.stamp(at: "Groups/Team/seed.md"))
    }

    func testRenamedRowIdentityRejectsItsOldPayload() throws {
        let h = try MacScopeDragHarness()
        defer { h.close() }
        let provider = try h.provider()
        h.view.editor.rename(to: "renamed.md")
        try h.waitForPath("renamed.md")
        XCTAssertTrue(h.drop(provider, onto: .group(h.team)))
        XCTAssertTrue(h.spin { !h.view.isScopeDropPending })
        XCTAssertNotNil(try h.files.stamp(at: "renamed.md"))
        XCTAssertNil(try h.files.stamp(at: "Groups/Team/renamed.md"))
    }

    func testSelectingARowKeepsItsRenderedDragSourceUsable() throws {
        let h = try MacScopeDragHarness()
        defer { h.close() }
        let renderedEpoch = h.view.scopeDragEpoch
        let row = try XCTUnwrap(h.view.model.rows.first { $0.relativePath == "Folder/seed.md" })
        h.view.selectPath(row.relativePath)
        try h.waitForPath("Folder/seed.md")
        let provider = try XCTUnwrap(h.view.scopeDragProvider(for: row.selection, epoch: renderedEpoch))
        XCTAssertTrue(h.drop(provider, onto: .group(h.team)))
        try h.waitForPath("Groups/Team/seed.md")
    }

    func testExternalDropsStillImportWithoutMovingOrReusingDuplicateIdentity() throws {
        let h = try MacScopeDragHarness()
        defer { h.close() }
        let url = h.directory.appendingPathComponent("external.md")
        let bytes = try h.files.read(at: "a.md")
        try bytes.write(to: url)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { done in
            DispatchQueue.global().async { done(url.dataRepresentation, nil) }
            return nil
        }
        XCTAssertFalse(h.drop(provider, onto: .group(h.team)))
        let imports = try XCTUnwrap(h.view.imports)
        XCTAssertTrue(imports.acceptDrop([provider]))
        XCTAssertTrue(h.spin { imports.hasReport })
        XCTAssertEqual(imports.createdCount, 1)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try h.files.read(at: "a.md"), bytes)
        let imported = PromptCodec.parseFile(try h.files.read(at: "Imported/external.md"), filename: "external.md")
        XCTAssertNotEqual(imported.frontMatter.id?.rawValue, MacScopeTransport.prompt)
        XCTAssertEqual(imported.body, PromptCodec.parseFile(bytes, filename: "a.md").body)
    }

    func testFailedEditAfterAcknowledgedScopeMoveKeepsSavedEditsAndNewRevision() throws {
        let h = try MacScopeDragHarness(keepSyncRunning: true)
        defer { h.close() }
        h.transport.failPut = true
        h.view.edit(try XCTUnwrap(h.view.editorState.source) + "\nSaved edit")
        XCTAssertTrue(try h.drop(onto: .group(h.team)))
        try h.decide(.save, action: .move)
        try h.waitForPath("Groups/Team/a.md")
        let edited = try h.files.read(at: "Groups/Team/a.md")
        h.delegate.syncComposition?.sync.syncNow()
        XCTAssertTrue(h.spin { h.transport.writes.count >= 2 })
        h.drainSync()
        let writes = h.transport.writes
        XCTAssertEqual(Array(writes.prefix(2)).map(\.method), [.post, .put])
        let move = try JSONDecoder().decode(SyncAPI.MovePromptRequest.self, from: XCTUnwrap(writes.first?.body))
        let put = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self, from: XCTUnwrap(writes.dropFirst().first?.body))
        XCTAssertEqual(move.scope, .group(groupID: h.team.rawValue))
        XCTAssertEqual(put.baseRev, 2)
        XCTAssertTrue(put.content.contains("Saved edit"))
        XCTAssertEqual(try h.files.read(at: "Groups/Team/a.md"), edited)
        XCTAssertTrue(h.view.editorState.source?.contains("Saved edit") == true)
        let state = try h.promptState()
        XCTAssertEqual(state["scope_key"] as? String, "group:" + h.team.rawValue)
        XCTAssertEqual(state["rev"] as? Int, 2)
        XCTAssertFalse(h.transport.sentOnMain)
    }

    func testCreatorDeniedTransferRestoresHeadAndPreservesEditedPrivateCopy() throws {
        let h = try MacScopeDragHarness(sourceInGroup: true, keepSyncRunning: true)
        defer { h.close() }
        let baseline = try h.files.read(at: "Groups/Team/a.md")
        h.transport.denyMove = true
        h.view.edit(try XCTUnwrap(h.view.editorState.source) + "\nNoncreator private edit")
        XCTAssertTrue(try h.drop(onto: .all))
        try h.decide(.save, action: .move)
        try h.waitForPath("a.md")
        h.delegate.syncComposition?.sync.syncNow()
        XCTAssertTrue(h.spin { h.transport.writes.contains { $0.method == .post } })
        h.drainSync()
        XCTAssertTrue(h.spin { (try? h.files.stamp(at: "a.md")) == nil })
        XCTAssertEqual(try h.files.read(at: "Groups/Team/a.md"), baseline)
        let copies = try h.files.listFiles().filter { $0.relativePath.hasPrefix("Conflicts/") }
        let copy = try XCTUnwrap(copies.first)
        let document = PromptCodec.parseFile(try h.files.read(at: copy.relativePath), filename: "copy.md")
        XCTAssertNotEqual(document.frontMatter.id?.rawValue, MacScopeTransport.prompt)
        XCTAssertTrue(document.body.contains("Noncreator private edit"))
        XCTAssertEqual(h.view.model.sections.first { $0.id == .group(h.team) }?.role, .editor)
    }
}

private final class MacScopeDragHarness {
    let directory: URL
    let root: URL
    let files: RootedFileStore
    let data: RootedFileStore
    let transport: MacScopeTransport
    let delegate: AppDelegate
    let team = ULID(MacScopeTransport.team)!
    let other = ULID(MacScopeTransport.other)!
    private let originalMenu: NSMenu?
    private let dialogs: MacScopeDialogs
    var view: LibraryViewState { delegate.libraryWindow!.presentation }

    init(role: SyncAPI.Role = .editor, sourceInGroup: Bool = false, keepSyncRunning: Bool = false) throws {
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertTrue(AppDelegate.isRunningTests)
        originalMenu = NSApp.mainMenu
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-y29-" + UUID().uuidString)
        root = directory.appendingPathComponent("library")
        files = try RootedFileStore(root: root)
        data = try RootedFileStore(root: directory.appendingPathComponent("data"))
        try files.createRoot()
        let transport = try MacScopeTransport(role: role, sourceInGroup: sourceInGroup)
        self.transport = transport
        let dialogs = MacScopeDialogs()
        self.dialogs = dialogs
        delegate = AppDelegate(libraryRoot: root, dataRoot: directory.appendingPathComponent("data"),
            httpTransport: transport, secrets: MacScopeSecrets(), editorDialog: { _, dialog, respond in
                dialogs.present(dialog, respond: respond)
            }, setActivationPolicy: { _ in }, activateApplication: {}, makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in false }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, makeFileWatcher: { _, _ in MacScopeWatcher() })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let account = try XCTUnwrap(delegate.accountModel)
        XCTAssertTrue(spin { !account.state.isBusy })
        var password = "test-password"
        account.login(server: "https://scope.example.test", username: "person", password: &password, deviceName: "Mac")
        XCTAssertTrue(spin { account.state.enabled && self.delegate.syncStatusModel?.state.lastSuccess != nil })
        if !keepSyncRunning {
            delegate.syncComposition?.sync.stop()
            drainSync()
        }
        delegate.showLibrary()
        let path = sourceInGroup ? "Groups/Team/a.md" : "a.md"
        XCTAssertTrue(spin { self.view.snapshot.rows.contains { $0.relativePath == RelativePath(path) } })
        view.selectPath(RelativePath(path))
        try waitForPath(path)
        try data.write(Data("Earlier history".utf8), at: "history/" + MacScopeTransport.prompt + "/20261001T130700.123Z-000000.md")
    }

    func provider(path: String? = nil) throws -> NSItemProvider {
        let path = path ?? view.editorState.prompt?.relativePath.string
        let row = try XCTUnwrap(view.model.rows.first { $0.relativePath.string == path })
        return try XCTUnwrap(view.scopeDragProvider(for: row.selection, epoch: view.scopeDragEpoch))
    }

    static func provider(_ bytes: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: LibraryViewState.scopeDragTypeIdentifier, visibility: .ownProcess) { done in
            done(bytes, nil)
            return nil
        }
        return provider
    }

    func bytes(from provider: NSItemProvider) throws -> Data {
        let reply = MacScopeBytes()
        provider.loadDataRepresentation(forTypeIdentifier: LibraryViewState.scopeDragTypeIdentifier) { bytes, _ in reply.set(bytes) }
        XCTAssertTrue(spin { reply.done })
        return try XCTUnwrap(reply.bytes)
    }

    func drop(_ provider: NSItemProvider, onto section: LibrarySectionID) -> Bool {
        view.acceptScopeDrop([provider], onto: section, epoch: view.scopeDragEpoch)
    }

    func drop(path: String? = nil, onto section: LibrarySectionID) throws -> Bool { drop(try provider(path: path), onto: section) }

    func decide(_ decision: EditorDecision, action: EditorDiscardAction) throws {
        XCTAssertTrue(spin { self.view.editorState.pendingDecision != nil })
        XCTAssertEqual(view.editorState.pendingDecision?.action, action)
        try dialogs.respond(.decision(decision))
        XCTAssertTrue(spin { self.view.editorState.pendingDecision == nil })
    }

    func waitForPath(_ path: String) throws {
        XCTAssertTrue(spin {
            self.view.editorState.prompt?.relativePath == RelativePath(path) && self.view.editorState.source != nil
                && self.view.editorState.status != .loading && self.view.editorState.status != .commandRunning
                && self.view.snapshot.selection == self.view.editorState.prompt && !self.view.isScopeDropPending
        }, String(describing: view.editorState.status))
    }

    func historyFiles() throws -> [StoredFile] {
        try data.listFiles().filter { $0.relativePath.hasPrefix("history/" + MacScopeTransport.prompt + "/") }
    }

    func promptState() throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data.read(at: "sync/state.json")) as? [String: Any])
        let prompts = try XCTUnwrap(root["prompts"] as? [String: Any])
        return try XCTUnwrap(prompts[MacScopeTransport.prompt] as? [String: Any])
    }

    func drainSync() {
        guard let sync = delegate.syncComposition?.sync else { return }
        let done = MacScopeBytes()
        Task.detached { await sync.drain(); done.set(Data()) }
        XCTAssertTrue(spin { done.done })
    }

    func close() {
        if let graph = delegate.syncComposition {
            graph.retireModels()
            let done = MacScopeBytes()
            Task.detached { _ = await graph.drainAndRetire(); done.set(Data()) }
            XCTAssertTrue(spin { done.done })
        }
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        NSApp.mainMenu = originalMenu
        try? FileManager.default.removeItem(at: directory)
    }

    func spin(_ predicate: () -> Bool, timeout: TimeInterval = 8) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
}

private final class MacScopeDialogs {
    private var response: ((LibraryEditorResponse) -> Void)?
    private var dialog: LibraryEditorDialog?
    func present(_ dialog: LibraryEditorDialog, respond: @escaping (LibraryEditorResponse) -> Void) -> () -> Void {
        self.dialog = dialog
        response = respond
        return { [weak self] in self?.response = nil; self?.dialog = nil }
    }
    func respond(_ value: LibraryEditorResponse) throws {
        XCTAssertTrue(try XCTUnwrap(dialog).accepts(value))
        let reply = try XCTUnwrap(response)
        response = nil
        dialog = nil
        reply(value)
    }
}

private final class MacScopeWatcher: FileStoreWatcher {
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {}
    func stop() {}
}

private final class MacScopeSecrets: SecretStore {
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

private final class MacScopeBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var finished = false
    var done: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var bytes: Data? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ bytes: Data?) { lock.lock(); value = bytes; finished = true; lock.unlock() }
}

private final class MacScopeHeldProvider {
    let provider = NSItemProvider()
    private let lock = NSLock()
    private let bytes: Data
    private var reply: ((Data?, Error?) -> Void)?
    var isRequested: Bool { lock.lock(); defer { lock.unlock() }; return reply != nil }
    init(bytes: Data) {
        self.bytes = bytes
        provider.registerDataRepresentation(forTypeIdentifier: LibraryViewState.scopeDragTypeIdentifier, visibility: .ownProcess) { [weak self] done in
            guard let self else { done(nil, CocoaError(.fileReadUnknown)); return nil }
            self.lock.lock(); self.reply = done; self.lock.unlock()
            return nil
        }
    }
    func release() {
        lock.lock(); let reply = self.reply; self.reply = nil; lock.unlock()
        reply?(bytes, nil)
    }
}

/// Only HTTP is fake; public Account/Sync APIs perform all journal work.
private final class MacScopeTransport: HTTPTransporting, @unchecked Sendable {
    static let userID = "00000000000000000000000001"
    static let device = "00000000000000000000000002"
    static let team = "00000000000000000000000003"
    static let prompt = "00000000000000000000000004"
    static let other = "00000000000000000000000007"
    static let seed = "00000000000000000000000008"
    private let lock = NSLock()
    private let role: SyncAPI.Role
    private var scope: SyncAPI.PromptScope
    private var path = "a.md"
    private var content = "---\nid: '" + prompt + "'\n---\nOriginal"
    private var rev: Int64 = 1
    private var requests: [HTTPRequest] = []
    private var mainRequest = false
    private var storedFailPut = false
    private var storedDenyMove = false
    var failPut: Bool { get { locked { storedFailPut } } set { locked { storedFailPut = newValue } } }
    var denyMove: Bool { get { locked { storedDenyMove } } set { locked { storedDenyMove = newValue } } }
    var sentOnMain: Bool { locked { mainRequest } }
    var writes: [HTTPRequest] {
        locked { requests.filter { $0.url.path.hasSuffix("/move") || ($0.method == .put && $0.url.lastPathComponent == Self.prompt) } }
    }

    init(role: SyncAPI.Role, sourceInGroup: Bool) throws {
        self.role = role
        scope = sourceInGroup ? .group(groupID: Self.team) : .user
        // The server supplies group-canonical bytes, including numeric ID quoting.
        content = String(decoding: try CanonicalForm.group(Data(content.utf8), filename: path).bytes, as: UTF8.self)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try locked {
            requests.append(request)
            mainRequest = mainRequest || Thread.isMainThread
            if request.url.path.hasSuffix("/login") {
                return try http(SyncAPI.AuthResponse(deviceToken: String(repeating: "a", count: 42) + "A", user: user))
            }
            if request.url.path.hasSuffix("/me") {
                return try http(SyncAPI.MeResponse(user: user, groups: [
                    .init(groupID: Self.team, name: "Team", role: role),
                    .init(groupID: Self.other, name: "Other", role: .owner)], devices: [
                        .init(id: Self.device, name: "Mac", createdAt: timestamp, lastSeenAt: nil, revokedAt: nil, isCurrent: true)]))
            }
            if request.url.path.hasSuffix("/move") {
                if storedDenyMove { return try failed(.forbidden) }
                let move = try JSONDecoder().decode(SyncAPI.MovePromptRequest.self, from: request.body ?? Data())
                scope = move.scope
                path = move.path
                rev += 1
                return try http(SyncAPI.WriteResponse(rev: rev, seq: rev))
            }
            if request.url.lastPathComponent == Self.prompt {
                if request.method == .get {
                    return try http(SyncAPI.Prompt(id: Self.prompt, rev: rev, scope: scope, path: path, content: content))
                }
                if request.method == .put {
                    if storedFailPut { return try failed(.internalError) }
                    let put = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self, from: request.body ?? Data())
                    content = put.content
                    path = put.path
                    rev += 1
                    return try http(SyncAPI.WriteResponse(rev: rev, seq: rev))
                }
            }
            if request.url.path.hasSuffix("/sync/pull") {
                let prompt = SyncAPI.FeedItem.upsert(seq: rev,
                    prompt: .init(id: Self.prompt, rev: rev, path: path, content: content))
                let seedBytes = "---\nid: '" + Self.seed + "'\n---\nFolder seed"
                // Snapshot items use the page head even when their revision is older.
                let seed = SyncAPI.FeedItem.upsert(seq: rev,
                    prompt: .init(id: Self.seed, rev: 1, path: "Folder/seed.md", content: seedBytes))
                let personal = scope == .user ? [prompt, seed] : [seed]
                let team = scope == .group(groupID: Self.team) ? [prompt] : []
                let other = scope == .group(groupID: Self.other) ? [prompt] : []
                let scopes: [SyncAPI.SyncScope] = [
                    .init(identity: .user(userID: Self.userID), mode: .snapshot, head: rev,
                        cursor: "u-\(rev)", hasMore: false, items: personal),
                    .init(identity: .group(groupID: Self.team, name: "Team", role: role), mode: .snapshot,
                        head: rev, cursor: "g-\(rev)", hasMore: false, items: team),
                    .init(identity: .group(groupID: Self.other, name: "Other", role: .owner), mode: .snapshot,
                        head: rev, cursor: "o-\(rev)", hasMore: false, items: other)]
                return try http(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: scopes, removed: []))
            }
            throw HTTPTransportError.invalidRequest
        }
    }

    private let timestamp = "2026-10-15T00:00:00.000Z"
    private var user: SyncAPI.User {
        .init(id: Self.userID, username: "person", displayName: nil, accountKind: .member, createdAt: timestamp, disabledAt: nil)
    }
    private func failed(_ code: SyncAPI.FailureCode) throws -> HTTPResponse {
        HTTPResponse(statusCode: code.httpStatus, body: try JSONEncoder().encode(SyncAPI.ErrorResponse.failure(code)))
    }
    private func http<T: Encodable>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value))
    }
    private func locked<T>(_ work: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try work() }
}
