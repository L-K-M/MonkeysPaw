#if os(Linux)
import CGtk
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxSettingsWindowTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var chooser: SettingsFolderChooser!
    private var paths: LinuxPaths!
    private var launched: [URL] = []

    override func setUpWithError() throws {
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        tools.environment["XDG_CURRENT_DESKTOP"] = "sway"
        paths = LinuxPaths(environment: tools.environment)
        chooser = SettingsFolderChooser()
        launched = []
        compose()
        MonkeysPawLinuxApp.installSettingsAction(application: application, environment: environment)
    }

    override func tearDown() {
        drainUI()
        environment?.shutdown()
        environment = nil
        drainUI()
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        chooser = nil
        tools = nil
    }

    func testSettingsActionReusesTabbedWindowAcrossCloseAndLeavesPickerWorking() throws {
        let window = try openSettingsAction()
        let general = environment.generalSettingsModel
        let shortcuts = environment.shortcutsSettingsModel
        let rememberedValues = environment.rememberedValuesSettingsModel
        let stack = try settingsWidget("settings-stack", in: window)
        let pages: [(name: String, title: String)] = [
            ("general", LinuxStrings.generalTab), ("shortcuts", LinuxStrings.shortcutsTab),
            ("delivery", DeliverySettingsStrings.title), ("assistant", LinuxAssistantSettingsStrings.tab),
            ("account", LinuxAccountSettingsStrings.tab)]
        var children: [GTK.Widget] = []
        var child = gtk_widget_get_first_child(stack)
        while let current = child {
            children.append(current)
            child = gtk_widget_get_next_sibling(current)
        }
        XCTAssertEqual(children.count, pages.count)
        for (page, expected) in zip(children, pages) {
            let stackPage = try XCTUnwrap(gtk_stack_get_page(mp_stack(stack), page))
            XCTAssertEqual(gtk_stack_page_get_name(stackPage).map { String(cString: $0) }, expected.name)
            XCTAssertEqual(gtk_stack_page_get_title(stackPage).map { String(cString: $0) }, expected.title)
        }
        XCTAssertEqual(gtk_window_get_hide_on_close(mp_window(window)), 1)
        XCTAssertEqual(try openSettingsAction(), window)
        XCTAssertEqual(settingsWindows.count, 1)
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(window) == 0 })
        XCTAssertEqual(gtk_window_get_application(mp_window(window)), application)
        XCTAssertEqual(try openSettingsAction(), window)
        XCTAssertTrue(environment.generalSettingsModel === general)
        XCTAssertTrue(environment.shortcutsSettingsModel === shortcuts)
        XCTAssertTrue(environment.rememberedValuesSettingsModel === rememberedValues)
        gtk_window_close(mp_window(window))

        let files = try RootedFileStore(root: defaultFolder)
        try files.write(Data("Hello {{topic}}".utf8), at: "hello.md")
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isVisible })
        XCTAssertEqual(environment.pickerModel.state, .picker)
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["hello.md"])
        environment.pickerModel.use(mode: .copyOnly)
        XCTAssertEqual(environment.pickerModel.state, .fill)
        environment.pickerModel.escape()
        XCTAssertEqual(environment.pickerModel.state, .picker)
        environment.pickerModel.dismiss()
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })
        XCTAssertEqual(try openSettingsAction(), window)
    }

    func testPickerSettingsButtonDismissesBeforeOpeningAndReusesTheWindow() throws {
        try assertPickerSettingsAccess {
            let button = try settingsWidget("picker-settings", in: self.environment.panel.clipboardOwner)
            XCTAssertEqual(String(cString: gtk_button_get_label(mp_button(button))), "Settings…")
            XCTAssertNotEqual(GTKTestSupport.activate(button), 0)
        }
    }

    func testPickerControlCommaDismissesBeforeOpeningAndReusesTheWindow() throws {
        try assertPickerSettingsAccess {
            XCTAssertNotEqual(mp_test_emit_key_pressed(self.environment.panel.clipboardOwner,
                UInt32(GDK_KEY_comma), GDK_CONTROL_MASK), 0)
        }
    }

    func testSettingsActionDismissesPickerWithoutDeliveryAndReusesTheWindow() throws {
        try assertPickerSettingsAccess { _ = try self.openSettingsAction() }
    }

    func testShortcutsOpenSetupReusesTheExistingWindowAndModels() throws {
        environment.presentFromLauncher()
        XCTAssertTrue(GTKTestSupport.spin { self.setupWindows.count == 1 })
        let setupWindow = try XCTUnwrap(setupWindows.first)
        let setup = environment.setupModel
        let shortcuts = environment.shortcutsSettingsModel
        // Isolate explicit Setup reuse from its first-run continuation.
        environment.settingsModel.completeLibraryFolderStep()
        environment.settingsModel.markSeedsOffered()
        gtk_window_close(mp_window(setupWindow))
        let settingsWindow = try openSettingsAction()
        let stack = try settingsWidget("settings-stack", in: settingsWindow)
        gtk_stack_set_visible_child_name(mp_stack(stack), "shortcuts")
        let button = try settingsWidget("settings-open-setup", in: settingsWindow)
        XCTAssertEqual(String(cString: gtk_button_get_label(mp_button(button))), "Open Setup…")

        for _ in 0..<2 {
            XCTAssertNotEqual(GTKTestSupport.activate(button), 0)
            XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(setupWindow) != 0 })
            XCTAssertEqual(setupWindows, [setupWindow])
            XCTAssertEqual(settingsWindows, [settingsWindow])
            XCTAssertTrue(environment.setupModel === setup)
            XCTAssertTrue(environment.shortcutsSettingsModel === shortcuts)
            XCTAssertFalse(environment.panel.isVisible)
            gtk_window_close(mp_window(setupWindow))
        }
    }

    func testChooseSwitchesLibraryInvalidChoiceKeepsPathAndDefaultAndRevealUseModel() throws {
        let window = try openSettingsAction()
        let pathLabel = try settingsWidget("settings-library-path", in: window)
        let useDefault = try settingsWidget("settings-use-default", in: window)
        XCTAssertEqual(labelText(pathLabel), defaultFolder.path)
        XCTAssertEqual(gtk_label_get_selectable(mp_label(pathLabel)), 1)
        XCTAssertEqual(gtk_widget_get_sensitive(useDefault), 0)
        let second = try library("Second", prompt: "Second library")
        let old = environment.pickerModel
        try choose(second.path, in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.labelText(pathLabel) == second.path })
        XCTAssertEqual(environment.settingsModel.libraryFolderPath, second.path)
        XCTAssertTrue(old !== environment.pickerModel)
        environment.pickerModel.open()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.results.map(\.relativePath) == ["prompt.md"] })
        XCTAssertEqual(labelText(try settingsWidget("settings-library-default", in: window)), LinuxStrings.customLibraryFolder)
        XCTAssertEqual(gtk_widget_get_sensitive(useDefault), 1)
        XCTAssertEqual(gtk_widget_get_visible(try settingsWidget("settings-general-error", in: window)), 0)
        try click("settings-reveal-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.launched == [second] })

        let invalid = tools.directory.appendingPathComponent("missing").path
        try choose(invalid, in: window)
        let message = try settingsWidget("settings-library-message", in: window)
        let failure = LibrarySwitchOutcome.invalidTarget(.rejectedByStore(.notFound))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.generalSettingsModel.state.lastSwitchMessage == failure })
        XCTAssertEqual(labelText(message), GeneralSettingsStrings.message(for: failure))
        XCTAssertNotEqual(gtk_widget_get_visible(message), 0)
        XCTAssertEqual(labelText(pathLabel), second.path)
        XCTAssertEqual(environment.settingsModel.libraryFolderPath, second.path)
        gtk_window_close(mp_window(window))
        XCTAssertEqual(try showSettings(), window)
        XCTAssertEqual(labelText(message), GeneralSettingsStrings.message(for: failure))
        XCTAssertNotEqual(gtk_widget_get_visible(message), 0, "Reopening must retain an unrelated switch error")

        try click("settings-use-default", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.labelText(pathLabel) == self.defaultFolder.path })
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
        XCTAssertEqual(gtk_widget_get_sensitive(useDefault), 0)
        XCTAssertEqual(gtk_widget_get_visible(message), 0)
        try click("settings-reveal-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.launched == [second, self.defaultFolder] })
        XCTAssertEqual(try openSettingsAction(), window)
    }

    func testReadOnlySettingsKeepSessionControlsAndTypedErrorsVisible() throws {
        let config = try RootedFileStore(root: paths.configDirectory)
        let future = Data("{\"version\":999}".utf8)
        try config.write(future, at: "settings.json")
        compose()
        let window = try showSettings()
        let failure = SettingsError.futureVersion(999)
        let errorLabel = try settingsWidget("settings-general-error", in: window)
        XCTAssertTrue(environment.generalSettingsModel.state.isReadOnly)
        XCTAssertEqual(labelText(errorLabel), GeneralSettingsStrings.settingsError(failure))
        XCTAssertNotEqual(gtk_widget_get_visible(errorLabel), 0)
        XCTAssertNotEqual(gtk_widget_get_sensitive(try settingsWidget("settings-use-default", in: window)), 0)
        let second = try library("ReadOnlySession", prompt: "Usable for this session")
        try choose(second.path, in: window)
        let path = try settingsWidget("settings-library-path", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.labelText(path) == second.path })
        XCTAssertEqual(environment.generalSettingsModel.state.lastSwitchMessage, .settingsNotSaved(failure))
        XCTAssertEqual(labelText(try settingsWidget("settings-library-message", in: window)),
            GeneralSettingsStrings.message(for: .settingsNotSaved(failure)))
        gtk_window_close(mp_window(window))
        XCTAssertEqual(try showSettings(), window)
        let switchMessage = try settingsWidget("settings-library-message", in: window)
        XCTAssertEqual(labelText(switchMessage), GeneralSettingsStrings.message(for: .settingsNotSaved(failure)))
        XCTAssertNotEqual(gtk_widget_get_visible(switchMessage), 0, "Reopening must retain a persistence failure")
        XCTAssertNotEqual(gtk_widget_get_sensitive(try settingsWidget("settings-choose-folder", in: window)), 0)
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        environment.pickerModel.open()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.results.map(\.relativePath) == ["prompt.md"] })
        try click("settings-reveal-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.launched == [second] })
        try click("settings-use-default", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.labelText(path) == self.defaultFolder.path })
        XCTAssertNotEqual(gtk_widget_get_sensitive(try settingsWidget("settings-use-default", in: window)), 0)
        XCTAssertEqual(try config.read(at: "settings.json"), future)
    }

    func testCreepyToggleCommitsAndTracksRepublishing() throws {
        let window = try showSettings()
        let toggle = try settingsWidget("settings-creepy", in: window)
        XCTAssertNotEqual(gtk_check_button_get_active(mp_check_button(toggle)), 0)
        gtk_check_button_set_active(mp_check_button(toggle), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.settingsModel.creepy == .disabled })
        XCTAssertTrue(GTKTestSupport.spin { self.environment.generalSettingsModel.state.creepy == .disabled })
        XCTAssertEqual(gtk_check_button_get_active(mp_check_button(toggle)), 0)
        let config = try RootedFileStore(root: paths.configDirectory)
        let reopened = SettingsService(store: SettingsStore(files: config))
        XCTAssertEqual(reopened.snapshot.document.creepy, .disabled)
        // An external write republishes into the open view.
        environment.settingsModel.setCreepy(.enabled)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.generalSettingsModel.state.creepy == .enabled })
        XCTAssertTrue(GTKTestSupport.spin { gtk_check_button_get_active(mp_check_button(toggle)) != 0 })
        // A hidden window ignores toggles; reopening re-syncs the control.
        gtk_window_close(mp_window(window))
        gtk_check_button_set_active(mp_check_button(toggle), 0)
        drainUI()
        XCTAssertEqual(environment.settingsModel.creepy, .enabled)
        XCTAssertEqual(try showSettings(), window)
        XCTAssertTrue(GTKTestSupport.spin { gtk_check_button_get_active(mp_check_button(toggle)) != 0 })
    }

    func testReadOnlySettingsDisableCreepyToggleWithoutWriting() throws {
        let config = try RootedFileStore(root: paths.configDirectory)
        let bytes = Data("{\"version\":999}".utf8)
        try config.write(bytes, at: "settings.json")
        compose()
        let window = try showSettings()
        let toggle = try settingsWidget("settings-creepy", in: window)
        XCTAssertEqual(gtk_widget_get_sensitive(toggle), 0)
        gtk_check_button_set_active(mp_check_button(toggle), 0)
        drainUI()
        XCTAssertEqual(environment.settingsModel.creepy, .enabled)
        XCTAssertEqual(environment.generalSettingsModel.state.creepy, .enabled)
        XCTAssertEqual(try config.read(at: "settings.json"), bytes)
    }

    func testCreepyWriteFailureRestoresCommittedToggleAndRetries() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        let window = try showSettings()
        let toggle = try settingsWidget("settings-creepy", in: window)
        environment.settingsModel.markSetupPresented()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.configDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.configDirectory.path) }
        for _ in 0..<2 {
            gtk_check_button_set_active(mp_check_button(toggle), 0)
            XCTAssertTrue(GTKTestSupport.spin { self.environment.generalSettingsModel.state.settingsError != nil })
            drainUI()
            XCTAssertNotEqual(gtk_check_button_get_active(mp_check_button(toggle)), 0)
            XCTAssertEqual(environment.settingsModel.creepy, .enabled)
        }
        XCTAssertNotEqual(gtk_widget_get_visible(try settingsWidget("settings-general-error", in: window)), 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.configDirectory.path)
        gtk_check_button_set_active(mp_check_button(toggle), 0)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.settingsModel.creepy == .disabled })
        XCTAssertTrue(GTKTestSupport.spin { self.environment.generalSettingsModel.state.creepy == .disabled })
        XCTAssertEqual(gtk_check_button_get_active(mp_check_button(toggle)), 0)
        drainUI()
        XCTAssertEqual(gtk_widget_get_visible(try settingsWidget("settings-general-error", in: window)), 0)
    }

    func testSandboxExternalFolderRefusalPreservesGraphAndLiveWatcher() throws {
        tools.environment["FLATPAK_ID"] = AppIdentity.linuxAppID
        paths = LinuxPaths(environment: tools.environment)
        compose()
        let window = try showSettings()
        let homeLibrary = try library("Home Library", prompt: "Home prompt")
        try choose(homeLibrary.path, in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.generalSettingsModel.state.activeLibraryPath == homeLibrary.path })
        let picker = environment.pickerModel
        let browser = environment.libraryBrowserModel
        let editor = environment.editorModel
        let imports = environment.libraryImportState
        picker.open()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isVisible })
        let config = try RootedFileStore(root: paths.configDirectory)
        let saved = try config.read(at: "settings.json")
        let external = try FakeLinuxTools()
        let externalFiles = try RootedFileStore(root: external.directory)
        try externalFiles.write(Data("External prompt".utf8), at: "external.md")
        let alias = tools.directory.appendingPathComponent("External Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: external.directory)
        let chooseButton = try settingsWidget("settings-choose-folder", in: window)

        for path in [external.directory.path, "/run/user/1000/doc/fixture/library", alias.path] {
            try choose(path, in: window)
            XCTAssertTrue(GTKTestSupport.spin {
                gtk_widget_get_sensitive(chooseButton) != 0
                    && self.environment.generalSettingsModel.state.lastSwitchMessage == .invalidTarget(.outsideSandboxHome)
            })
            let message = try settingsWidget("settings-library-message", in: window)
            XCTAssertEqual(labelText(message), GeneralSettingsStrings.message(for: .invalidTarget(.outsideSandboxHome)))
            XCTAssertNotEqual(gtk_widget_get_visible(message), 0)
            XCTAssertEqual(environment.generalSettingsModel.state.activeLibraryPath, homeLibrary.path)
            XCTAssertTrue(environment.pickerModel === picker)
            XCTAssertTrue(environment.libraryBrowserModel === browser)
            XCTAssertTrue(environment.editorModel === editor)
            XCTAssertTrue(environment.libraryImportState === imports)
            XCTAssertEqual(picker.state, .picker)
            XCTAssertTrue(environment.panel.isVisible)
            XCTAssertEqual(environment.settingsModel.libraryFolderPath, homeLibrary.path)
            XCTAssertEqual(try config.read(at: "settings.json"), saved)
        }
        try RootedFileStore(root: homeLibrary).write(Data("Still watched".utf8), at: "later.md")
        XCTAssertTrue(GTKTestSupport.spin { picker.results.map(\.relativePath) == ["later.md", "prompt.md"] })

        let count = chooser.requests.count
        try click("settings-choose-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == count + 1 })
        chooser.requests.last?.done(nil)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_sensitive(chooseButton) != 0 })
        XCTAssertTrue(environment.pickerModel === picker)
        XCTAssertEqual(try config.read(at: "settings.json"), saved)

        try click("settings-use-default", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.generalSettingsModel.state.activeLibraryPath == self.defaultFolder.path })
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
    }

    func testSandboxEnvironmentUsesPrivateSettingsWithoutImportingNativeState() throws {
        let nativeConfig = try RootedFileStore(root: paths.configDirectory)
        let native = SettingsService(store: SettingsStore(files: nativeConfig))
        let nativeLibrary = try library("Native Library", prompt: "Native prompt")
        try native.setLibraryFolder(nativeLibrary.path)
        try native.markSetupPresented()
        let saved = try nativeConfig.read(at: "settings.json")
        try LinuxFirstRunState(paths: paths).recordPresentation()

        tools.environment["FLATPAK_ID"] = AppIdentity.linuxAppID
        paths = LinuxPaths(environment: tools.environment)
        compose()
        let expectedConfig = tools.directory.appendingPathComponent(".var/app/ch.lkmc.monkeyspaw/config/monkeyspaw")
        XCTAssertEqual(paths.configDirectory.path, expectedConfig.path)
        XCTAssertEqual(paths.dataDirectory.path, tools.directory.appendingPathComponent(".var/app/ch.lkmc.monkeyspaw/data/monkeyspaw").path)
        let window = try showSettings()
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        XCTAssertEqual(labelText(try settingsWidget("settings-library-path", in: window)), defaultFolder.path)
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
        XCTAssertTrue(environment.settingsModel.needsSetupPresentation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedConfig.appendingPathComponent("setup-shown").path))
        environment.settingsModel.markSetupPresented()
        let isolated = try RootedFileStore(root: expectedConfig)
        XCTAssertNotEqual(try isolated.read(at: "settings.json"), saved)
        XCTAssertEqual(try nativeConfig.read(at: "settings.json"), saved)
    }

    func testSandboxStartupRefusesSavedExternalLibrary() throws {
        let external = try FakeLinuxTools()
        let externalFiles = try RootedFileStore(root: external.directory)
        try externalFiles.write(Data("External prompt".utf8), at: "external.md")
        tools.environment["FLATPAK_ID"] = AppIdentity.linuxAppID
        paths = LinuxPaths(environment: tools.environment)
        let config = try RootedFileStore(root: paths.configDirectory)
        try SettingsService(store: SettingsStore(files: config)).setLibraryFolder(external.directory.path)
        let saved = try config.read(at: "settings.json")
        compose()
        _ = try showSettings()
        XCTAssertFalse(environment.pickerModel.libraryAvailable)
        XCTAssertTrue(environment.pickerModel.results.isEmpty)
        XCTAssertEqual(try config.read(at: "settings.json"), saved)
        XCTAssertEqual(try externalFiles.read(at: "external.md"), Data("External prompt".utf8))
        XCTAssertEqual(environment.switchLibrary(to: nil), .switched)
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
    }

    func testNativeChooserStillAcceptsOutsideHomeLibrary() throws {
        let external = try FakeLinuxTools()
        try RootedFileStore(root: external.directory).write(Data("External prompt".utf8), at: "external.md")
        let window = try showSettings()
        try choose(external.directory.path, in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.generalSettingsModel.state.activeLibraryPath == external.directory.path })
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        XCTAssertEqual(environment.settingsModel.libraryFolderPath, external.directory.path)
    }

    func testCancelledChooserRestoresChooseWithoutChangingTheLibrary() throws {
        let window = try showSettings()
        let count = chooser.requests.count
        try click("settings-choose-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == count + 1 })
        let chooseButton = try settingsWidget("settings-choose-folder", in: window)
        XCTAssertEqual(gtk_widget_get_sensitive(chooseButton), 0)
        chooser.requests.last?.done(nil)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_sensitive(chooseButton) != 0 })
        XCTAssertEqual(environment.generalSettingsModel.state.activeLibraryPath, defaultFolder.path)
        XCTAssertNil(environment.generalSettingsModel.state.lastSwitchMessage)
    }

    func testClosedWindowRejectsLateChooserResultsEvenAfterReopening() throws {
        let window = try showSettings()
        let second = try library("LateResponse")
        try click("settings-choose-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == 1 })
        let oldCompletion = try XCTUnwrap(chooser.requests.last?.done)
        oldCompletion(second.path) // Queue a result immediately before close.
        gtk_window_close(mp_window(window))
        XCTAssertEqual(gtk_widget_get_visible(window), 0)
        XCTAssertGreaterThan(chooser.cancelCount, 0)
        XCTAssertEqual(try showSettings(), window)
        drainUI()
        XCTAssertEqual(environment.generalSettingsModel.state.activeLibraryPath, defaultFolder.path)

        try click("settings-choose-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == 2 })
        oldCompletion(second.path)
        drainUI()
        XCTAssertEqual(environment.generalSettingsModel.state.activeLibraryPath, defaultFolder.path)
        chooser.requests.last?.done(second.path)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.generalSettingsModel.state.activeLibraryPath == second.path })
    }

    func testDestroyedWindowRejectsPendingResultsAndDetachedButtonEvents() throws {
        let window = try showSettings()
        let reveal = try settingsWidget("settings-reveal-folder", in: window)
        g_object_ref(reveal)
        defer { g_object_unref(reveal) }
        let second = try library("DestroyedResponse")
        try click("settings-choose-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == 1 })
        let completion = try XCTUnwrap(chooser.requests.last?.done)
        completion(second.path)
        gtk_window_destroy(mp_window(window))
        environment.showSettings() // Recreate without touching the destroyed GTK window.
        completion(second.path)
        _ = GTKTestSupport.activate(reveal)
        drainUI()
        XCTAssertEqual(environment.generalSettingsModel.state.activeLibraryPath, defaultFolder.path)
        XCTAssertTrue(launched.isEmpty)
        let reopened = try visibleSettings()
        XCTAssertEqual(settingsWindows.count, 1)
        let path = try settingsWidget("settings-library-path", in: reopened)
        try choose(second.path, in: reopened)
        XCTAssertTrue(GTKTestSupport.spin { self.labelText(path) == second.path })
    }

    func testInvalidPathIsRejectedBeforeFileURLResolvesIt() throws {
        let window = try showSettings()
        try choose("relative-library", in: window)
        let failure = LibrarySwitchOutcome.invalidTarget(.rejectedByStore(.invalidRoot))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.generalSettingsModel.state.lastSwitchMessage == failure })
        XCTAssertEqual(environment.generalSettingsModel.state.activeLibraryPath, defaultFolder.path)
        XCTAssertEqual(labelText(try settingsWidget("settings-library-message", in: window)), GeneralSettingsStrings.message(for: failure))
    }

    func testPresentationModelsDoNotRetainCompositionRoot() throws {
        _ = try openSettingsAction()
        weak var lifetime = environment
        let general = environment.generalSettingsModel
        let shortcuts = environment.shortcutsSettingsModel
        let rememberedValues = environment.rememberedValuesSettingsModel
        environment.shutdown()
        environment = nil
        drainUI()
        XCTAssertNil(lifetime)
        lifetime = nil
        // Retained presentation instances remain safe without their root.
        general.revealFolder()
        shortcuts.refresh()
        rememberedValues.requestForgetAll()
        drainUI()
        rememberedValues.confirmForgetAll()
        drainUI()
        XCTAssertEqual(rememberedValues.state.lastOutcome, .fileStoreFailure(.ioFailure))
        XCTAssertTrue(launched.isEmpty)
    }

    func testOpenRequestQueuedBeforeShutdownBuildsNoWindow() throws {
        environment.showSettings()
        environment.shutdown()
        drainUI()
        XCTAssertTrue(settingsWindows.isEmpty)
    }

    func testEveryLinuxSwitchResultMapsLosslesslyToCore() {
        let cases: [(LinuxEnvironment.LibrarySwitchResult, LibrarySwitchOutcome)] = [
            (.switched, .switched),
            (.deliveryInFlight, .deliveryInFlight),
            (.repeatInvalidationFailed, .repeatInvalidationFailed),
            (.outsideSandboxHome, .invalidTarget(.outsideSandboxHome)),
            (.invalidTarget(.outsideRoot), .invalidTarget(.rejectedByStore(.outsideRoot))),
            (.libraryUnavailable(.notFound), .libraryUnavailable(.notFound)),
            (.persistenceFailed(.writeFailed(.ioFailure)), .settingsNotSaved(.writeFailed(.ioFailure))),
            (.persistenceFailed(.futureVersion(999)), .settingsNotSaved(.futureVersion(999))),
        ]
        for (result, expected) in cases { XCTAssertEqual(result.settingsOutcome, expected) }
    }

    private var defaultFolder: URL { paths.documentsDirectory.appendingPathComponent("MonkeysPaw", isDirectory: true) }

    private func assertPickerSettingsAccess(_ open: () throws -> Void) throws {
        try RootedFileStore(root: defaultFolder).write(Data("Test prompt".utf8), at: "prompt.md")
        let window = try openSettingsAction()
        let picker = environment.pickerModel
        GTKClipboard(owner: environment.panel.clipboardOwner).writeText("Keep clipboard")
        var presentations = 0
        GTK.onNotify(UnsafeMutableRawPointer(window), "visible") { [weak self] in
            guard let self, gtk_widget_get_visible(window) != 0 else { return }
            presentations += 1
            XCTAssertEqual(picker.state, .closed, "Dismiss the picker before showing Settings")
            XCTAssertFalse(self.environment.panel.isVisible)
        }

        for _ in 0..<2 {
            gtk_window_close(mp_window(window))
            environment.activateToggle()
            XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
            let count = presentations
            try open()
            XCTAssertTrue(GTKTestSupport.spin { presentations == count + 1 })
            XCTAssertEqual(try visibleSettings(), window)
            XCTAssertEqual(settingsWindows.count, 1)
            XCTAssertEqual(picker.state, .closed)
            XCTAssertFalse(environment.panel.isVisible)
            XCTAssertTrue(environment.pickerModel === picker)

            let clipboard = SettingsClipboardRead()
            GTKClipboard(owner: environment.panel.clipboardOwner).readText { clipboard.store($0) }
            XCTAssertTrue(GTKTestSupport.spin { clipboard.value != nil })
            XCTAssertEqual(clipboard.value, "Keep clipboard", "Opening Settings must not deliver a prompt")
        }

        // Settings is still visible: either picker entry must raise that window.
        picker.open()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        try open()
        XCTAssertTrue(GTKTestSupport.spin {
            !self.environment.panel.isVisible && gtk_window_is_active(mp_window(window)) != 0
        })
        XCTAssertEqual(settingsWindows, [window])
        XCTAssertEqual(picker.state, .closed)
        let identity = try XCTUnwrap(picker.results.first?.identity)
        let data = try RootedFileStore(root: paths.dataDirectory)
        XCTAssertTrue(try UsageStore(files: data, clock: SystemClock()).useEvents(for: identity).isEmpty)
    }

    private func compose() {
        environment?.shutdown()
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            folderChooser: chooser, launchURI: { [weak self] in self?.launched.append($0) })
    }

    private func openSettingsAction() throws -> GTK.Widget {
        g_action_group_activate_action(mp_action_group(application), ActionName.settings.rawValue, nil)
        return try visibleSettings()
    }

    private func showSettings() throws -> GTK.Widget {
        environment.showSettings()
        return try visibleSettings()
    }

    private func visibleSettings() throws -> GTK.Widget {
        XCTAssertTrue(GTKTestSupport.spin { self.settingsWindows.contains { gtk_widget_get_visible($0) != 0 } })
        return try XCTUnwrap(settingsWindows.first)
    }

    private var settingsWindows: [GTK.Widget] {
        windows(titled: LinuxStrings.settings)
    }

    private var setupWindows: [GTK.Widget] {
        windows(titled: LinuxStrings.setup)
    }

    private func windows(titled title: String) -> [GTK.Widget] {
        var windows: [GTK.Widget] = []
        var node = gtk_application_get_windows(application)
        while let current = node {
            if let raw = current.pointee.data {
                let window = raw.assumingMemoryBound(to: GtkWindow.self)
                if gtk_window_get_title(window).map({ String(cString: $0) }) == title {
                    windows.append(mp_window_widget(window))
                }
            }
            node = current.pointee.next
        }
        return windows
    }

    private func library(_ name: String, prompt: String = "Test prompt") throws -> URL {
        let directory = tools.directory.appendingPathComponent(name, isDirectory: true)
        try RootedFileStore(root: directory).write(Data(prompt.utf8), at: "prompt.md")
        return directory
    }

    private func choose(_ path: String, in window: GTK.Widget) throws {
        let count = chooser.requests.count
        try click("settings-choose-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == count + 1 })
        let request = try XCTUnwrap(chooser.requests.last)
        XCTAssertEqual(request.parent, window)
        XCTAssertEqual(request.currentPath, environment.generalSettingsModel.state.activeLibraryPath)
        request.done(path)
    }

    private func click(_ name: String, in window: GTK.Widget) throws {
        XCTAssertNotEqual(GTKTestSupport.activate(try settingsWidget(name, in: window)), 0)
    }

    private func labelText(_ widget: GTK.Widget) -> String { String(cString: gtk_label_get_text(mp_label(widget))) }

    private func drainUI() {
        var drained = false
        GTK.onMainLoop { drained = true }
        XCTAssertTrue(GTKTestSupport.spin { drained })
    }
}

private final class SettingsClipboardRead: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    func store(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        text = value
    }
}

/// Deliberately keeps old completions after cancel to exercise stale responses.
final class SettingsFolderChooser: LinuxFolderChoosing {
    struct Request {
        let parent: GTK.Widget
        let currentPath: String
        let done: (String?) -> Void
    }
    private(set) var requests: [Request] = []
    private(set) var cancelCount = 0
    func chooseFolder(parent: GTK.Widget, currentPath: String, done: @escaping (String?) -> Void) {
        requests.append(Request(parent: parent, currentPath: currentPath, done: done))
    }
    func cancel() { cancelCount += 1 }
}

func settingsWidget(_ name: String, in parent: GTK.Widget) throws -> GTK.Widget {
    func find(_ widget: GTK.Widget) -> GTK.Widget? {
        if String(cString: gtk_widget_get_name(widget)) == name { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let found = find(current) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }
    return try XCTUnwrap(find(parent), "Missing Settings control: \(name)")
}
#endif
