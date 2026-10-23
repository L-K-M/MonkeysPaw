import AppKit
import Darwin
import MonkeysPawCore
import SwiftUI
import XCTest
@testable import MonkeysPaw

/// Isolated on-disk state and real picker controls; no hotkey registration,
/// permission requests or activation of an external application.
final class MacForgetControlsTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var files: RootedFileStore!
    private var dataFiles: RootedFileStore!
    private var values: ValuesStore!
    private var delegate: AppDelegate!
    private var panel: PanelController!
    private let scheduler = ForgetControlsScheduler()
    private var originalWindows: Set<ObjectIdentifier> = []
    private var confirmations: [(SettingsWindowController.ForgetAllResponse) -> Void] = []
    private var confirmationCancellations = 0

    override func setUpWithError() throws {
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library", isDirectory: true)
        data = directory.appendingPathComponent("data", isDirectory: true)
        files = try RootedFileStore(root: root)
        dataFiles = try RootedFileStore(root: data)
        values = ValuesStore(files: dataFiles)
        try files.write(Data(prompt(title: "Alpha").utf8), at: "a.md")
        try files.write(Data(prompt(title: "Beta").utf8), at: "b.md")
    }

    override func tearDown() {
        scheduler.drain()
        delegate?.pickerModel?.dismiss()
        panel?.hide()
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate = nil
        panel = nil
        confirmations = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func start(confirmation: SettingsWindowController.ForgetAllConfirmation? = nil) throws {
        let confirm: SettingsWindowController.ForgetAllConfirmation = confirmation ?? { [weak self] _, done in
            self?.confirmations.append(done)
            return { [weak self] in
                self?.confirmationCancellations += 1
                // Native endSheet may complete inline. Revoked callbacks must
                // not finish a newer request or perform a forgotten mutation.
                done(.cancelled)
            }
        }
        delegate = AppDelegate(libraryRoot: root, dataRoot: data, launchURI: { _ in
            XCTFail("Forgetting must not launch an editor or library")
        }, forgetAllConfirmation: confirm, setActivationPolicy: { _ in }, activateApplication: {},
            makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in
                    XCTFail("Forgetting must not activate an external application")
                    return false
                }), mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, scheduler: scheduler, makePanelController: { [weak self] main, scheduler, log in
                let panel = PanelController(mainThread: main, scheduler: scheduler, log: log)
                self?.panel = panel
                return panel
            }, makeFileWatcher: { _, _ in ForgetControlsWatcher() })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertNotNil(delegate.rememberedValuesSettingsModel)
    }

    func testPickerForgetRemovesSelectedValuesAndDraftAndKeepsOtherPrompt() throws {
        try start()
        let alpha = try identity("a.md")
        let beta = try identity("b.md")
        try values.record(identity: alpha, values: ["topic": "Remembered Alpha", "stale": "Old field"])
        try values.record(identity: beta, values: ["topic": "Remembered Beta"])
        try draft("Beta draft", for: "Beta")
        try draft("Alpha draft", for: "Alpha")
        let picker = try picker()
        let presentation = try presentation()
        let clipboardRevision = NSPasteboard.general.changeCount
        XCTAssertTrue(presentation.showsForgetValues)
        XCTAssertTrue(presentation.canForgetValues)
        presentation.showStatus(Strings.promptFileUnavailable)

        presentation.forgetSelectedValues()
        XCTAssertTrue(spin { (try? self.values.rememberedValues(for: alpha)) == [:] })

        XCTAssertEqual(try values.rememberedValues(for: alpha), [:])
        XCTAssertEqual(try values.rememberedValues(for: beta), ["topic": "Remembered Beta"])
        XCTAssertEqual(picker.state, .picker)
        XCTAssertEqual(presentation.status, "")
        XCTAssertNil(picker.forgetValuesError)
        XCTAssertEqual(try openForm("Alpha").values["topic"], "Alpha default")
        picker.escape()
        XCTAssertEqual(try openForm("Beta").values["topic"], "Beta draft")
        try assertNoLearningOrClipboardWrite(clipboardRevision, identities: [alpha, beta])
    }

    func testFillForgetResetsNativeControlsAndPreviewWithoutReplacingForm() throws {
        let source = """
        ---
        title: Alpha
        fields:
          topic: {default: Alpha default}
          detail: {type: multiline, default: Detail default, remember: false}
          language: {type: choice, options: [en, fr], default: en}
        ---
        {{topic}} / {{detail}} / {{language}}
        """
        try files.write(Data(source.utf8), at: "a.md")
        try start()
        let alpha = try identity("a.md")
        let beta = try identity("b.md")
        try values.record(identity: alpha, values: ["topic": "Remembered", "language": "fr"])
        try values.record(identity: beta, values: ["topic": "Kept"])
        let fill = try openForm("Alpha", mode: .paste(.terminal))
        fill.setValue("Draft", name: "topic")
        fill.setValue("Edited detail", name: "detail")
        fill.setValue("fr", name: "language")
        fill.focusField(at: 1)
        XCTAssertTrue(spin { (self.find("fill-field-topic") as? PickerTextField)?.stringValue == "Draft" })
        let topic = try XCTUnwrap(find("fill-field-topic") as? PickerTextField)
        let detail = try XCTUnwrap(find("fill-field-detail") as? PickerMultilineTextView)
        let language = try XCTUnwrap(find("fill-field-language") as? PickerChoiceButton)
        let clipboardRevision = NSPasteboard.general.changeCount

        XCTAssertTrue(try presentation().showsForgetValues)
        XCTAssertTrue(try presentation().canForgetValues)
        try presentation().forgetSelectedValues()
        XCTAssertTrue(spin { fill.values["topic"] == "Alpha default" })

        XCTAssertTrue(try picker().fillModel === fill)
        XCTAssertEqual(try picker().state, .fill)
        XCTAssertEqual(fill.preferredMode, .paste(.terminal))
        XCTAssertEqual(fill.focusIndex, 1)
        XCTAssertEqual(fill.values, ["topic": "Alpha default", "detail": "Detail default", "language": "en"])
        XCTAssertEqual(fill.preview, .rendered("Alpha default / Detail default / en"))
        XCTAssertEqual(try presentation().preview, "Alpha default / Detail default / en")
        XCTAssertEqual(try presentation().status, "")
        XCTAssertTrue(spin {
            topic.stringValue == "Alpha default" && detail.string == "Detail default"
                && language.selectedItem?.representedObject as? String == "en"
        })
        XCTAssertTrue(find("fill-field-topic") === topic)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(try values.rememberedValues(for: alpha), [:])
        XCTAssertEqual(try values.rememberedValues(for: beta), ["topic": "Kept"])
        try assertNoLearningOrClipboardWrite(clipboardRevision, identities: [alpha, beta])
    }

    func testCorruptValuesShowTypedMessageAndPreserveFormAndDraftUntilRetry() throws {
        try start()
        let alpha = try identity("a.md")
        try values.record(identity: alpha, values: ["topic": "Remembered"])
        let original = try dataFiles.read(at: "values.json")
        let fill = try openForm("Alpha")
        fill.setValue("Keep draft", name: "topic")
        let corrupt = Data("private invalid contents".utf8)
        try dataFiles.write(corrupt, at: "values.json")

        XCTAssertTrue(try presentation().showsForgetValues)
        XCTAssertTrue(try presentation().canForgetValues)
        try presentation().forgetSelectedValues()
        XCTAssertTrue(spin { self.delegate.pickerModel?.forgetValuesError != nil })

        XCTAssertEqual(try picker().forgetValuesError as? LibraryError, .operationFailed)
        XCTAssertEqual(try presentation().status, RememberedValuesStrings.message(for: .libraryFailure(.operationFailed)))
        XCTAssertFalse(try presentation().status.contains("private invalid contents"))
        XCTAssertTrue(try picker().fillModel === fill)
        XCTAssertEqual(fill.values["topic"], "Keep draft")
        XCTAssertEqual(try dataFiles.read(at: "values.json"), corrupt)
        try picker().escape()
        try dataFiles.writePrivate(original, at: "values.json")
        XCTAssertEqual(try openForm("Alpha").values["topic"], "Keep draft")
        XCTAssertEqual(try values.rememberedValues(for: alpha), ["topic": "Remembered"])
        try presentation().forgetSelectedValues()
        XCTAssertNil(try picker().forgetValuesError)
        XCTAssertEqual(try presentation().status, "")
        XCTAssertEqual(try picker().fillModel?.values["topic"], "Alpha default")
    }

    func testForgettingMultilineInputClearsItsNativeUndoHistory() throws {
        try files.write(Data("---\ntitle: Alpha\nfields:\n  detail: {type: multiline, default: Default}\n---\n{{detail}}".utf8), at: "a.md")
        try start()
        let fill = try openForm("Alpha")
        XCTAssertTrue(spin { self.find("fill-field-detail") != nil })
        let text = try XCTUnwrap(find("fill-field-detail") as? PickerMultilineTextView)
        let window = try XCTUnwrap(text.window)
        XCTAssertTrue(window.makeFirstResponder(text))
        let undo = try XCTUnwrap(text.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        text.insertText(" forgotten input", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
        text.breakUndoCoalescing()
        undo.endUndoGrouping()
        XCTAssertTrue(undo.canUndo)
        XCTAssertEqual(fill.values["detail"], "Default forgotten input")

        try presentation().forgetSelectedValues()
        XCTAssertTrue(spin { text.string == "Default" })
        XCTAssertFalse(undo.canUndo, "Undo must not resurrect forgotten field values or replay stale ranges")
        XCTAssertFalse(undo.canRedo)
        XCTAssertEqual(fill.values["detail"], "Default")
        XCTAssertTrue(panel.isVisible)
    }

    func testForgettingFocusedTextRetiresCompositionAndUpdatesTheFieldEditor() throws {
        try start()
        let fill = try openForm("Alpha")
        XCTAssertTrue(spin { (self.find("fill-field-topic") as? PickerTextField)?.currentEditor() != nil })
        let field = try XCTUnwrap(find("fill-field-topic") as? PickerTextField)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(editor.hasMarkedText())

        try presentation().forgetSelectedValues()
        XCTAssertTrue(spin { editor.string == "Alpha default" && !editor.hasMarkedText() })
        XCTAssertEqual(field.stringValue, "Alpha default")
        XCTAssertEqual(fill.values["topic"], "Alpha default")
        XCTAssertFalse(editor.undoManager?.canUndo ?? false)
        XCTAssertTrue(panel.isVisible)
    }

    func testForgetHiddenWithoutSelectionAndRetiredPresentationCannotMutateValues() throws {
        try start()
        let alpha = try identity("a.md")
        try values.record(identity: alpha, values: ["topic": "Kept"])
        let old = try presentation()
        try picker().open()
        old.setQuery("No matching prompt")
        XCTAssertFalse(old.showsForgetValues)
        XCTAssertFalse(old.canForgetValues)
        XCTAssertEqual(old.state, .picker)
        XCTAssertNotNil(old.model.noMatches)
        old.forgetSelectedValues()
        XCTAssertNil(try picker().forgetValuesError)
        old.setQuery("Alpha")
        let other = directory.appendingPathComponent("chosen", isDirectory: true)
        try RootedFileStore(root: other).write(Data(prompt(title: "New").utf8), at: "a.md")
        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        old.forgetSelectedValues()
        XCTAssertEqual(try values.rememberedValues(for: alpha), ["topic": "Kept"])
    }

    func testSettingsCancelKeepsValuesAndConfirmClearsAllDraftsWhilePanelClosed() throws {
        try start()
        let alpha = try identity("a.md")
        let beta = try identity("b.md")
        try values.record(identity: alpha, values: ["topic": "Remembered Alpha"])
        try values.record(identity: beta, values: ["topic": "Remembered Beta"])
        try draft("Alpha draft", for: "Alpha")
        try draft("Beta draft", for: "Beta")
        let original = try dataFiles.read(at: "values.json")
        delegate.showSettings()
        let presentation = try settings().presentation
        XCTAssertEqual(try picker().state, .closed)
        XCTAssertFalse(panel.isVisible)
        let clipboardRevision = NSPasteboard.general.changeCount

        presentation.requestForgetAll()
        XCTAssertEqual(presentation.rememberedValues.confirmation, .forgetAll)
        XCTAssertEqual(try dataFiles.read(at: "values.json"), original)
        confirmations[0](.cancelled)
        XCTAssertEqual(presentation.rememberedValues.confirmation, .none)
        XCTAssertNil(presentation.rememberedValues.message)
        XCTAssertEqual(try dataFiles.read(at: "values.json"), original)
        XCTAssertEqual(try openForm("Alpha").values["topic"], "Alpha draft")
        try picker().escape()
        XCTAssertEqual(try openForm("Beta").values["topic"], "Beta draft")

        delegate.showSettings()
        presentation.requestForgetAll()
        confirmations[1](.confirmed)
        XCTAssertEqual(presentation.rememberedValues.lastOutcome, .forgotten)
        XCTAssertEqual(presentation.rememberedValues.message, RememberedValuesStrings.message(for: .forgotten))
        XCTAssertEqual(try picker().state, .closed)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(try dataFiles.read(at: "values.json"), Data("{\"values\":{},\"version\":1}".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: data.appendingPathComponent("values.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try openForm("Alpha").values["topic"], "Alpha default")
        try picker().escape()
        XCTAssertEqual(try openForm("Beta").values["topic"], "Beta default")
        try assertNoLearningOrClipboardWrite(clipboardRevision, identities: [alpha, beta])
    }

    func testSettingsConfirmationUsesCurrentPickerAfterLibrarySwitch() throws {
        try start()
        let old = try picker()
        let model = try XCTUnwrap(delegate.rememberedValuesSettingsModel)
        let alpha = try identity("a.md")
        try values.record(identity: alpha, values: ["topic": "Remembered"])
        let original = try dataFiles.read(at: "values.json")
        let oldFill = try openForm("Alpha")
        oldFill.setValue("Retired draft", name: "topic")
        try dataFiles.write(Data("invalid".utf8), at: "values.json")
        try presentation().forgetSelectedValues()
        try dataFiles.writePrivate(original, at: "values.json")
        delegate.showSettings()
        let settings = try settings()
        let window = try XCTUnwrap(settings.window)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        let hosting = try XCTUnwrap(tabs.tabViewItems[SettingsViewState.Tab.general.rawValue].viewController
            as? NSHostingController<SettingsView>)
        XCTAssertTrue(hosting.rootView.presentation === settings.presentation)
        XCTAssertFalse(settings.presentation.isChoosingFolder)
        XCTAssertEqual(settings.presentation.rememberedValues.confirmation, .none)
        settings.presentation.requestForgetAll()
        XCTAssertEqual(settings.presentation.rememberedValues.confirmation, .forgetAll)
        let other = directory.appendingPathComponent("chosen", isDirectory: true)
        try RootedFileStore(root: other).write(Data(prompt(title: "New").utf8), at: "a.md")

        XCTAssertEqual(delegate.switchLibrary(to: other), .switched)
        let current = try picker()
        XCTAssertFalse(current === old)
        XCTAssertTrue(delegate.rememberedValuesSettingsModel === model)
        XCTAssertEqual(try openForm("New").values["topic"], "Remembered")
        current.fillModel?.setValue("New draft", name: "topic")
        delegate.showSettings()
        XCTAssertTrue(try self.settings().window === window)
        confirmations[0](.confirmed)

        XCTAssertEqual(try values.rememberedValues(for: alpha), [:])
        XCTAssertEqual(old.forgetValuesError as? LibraryError, .operationFailed, "Do not mutate the retired picker")
        XCTAssertEqual(oldFill.values["topic"], "Retired draft")
        XCTAssertEqual(try openForm("New").values["topic"], "New default")
    }

    func testUnreadableValuesShowTypedFailuresAndGlobalResetRecovers() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses file and directory permissions.") }
        try start()
        let alpha = try identity("a.md")
        try values.record(identity: alpha, values: ["topic": "Remembered"])
        let original = try dataFiles.read(at: "values.json")
        try draft("Keep draft", for: "Alpha")
        let url = data.appendingPathComponent("values.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try presentation().forgetSelectedValues()
        XCTAssertEqual(try picker().forgetValuesError as? FileStoreError, .ioFailure)
        XCTAssertEqual(try presentation().status, RememberedValuesStrings.message(for: .fileStoreFailure(.ioFailure)))
        XCTAssertEqual(try openForm("Alpha").values["topic"], "Keep draft")
        delegate.showSettings()
        let presentation = try settings().presentation
        // Global reset tombstones repeat before clearing values. A blocked
        // tombstone preserves the values/draft and disables repeat until retry.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: data.path)
        presentation.requestForgetAll()
        confirmations[0](.confirmed)
        XCTAssertEqual(presentation.rememberedValues.lastOutcome, .libraryFailure(.operationFailed))
        XCTAssertEqual(presentation.rememberedValues.message, RememberedValuesStrings.message(for: .libraryFailure(.operationFailed)))
        XCTAssertEqual(delegate.repeatModel?.availability, .unavailable(.invalidationFailed))
        XCTAssertEqual(try openForm("Alpha").values["topic"], "Keep draft")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try dataFiles.read(at: "values.json"), original)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        delegate.showSettings()
        presentation.requestForgetAll()
        confirmations[1](.confirmed)
        XCTAssertEqual(presentation.rememberedValues.lastOutcome, .forgotten)
        XCTAssertEqual(try dataFiles.read(at: "values.json"), Data("{\"values\":{},\"version\":1}".utf8))
        XCTAssertEqual(try openForm("Alpha").values["topic"], "Alpha default")
    }

    func testFillDeliveryUsesSharedForgetStateAndRefusalCopy() {
        let delivering = PickerViewState.forgetValuesState(picker: .fill, fill: .delivering)
        XCTAssertEqual(delivering, .delivering)
        XCTAssertEqual(Strings.forgetValuesError(LibraryError.operationFailed, state: delivering),
            RememberedValuesStrings.message(for: .deliveryInFlight))
        XCTAssertEqual(PickerViewState.forgetValuesState(picker: .delivering, fill: nil), .delivering)
        XCTAssertEqual(PickerViewState.forgetValuesState(picker: .fill, fill: .editing), .fill)
        XCTAssertEqual(PickerViewState.forgetValuesState(picker: .picker, fill: nil), .picker)
    }

    func testDeliveryDisablesPickerForgetAndSettingsReportsRefusal() throws {
        try start()
        let alpha = try identity("a.md")
        try values.record(identity: alpha, values: ["topic": "Remembered"])
        let original = try dataFiles.read(at: "values.json")
        delegate.showSettings()
        let settings = try settings().presentation
        settings.requestForgetAll()
        let fill = try openForm("Alpha")
        fill.deliver(mode: .copyOnly)
        XCTAssertEqual(try picker().state, .delivering)
        defer { scheduler.drain() }
        XCTAssertFalse(try presentation().canForgetValues)
        try presentation().forgetSelectedValues()
        XCTAssertEqual(try picker().forgetValuesError as? LibraryError, .operationFailed)
        XCTAssertEqual(try presentation().status, RememberedValuesStrings.message(for: .deliveryInFlight))
        confirmations[0](.confirmed)
        XCTAssertEqual(settings.rememberedValues.lastOutcome, .deliveryInFlight)
        XCTAssertEqual(settings.rememberedValues.message, RememberedValuesStrings.message(for: .deliveryInFlight))
        XCTAssertEqual(try dataFiles.read(at: "values.json"), original)
        XCTAssertEqual(fill.values["topic"], "Remembered")
    }

    func testClosingSettingsRevokesLateResponseAcrossReopen() throws {
        try start()
        try values.record(identity: identity("a.md"), values: ["topic": "Kept"])
        let original = try dataFiles.read(at: "values.json")
        delegate.showSettings()
        let settings = try settings()
        settings.presentation.requestForgetAll()
        let late = confirmations[0]
        try XCTUnwrap(settings.window).close()
        XCTAssertEqual(confirmationCancellations, 1)
        XCTAssertEqual(settings.presentation.rememberedValues.confirmation, .none)
        late(.confirmed)
        XCTAssertEqual(try dataFiles.read(at: "values.json"), original)
        delegate.showSettings()
        settings.presentation.requestForgetAll()
        late(.confirmed)
        XCTAssertEqual(settings.presentation.rememberedValues.confirmation, .forgetAll)
        XCTAssertEqual(try dataFiles.read(at: "values.json"), original)
        confirmations[1](.cancelled)
        XCTAssertEqual(settings.presentation.rememberedValues.confirmation, .none)
    }

    func testNativeAlertSheetCancelAndConfirmUseSharedCopyAndOutcome() throws {
        try start(confirmation: SettingsWindowController.confirmForgetAll)
        try values.record(identity: identity("a.md"), values: ["topic": "Kept"])
        let original = try dataFiles.read(at: "values.json")
        delegate.showSettings()
        let settings = try settings()
        let window = try XCTUnwrap(settings.window)
        settings.presentation.requestForgetAll()
        XCTAssertTrue(spin { window.attachedSheet != nil })
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(labels(in: sheet.contentView).contains(RememberedValuesStrings.confirmationTitle))
        XCTAssertTrue(labels(in: sheet.contentView).contains(RememberedValuesStrings.confirmationMessage))
        let cancel = try XCTUnwrap(button(RememberedValuesStrings.cancel, in: sheet.contentView))
        let forget = try XCTUnwrap(button(RememberedValuesStrings.forgetAll, in: sheet.contentView))
        XCTAssertEqual(cancel.accessibilityLabel(), RememberedValuesStrings.cancel)
        XCTAssertEqual(forget.accessibilityLabel(), RememberedValuesStrings.forgetAll)
        XCTAssertTrue(forget.hasDestructiveAction)
        cancel.performClick(nil)
        XCTAssertTrue(spin { settings.presentation.rememberedValues.confirmation == .none && window.attachedSheet == nil })
        XCTAssertEqual(try dataFiles.read(at: "values.json"), original)
        settings.presentation.requestForgetAll()
        XCTAssertTrue(spin { window.attachedSheet != nil })
        try XCTUnwrap(button(RememberedValuesStrings.forgetAll, in: window.attachedSheet?.contentView)).performClick(nil)
        XCTAssertTrue(spin { settings.presentation.rememberedValues.lastOutcome == .forgotten })
        XCTAssertEqual(try dataFiles.read(at: "values.json"), Data("{\"values\":{},\"version\":1}".utf8))
    }

    func testConfirmationResponseFromWorkerPublishesOnUIThread() throws {
        try start()
        delegate.showSettings()
        try settings().presentation.requestForgetAll()
        let done = confirmations[0]
        let model = try XCTUnwrap(delegate.rememberedValuesSettingsModel)
        let published = expectation(description: "Confirmed outcome is published on the UI thread")
        let forward = model.onChange
        model.onChange = {
            XCTAssertTrue(Thread.isMainThread)
            forward?()
            published.fulfill()
        }
        DispatchQueue.global().async { done(.confirmed) }
        wait(for: [published], timeout: 2)
        XCTAssertEqual(try settings().presentation.rememberedValues.lastOutcome, .forgotten)
    }

    func testInlineConfirmationDoesNotLeaveCancellationPending() throws {
        var cancellations = 0
        try start(confirmation: { _, done in
            done(.confirmed)
            return { cancellations += 1 }
        })
        delegate.showSettings()
        try settings().presentation.requestForgetAll()
        XCTAssertEqual(try settings().presentation.rememberedValues.lastOutcome, .forgotten)
        try XCTUnwrap(settings().window).close()
        XCTAssertEqual(cancellations, 0)
    }

    func testRememberedValuesPortDoesNotRetainCompositionRoot() throws {
        try start()
        let model = try XCTUnwrap(delegate.rememberedValuesSettingsModel)
        weak var reference = delegate
        delegate = nil
        XCTAssertNil(reference)
        model.requestForgetAll()
        model.confirmForgetAll()
        XCTAssertEqual(model.state.lastOutcome, .libraryFailure(.operationFailed))
    }

    private func prompt(title: String) -> String {
        "---\ntitle: \(title)\nfields:\n  topic: {default: \(title) default}\n---\n{{topic}}"
    }

    private func picker() throws -> PickerModel { try XCTUnwrap(delegate.pickerModel) }
    private func presentation() throws -> PickerViewState { try XCTUnwrap(delegate.pickerPresentation) }
    private func settings() throws -> SettingsWindowController { try XCTUnwrap(delegate.settingsWindow) }

    private func identity(_ path: String) throws -> PromptIdentity {
        try XCTUnwrap(picker().results.first { $0.relativePath == path }?.identity)
    }

    private func openForm(_ query: String, mode: DeliveryMode = .copyOnly) throws -> FillModel {
        let picker = try picker()
        if picker.state != .picker { picker.open() }
        picker.setQuery(query)
        picker.use(mode: mode)
        XCTAssertEqual(picker.state, .fill)
        return try XCTUnwrap(picker.fillModel)
    }

    private func draft(_ value: String, for query: String) throws {
        try openForm(query).setValue(value, name: "topic")
        try picker().escape()
    }

    private func assertNoLearningOrClipboardWrite(_ revision: Int, identities: [PromptIdentity]) throws {
        XCTAssertEqual(NSPasteboard.general.changeCount, revision)
        let usage = UsageStore(files: dataFiles, clock: SystemClock())
        for identity in identities { XCTAssertEqual(try usage.useEvents(for: identity), []) }
    }

    private func find(_ identifier: String) -> NSView? {
        func walk(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            for child in view.subviews { if let found = walk(child) { return found } }
            return nil
        }
        return (try? pickerWindow())?.contentView.flatMap(walk)
    }

    private func pickerWindow() throws -> PromptPanel {
        try XCTUnwrap(NSApp.windows.compactMap { $0 as? PromptPanel }.first {
            !originalWindows.contains(ObjectIdentifier($0))
        })
    }

    private func button(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews { if let found = button(title, in: child) { return found } }
        return nil
    }

    private func labels(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { labels(in: $0) }
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

private final class ForgetControlsScheduler: MonkeysPawCore.Scheduler {
    private var pending: [() -> Void] = []
    func after(_ delay: Duration, _ work: @escaping () -> Void) { pending.append(work) }
    func drain() { while !pending.isEmpty { pending.removeFirst()() } }
}

private final class ForgetControlsWatcher: FileStoreWatcher {
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {}
    func stop() {}
}
