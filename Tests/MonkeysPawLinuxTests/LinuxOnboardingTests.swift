#if os(Linux)
import CGtk
import Foundation
import Glibc
@testable import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxOnboardingTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var paths: LinuxPaths!
    private var chooser: SettingsFolderChooser!
    private var notifications: OnboardingNotifications!

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
        notifications = OnboardingNotifications()
        compose()
    }

    override func tearDown() {
        environment?.shutdown()
        environment = nil
        drainUI()
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        chooser = nil
        notifications = nil
        tools = nil
    }

    func testFreshInstallContinuesFromSetupSeedsOnceAndRestartsWithoutOnboarding() throws {
        environment.presentFromLauncher()
        let setup = try visibleWindow(titled: LinuxStrings.setup)
        drainUI()
        XCTAssertTrue(environment.settingsModel.firstRun.setupPresented)
        XCTAssertTrue(windows(titled: LinuxStrings.onboarding).isEmpty)
        gtk_window_close(mp_window(setup))
        let onboarding = try visibleWindow(titled: LinuxStrings.onboarding)
        XCTAssertEqual(gtk_window_get_hide_on_close(mp_window(onboarding)), 1)
        XCTAssertEqual(try label("onboarding-library-path", in: onboarding), defaultFolder.path)
        XCTAssertEqual(gtk_label_get_selectable(mp_label(try settingsWidget("onboarding-library-path", in: onboarding))), 1)
        XCTAssertFalse(environment.panel.isVisible)
        try click("onboarding-use-default", in: onboarding)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.step == .seedOffer })
        XCTAssertTrue(environment.settingsModel.firstRun.libraryFolderCompleted)
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
        XCTAssertFalse(environment.settingsModel.firstRun.seedsOffered)
        try click("onboarding-accept-seeds", in: onboarding)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.seedSummary != nil })
        let summary = try XCTUnwrap(environment.onboardingModel.state.seedSummary)
        XCTAssertEqual(summary.seededCount, SeedCatalog.prompts.count)
        XCTAssertEqual(summary.skippedExistingCount, 0)
        XCTAssertEqual(try label("onboarding-seed-summary", in: onboarding), OnboardingStrings.seedSummary(summary))
        XCTAssertEqual(environment.onboardingModel.state.step, .complete)
        XCTAssertTrue(environment.settingsModel.firstRun.seedsOffered)
        let files = try RootedFileStore(root: defaultFolder)
        let before = try SeedCatalog.prompts.map { try files.read(at: $0.relativePath) }
        try click("onboarding-close", in: onboarding)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(onboarding) == 0 })
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.results.count == SeedCatalog.prompts.count })
        XCTAssertTrue(environment.panel.isVisible)
        try relaunch()
        environment.presentFromLauncher()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isVisible })
        XCTAssertTrue(windows(titled: LinuxStrings.onboarding).isEmpty)
        XCTAssertTrue(windows(titled: LinuxStrings.setup).isEmpty)
        XCTAssertEqual(try SeedCatalog.prompts.map { try files.read(at: $0.relativePath) }, before)
        XCTAssertEqual(notifications.count, 0)
    }

    func testDecliningSeedsRecordsTheOfferWithoutCopyingOrRepeatingIt() throws {
        let window = try folderStep()
        try click("onboarding-use-default", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.step == .seedOffer })
        try click("onboarding-decline-seeds", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.step == .complete })
        XCTAssertTrue(environment.settingsModel.firstRun.seedsOffered)
        XCTAssertNil(environment.onboardingModel.state.seedSummary)
        XCTAssertTrue(try RootedFileStore(root: defaultFolder).listFiles().isEmpty)
        try relaunch()
        environment.presentFromLauncher()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isVisible })
        XCTAssertTrue(windows(titled: LinuxStrings.onboarding).isEmpty)
    }

    func testChoosingAnEmptyFolderSeedsOnlyTheCurrentGraphAndKeepsSettingsObservers() throws {
        environment.showSettings()
        let settings = try visibleWindow(titled: LinuxStrings.settings)
        gtk_window_close(mp_window(settings))
        let window = try folderStep()
        let second = try library("Chosen")
        try choose(second.path, in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.step == .seedOffer })
        XCTAssertEqual(environment.settingsModel.libraryFolderPath, second.path)
        XCTAssertTrue(GTKTestSupport.spin {
            (try? self.label("onboarding-library-path", in: window)) == second.path
                && self.environment.generalSettingsModel.state.activeLibraryPath == second.path
        })
        try click("onboarding-accept-seeds", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.seedSummary != nil })
        let chosen = try RootedFileStore(root: second)
        for seed in SeedCatalog.prompts { XCTAssertNotNil(try chosen.stamp(at: seed.relativePath)) }
        XCTAssertTrue(try RootedFileStore(root: defaultFolder).listFiles().isEmpty)
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.results.count == SeedCatalog.prompts.count })
        environment.showSettings()
        _ = try visibleWindow(titled: LinuxStrings.settings)
        XCTAssertEqual(try label("settings-library-path", in: settings), second.path)
    }

    func testInvalidFolderShowsTypedCopyAndDoesNotCompleteTheFolderStep() throws {
        let window = try folderStep()
        for (path, error) in [(tools.directory.appendingPathComponent("missing").path, FileStoreError.notFound),
                              ("relative-folder", .invalidRoot)] {
            try choose(path, in: window)
            let outcome = LibrarySwitchOutcome.invalidTarget(.rejectedByStore(error))
            XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.lastSwitchMessage == outcome })
            XCTAssertEqual(try label("onboarding-library-message", in: window), GeneralSettingsStrings.message(for: outcome))
            XCTAssertEqual(try label("onboarding-library-path", in: window), defaultFolder.path)
            XCTAssertEqual(environment.onboardingModel.state.step, .libraryFolder)
            XCTAssertFalse(environment.settingsModel.firstRun.libraryFolderCompleted)
            XCTAssertNil(environment.settingsModel.libraryFolderPath)
        }
    }

    func testLegacySetupMarkerResumesAtFolderWithoutShowingSetup() throws {
        try LinuxFirstRunState(paths: paths).recordPresentation()
        environment.presentFromLauncher()
        _ = try visibleWindow(titled: LinuxStrings.onboarding)
        XCTAssertEqual(environment.onboardingModel.state.step, .libraryFolder)
        XCTAssertTrue(windows(titled: LinuxStrings.setup).isEmpty)
        XCTAssertFalse(environment.settingsModel.firstRun.libraryFolderCompleted)
        XCTAssertFalse(environment.panel.isVisible)
    }

    func testCompletedFolderWithPendingOfferResumesAtSeedsOnLaunch() throws {
        environment.settingsModel.markSetupPresented()
        environment.settingsModel.completeLibraryFolderStep()
        try relaunch()
        environment.presentFromLauncher()
        let window = try visibleWindow(titled: LinuxStrings.onboarding)
        XCTAssertEqual(environment.onboardingModel.state.step, .seedOffer)
        XCTAssertNotEqual(gtk_widget_get_visible(try settingsWidget("onboarding-accept-seeds", in: window)), 0)
        XCTAssertTrue(windows(titled: LinuxStrings.setup).isEmpty)
    }

    func testEligibleMalformedPromptSkipsSeedsWithoutConsumingTheOffer() throws {
        try RootedFileStore(root: defaultFolder).write(Data("---\nfields: [\n---\nInvalid".utf8), at: "invalid.md")
        let window = try folderStep()
        try click("onboarding-use-default", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.step == .complete })
        XCTAssertFalse(environment.settingsModel.firstRun.seedsOffered)
        XCTAssertNil(environment.onboardingModel.state.seedSummary)
        XCTAssertEqual(try RootedFileStore(root: defaultFolder).listFiles().map(\.relativePath), ["invalid.md"])
    }

    func testMissingChosenFolderNotifiesOnceAndRecoverySurvivesClosingTheWindow() throws {
        let missing = tools.directory.appendingPathComponent("missing")
        completeProgress()
        environment.settingsModel.setLibraryFolder(missing.path)
        try relaunch()
        environment.start()
        let window = try visibleWindow(titled: LinuxStrings.onboarding)
        XCTAssertEqual(environment.libraryStatusModel.state, .unavailableAtStartup)
        XCTAssertEqual(environment.onboardingModel.state.step, .libraryFolder)
        XCTAssertTrue(environment.settingsModel.firstRun.libraryFolderCompleted)
        XCTAssertTrue(environment.settingsModel.firstRun.seedsOffered)
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(try label("onboarding-library-path", in: window), missing.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        gtk_window_close(mp_window(window))
        environment.presentFromLauncher()
        XCTAssertEqual(try visibleWindow(titled: LinuxStrings.onboarding), window)
        let recovered = try library("Recovered", prompt: "Recovered prompt")
        try choose(recovered.path, in: window)
        XCTAssertTrue(GTKTestSupport.spin {
            self.environment.libraryStatusModel.state == .available && self.environment.onboardingModel.state.step == .complete
        })
        XCTAssertEqual(environment.libraryStatusModel.menuLabel, OnboardingStrings.libraryAvailableMenu)
        XCTAssertEqual(notifications.count, 1)
        try click("onboarding-close", in: window)
        environment.presentFromLauncher()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isVisible })
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["prompt.md"])
        try relaunch()
        environment.presentFromLauncher()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isVisible })
        XCTAssertTrue(windows(titled: LinuxStrings.onboarding).isEmpty)
    }

    func testUnreadableChosenFolderOpensRecoveryAndCanUseTheDefault() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        let unreadable = try library("Unreadable")
        completeProgress()
        environment.settingsModel.setLibraryFolder(unreadable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
        try relaunch()
        environment.presentFromLauncher()
        let window = try visibleWindow(titled: LinuxStrings.onboarding)
        XCTAssertEqual(notifications.count, 1)
        XCTAssertFalse(environment.pickerModel.libraryAvailable)
        XCTAssertEqual(environment.libraryStatusModel.menuLabel, OnboardingStrings.libraryUnavailableMenu)
        try click("onboarding-use-default", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryStatusModel.state == .available })
        XCTAssertEqual(environment.onboardingModel.state.step, .complete)
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
    }

    func testWatcherStartupFailureCountsAsStartupUnavailability() throws {
        completeProgress()
        compose(watcherFactory: { _ in OnboardingWatcher(startFailure: .ioFailure) })
        environment.presentFromLauncher()
        _ = try visibleWindow(titled: LinuxStrings.onboarding)
        XCTAssertEqual(environment.libraryStatusModel.state, .unavailableAtStartup)
        XCTAssertEqual(notifications.count, 1)
        XCTAssertFalse(environment.pickerModel.libraryAvailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultFolder.path))
    }

    func testRuntimeLossKeepsCachedPromptsAndOnlyAHealthySwitchRestoresStatus() throws {
        completeProgress()
        try RootedFileStore(root: defaultFolder).write(Data("Cached prompt".utf8), at: "cached.md")
        environment.presentFromLauncher()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isVisible })
        let status = environment.libraryStatusModel
        XCTAssertEqual(status.state, .available)
        try FileManager.default.removeItem(at: defaultFolder)
        XCTAssertTrue(GTKTestSupport.spin { status.state == .lostWhileRunning })
        XCTAssertEqual(status.menuLabel, OnboardingStrings.libraryUnavailableMenu)
        XCTAssertEqual(environment.pickerModel.results.map(\.relativePath), ["cached.md"])
        XCTAssertFalse(environment.pickerModel.libraryAvailable)
        XCTAssertEqual(environment.onboardingModel.state.step, .complete)
        XCTAssertTrue(windows(titled: LinuxStrings.onboarding).isEmpty)
        XCTAssertEqual(notifications.count, 0)
        try RootedFileStore(root: defaultFolder).write(Data("Restored".utf8), at: "restored.md")
        drainUI()
        XCTAssertEqual(status.state, .lostWhileRunning)
        let recovered = try library("AfterRuntimeLoss", prompt: "Recovered")
        XCTAssertEqual(environment.switchLibrary(to: recovered), .switched)
        XCTAssertTrue(GTKTestSupport.spin { status.state == .available })
        XCTAssertTrue(environment.libraryStatusModel === status)
        XCTAssertEqual(status.menuLabel, OnboardingStrings.libraryAvailableMenu)
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.results.map(\.relativePath) == ["prompt.md"] })
        XCTAssertEqual(notifications.count, 0)
    }

    func testRetiredWatcherCannotChangeTheReplacementStatus() throws {
        completeProgress()
        let old = OnboardingWatcher()
        let second = try library("NewGraph", prompt: "New")
        compose(watcherFactory: { directory in directory == self.defaultFolder ? old : OnboardingWatcher() })
        environment.presentFromLauncher()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isVisible })
        let status = environment.libraryStatusModel
        old.emit(.rootUnavailable(.notFound))
        XCTAssertEqual(environment.switchLibrary(to: second), .switched)
        old.emit(.rootUnavailable(.outsideRoot))
        drainUI()
        XCTAssertEqual(status.state, .available)
        XCTAssertTrue(environment.pickerModel.libraryAvailable)
        XCTAssertEqual(notifications.count, 0)
    }

    func testReadOnlySettingsSuppressSetupAndOnboardingWithoutRewritingSettings() throws {
        let config = try RootedFileStore(root: paths.configDirectory)
        let future = Data("{\"version\":999}".utf8)
        try config.write(future, at: "settings.json")
        compose()
        environment.presentFromLauncher()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isVisible })
        XCTAssertTrue(environment.onboardingModel.state.isReadOnly)
        XCTAssertEqual(environment.onboardingModel.state.settingsError, .futureVersion(999))
        XCTAssertEqual(environment.onboardingModel.state.step, .complete)
        XCTAssertTrue(windows(titled: LinuxStrings.onboarding).isEmpty)
        XCTAssertTrue(windows(titled: LinuxStrings.setup).isEmpty)
        environment.showSettings()
        let settings = try visibleWindow(titled: LinuxStrings.settings)
        XCTAssertEqual(try label("settings-general-error", in: settings), GeneralSettingsStrings.settingsError(.futureVersion(999)))
        XCTAssertEqual(try config.read(at: "settings.json"), future)
    }

    func testSeedWriteFailureShowsTypedCopyAndDoesNotRepeatAfterRestart() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        let window = try folderStep()
        try click("onboarding-use-default", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.step == .seedOffer })
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: defaultFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: defaultFolder.path) }
        try click("onboarding-accept-seeds", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.seedFailure != nil })
        let failure = try XCTUnwrap(environment.onboardingModel.state.seedFailure)
        XCTAssertEqual(try label("onboarding-seed-failure", in: window), OnboardingStrings.seedFailure(failure))
        XCTAssertTrue(environment.settingsModel.firstRun.seedsOffered)
        XCTAssertEqual(environment.onboardingModel.state.step, .complete)
        XCTAssertTrue(try RootedFileStore(root: defaultFolder).listFiles().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: defaultFolder.path)
        try relaunch()
        environment.presentFromLauncher()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isVisible })
        XCTAssertTrue(windows(titled: LinuxStrings.onboarding).isEmpty)
        XCTAssertTrue(try RootedFileStore(root: defaultFolder).listFiles().isEmpty)
    }

    func testFailedSeedOfferRecordingCopiesNothingAndLeavesTheOfferPending() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        let window = try folderStep()
        try click("onboarding-use-default", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.step == .seedOffer })
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.configDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.configDirectory.path) }
        try click("onboarding-accept-seeds", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.settingsError != nil })
        XCTAssertEqual(environment.onboardingModel.state.step, .seedOffer)
        XCTAssertFalse(environment.settingsModel.firstRun.seedsOffered)
        XCTAssertNil(environment.onboardingModel.state.seedSummary)
        XCTAssertTrue(try RootedFileStore(root: defaultFolder).listFiles().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.configDirectory.path)
        try click("onboarding-decline-seeds", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.onboardingModel.state.step == .complete })
    }

    func testCancelledAndStaleChooserResponsesCannotSwitchAfterClosingAndReopening() throws {
        let window = try folderStep()
        let second = try library("StaleChoice", prompt: "Keep out")
        try click("onboarding-choose-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == 1 })
        let button = try settingsWidget("onboarding-choose-folder", in: window)
        XCTAssertEqual(gtk_widget_get_sensitive(button), 0)
        chooser.requests[0].done(nil)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_sensitive(button) != 0 })
        try click("onboarding-choose-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == 2 })
        let old = chooser.requests[1].done
        old(second.path)
        gtk_window_close(mp_window(window))
        environment.presentFromLauncher()
        XCTAssertEqual(try visibleWindow(titled: LinuxStrings.onboarding), window)
        drainUI()
        XCTAssertEqual(try label("onboarding-library-path", in: window), defaultFolder.path)
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
        try click("onboarding-choose-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == 3 })
        old(second.path)
        drainUI()
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
        chooser.requests[2].done(second.path)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.settingsModel.libraryFolderPath == second.path })
        XCTAssertEqual(environment.onboardingModel.state.step, .complete)
    }

    func testDestroyedWindowIgnoresQueuedChooserAndDetachedButtons() throws {
        let window = try folderStep()
        let acceptDefault = try settingsWidget("onboarding-use-default", in: window)
        g_object_ref(acceptDefault)
        defer { g_object_unref(acceptDefault) }
        let second = try library("DestroyedChoice")
        try click("onboarding-choose-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == 1 })
        let done = chooser.requests[0].done
        done(second.path)
        gtk_window_destroy(mp_window(window))
        done(second.path)
        _ = gtk_widget_activate(acceptDefault)
        environment.presentFromLauncher()
        drainUI()
        XCTAssertTrue(windows(titled: LinuxStrings.onboarding).isEmpty)
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
        XCTAssertFalse(environment.settingsModel.firstRun.libraryFolderCompleted)
    }

    func testShutdownRejectsQueuedLaunchAndSetupContinuation() throws {
        environment.presentFromLauncher()
        environment.shutdown()
        drainUI()
        XCTAssertTrue(windows(titled: LinuxStrings.setup).isEmpty)
        XCTAssertTrue(windows(titled: LinuxStrings.onboarding).isEmpty)
        try relaunch()
        environment.presentFromLauncher()
        let setup = try visibleWindow(titled: LinuxStrings.setup)
        gtk_window_close(mp_window(setup))
        environment.shutdown()
        drainUI()
        XCTAssertTrue(windows(titled: LinuxStrings.onboarding).isEmpty)
    }

    func testSettingsAndOnboardingRetireOnlyTheirOwnChooserRequests() throws {
        let onboarding = try folderStep()
        let second = try library("SharedChooser", prompt: "Chosen prompt")
        try click("onboarding-choose-folder", in: onboarding)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == 1 })
        let oldOnboarding = chooser.requests[0].done
        environment.showSettings()
        let settings = try visibleWindow(titled: LinuxStrings.settings)
        XCTAssertEqual(gtk_widget_get_visible(onboarding), 0)
        oldOnboarding(second.path)
        drainUI()
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
        try click("settings-choose-folder", in: settings)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == 2 })
        let oldSettings = chooser.requests[1].done
        environment.presentFromLauncher()
        XCTAssertEqual(try visibleWindow(titled: LinuxStrings.onboarding), onboarding)
        XCTAssertEqual(gtk_widget_get_visible(settings), 0)
        oldSettings(second.path)
        drainUI()
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
        try click("onboarding-choose-folder", in: onboarding)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == 3 })
        let cancellationCount = chooser.cancelCount
        // Raising onboarding must not let a hidden Settings wrapper cancel it.
        environment.presentFromLauncher()
        _ = try visibleWindow(titled: LinuxStrings.onboarding)
        drainUI()
        XCTAssertEqual(chooser.cancelCount, cancellationCount)
        chooser.requests[2].done(second.path)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.settingsModel.libraryFolderPath == second.path })
    }

    func testSettingsRequestSupersedesQueuedSetupCloseContinuation() throws {
        environment.presentFromLauncher()
        let setup = try visibleWindow(titled: LinuxStrings.setup)
        gtk_window_close(mp_window(setup))
        environment.showSettings()
        let settings = try visibleWindow(titled: LinuxStrings.settings)
        drainUI()
        XCTAssertTrue(windows(titled: LinuxStrings.onboarding).isEmpty)
        XCTAssertNotEqual(gtk_widget_get_visible(settings), 0)
    }

    func testRuntimeLossDuringFolderStepDisablesChoicesAndShowsRestartGuidance() throws {
        let window = try folderStep()
        try click("onboarding-choose-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == 1 })
        try FileManager.default.removeItem(at: defaultFolder)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.libraryStatusModel.state == .lostWhileRunning })
        XCTAssertEqual(try label("onboarding-library-status", in: window), OnboardingStrings.restartForLibrary)
        for name in ["onboarding-choose-folder", "onboarding-use-default"] {
            XCTAssertEqual(gtk_widget_get_sensitive(try settingsWidget(name, in: window)), 0)
        }
        XCTAssertGreaterThan(chooser.cancelCount, 0)
        chooser.requests[0].done(try library("LostDuringChoice").path)
        drainUI()
        XCTAssertNil(environment.settingsModel.libraryFolderPath)
        XCTAssertFalse(environment.settingsModel.firstRun.libraryFolderCompleted)
        XCTAssertEqual(notifications.count, 0)
    }

    func testRetainedOnboardingAndStatusModelsDoNotRetainTheEnvironment() throws {
        _ = try folderStep()
        let model = environment.onboardingModel
        let status = environment.libraryStatusModel
        weak var lifetime = environment
        environment.shutdown()
        environment = nil
        drainUI()
        XCTAssertNil(lifetime)
        lifetime = nil
        model.refresh()
        model.useDefaultFolder()
        status.update(.lostWhileRunning)
        drainUI()
        XCTAssertEqual(model.state.lastSwitchMessage, .libraryUnavailable(.ioFailure))
    }

    private var defaultFolder: URL {
        paths.documentsDirectory.appendingPathComponent("MonkeysPaw", isDirectory: true)
    }

    private func compose(watcherFactory: ((URL) throws -> FileStoreWatcher)? = nil) {
        environment?.shutdown()
        environment = nil
        drainUI()
        environment = LinuxEnvironment(application: application, environment: tools.environment,
            libraryWatcherFactory: watcherFactory, folderChooser: chooser, libraryAvailabilityNotifier: notifications)
    }

    private func relaunch() throws {
        environment.shutdown()
        environment = nil
        drainUI()
        GTKTestSupport.destroy(application)
        application = try GTKTestSupport.application()
        compose()
    }

    private func completeProgress() {
        environment.settingsModel.markSetupPresented()
        environment.settingsModel.completeLibraryFolderStep()
        environment.settingsModel.markSeedsOffered()
    }

    private func folderStep() throws -> GTK.Widget {
        environment.settingsModel.markSetupPresented()
        environment.presentFromLauncher()
        let window = try visibleWindow(titled: LinuxStrings.onboarding)
        XCTAssertEqual(environment.onboardingModel.state.step, .libraryFolder)
        return window
    }

    private func library(_ name: String, prompt: String? = nil) throws -> URL {
        let root = tools.directory.appendingPathComponent(name, isDirectory: true)
        let files = try RootedFileStore(root: root)
        try files.createRoot()
        if let prompt { try files.write(Data(prompt.utf8), at: "prompt.md") }
        return root
    }

    private func windows(titled title: String) -> [GTK.Widget] {
        var result: [GTK.Widget] = []
        var node = gtk_application_get_windows(application)
        while let current = node {
            if let data = current.pointee.data {
                let window = data.assumingMemoryBound(to: GtkWindow.self)
                if gtk_window_get_title(window).map({ String(cString: $0) }) == title {
                    result.append(mp_window_widget(window))
                }
            }
            node = current.pointee.next
        }
        return result
    }

    private func visibleWindow(titled title: String) throws -> GTK.Widget {
        XCTAssertTrue(GTKTestSupport.spin { self.windows(titled: title).contains { gtk_widget_get_visible($0) != 0 } })
        return try XCTUnwrap(windows(titled: title).first { gtk_widget_get_visible($0) != 0 })
    }

    private func label(_ name: String, in window: GTK.Widget) throws -> String {
        String(cString: gtk_label_get_text(mp_label(try settingsWidget(name, in: window))))
    }

    private func click(_ name: String, in window: GTK.Widget) throws {
        XCTAssertNotEqual(gtk_widget_activate(try settingsWidget(name, in: window)), 0)
    }

    private func choose(_ path: String, in window: GTK.Widget) throws {
        let count = chooser.requests.count
        try click("onboarding-choose-folder", in: window)
        XCTAssertTrue(GTKTestSupport.spin { self.chooser.requests.count == count + 1 })
        let request = try XCTUnwrap(chooser.requests.last)
        XCTAssertEqual(request.parent, window)
        XCTAssertEqual(request.currentPath, try label("onboarding-library-path", in: window))
        request.done(path)
    }

    private func drainUI() {
        var drained = false
        GTK.onMainLoop { drained = true }
        XCTAssertTrue(GTKTestSupport.spin { drained })
    }
}

private final class OnboardingNotifications: LibraryAvailabilityNotifier {
    private(set) var count = 0
    func libraryUnavailable() { count += 1 }
}

/// Retain callbacks after stop to prove generation guards protect new graphs.
private final class OnboardingWatcher: FileStoreWatcher {
    private let startFailure: FileStoreError?
    private var callback: (@Sendable (FileStoreWatchEvent) -> Void)?

    init(startFailure: FileStoreError? = nil) { self.startFailure = startFailure }
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {
        if let startFailure { throw startFailure }
        callback = onEvent
    }
    func stop() {}
    func emit(_ event: FileStoreWatchEvent) { callback?(event) }
}
#endif
