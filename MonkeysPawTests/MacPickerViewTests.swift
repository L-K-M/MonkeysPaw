import AppKit
import Carbon.HIToolbox
import Combine
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

/// Every graph uses isolated roots and a recording launcher. FSEvents and the
/// native panel are real; focus restoration never activates an external app.
final class MacPickerViewTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var files: RootedFileStore!
    private var delegate: AppDelegate!
    private var controller: PanelController!
    private var launched: [URL] = []
    private var originalWindows: Set<ObjectIdentifier> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library", isDirectory: true)
        data = directory.appendingPathComponent("data", isDirectory: true)
        files = try RootedFileStore(root: root)
    }

    override func tearDown() {
        defer { super.tearDown() }
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate?.pickerModel?.dismiss()
        controller?.hide()
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        delegate = nil
        controller = nil
        files = nil
        launched = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func start(scheduler: MonkeysPawCore.Scheduler = DispatchScheduler()) throws -> PickerModel {
        delegate = AppDelegate(libraryRoot: root, dataRoot: data, launchURI: { [weak self] in self?.launched.append($0) },
            makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in
                    XCTFail("Hosted picker tests must not activate an external app")
                    return false
                }), mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, scheduler: scheduler, makePanelController: { [weak self] main, scheduler, log in
                let panel = PanelController(mainThread: main, scheduler: scheduler, log: log)
                self?.controller = panel
                return panel
            })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        return try XCTUnwrap(delegate.pickerModel)
    }

    private func open(scheduler: MonkeysPawCore.Scheduler = DispatchScheduler()) throws -> PickerModel {
        let picker = try start(scheduler: scheduler)
        delegate.togglePicker()
        XCTAssertTrue(spin { self.controller.isActiveAndVisible })
        XCTAssertEqual(picker.state, .picker)
        XCTAssertTrue(spin { self.find("picker-query") != nil })
        return picker
    }

    func testGraphCreatesRootAndInstallsPickerBeforePublishingInitialIndex() throws {
        let picker = try start()
        XCTAssertEqual(picker.state, .closed)
        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(picker.libraryAvailable)
        XCTAssertTrue(picker.results.isEmpty)
        XCTAssertEqual(NSApp.windows.map(ObjectIdentifier.init).filter { !originalWindows.contains($0) }, [])
    }

    func testOnDiskPromptAndEditLibraryLaunchURLs() throws {
        let path = "folder name/Prompt #%.md"
        try files.write(Data("---\ntitle: Useful\nfavorite: true\ntags: [code]\n---\nBody".utf8), at: path)
        let picker = try open()
        XCTAssertEqual(picker.results.first?.title, "Useful")
        XCTAssertEqual(picker.results.first?.folder, "folder name")
        XCTAssertEqual(picker.results.first?.tags, ["code"])
        XCTAssertEqual(picker.results.first?.favorite, true)
        XCTAssertEqual(picker.selectedPreview, .body("Body"))
        picker.editSelected()
        XCTAssertNil(picker.requestedIntent)
        XCTAssertEqual(launched, [root.appendingPathComponent(path)])
        XCTAssertEqual(picker.state, .closed)
        XCTAssertFalse(controller.isVisible)

        picker.open()
        picker.openLibrary()
        XCTAssertNil(picker.requestedIntent)
        XCTAssertEqual(launched, [root.appendingPathComponent(path), root])
        XCTAssertEqual(picker.state, .closed)
        XCTAssertFalse(controller.isVisible)
    }

    func testNoMatchCreationKeepsExactTitleAfterSanitizingAndCollision() throws {
        try files.write(Data("---\ntitle: Unrelated\n---\nExisting".utf8), at: "a b.md")
        let picker = try open()
        let title = "  a/b  "
        picker.setQuery(title)
        XCTAssertEqual(picker.noMatches?.createTitle, title)
        try XCTUnwrap(delegate.pickerPresentation).createNoMatch()
        let path = "a b 2.md"
        let document = PromptCodec.parseFile(try files.read(at: path), filename: path)
        XCTAssertEqual(document.frontMatter.title, title)
        XCTAssertEqual(document.body, Strings.newPromptBody)
        XCTAssertNotNil(document.frontMatter.id)
        XCTAssertTrue(document.canRender)
        XCTAssertEqual(try files.read(at: "a b.md"), Data("---\ntitle: Unrelated\n---\nExisting".utf8))
        XCTAssertEqual(launched, [root.appendingPathComponent(path)])
        XCTAssertEqual(picker.state, .closed)
    }

    func testUnavailableLibraryShortcutsKeepPickerQueryAndSelection() throws {
        try files.write(Data("Cached Alpha".utf8), at: "cached-alpha.md")
        try files.write(Data("Cached Beta".utf8), at: "cached-beta.md")
        let picker = try open()
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        let panel = try currentPanel()
        let query = try XCTUnwrap(find("picker-query") as? PickerTextField)
        presentation.setQuery("cached")
        picker.selectResult(at: 1)
        XCTAssertEqual(picker.selectionIndex, 1)
        XCTAssertTrue(spin { query.stringValue == "cached" })
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(spin { !picker.libraryAvailable })

        for (code, characters) in [(kVK_ANSI_L, "l"), (kVK_Return, "\r")] {
            try sendKey(code: UInt16(code), characters: characters, modifiers: .command, to: panel)
            XCTAssertNil(picker.requestedIntent)
            XCTAssertEqual(picker.state, .picker)
            XCTAssertEqual(presentation.state, .picker)
            XCTAssertTrue(controller.isVisible)
            XCTAssertTrue(launched.isEmpty)
            XCTAssertEqual(picker.query, "cached")
            XCTAssertEqual(query.stringValue, "cached")
            XCTAssertEqual(picker.selectionIndex, 1)
            XCTAssertEqual(presentation.transientStatus, Strings.libraryUnavailable)
            XCTAssertEqual(presentation.status, Strings.libraryUnavailable)
        }
    }

    func testExternalSaveReachesPickerWithinOneSecondThroughFSEvents() throws {
        let picker = try open()
        let started = ProcessInfo.processInfo.systemUptime
        try Data("External body".utf8).write(to: root.appendingPathComponent("external.md"), options: .atomic)
        let arrived = spin(until: started + 1.0) { picker.results.first?.relativePath == "external.md" }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let timing = XCTAttachment(string: "External save → picker: \(elapsed) seconds")
        timing.lifetime = .keepAlways
        add(timing)
        XCTAssertTrue(arrived, "Real FSEvents → debounce → index → picker exceeded one second")
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertEqual(picker.selectedPreview, .body("External body"))
    }

    func testBackgroundSchedulerPublishesOnlyOnMainThread() throws {
        let picker = try open(scheduler: BackgroundPickerScheduler())
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        let subscription = presentation.objectWillChange.sink { XCTAssertTrue(Thread.isMainThread) }
        defer { subscription.cancel() }
        try Data("Body".utf8).write(to: root.appendingPathComponent("external.md"))
        XCTAssertTrue(spin { picker.results.count == 1 })
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(spin { !picker.libraryAvailable })
        XCTAssertEqual(picker.results.count, 1)
    }

    func testRootRemovalKeepsCacheAndRequiresRestart() throws {
        try files.write(Data("Cached".utf8), at: "cached.md")
        let picker = try open()
        // Keep an independent stream alive to prove FSEvents saw restoration.
        let restored = expectation(description: "FSEvents observed the restored prompt")
        let observer = try RootedFileWatcher(root: root, log: OSLogSink())
        try observer.start { event in
            if event == .file(FileStoreEvent(relativePath: "restored.md", kind: .created)) { restored.fulfill() }
        }
        defer { observer.stop() }
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(spin { !picker.libraryAvailable })
        XCTAssertEqual(picker.results.count, 1)
        XCTAssertEqual(picker.selectedPreview, .body("Cached"))
        XCTAssertTrue(try XCTUnwrap(delegate.pickerPresentation).status.contains(Strings.libraryUnavailable))
        try files.write(Data("Restored".utf8), at: "restored.md")
        wait(for: [restored], timeout: 3)
        XCTAssertFalse(picker.libraryAvailable)
        XCTAssertEqual(picker.results.map(\.relativePath), ["cached.md"])
        picker.dismiss()
        picker.open()
        XCTAssertFalse(picker.libraryAvailable)
        XCTAssertEqual(picker.results.map(\.relativePath), ["cached.md"])
    }

    func testRootRemovalFlushesPendingReloadWithoutLosingCachedPrompt() throws {
        try files.write(Data("Cached".utf8), at: "cached.md")
        let scheduler = ObservedPickerScheduler()
        let picker = try open(scheduler: scheduler)
        try Data("Pending edit".utf8).write(to: root.appendingPathComponent("cached.md"))
        XCTAssertTrue(spin { scheduler.sawDebounce })
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(spin { !picker.libraryAvailable })
        XCTAssertEqual(picker.results.count, 1)
        XCTAssertEqual(picker.selectedPreview, .body("Cached"))
    }

    func testEmptyRootRemovalShowsBanner() throws {
        let picker = try open()
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(spin { !picker.libraryAvailable })
        XCTAssertTrue(picker.results.isEmpty)
        XCTAssertTrue(try XCTUnwrap(delegate.pickerPresentation).status.contains(Strings.libraryUnavailable))
    }

    func testNonDirectoryLibraryDegradesWithoutNativeLaunchOrCreation() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Not a directory".utf8).write(to: root)
        let picker = try open()
        XCTAssertFalse(picker.libraryAvailable)
        picker.setQuery("New prompt")
        try XCTUnwrap(delegate.pickerPresentation).createNoMatch()
        XCTAssertTrue(launched.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root), Data("Not a directory".utf8))
    }

    func testToggleDismissesOnlyVisibleKeyPanelAndRefocusesReusedSearch() throws {
        let picker = try open()
        let panel = try currentPanel()
        XCTAssertTrue(controller.isActiveAndVisible)
        delegate.togglePicker()
        XCTAssertEqual(picker.state, .closed)
        XCTAssertFalse(controller.isVisible)
        delegate.togglePicker()
        XCTAssertEqual(picker.state, .picker)
        let query = try XCTUnwrap(find("picker-query") as? PickerTextField)
        XCTAssertTrue(spin { self.isFocused(query, in: panel) })

        panel.resignKey()
        XCTAssertFalse(controller.isActiveAndVisible)
        XCTAssertTrue(controller.isVisible)
        delegate.togglePicker()
        XCTAssertEqual(picker.state, .picker)
        XCTAssertTrue(spin { self.controller.isActiveAndVisible && self.isFocused(query, in: panel) })
    }

    func testBlurDismissesFillAndKeepsDraft() throws {
        try files.write(Data("{{topic}}".utf8), at: "fields.md")
        let picker = try open()
        picker.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        fill.setValue("Draft", name: "topic")
        let panel = try currentPanel()
        panel.resignKey()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        XCTAssertTrue(spin { picker.state == .closed })
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(fill.state, .closed)
        picker.open()
        picker.use(mode: .copyOnly)
        XCTAssertEqual(picker.fillModel?.values["topic"], "Draft")
    }

    func testDescriptionsNativeFocusAndLivePreviewForAllFieldKinds() throws {
        let source = """
        ---
        fields:
          topic: {label: Topic, description: Describe the topic, default: Swift}
          detail: {type: multiline, description: Add details, default: One line}
          language:
            type: choice
            description: Choose a language
            options: [{label: English, value: en}, {label: French, value: fr}]
            default: en
          plain: {optional: true}
          empty: {optional: true, description: ""}
        ---
        {{topic}}: {{detail}} ({{language}}){{plain}}{{empty}}
        """
        try files.write(Data(source.utf8), at: "fields.md")
        let picker = try open()
        picker.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { self.find("fill-field-language") != nil })
        for (name, text) in [("topic", "Describe the topic"), ("detail", "Add details"), ("language", "Choose a language")] {
            let label = try XCTUnwrap(find("fill-description-" + name) as? NSTextField)
            XCTAssertEqual(label.stringValue, text)
            XCTAssertFalse(label.isHiddenOrHasHiddenAncestor)
        }
        XCTAssertNil(find("fill-description-plain"))
        XCTAssertNil(find("fill-description-empty"))
        let topic = try XCTUnwrap(find("fill-field-topic") as? PickerTextField)
        let detail = try XCTUnwrap(find("fill-field-detail") as? PickerMultilineTextView)
        let language = try XCTUnwrap(find("fill-field-language") as? PickerChoiceButton)
        let panel = try currentPanel()
        XCTAssertTrue(spin { self.isFocused(topic, in: panel) })
        topic.stringValue = "Rust"
        topic.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: topic))
        detail.string = "Line one\nLine two"
        detail.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: detail))
        language.selectItem(at: 2)
        if let action = language.action { NSApp.sendAction(action, to: language.target, from: language) }
        XCTAssertEqual(fill.values["topic"], "Rust")
        XCTAssertEqual(fill.values["detail"], "Line one\nLine two")
        XCTAssertEqual(fill.values["language"], "fr")
        XCTAssertEqual(fill.preview, .rendered("Rust: Line one\nLine two (fr)"))
        XCTAssertTrue(spin { self.find("fill-field-topic") === topic })
        panel.makeFirstResponder(language)
        XCTAssertEqual(fill.focusIndex, 2)
        fill.focusNext()
        XCTAssertTrue(spin {
            guard let plain = self.find("fill-field-plain") as? NSTextField else { return false }
            return self.isFocused(plain, in: panel)
        })
        fill.focusField(at: 1)
        XCTAssertTrue(spin { panel.firstResponder === detail })
        XCTAssertEqual(PanelController.focusedFieldKind(in: panel), .multiline)
        picker.escape()
        XCTAssertEqual(picker.state, .picker)
        XCTAssertTrue(spin {
            guard let query = self.find("picker-query") as? PickerTextField else { return false }
            return self.isFocused(query, in: panel)
        })
        picker.use(mode: .copyOnly)
        XCTAssertEqual(picker.fillModel?.values, fill.values)
    }

    func testLocalKeyMonitorRoutesFieldEditorAndCommandWClosesFill() throws {
        try files.write(Data("{{topic}} {{detail}}".utf8), at: "fields.md")
        let picker = try open()
        let panel = try currentPanel()
        try sendKey(code: 36, characters: "\r", modifiers: .option, to: panel)
        XCTAssertEqual(picker.state, .fill)
        XCTAssertEqual(picker.fillModel?.preferredMode, .copyOnly)
        XCTAssertTrue(spin {
            guard let field = self.find("fill-field-topic") as? PickerTextField else { return false }
            return self.isFocused(field, in: panel)
        })
        XCTAssertEqual(PanelController.focusedFieldKind(in: panel), .text)
        try sendKey(code: 48, characters: "\t", to: panel)
        XCTAssertEqual(picker.fillModel?.focusIndex, 1)
        try sendKey(code: 53, characters: "\u{1b}", to: panel)
        XCTAssertEqual(picker.state, .picker)
        picker.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        fill.setValue("Draft", name: "topic")
        let close = try keyEvent(code: 13, characters: "w", modifiers: .command, to: panel)
        XCTAssertTrue(panel.performKeyEquivalent(with: close))
        XCTAssertEqual(picker.state, .closed)
        XCTAssertFalse(controller.isVisible)
        picker.open()
        picker.use(mode: .copyOnly)
        XCTAssertEqual(picker.fillModel?.values["topic"], "Draft")
    }

    func testMultilineReturnReachesNativeTextViewThroughLocalMonitor() throws {
        try files.write(Data("---\nfields:\n  detail: {type: multiline, default: First}\n---\n{{detail}}".utf8), at: "multiline.md")
        let picker = try open()
        picker.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        let panel = try currentPanel()
        XCTAssertTrue(spin {
            guard let detail = self.find("fill-field-detail") else { return false }
            return panel.firstResponder === detail
        })
        let detail = try XCTUnwrap(find("fill-field-detail") as? PickerMultilineTextView)
        detail.setSelectedRange(NSRange(location: detail.string.utf16.count, length: 0))
        try sendKey(code: 36, characters: "\r", to: panel)
        XCTAssertEqual(picker.state, .fill)
        XCTAssertEqual(fill.values["detail"], "First\n")
        XCTAssertEqual(fill.preview, .rendered("First\n"))
    }

    func testMultilineTypingCanBeUndoneWithCommandZ() throws {
        // Injected test graphs skip the application's main menu. Supply its
        // Undo item so Command-Z follows the native responder chain.
        let originalMenu = NSApp.mainMenu
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu()
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        defer { NSApp.mainMenu = originalMenu }
        try files.write(Data("---\nfields:\n  detail: {type: multiline, default: First}\n---\n{{detail}}".utf8), at: "multiline.md")
        let picker = try open()
        picker.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        let panel = try currentPanel()
        XCTAssertTrue(spin {
            guard let detail = self.find("fill-field-detail") else { return false }
            return panel.firstResponder === detail
        })
        let detail = try XCTUnwrap(find("fill-field-detail") as? PickerMultilineTextView)
        XCTAssertTrue(detail.allowsUndo)
        detail.setSelectedRange(NSRange(location: detail.string.utf16.count, length: 0))
        try sendKey(code: UInt16(kVK_ANSI_X), characters: "x", to: panel)
        XCTAssertEqual(detail.string, "Firstx")
        XCTAssertEqual(fill.values["detail"], "Firstx")
        detail.breakUndoCoalescing()
        try sendKey(code: UInt16(kVK_ANSI_Z), characters: "z", modifiers: .command, to: panel)
        XCTAssertTrue(spin { detail.string == "First" && fill.values["detail"] == "First" })
        XCTAssertEqual(picker.state, .fill)
        XCTAssertEqual(fill.preview, .rendered("First"))
    }

    func testSearchMarkedTextKeepsReturnAndEscapeOutOfPickerRouting() throws {
        try files.write(Data("---\ntitle: かな\n---\nBody".utf8), at: "search.md")
        let picker = try open()
        let panel = try currentPanel()
        let query = try XCTUnwrap(find("picker-query") as? PickerTextField)
        XCTAssertTrue(spin { self.isFocused(query, in: panel) })
        let editor = try XCTUnwrap(query.currentEditor() as? NSTextView)
        var routedKeys = 0
        let route = controller.onKey
        controller.onKey = { event, kind in
            routedKeys += 1
            return route?(event, kind) ?? false
        }
        // Hosted tests have no real input method. AppKit then turns the passed
        // Escape into cancelOperation:, which a composing IME would consume.
        // Isolate the monitor's decision from that test-only fallback.
        let escape = controller.onEscape
        let cancel = controller.onCancel
        controller.onEscape = {}
        controller.onCancel = {}
        defer {
            controller.onEscape = escape
            controller.onCancel = cancel
        }

        for (code, characters): (UInt16, String) in [(36, "\r"), (53, "\u{1b}")] {
            // Keep a matching selection when starting the next composition
            // after Return has committed the previous one.
            editor.unmarkText()
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertNotNil(picker.selectionIndex)
            try sendKey(code: code, characters: characters, to: panel)
            XCTAssertEqual(routedKeys, 0)
            XCTAssertEqual(picker.state, .picker)
            XCTAssertFalse(picker.isResolvingBuiltins)
            XCTAssertTrue(controller.isVisible)
        }
        editor.unmarkText()
    }

    func testFillMarkedTextKeepsDeliveryAndEscapeOutOfTextRouting() throws {
        try files.write(Data("---\nfields:\n  topic: {default: Topic}\n  detail: {type: multiline, default: Detail}\n---\n{{topic}} {{detail}}".utf8), at: "fields.md")
        let picker = try open()
        picker.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        let panel = try currentPanel()
        XCTAssertTrue(spin { fill.deliverEnabled && self.find("fill-field-detail") != nil })
        var routedKeys = 0
        let route = controller.onKey
        controller.onKey = { event, kind in
            routedKeys += 1
            return route?(event, kind) ?? false
        }
        // Hosted tests have no real input method. AppKit then turns the passed
        // Escape into cancelOperation:, which a composing IME would consume.
        // Isolate the monitor's decision from that test-only fallback.
        let escape = controller.onEscape
        let cancel = controller.onCancel
        controller.onEscape = {}
        controller.onCancel = {}
        defer {
            controller.onEscape = escape
            controller.onCancel = cancel
        }

        for (position, name) in ["topic", "detail"].enumerated() {
            fill.focusField(at: position)
            let input = try XCTUnwrap(find("fill-field-" + name))
            XCTAssertTrue(spin {
                if let field = input as? NSTextField { return self.isFocused(field, in: panel) }
                return panel.firstResponder === input
            })
            let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
            for (code, characters): (UInt16, String) in [(36, "\r"), (53, "\u{1b}")] {
                editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
                editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertTrue(editor.hasMarkedText())
                let modifiers: NSEvent.ModifierFlags = name == "detail" && code == 36 ? .command : []
                try sendKey(code: code, characters: characters, modifiers: modifiers, to: panel)
                XCTAssertEqual(routedKeys, 0)
                XCTAssertEqual(picker.state, .fill)
                XCTAssertEqual(fill.state, .editing)
                XCTAssertTrue(controller.isVisible)
                editor.unmarkText()
            }
        }
    }

    func testSpaceOnFocusedUseButtonKeepsNativeFocusAndQuery() throws {
        try files.write(Data("Body".utf8), at: "Alpha.md")
        let picker = try open()
        let panel = try currentPanel()
        let query = try XCTUnwrap(find("picker-query") as? PickerTextField)
        XCTAssertTrue(spin { self.isFocused(query, in: panel) })
        picker.setQuery("Al")
        XCTAssertTrue(spin { query.stringValue == "Al" })
        // Hosted runners need not enable Full Keyboard Access. This native Use
        // button accepts focus explicitly and records the native key path.
        let button = PickerKeyboardButton(title: Strings.usePrompt, target: nil, action: nil)
        panel.contentView?.addSubview(button)
        XCTAssertTrue(panel.makeFirstResponder(button))
        try sendKey(code: 49, characters: " ", to: panel)
        XCTAssertTrue(panel.firstResponder === button)
        XCTAssertEqual(button.keysReceived, 1)
        XCTAssertEqual(picker.query, "Al")
        XCTAssertEqual(query.stringValue, "Al")
    }

    func testHandledIntentDoesNotRepeatOrBlockLaterPublication() throws {
        let picker = try open()
        var intents: [PickerModel.Intent] = []
        var publications = 0
        let presentation = PickerViewState(model: picker, mainThread: DispatchMainThread(),
            requestedIntent: {
                XCTAssertGreaterThan(publications, 0, "Publish before handling an intent that keeps the panel open")
                intents.append($0)
            }, createPrompt: { _ in })
        let subscription = presentation.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        picker.openLibrary() // This handler deliberately leaves the panel open.
        XCTAssertGreaterThan(publications, 0)
        picker.setQuery("new query")
        XCTAssertEqual(intents, [.openLibrary])
        XCTAssertNil(picker.requestedIntent)
        XCTAssertEqual(presentation.state, .picker)
        XCTAssertGreaterThan(publications, 0)
    }

    func testObsoleteChoiceValueExplicitlyDeselectsPreviouslySelectedItem() throws {
        try files.write(Data("---\nfields:\n  language: {type: choice, options: [Rust, Swift], default: Rust}\n---\n{{language}}".utf8), at: "choice.md")
        let picker = try open()
        picker.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { self.find("fill-field-language") != nil })
        let choice = try XCTUnwrap(find("fill-field-language") as? PickerChoiceButton)
        XCTAssertEqual(choice.selectedItem?.representedObject as? String, "Rust")
        fill.setValue("Java", name: "language")
        XCTAssertTrue(spin { choice.selectedItem == nil })
        XCTAssertEqual(fill.values["language"], "Java")
        XCTAssertFalse(fill.deliverEnabled)
    }

    func testTypingAfterNativeResultFocusContinuesSearch() throws {
        try files.write(Data("Body".utf8), at: "Alpha.md")
        try files.write(Data("Body".utf8), at: "Beta.md")
        let picker = try open()
        let panel = try currentPanel()
        let query = try XCTUnwrap(find("picker-query") as? PickerTextField)
        XCTAssertTrue(spin { self.isFocused(query, in: panel) })
        picker.setQuery("a")
        XCTAssertTrue(spin { query.stringValue == "a" })
        picker.selectResult(at: 1)
        // A native list/preview can own focus without being a text input.
        // This responder records keys that would otherwise dead-end there.
        let sink = PickerKeyboardSink(frame: .zero)
        panel.contentView?.addSubview(sink)
        XCTAssertTrue(panel.makeFirstResponder(sink))
        XCTAssertTrue(panel.firstResponder === sink)
        try sendKey(code: 37, characters: "l", to: panel)
        XCTAssertEqual(picker.query, "al")
        XCTAssertEqual(picker.results.map(\.title), ["Alpha"])
        XCTAssertEqual(sink.keysReceived, 0)
        XCTAssertTrue(isFocused(query, in: panel))

        XCTAssertTrue(panel.makeFirstResponder(sink))
        let command = try keyEvent(code: 0, characters: "a", modifiers: .command, to: panel)
        XCTAssertFalse(controller.forwardTypingToSearch(command))
        let tab = try keyEvent(code: 48, characters: "\t", modifiers: [], to: panel)
        XCTAssertFalse(controller.forwardTypingToSearch(tab))
        XCTAssertTrue(panel.firstResponder === sink)
        XCTAssertEqual(picker.query, "al")
    }

    func testPendingFocusRetriesWhenNativeWindowBecomesKey() throws {
        _ = try open()
        let panel = try currentPanel()
        let query = try XCTUnwrap(find("picker-query") as? PickerTextField)
        XCTAssertTrue(spin { self.isFocused(query, in: panel) })
        let sink = PickerKeyboardSink(frame: .zero)
        panel.contentView?.addSubview(sink)
        XCTAssertTrue(panel.makeFirstResponder(sink))
        panel.resignKey()
        XCTAssertFalse(panel.isKeyWindow)
        query.pickerFocus.update(view: query, wantsFocus: true, revision: 999)
        pump(for: 0.02) // Run the deferred focus attempt while the panel is non-key.
        XCTAssertTrue(panel.firstResponder === sink)
        panel.makeKey() // No controller show or SwiftUI revision to retry it.
        XCTAssertTrue(spin { self.isFocused(query, in: panel) })
    }

    func testRemovingViewCancelsPendingFocusBeforeWindowBecomesKey() throws {
        _ = try open()
        let panel = try currentPanel()
        let query = try XCTUnwrap(find("picker-query") as? PickerTextField)
        XCTAssertTrue(spin { self.isFocused(query, in: panel) })
        let field = PickerTextField(string: "Detached field")
        let sink = PickerKeyboardSink(frame: .zero)
        panel.contentView?.addSubview(field)
        panel.contentView?.addSubview(sink)
        XCTAssertTrue(panel.makeFirstResponder(sink))
        panel.resignKey()
        field.pickerFocus.update(view: field, wantsFocus: true, revision: 1)
        pump(for: 0.02)
        field.removeFromSuperview()
        panel.contentView?.addSubview(field)
        panel.makeKey()
        pump(for: 0.02)
        XCTAssertTrue(panel.firstResponder === sink)
    }

    func testNoLongerWantedFocusCancelsPendingRetry() throws {
        _ = try open()
        let panel = try currentPanel()
        let query = try XCTUnwrap(find("picker-query") as? PickerTextField)
        XCTAssertTrue(spin { self.isFocused(query, in: panel) })
        let sink = PickerKeyboardSink(frame: .zero)
        panel.contentView?.addSubview(sink)
        XCTAssertTrue(panel.makeFirstResponder(sink))
        panel.resignKey()
        query.pickerFocus.update(view: query, wantsFocus: true, revision: 999)
        pump(for: 0.02)
        query.pickerFocus.update(view: query, wantsFocus: false, revision: 999)
        panel.makeKey()
        pump(for: 0.02)
        XCTAssertTrue(panel.firstResponder === sink)
    }

    func testTransientStatusClearsOnQueryAndReopen() throws {
        let picker = try open()
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.showStatus(Strings.createPromptFailed)
        XCTAssertEqual(presentation.status, Strings.createPromptFailed)
        presentation.setQuery("New prompt")
        XCTAssertEqual(presentation.status, "")
        presentation.showStatus(Strings.createPromptFailed)
        picker.dismiss()
        picker.open()
        XCTAssertEqual(presentation.status, "")
        XCTAssertEqual(picker.query, "New prompt")
    }

    func testPasteTargetNameUsesCapturedPIDAndRejectsMismatchedIdentity() {
        let app = NSRunningApplication.current
        XCTAssertEqual(AppDelegate.pasteTargetName(for: .macOS(processID: app.processIdentifier,
            bundleID: app.bundleIdentifier)), app.localizedName ?? Strings.noPasteTarget)
        XCTAssertEqual(AppDelegate.pasteTargetName(for: nil), Strings.noPasteTarget)
        XCTAssertEqual(AppDelegate.pasteTargetName(for: .macOS(processID: app.processIdentifier,
            bundleID: "wrong.bundle")), Strings.noPasteTarget)
    }

    private func currentPanel() throws -> PromptPanel {
        try XCTUnwrap(NSApp.windows.compactMap { $0 as? PromptPanel }.first {
            !originalWindows.contains(ObjectIdentifier($0))
        })
    }

    private func isFocused(_ field: NSTextField, in panel: NSWindow) -> Bool {
        guard let editor = field.currentEditor() else { return false }
        return panel.firstResponder === editor
    }

    private func find(_ identifier: String) -> NSView? {
        func walk(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            for child in view.subviews { if let found = walk(child) { return found } }
            return nil
        }
        return (try? currentPanel()).flatMap { $0.contentView }.flatMap(walk)
    }

    private func spin(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        spin(until: ProcessInfo.processInfo.systemUptime + timeout, condition)
    }

    private func spin(until deadline: TimeInterval, _ condition: () -> Bool) -> Bool {
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return false
    }

    private func pump(for duration: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        _ = spin(until: deadline) { ProcessInfo.processInfo.systemUptime >= deadline }
    }

    private func sendKey(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [],
                         to panel: PromptPanel) throws {
        NSApp.sendEvent(try keyEvent(code: code, characters: characters, modifiers: modifiers, to: panel))
    }

    private func keyEvent(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags,
                          to panel: PromptPanel) throws -> NSEvent {
        if !panel.isKeyWindow { panel.makeKey() }
        let becameKey = spin { panel.isKeyWindow }
        _ = try XCTUnwrap(becameKey ? panel : nil, "Picker panel could not become key before a test key event")

        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}

private final class PickerKeyboardSink: NSView {
    private(set) var keysReceived = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keysReceived += 1 }
}

private final class PickerKeyboardButton: NSButton {
    private(set) var keysReceived = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keysReceived += 1 }
}

private struct BackgroundPickerScheduler: MonkeysPawCore.Scheduler {
    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay.timeInterval, execute: work)
    }
}

private final class ObservedPickerScheduler: MonkeysPawCore.Scheduler {
    private let lock = NSLock()
    private var observed = false
    var sawDebounce: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        if delay == Limits.watchDebounce {
            lock.lock()
            observed = true
            lock.unlock()
        }
        DispatchScheduler().after(delay, work)
    }
}
