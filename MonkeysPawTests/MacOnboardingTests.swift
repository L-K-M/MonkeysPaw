import AppKit
import Darwin
import MonkeysPawCore
import SwiftUI
import UserNotifications
import XCTest
@testable import MonkeysPaw

/// Exercise the production launch flow explicitly: hosted launch itself stays
/// inert. Every file, chooser result, watcher and notification is isolated.
final class MacOnboardingTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var delegate: AppDelegate!
    private var originalWindows: Set<ObjectIdentifier> = []
    private var notificationDelegate: UNUserNotificationCenterDelegate?
    private var watchers: [OnboardingWatcher] = []
    private var chooserCompletions: [(URL?) -> Void] = []
    private var chooserCancellations = 0
    private var notifications: [UNNotificationRequest] = []
    private var revealed: [URL] = []
    private var legacyWrites = 0
    private var policies: [NSApplication.ActivationPolicy] = []
    private var activations = 0

    override func setUpWithError() throws {
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        notificationDelegate = UNUserNotificationCenter.current().delegate
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("default", isDirectory: true)
        data = directory.appendingPathComponent("data", isDirectory: true)
    }

    override func tearDown() {
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate = nil // Deferred Setup-close callbacks must not start another flow.
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        chooserCompletions = []
        watchers = []
        UNUserNotificationCenter.current().delegate = notificationDelegate
        try? FileManager.default.removeItem(at: directory)
    }

    private func start(legacy: LegacyFirstRun = .setupNotPresented,
                       chooser: SettingsWindowController.FolderChooser? = nil,
                       watcherStart: @escaping (URL) throws -> Void = { _ in }) {
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate = AppDelegate(libraryRoot: root, dataRoot: data, legacyFirstRun: legacy,
            recordLegacySetup: { [weak self] in self?.legacyWrites += 1 }, launchURI: { _ in
                XCTFail("Onboarding must not open an editor")
            }, revealLibrary: { [weak self] in self?.revealed.append($0) },
            folderChooser: chooser ?? { [weak self] _, done in
                self?.chooserCompletions.append(done)
                return { [weak self] in
                    self?.chooserCancellations += 1
                    done(nil) // Cancellation can reply inline.
                }
            }, makeNotifier: { [weak self] in
                UserNotificationNotifier(requestAuthorization: { _, done in done(true) },
                    submit: { [weak self] _, request in self?.notifications.append(request) })
            }, setActivationPolicy: { [weak self] in self?.policies.append($0) },
            activateApplication: { [weak self] in self?.activations += 1 },
            makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in
                    XCTFail("Onboarding must not restore an external target")
                    return false
                }), mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, makeFileWatcher: { [weak self] url, _ in
                let watcher = OnboardingWatcher { try watcherStart(url) }
                self?.watchers.append(watcher)
                return watcher
            })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    private func model() throws -> OnboardingModel { try XCTUnwrap(delegate.onboardingModel) }
    private func controller() throws -> OnboardingWindowController { try XCTUnwrap(delegate.onboardingWindow) }
    private func window() throws -> NSWindow { try XCTUnwrap(controller().window) }
    private func setupWindow() throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first {
            !originalWindows.contains(ObjectIdentifier($0)) && $0.title == Strings.setupTitle
        })
    }
    private func presentation() throws -> OnboardingViewState {
        // Headless hosts build SwiftUI's accessibility tree lazily. Check the
        // actual hosted view's binding, then drive its state and intents.
        let controller = try controller()
        let window = try XCTUnwrap(controller.window)
        let hosting = try XCTUnwrap(window.contentView as? NSHostingView<OnboardingView>)
        XCTAssertTrue(hosting.rootView.presentation === controller.presentation)
        return controller.presentation
    }

    private func files(at url: URL) throws -> RootedFileStore {
        let files = try RootedFileStore(root: url)
        try files.createRoot()
        return files
    }

    private func saveProgress(folder: URL? = nil, folderCompleted: Bool = true,
                              seedsOffered: Bool = true, tourCompleted: Bool = true) throws {
        let service = SettingsService(store: SettingsStore(files: try files(at: data)))
        try service.setLibraryFolder(folder?.path)
        try service.markSetupPresented()
        if folderCompleted { try service.completeLibraryFolderStep() }
        if seedsOffered { try service.markSeedsOffered() }
        if tourCompleted { try service.completeTour() }
    }

    func testSetupCloseAfterTerminationCannotResumeOnboarding() throws {
        start()
        delegate.beginOnboarding()
        let setup = try setupWindow()
        let setupController = try XCTUnwrap(setup.delegate as? SetupWindowController)
        let continuation = try XCTUnwrap(setupController.onClose)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertNil(setupController.onClose)
        XCTAssertNil(setup.delegate)
        XCTAssertFalse(setup.isVisible)

        setup.close()
        continuation() // Even an already-retained continuation must be inert.
        delegate.beginOnboarding()
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        drainMainQueue()
        XCTAssertNil(try controller().window)
        XCTAssertEqual(delegate.pickerModel?.state, .closed)
    }

    func testQueuedSetupCloseCannotResumeAfterTermination() throws {
        start()
        delegate.beginOnboarding()
        try setupWindow().close() // The next-step continuation is now queued.
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        drainMainQueue()
        XCTAssertNil(try controller().window)
    }

    func testClosedFolderStepResumesAtSameStepOnReopen() throws {
        start(legacy: .setupPresented)
        delegate.beginOnboarding()
        let onboarding = try window()
        onboarding.close()
        try model().refresh()
        XCTAssertFalse(onboarding.isVisible, "Closing must leave the step pending without reopening it immediately")

        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(onboarding.isVisible)
        XCTAssertTrue(try window() === onboarding)
        XCTAssertEqual(try model().state.step, .libraryFolder)
        XCTAssertFalse(try XCTUnwrap(delegate.settingsModel).firstRun.libraryFolderCompleted)

        onboarding.close()
        delegate.beginOnboarding()
        XCTAssertTrue(onboarding.isVisible, "A close must clear presentation bookkeeping for the same pending step")
    }

    func testCompletedFirstRunReopenOpensPickerWithoutOnboarding() throws {
        try saveProgress()
        start()
        delegate.beginOnboarding()
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertEqual(try model().state.step, .complete)
        XCTAssertNil(try controller().window)
        XCTAssertEqual(delegate.pickerModel?.state, .picker)
    }

    func testExplicitSetupMenuRequestKeepsSetupForPendingOnboarding() throws {
        start(legacy: .setupPresented)
        delegate.beginOnboarding()
        let onboarding = try window()
        onboarding.close()
        let menu = delegate.makeStatusMenu()
        let setupItem = try XCTUnwrap(menu.items.first { $0.title == Strings.setup })
        let action = try XCTUnwrap(setupItem.action)
        XCTAssertTrue(NSApp.sendAction(action, to: setupItem.target, from: setupItem))
        let setup = try setupWindow()
        XCTAssertTrue(setup.isVisible)
        XCTAssertFalse(onboarding.isVisible)

        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertTrue(setup.isVisible)
        XCTAssertFalse(onboarding.isVisible)
        setup.close()
        drainMainQueue()
        XCTAssertTrue(onboarding.isVisible)
        XCTAssertEqual(try model().state.step, .libraryFolder)
    }

    func testShowHidesVisibleOnboardingWhenSettingsReturnToSetup() throws {
        start(legacy: .setupPresented)
        delegate.beginOnboarding()
        let controller = try controller()
        let onboarding = try window()
        controller.onStateChange = nil // Isolate show() from composition routing.
        let reset = Data(#"{"version":1,"libraryFolderPath":null,"firstRun":{"setupPresented":false,"libraryFolderCompleted":false,"seedsOffered":false}}"#.utf8)
        try files(at: data).write(reset, at: "settings.json")
        try XCTUnwrap(delegate.settingsModel).clearLibraryFolder() // Reread the replaced settings.
        XCTAssertEqual(controller.presentation.state.step, .setup)
        XCTAssertTrue(onboarding.isVisible)

        controller.show()
        XCTAssertFalse(onboarding.isVisible)
        try model().markSetupPresented()
        controller.show()
        XCTAssertTrue(try window() === onboarding)
        XCTAssertTrue(onboarding.isVisible, "A later eligible step reuses the hidden window")
    }

    func testShowHidesVisibleOnboardingWhenReadOnlyChangeHookIsUnavailable() throws {
        start(legacy: .setupPresented)
        delegate.beginOnboarding()
        let controller = try controller()
        let onboarding = try window()
        controller.presentation.onChange = nil // show() must also enforce eligibility itself.
        try files(at: data).write(Data(#"{"version":999}"#.utf8), at: "settings.json")
        try XCTUnwrap(delegate.settingsModel).clearLibraryFolder()
        XCTAssertTrue(controller.presentation.state.isReadOnly)
        XCTAssertTrue(onboarding.isVisible)

        controller.show()
        XCTAssertFalse(onboarding.isVisible)
    }

    func testFreshLaunchPresentsSetupThenFolderSeedsOnceAndNoWindowAfterRestart() throws {
        start()
        XCTAssertEqual(try model().state.step, .setup)
        XCTAssertNil(try controller().window)
        delegate.beginOnboarding()
        let setup = try XCTUnwrap(NSApp.windows.first {
            !originalWindows.contains(ObjectIdentifier($0)) && $0.title == Strings.setupTitle
        })
        XCTAssertTrue(setup.isVisible)
        XCTAssertEqual(legacyWrites, 1)
        XCTAssertEqual(try model().state.step, .libraryFolder)
        XCTAssertNil(try controller().window, "Setup must remain the first screen")
        setup.close()
        XCTAssertTrue(spin { self.delegate.onboardingWindow?.window?.isVisible == true })
        let onboarding = try window()
        let presentation = try presentation()
        XCTAssertEqual(presentation.state.step, .libraryFolder)
        XCTAssertEqual(presentation.activeLibraryPath, root.path)
        XCTAssertEqual(presentation.defaultLibraryPath, root.path)
        XCTAssertEqual(policies, [], "Onboarding follows Setup's accessory policy")

        XCTAssertTrue(presentation.canChooseFolder)
        presentation.useDefaultFolder()
        XCTAssertTrue(spin { presentation.state.step == .seedOffer })
        XCTAssertTrue(try window() === onboarding)
        XCTAssertTrue(presentation.canOfferSeeds)
        presentation.acceptSeeds()
        XCTAssertTrue(spin { presentation.state.seedSummary != nil })
        XCTAssertEqual(try model().state.step, .tour)
        let summary = try XCTUnwrap(model().state.seedSummary)
        XCTAssertEqual(summary.seededCount, 10)
        XCTAssertEqual(summary.skippedExistingCount, 0)
        XCTAssertEqual(delegate.pickerModel?.results.count, 10)
        XCTAssertTrue(delegate.pickerModel?.results.contains { $0.relativePath == "code/explain-an-error.md" } == true)
        XCTAssertEqual(presentation.state.step, .tour)
        XCTAssertEqual(presentation.state.seedSummary, summary)
        XCTAssertTrue(presentation.canCompleteTour)
        XCTAssertTrue(onboarding.isVisible)
        XCTAssertFalse(try XCTUnwrap(delegate.settingsModel).firstRun.tourCompleted)
        let seeded = try files(at: root).listFiles().map { ($0.relativePath, try files(at: root).read(at: $0.relativePath)) }
        try model().acceptSeeds()
        for (path, bytes) in seeded { XCTAssertEqual(try files(at: root).read(at: path), bytes) }
        presentation.completeTour()
        XCTAssertTrue(spin { presentation.state.step == .complete && !onboarding.isVisible })
        XCTAssertFalse(presentation.canCompleteTour)
        XCTAssertTrue(try XCTUnwrap(delegate.settingsModel).firstRun.tourCompleted)
        XCTAssertEqual(policies, [])
        XCTAssertTrue(try XCTUnwrap(delegate.settingsModel).firstRun.seedsOffered)

        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertFalse(onboarding.isVisible)
        XCTAssertEqual(delegate.pickerModel?.state, .picker)
        delegate.pickerModel?.dismiss()

        start()
        delegate.beginOnboarding()
        XCTAssertEqual(try model().state.step, .complete)
        XCTAssertNil(try controller().window)
        XCTAssertEqual(delegate.pickerModel?.results.count, 10)
        XCTAssertEqual(legacyWrites, 1)
        XCTAssertTrue(notifications.isEmpty)
    }

    func testTourCloseIntentCompletesItAndDoesNotRepeat() throws {
        let presentation = try tourStep()
        let onboarding = try window()
        XCTAssertFalse(try XCTUnwrap(delegate.settingsModel).firstRun.tourCompleted)
        presentation.close()
        XCTAssertTrue(spin { presentation.state.step == .complete && !onboarding.isVisible })
        XCTAssertTrue(try XCTUnwrap(delegate.settingsModel).firstRun.tourCompleted)
        let saved = SettingsService(store: SettingsStore(files: try files(at: data)))
        XCTAssertTrue(saved.snapshot.document.firstRun.tourCompleted)
        start()
        delegate.beginOnboarding()
        XCTAssertEqual(try model().state.step, .complete)
        XCTAssertNil(try controller().window)
        XCTAssertTrue(try files(at: root).listFiles().isEmpty)
    }

    func testNativeCloseCompletesTourResumedAfterRestart() throws {
        _ = try tourStep()
        start()
        delegate.beginOnboarding()
        let presentation = try presentation()
        let onboarding = try window()
        XCTAssertEqual(presentation.state.step, .tour)
        XCTAssertTrue(presentation.canCompleteTour)
        onboarding.performClose(nil)
        XCTAssertTrue(spin { presentation.state.step == .complete && !onboarding.isVisible })
        XCTAssertTrue(try XCTUnwrap(delegate.settingsModel).firstRun.tourCompleted)
        XCTAssertEqual(policies, [])
    }

    func testDirectCloseCompletesTourAfterNativeWindowTeardown() throws {
        try saveProgress(tourCompleted: false)
        start()
        delegate.beginOnboarding()
        let presentation = try presentation()
        let onboarding = try window()
        XCTAssertEqual(presentation.state.step, .tour)
        onboarding.close() // NSWindow.close bypasses windowShouldClose.
        XCTAssertTrue(spin { presentation.state.step == .complete && !onboarding.isVisible })
        XCTAssertTrue(try XCTUnwrap(delegate.settingsModel).firstRun.tourCompleted)
    }

    func testFirstDirectTourCloseWriteFailureRetainsErrorAfterRoutingAndRetry() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        let presentation = try tourStep()
        let onboarding = try window()
        let config = try files(at: data)
        let before = try config.read(at: "settings.json")
        let failure = SettingsError.writeFailed(.ioFailure)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: data.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path) }
        // Direct close must be the first failed intent: a pre-existing error
        // deduplicates publication and can hide a routing refresh regression.
        onboarding.close()
        drainMainQueue()
        XCTAssertTrue(onboarding.isVisible)
        XCTAssertEqual(presentation.state.step, .tour)
        XCTAssertEqual(presentation.state.settingsError, failure)
        XCTAssertEqual(presentation.messages, [GeneralSettingsStrings.settingsError(failure)])
        XCTAssertFalse(try XCTUnwrap(delegate.settingsModel).firstRun.tourCompleted)
        XCTAssertEqual(try config.read(at: "settings.json"), before)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        presentation.completeTour()
        XCTAssertTrue(spin { presentation.state.step == .complete && !onboarding.isVisible })
        XCTAssertTrue(try XCTUnwrap(delegate.settingsModel).firstRun.tourCompleted)
        XCTAssertNil(presentation.state.settingsError)
    }

    func testTourWriteFailureKeepsDoneAndBothNativeClosePathsPendingUntilRetry() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        let presentation = try tourStep()
        let onboarding = try window()
        let config = try files(at: data)
        let before = try config.read(at: "settings.json")
        let failure = SettingsError.writeFailed(.ioFailure)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: data.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path) }
        presentation.completeTour()
        XCTAssertEqual(presentation.state.step, .tour)
        XCTAssertEqual(presentation.state.settingsError, failure)
        XCTAssertEqual(presentation.messages, [GeneralSettingsStrings.settingsError(failure)])
        XCTAssertTrue(presentation.canCompleteTour)
        XCTAssertTrue(onboarding.isVisible)
        XCTAssertFalse(try XCTUnwrap(delegate.settingsModel).firstRun.tourCompleted)
        XCTAssertEqual(try config.read(at: "settings.json"), before)
        onboarding.performClose(nil)
        XCTAssertTrue(onboarding.isVisible)
        XCTAssertEqual(presentation.state.step, .tour)
        XCTAssertEqual(presentation.state.settingsError, failure)
        onboarding.close()
        drainMainQueue()
        XCTAssertTrue(onboarding.isVisible)
        XCTAssertEqual(presentation.state.step, .tour)
        XCTAssertEqual(presentation.messages, [GeneralSettingsStrings.settingsError(failure)])
        XCTAssertFalse(try XCTUnwrap(delegate.settingsModel).firstRun.tourCompleted)
        XCTAssertEqual(try config.read(at: "settings.json"), before)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        start()
        delegate.beginOnboarding()
        let resumed = try self.presentation()
        let resumedWindow = try window()
        XCTAssertEqual(resumed.state.step, .tour)
        resumedWindow.performClose(nil)
        XCTAssertTrue(spin { resumed.state.step == .complete && !resumedWindow.isVisible })
        XCTAssertTrue(try XCTUnwrap(delegate.settingsModel).firstRun.tourCompleted)
        XCTAssertNil(resumed.state.settingsError)
    }

    func testNonEmptyFreshLibraryReachesTourWithoutOfferingSeeds() throws {
        try files(at: root).write(Data("Keep this prompt".utf8), at: "kept.md")
        start()
        delegate.beginOnboarding()
        try setupWindow().close()
        XCTAssertTrue(spin { self.delegate.onboardingWindow?.window?.isVisible == true })
        let presentation = try presentation()
        presentation.useDefaultFolder()
        XCTAssertEqual(presentation.state.step, .tour)
        XCTAssertFalse(try XCTUnwrap(delegate.settingsModel).firstRun.seedsOffered)
        XCTAssertTrue(presentation.canCompleteTour)
        presentation.completeTour()
        XCTAssertEqual(presentation.state.step, .complete)
        XCTAssertEqual(try files(at: root).read(at: "kept.md"), Data("Keep this prompt".utf8))
    }

    func testTerminationKeepsPendingTourAndRetiresQueuedDirectCloseCompletion() throws {
        let presentation = try tourStep()
        try window().close()
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        drainMainQueue()
        XCTAssertEqual(presentation.state.step, .tour)
        XCTAssertFalse(try XCTUnwrap(delegate.settingsModel).firstRun.tourCompleted)
        XCTAssertNil(try controller().window)
    }

    private func tourStep() throws -> OnboardingViewState {
        start()
        delegate.beginOnboarding()
        try setupWindow().close()
        XCTAssertTrue(spin { self.delegate.onboardingWindow?.window?.isVisible == true })
        let presentation = try presentation()
        presentation.useDefaultFolder()
        XCTAssertEqual(presentation.state.step, .seedOffer)
        presentation.declineSeeds()
        XCTAssertEqual(presentation.state.step, .tour)
        XCTAssertTrue(presentation.canCompleteTour)
        return presentation
    }

    func testLegacyInstallShowsFolderAndDecliningNeverCopiesAfterRestart() throws {
        start(legacy: .setupPresented)
        XCTAssertEqual(try model().state.step, .libraryFolder)
        delegate.beginOnboarding()
        XCTAssertTrue(try window().isVisible)
        XCTAssertEqual(legacyWrites, 0)
        let presentation = try presentation()
        XCTAssertEqual(presentation.state.step, .libraryFolder)
        XCTAssertTrue(presentation.canChooseFolder)
        presentation.useDefaultFolder()
        XCTAssertTrue(spin { presentation.state.step == .seedOffer })
        XCTAssertTrue(presentation.canOfferSeeds)
        presentation.declineSeeds()
        XCTAssertTrue(spin { presentation.state.step == .complete })
        XCTAssertNil(presentation.state.seedSummary)
        XCTAssertTrue(try files(at: root).listFiles().isEmpty)
        try window().close()
        start()
        delegate.beginOnboarding()
        XCTAssertEqual(try model().state.step, .complete)
        XCTAssertNil(try controller().window)
        XCTAssertTrue(try files(at: root).listFiles().isEmpty)
    }

    func testChosenFolderUsesCurrentGraphForEligibilityAndSeedDestination() throws {
        try files(at: root).write(Data("Keep the original".utf8), at: "original.md")
        let chosen = directory.appendingPathComponent("chosen", isDirectory: true)
        let chosenFiles = try files(at: chosen)
        start(legacy: .setupPresented)
        delegate.beginOnboarding()
        let presentation = try presentation()
        XCTAssertTrue(presentation.canChooseFolder)
        presentation.chooseFolder()
        XCTAssertTrue(spin { self.chooserCompletions.count == 1 })
        chooserCompletions[0](chosen)
        XCTAssertEqual(presentation.activeLibraryPath, chosen.path)
        XCTAssertEqual(presentation.state.step, .seedOffer)
        XCTAssertEqual(delegate.settingsModel?.libraryFolderPath, chosen.path)
        XCTAssertTrue(presentation.canOfferSeeds)
        presentation.acceptSeeds()
        XCTAssertTrue(spin { presentation.state.step == .complete })
        XCTAssertEqual(try chosenFiles.listFiles().count, 10)
        XCTAssertEqual(delegate.pickerModel?.results.count, 10)
        XCTAssertEqual(try files(at: root).listFiles().map(\.relativePath), ["original.md"])
        XCTAssertEqual(try files(at: root).read(at: "original.md"), Data("Keep the original".utf8))
        XCTAssertEqual(delegate.settingsWindow?.presentation.general.activeLibraryPath, chosen.path)
    }

    func testNonEmptyLibraryIncludingInvalidPromptSkipsSeedOffer() throws {
        try files(at: root).write(Data("---\ntitle: [\n---\nInvalid prompt".utf8), at: "invalid.md")
        start(legacy: .setupPresented)
        delegate.beginOnboarding()
        let presentation = try presentation()
        XCTAssertTrue(presentation.canChooseFolder)
        presentation.useDefaultFolder()
        XCTAssertEqual(presentation.state.step, .complete)
        XCTAssertFalse(try XCTUnwrap(delegate.settingsModel).firstRun.seedsOffered)
        XCTAssertFalse(presentation.canOfferSeeds)
        XCTAssertEqual(try files(at: root).listFiles().map(\.relativePath), ["invalid.md"])
    }

    func testInvalidChooserResultShowsTypedMessageAndKeepsFolderPending() throws {
        start(legacy: .setupPresented)
        delegate.beginOnboarding()
        let presentation = try presentation()
        XCTAssertTrue(presentation.canChooseFolder)
        presentation.chooseFolder()
        XCTAssertTrue(spin { self.chooserCompletions.count == 1 })
        chooserCompletions[0](directory.appendingPathComponent("missing"))
        let outcome = LibrarySwitchOutcome.invalidTarget(.rejectedByStore(.notFound))
        XCTAssertEqual(try model().state.lastSwitchMessage, outcome)
        XCTAssertEqual(presentation.messages, [try XCTUnwrap(GeneralSettingsStrings.message(for: outcome))])
        XCTAssertEqual(presentation.state.step, .libraryFolder)
        XCTAssertFalse(try XCTUnwrap(delegate.settingsModel).firstRun.libraryFolderCompleted)
        XCTAssertEqual(delegate.libraryDirectory, root)
        XCTAssertFalse(presentation.isChoosingFolder)
        XCTAssertTrue(presentation.canChooseFolder)
        XCTAssertFalse(presentation.messages.joined().contains(directory.path))
        presentation.useDefaultFolder()
        XCTAssertEqual(presentation.state.step, .seedOffer)
        XCTAssertTrue(presentation.messages.isEmpty)
    }

    func testStartupMissingChosenFolderNotifiesOnceAndRecoversAfterClosingWindow() throws {
        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        try saveProgress(folder: missing)
        start()
        let status = try XCTUnwrap(delegate.libraryStatusModel)
        XCTAssertEqual(status.state, .unavailableAtStartup)
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.content.body, OnboardingStrings.libraryUnavailableNotificationBody)
        XCTAssertEqual(activations, 0, "The notification must not activate a window")
        XCTAssertEqual(try model().state.step, .libraryFolder)
        delegate.beginOnboarding()
        let onboarding = try window()
        onboarding.close()
        try model().refresh()
        XCTAssertFalse(onboarding.isVisible, "Refresh must respect a dismissed recovery window")
        XCTAssertEqual(try model().state.step, .libraryFolder)
        XCTAssertTrue(try XCTUnwrap(delegate.settingsModel).firstRun.libraryFolderCompleted)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(onboarding.isVisible)
        XCTAssertTrue(try window() === onboarding)
        let readable = directory.appendingPathComponent("readable", isDirectory: true)
        try files(at: readable).write(Data("Recovered".utf8), at: "recovered.md")
        try presentation().chooseFolder()
        chooserCompletions[0](readable)
        XCTAssertEqual(status.state, .available)
        XCTAssertEqual(try model().state.step, .complete)
        XCTAssertEqual(delegate.pickerModel?.results.map(\.relativePath), ["recovered.md"])
        XCTAssertEqual(delegate.settingsModel?.libraryFolderPath, readable.path)
        try model().refresh()
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertEqual(notifications.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testStartupWatcherFailureAlsoOpensRecoveryAndDefaultRetryStartsHealthyGraph() throws {
        try saveProgress()
        var starts = 0
        start(watcherStart: { _ in
            starts += 1
            if starts == 1 { throw FileStoreError.ioFailure }
        })
        XCTAssertEqual(delegate.libraryStatusModel?.state, .unavailableAtStartup)
        XCTAssertEqual(notifications.count, 1)
        delegate.beginOnboarding()
        try presentation().useDefaultFolder()
        XCTAssertEqual(delegate.libraryStatusModel?.state, .available)
        XCTAssertEqual(try model().state.step, .complete)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(notifications.count, 1)
    }

    func testStartupUnreadableChosenFolderUsesRecoveryWithoutCreatingItAgain() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        let chosen = directory.appendingPathComponent("unreadable", isDirectory: true)
        try files(at: chosen).write(Data("Kept".utf8), at: "kept.md")
        try saveProgress(folder: chosen)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: chosen.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: chosen.path) }
        start()
        XCTAssertEqual(delegate.libraryStatusModel?.state, .unavailableAtStartup)
        XCTAssertEqual(notifications.count, 1)
        delegate.beginOnboarding()
        XCTAssertEqual(try model().state.step, .libraryFolder)
        try presentation().useDefaultFolder()
        XCTAssertEqual(delegate.libraryStatusModel?.state, .available)
        XCTAssertEqual(try model().state.step, .complete)
        XCTAssertNil(try XCTUnwrap(delegate.settingsModel).libraryFolderPath)
    }

    func testRuntimeLossUpdatesExistingMenuWithoutNotificationAndHealthySwitchRestoresIt() throws {
        try files(at: root).write(Data("Cached".utf8), at: "cached.md")
        try saveProgress()
        start()
        delegate.beginOnboarding()
        let menu = delegate.makeStatusMenu()
        let item = try XCTUnwrap(menu.items.first { $0.title == OnboardingStrings.libraryAvailableMenu })
        XCTAssertTrue(item.isEnabled)
        XCTAssertFalse(menu.autoenablesItems)
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        let libraryWindow = try XCTUnwrap(delegate.libraryWindow?.window)
        XCTAssertTrue(libraryWindow.isVisible)
        XCTAssertTrue(revealed.isEmpty)
        delegate.libraryWindow?.presentation.revealFolder()
        XCTAssertEqual(revealed, [root])
        let stale = watchers[0]
        DispatchQueue.global().sync { stale.emit(.rootUnavailable(.notFound)) }
        XCTAssertTrue(spin { item.title == OnboardingStrings.libraryUnavailableMenu })
        XCTAssertFalse(item.isEnabled)
        menu.update()
        XCTAssertFalse(item.isEnabled, "Native validation must not enable an unavailable library")
        XCTAssertFalse(try XCTUnwrap(delegate.pickerModel).libraryAvailable)
        XCTAssertEqual(delegate.pickerModel?.results.map(\.relativePath), ["cached.md"])
        XCTAssertEqual(delegate.libraryStatusModel?.state, .lostWhileRunning)
        XCTAssertNil(try controller().window)
        XCTAssertTrue(notifications.isEmpty)

        let other = directory.appendingPathComponent("other", isDirectory: true)
        try files(at: other).write(Data("Other".utf8), at: "other.md")
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        XCTAssertEqual(item.title, OnboardingStrings.libraryAvailableMenu)
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        XCTAssertTrue(delegate.libraryWindow?.window === libraryWindow)
        XCTAssertEqual(delegate.libraryWindow?.presentation.activeLibraryPath, other.path)
        XCTAssertEqual(revealed, [root])
        delegate.libraryWindow?.presentation.revealFolder()
        XCTAssertEqual(revealed, [root, other])
        stale.emit(.rootUnavailable(.ioFailure))
        XCTAssertTrue(spin { self.delegate.libraryStatusModel?.state == .available })
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(notifications.isEmpty)
    }

    func testReadOnlySettingsSuppressEveryOnboardingWindowAndPreserveSettingsError() throws {
        let config = try files(at: data)
        let original = Data("{\"version\":999}".utf8)
        try config.write(original, at: "settings.json")
        start()
        delegate.beginOnboarding()
        XCTAssertEqual(try model().state.step, .complete)
        XCTAssertTrue(try model().state.isReadOnly)
        XCTAssertNil(try controller().window)
        XCTAssertEqual(NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.count, 0)
        delegate.showSettings()
        XCTAssertEqual(delegate.settingsWindow?.presentation.general.settingsError, .futureVersion(999))
        XCTAssertEqual(try config.read(at: "settings.json"), original)
        XCTAssertEqual(legacyWrites, 0)
    }

    func testSeedFailureIsShownAfterDurableOfferAndDoesNotRepeat() throws {
        start(legacy: .setupPresented)
        delegate.beginOnboarding()
        let presentation = try presentation()
        XCTAssertTrue(presentation.canChooseFolder)
        presentation.useDefaultFolder()
        XCTAssertTrue(presentation.canOfferSeeds)
        // A regular non-prompt file is ignored by enumeration but blocks the
        // catalog's code/ parent. This deterministically fails without chmod.
        try files(at: root).write(Data("Blocked directory".utf8), at: "code")
        presentation.acceptSeeds()
        XCTAssertEqual(presentation.state.step, .complete)
        let failure = try XCTUnwrap(presentation.state.seedFailure)
        XCTAssertTrue(presentation.messages.contains(OnboardingStrings.seedFailure(failure)))
        XCTAssertNil(presentation.state.seedSummary)
        XCTAssertTrue(try XCTUnwrap(delegate.settingsModel).firstRun.seedsOffered)
        try window().close()
        start()
        delegate.beginOnboarding()
        XCTAssertEqual(try model().state.step, .complete)
        XCTAssertNil(try controller().window)
        XCTAssertEqual(try files(at: root).listFiles().map(\.relativePath), ["code"])
    }

    func testFolderRetirementFailureKeepsRootAndDurableRetryCompletesStep() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        try saveProgress(folderCompleted: false, seedsOffered: false)
        start()
        delegate.beginOnboarding()
        let chosen = directory.appendingPathComponent("chosen", isDirectory: true)
        _ = try files(at: chosen)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: data.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path) }
        try presentation().chooseFolder()
        chooserCompletions[0](chosen)
        XCTAssertEqual(try model().state.step, .libraryFolder)
        XCTAssertEqual(try model().state.lastSwitchMessage, .repeatInvalidationFailed)
        XCTAssertNil(try model().state.settingsError)
        XCTAssertEqual(try presentation().messages,
            [try XCTUnwrap(GeneralSettingsStrings.message(for: .repeatInvalidationFailed))],
            "Retirement errors must not be shown twice")
        XCTAssertEqual(try presentation().activeLibraryPath, root.path)
        XCTAssertEqual(delegate.repeatModel?.availability, .unavailable(.invalidationFailed))
        XCTAssertFalse(try XCTUnwrap(delegate.settingsModel).firstRun.libraryFolderCompleted)
        XCTAssertNil(try XCTUnwrap(delegate.settingsModel).libraryFolderPath)
        XCTAssertEqual(delegate.libraryStatusModel?.state, .available)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        try presentation().chooseFolder()
        chooserCompletions[1](chosen)
        XCTAssertEqual(try model().state.step, .seedOffer)
        XCTAssertTrue(try XCTUnwrap(delegate.settingsModel).firstRun.libraryFolderCompleted)
        XCTAssertEqual(delegate.settingsModel?.libraryFolderPath, chosen.path)
        XCTAssertTrue(try presentation().messages.isEmpty)
    }

    func testSeedFlagWriteFailureKeepsOfferAndCopiesNothingUntilRetry() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        try saveProgress(seedsOffered: false)
        start()
        delegate.beginOnboarding()
        XCTAssertEqual(try model().state.step, .seedOffer)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: data.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path) }
        try presentation().acceptSeeds()
        XCTAssertEqual(try model().state.step, .seedOffer)
        XCTAssertEqual(try model().state.settingsError, .writeFailed(.ioFailure))
        XCTAssertTrue(try files(at: root).listFiles().isEmpty)
        XCTAssertFalse(try XCTUnwrap(delegate.settingsModel).firstRun.seedsOffered)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        try presentation().acceptSeeds()
        XCTAssertEqual(try model().state.step, .complete)
        XCTAssertEqual(delegate.pickerModel?.results.count, 10)
        XCTAssertNil(try model().state.settingsError)
    }

    func testChooserCancelCloseHiddenCompletionAndOldResponseCannotSwitchFolder() throws {
        start(legacy: .setupPresented)
        delegate.beginOnboarding()
        let presentation = try presentation()
        let chosen = directory.appendingPathComponent("chosen", isDirectory: true)
        _ = try files(at: chosen)
        presentation.chooseFolder()
        presentation.chooseFolder()
        XCTAssertEqual(chooserCompletions.count, 1)
        chooserCompletions[0](nil)
        XCTAssertFalse(presentation.isChoosingFolder)
        XCTAssertEqual(delegate.libraryDirectory, root)

        presentation.chooseFolder()
        let late = chooserCompletions[1]
        let onboarding = try window()
        onboarding.close()
        XCTAssertEqual(chooserCancellations, 1)
        XCTAssertFalse(presentation.isChoosingFolder)
        late(chosen)
        XCTAssertEqual(delegate.libraryDirectory, root)
        try controller().show()
        XCTAssertTrue(try window() === onboarding)
        presentation.chooseFolder()
        late(chosen)
        XCTAssertTrue(presentation.isChoosingFolder)
        onboarding.orderOut(nil)
        chooserCompletions[2](chosen)
        XCTAssertFalse(presentation.isChoosingFolder)
        XCTAssertEqual(delegate.libraryDirectory, root)
        try controller().show()
        presentation.chooseFolder()
        chooserCompletions[3](chosen)
        XCTAssertEqual(delegate.libraryDirectory, chosen)
        XCTAssertEqual(presentation.state.step, .seedOffer)
    }

    func testSynchronousChooserAndWorkerReplyUseSameComposition() throws {
        let chosen = directory.appendingPathComponent("chosen", isDirectory: true)
        _ = try files(at: chosen)
        var cancellations = 0
        start(legacy: .setupPresented, chooser: { _, done in
            done(chosen)
            return { cancellations += 1 }
        })
        delegate.beginOnboarding()
        try presentation().chooseFolder()
        XCTAssertEqual(delegate.libraryDirectory, chosen)
        XCTAssertEqual(try model().state.step, .seedOffer)
        XCTAssertFalse(try presentation().isChoosingFolder)
        try window().close()
        XCTAssertEqual(cancellations, 0)

        // A second isolated install verifies marshalling of an async chooser.
        try FileManager.default.removeItem(at: data)
        start(legacy: .setupPresented)
        delegate.beginOnboarding()
        let presentation = try presentation()
        presentation.chooseFolder()
        let done = chooserCompletions[0]
        let publish = presentation.onChange
        var publishedOnMain = false
        presentation.onChange = {
            publishedOnMain = Thread.isMainThread
            publish?()
        }
        DispatchQueue.global().async { done(chosen) }
        XCTAssertTrue(spin { self.delegate.libraryDirectory == chosen })
        XCTAssertTrue(publishedOnMain)
        XCTAssertFalse(presentation.isChoosingFolder)
    }

    func testOnboardingClosuresAndLateChooserDoNotRetainCompositionRoot() throws {
        start(legacy: .setupPresented)
        delegate.beginOnboarding()
        let model = try model()
        let presentation = try presentation()
        let controller = try controller()
        let onboarding = try window()
        presentation.chooseFolder()
        let done = chooserCompletions[0]
        weak var reference = delegate
        // Prove cancellation follows the root's lifetime even if native code or
        // a caller still holds the controller and its window.
        withExtendedLifetime(controller) {
            delegate = nil
            XCTAssertNil(reference)
            XCTAssertEqual(chooserCancellations, 1)
            XCTAssertFalse(presentation.isChoosingFolder)
            XCTAssertFalse(onboarding.isVisible)
            done(root)
            XCTAssertNil(model.state.lastSwitchMessage, "A late chooser result must not attempt a switch")
            model.useDefaultFolder()
            XCTAssertEqual(model.state.lastSwitchMessage, .libraryUnavailable(.ioFailure))
        }
    }

    func testTerminationCancelsChooserOnceAndLateResponseCannotSwitchFolder() throws {
        start(legacy: .setupPresented)
        delegate.beginOnboarding()
        let presentation = try presentation()
        let onboarding = try window()
        let chosen = directory.appendingPathComponent("chosen", isDirectory: true)
        _ = try files(at: chosen)
        presentation.chooseFolder()
        let done = chooserCompletions[0]
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(chooserCancellations, 1)
        XCTAssertFalse(presentation.isChoosingFolder)
        XCTAssertFalse(onboarding.isVisible)
        done(chosen)
        XCTAssertEqual(delegate.libraryDirectory, root)
        XCTAssertNil(try model().state.lastSwitchMessage)
        XCTAssertFalse(try XCTUnwrap(delegate.settingsModel).firstRun.libraryFolderCompleted)

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(chooserCancellations, 1)
    }

    private func drainMainQueue() {
        let drained = expectation(description: "Deferred native window work completes")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func spin(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return false
    }
}

private final class OnboardingWatcher: FileStoreWatcher {
    private let onStart: () throws -> Void
    private var onEvent: (@Sendable (FileStoreWatchEvent) -> Void)?
    init(_ onStart: @escaping () throws -> Void) { self.onStart = onStart }
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {
        self.onEvent = onEvent
        try onStart()
    }
    func stop() {}
    func emit(_ event: FileStoreWatchEvent) { onEvent?(event) }
}
