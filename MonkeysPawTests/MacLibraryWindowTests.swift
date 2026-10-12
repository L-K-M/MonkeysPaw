import AppKit
import Carbon.HIToolbox
import Combine
import MonkeysPawCore
import SwiftUI
import XCTest
@testable import MonkeysPaw

/// Inspect the hosting view's presentation, rather than SwiftUI's lazy
/// accessibility tree. Regular windows need not win activation on CI.
final class MacLibraryWindowTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var files: RootedFileStore!
    private var delegate: AppDelegate!
    private var panel: PanelController!
    private let scheduler = LibraryWindowScheduler()
    private var watchers: [LibraryWindowWatcher] = []
    private var originalWindows: Set<ObjectIdentifier> = []
    private var originalMenu: NSMenu?
    private var policies: [NSApplication.ActivationPolicy] = []
    private var applicationActivations = 0
    private var launched: [URL] = []
    private var revealed: [URL] = []
    private var targetActivations: [DeliveryTarget] = []
    private var frontmost: DeliveryTarget?
    private var ownPID: Int32 { NSRunningApplication.current.processIdentifier }
    private var ownTarget: DeliveryTarget { .macOS(processID: ownPID, bundleID: "test.own") }
    private var externalTarget: DeliveryTarget { .macOS(processID: ownPID + 1, bundleID: "test.external") }

    override func setUpWithError() throws {
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        originalMenu = NSApp.mainMenu
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library", isDirectory: true)
        data = directory.appendingPathComponent("data", isDirectory: true)
        files = try RootedFileStore(root: root)
        try files.createRoot()
    }

    override func tearDown() {
        delegate?.pickerModel?.dismiss()
        panel?.hide()
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        scheduler.drain()
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate = nil
        panel = nil
        watchers = []
        NSApp.mainMenu = originalMenu
        try? FileManager.default.removeItem(at: directory)
    }

    private func start() throws {
        delegate = AppDelegate(libraryRoot: root, dataRoot: data,
            launchURI: { [weak self] in self?.launched.append($0) },
            backgroundWork: LibraryWindowInlineWork(), editorDialog: { _, _, _ in {} },
            revealLibrary: { [weak self] in self?.revealed.append($0) },
            setActivationPolicy: { [weak self] in self?.policies.append($0) },
            activateApplication: { [weak self] in self?.applicationActivations += 1 },
            makeFocusTracker: { [weak self] main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { [weak self] in self?.frontmost },
                    activate: { [weak self] in self?.targetActivations.append($0); return true }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, scheduler: scheduler, makePanelController: { [weak self] main, scheduler, log in
                let panel = PanelController(mainThread: main, scheduler: scheduler, log: log, keyWindow: { nil })
                self?.panel = panel
                return panel
            }, makeFileWatcher: { [weak self] _, _ in
                let watcher = LibraryWindowWatcher()
                self?.watchers.append(watcher)
                return watcher
            })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    private func put(_ source: String, at path: String) throws { try files.write(Data(source.utf8), at: path) }
    private func controller() throws -> LibraryWindowController { try XCTUnwrap(delegate.libraryWindow) }
    private func window() throws -> NSWindow { try XCTUnwrap(controller().window) }

    private func presentation() throws -> LibraryViewState {
        let controller = try controller()
        let hosting = try XCTUnwrap(window().contentView as? NSHostingView<LibraryView>)
        XCTAssertTrue(hosting.rootView.presentation === controller.presentation)
        return controller.presentation
    }

    private func key(_ code: Int, characters: String = "", modifiers: NSEvent.ModifierFlags = [],
                     in window: NSWindow? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)))
    }

    func testOpeningTwiceAndReopeningReusesOneWindowAndHostingView() throws {
        try put("Body", at: "one.md")
        try start()
        XCTAssertNil(try controller().window, "Hosted launch composes the browser without showing a window")
        XCTAssertNotNil(delegate.libraryBrowserModel)
        delegate.showLibrary()
        let window = try window()
        let hosting = try XCTUnwrap(window.contentView)
        delegate.showLibrary()
        XCTAssertTrue(try self.window() === window)
        XCTAssertTrue(window.contentView === hosting)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(applicationActivations, 2)
        XCTAssertEqual(policies, [.regular])
        XCTAssertEqual(NSApp.windows.filter {
            !originalWindows.contains(ObjectIdentifier($0)) && $0.title == LibraryStrings.title
        }.count, 1)
        window.close()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(policies, [.regular, .accessory])
        delegate.showLibrary()
        XCTAssertTrue(try self.window() === window)
        XCTAssertTrue(window.contentView === hosting)
        XCTAssertEqual(policies, [.regular, .accessory, .regular])
        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(revealed.isEmpty)
    }

    func testPickerLibraryControlAndCommandLOpenWindowWithoutLaunchingFolder() throws {
        try put("Body", at: "one.md")
        try start()
        let picker = try XCTUnwrap(delegate.pickerModel)
        picker.open()
        XCTAssertTrue(panel.isVisible)
        // The Library button forwards this same presentation-model intent.
        picker.openLibrary()
        let window = try window()
        XCTAssertEqual(picker.state, .closed)
        XCTAssertNil(picker.requestedIntent)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(window.isVisible)
        window.close()

        picker.open()
        let pickerPresentation = try XCTUnwrap(delegate.pickerPresentation)
        XCTAssertTrue(pickerPresentation.route(try key(kVK_ANSI_L, characters: "l", modifiers: .command), fieldKind: nil))
        XCTAssertEqual(picker.state, .closed)
        XCTAssertTrue(try self.window() === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(revealed.isEmpty)
    }

    func testStatusAndMainMenuOpenLibraryAndKeepUnavailableRowsDisabled() throws {
        try put("Body", at: "one.md")
        try start()
        delegate.installMainMenu()
        let main = try XCTUnwrap(NSApp.mainMenu)
        let appMenu = try XCTUnwrap(main.items.first?.submenu)
        let status = delegate.makeStatusMenu()
        let mainItem = try XCTUnwrap(appMenu.items.first { $0.title == OnboardingStrings.libraryAvailableMenu })
        let statusItem = try XCTUnwrap(status.items.first { $0.title == OnboardingStrings.libraryAvailableMenu })
        XCTAssertTrue(mainItem.target === delegate)
        XCTAssertTrue(statusItem.target === delegate)
        XCTAssertEqual(mainItem.action, statusItem.action)
        XCTAssertEqual(mainItem.keyEquivalent, "l")
        XCTAssertEqual(mainItem.keyEquivalentModifierMask, .command)
        XCTAssertFalse(appMenu.autoenablesItems)
        XCTAssertTrue(main.performKeyEquivalent(with: try key(kVK_ANSI_L, characters: "l", modifiers: .command)))
        let libraryWindow = try window()
        libraryWindow.close()
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(statusItem.action), to: statusItem.target, from: statusItem))
        XCTAssertTrue(try window() === libraryWindow)
        XCTAssertTrue(libraryWindow.isVisible)
        XCTAssertTrue(revealed.isEmpty)

        watchers[0].emit(.rootUnavailable(.notFound))
        scheduler.drain()
        for item in [mainItem, statusItem] {
            XCTAssertEqual(item.title, OnboardingStrings.libraryUnavailableMenu)
            XCTAssertFalse(item.isEnabled)
        }
        appMenu.update()
        status.update()
        XCTAssertFalse(mainItem.isEnabled)
        XCTAssertFalse(statusItem.isEnabled)
        let presentation = try presentation()
        XCTAssertFalse(presentation.libraryAvailable)
        presentation.revealFolder()
        XCTAssertTrue(revealed.isEmpty)
        libraryWindow.close()
        let activations = applicationActivations
        delegate.showLibrary()
        XCTAssertFalse(libraryWindow.isVisible)
        XCTAssertEqual(applicationActivations, activations)
    }

    func testSidebarCountsNestedFoldersTagsFilterAndHiddenSelectionComeFromBrowser() throws {
        try put("---\ntitle: Alpha\nfavorite: true\ntags: [CODE, code]\n---\nAlpha body", at: "work/deep/a.md")
        try put("---\ntitle: Beta\ntags: [code, review]\n---\nBeta body", at: "work/b.md")
        try put("Root", at: "root.md")
        try start()
        delegate.showLibrary()
        let presentation = try presentation()
        XCTAssertEqual(Array(presentation.snapshot.sections.prefix(3)).map(\.id), [.all, .favourites, .recent])
        XCTAssertEqual(presentation.snapshot.sections.first { $0.id == .all }?.count, 3)
        XCTAssertEqual(presentation.snapshot.sections.first { $0.id == .favourites }?.count, 1)
        XCTAssertEqual(presentation.snapshot.sections.first { $0.id == .folder("work") }?.count, 2)
        let nested = try XCTUnwrap(presentation.snapshot.sections.first { $0.id == .folder("work/deep") })
        XCTAssertEqual(nested.depth, 1)
        XCTAssertEqual(nested.parent, .folder("work"))
        XCTAssertEqual(presentation.snapshot.sections.first { $0.id == .tag("code") }?.count, 2)
        presentation.selectSection(.folder("work"))
        XCTAssertEqual(presentation.snapshot.rows.map(\.title), ["Alpha", "Beta"])
        presentation.selectPath("work/deep/a.md")
        let selected = presentation.snapshot.selection
        XCTAssertEqual(presentation.preview, .rendered("Alpha body"))
        presentation.setFilter("Beta")
        XCTAssertEqual(presentation.snapshot.rows.map(\.relativePath), ["work/b.md"])
        XCTAssertEqual(presentation.snapshot.sections.first { $0.id == .all }?.count, 3)
        presentation.selectPath(nil) // Native List reconciliation after filtering.
        XCTAssertEqual(presentation.snapshot.selection, selected)
        XCTAssertEqual(presentation.preview, .rendered("Alpha body"))
        presentation.setFilter("")
        presentation.selectSection(.tag("REVIEW"))
        XCTAssertEqual(presentation.snapshot.rows.map(\.relativePath), ["work/b.md"])
        XCTAssertEqual(presentation.snapshot.selection, selected)
        presentation.moveSelection(.down)
        XCTAssertEqual(presentation.snapshot.selectedPrompt?.title, "Beta")
        presentation.selectSection(.all)
        presentation.moveSelection(.up)
        XCTAssertEqual(presentation.snapshot.selectedPrompt?.title, "Alpha")
        presentation.moveSelection(.up)
        XCTAssertEqual(presentation.snapshot.selectedPrompt?.title, "Alpha", "Arrows stop at the list boundary")
    }

    func testRecentShowsRetainedUseDateAndRefreshesWithoutAnIndexRebuild() throws {
        try put("---\ntitle: Alpha\n---\nBody", at: "a.md")
        try put("---\ntitle: Beta\n---\nBody", at: "b.md")
        let dataFiles = try RootedFileStore(root: data)
        try dataFiles.createRoot()
        let clock = SystemClock()
        let usage = UsageStore(files: dataFiles, clock: clock)
        let library = LibraryService(library: files, data: dataFiles, clock: clock, entropy: SystemEntropy())
        let alpha = try library.load(at: "a.md")
        let usedAt = Date(timeIntervalSince1970: 1_780_000_000)
        try usage.recordUse(identity: alpha.identity, at: usedAt)
        try start()
        delegate.showLibrary()
        let presentation = try presentation()
        presentation.selectSection(.recent)
        XCTAssertEqual(presentation.snapshot.rows.map(\.relativePath), ["a.md"])
        XCTAssertEqual(presentation.snapshot.rows.first?.lastUsedAt, usedAt)
        XCTAssertEqual(presentation.snapshot.sections.first { $0.id == .recent }?.count, 1)

        let picker = try XCTUnwrap(delegate.pickerModel)
        picker.open()
        picker.setQuery("Beta")
        picker.use(mode: .copyOnly)
        scheduler.drain()
        XCTAssertEqual(picker.state, .done(.copiedOnly(.requested)))
        XCTAssertEqual(presentation.snapshot.rows.map(\.relativePath), ["b.md", "a.md"])
        XCTAssertNotNil(presentation.snapshot.rows.first?.lastUsedAt)
        XCTAssertEqual(presentation.snapshot.sections.first { $0.id == .recent }?.count, 2)
    }

    func testRenderedPreviewUsesDefaultsNamesDateTimeAndLiteralClipboardWithoutUse() throws {
        let source = """
        ---
        title: Preview
        fields:
          tone:
            type: choice
            options: [brief, detailed]
            default: brief
          topic:
            type: choice
            options: [code, prose]
          note:
            default: ""
        ---
        {{tone}} {{topic}} {{note}} {{implicit}} {{date}} {{time}} {{clipboard}} {{clipboard}} \\{{literal}}
        """
        let document = PromptCodec.parse(source, filename: "preview.md")
        XCTAssertTrue(document.canRender)
        // The native adapter renders EditorModel's preview; the shared model
        // owns exact date/time formatting and default substitution.
        try put(source, at: "preview.md")
        try start()
        delegate.showLibrary()
        let presentation = try presentation()
        presentation.selectPath("preview.md")
        guard case .rendered(let text) = presentation.preview else { return XCTFail("Expected rendered preview") }
        XCTAssertTrue(text.contains("{clipboard} {clipboard}"))
        XCTAssertTrue(text.contains("brief {topic} {note} {implicit}"))
        XCTAssertFalse(text.contains("{{date}}"))
        XCTAssertFalse(text.contains("{{time}}"))
        XCTAssertEqual(delegate.pickerModel?.state, .closed)
        XCTAssertTrue(launched.isEmpty)
    }

    func testInvalidFutureOversizedAndNonUTF8RowsShowIssuesAndDisableFavourite() throws {
        try put("---\ntitle: [broken\n---\nInvalid body", at: "invalid.md")
        try put("---\nformat: 2\n---\nFuture body", at: "future.md")
        try files.write(Data(repeating: 65, count: Limits.maxPromptBytes + 1), at: "large.md")
        try files.write(Data([0xff]), at: "encoding.md")
        try start()
        delegate.showLibrary()
        let presentation = try presentation()
        for (path, code) in [("invalid.md", PromptIssueCode.invalidYAML), ("future.md", .unsupportedFormat),
                             ("large.md", .sourceTooLarge), ("encoding.md", .invalidUTF8)] {
            presentation.selectPath(RelativePath(path))
            let row = try XCTUnwrap(presentation.snapshot.selectedPrompt)
            XCTAssertFalse(row.canRender)
            XCTAssertFalse(presentation.canToggleFavorite)
            guard case .issues(let issues) = presentation.preview else { return XCTFail("Expected issues for \(path)") }
            XCTAssertTrue(issues.contains { $0.code == code }, path)
            XCTAssertEqual(issues, row.issues)
            if path != "invalid.md" { XCTAssertTrue(row.isReadOnly) }
        }
    }

    func testFavoriteButtonAndShortcutSaveRefreshPickerAndSurfaceStampedConflict() throws {
        try put("---\ntitle: One\n---\nBody", at: "one.md")
        try start()
        delegate.showLibrary()
        let presentation = try presentation()
        presentation.selectPath("one.md")
        XCTAssertTrue(presentation.canToggleFavorite)
        // The native button forwards to this adapter intent.
        presentation.toggleFavorite()
        guard case .savePending? = presentation.favoriteOutcome else { return XCTFail("Expected editor-owned save") }
        XCTAssertEqual(presentation.editorState.status, .saved)
        XCTAssertEqual(presentation.snapshot.selectedPrompt?.favorite, true)
        XCTAssertEqual(presentation.snapshot.sections.first { $0.id == .favourites }?.count, 1)
        XCTAssertNil(presentation.favoriteMessage)
        XCTAssertTrue(PromptCodec.parseFile(try files.read(at: "one.md"), filename: "one.md").frontMatter.favorite)
        let picker = try XCTUnwrap(delegate.pickerModel)
        picker.open()
        XCTAssertEqual(picker.results.first?.favorite, true)
        delegate.showLibrary()
        XCTAssertTrue(try controller().handleKeyEvent(try key(kVK_ANSI_F, characters: "F", modifiers: [.command, .shift], in: window())))
        XCTAssertEqual(presentation.snapshot.selectedPrompt?.favorite, false)

        let external = Data("---\ntitle: External\nfavorite: true\n---\nChanged outside the app".utf8)
        try files.write(external, at: "one.md")
        presentation.toggleFavorite()
        guard case .savePending? = presentation.favoriteOutcome else { return XCTFail("Expected editor-owned conflict") }
        XCTAssertEqual(presentation.editorState.conflict?.kind, .modified)
        XCTAssertNil(presentation.favoriteMessage, "The editor owns its conflict feedback")
        XCTAssertEqual(presentation.snapshot.selectedPrompt?.favorite, false)
        XCTAssertEqual(try files.read(at: "one.md"), external, "A failed favourite never overwrites an external edit")
    }

    func testEscapeClearsFilterThenClosesAndReturnDoesNotOpenEditor() throws {
        try put("Body", at: "one.md")
        try start()
        delegate.showLibrary()
        let presentation = try presentation()
        presentation.selectPath("one.md")
        presentation.setFilter("one")
        let window = try window()
        let revision = presentation.focusRevision
        let escape = try key(kVK_Escape, characters: "\u{1b}", in: window)
        XCTAssertTrue(try controller().handleKeyEvent(escape))
        XCTAssertEqual(presentation.snapshot.filter, "")
        XCTAssertGreaterThan(presentation.focusRevision, revision)
        XCTAssertTrue(window.isVisible)
        // Return has no editor/open action in this shell. Native lists consume
        // it; the window router only handles Escape and the favourite shortcut.
        XCTAssertFalse(try controller().handleKeyEvent(try key(kVK_Return, characters: "\r", in: window)))
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertTrue(try controller().handleKeyEvent(escape))
        XCTAssertFalse(window.isVisible)
        delegate.showLibrary()
        presentation.setFilter("one")
        window.cancelOperation(nil)
        XCTAssertEqual(presentation.snapshot.filter, "")
        XCTAssertTrue(window.isVisible)
        window.cancelOperation(nil)
        XCTAssertFalse(window.isVisible)
    }

    func testSettingsAndLibraryShareRegularPolicyUntilTheLastWindowCloses() throws {
        try start()
        delegate.showLibrary()
        let libraryWindow = try window()
        delegate.showSettings()
        let settingsWindow = try XCTUnwrap(delegate.settingsWindow?.window)
        XCTAssertEqual(policies, [.regular])
        libraryWindow.close()
        XCTAssertTrue(settingsWindow.isVisible)
        XCTAssertEqual(policies, [.regular])
        settingsWindow.close()
        XCTAssertEqual(policies, [.regular, .accessory])
        delegate.showLibrary()
        delegate.showSettings()
        settingsWindow.close()
        XCTAssertTrue(libraryWindow.isVisible)
        XCTAssertEqual(policies, [.regular, .accessory, .regular])
        libraryWindow.close()
        XCTAssertEqual(policies, [.regular, .accessory, .regular, .accessory])
    }

    func testKeyRoutingLeavesMarkedTextAndOtherWindowEventsAlone() throws {
        try put("Body", at: "one.md")
        try start()
        delegate.showLibrary()
        let presentation = try presentation()
        presentation.selectPath("one.md")
        presentation.setFilter("one")
        let window = try window()
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        window.contentView?.addSubview(input)
        defer {
            input.unmarkText()
            window.makeFirstResponder(nil)
            input.removeFromSuperview()
        }
        XCTAssertTrue(window.makeFirstResponder(input))
        input.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(input.hasMarkedText())
        let controller = try controller()
        XCTAssertFalse(controller.handleKeyEvent(try key(kVK_Escape, in: window)))
        XCTAssertFalse(controller.handleKeyEvent(try key(kVK_ANSI_F, characters: "F", modifiers: [.command, .shift], in: window)))
        XCTAssertEqual(presentation.snapshot.filter, "one")
        XCTAssertEqual(presentation.snapshot.selectedPrompt?.favorite, false)
        XCTAssertTrue(window.isVisible)
        input.unmarkText()
        XCTAssertFalse(controller.handleKeyEvent(try key(kVK_Escape)))
        XCTAssertFalse(controller.handleKeyEvent(try key(kVK_Escape, modifiers: .option, in: window)))
        XCTAssertEqual(presentation.snapshot.filter, "one")
        XCTAssertTrue(controller.handleKeyEvent(try key(kVK_Escape, in: window)))
        XCTAssertEqual(presentation.snapshot.filter, "")
        XCTAssertTrue(window.isVisible)
    }

    func testLibrarySwitchRebindsExistingWindowAndRetiresOldBrowserAndCallbacks() throws {
        try put("---\ntitle: Alpha\n---\nOld", at: "alpha.md")
        try start()
        delegate.showLibrary()
        let window = try window()
        let hosting = try XCTUnwrap(window.contentView)
        let presentation = try presentation()
        let old = try XCTUnwrap(delegate.libraryBrowserModel)
        presentation.selectPath("alpha.md")
        presentation.setFilter("Alpha")
        let previous = old.state
        let other = directory.appendingPathComponent("chosen", isDirectory: true)
        let otherFiles = try RootedFileStore(root: other)
        try otherFiles.write(Data("---\ntitle: Beta\n---\nNew".utf8), at: "beta.md")
        let staleWatcher = watchers[0]
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        XCTAssertTrue(try self.window() === window)
        XCTAssertTrue(window.contentView === hosting)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(try self.presentation() === presentation)
        XCTAssertFalse(presentation.model === old)
        XCTAssertEqual(presentation.activeLibraryPath, other.path)
        XCTAssertEqual(presentation.snapshot.filter, "")
        XCTAssertEqual(presentation.snapshot.rows.map(\.title), ["Beta"])
        XCTAssertNil(presentation.snapshot.selection)
        XCTAssertEqual(presentation.preview, .none)
        old.setFilter("retired")
        XCTAssertEqual(old.state, previous)
        guard case .inactive = old.toggleFavorite() else { return XCTFail("Retired browsers cannot write") }
        staleWatcher.emit(.rootUnavailable(.ioFailure))
        XCTAssertTrue(presentation.libraryAvailable)
        XCTAssertEqual(delegate.libraryStatusModel?.state, .available)
        presentation.revealFolder()
        XCTAssertEqual(revealed, [other])
    }

    func testLibraryCancelsArmedTargetDeferredBlurAndQueuedSummon() throws {
        try start()
        frontmost = externalTarget
        let picker = try XCTUnwrap(delegate.pickerModel)
        picker.open()
        let native = try XCTUnwrap(NSApp.windows.compactMap { $0 as? PromptPanel }.first {
            !originalWindows.contains(ObjectIdentifier($0))
        })
        frontmost = ownTarget
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: native)
        delegate.showLibrary()
        XCTAssertEqual(picker.state, .closed)
        XCTAssertFalse(panel.isVisible)
        try window().close()
        scheduler.drain()
        XCTAssertTrue(targetActivations.isEmpty)

        frontmost = externalTarget
        picker.open()
        frontmost = ownTarget
        picker.dismiss()
        XCTAssertEqual(targetActivations, [externalTarget])
        frontmost = externalTarget
        picker.open()
        XCTAssertFalse(panel.isVisible, "The summon waits for the held restore")
        frontmost = ownTarget
        delegate.showLibrary()
        try window().close()
        scheduler.drain()
        XCTAssertEqual(picker.state, .closed)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(targetActivations, [externalTarget], "Library cancels older restore retries")
    }

    func testTerminationDeactivatesRetainedPresentationAndBrowser() throws {
        try put("Body", at: "one.md")
        try start()
        delegate.showLibrary()
        let controller = try controller()
        let presentation = try presentation()
        let browser = try XCTUnwrap(delegate.libraryBrowserModel)
        presentation.selectPath("one.md")
        let state = presentation.snapshot
        let bytes = try files.read(at: "one.md")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(try window().isVisible)
        XCTAssertFalse(presentation.libraryAvailable)
        XCTAssertFalse(presentation.canToggleFavorite)
        presentation.setFilter("late")
        presentation.toggleFavorite()
        presentation.revealFolder()
        browser.setFilter("late")
        guard case .inactive = browser.toggleFavorite() else { return XCTFail("Termination retires the browser") }
        controller.show()
        delegate.showLibrary()
        watchers[0].emit(.rootUnavailable(.notFound))
        XCTAssertEqual(presentation.snapshot, state)
        XCTAssertEqual(try files.read(at: "one.md"), bytes)
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertFalse(try window().isVisible)
    }

    func testAdapterDetachesObserverAndRejectsQueuedRetiredGraphPublications() throws {
        let dataFiles = try RootedFileStore(root: data)
        try dataFiles.createRoot()
        let clock = SystemClock()
        let usage = UsageStore(files: dataFiles, clock: clock)
        let library = LibraryService(library: files, data: dataFiles, clock: clock, entropy: SystemEntropy())
        try put("Old", at: "old.md")
        let index = PromptIndex(service: library, usage: usage, clock: clock)
        try index.rebuild()
        let main = LibraryWindowMainThread()
        let editing = PromptEditingService(library: library, index: index, work: LibraryWindowInlineWork(), main: main)
        let editor = EditorModel(editing: editing, clock: clock, timeZone: { TimeZone.current }, main: main)
        let old = LibraryBrowserModel(index: index, usage: usage, favorites: library, main: main, editor: editor)
        let presentation = LibraryViewState(model: old, editor: editor, libraryPath: root.path, available: true,
            mainThread: main, revealLibrary: {})
        var changes = 0
        let subscription = presentation.$snapshot.dropFirst().sink { _ in changes += 1 }
        defer { subscription.cancel() }
        main.deferWork = true
        old.setFilter("Old")
        main.runNext() // Core has published; the adapter's UI hop is still queued.
        let other = directory.appendingPathComponent("new", isDirectory: true)
        let otherFiles = try RootedFileStore(root: other)
        try otherFiles.write(Data("New".utf8), at: "new.md")
        let newLibrary = LibraryService(library: otherFiles, data: dataFiles, clock: clock, entropy: SystemEntropy())
        let newIndex = PromptIndex(service: newLibrary, usage: usage, clock: clock)
        try newIndex.rebuild()
        let newEditing = PromptEditingService(library: newLibrary, index: newIndex, work: LibraryWindowInlineWork(), main: main)
        let newEditor = EditorModel(editing: newEditing, clock: clock, timeZone: { TimeZone.current }, main: main)
        let new = LibraryBrowserModel(index: newIndex, usage: usage, favorites: newLibrary, main: main, editor: newEditor)
        presentation.rebind(to: new, editor: newEditor, libraryPath: other.path, available: true)
        let rebound = presentation.snapshot
        let reboundChanges = changes
        main.drain()
        XCTAssertEqual(presentation.snapshot, rebound)
        XCTAssertEqual(changes, reboundChanges)
        try put("Later", at: "later.md")
        try index.rebuild() // Old model is still active, but its view token is gone.
        main.drain()
        XCTAssertEqual(presentation.snapshot, rebound)
        XCTAssertEqual(changes, reboundChanges)
        XCTAssertEqual(old.rows.count, 1, "Its retained filter applies to the old graph only")
        presentation.deactivate()
        new.setFilter("missing")
        main.drain()
        XCTAssertEqual(presentation.snapshot, rebound)
        old.deactivate()
        new.deactivate()
        editor.deactivate()
        newEditor.deactivate()
        editing.deactivate()
        newEditing.deactivate()
    }

    func testRetainedLibraryControllerAndPresentationDoNotRetainCompositionRoot() throws {
        try put("Body", at: "one.md")
        try start()
        delegate.showLibrary()
        let controller = try controller()
        let presentation = try presentation()
        let browser = try XCTUnwrap(delegate.libraryBrowserModel)
        let window = try window()
        weak var rootReference = delegate
        delegate = nil
        XCTAssertNil(rootReference)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(presentation.libraryAvailable)
        controller.show()
        presentation.revealFolder()
        guard case .inactive = browser.toggleFavorite() else { return XCTFail("A released root retires its browser") }
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(revealed.isEmpty)
    }

    func testFavouriteFailureMessagesPreserveTypedOutcomesWithoutToolBodies() {
        XCTAssertNotNil(LibraryStrings.favoriteMessage(.noSelection))
        XCTAssertNotNil(LibraryStrings.favoriteMessage(.inactive))
        XCTAssertNotEqual(LibraryStrings.favoriteMessage(.fileStoreFailure(.notFound)),
                          LibraryStrings.favoriteMessage(.fileStoreFailure(.ioFailure)))
        XCTAssertNotEqual(LibraryStrings.favoriteMessage(.libraryFailure(.conflict)),
                          LibraryStrings.favoriteMessage(.libraryFailure(.operationFailed)))
        XCTAssertEqual(LibraryStrings.favoriteMessage(.writeFailure(.invalidPrompt)), PromptWriteError.invalidPrompt.description)
    }
}

private struct LibraryWindowInlineWork: BackgroundWork {
    func run(_ work: @escaping () -> Void) { work() }
}

private final class LibraryWindowScheduler: MonkeysPawCore.Scheduler {
    private var pending: [() -> Void] = []
    func after(_ delay: Duration, _ work: @escaping () -> Void) { pending.append(work) }
    func drain() { while !pending.isEmpty { pending.removeFirst()() } }
}

private final class LibraryWindowWatcher: FileStoreWatcher {
    private var onEvent: (@Sendable (FileStoreWatchEvent) -> Void)?
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws { self.onEvent = onEvent }
    func stop() {} // Retain a stale callback to exercise generation guards.
    func emit(_ event: FileStoreWatchEvent) { onEvent?(event) }
}

private final class LibraryWindowMainThread: MainThread {
    var deferWork = false
    private var pending: [() -> Void] = []
    func run(_ work: @escaping () -> Void) {
        if deferWork { pending.append(work) }
        else { work() }
    }
    func runNext() { if !pending.isEmpty { pending.removeFirst()() } }
    func drain() { while !pending.isEmpty { runNext() } }
}
