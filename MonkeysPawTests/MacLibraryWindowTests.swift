import AppKit
import Carbon.HIToolbox
import Combine
import MonkeysPawCore
import SwiftUI
import XCTest
@testable import MonkeysPaw

/// Inspect the controller's presentation, rather than SwiftUI's lazy
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
    private func spin(_ predicate: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }

    private func controller() throws -> LibraryWindowController { try XCTUnwrap(delegate.libraryWindow) }
    private func window() throws -> NSWindow { try XCTUnwrap(controller().window) }

    private func presentation() throws -> LibraryViewState {
        let controller = try controller()
        XCTAssertTrue(try window().contentViewController === controller.splitController)
        XCTAssertEqual(controller.splitController?.splitViewItems.count, 4)
        return controller.presentation
    }

    private func key(_ code: Int, characters: String = "", modifiers: NSEvent.ModifierFlags = [],
                     in window: NSWindow? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)))
    }

    func testOpeningTwiceAndReopeningReusesOneWindowAndNativeSplitView() throws {
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
            !originalWindows.contains(ObjectIdentifier($0)) && $0 === window
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
        let windowMenu = try XCTUnwrap(NSApp.windowsMenu)
        let mainItem = try XCTUnwrap(windowMenu.items.first { $0.action == #selector(AppDelegate.showLibrary) })
        let status = delegate.makeStatusMenu()
        let statusItem = try XCTUnwrap(status.items.first { $0.title == OnboardingStrings.libraryAvailableMenu })
        XCTAssertNil(mainItem.target)
        XCTAssertTrue(statusItem.target === delegate)
        XCTAssertEqual(mainItem.keyEquivalent, "l")
        XCTAssertEqual(mainItem.keyEquivalentModifierMask, .command)
        XCTAssertTrue(main.items.contains { $0.submenu === windowMenu })
        XCTAssertTrue(delegate.validateMenuItem(mainItem))
        delegate.showLibrary()
        let libraryWindow = try window()
        libraryWindow.close()
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(statusItem.action), to: statusItem.target, from: statusItem))
        XCTAssertTrue(try window() === libraryWindow)
        XCTAssertTrue(libraryWindow.isVisible)
        watchers[0].emit(.rootUnavailable(.notFound))
        scheduler.drain()
        XCTAssertEqual(statusItem.title, OnboardingStrings.libraryUnavailableMenu)
        XCTAssertFalse(statusItem.isEnabled)
        XCTAssertFalse(delegate.validateMenuItem(mainItem))
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
        try controller().toggleFavorite(nil)
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

    func testEscapeDoesNotCloseLibraryAndReturnFocusesEditor() throws {
        try put("Body", at: "one.md")
        try start()
        delegate.showLibrary()
        let presentation = try presentation()
        presentation.selectPath("one.md")
        presentation.setFilter("one")
        let window = try window()
        window.cancelOperation(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(presentation.snapshot.filter, "one", "Escape outside Search does not navigate")
        let search = try XCTUnwrap(controller().searchItem?.searchField)
        search.stringValue = ""
        try controller().filterSearch(search)
        XCTAssertEqual(presentation.snapshot.filter, "")
        window.cancelOperation(nil)
        XCTAssertTrue(window.isVisible)
        let revision = presentation.editorFocusRevision
        try controller().promptList?.tableView.keyDown(with: key(kVK_Return, characters: "\r", in: window))
        XCTAssertGreaterThan(presentation.editorFocusRevision, revision)
        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(revealed.isEmpty)
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

    func testLibraryCommandValidationLeavesMarkedTextAndOtherWindowsAlone() throws {
        try put("Body", at: "one.md")
        try start()
        delegate.showLibrary()
        let presentation = try presentation()
        presentation.selectPath("one.md")
        let window = try window()
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        window.contentView?.addSubview(input)
        defer { input.unmarkText(); window.makeFirstResponder(nil); input.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(input))
        let controller = try controller()
        let item = NSMenuItem(title: LibraryStrings.favourite,
            action: #selector(LibraryWindowController.toggleFavorite(_:)), keyEquivalent: "d")
        XCTAssertTrue(controller.validateLibraryMenuItem(item, in: window))
        input.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(input.hasMarkedText())
        XCTAssertFalse(controller.validateLibraryMenuItem(item, in: window))
        let search = NSMenuItem(title: MainMenuStrings.searchLibrary,
            action: #selector(LibraryWindowController.searchLibrary(_:)), keyEquivalent: "f")
        XCTAssertFalse(controller.validateLibraryMenuItem(search, in: window))
        controller.searchLibrary(nil)
        XCTAssertTrue(window.firstResponder === input)
        let newPrompt = NSMenuItem(title: LibraryCommandStrings.newPrompt,
            action: #selector(LibraryWindowController.newDocument(_:)), keyEquivalent: "n")
        XCTAssertFalse(controller.validateLibraryMenuItem(newPrompt, in: window))
        controller.toggleFavorite(nil)
        controller.newDocument(nil)
        XCTAssertNil(presentation.newPromptRequest, "Marked text keeps New Prompt from opening its sheet")
        XCTAssertEqual(presentation.snapshot.selectedPrompt?.favorite, false)
        input.unmarkText()
        XCTAssertTrue(controller.validateLibraryMenuItem(item, in: window))
        XCTAssertFalse(controller.validateLibraryMenuItem(item, in: nil))
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        XCTAssertFalse(controller.validateLibraryMenuItem(item, in: other))
        XCTAssertTrue(window.isVisible)
    }

    func testNativeWindowSplitViewAndCustomizableToolbar() throws {
        try start()
        delegate.showLibrary()
        let controller = try controller()
        let window = try window()
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(window.isRestorable)
        XCTAssertEqual(window.frameAutosaveName, "Library")
        XCTAssertEqual(window.contentMinSize, NSSize(width: 820, height: 480))
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        XCTAssertEqual(split.splitView.autosaveName, "LibrarySplitView")
        XCTAssertEqual(split.splitViewItems.count, 4)
        let items = split.splitViewItems
        XCTAssertEqual(items[0].behavior, .sidebar)
        XCTAssertEqual(items[0].minimumThickness, 180)
        XCTAssertEqual(items[0].maximumThickness, 320)
        XCTAssertEqual(items[1].behavior, .contentList)
        XCTAssertEqual(items[1].minimumThickness, 240)
        XCTAssertEqual(items[2].minimumThickness, 360)
        XCTAssertLessThan(items[2].holdingPriority.rawValue, items[1].holdingPriority.rawValue)
        XCTAssertEqual(items[3].behavior, .inspector)
        XCTAssertEqual(items[3].minimumThickness, 280)
        XCTAssertEqual(items[3].maximumThickness, 560)
        XCTAssertTrue(items[3].isCollapsed)
        items[0].isCollapsed = false
        let sidebarCommand = NSMenuItem(title: "Sidebar", action: Selector(("toggleSidebar:")), keyEquivalent: "")
        XCTAssertTrue(controller.validateLibraryMenuItem(sidebarCommand, in: window))
        XCTAssertEqual(sidebarCommand.title, "Hide Sidebar")
        items[0].isCollapsed = true
        XCTAssertTrue(controller.validateLibraryMenuItem(sidebarCommand, in: window))
        XCTAssertEqual(sidebarCommand.title, "Show Sidebar")
        let toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertEqual(toolbar.identifier, "LibraryToolbar")
        XCTAssertEqual(toolbar.displayMode, .iconOnly)
        XCTAssertTrue(toolbar.allowsUserCustomization)
        XCTAssertTrue(toolbar.autosavesConfiguration)
        let toolbarCommand = NSMenuItem(title: "Toolbar", action: Selector(("toggleToolbarShown:")), keyEquivalent: "")
        toolbar.isVisible = false
        XCTAssertTrue(controller.validateLibraryMenuItem(toolbarCommand, in: window))
        XCTAssertEqual(toolbarCommand.title, "Show Toolbar")
        toolbar.isVisible = true
        XCTAssertTrue(controller.validateLibraryMenuItem(toolbarCommand, in: window))
        XCTAssertEqual(toolbarCommand.title, "Hide Toolbar")
        XCTAssertEqual(controller.toolbarDefaultItemIdentifiers(toolbar), [.toggleSidebar, .sidebarTrackingSeparator,
            .flexibleSpace, .libraryNewPrompt, .libraryListSeparator, .libraryEditorMode, .flexibleSpace, .libraryFavorite,
            .libraryAssistant, .librarySearch, .inspectorTrackingSeparator, .toggleInspector])
        for id in [NSToolbarItem.Identifier.libraryReveal, .libraryImport, .libraryDelete, .space] {
            XCTAssertTrue(controller.toolbarAllowedItemIdentifiers(toolbar).contains(id))
        }
    }

    func testInspectorCollapseAndPresentationStayInSyncWithoutResizingWindow() throws {
        try put("Body", at: "one.md")
        try start()
        delegate.showLibrary()
        let controller = try controller()
        let item = try XCTUnwrap(controller.inspectorItem)
        let window = try window()
        let frame = window.frame
        let minimum = window.contentMinSize
        item.isCollapsed = false
        XCTAssertTrue(controller.presentation.isInspectorVisible)
        item.isCollapsed = true
        XCTAssertFalse(controller.presentation.isInspectorVisible)
        controller.presentation.showInspector(.fields)
        controller.refreshWindowPresentation()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        XCTAssertFalse(item.isCollapsed)
        controller.presentation.setInspectorVisible(false)
        controller.refreshWindowPresentation()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        XCTAssertTrue(item.isCollapsed)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(window.contentMinSize, minimum)
    }

    func testWindowDocumentIdentityAndEditorModeCommands() throws {
        try put("---\ntitle: Display Title\n---\nBody", at: "folder/one.md")
        try start()
        delegate.showLibrary()
        let controller = try controller()
        let presentation = controller.presentation
        let window = try window()
        controller.refreshWindowPresentation()
        XCTAssertEqual(window.title, "All Prompts")
        XCTAssertEqual(window.subtitle, "1 prompt")
        XCTAssertNil(window.representedURL)
        XCTAssertFalse(window.isDocumentEdited)
        presentation.selectSection(.favourites)
        controller.refreshWindowPresentation()
        XCTAssertEqual(window.title, "Favourites")
        XCTAssertEqual(window.subtitle, "0 prompts")
        presentation.selectSection(.all)
        presentation.selectPath("folder/one.md")
        controller.refreshWindowPresentation()
        XCTAssertEqual(window.title, "Display Title")
        XCTAssertEqual(window.subtitle, "folder/one.md")
        XCTAssertEqual(window.representedURL, root.appendingPathComponent("folder/one.md"))
        presentation.setFilter("No match")
        controller.refreshWindowPresentation()
        XCTAssertEqual(window.title, "Display Title", "A filtered-out row never changes the open document title")
        presentation.setFilter("")
        presentation.edit("Draft")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        XCTAssertTrue(window.isDocumentEdited)
        controller.showPreview(nil)
        XCTAssertEqual(presentation.editorMode, .preview)
        let toolbar = try XCTUnwrap(window.toolbar)
        let group = try XCTUnwrap(controller.toolbar(toolbar, itemForItemIdentifier: .libraryEditorMode,
            willBeInsertedIntoToolbar: false) as? NSToolbarItemGroup)
        group.selectedIndex = 0
        controller.selectEditorMode(group)
        XCTAssertEqual(presentation.editorMode, .edit)
        group.selectedIndex = 1
        controller.selectEditorMode(group)
        XCTAssertEqual(presentation.editorMode, .preview)
        group.selectedIndex = LibraryViewState.EditorMode.source.rawValue
        controller.selectEditorMode(group)
        XCTAssertEqual(presentation.editorMode, .source)
        XCTAssertEqual(group.subitems.count, 3)
        controller.showEdit(nil)
        XCTAssertEqual(presentation.editorMode, .edit)
        let item = NSMenuItem(title: "Preview", action: #selector(LibraryWindowController.showPreview(_:)), keyEquivalent: "2")
        XCTAssertTrue(controller.validateLibraryMenuItem(item, in: window))
        XCTAssertEqual(item.state, .off)
        controller.showPreview(nil)
        XCTAssertTrue(controller.validateLibraryMenuItem(item, in: window))
        XCTAssertEqual(item.state, .on)
        controller.showInFinder(nil)
        XCTAssertEqual(revealed, [root.appendingPathComponent("folder/one.md")])
    }

    func testPromptTableRowsTypeSelectionKeyboardOpenAndDeleteIntent() throws {
        try put("---\ntitle: Alpha\ndescription: A description\n---\nBody", at: "a.md")
        try put("---\ntitle: Beta\ntags: [code]\n---\nBody", at: "folder/b.md")
        try start()
        delegate.showLibrary()
        let controller = try controller()
        let list = try XCTUnwrap(controller.promptList)
        let table = list.tableView
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertNil(table.headerView)
        XCTAssertTrue(table.allowsTypeSelect)
        XCTAssertTrue(table.allowsEmptySelection)
        XCTAssertFalse(table.allowsMultipleSelection)
        let cell = try XCTUnwrap(list.tableView(table, viewFor: table.tableColumns.first, row: 0) as? LibraryPromptCell)
        XCTAssertEqual(cell.titleField.stringValue, "Alpha")
        XCTAssertEqual(cell.detailField.stringValue, "A description")
        let second = try XCTUnwrap(list.tableView(table, viewFor: table.tableColumns.first, row: 1) as? LibraryPromptCell)
        XCTAssertEqual(second.detailField.stringValue, "folder · #code")
        XCTAssertEqual(list.tableView(table, typeSelectStringFor: table.tableColumns.first, row: 1), "Beta")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(controller.presentation.editorState.prompt?.relativePath, "folder/b.md")
        controller.presentation.setFilter("Alpha")
        XCTAssertEqual(table.selectedRow, -1, "A hidden selection has no highlighted row")
        XCTAssertEqual(controller.presentation.editorState.prompt?.relativePath, "folder/b.md")
        controller.presentation.setFilter("")
        let revision = controller.presentation.editorFocusRevision
        table.keyDown(with: try key(kVK_Return, in: try window()))
        XCTAssertGreaterThan(controller.presentation.editorFocusRevision, revision)
        table.keyDown(with: try key(kVK_Delete, modifiers: .command, in: try window()))
        XCTAssertEqual(controller.presentation.fileCommandRequest?.command, .delete)
    }

    func testSelectionDefersMouseUpAndCancelsDraggedClick() {
        var buttonDown = false
        var opened: [RelativePath] = []
        let deferral = LibrarySelectionDeferral(isButtonDown: { buttonDown }, open: { opened.append($0) })
        deferral.select("keyboard.md")
        XCTAssertEqual(opened, ["keyboard.md"])
        buttonDown = true
        deferral.beginMouseSelection("mouse.md")
        deferral.select("mouse.md")
        XCTAssertEqual(opened, ["keyboard.md"])
        buttonDown = false
        deferral.endMouseSelection()
        XCTAssertEqual(opened, ["keyboard.md", "mouse.md"])
        buttonDown = true
        deferral.beginMouseSelection("drag.md")
        deferral.select("drag.md")
        deferral.beginDrag()
        buttonDown = false
        deferral.endMouseSelection()
        XCTAssertEqual(opened, ["keyboard.md", "mouse.md"])
    }

    func testLibraryValidationRejectsSheetsNoPromptAndUnavailableLibrary() throws {
        try put("Body", at: "one.md")
        try start()
        delegate.showLibrary()
        let controller = try controller()
        let window = try window()
        let item = NSMenuItem(title: EditorStrings.save,
            action: #selector(LibraryWindowController.saveDocument(_:)), keyEquivalent: "s")
        XCTAssertFalse(controller.validateLibraryMenuItem(item, in: window))
        controller.presentation.selectPath("one.md")
        XCTAssertTrue(controller.validateLibraryMenuItem(item, in: window))
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        XCTAssertFalse(controller.validateLibraryMenuItem(item, in: window))
        window.endSheet(sheet)
        sheet.orderOut(nil)
        controller.presentation.setLibraryAvailable(false)
        XCTAssertFalse(controller.validateLibraryMenuItem(item, in: window))
    }

    func testSearchFieldActionsKeepTheBrowserFilterInSync() throws {
        try put("Alpha", at: "alpha.md")
        try start()
        delegate.showLibrary()
        let controller = try controller()
        let search = try XCTUnwrap(controller.searchItem?.searchField)
        XCTAssertTrue(search.target === controller)
        XCTAssertEqual(search.action, #selector(LibraryWindowController.filterSearch(_:)))
        search.stringValue = "Alpha"
        controller.filterSearch(search)
        XCTAssertEqual(controller.presentation.snapshot.filter, "Alpha")
        let editor = NSTextView()
        editor.string = "Alpha"
        let cancel = #selector(NSResponder.cancelOperation(_:))
        XCTAssertTrue(controller.control(search, textView: editor, doCommandBy: cancel))
        XCTAssertEqual(editor.string, "")
        search.sendAction(search.action, to: search.target)
        XCTAssertEqual(controller.presentation.snapshot.filter, "")
        XCTAssertFalse(controller.control(search, textView: editor, doCommandBy: cancel), "Empty Search ends natively")
        search.stringValue = "Alpha"
        controller.filterSearch(search)
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(controller.control(search, textView: editor, doCommandBy: cancel))
        XCTAssertEqual(controller.presentation.snapshot.filter, "Alpha")
        editor.unmarkText()
        controller.presentation.setFilter("Other")
        controller.refreshWindowPresentation()
        XCTAssertEqual(search.stringValue, "Other")
    }

    func testEndingToolbarSearchDoesNotPublishStaleNativeText() throws {
        try put("Kept", at: "kept.md")
        try start()
        delegate.showLibrary()
        let controller = try controller()
        let search = try XCTUnwrap(controller.searchItem?.searchField)
        controller.presentation.setFilter("Kept")
        // A model publication can precede the toolbar's queued render. Ending
        // or collapsing search is a lifecycle event, not a new query edit.
        search.stringValue = ""
        search.delegate?.searchFieldDidEndSearching?(search)
        XCTAssertEqual(controller.presentation.snapshot.filter, "Kept")
        controller.synchronizeSearch {
            search.sendAction(search.action, to: search.target)
        }
        XCTAssertEqual(controller.presentation.snapshot.filter, "Kept", "Presentation actions are not query edits")
        controller.refreshWindowPresentation()
        XCTAssertEqual(search.stringValue, "Kept")
        search.stringValue = ""
        search.sendAction(search.action, to: search.target)
        XCTAssertEqual(controller.presentation.snapshot.filter, "", "The cancel action still clears the query")
    }

    func testNativeSearchCancelButtonClearsTheQuery() throws {
        try put("Kept", at: "kept.md")
        try start()
        delegate.showLibrary()
        let controller = try controller()
        controller.searchLibrary(nil)
        let search = try XCTUnwrap(controller.searchItem?.searchField)
        search.stringValue = "Kept"
        search.sendAction(search.action, to: search.target)
        XCTAssertEqual(controller.presentation.snapshot.filter, "Kept")
        let cell = try XCTUnwrap(search.cell as? NSSearchFieldCell)
        let cancel = try XCTUnwrap(cell.cancelButtonCell)
        cancel.performClick(search)
        XCTAssertEqual(controller.presentation.snapshot.filter, "")
        XCTAssertEqual(search.stringValue, "")
    }

    func testFindWithoutAnOpenEditorFocusesLibrarySearch() throws {
        try start()
        delegate.showLibrary()
        let controller = try controller()
        let item = NSMenuItem(title: "Find…", action: #selector(LibraryWindowController.performFindPanelAction(_:)), keyEquivalent: "f")
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        controller.performFindPanelAction(item)
        let search = try XCTUnwrap(controller.searchItem?.searchField)
        let responder = try window().firstResponder
        XCTAssertTrue(responder === search.currentEditor() || responder === search)
    }

    func testDockReopenRestoresAMinimizedLibraryInsteadOfOpeningThePicker() throws {
        try put("Body", at: "one.md")
        try start()
        delegate.showLibrary()
        let window = try window()
        XCTAssertTrue(spin { window.isVisible })
        window.miniaturize(nil)
        guard spin({ window.isMiniaturized }) else {
            throw XCTSkip("The window server did not minimize the hosted window")
        }
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(spin { !window.isMiniaturized && window.isVisible })
        XCTAssertNotEqual(delegate.pickerModel?.state, .picker, "The Dock restores the window, not the picker")
    }

    func testSidebarContextMenuCreatesInClickedFolderAndRevealsIt() throws {
        try put("Body", at: "Folder/one.md")
        try start()
        delegate.showLibrary()
        let presentation = try presentation()
        presentation.requestNewPrompt(in: .folder("Folder"))
        XCTAssertEqual(presentation.snapshot.selectedSection, .folder("Folder"))
        let request = try XCTUnwrap(presentation.newPromptRequest)
        XCTAssertEqual(request.folder, "Folder")
        presentation.resolveNewPrompt(.cancelFileCommand, id: request.id)
        presentation.revealFolder("Folder")
        XCTAssertEqual(revealed, [root.appendingPathComponent("Folder")])
        presentation.revealFolder("Missing")
        XCTAssertEqual(revealed.count, 1, "Only sidebar folders can be revealed")
    }

    func testNewPromptCommandUsesSharedGateAndRefusesOtherWindowsAndDialogs() throws {
        try start()
        delegate.showLibrary()
        let controller = try controller()
        let presentation = try presentation()
        let window = try window()
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let item = NSMenuItem(title: LibraryCommandStrings.newPrompt,
            action: #selector(LibraryWindowController.newDocument(_:)), keyEquivalent: "n")
        XCTAssertTrue(presentation.canCreatePrompt, "An empty library can create its first prompt")
        XCTAssertFalse(controller.validateLibraryMenuItem(item, in: other))
        XCTAssertTrue(controller.validateLibraryMenuItem(item, in: window))
        controller.newDocument(nil)
        let request = try XCTUnwrap(presentation.newPromptRequest)
        XCTAssertFalse(presentation.canCreatePrompt)
        XCTAssertFalse(controller.validateLibraryMenuItem(item, in: window))
        controller.newDocument(nil)
        XCTAssertEqual(presentation.newPromptRequest?.id, request.id)
        presentation.resolveNewPrompt(.cancelFileCommand, id: request.id)
        XCTAssertTrue(presentation.canCreatePrompt)
        presentation.setLibraryAvailable(false)
        XCTAssertFalse(controller.validateLibraryMenuItem(item, in: window))
        controller.newDocument(nil)
        XCTAssertNil(presentation.newPromptRequest)
        presentation.setLibraryAvailable(true)
        presentation.didHide()
        XCTAssertFalse(presentation.canCreatePrompt)
    }

    func testSearchLibraryFocusesFilterWithoutChangingSelectionOrDirtyDraft() throws {
        try put("Body", at: "one.md")
        try start()
        delegate.showLibrary()
        let controller = try controller()
        let presentation = try presentation()
        let window = try window()
        presentation.selectPath("one.md")
        presentation.edit("Draft")
        presentation.setFilter("one")
        let selection = presentation.snapshot.selection
        controller.searchLibrary(nil)
        let filter = try XCTUnwrap(controller.searchItem?.searchField)
        XCTAssertTrue(window.firstResponder === filter.currentEditor() || window.firstResponder === filter)
        XCTAssertEqual(presentation.snapshot.filter, "one")
        XCTAssertEqual(presentation.snapshot.selection, selection)
        XCTAssertEqual(presentation.editorState.source, "Draft")
        XCTAssertTrue(presentation.editorState.isDirty)

        delegate.installMainMenu()
        let edit = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" })
        let find = try XCTUnwrap(edit.items.compactMap(\.submenu).first { $0.title == MainMenuStrings.find })
        let search = try XCTUnwrap(find.items.first { $0.action == #selector(LibraryWindowController.searchLibrary(_:)) })
        XCTAssertEqual(search.keyEquivalent, "f")
        XCTAssertEqual(search.keyEquivalentModifierMask, [.command, .option])
        XCTAssertNil(search.target)
        XCTAssertFalse(delegate.validateLibraryFileMenuItem(search, in: nil))
        XCTAssertTrue(delegate.validateLibraryFileMenuItem(search, in: window))
        presentation.requestNewPrompt()
        XCTAssertFalse(delegate.validateLibraryFileMenuItem(search, in: window))
    }

    func testImportChooserPublishesNewPromptToolbarGateChanges() throws {
        try start()
        delegate.showLibrary()
        let presentation = try presentation()
        let imports = try XCTUnwrap(presentation.imports)
        var finishChoosing: (([URL]) -> Void)?
        imports.onChoose = { done in finishChoosing = done; return {} }
        var publications = 0
        let subscription = presentation.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        XCTAssertTrue(presentation.canCreatePrompt)
        imports.choose()
        XCTAssertGreaterThan(publications, 0)
        XCTAssertFalse(presentation.canCreatePrompt)
        presentation.requestNewPrompt()
        XCTAssertNil(presentation.newPromptRequest)
        let choosingPublications = publications
        try XCTUnwrap(finishChoosing)([])
        XCTAssertGreaterThan(publications, choosingPublications)
        XCTAssertTrue(presentation.canCreatePrompt)
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
