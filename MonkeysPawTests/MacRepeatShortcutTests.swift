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
        XCTAssertEqual(repeatMenu.keyEquivalent, "", "Repeat has no default menu equivalent")
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
}
