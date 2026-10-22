import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class MacRepeatShortcutTests: XCTestCase {
    private var directory: URL!
    private var delegate: AppDelegate!
    private var backend: MacRepeatHotkeys!
    private var work: MacRepeatWork!
    private var scheduler: MacRepeatScheduler!
    private var originalWindows: Set<ObjectIdentifier> = []
    private var presentation: SettingsViewState { delegate.settingsWindow!.presentation }
    private var data: URL { directory.appendingPathComponent("data") }

    override func setUpWithError() throws {
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        work = MacRepeatWork()
        scheduler = MacRepeatScheduler()
        compose()
    }

    override func tearDown() {
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        work?.drain()
        scheduler?.drain()
        delegate = nil
        backend = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func compose() {
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        backend = MacRepeatHotkeys()
        let backend = self.backend!
        delegate = AppDelegate(libraryRoot: directory.appendingPathComponent("library"), dataRoot: data,
            launchURI: { _ in XCTFail("Unexpected launch") }, backgroundWork: work,
            httpTransport: MacRepeatNoHTTP(), clipboard: MacRepeatClipboard(),
            makeHotkeyBackend: { backend }, pasteInjectors: [],
            setActivationPolicy: { _ in }, activateApplication: {},
            makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in
                    XCTFail("No captured app in shortcut settings tests"); return false
                }), mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            },
            makeFileWatcher: { _, _ in MacRepeatWatcher() })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertTrue(backend.requested.isEmpty, "Hosted launch must not register even an injected backend")
        delegate.startShortcuts()
    }

    func testLiveRepeatBindingClearAndBothChoicesSurviveRestart() throws {
        XCTAssertEqual(presentation.repeatLast.binding, .unbound)
        XCTAssertFalse(presentation.canVerifyShortcut(.repeatLast))
        XCTAssertFalse(presentation.canClearShortcut(.repeatLast))
        let picker = try XCTUnwrap(presentation.togglePicker.registration)
        presentation.setAccelerator("Ctrl+Alt+R", for: .repeatLast)
        XCTAssertEqual(presentation.repeatLast.binding, .accelerator(try Accelerator("Ctrl+Alt+R")))
        XCTAssertTrue(presentation.canClearShortcut(.repeatLast))
        XCTAssertEqual(presentation.togglePicker.registration, picker)
        XCTAssertEqual(presentation.repeatLast.verification, .notStarted)

        compose()
        XCTAssertEqual(presentation.repeatLast.binding, .accelerator(try Accelerator("Ctrl+Alt+R")))
        XCTAssertEqual(presentation.togglePicker.binding, .accelerator(try Accelerator("Ctrl+Alt+P")))
        let reboundPicker = presentation.togglePicker.registration
        presentation.clearShortcut(.repeatLast)
        XCTAssertEqual(presentation.repeatLast.binding, .unbound)
        XCTAssertEqual(presentation.togglePicker.registration, reboundPicker)
        compose()
        XCTAssertEqual(presentation.repeatLast.binding, .unbound)
        presentation.clearShortcut(.togglePicker)
        compose()
        XCTAssertEqual(presentation.togglePicker.binding, .unbound)
        XCTAssertEqual(presentation.repeatLast.binding, .unbound)
    }

    func testRepeatCollisionAndNativeFailureKeepPreviousIndependentBindings() throws {
        presentation.setAccelerator("Ctrl+Alt+R", for: .repeatLast)
        let picker = presentation.togglePicker.registration
        let repeatRegistration = presentation.repeatLast.registration
        let requests = backend.requested.count
        presentation.setAccelerator("Ctrl+Alt+P", for: .repeatLast)
        XCTAssertEqual(presentation.shortcutsModel.error(for: .repeatLast), .collision(.togglePicker))
        XCTAssertNotNil(presentation.displayedShortcutError(for: .repeatLast))
        XCTAssertNil(presentation.displayedShortcutError)
        XCTAssertEqual(backend.requested.count, requests)
        XCTAssertEqual(presentation.repeatLast.registration, repeatRegistration)
        XCTAssertEqual(presentation.togglePicker.registration, picker)

        backend.nextStatus = .failed
        presentation.setAccelerator("Ctrl+Alt+K", for: .repeatLast)
        XCTAssertEqual(presentation.shortcutsModel.error(for: .repeatLast), .registrationFailed)
        XCTAssertEqual(presentation.repeatLast.binding, .accelerator(try Accelerator("Ctrl+Alt+R")))
        XCTAssertEqual(presentation.togglePicker.registration, picker)
        compose()
        XCTAssertEqual(presentation.repeatLast.binding, .accelerator(try Accelerator("Ctrl+Alt+R")))
    }

    func testSaveFailureRollsBackRepeatRebindAndClearWithoutLosingPicker() throws {
        presentation.setAccelerator("Ctrl+Alt+R", for: .repeatLast)
        for clear in [false, true] {
            let picker = presentation.togglePicker.registration
            let settings = data.appendingPathComponent("settings.json")
            let saved = data.appendingPathComponent("saved-settings.json")
            backend.onRegister = { [weak self] action, _ in
                guard action == .repeatLast else { return }
                self?.backend.onRegister = nil
                do {
                    try FileManager.default.moveItem(at: settings, to: saved)
                    try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
                } catch { XCTFail("Cannot install isolated save failure") }
            }
            if clear { presentation.clearShortcut(.repeatLast) }
            else { presentation.setAccelerator("Ctrl+Alt+K", for: .repeatLast) }
            guard case .saveFailed = presentation.shortcutsModel.error(for: .repeatLast) else {
                return XCTFail("Expected visible persistence failure")
            }
            XCTAssertEqual(presentation.repeatLast.binding, .accelerator(try Accelerator("Ctrl+Alt+R")))
            XCTAssertEqual(presentation.togglePicker.registration, picker)
            try FileManager.default.removeItem(at: settings)
            try FileManager.default.moveItem(at: saved, to: settings)
            compose()
            XCTAssertEqual(presentation.repeatLast.binding, .accelerator(try Accelerator("Ctrl+Alt+R")))
        }
    }

    func testOnlyDistinctBackendEventsVerifyAndMenuNeverVerifiesRepeat() throws {
        presentation.setAccelerator("Ctrl+Alt+R", for: .repeatLast)
        presentation.beginVerification(.togglePicker)
        presentation.beginVerification(.repeatLast)
        presentation.refresh()
        XCTAssertEqual(presentation.togglePicker.verification, .waiting)
        XCTAssertEqual(presentation.repeatLast.verification, .waiting)
        let repeatMenu = try XCTUnwrap(delegate.makeStatusMenu().items.first { $0.title == Strings.repeatLast })
        XCTAssertEqual(repeatMenu.keyEquivalent, "r", "The confirmed global binding is displayed")
        XCTAssertEqual(repeatMenu.keyEquivalentModifierMask, [.control, .option])
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(repeatMenu.action), to: repeatMenu.target, from: repeatMenu))
        work.drain()
        XCTAssertEqual(presentation.repeatLast.verification, .waiting)
        delegate.repeatWindow?.window?.close()
        backend.callbacks[.repeatLast]?()
        XCTAssertEqual(presentation.repeatLast.verification, .verified)
        XCTAssertEqual(presentation.togglePicker.verification, .waiting)
        backend.callbacks[.togglePicker]?()
        XCTAssertEqual(presentation.togglePicker.verification, .verified)
    }

    func testStatusMenuOrderTitlesAndStandardCommands() throws {
        let menu = delegate.makeStatusMenu()
        let libraryLabel = try XCTUnwrap(delegate.libraryStatusModel?.menuLabel)
        XCTAssertEqual(menu.items.map(\.title), [
            "Show Picker", "Repeat Last Prompt", "", libraryLabel, "", "Settings…", "Setup…", "",
            "About Monkey's Paw", "Quit Monkey's Paw"
        ])
        XCTAssertEqual(menu.items.enumerated().filter { $0.element.isSeparatorItem }.map(\.offset), [2, 4, 7])
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items[3].isEnabled, delegate.libraryStatusModel?.libraryAvailable)
        XCTAssertEqual(menu.items[5].action, #selector(AppDelegate.showSettings))
        XCTAssertEqual(menu.items[5].keyEquivalent, ",")
        XCTAssertEqual(menu.items[5].keyEquivalentModifierMask, .command)
        XCTAssertEqual(menu.items[8].action, #selector(AppDelegate.showAboutPanel(_:)))
        XCTAssertTrue(menu.items[8].target === delegate)
        XCTAssertEqual(menu.items[9].action, #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(menu.items[9].keyEquivalent, "q")
        XCTAssertEqual(menu.items[9].keyEquivalentModifierMask, .command)
    }

    func testStatusMenuRefreshesCarbonShortcutDisplayWithoutDispatchingIt() throws {
        let menu = try XCTUnwrap(delegate.makeStatusMenu() as? StatusMenu)
        let picker = menu.items[0]
        let repeatItem = menu.items[1]
        XCTAssertEqual(picker.keyEquivalent, "p")
        XCTAssertEqual(picker.keyEquivalentModifierMask, [.control, .option])
        XCTAssertEqual(repeatItem.keyEquivalent, "")
        XCTAssertTrue(repeatItem.keyEquivalentModifierMask.isEmpty)
        let registrations = backend.requested.count
        menu.menuNeedsUpdate(menu)
        XCTAssertEqual(backend.requested.count, registrations, "Opening the menu must only read registration facts")

        presentation.setAccelerator("Ctrl+Shift+R", for: .repeatLast)
        menu.menuNeedsUpdate(menu)
        XCTAssertEqual(repeatItem.keyEquivalent, "r")
        XCTAssertEqual(repeatItem.keyEquivalentModifierMask, [.control, .shift])
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "R", charactersIgnoringModifiers: "R", isARepeat: false, keyCode: 15))
        XCTAssertFalse(menu.performKeyEquivalent(with: event))
        XCTAssertNil(delegate.repeatModel?.result)
        XCTAssertEqual(repeatItem.keyEquivalent, "r", "Dispatch must retain the displayed binding")

        presentation.clearShortcut(.repeatLast)
        presentation.clearShortcut(.togglePicker)
        menu.menuNeedsUpdate(menu)
        XCTAssertEqual(picker.keyEquivalent, "")
        XCTAssertEqual(repeatItem.keyEquivalent, "")
        XCTAssertTrue(picker.keyEquivalentModifierMask.isEmpty)
        XCTAssertTrue(repeatItem.keyEquivalentModifierMask.isEmpty)
    }

    func testStatusMenuDisplaysCarbonFunctionAndPlusKeys() throws {
        let menu = try XCTUnwrap(delegate.makeStatusMenu() as? StatusMenu)
        presentation.setAccelerator("Ctrl+F3", for: .repeatLast)
        menu.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items[1].keyEquivalent, String(try XCTUnwrap(UnicodeScalar(NSF3FunctionKey))))
        XCTAssertEqual(menu.items[1].keyEquivalentModifierMask, .control)
        presentation.setAccelerator("Alt+Plus", for: .repeatLast)
        menu.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items[1].keyEquivalent, "=")
        XCTAssertEqual(menu.items[1].keyEquivalentModifierMask, [.option, .shift])
    }

    func testAboutOptionsUseBundleVersionAndLinkedCredits() throws {
        let options = AppDelegate.aboutPanelOptions(bundle: .main)
        XCTAssertEqual(options[.applicationName] as? String, AppIdentity.displayName)
        XCTAssertEqual(options[.applicationVersion] as? String,
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        XCTAssertEqual(options[.version] as? String, Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        let credits = try XCTUnwrap(options[.credits] as? NSAttributedString)
        XCTAssertTrue(credits.string.contains(Strings.aboutDescription))
        let link = (credits.string as NSString).range(of: Strings.projectLink)
        XCTAssertNotEqual(link.location, NSNotFound)
        guard link.location != NSNotFound else { return }
        XCTAssertEqual((credits.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString,
            "https://github.com/L-K-M/MonkeysPaw")
    }

    func testSettingsCloseReopenKeepsLiveRowsAndRetiredCallbacksCannotActivate() throws {
        delegate.showSettings()
        let controller = try XCTUnwrap(delegate.settingsWindow)
        let window = try XCTUnwrap(controller.window)
        presentation.setAccelerator("Ctrl+Alt+R", for: .repeatLast)
        let obsolete = try XCTUnwrap(backend.callbacks[.repeatLast])
        window.close()
        presentation.setAccelerator("Ctrl+Alt+K", for: .repeatLast)
        delegate.showSettings()
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(presentation.repeatLast.binding, .accelerator(try Accelerator("Ctrl+Alt+K")))
        presentation.beginVerification(.repeatLast)
        obsolete()
        XCTAssertEqual(presentation.repeatLast.verification, .waiting)
        XCTAssertNil(delegate.repeatModel?.result)
        let callback = try XCTUnwrap(backend.callbacks[.repeatLast])
        let model = delegate.repeatModel
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        callback()
        XCTAssertEqual(model?.state, .inactive)
        XCTAssertNil(model?.result)
    }

    func testCaptureErrorIsScopedToActionAndClearingRemovesOnlyItsError() {
        presentation.captureFailed(.unsupportedCarbonKey, for: .repeatLast)
        XCTAssertEqual(presentation.displayedShortcutError(for: .repeatLast), Strings.carbonUnsupportedKey)
        XCTAssertNil(presentation.displayedShortcutError)
        presentation.clearShortcut(.repeatLast)
        XCTAssertNil(presentation.displayedShortcutError(for: .repeatLast))
    }

    func testRetainedSettingsAndBackendCallbacksDoNotKeepDelegateAlive() throws {
        presentation.setAccelerator("Ctrl+Alt+R", for: .repeatLast)
        let retainedPresentation = presentation
        let callback = try XCTUnwrap(backend.callbacks[.repeatLast])
        let model = try XCTUnwrap(delegate.repeatModel)
        weak var owner = delegate
        delegate = nil
        XCTAssertNil(owner)
        XCTAssertEqual(model.state, .inactive)
        callback()
        retainedPresentation.refresh()
        XCTAssertNil(model.result)
        XCTAssertFalse(NSApp.windows.contains { !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible })
    }

    func testShutdownClosesSettingsStopsRecorderAndPreventsReopening() throws {
        delegate.showSettings()
        let controller = try XCTUnwrap(delegate.settingsWindow)
        let window = try XCTUnwrap(controller.window)
        let recorder = ShortcutRecorderButton(frame: .zero)
        window.contentView = recorder
        recorder.beginCapture()
        XCTAssertTrue(recorder.isRecording)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(controller.window)
        controller.show()
        XCTAssertNil(controller.window)
        XCTAssertFalse(window.isVisible)
    }
}
