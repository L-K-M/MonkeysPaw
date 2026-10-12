#if os(Linux)
import CGtk
import Foundation
import Glibc
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxLibrarySwitchTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var notifications: FakePortal!
    private var environment: LinuxEnvironment!
    private var paths: LinuxPaths!
    private var root: URL!
    private var files: RootedFileStore!
    private var launchedURLs: [URL] = []

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        paths = LinuxPaths(environment: tools.environment)
        root = paths.documentsDirectory.appendingPathComponent("MonkeysPaw", isDirectory: true)
        files = try RootedFileStore(root: root)
        notifications = try FakePortal(address: address)
        try notifications.ownNotifications()
        launchedURLs = []
        compose()
    }

    override func tearDown() {
        if environment != nil { drainUI() }
        environment?.shutdown()
        environment = nil
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        notifications?.shutdown()
        notifications = nil
        files = nil
        tools = nil
    }

    func testSwitchRebindsTheSameWindowAndRoutesKeysAndURIsToTheNewPicker() throws {
        try files.write(Data("Alpha".utf8), at: "a.md")
        let second = try library("B", prompts: ["b.md": "Beta", "c.md": "Charlie", "d.md": "Delta"])
        try openPicker()
        let old = environment.pickerModel
        let window = environment.panel.clipboardOwner
        let controllers = gtk_widget_observe_controllers(window)!
        defer { g_object_unref(UnsafeMutableRawPointer(controllers)) }
        let controllerCount = g_list_model_get_n_items(controllers)

        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        XCTAssertEqual(old.state, .closed)
        XCTAssertNil(old.onChange)
        XCTAssertFalse(environment.panel.isVisible)
        XCTAssertEqual(environment.panel.clipboardOwner, window)
        XCTAssertEqual(gtk_window_get_application(mp_window(window)), application)
        XCTAssertEqual(g_list_model_get_n_items(controllers), controllerCount)
        try openPicker()
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["b.md", "c.md", "d.md"])
        XCTAssertTrue(old !== environment.pickerModel)
        XCTAssertNotEqual(mp_test_emit_key_pressed(window, UInt32(GDK_KEY_Down), GdkModifierType(rawValue: 0)), 0)
        XCTAssertEqual(environment.pickerModel.selectionIndex, 1)
        environment.pickerModel.editSelected()
        XCTAssertTrue(GTKTestSupport.spin { self.launchedURLs.count == 1 })
        XCTAssertEqual(launchedURLs, [second.appendingPathComponent("c.md")])
        try openPicker()
        environment.pickerModel.openLibrary()
        XCTAssertTrue(GTKTestSupport.spin {
            guard let window = gtk_application_get_active_window(self.application),
                  let title = gtk_window_get_title(window) else { return false }
            return String(cString: title) == LinuxStrings.library
        })
        XCTAssertEqual(launchedURLs, [second.appendingPathComponent("c.md")])

        try openPicker()
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })
        XCTAssertEqual(environment.pickerModel.state, .closed)
        XCTAssertEqual(gtk_window_get_application(mp_window(window)), application)
    }

    func testInvalidTargetsKeepTheGraphAndSettingsAndDoNotCreateChosenFolders() throws {
        try files.write(Data("Alpha".utf8), at: "a.md")
        environment.settingsModel.markSetupPresented()
        try openPicker()
        let old = environment.pickerModel
        let config = try RootedFileStore(root: paths.configDirectory)
        let saved = try config.read(at: "settings.json")
        let missing = tools.directory.appendingPathComponent("missing/child")
        let regular = tools.directory.appendingPathComponent("file")
        try Data().write(to: regular)
        let alias = tools.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)

        for (target, failure) in [(missing, FileStoreError.notFound), (regular, .invalidRoot),
                                  (alias, .outsideRoot), (URL(string: "https://example.invalid/library")!, .invalidRoot),
                                  (URL(string: "relative-library")!, .invalidRoot),
                                  (URL(fileURLWithPath: "/"), .invalidRoot)] {
            XCTAssertEqual(environment.switchLibrary(to: target), .invalidTarget(failure))
            XCTAssertTrue(environment.pickerModel === old)
            XCTAssertEqual(old.state, .closed)
            XCTAssertEqual(old.results.map(\.relativePath), ["a.md"])
            XCTAssertEqual(try config.read(at: "settings.json"), saved)
            try openPicker()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    func testUnreadableTargetIsRejectedWithoutStoppingTheOldWatcher() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        try files.write(Data("Alpha".utf8), at: "a.md")
        let second = try library("B")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: second.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: second.path) }
        try openPicker()
        let old = environment.pickerModel
        XCTAssertEqual(environment.switchLibrary(to: second), .invalidTarget(.ioFailure))
        XCTAssertTrue(environment.pickerModel === old)
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
        try openPicker()
        try files.write(Data("Still watched".utf8), at: "new.md")
        XCTAssertTrue(GTKTestSupport.spin { old.results.count == 2 })
    }

    func testSwitchDuringDeliveryIsRefusedBeforeDismissalOrValidation() throws {
        let scheduler = SwitchScheduler()
        compose(scheduler: scheduler)
        try files.write(Data("Alpha".utf8), at: "a.md")
        let second = try library("B")
        try openPicker()
        let old = environment.pickerModel
        old.use(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin {
            old.state == .delivering && scheduler.delays.contains(Limits.settleDelayLinux)
        })
        let settings = environment.settingsModel.state
        XCTAssertEqual(environment.switchLibrary(to: second), .deliveryInFlight)
        XCTAssertTrue(environment.pickerModel === old)
        XCTAssertEqual(old.state, .delivering)
        XCTAssertEqual(environment.settingsModel.state, settings)
        scheduler.fireAll()
        XCTAssertTrue(GTKTestSupport.spin { old.state == .done(.copiedOnly(.requested)) })
        XCTAssertTrue(GTKTestSupport.spin { self.notifications.notificationCount == 1 })
    }

    func testSwitchDiscardsQueuedPresentationAndTargetsBehindFocusRestoration() throws {
        let focus = SwitchFocusTracker()
        compose(focusTracker: focus)
        try files.write(Data("Alpha".utf8), at: "a.md")
        let second = try library("B", prompts: ["b.md": "Beta"])
        try openPicker()
        let old = environment.pickerModel
        let window = environment.panel.clipboardOwner
        old.dismiss()
        XCTAssertTrue(GTKTestSupport.spin { focus.restoredTargets.count == 1 })
        XCTAssertFalse(environment.panel.isVisible)

        // These requests enter DeliveryService while its first restore is held.
        old.open()
        old.dismiss()
        old.open()
        drainUI()
        XCTAssertEqual(focus.restoredTargets.count, 1)
        XCTAssertFalse(environment.panel.isVisible)
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        let current = environment.pickerModel
        XCTAssertTrue(current !== old)
        XCTAssertEqual(current.state, .closed)

        var visibilityChanges = 0
        GTK.onNotify(UnsafeMutableRawPointer(window), "visible") { visibilityChanges += 1 }
        drainUI()
        focus.release()
        drainNativeEvents()
        XCTAssertEqual(visibilityChanges, 0, "Retired requests must not show or hide the reused panel")
        XCTAssertEqual(focus.restoredTargets.count, 1, "Queued old dismissals must not restore their targets")
        XCTAssertEqual(current.state, .closed)
        XCTAssertFalse(environment.panel.isVisible)
        XCTAssertEqual(environment.panel.clipboardOwner, window)

        // Discarded queue slots must finish so the replacement can still open.
        try openPicker()
        current.setQuery("Beta")
        XCTAssertEqual(current.results.map(\.relativePath), ["b.md"])
        XCTAssertEqual(current.query, "Beta")
        XCTAssertTrue(environment.panel.isVisible)
        XCTAssertTrue(environment.pickerModel === current)
    }

    func testSettingsActionDuringDeliveryKeepsTheGraphAndRefusesWindowEntry() throws {
        let scheduler = SwitchScheduler()
        compose(scheduler: scheduler)
        MonkeysPawLinuxApp.installSettingsAction(application: application, environment: environment)
        try files.write(Data("Alpha".utf8), at: "a.md")
        try openPicker()
        let picker = environment.pickerModel
        picker.use(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin {
            picker.state == .delivering && scheduler.delays.contains(Limits.settleDelayLinux)
        })

        g_action_group_activate_action(mp_action_group(application), ActionName.settings.rawValue, nil)
        drainUI()
        XCTAssertEqual(g_list_length(gtk_application_get_windows(application)), 1,
                       "Settings must not open while delivery owns the focus sequence")
        XCTAssertEqual(picker.state, .delivering)
        XCTAssertTrue(environment.pickerModel === picker)
        scheduler.fireAll()
        XCTAssertTrue(GTKTestSupport.spin { picker.state == .done(.copiedOnly(.requested)) })
        XCTAssertTrue(GTKTestSupport.spin { self.notifications.notificationCount == 1 })

        // A fresh Settings request works once the delivery has completed.
        g_action_group_activate_action(mp_action_group(application), ActionName.settings.rawValue, nil)
        XCTAssertTrue(GTKTestSupport.spin {
            // Setup also owns a hidden self-test target; count Settings itself.
            var node = gtk_application_get_windows(self.application)
            var visibleSettings = 0
            while let current = node {
                if let window = current.pointee.data?.assumingMemoryBound(to: GtkWindow.self),
                   gtk_window_get_title(window).map({ String(cString: $0) }) == LinuxStrings.settings,
                   gtk_widget_get_visible(mp_window_widget(window)) != 0 {
                    visibleSettings += 1
                }
                node = current.pointee.next
            }
            return visibleSettings == 1
        })
        XCTAssertEqual(picker.state, .closed)
        XCTAssertFalse(environment.panel.isVisible)
    }

    func testPendingOnboardingLauncherRequestDuringDeliveryRefusesWindowEntry() throws {
        let scheduler = SwitchScheduler()
        compose(scheduler: scheduler)
        environment.settingsModel.markSetupPresented()
        try files.write(Data("Alpha".utf8), at: "a.md")
        try openPicker()
        let picker = environment.pickerModel
        picker.use(mode: .copyOnly)
        XCTAssertTrue(GTKTestSupport.spin {
            picker.state == .delivering && scheduler.delays.contains(Limits.settleDelayLinux)
        })

        environment.presentFromLauncher()
        drainUI()
        XCTAssertEqual(g_list_length(gtk_application_get_windows(application)), 1,
                       "Onboarding must not open while delivery owns the focus sequence")
        XCTAssertEqual(picker.state, .delivering)
        XCTAssertTrue(environment.pickerModel === picker)
        scheduler.fireAll()
        XCTAssertTrue(GTKTestSupport.spin { picker.state == .done(.copiedOnly(.requested)) })
        XCTAssertTrue(GTKTestSupport.spin { self.notifications.notificationCount == 1 })

        environment.presentFromLauncher()
        XCTAssertTrue(GTKTestSupport.spin {
            guard let window = gtk_application_get_active_window(self.application),
                  let title = gtk_window_get_title(window) else { return false }
            return String(cString: title) == LinuxStrings.onboarding
                && gtk_widget_get_visible(mp_window_widget(window)) != 0
        })
    }

    func testOldNativeEventsAndDebounceCannotChangeTheReplacementLibrary() throws {
        let scheduler = SwitchScheduler()
        compose(scheduler: scheduler)
        try files.write(Data("Alpha".utf8), at: "a.md")
        let second = try library("B", prompts: ["b.md": "Beta"])
        try openPicker()
        try files.write(Data("Queued modification".utf8), at: "a.md")
        XCTAssertTrue(GTKTestSupport.spin { scheduler.delays.contains(Limits.watchDebounce) })
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        try openPicker()
        try files.write(Data("Late old save".utf8), at: "late.md")
        try FileManager.default.removeItem(at: root)
        scheduler.fireAll()
        drainNativeEvents()
        scheduler.fireAll()
        drainUI()
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["b.md"])
        XCTAssertTrue(environment.pickerModel.libraryAvailable)

        try RootedFileStore(root: second).write(Data("New watched save".utf8), at: "new.md")
        XCTAssertTrue(GTKTestSupport.spin { scheduler.hasPending })
        scheduler.fireAll()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.results.count == 2 })
    }

    func testQueuedOldHealthAndRetainedRawCallbacksAreInert() throws {
        let scheduler = SwitchScheduler()
        let raw = SwitchWatcher()
        let second = try library("B", prompts: ["b.md": "Beta"])
        compose(scheduler: scheduler, watcherFactory: { directory in
            directory == second ? SwitchWatcher() : raw
        })
        try files.write(Data("Alpha".utf8), at: "a.md")
        try openPicker()
        raw.emit(.rootUnavailable(.notFound))
        scheduler.fireAll() // Composition's MainThread work is now queued.
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        XCTAssertGreaterThan(raw.stopCount, 0)
        try openPicker()
        drainUI()
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["b.md"])
        // The old driver deliberately retains its callback after stop.
        raw.emit(.rootUnavailable(.outsideRoot))
        scheduler.fireAll()
        drainUI()
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
    }

    func testQueuedOldIndexAndLauncherWorkCannotRepublishAfterSwitch() throws {
        try files.write(Data("Alpha".utf8), at: "a.md")
        let second = try library("B", prompts: ["b.md": "Beta"])
        let old = environment.pickerModel
        let viewChanged = old.onChange
        var oldPublications = 0
        old.onChange = { oldPublications += 1; viewChanged?() }
        // Do not drain GTK: A's rebuild and its requested URI remain queued.
        environment.activateToggle()
        old.editSelected()
        XCTAssertTrue(launchedURLs.isEmpty)
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        let retiredPublications = oldPublications
        try openPicker()
        drainUI()
        XCTAssertEqual(oldPublications, retiredPublications)
        XCTAssertTrue(launchedURLs.isEmpty)
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["b.md"])
    }

    func testDetachedOldWidgetsCannotInvokeTheNewPicker() throws {
        try files.write(Data("{{topic}}".utf8), at: "a.md")
        let second = try library("B", prompts: ["b.md": "{{topic}}"])
        try openPicker()
        let oldQuery = try widget(named: "picker-query")
        let oldUse = try widget(named: "picker-use")
        g_object_ref(oldQuery)
        g_object_ref(oldUse)
        defer { g_object_unref(oldQuery); g_object_unref(oldUse) }
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        try openPicker()
        mp_entry_set_text(oldQuery, "stale query")
        XCTAssertNotEqual(gtk_widget_activate(oldUse), 0)
        drainNativeEvents()
        XCTAssertEqual(environment.pickerModel.query, "")
        XCTAssertEqual(environment.pickerModel.state, .picker)
        XCTAssertEqual(String(cString: mp_entry_text(try widget(named: "picker-query"))), "")
    }

    func testSwitchDropsDraftsButSharesValuesUsageAndSetup() throws {
        try files.write(Data("{{topic}}".utf8), at: "same.md")
        let second = try library("B", prompts: ["same.md": "{{topic}}"])
        try openPicker()
        let identity = try XCTUnwrap(environment.pickerModel.results.first?.identity)
        let data = try RootedFileStore(root: paths.dataDirectory)
        try ValuesStore(files: data).record(identity: identity, values: ["topic": "Remembered"])
        try UsageStore(files: data, clock: SystemClock()).recordUse(identity: identity)
        let setup = environment.setupModel
        environment.pickerModel.use(mode: .copyOnly)
        let oldFill = try XCTUnwrap(environment.pickerModel.fillModel)
        XCTAssertEqual(oldFill.values["topic"], "Remembered")
        oldFill.setValue("Session draft", name: "topic")
        weak let oldPicker = environment.pickerModel
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        XCTAssertEqual(oldFill.state, .closed)
        // Keep the old form alive while its native controls have been removed.
        oldFill.setValue("Late edit", name: "topic")
        try openPicker()
        XCTAssertEqual(environment.pickerModel.results.first?.identity, identity)
        environment.pickerModel.use(mode: .copyOnly)
        XCTAssertEqual(environment.pickerModel.fillModel?.values["topic"], "Remembered")
        XCTAssertEqual(try UsageStore(files: data, clock: SystemClock()).useEvents(for: identity).count, 1)
        XCTAssertTrue(environment.setupModel === setup)
        XCTAssertNil(oldPicker)
        XCTAssertEqual(environment.pickerModel.fillModel?.state, .editing)
    }

    func testReplacementWatcherIsArmedAfterPickerHookAndBeforeRebuild() throws {
        let second = try library("B", prompts: ["before.md": "Before"])
        let raw = SwitchWatcher {
            XCTAssertNotNil(self.environment.pickerModel.onChange)
            XCTAssertEqual(self.environment.pickerModel.state, .closed)
            try RootedFileStore(root: second).write(Data("During start".utf8), at: "during.md")
        }
        compose(watcherFactory: { directory in
            directory == second ? raw : SwitchWatcher()
        })
        try files.write(Data("Alpha".utf8), at: "a.md")
        try openPicker()
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        try openPicker()
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["before.md", "during.md"])
    }

    func testStartupFailureDegradesNewGraphWithoutPersistingAndCanSwitchAgain() throws {
        let second = try library("B", prompts: ["b.md": "Beta"])
        let failing = SwitchWatcher { throw FileStoreError.ioFailure }
        compose(watcherFactory: { directory in
            directory == second ? failing : SwitchWatcher()
        })
        try files.write(Data("Alpha".utf8), at: "a.md")
        try openPicker()
        let settings = environment.settingsModel.state
        XCTAssertEqual(environment.switchLibrary(to: second), .libraryUnavailable(.ioFailure))
        XCTAssertFalse(environment.pickerModel.libraryAvailable)
        XCTAssertGreaterThan(failing.stopCount, 0)
        XCTAssertEqual(environment.settingsModel.state, settings)
        XCTAssertEqual(environment.switchLibrary(to: nil), .switched)
        try openPicker()
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["a.md"])
    }

    func testReplacementResetsAvailabilityAndTheWarningLatch() throws {
        try files.write(Data("Cached Alpha".utf8), at: "a.md")
        let second = try library("B", prompts: ["b.md": "Cached Beta"])
        try openPicker()
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.pickerModel.libraryAvailable })
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        try openPicker()
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        try FileManager.default.removeItem(at: second)
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.pickerModel.libraryAvailable })
        XCTAssertEqual(environment.pickerModel.selectedPreview, .body("Cached Beta"))
        let log = try String(contentsOf: paths.dataDirectory.appendingPathComponent("logs/monkeyspaw.log"), encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").filter { $0.contains("Library unavailable (notFound)") }.count, 2)
    }

    func testPromptCreationUsesOnlyTheReplacementLibrary() throws {
        try files.write(Data("Alpha".utf8), at: "a.md")
        let second = try library("B")
        try openPicker()
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        try openPicker()
        environment.pickerModel.setQuery("New prompt")
        let label = try XCTUnwrap(environment.pickerModel.noMatches?.createLabel)
        let create = try widget(matching: {
            mp_is_button($0) != 0 && gtk_button_get_label(mp_button($0)).map { String(cString: $0) } == label
        })
        XCTAssertNotEqual(gtk_widget_activate(create), 0)
        let target = second.appendingPathComponent("New prompt.md")
        XCTAssertTrue(GTKTestSupport.spin { self.launchedURLs == [target] })
        XCTAssertFalse(environment.panel.isVisible)
        XCTAssertEqual(environment.pickerModel.state, .closed)
        XCTAssertNil(try files.stamp(at: "New prompt.md"))
        let created = PromptCodec.parseFile(try RootedFileStore(root: second).read(at: "New prompt.md"), filename: "New prompt.md")
        XCTAssertEqual(created.frontMatter.title, "New prompt")
        XCTAssertEqual(created.body, LinuxStrings.newPromptBody)
        try openPicker()
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["New prompt.md"])
    }

    func testPersistedChoiceIsUsedOnNextLaunchAndDefaultKeepsProgress() throws {
        try files.write(Data("Alpha".utf8), at: "a.md")
        let second = try library("B", prompts: ["b.md": "Beta"])
        environment.settingsModel.markSetupPresented()
        environment.settingsModel.completeLibraryFolderStep()
        environment.settingsModel.markSeedsOffered()
        let progress = environment.settingsModel.firstRun
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        XCTAssertEqual(environment.settingsModel.libraryFolderPath, second.path)
        try relaunch()
        try openPicker()
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["b.md"])
        XCTAssertEqual(environment.settingsModel.firstRun, progress)
        XCTAssertEqual(environment.switchLibrary(to: nil), .switched)
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
        XCTAssertEqual(environment.settingsModel.firstRun, progress)
        try relaunch()
        try openPicker()
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["a.md"])
    }

    func testSettingsWriteFailureKeepsNewGraphForTheSessionAndReportsTheError() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        try files.write(Data("Alpha".utf8), at: "a.md")
        let second = try library("B", prompts: ["b.md": "Beta"])
        environment.settingsModel.markSetupPresented()
        let config = try RootedFileStore(root: paths.configDirectory)
        let saved = try config.read(at: "settings.json")
        try openPicker()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.configDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.configDirectory.path) }
        XCTAssertEqual(environment.switchLibrary(to: second), .persistenceFailed(.writeFailed(.ioFailure)))
        XCTAssertEqual(environment.settingsModel.error, .writeFailed(.ioFailure))
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
        XCTAssertEqual(try config.read(at: "settings.json"), saved)
        try openPicker()
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["b.md"])
        try relaunch()
        try openPicker()
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["a.md"])
    }

    func testLegacySetupImportLeavesTheLibraryStepPending() throws {
        try LinuxFirstRunState(paths: paths).recordPresentation()
        XCTAssertFalse(environment.settingsModel.needsSetupPresentation)
        XCTAssertTrue(environment.settingsModel.needsLibraryFolderStep)
        XCTAssertFalse(environment.settingsModel.firstRun.libraryFolderCompleted)
        environment.presentFromLauncher()
        XCTAssertTrue(GTKTestSupport.spin {
            guard let window = gtk_application_get_active_window(self.application),
                  let title = gtk_window_get_title(window) else { return false }
            return String(cString: title) == LinuxStrings.onboarding
                && gtk_widget_get_visible(mp_window_widget(window)) != 0
        })
        XCTAssertFalse(environment.panel.isVisible)
        XCTAssertTrue(environment.settingsModel.needsLibraryFolderStep)
    }

    func testReadOnlySettingsUseTheDefaultWithoutRewritingFutureOrCorruptFiles() throws {
        try files.write(Data("Default".utf8), at: "default.md")
        let config = try RootedFileStore(root: paths.configDirectory)
        for (source, failure) in [("{\"version\":999}", SettingsError.futureVersion(999)), ("broken", .corruptFile)] {
            try config.write(Data(source.utf8), at: "settings.json")
            try relaunch()
            XCTAssertTrue(environment.settingsModel.isReadOnly)
            XCTAssertEqual(environment.settingsModel.error, failure)
            environment.presentFromLauncher()
            XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
            XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["default.md"])
            XCTAssertEqual(try config.read(at: "settings.json"), Data(source.utf8))
        }
    }

    func testSymlinkedDefaultLibraryStillLoadsAndCanBeReselected() throws {
        // Users may link the default folder into a synced directory; only a
        // chosen folder must not be a symlink itself.
        let target = try library("Synced", prompts: ["s.md": "Synced"])
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        try openPicker()
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["s.md"])

        XCTAssertEqual(environment.switchLibrary(to: nil), .switched)
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        try openPicker()
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["s.md"])
    }

    func testUnusedEnvironmentShutdownDoesNotConstructTheLibraryOrPanel() {
        XCTAssertNil(gtk_application_get_windows(application))
        environment.shutdown()
        XCTAssertNil(gtk_application_get_windows(application))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configDirectory.path))
    }

    private func compose(scheduler: Scheduler? = nil,
                         focusTracker: FocusTracker? = nil,
                         watcherFactory: ((URL) throws -> FileStoreWatcher)? = nil) {
        environment?.shutdown()
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            scheduler: scheduler, focusTracker: focusTracker, libraryWatcherFactory: watcherFactory,
            launchURI: { [weak self] url in self?.launchedURLs.append(url) })
    }

    private func relaunch() throws {
        // Delivery's shared dismissal queue owns the old panel until its hide
        // runs. A real switch keeps that window; this simulated process restart
        // must finish queued UI work before destroying the old application.
        drainUI()
        environment.shutdown()
        environment = nil
        GTKTestSupport.destroy(application)
        application = try GTKTestSupport.application()
        compose()
    }

    private func library(_ name: String, prompts: [String: String] = [:]) throws -> URL {
        let directory = tools.directory.appendingPathComponent(name, isDirectory: true)
        let store = try RootedFileStore(root: directory)
        try store.createRoot()
        for (path, source) in prompts { try store.write(Data(source.utf8), at: path) }
        return directory
    }

    private func openPicker() throws {
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        XCTAssertEqual(environment.pickerModel.state, .picker)
    }

    private func drainUI() {
        var drained = false
        environment.mainThread.run { drained = true }
        XCTAssertTrue(GTKTestSupport.spin { drained })
    }

    private func drainNativeEvents() {
        // Cover GTK's delayed button activation and native monitor/idle work.
        var drained = false
        GTK.after(0.4) { drained = true }
        XCTAssertTrue(GTKTestSupport.spin { drained })
    }

    private func widget(named name: String) throws -> GTK.Widget {
        try widget(matching: { String(cString: gtk_widget_get_name($0)) == name })
    }

    private func widget(matching predicate: (GTK.Widget) -> Bool) throws -> GTK.Widget {
        func find(_ widget: GTK.Widget) -> GTK.Widget? {
            if predicate(widget) { return widget }
            var child = gtk_widget_get_first_child(widget)
            while let current = child {
                if let found = find(current) { return found }
                child = gtk_widget_get_next_sibling(current)
            }
            return nil
        }
        return try XCTUnwrap(find(environment.panel.clipboardOwner), "Missing GTK control")
    }
}

private final class SwitchFocusTracker: FocusTracker {
    private(set) var restoredTargets: [DeliveryTarget] = []
    private var pending: ((FocusConfirmation) -> Void)?
    private var isHolding = true

    func captureTarget() -> DeliveryTarget? { .linux(session: .otherX11, x11WindowClass: "External") }

    func restore(_ target: DeliveryTarget, completion: @escaping (FocusConfirmation) -> Void) {
        restoredTargets.append(target)
        guard isHolding else { completion(.unconfirmed); return }
        pending = completion
    }

    func release() {
        isHolding = false
        let completion = pending
        pending = nil
        completion?(.unconfirmed)
    }
}

private final class SwitchScheduler: Scheduler {
    private(set) var delays: [Duration] = []
    private var pending: [() -> Void] = []
    var hasPending: Bool { !pending.isEmpty }

    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        delays.append(delay)
        pending.append(work)
    }

    func fireAll() {
        let callbacks = pending
        pending = []
        callbacks.forEach { $0() }
    }
}

private final class SwitchWatcher: FileStoreWatcher {
    private let onStart: () throws -> Void
    private var callback: (@Sendable (FileStoreWatchEvent) -> Void)?
    private(set) var stopCount = 0

    init(onStart: @escaping () throws -> Void = {}) { self.onStart = onStart }
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {
        callback = onEvent
        try onStart()
    }
    func stop() { stopCount += 1 }
    func emit(_ update: FileStoreWatchEvent) { callback?(update) }
}
#endif
