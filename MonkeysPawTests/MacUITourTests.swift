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
        delegate?.pickerModel?.dismiss()
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate = nil
        NSApp.mainMenu = originalMenu
        NSApp.appearance = originalAppearance
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testRenderTour() throws {
        try start()

        tourOnboarding()
        tourLibrary(appearance: "light")
        tourSettings(appearance: "light")
        tourPicker(appearance: "light")

        NSApp.appearance = NSAppearance(named: .darkAqua)
        settle()
        tourLibrary(appearance: "dark")
        tourSettings(appearance: "dark")
        tourPicker(appearance: "dark")

        try windowNotes.joined(separator: "\n").write(to: output.appendingPathComponent("windows.txt"),
            atomically: true, encoding: .utf8)
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
        guard let panel = NSApp.windows.first(where: { $0 is PromptPanel && $0.isVisible }) else {
            windowNotes.append("\(name): no visible panel")
            return
        }
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
        guard let library = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(library, "CGWindowListCreateImage") else { return nil }
        let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
        let options = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
        return function(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                        CGWindowID(window.windowNumber), options)?.takeRetainedValue()
    }

    // MARK: - Text descriptions

    private func describe(_ window: NSWindow, as name: String) {
        var parts = ["\(name): title=\"\(window.title)\" subtitle=\"\(window.subtitle)\"",
                     "frame=\(NSStringFromRect(window.frame))",
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
