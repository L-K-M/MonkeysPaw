#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxAssistantSettingsTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var environment: LinuxEnvironment!
    private var view: LinuxSettingsWindow!
    private var window: GTK.Widget!
    private var files: RootedFileStore!
    private var service: ProviderSettingsService!
    private var secrets: AssistantPageSecrets!
    private var transport: AssistantPageTransport!
    private var work: LinuxBackgroundWork!
    private weak var model: AssistantSettingsModel?
    private var modelCount = 0
    private var syncAccountUserID: ULID?
    private var sentinel = ""

    override func setUpWithError() throws {
        application = try GTKTestSupport.application()
        tools = try FakeLinuxTools()
        work = LinuxBackgroundWork()
        secrets = AssistantPageSecrets()
        transport = AssistantPageTransport()
        sentinel = "stored-key-" + UUID().uuidString
        files = try RootedFileStore(root: tools.directory.appendingPathComponent("providers"))
        service = ProviderSettingsService(store: ProviderSettingsStore(files: files), secrets: secrets)
        environment = LinuxEnvironment(application: application, environment: [
            "HOME": tools.directory.path, "PATH": tools.directory.path,
            "XDG_CONFIG_HOME": tools.directory.appendingPathComponent("config").path,
            "XDG_DATA_HOME": tools.directory.appendingPathComponent("data").path,
        ], assistantTransport: transport)
    }

    override func tearDownWithError() throws {
        transport?.releaseHeld()
        secrets?.releaseWrite()
        view?.hide()
        environment?.shutdown()
        view = nil
        if work != nil { try worker {} }
        drainUI()
        if let application { GTKTestSupport.destroy(application) }
        environment = nil
        window = nil
        application = nil
        model = nil
        service = nil
        files = nil
        secrets = nil
        transport = nil
        work = nil
        tools = nil
    }

    func testAllProfileIntentsManualModelAndClearDeleteCoherenceWithoutNetwork() throws {
        try show()
        XCTAssertFalse(try sensitive("save"))
        try click("add")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.isNewProfile == true })
        let first = try XCTUnwrap(model?.state.draft?.id)
        try input("name", "Local")
        gtk_combo_box_set_active(mp_combo_box(try control("kind")), 1)
        try input("base-url", "http://localhost:11434/v1")
        try input("model-id", "unlisted-manual-model")
        try input("key", sentinel)
        drainUI()
        XCTAssertEqual(model?.state.draft?.kind, .openaiCompatible)
        XCTAssertEqual(model?.state.draft?.baseURL, "http://localhost:11434/v1")
        XCTAssertEqual(model?.state.keyEdit, .replace)
        try save()
        XCTAssertEqual(model?.state.selectedProfileID, first)
        XCTAssertEqual(try entryText("model-id"), "unlisted-manual-model")
        try assertStoredKeyAbsent()

        try click("add")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.draft?.id != first })
        let second = try XCTUnwrap(model?.state.draft?.id)
        try input("name", "Second")
        drainUI()
        try save()
        XCTAssertEqual(model?.state.selectedProfileID, first)
        XCTAssertEqual(model?.state.draft?.id, second)
        XCTAssertTrue(try visible("activate"))
        try click("activate")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.selectedProfileID == second && self.model?.state.operation == nil })
        try input("name", "Renamed")
        drainUI()
        try save()
        XCTAssertEqual(model?.state.profiles.last?.displayName, "Renamed")
        try selectRow(0, id: first)
        XCTAssertEqual(try entryText("name"), "Local")
        XCTAssertEqual(try entryText("model-id"), "unlisted-manual-model")
        try input("model-id", "discard-me")
        drainUI()
        try click("refresh")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.draft?.modelID == "unlisted-manual-model" && self.model?.state.operation == nil })
        try click("clear-key")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.keyEdit == .clear })
        XCTAssertEqual(try entryText("key"), "")
        XCTAssertEqual(try labelText("key-edit"), LinuxAssistantSettingsStrings.keyEdit(.clear))
        XCTAssertTrue(secrets.hasPersisted(.provider(first)), "Clear remains staged until Save")
        try save()
        XCTAssertFalse(secrets.hasPersisted(.provider(first)))
        XCTAssertEqual(model?.state.keyStorage, AssistantSettingsModel.KeyStorage.none)
        XCTAssertNil(model?.state.profiles.first?.secretReference)
        try click("disable")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.selectedProfileID == nil && self.model?.state.draft == nil })
        XCTAssertEqual(try labelText("active"), LinuxAssistantSettingsStrings.inactive)
        try selectRow(1, id: second)
        try click("delete")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.profiles.count == 1 && self.model?.state.operation == nil })
        XCTAssertNil(model?.state.selectedProfileID)
        try selectRow(0, id: first)
        try click("delete")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.profiles.isEmpty == true && self.model?.state.operation == nil })
        XCTAssertNil(model?.state.draft)
        XCTAssertFalse(try sensitive("test"))
        XCTAssertTrue(transport.requests.isEmpty)
        try assertStoredKeyAbsent()
    }

    func testPasswordEntryKeepReplaceResetAndDiscardUnsavedProfile() throws {
        let saved = try seed()
        try show()
        XCTAssertEqual(gtk_entry_get_visibility(mp_entry(try control("key"))), 0)
        XCTAssertEqual(gtk_entry_get_input_purpose(mp_entry(try control("key"))), GTK_INPUT_PURPOSE_PASSWORD)
        try assertStoredKeyAbsent()
        try input("key", "replacement-" + UUID().uuidString)
        drainUI()
        XCTAssertEqual(model?.state.keyEdit, .replace)
        try click("keep-key")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.keyEdit == .keep && (try? self.entryText("key")) == "" })
        try input("key", "replacement-" + UUID().uuidString)
        drainUI()
        try save()
        XCTAssertEqual(model?.state.keyEdit, .keep)
        XCTAssertEqual(try entryText("key"), "")
        try assertStoredKeyAbsent()
        try input("key", "   ")
        drainUI()
        XCTAssertEqual(model?.state.keyEdit, .keep, "Blank input means Keep")
        try click("add")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.isNewProfile == true })
        try input("key", "unsaved-" + UUID().uuidString)
        drainUI()
        try click("delete")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.draft?.id == saved.id })
        XCTAssertEqual(try entryText("key"), "")
        XCTAssertEqual(model?.state.profiles.count, 1)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testStorageTiersUnencryptedNoticeAndEnvironmentClear() throws {
        for tier in [SecretTier.secretService, .file, .environment, .keychain] {
            view?.hide()
            let draft = ProviderDraft(displayName: tier.rawValue, kind: .openaiCompatible,
                baseURL: "http://localhost:11434/v1", modelID: "local",
                key: tier == .environment ? .keep : .replace(SecretValue(sentinel)))
            secrets.setTier(tier == .environment ? .secretService : tier)
            if tier == .environment { secrets.setEnvironment(SecretValue(sentinel), account: .provider(draft.id)) }
            try worker { try self.service.save(draft); try self.service.selectProfile(draft.id) }
            try show()
            XCTAssertEqual(model?.state.keyStorage, .saved(tier))
            XCTAssertEqual(try labelText("storage"), LinuxAssistantSettingsStrings.storage(.saved(tier)))
            XCTAssertEqual(try visible("storage-warning"), tier == .file)
            if tier == .file { XCTAssertTrue(try labelText("storage-warning").contains("unencrypted")) }
            try assertStoredKeyAbsent()
            if tier == .environment {
                try input("key", "replacement")
                drainUI()
                try click("save")
                XCTAssertTrue(GTKTestSupport.spin { self.model?.state.error == .secret(.readOnly) })
                XCTAssertEqual(try labelText("error"), LinuxAssistantSettingsStrings.settingsError(.secret(.readOnly)))
                try click("clear-key")
                XCTAssertTrue(GTKTestSupport.spin { self.model?.state.keyEdit == .clear })
                try save()
                XCTAssertEqual(model?.state.keyStorage, AssistantSettingsModel.KeyStorage.none)
                XCTAssertTrue(secrets.hasEnvironment(.provider(draft.id)))
                XCTAssertEqual(try entryText("key"), "")
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTestSuccessFillsPickerManualIDSurvivesFailureAndEmptyListing() throws {
        _ = try seed()
        try show()
        XCTAssertTrue(transport.requests.isEmpty)
        let models = [ModelDescriptor(id: "a", displayName: "Model A"), ModelDescriptor(id: "z")]
        transport.enqueue(.response(HTTPResponse(statusCode: 200,
            body: Data(#"{"data":[{"id":"z"},{"id":"a","display_name":"Model A"}]}"#.utf8))))
        try runTest(.ok(models: models))
        XCTAssertEqual(try entryText("model-id"), "manual")
        XCTAssertTrue(try sensitive("model-picker"))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.absoluteString, "http://localhost:11434/v1/models")
        XCTAssertEqual(request.requestByteCap, Limits.httpRequestCap)
        XCTAssertEqual(request.responseByteCap, Limits.responseCap)
        XCTAssertGreaterThan(request.deadline, ContinuousClock.now)
        XCTAssertNotNil(request.headers["Authorization"])
        XCTAssertEqual(try labelText("test-result"), LinuxAssistantSettingsStrings.testResult(.ok(models: models)))
        transport.enqueue(.response(HTTPResponse(statusCode: 405, body: Data(sentinel.utf8))))
        try runTest(.unsupportedListing)
        XCTAssertEqual(model?.state.availableModels, models, "An unchanged failed Test keeps suggestions")
        XCTAssertEqual(try entryText("model-id"), "manual")
        gtk_combo_box_set_active(mp_combo_box(try control("model-picker")), 1)
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.draft?.modelID == "a" })
        XCTAssertEqual(try entryText("model-id"), "a")
        XCTAssertFalse(try sensitive("model-picker"), "Editing invalidates old suggestions")
        try input("model-id", "always-allowed")
        drainUI()
        transport.enqueue(.response(HTTPResponse(statusCode: 200, body: Data(#"{"data":[]}"#.utf8))))
        try runTest(.ok(models: []))
        XCTAssertEqual(try entryText("model-id"), "always-allowed")
        XCTAssertTrue(try sensitive("model-id"))
        XCTAssertFalse(try sensitive("model-picker"))
        try assertStoredKeyAbsent()
    }

    func testAnthropicAndTypedTestFailuresNeverRenderProviderBodies() throws {
        _ = try seed(kind: .anthropic)
        try show()
        let outcomes: [(AssistantPageTransport.Reply, ConnectionTestResult)] = [
            (.response(HTTPResponse(statusCode: 401, body: Data(sentinel.utf8))), .authentication),
            (.response(HTTPResponse(statusCode: 404, body: Data(sentinel.utf8))), .notFound),
            (.response(HTTPResponse(statusCode: 429, headers: ["retry-after": "5"], body: Data(sentinel.utf8))), .rateLimited(retryAfter: 5)),
            (.failure(.networkFailure), .network),
            (.failure(.deadlineExceeded), .timeout),
            (.response(HTTPResponse(statusCode: 501, body: Data(sentinel.utf8))), .unsupportedListing),
            (.response(HTTPResponse(statusCode: 200, body: Data(sentinel.utf8))), .invalidResponse),
            (.response(HTTPResponse(statusCode: 503, body: Data(sentinel.utf8))), .providerFailure(statusCode: 503)),
        ]
        for (reply, result) in outcomes {
            transport.enqueue(reply)
            try runTest(result)
            XCTAssertEqual(try labelText("test-result"), LinuxAssistantSettingsStrings.testResult(result))
            XCTAssertTrue(try sensitive("model-id"))
            XCTAssertEqual(try entryText("model-id"), "manual")
            try assertStoredKeyAbsent()
        }
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertNotNil(request.headers["x-api-key"])
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
    }

    func testProgressCancellationEditsAndCloseRejectLateResults() throws {
        _ = try seed()
        try show()
        try startHeldTest()
        XCTAssertEqual(try labelText("progress"), LinuxAssistantSettingsStrings.testing)
        XCTAssertTrue(try visible("cancel-test"))
        XCTAssertFalse(try sensitive("test"))
        try click("cancel-test")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.isTesting == false && self.transport.cancellations == 1 })
        transport.releaseHeld()
        drainUI()
        XCTAssertTrue(model?.state.availableModels.isEmpty == true)
        XCTAssertFalse(try visible("cancel-test"))

        try startHeldTest()
        try input("model-id", "edited-while-testing")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.draft?.modelID == "edited-while-testing" && self.model?.state.isTesting == false })
        transport.releaseHeld()
        drainUI()
        XCTAssertTrue(model?.state.availableModels.isEmpty == true)
        try startHeldTest()
        let retained = model
        gtk_window_close(mp_window(window))
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_visible(self.window) == 0 && self.transport.cancellations == 3 })
        drainUI()
        XCTAssertTrue(model === retained)
        XCTAssertEqual(try entryText("key"), "")
        view.show()
        waitLoaded()
        XCTAssertEqual(modelCount, 1)
        transport.releaseHeld()
        drainUI()
        XCTAssertTrue(model?.state.availableModels.isEmpty == true)
        XCTAssertNil(model?.state.testResult)
        XCTAssertEqual(try entryText("model-id"), "manual")
    }

    func testModelPickerReflectsDraftAfterListingAndUnrelatedPublication() throws {
        _ = try seed()
        try show()
        let models = [ModelDescriptor(id: "a"), ModelDescriptor(id: "manual")]
        transport.enqueue(.response(HTTPResponse(statusCode: 200,
            body: Data(#"{"data":[{"id":"a"},{"id":"manual"}]}"#.utf8))))
        try runTest(.ok(models: models))
        XCTAssertEqual(gtk_combo_box_get_active(mp_combo_box(try control("model-picker"))), 2)
        model?.keepKey()
        drainUI()
        XCTAssertEqual(gtk_combo_box_get_active(mp_combo_box(try control("model-picker"))), 2)
        view.hide()
        view.show()
        waitLoaded()
        XCTAssertEqual(modelCount, 1)
    }

    func testHiddenSettingsIgnoresNativeActionsWithRetainedModel() throws {
        _ = try seed()
        try show()
        view.hide()
        drainUI()
        waitLoaded()
        let draft = model?.state.draft?.id
        let profiles = service.snapshot.settings
        var instance = GValue()
        g_value_init(&instance, gtk_button_get_type())
        g_value_set_object(&instance, try control("add"))
        g_signal_emitv(&instance, g_signal_lookup("clicked", gtk_button_get_type()), 0, nil)
        g_value_unset(&instance)
        try input("name", "Hidden edit")
        drainUI()
        XCTAssertEqual(model?.state.draft?.id, draft)
        XCTAssertEqual(model?.state.keyEdit, .keep)
        XCTAssertEqual(service.snapshot.settings, profiles)
        view.show()
        waitLoaded()
        XCTAssertEqual(modelCount, 1)
        XCTAssertEqual(try entryText("name"), "Saved")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testHiddenPageDetachesAndRefreshesOnceWhenShown() throws {
        _ = try seed()
        try show()
        let reads = secrets.readCount
        try input("key", "Staged replacement")
        drainUI()
        view.hide()
        try worker {}
        drainUI()
        XCTAssertEqual(try entryText("key"), "")
        XCTAssertNil(model?.onChange)
        XCTAssertEqual(model?.state.keyEdit, .keep)
        XCTAssertEqual(secrets.readCount, reads)
        model?.renameProfile("Background update")
        drainUI()
        XCTAssertEqual(secrets.readCount, reads)
        view.show()
        waitLoaded()
        try worker {}
        drainUI()
        XCTAssertEqual(modelCount, 1)
        XCTAssertEqual(secrets.readCount, reads + 1)
        XCTAssertEqual(try entryText("name"), "Saved")
        view.show()
        try worker {}
        drainUI()
        XCTAssertEqual(secrets.readCount, reads + 1)
    }

    func testShowDuringAcceptedSaveDefersOneRefreshAndKeepsMutationCallbacks() throws {
        _ = try seed()
        try show()
        var mutations = 0
        var refreshes = 0
        var previousOperation = model?.state.operation
        model?.onProfilesChanged = { mutations += 1 }
        secrets.blockNextWrite()
        try input("key", "Replacement")
        drainUI()
        try click("save")
        XCTAssertTrue(GTKTestSupport.spin { self.secrets.isWriteBlocked })
        view.hide()
        drainUI()
        XCTAssertEqual(try entryText("key"), "")
        XCTAssertNil(model?.onChange)
        view.show()
        let render = model?.onChange
        model?.onChange = {
            render?()
            let operation = self.model?.state.operation
            if operation == .loading, previousOperation != .loading { refreshes += 1 }
            previousOperation = operation
        }
        secrets.releaseWrite()
        waitLoaded()
        try worker {}
        drainUI()
        XCTAssertEqual(mutations, 2)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(modelCount, 1)
        XCTAssertEqual(try entryText("key"), "")
        XCTAssertEqual(service.snapshot.settings.profiles.first?.displayName, "Saved")
    }

    func testSavingStaysResponsivePreservesNewerMetadataAndClearsCommittedKey() throws {
        _ = try seed()
        try show()
        secrets.blockNextWrite()
        try input("key", "replacement-" + UUID().uuidString)
        drainUI()
        try click("save")
        XCTAssertTrue(GTKTestSupport.spin { self.secrets.isWriteBlocked && self.model?.state.operation == .saving })
        XCTAssertEqual(try labelText("progress"), LinuxAssistantSettingsStrings.progress(.saving))
        XCTAssertFalse(try sensitive("add"))
        XCTAssertFalse(try sensitive("test"))
        XCTAssertTrue(try sensitive("name"))
        var heartbeat = false
        GTK.onMainLoop { heartbeat = true }
        XCTAssertTrue(GTKTestSupport.spin { heartbeat })
        try input("name", "Newer staged name")
        drainUI()
        XCTAssertEqual(model?.state.draft?.displayName, "Newer staged name")
        secrets.releaseWrite()
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.operation == nil && self.model?.state.keyEdit == .keep })
        XCTAssertEqual(try entryText("key"), "")
        XCTAssertEqual(try entryText("name"), "Newer staged name")
        XCTAssertEqual(model?.state.profiles.first?.displayName, "Saved")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testUnrelatedPublishCannotOverwriteTypingBeforeDeferredInputArrives() throws {
        _ = try seed()
        try show()
        for suffix in ["name", "base-url", "model-id"] {
            let entry = try control(suffix)
            XCTAssertNotEqual(gtk_widget_grab_focus(entry), 0)
            let first = "typed-" + suffix
            let expected = first + "-second"
            var preservedFirstInput = false
            var typedSecondInput = false
            // Queue an unrelated publication before the field's first intent,
            // then simulate the next keystroke between publication and intent.
            model?.keepKey()
            GTK.onMainLoop {
                let text = String(cString: mp_entry_text(entry))
                preservedFirstInput = text.utf8.elementsEqual(first.utf8)
                mp_entry_set_text(entry, text + "-second")
                typedSecondInput = true
            }
            mp_entry_set_text(entry, first)
            XCTAssertTrue(GTKTestSupport.spin { typedSecondInput })
            drainUI()
            XCTAssertTrue(preservedFirstInput, "A stale publication overwrote native input")
            XCTAssertEqual(String(cString: mp_entry_text(entry)), expected)
            let draft = try XCTUnwrap(model?.state.draft)
            let staged = suffix == "name" ? draft.displayName : (suffix == "base-url" ? draft.baseURL : draft.modelID)
            XCTAssertEqual(staged, expected)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRetestedPickerPreservesByteDistinctUnicodeModelIDs() throws {
        _ = try seed()
        try show()
        let composed = "é"
        let decomposed = "e\u{301}"
        for id in [composed, decomposed] {
            let body = try JSONSerialization.data(withJSONObject: ["data": [["id": id]]])
            transport.enqueue(.response(HTTPResponse(statusCode: 200, body: body)))
            try runTest(.ok(models: [ModelDescriptor(id: id)]))
        }
        let returned = try XCTUnwrap(model?.state.availableModels.first?.id)
        XCTAssertTrue(returned.utf8.elementsEqual(decomposed.utf8))
        gtk_combo_box_set_active(mp_combo_box(try control("model-picker")), 1)
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.draft?.modelID != "manual" })
        let picked = try XCTUnwrap(model?.state.draft?.modelID)
        XCTAssertTrue(picked.utf8.elementsEqual(decomposed.utf8), "Picker used a previous Test's byte-distinct ID")
        XCTAssertTrue(try entryText("model-id").utf8.elementsEqual(decomposed.utf8))
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testDestinationGateAndFailedSaveClearDeleteKeepCoherentState() throws {
        let saved = try seed()
        try show()
        try input("base-url", "https://other.example/v1")
        drainUI()
        try click("save")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.requiresKeyReentry == true })
        XCTAssertEqual(try labelText("error"), LinuxAssistantSettingsStrings.settingsError(.keyRequiredForChangedDestination))
        try click("test")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.testResult == .settings(.keyRequiredForChangedDestination) })
        XCTAssertTrue(transport.requests.isEmpty)
        try click("refresh")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.draft?.baseURL == saved.baseURL && self.model?.state.operation == nil })
        secrets.setDeleteError(.deleteFailed)
        try click("clear-key")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.keyEdit == .clear })
        try click("save")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.error == .secret(.deleteFailed) && self.model?.state.operation == nil })
        waitLoaded()
        XCTAssertEqual(model?.state.keyEdit, .clear)
        XCTAssertEqual(model?.state.keyStorage, .saved(.secretService))
        XCTAssertTrue(secrets.hasPersisted(.provider(saved.id)))
        try click("delete")
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.operation == .deleting })
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.operation == nil })
        XCTAssertEqual(model?.state.profiles.count, 1)
        XCTAssertEqual(model?.state.selectedProfileID, saved.id)
        XCTAssertEqual(try labelText("error"), LinuxAssistantSettingsStrings.settingsError(.secret(.deleteFailed)))
        secrets.setDeleteError(nil)
        try save()
        XCTAssertEqual(model?.state.keyStorage, AssistantSettingsModel.KeyStorage.none)
        try assertStoredKeyAbsent()
    }

    func testReadOnlySettingsAndUnavailableTierShowTypedErrorsWithoutNetwork() throws {
        _ = try seed()
        secrets.setReadError(.locked)
        try show()
        XCTAssertEqual(model?.state.keyStorage, .failed(.secret(.locked)))
        XCTAssertEqual(try labelText("storage"), LinuxAssistantSettingsStrings.storage(.failed(.secret(.locked))))
        XCTAssertEqual(try labelText("error"), LinuxAssistantSettingsStrings.settingsError(.secret(.locked)))
        try assertStoredKeyAbsent()
        view.hide()
        gtk_window_destroy(mp_window(window))
        view = nil
        window = nil
        try files.write(Data(#"{"version":999}"#.utf8), at: "provider-settings.json")
        service = ProviderSettingsService(store: ProviderSettingsStore(files: files), secrets: secrets)
        try show()
        XCTAssertTrue(model?.state.isReadOnly == true)
        XCTAssertEqual(try labelText("error"), LinuxAssistantSettingsStrings.settingsError(.futureVersion(999)))
        XCTAssertFalse(try sensitive("add"))
        XCTAssertFalse(try sensitive("save"))
        XCTAssertFalse(try sensitive("test"))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testProductionCompositionUsesFileTierTransportAndRetiresOnShutdown() throws {
        environment.showSettings()
        XCTAssertTrue(GTKTestSupport.spin { self.settingsWindow() != nil })
        window = try XCTUnwrap(settingsWindow())
        try GTKTestSupport.selectAssistantTab(in: window)
        XCTAssertTrue(GTKTestSupport.spin { (try? self.sensitive("add")) == true })
        try click("add")
        XCTAssertTrue(GTKTestSupport.spin { (try? self.sensitive("key")) == true })
        try input("name", "Composed")
        gtk_combo_box_set_active(mp_combo_box(try control("kind")), 1)
        try input("base-url", "http://localhost:11434/v1")
        try input("model-id", "manual-composed")
        try input("key", sentinel)
        drainUI()
        var saveClicked = false
        GTK.onSignal(try control("save"), "clicked") { saveClicked = true }
        try click("save")
        XCTAssertTrue(GTKTestSupport.spin { saveClicked }, "GTK did not dispatch Save")
        let stored = GTKTestSupport.spin { (try? self.labelText("storage")) == LinuxAssistantSettingsStrings.storage(.saved(.file)) }
        let saveStatus = "\(try labelText("progress")); \(try labelText("error"))"
        XCTAssertTrue(stored, saveStatus)
        XCTAssertTrue(try visible("storage-warning"))
        try assertStoredKeyAbsent()
        XCTAssertTrue(transport.requests.isEmpty)
        transport.enqueue(.held)
        try click("test")
        XCTAssertTrue(GTKTestSupport.spin { self.transport.heldCount == 1 })
        XCTAssertEqual(try labelText("progress"), LinuxAssistantSettingsStrings.testing)
        environment.shutdown()
        XCTAssertTrue(GTKTestSupport.spin { self.transport.cancellations == 1 })
        XCTAssertEqual(gtk_widget_get_visible(window), 0)
        XCTAssertEqual(try entryText("key"), "")
        transport.releaseHeld()
        drainUI()
        XCTAssertEqual(try labelText("test-result"), "")
    }

    func testSyncKeyAccountChangeClearsNativeEntryAndPreservesProviderDraft() throws {
        try show()
        XCTAssertTrue(settled { self.model?.syncKey?.state.status == .noAccount })
        XCTAssertFalse(try sensitive("sync-generate"))
        try click("add")
        XCTAssertTrue(settled { self.model?.state.isNewProfile == true })
        try input("name", "Staged profile")
        XCTAssertTrue(settled { self.model?.state.draft?.displayName == "Staged profile" })
        let draftID = model?.state.draft?.id
        syncAccountUserID = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!
        view.accountBindingDidChange()
        XCTAssertTrue(settled { self.model?.syncKey?.state.status == .missing && self.model?.syncKey?.state.busy == false })
        XCTAssertTrue(try sensitive("sync-generate"))
        try input("sync-entry", "typed input for the old account")
        syncAccountUserID = nil
        view.accountBindingDidChange()
        XCTAssertTrue(settled { self.model?.syncKey?.state.status == .noAccount })
        XCTAssertEqual(try entryText("sync-entry"), "")
        XCTAssertEqual(model?.state.draft?.id, draftID)
        XCTAssertEqual(model?.state.draft?.displayName, "Staged profile")
    }

    private func seed(kind: ProviderKind = .openaiCompatible) throws -> ProviderDraft {
        let draft = ProviderDraft(displayName: "Saved", kind: kind,
            baseURL: kind == .anthropic ? "https://api.anthropic.com" : "http://localhost:11434/v1",
            modelID: "manual", key: .replace(SecretValue(sentinel)))
        try worker { try self.service.save(draft) }
        return draft
    }

    private func show() throws {
        if view == nil {
            view = LinuxSettingsWindow(application: application, general: environment.generalSettingsModel,
                shortcuts: environment.shortcutsSettingsModel, rememberedValues: environment.rememberedValuesSettingsModel,
                delivery: environment.deliverySettingsModel, updates: environment.updateSettingsModel, session: .otherX11,
                makeAssistant: { [weak self] in
                    guard let self else { return nil }
                    let main = GLibMainThread()
                    let assistant = AssistantService(providerSettings: self.service,
                        anthropic: AnthropicClient(transport: self.transport),
                        openAICompatible: OpenAIClient(transport: self.transport, providerState: ProviderStateStore(files: self.files)),
                        work: self.work, main: main)
                    let syncKey = ProviderSyncKeyModel(keys: ProviderSyncKeyService(secrets: self.secrets, entropy: SystemEntropy()),
                        accountUserID: { [weak self] in self?.syncAccountUserID }, work: self.work, mainThread: main)
                    let model = AssistantSettingsModel(settings: self.service, assistant: assistant,
                        work: self.work, mainThread: main, syncKey: syncKey)
                    self.model = model
                    self.modelCount += 1
                    return model
                }, chooser: SettingsFolderChooser(), openSetup: { XCTFail("Unexpected Setup") })
        }
        view.show()
        window = try XCTUnwrap(settingsWindow())
        gtk_stack_set_visible_child_name(mp_stack(try settingsWidget("settings-stack", in: window)), "assistant")
        waitLoaded()
    }

    private func waitLoaded() {
        drainUI() // A retained model can still be idle before show()'s queued refresh starts.
        XCTAssertTrue(settled { self.model != nil && self.model?.state.operation == nil && self.model?.state.keyStorage != .loading })
    }

    /// Loads and saves reach the secret store on a worker; a loaded host can
    /// exceed the default three-second spin (observed at load average 10).
    private func settled(_ predicate: () -> Bool) -> Bool {
        GTKTestSupport.spin(until: predicate, timeout: .seconds(10))
    }

    private func save() throws {
        let reset = model?.state.keyInputReset
        try click("save")
        XCTAssertTrue(settled { self.model?.state.operation == nil && self.model?.state.keyInputReset != reset })
        waitLoaded()
        XCTAssertNil(model?.state.error)
    }

    private func runTest(_ expected: ConnectionTestResult) throws {
        let count = transport.requests.count
        try click("test")
        XCTAssertTrue(GTKTestSupport.spin { self.transport.requests.count == count + 1 && self.model?.state.isTesting == false && self.model?.state.testResult == expected })
    }

    private func startHeldTest() throws {
        transport.enqueue(.held)
        try click("test")
        XCTAssertTrue(GTKTestSupport.spin { self.transport.heldCount == 1 && self.model?.state.isTesting == true })
    }

    private func selectRow(_ index: Int32, id: ProviderProfileID) throws {
        let list = try control("profiles")
        gtk_list_box_select_row(mp_list_box(list), gtk_list_box_get_row_at_index(mp_list_box(list), index))
        XCTAssertTrue(GTKTestSupport.spin { self.model?.state.draft?.id == id && self.model?.state.operation == nil && self.model?.state.keyStorage != .loading })
    }

    private func control(_ suffix: String) throws -> GTK.Widget { try settingsWidget("settings-assistant-" + suffix, in: window) }
    private func click(_ suffix: String) throws { XCTAssertNotEqual(gtk_widget_activate(try control(suffix)), 0) }
    private func input(_ suffix: String, _ text: String) throws { mp_entry_set_text(try control(suffix), text) }
    private func entryText(_ suffix: String) throws -> String { String(cString: mp_entry_text(try control(suffix))) }
    private func labelText(_ suffix: String) throws -> String { String(cString: gtk_label_get_text(mp_label(try control(suffix)))) }
    private func visible(_ suffix: String) throws -> Bool { gtk_widget_is_visible(try control(suffix)) != 0 }
    private func sensitive(_ suffix: String) throws -> Bool { gtk_widget_is_sensitive(try control(suffix)) != 0 }

    private func assertStoredKeyAbsent(file: StaticString = #filePath, line: UInt = #line) throws {
        func textContainsKey(_ widget: GTK.Widget) -> Bool {
            let instance = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self)
            if g_type_check_instance_is_a(instance, gtk_label_get_type()) != 0,
               String(cString: gtk_label_get_text(mp_label(widget))).contains(sentinel) { return true }
            if g_type_check_instance_is_a(instance, gtk_editable_get_type()) != 0,
               String(cString: mp_entry_text(widget)).contains(sentinel) { return true }
            var child = gtk_widget_get_first_child(widget)
            while let current = child {
                if textContainsKey(current) { return true }
                child = gtk_widget_get_next_sibling(current)
            }
            return false
        }
        XCTAssertFalse(textContainsKey(window), "A stored key reached widget text", file: file, line: line)
        if let data = try? files.read(at: "provider-settings.json") {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(sentinel), file: file, line: line)
        }
    }

    private func settingsWindow() -> GTK.Widget? {
        var node = gtk_application_get_windows(application)
        while let current = node {
            if let raw = current.pointee.data {
                let window = raw.assumingMemoryBound(to: GtkWindow.self)
                if gtk_window_get_title(window).map(String.init(cString:)) == LinuxStrings.settings {
                    return mp_window_widget(window)
                }
            }
            node = current.pointee.next
        }
        return nil
    }

    private func worker(_ body: @escaping () throws -> Void) throws {
        let running = try XCTUnwrap(work, "Assistant settings worker unavailable")
        var result: Result<Void, Error>?
        running.run {
            let outcome = Result(catching: body)
            GTK.onMainLoop { result = outcome }
        }
        XCTAssertTrue(GTKTestSupport.spin { result != nil })
        try XCTUnwrap(result).get()
    }

    private func drainUI() {
        var drained = false
        GTK.onMainLoop { drained = true }
        XCTAssertTrue(GTKTestSupport.spin { drained })
    }
}

private final class AssistantPageSecrets: SecretStore {
    private let lock = NSLock()
    private var persisted: [SecretAccount: StoredSecret] = [:]
    private var environment: [SecretAccount: SecretValue] = [:]
    private var tier: SecretTier = .secretService
    private var readError: SecretStoreError?
    private var deleteError: SecretStoreError?
    private var writeGate: DispatchSemaphore?
    private var writeBlocked = false
    private var reads = 0

    var isWriteBlocked: Bool { locked { writeBlocked } }
    var readCount: Int { locked { reads } }
    func setTier(_ value: SecretTier) { locked { tier = value } }
    func setEnvironment(_ value: SecretValue, account: SecretAccount) { locked { environment[account] = value } }
    func hasEnvironment(_ account: SecretAccount) -> Bool { locked { environment[account] != nil } }
    func hasPersisted(_ account: SecretAccount) -> Bool { locked { persisted[account] != nil } }
    func setReadError(_ value: SecretStoreError?) { locked { readError = value } }
    func setDeleteError(_ value: SecretStoreError?) { locked { deleteError = value } }
    func blockNextWrite() { locked { writeGate = DispatchSemaphore(value: 0) } }
    func releaseWrite() { locked { writeGate?.signal(); writeGate = nil; writeBlocked = false } }

    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        XCTAssertFalse(Thread.isMainThread, "Secret I/O must stay off GLib")
        return try locked {
            reads += 1
            if let readError { throw readError }
            if case .effective = source, let value = environment[account] {
                return StoredSecret(value: value, tier: .environment)
            }
            return persisted[account]
        }
    }

    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        XCTAssertFalse(Thread.isMainThread, "Secret I/O must stay off GLib")
        let gate = locked { () -> DispatchSemaphore? in
            if writeGate != nil { writeBlocked = true }
            return writeGate
        }
        gate?.wait()
        return locked { persisted[account] = StoredSecret(value: value, tier: tier); return tier }
    }

    func delete(account: SecretAccount) throws {
        XCTAssertFalse(Thread.isMainThread, "Secret I/O must stay off GLib")
        try locked {
            if let deleteError { throw deleteError }
            persisted[account] = nil
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Held replies deliberately ignore cancellation to prove native retirement.
private final class AssistantPageTransport: HTTPTransporting, @unchecked Sendable {
    enum Reply { case response(HTTPResponse), failure(HTTPTransportError), held }
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var recorded: [HTTPRequest] = []
    private var held: [CheckedContinuation<HTTPResponse, Error>] = []
    private var cancelled = 0

    var requests: [HTTPRequest] { locked { recorded } }
    var heldCount: Int { locked { held.count } }
    var cancellations: Int { locked { cancelled } }
    func enqueue(_ reply: Reply) { locked { replies.append(reply) } }
    func releaseHeld() {
        let pending = locked { let pending = held; held = []; return pending }
        let response = HTTPResponse(statusCode: 200, body: Data(#"{"data":[{"id":"late"}]}"#.utf8))
        pending.forEach { $0.resume(returning: response) }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        XCTAssertFalse(Thread.isMainThread, "Network work must stay off GLib")
        let reply = locked { () -> Reply in
            recorded.append(request)
            guard !replies.isEmpty else { XCTFail("Unexpected request"); return .failure(.networkFailure) }
            return replies.removeFirst()
        }
        switch reply {
        case .response(let response): return response
        case .failure(let error): throw error
        case .held:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in locked { held.append(continuation) } }
            } onCancel: { self.locked { self.cancelled += 1 } }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
#endif
