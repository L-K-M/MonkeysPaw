import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

/// Renders the app's windows, sheets and menus for design review.
///
/// CI sets `TEST_RUNNER_MONKEYSPAW_UI_TOUR_DIR`; xcodebuild strips the prefix
/// and the tour writes PNGs plus `menus.txt` and `windows.txt` there. Ordinary
/// test runs skip it. Each state is the window server's composited image of
/// the window, or AppKit's cached display when that is unavailable.
final class MacUITourTests: XCTestCase {
    private static let directoryKey = "MONKEYSPAW_UI_TOUR_DIR"
    private static let settleTime: TimeInterval = 0.8

    private var output: URL!
    private var directory: URL!
    private var delegate: AppDelegate!
    private var originalWindows: Set<ObjectIdentifier> = []
    private var originalMenu: NSMenu?
    private var originalAppearance: NSAppearance?
    private var windowNotes: [String] = []
    private var statusItem: NSStatusItem?

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment[Self.directoryKey], !path.isEmpty else {
            throw XCTSkip("Set \(Self.directoryKey) to render the UI tour")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        originalMenu = NSApp.mainMenu
        originalAppearance = NSApp.appearance
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        statusItem?.menu?.cancelTracking()
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        delegate?.pickerModel?.dismiss()
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate = nil
        NSApp.mainMenu = originalMenu
        NSApp.appearance = originalAppearance
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testRenderTour() throws {
        defer {
            do {
                try windowNotes.joined(separator: "\n").write(to: output.appendingPathComponent("windows.txt"),
                    atomically: true, encoding: .utf8)
            } catch { XCTFail("The render tour could not write its window evidence") }
        }
        try start()

        tourOnboarding()
        tourLibrary(appearance: "light")
        try tourFieldSettings(appearance: "light")
        tourSettings(appearance: "light")
        tourPicker(appearance: "light")
        try tourStatusItem(appearance: "light")

        NSApp.appearance = NSAppearance(named: .darkAqua)
        settle()
        tourLibrary(appearance: "dark")
        try tourFieldSettings(appearance: "dark")
        tourSettings(appearance: "dark")
        tourPicker(appearance: "dark")
        try tourStatusItem(appearance: "dark")

    }

    // MARK: - Composition

    private func start() throws {
        let root = directory.appendingPathComponent("library", isDirectory: true)
        let data = directory.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try copySeeds(to: root)
        delegate = AppDelegate(libraryRoot: root, dataRoot: data,
            launchURI: { _ in }, revealLibrary: { _ in },
            makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in true }),
                    mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.installMainMenu()
        settle()
        try describeMenus()
    }

    /// The repository's starter prompts give every view realistic content.
    private func copySeeds(to root: URL) throws {
        let seeds = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("seed", isDirectory: true)
        let manager = FileManager.default
        for name in try manager.contentsOfDirectory(atPath: seeds.path) where name != "README.md" {
            try manager.copyItem(at: seeds.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
    }

    // MARK: - Tours

    private func tourOnboarding() {
        delegate.beginOnboarding()
        settle()
        captureVisibleWindows(prefix: "onboarding-1")
        for window in newVisibleWindows() { window.performClose(nil) }
        settle()
        captureVisibleWindows(prefix: "onboarding-2")
        for window in newVisibleWindows() { window.performClose(nil) }
        settle()
    }

    private func tourLibrary(appearance: String) {
        delegate.showLibrary()
        settle()
        guard let controller = delegate.libraryWindow, let window = controller.window else {
            windowNotes.append("library: no window")
            return
        }
        let presentation = controller.presentation
        window.setContentSize(NSSize(width: 1180, height: 720))
        capture(window, as: "library-\(appearance)-initial")
        capture(window, as: "library-\(appearance)-toolbar")

        if let row = presentation.snapshot.rows.first(where: { $0.title.hasPrefix("Review") })
            ?? presentation.snapshot.rows.first {
            presentation.selectPath(row.relativePath)
        }
        settle()
        presentation.editorMode = .edit
        settle()
        capture(window, as: "library-\(appearance)-edit")
        presentation.setInspectorVisible(false)
        presentation.editorMode = .preview
        settle()
        capture(window, as: "library-\(appearance)-preview")
        presentation.showInspector(.fields)
        settle()
        capture(window, as: "library-\(appearance)-fields")
        presentation.showInspector(.history)
        settle()
        capture(window, as: "library-\(appearance)-history")
        presentation.editorMode = .edit
        presentation.setInspectorVisible(false)
        settle()

        if let section = presentation.snapshot.sections.first(where: {
            if case .folder = $0.id { return true }
            return false
        }) {
            presentation.selectSection(section.id)
            settle()
            capture(window, as: "library-\(appearance)-folder")
            presentation.selectSection(.all)
            settle()
        }

        presentation.setFilter("zzzz-no-match")
        settle()
        capture(window, as: "library-\(appearance)-filter-empty")
        presentation.setFilter("")
        settle()

        if presentation.canShowAssistant {
            presentation.showInspector(.assistant)
            settle()
            capture(window, as: "library-\(appearance)-assistant")
            presentation.closeAssistant()
            settle()
        }

        if let source = presentation.editorState.source {
            presentation.edit(source + "\nA draft line.\n")
            settle()
            capture(window, as: "library-\(appearance)-dirty")
            controller.requestClose()
            settle()
            captureSheet(of: window, as: "library-\(appearance)-unsaved-sheet")
            endSheet(of: window)
            presentation.revert()
            settle()
            captureSheet(of: window, as: "library-\(appearance)-revert-sheet")
            endSheet(of: window)
        }

        presentation.requestFileCommand(.rename)
        settle()
        captureSheet(of: window, as: "library-\(appearance)-rename-sheet")
        endSheet(of: window)
        presentation.requestFileCommand(.move)
        settle()
        captureSheet(of: window, as: "library-\(appearance)-move-sheet")
        endSheet(of: window)
        presentation.requestFileCommand(.delete)
        settle()
        captureSheet(of: window, as: "library-\(appearance)-delete-sheet")
        endSheet(of: window)
        tourDiskConflicts(controller, window: window, appearance: appearance)
        settle()
        describe(window, as: "library")
    }

    private func tourDiskConflicts(_ controller: LibraryWindowController, window: NSWindow, appearance: String) {
        let presentation = controller.presentation
        guard let prompt = presentation.editorState.prompt, let source = presentation.editorState.source else { return }
        let file = URL(fileURLWithPath: presentation.activeLibraryPath, isDirectory: true)
            .appendingPathComponent(prompt.relativePath.string)
        // These are copied tour seeds in a temporary library, never owner files.
        do {
            presentation.edit(source + "\nA local draft.\n")
            try Data((source + "\nAn external change.\n").utf8).write(to: file)
            presentation.save()
            settle()
            captureSheet(of: window, as: "library-\(appearance)-modified-on-disk-sheet")
            endSheet(of: window)
            presentation.editor.resolveConflict(.takeTheirs)
            settle()
            guard let latest = presentation.editorState.source else { return }
            presentation.edit(latest + "\nA draft after deletion.\n")
            try FileManager.default.removeItem(at: file)
            presentation.save()
            settle()
            captureSheet(of: window, as: "library-\(appearance)-deleted-on-disk-sheet")
            endSheet(of: window)
            presentation.editor.resolveConflict(.keepMine)
            settle()
        } catch {
            windowNotes.append("library-\(appearance): disk-conflict tour setup failed")
        }
    }

    private func tourSettings(appearance: String) {
        delegate.showSettings()
        settle()
        guard let controller = delegate.settingsWindow, let window = controller.window else {
            windowNotes.append("settings: no window")
            return
        }
        let tabs: [(SettingsViewState.Tab, String)] = [(.general, "general"), (.shortcuts, "shortcuts"),
            (.delivery, "delivery"), (.assistant, "assistant"), (.account, "account")]
        for (tab, name) in tabs {
            controller.presentation.selectedTab = tab
            settle()
            capture(window, as: "settings-\(appearance)-\(name)")
        }
        describe(window, as: "settings")
        window.performClose(nil)
        settle()
    }

    private func tourPicker(appearance: String) {
        guard let picker = delegate.pickerModel else { return }
        picker.open()
        settle()
        capturePanel(as: "picker-\(appearance)-open")
        delegate.pickerPresentation?.setQuery("rev")
        settle()
        capturePanel(as: "picker-\(appearance)-query")
        picker.use(mode: .paste(.standard))
        settle()
        capturePanel(as: "picker-\(appearance)-fill")
        picker.escape()
        settle()
        delegate.pickerPresentation?.setQuery("zzzz-no-match")
        settle()
        capturePanel(as: "picker-\(appearance)-no-match")
        picker.dismiss()
        settle()
    }

    /// The placeholder-settings sheet is a real attached window presented by
    /// the form. The tour drives it through production intents, records its
    /// accessibility tree and presses its own controls.
    private func tourFieldSettings(appearance: String) throws {
        guard let controller = delegate.libraryWindow, let window = controller.window else {
            windowNotes.append("field-settings-\(appearance): no library window")
            XCTFail("The tour's library window is not available")
            return
        }
        let presentation = controller.presentation
        presentation.editorMode = .edit
        presentation.selectPath("draft-a-prompt.md")
        settle()
        if let decision = presentation.editorState.pendingDecision {
            presentation.editor.resolveDecision(.save, id: decision.id)
            settle()
        }
        // "success" carries a declared default to inspect; "task" stays
        // implicit so toggling a default on writes a real declaration.
        let fieldName = appearance == "dark" ? "task" : "success"
        guard presentation.canEditFieldSettings, presentation.fieldSettingsDraft == nil,
              let field = presentation.editorState.form?.fieldSettings.first(where: { $0.name == fieldName }) else {
            windowNotes.append("field-settings-\(appearance): cannot request settings for \(fieldName)")
            XCTFail("The tour cannot open placeholder settings for \(fieldName)")
            return
        }
        presentation.requestFieldSettings(field)
        settle()
        let sheet = try XCTUnwrap(window.attachedSheet, "requestFieldSettings attaches a real sheet")
        XCTAssertTrue(sheet.sheetParent === window)
        capture(sheet, as: "library-\(appearance)-field-settings-sheet")
        describe(sheet, as: "field-settings-\(appearance)")
        let elements = describeAccessibility(of: sheet, as: "field-settings-\(appearance)")
        XCTAssertFalse(elements.isEmpty, "The settings sheet exposes no accessibility elements")

        let named = try XCTUnwrap(accessibilityElement(in: sheet, identifier: "library-field-name"))
        XCTAssertTrue(accessibilityText(named).contains(fieldName), "The sheet must name its field")
        let type = try XCTUnwrap(accessibilityElement(in: sheet, identifier: "library-field-type"))
        XCTAssertTrue(accessibilityText(type).contains(EditorStrings.fieldType),
            "The native type control must expose its name")
        if appearance != "dark" {
            let label = try XCTUnwrap(accessibilityElement(in: sheet, identifier: "library-field-label"))
            XCTAssertEqual(accessibility(label, Selector(("accessibilityValue"))), field.label)
        }
        let apply = try XCTUnwrap(accessibilityElement(in: sheet, identifier: "library-field-settings-apply"))
        let cancel = try XCTUnwrap(accessibilityElement(in: sheet, identifier: "library-field-settings-cancel"))
        // A control's accessible name can land in its title instead of its label.
        XCTAssertEqual(accessibility(apply, Selector(("accessibilityRole"))), "AXButton")
        XCTAssertTrue(accessibilityText(apply).contains(LibraryFieldStrings.apply))
        XCTAssertEqual(accessibility(cancel, Selector(("accessibilityRole"))), "AXButton")
        XCTAssertTrue(accessibilityText(cancel).contains(LibraryDialogStrings.cancel))

        if appearance == "dark" {
            let draft = try XCTUnwrap(presentation.fieldSettingsDraft)
            XCTAssertFalse(draft.hasDefault)
            let toggle = try XCTUnwrap(accessibilityElement(in: sheet, identifier: "library-field-default-toggle"))
            XCTAssertTrue(accessibilityPress(toggle), "The default toggle does not accept AXPress")
            settle()
            XCTAssertTrue(draft.hasDefault, "AXPress on the default toggle did not stage a default")
            let currentApply = try XCTUnwrap(accessibilityElement(in: sheet, identifier: "library-field-settings-apply"))
            XCTAssertTrue(accessibilityPress(currentApply), "Apply does not accept AXPress")
            settle()
            XCTAssertNil(presentation.fieldSettingsDraft)
            XCTAssertNil(window.attachedSheet)
            XCTAssertTrue(presentation.editorState.isDirty, "Applying a staged setting must dirty the draft")
            presentation.save()
            settle()
            XCTAssertFalse(presentation.editorState.isDirty, "The applied setting did not save")
        } else {
            XCTAssertTrue(accessibilityPress(cancel), "Cancel does not accept AXPress")
            settle()
            XCTAssertNil(presentation.fieldSettingsDraft)
            XCTAssertNil(window.attachedSheet)
            XCTAssertFalse(presentation.editorState.isDirty, "Cancel must leave the draft untouched")
        }
    }

    /// The real NSStatusItem assembled here once and reused for both passes.
    /// The button lives in a real status-bar window, so these captures are the
    /// live menu-bar rendering, not a synthetic MenuBarIcon draw. The
    /// system-owned menu-bar tint is out of the test's control; the button's
    /// appearance is forced to match the tour's window passes.
    private func tourStatusItem(appearance: String) throws {
        if statusItem == nil {
            // The isRunningTests launch guard keeps installStatusItem() off, so
            // the tour builds a real item through the same production seams.
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.image = delegate.makeStatusItemImage()
            statusItem?.menu = delegate.makeStatusMenu()
        }
        let item = try XCTUnwrap(statusItem, "the tour's live status item could not be created")
        let button = try XCTUnwrap(item.button, "The live status item exposes a real button")
        let named: NSAppearance.Name = appearance == "dark" ? .darkAqua : .aqua
        button.appearance = NSAppearance(named: named)
        settle()

        XCTAssertTrue(item.isVisible)
        let image = try XCTUnwrap(button.image, "The live status button carries the production image")
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(image.accessibilityDescription, AppIdentity.displayName)
        let buttonWindow = try XCTUnwrap(button.window, "The live status button is not attached to a window")
        let axName = button.accessibilityLabel() ?? ""
        windowNotes.append("status-item-\(appearance): live NSStatusBarButton window=\(type(of: buttonWindow)) "
            + "frame=\(NSStringFromRect(buttonWindow.frame)) level=\(buttonWindow.level.rawValue) "
            + "number=\(buttonWindow.windowNumber) visible=\(buttonWindow.isVisible) axName=\"\(axName)\" "
            + "effectiveAppearance=\(button.effectiveAppearance.name.rawValue)")
        XCTAssertFalse(axName.isEmpty, "The live status button needs an accessibility name")
        try windowNotes.joined(separator: "\n").write(to: output.appendingPathComponent("windows.txt"),
            atomically: true, encoding: .utf8)
        capture(buttonWindow, as: "status-item-\(appearance)")

        let shown = Set(NSApp.windows.filter { $0.isVisible }.map(ObjectIdentifier.init))
        // Menu tracking can block performClick; its run-loop timer owns capture and dismissal.
        let probe = Timer(timeInterval: Self.settleTime, repeats: false) { [weak self] _ in
            defer { item.menu?.cancelTracking() }
            guard let self else { return }
            let menus = NSApp.windows.filter { $0.isVisible && !shown.contains(ObjectIdentifier($0)) }
            if menus.isEmpty {
                self.windowNotes.append("status-menu-\(appearance): no tracking window exposed; menu capture unavailable")
            }
            for (index, menuWindow) in menus.enumerated() {
                menuWindow.appearance = NSAppearance(named: named)
                self.capture(menuWindow, as: "status-menu-\(appearance)-\(index)")
                self.describe(menuWindow, as: "status-menu-\(appearance)")
                self.windowNotes.append("status-menu-\(appearance)-\(index): class=\(type(of: menuWindow))")
            }
        }
        RunLoop.main.add(probe, forMode: .common)
        RunLoop.main.add(probe, forMode: .eventTracking)
        defer { probe.invalidate(); item.menu?.cancelTracking() }
        button.performClick(nil)
        settle()
        item.menu?.cancelTracking()
        settle()
        button.appearance = nil
    }

    // MARK: - Capture

    private func settle(_ seconds: TimeInterval = MacUITourTests.settleTime) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func newVisibleWindows() -> [NSWindow] {
        NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible && $0.sheetParent == nil }
    }

    private func captureVisibleWindows(prefix: String) {
        for (position, window) in newVisibleWindows().enumerated() {
            capture(window, as: "\(prefix)-\(position)")
            describe(window, as: prefix)
        }
    }

    private func capturePanel(as name: String) {
        guard let panel = NSApp.windows.first(where: {
            $0 is PromptPanel && $0.isVisible && !originalWindows.contains(ObjectIdentifier($0))
        }) else {
            windowNotes.append("\(name): no visible panel")
            XCTFail("The tour's picker is not visible: \(name)")
            return
        }
        XCTAssertFalse(originalWindows.contains(ObjectIdentifier(panel)), "Capture the tour's own panel: \(name)")
        capture(panel, as: name)
    }

    private func captureSheet(of window: NSWindow, as name: String) {
        guard let sheet = window.attachedSheet else {
            windowNotes.append("\(name): no sheet")
            return
        }
        capture(sheet, as: name)
    }

    private func endSheet(of window: NSWindow) {
        guard let sheet = window.attachedSheet else { return }
        window.endSheet(sheet, returnCode: .cancel)
        settle()
    }

    private func capture(_ window: NSWindow, as name: String) {
        window.displayIfNeeded()
        // The window server's composited image shows materials (sidebars,
        // inspectors, glass) that the view-hierarchy fallback cannot draw.
        if let image = Self.compositedImage(of: window) {
            write(NSBitmapImageRep(cgImage: image), as: name)
            return
        }
        windowNotes.append("\(name): composited capture unavailable; cached display used")
        // The theme frame includes the title bar and toolbar, not just content.
        let view = window.contentView?.superview ?? window.contentView
        if let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            write(rep, as: name)
        }
    }

    private func write(_ rep: NSBitmapImageRep, as name: String) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: output.appendingPathComponent(name + ".png"))
    }

    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Swift marks CGWindowListCreateImage obsoleted, but the window server
    /// still renders an app's own windows without a capture grant.
    private static func compositedImage(of window: NSWindow) -> CGImage? {
        guard let windowID = CGWindowID(exactly: window.windowNumber), windowID != 0,
              let library = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(library, "CGWindowListCreateImage") else { return nil }
        let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
        let options = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
        return function(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                        windowID, options)?.takeRetainedValue()
    }

    // MARK: - Accessibility

    /// In-process NSAccessibility reads only; CI grants no AX trust and these
    /// checks say nothing about VoiceOver. SwiftUI children can expose the
    /// selectors without adopting NSAccessibilityProtocol, so reads go through
    /// responds/perform as in the Settings tests.
    private func accessibilityElements(in root: NSObject, depth: Int = 14) -> [NSObject] {
        let children = #selector(NSAccessibilityProtocol.accessibilityChildren)
        guard depth > 0, root.responds(to: children),
              let descendants = root.perform(children)?.takeUnretainedValue() as? [Any] else { return [] }
        return descendants.flatMap { descendant -> [NSObject] in
            guard let node = descendant as? NSObject else { return [] }
            return [node] + accessibilityElements(in: node, depth: depth - 1)
        }
    }

    private func accessibility(_ element: NSObject, _ selector: Selector) -> String? {
        guard element.responds(to: selector),
              let value = element.perform(selector)?.takeUnretainedValue() else { return nil }
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let string = value as? NSAttributedString { return string.string.isEmpty ? nil : string.string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func accessibilityText(_ element: NSObject) -> String {
        [#selector(NSAccessibilityProtocol.accessibilityLabel),
         #selector(NSAccessibilityProtocol.accessibilityTitle),
         Selector(("accessibilityValue"))]
            .compactMap { accessibility(element, $0) }
            .joined(separator: " ")
    }

    /// Windows may expose their SwiftUI tree through the content view instead.
    private func accessibilityElements(under window: NSWindow) -> [NSObject] {
        let elements = accessibilityElements(in: window)
        if !elements.isEmpty { return elements }
        guard let contentView = window.contentView else { return [] }
        return accessibilityElements(in: contentView)
    }

    private func accessibilityElement(in window: NSWindow, identifier: String) -> NSObject? {
        // SwiftUI exposes the identifier selector without protocol conformance.
        accessibilityElements(under: window).first {
            accessibility($0, Selector(("accessibilityIdentifier"))) == identifier
        }
    }

    /// AXPress lands as the control's real action; its BOOL result is not read.
    private func accessibilityPress(_ element: NSObject) -> Bool {
        let press = Selector(("accessibilityPerformPress"))
        guard element.responds(to: press) else { return false }
        _ = element.perform(press)
        return true
    }

    private func describeAccessibility(of window: NSWindow, as name: String) -> [NSObject] {
        let elements = accessibilityElements(under: window)
        if elements.isEmpty {
            windowNotes.append("\(name): no accessibility elements")
            return elements
        }
        for (index, element) in elements.enumerated() {
            let parts = ["id=\(accessibility(element, Selector(("accessibilityIdentifier"))) ?? "-")",
                "role=\(accessibility(element, Selector(("accessibilityRole"))) ?? "-")",
                "label=\(accessibility(element, #selector(NSAccessibilityProtocol.accessibilityLabel)) ?? "-")",
                "value=\(accessibility(element, Selector(("accessibilityValue"))) ?? "-")"]
            windowNotes.append("\(name) ax[\(index)]: " + parts.joined(separator: " "))
        }
        return elements
    }

    // MARK: - Text descriptions

    private func describe(_ window: NSWindow, as name: String) {
        var parts = ["\(name): title=\"\(window.title)\" subtitle=\"\(window.subtitle)\"",
                     "frame=\(NSStringFromRect(window.frame))",
                     "screenVisible=\(window.screen.map { NSStringFromRect($0.visibleFrame) } ?? "none")",
                     "contentMin=\(NSStringFromSize(window.contentMinSize))",
                     "style=\(window.styleMask.rawValue)",
                     "restorable=\(window.isRestorable)",
                     "autosave=\"\(window.frameAutosaveName)\"",
                     "tabbing=\(window.tabbingMode.rawValue)",
                     "toolbar=\(window.toolbar.map { "\($0.items.map(\.itemIdentifier.rawValue))" } ?? "none")"]
        if let toolbar = window.toolbar { parts.append("toolbarStyle=\(window.toolbarStyle.rawValue) customizable=\(toolbar.allowsUserCustomization)") }
        windowNotes.append(parts.joined(separator: " "))
    }

    private func describeMenus() throws {
        var lines = ["# Main menu"]
        if let main = NSApp.mainMenu { lines += describe(main) }
        lines += ["", "# Status menu"]
        lines += describe(delegate.makeStatusMenu())
        try lines.joined(separator: "\n").write(to: output.appendingPathComponent("menus.txt"),
            atomically: true, encoding: .utf8)
    }

    private func describe(_ menu: NSMenu, depth: Int = 0) -> [String] {
        menu.update()
        let indent = String(repeating: "    ", count: depth)
        return menu.items.flatMap { item -> [String] in
            if item.isSeparatorItem { return [indent + "----"] }
            var line = indent + (item.title.isEmpty ? "(untitled)" : item.title)
            let key = shortcut(item)
            if !key.isEmpty { line += "  [" + key + "]" }
            if !item.isEnabled { line += "  (disabled)" }
            if item.isAlternate { line += "  (alternate)" }
            var lines = [line]
            if let submenu = item.submenu { lines += describe(submenu, depth: depth + 1) }
            return lines
        }
    }

    private func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let modifiers = item.keyEquivalentModifierMask
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch item.keyEquivalent {
        case "\r": return text + "↩"
        case "\u{1b}": return text + "⎋"
        case "\u{8}", "\u{7f}": return text + "⌫"
        case " ": return text + "Space"
        default: return text + item.keyEquivalent.uppercased()
        }
    }
}
