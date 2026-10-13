import AppKit
import Combine
import MonkeysPawCore
import SwiftUI
import XCTest
@testable import MonkeysPaw

final class MacAssistantSettingsTests: XCTestCase {
    func testLoadingAndEveryDraftIntentStayLocalUntilSaveOrTest() throws {
        let h = try MacAssistantSettingsHarness()
        let view = h.presentation
        XCTAssertEqual(view.state.operation, .loading)
        XCTAssertNotNil(view.progressMessage)
        XCTAssertFalse(view.canChangeProfiles)
        view.addProfile()
        view.save()
        view.testConnection()
        XCTAssertNil(view.state.draft)
        h.work.drain()
        XCTAssertTrue(view.canChangeProfiles)
        XCTAssertFalse(view.canSave)
        view.addProfile()
        let id = try XCTUnwrap(view.state.draft?.id)
        view.renameProfile("Local Ollama")
        view.setKind(.openaiCompatible)
        view.setBaseURL("http://localhost:11434/v1")
        view.setModelID("manual-unlisted-model")
        view.setKeyInput("replacement")
        XCTAssertEqual(view.state.keyEdit, .replace)
        view.setKeyInput(" \n\t")
        XCTAssertEqual(view.state.keyEdit, .keep)
        view.clearKey()
        XCTAssertEqual(view.state.keyEdit, .clear)
        view.keepKey()
        XCTAssertEqual(view.state.keyEdit, .keep)
        XCTAssertTrue(view.state.isNewProfile)
        XCTAssertTrue(view.state.profiles.isEmpty)
        XCTAssertEqual(h.files.writes, 0)
        XCTAssertEqual(h.secrets.reads, 0)
        XCTAssertEqual(h.secrets.writes, 0)
        XCTAssertEqual(h.client.calls, 0)

        view.save()
        XCTAssertEqual(view.state.operation, .saving)
        XCTAssertFalse(view.canChangeProfiles)
        XCTAssertFalse(view.canTest)
        XCTAssertTrue(view.canEditDraft)
        view.addProfile()
        view.renameProfile("Newer staged name")
        view.setModelID("newer-manual-model")
        view.setKeyInput("newer-staged-key")
        let reset = view.state.keyInputReset
        h.work.drain()
        XCTAssertEqual(view.state.profiles.map(\.displayName), ["Local Ollama"])
        XCTAssertEqual(view.state.profiles.first?.modelID, "manual-unlisted-model")
        XCTAssertEqual(view.state.selectedProfileID, id)
        XCTAssertEqual(view.state.draft?.displayName, "Newer staged name")
        XCTAssertEqual(view.state.draft?.modelID, "newer-manual-model")
        XCTAssertEqual(view.state.keyEdit, .replace)
        XCTAssertEqual(view.state.keyInputReset, reset, "Save must preserve newer secure-field input")
        XCTAssertEqual(h.secrets.writes, 0, "The first Save captured the earlier key edit")
        view.save()
        h.work.drain()
        XCTAssertEqual(view.state.profiles.map(\.displayName), ["Newer staged name"])
        XCTAssertEqual(view.state.profiles.first?.modelID, "newer-manual-model")
        let saved = try XCTUnwrap(view.state.profiles.first)
        XCTAssertEqual(try h.settings.resolveForTesting(ProviderDraft(profile: saved)).key,
                       SecretValue("newer-staged-key"))
        XCTAssertEqual(view.state.keyEdit, .keep)
        XCTAssertNil(view.state.operation)
        XCTAssertNil(view.progressMessage)
    }

    func testSelectRenameRefreshDisableAndDeleteRemainCoherent() throws {
        let first = ProviderDraft(displayName: "First")
        let second = ProviderDraft(displayName: "Second")
        let h = try MacAssistantSettingsHarness(profiles: [first, second])
        h.work.drain()
        let view = h.presentation
        XCTAssertEqual(view.state.selectedProfileID, first.id)
        view.selectProfile(second.id)
        XCTAssertEqual(view.state.operation, .selecting)
        XCTAssertFalse(view.canEditDraft)
        h.work.drain()
        XCTAssertEqual(view.state.draft?.id, second.id)
        view.renameProfile("Staged rename")
        view.refresh()
        h.work.drain()
        XCTAssertEqual(view.state.draft?.displayName, "Second")
        view.renameProfile("Renamed")
        view.save()
        h.work.drain()
        XCTAssertEqual(view.state.profiles.map(\.displayName), ["First", "Renamed"])
        view.addProfile()
        XCTAssertEqual(view.state.selectedProfileID, second.id)
        let writes = h.files.writes
        let secretWrites = h.secrets.writes
        let reset = view.state.keyInputReset
        view.deleteProfile()
        XCTAssertNil(view.state.operation, "Discarding a new draft is a local model intent")
        h.work.drain()
        XCTAssertEqual(view.state.profiles.count, 2, "Deleting an unsaved draft discards it")
        XCTAssertEqual(view.state.draft?.id, second.id)
        XCTAssertFalse(view.state.isNewProfile)
        XCTAssertNil(view.state.error)
        XCTAssertNotEqual(view.state.keyInputReset, reset)
        XCTAssertEqual(h.files.writes, writes)
        XCTAssertEqual(h.secrets.writes, secretWrites)
        view.deleteProfile()
        XCTAssertEqual(view.state.operation, .deleting)
        h.work.drain()
        XCTAssertEqual(view.state.profiles.map(\.id), [first.id])
        XCTAssertNil(view.state.selectedProfileID)
        XCTAssertNil(view.state.draft)
        XCTAssertEqual(view.state.keyStorage, .none)
        XCTAssertEqual(view.activeProfileMessage, SettingsAssistantStrings.inactive)
        view.selectProfile(first.id)
        h.work.drain()
        view.selectProfile(nil)
        h.work.drain()
        XCTAssertNil(view.state.draft)
        XCTAssertNil(view.state.selectedProfileID)
        XCTAssertEqual(view.state.profiles.map(\.id), [first.id])
        XCTAssertEqual(h.client.calls, 0)
    }

    func testNewDraftUnselectsOldRowAndSavedInactiveDraftCanBeActivated() throws {
        let original = ProviderDraft(displayName: "Original")
        let h = try MacAssistantSettingsHarness(profiles: [original])
        h.work.drain()
        let view = h.presentation
        XCTAssertEqual(view.profileSelection, original.id)
        view.addProfile()
        XCTAssertNil(view.profileSelection, "No saved row is selected while editing a new draft")
        XCTAssertEqual(view.state.selectedProfileID, original.id)
        XCTAssertFalse(view.canActivateDraft)
        view.selectProfile(original.id)
        h.work.drain()
        XCTAssertEqual(view.state.draft?.id, original.id, "The active row can return from a new draft")
        view.addProfile()
        view.renameProfile("New saved profile")
        let newID = try XCTUnwrap(view.state.draft?.id)
        view.save()
        h.work.drain()
        XCTAssertEqual(view.state.selectedProfileID, original.id)
        XCTAssertEqual(view.profileSelection, newID)
        XCTAssertTrue(view.canActivateDraft, "The edited saved row needs an explicit activation path")
        view.activateProfile()
        h.work.drain()
        XCTAssertEqual(view.state.selectedProfileID, newID)
        XCTAssertEqual(view.state.draft?.id, newID)
        XCTAssertFalse(view.canActivateDraft)
        XCTAssertEqual(h.client.calls, 0)
    }

    func testKeyNeverEntersPublishedOrDisplayedStringsAndNativeResetPreservesClear() throws {
        let sentinel = "saved-key-" + UUID().uuidString
        let profile = ProviderDraft(displayName: "Private", key: .replace(SecretValue(sentinel)))
        let h = try MacAssistantSettingsHarness(profiles: [profile])
        var published: [AssistantSettingsModel.State] = []
        let observation = h.presentation.$state.sink { published.append($0) }
        defer { observation.cancel() }
        h.work.drain()
        let view = h.presentation
        XCTAssertEqual(view.storageMessage, "Key saved · Keychain")
        XCTAssertEqual(view.state.keyEdit, .keep)

        let field = NSSecureTextField(frame: .zero)
        let coordinator = SettingsAssistantKeyField.Coordinator()
        field.delegate = coordinator
        coordinator.update(field, reset: view.state.keyInputReset, isEditable: view.canEditDraft,
                           onInput: view.setKeyInput)
        XCTAssertTrue(field.stringValue.isEmpty, "Saved keys must never be supplied to the field")
        field.stringValue = sentinel
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(view.state.keyEdit, .replace)
        view.clearKey()
        coordinator.update(field, reset: view.state.keyInputReset, isEditable: view.canEditDraft,
                           onInput: view.setKeyInput)
        XCTAssertTrue(field.stringValue.isEmpty)
        XCTAssertEqual(view.state.keyEdit, .clear, "Programmatic clearing must not forward blank Keep")
        view.keepKey()
        view.setKeyInput(sentinel)
        view.save()
        h.work.drain()
        coordinator.update(field, reset: view.state.keyInputReset, isEditable: view.canEditDraft,
                           onInput: view.setKeyInput)
        XCTAssertTrue(field.stringValue.isEmpty)
        XCTAssertEqual(view.state.keyEdit, .keep)
        XCTAssertTrue(h.files.contents.values.allSatisfy { !String(decoding: $0, as: UTF8.self).contains(sentinel) })
        for state in published { assertNoKey(sentinel, state: state) }
        assertNoKey(sentinel, state: view.state)
        XCTAssertFalse(([view.activeProfileMessage, view.storageMessage, view.keyEditMessage]
            + view.errorMessages).contains { $0.contains(sentinel) })
        field.stringValue = sentinel
        SettingsAssistantKeyField.dismantleNSView(field, coordinator: coordinator)
        XCTAssertTrue(field.stringValue.isEmpty)
        XCTAssertNil(field.delegate)
    }

    func testTierLabelsAndUnencryptedWarningIncludeEnvironmentReadOnly() throws {
        for tier in [SecretTier.keychain, .secretService, .environment, .file] {
            let profile = ProviderDraft(key: .replace(SecretValue("test-key")))
            let h = try MacAssistantSettingsHarness(profiles: [profile])
            h.secrets.tier = tier
            h.work.drain()
            XCTAssertEqual(h.presentation.state.keyStorage.tier, tier)
            XCTAssertEqual(h.presentation.storageWarning != nil, tier == .file)
            if tier == .file { XCTAssertTrue(h.presentation.storageMessage.contains("unencrypted")) }
            if tier == .environment {
                XCTAssertTrue(h.presentation.storageMessage.contains("read-only"))
                h.presentation.setKeyInput("replacement")
                h.presentation.save()
                h.work.drain()
                XCTAssertEqual(h.presentation.state.error, .secret(.readOnly))
                XCTAssertFalse(h.presentation.errorMessages.isEmpty)
            }
        }
    }

    func testClearAndDeleteFailuresKeepSavedStatusAndSuccessfulClearDropsReference() throws {
        let profile = ProviderDraft(key: .replace(SecretValue("test-key")))
        let h = try MacAssistantSettingsHarness(profiles: [profile])
        h.work.drain()
        let view = h.presentation
        view.clearKey()
        XCTAssertEqual(view.state.keyStorage, .saved(.keychain))
        h.secrets.deleteError = .deleteFailed
        view.save()
        h.work.drain()
        XCTAssertEqual(view.state.error, .secret(.deleteFailed))
        XCTAssertEqual(view.state.keyEdit, .clear)
        XCTAssertEqual(view.state.keyStorage, .saved(.keychain))
        view.deleteProfile()
        h.work.drain()
        XCTAssertEqual(view.state.profiles.count, 1)
        XCTAssertEqual(view.state.draft?.id, profile.id)
        h.secrets.deleteError = nil
        view.save()
        h.work.drain()
        XCTAssertNil(view.state.error)
        XCTAssertNil(view.state.profiles.first?.secretReference)
        XCTAssertEqual(view.state.keyEdit, .keep)
        XCTAssertEqual(view.state.keyStorage, .none)
        view.refresh()
        h.work.drain()
        XCTAssertEqual(view.state.keyStorage, .none)
        view.deleteProfile()
        h.work.drain()
        XCTAssertNil(view.state.draft)
        XCTAssertEqual(view.state.keyStorage, .none)
        XCTAssertTrue(view.state.profiles.isEmpty)
    }

    func testSaveValidationAndDestinationReentryUseTypedCopy() throws {
        let profile = ProviderDraft(key: .replace(SecretValue("test-key")))
        let h = try MacAssistantSettingsHarness(profiles: [profile])
        h.work.drain()
        let view = h.presentation
        view.setBaseURL("https://other.example")
        view.save()
        h.work.drain()
        XCTAssertEqual(view.state.error, .keyRequiredForChangedDestination)
        XCTAssertTrue(view.state.requiresKeyReentry)
        XCTAssertEqual(view.errorMessages, [SettingsAssistantStrings.settingsError(.keyRequiredForChangedDestination)])
        view.setKeyInput("new-test-key")
        view.save()
        h.work.drain()
        XCTAssertNil(view.state.error)
        view.setBaseURL("http://remote.example")
        view.save()
        h.work.drain()
        XCTAssertEqual(view.state.error, .insecureBaseURL)
        XCTAssertEqual(view.errorMessages, [SettingsAssistantStrings.settingsError(.insecureBaseURL)])
        XCTAssertEqual(view.state.draft?.baseURL, "http://remote.example")
    }

    func testConnectionSuccessSuppliesPickerAndManualModelAlwaysSurvives() throws {
        let h = try MacAssistantSettingsHarness()
        h.work.drain()
        let view = h.presentation
        view.addProfile()
        view.setKind(.openaiCompatible)
        view.setBaseURL("http://localhost:11434/v1")
        view.setModelID("manual-before-test")
        let models = [ModelDescriptor(id: "listed", displayName: "Listed model")]
        h.client.result = .success(AssistantModelPage(models: models))
        runTest(h, expecting: .ok(models: models))
        XCTAssertEqual(view.state.availableModels, models)
        XCTAssertEqual(view.state.draft?.modelID, "manual-before-test")
        XCTAssertEqual(view.testMessage, SettingsAssistantStrings.testResult(.ok(models: models)))
        XCTAssertEqual(SettingsAssistantStrings.modelLabel(models[0]), "Listed model (listed)")
        view.setModelID(models[0].id)
        XCTAssertEqual(view.state.draft?.modelID, "listed")
        view.setModelID("manual-after-picker")
        h.client.result = .success(AssistantModelPage(models: []))
        runTest(h, expecting: .ok(models: []))
        XCTAssertTrue(view.state.availableModels.isEmpty)
        XCTAssertEqual(view.state.draft?.modelID, "manual-after-picker")
        XCTAssertTrue(view.canEditDraft)
        view.save()
        h.work.drain()
        XCTAssertEqual(view.state.profiles.first?.modelID, "manual-after-picker")
    }

    func testEveryConnectionFailureShowsTypedCopyAndKeepsManualID() throws {
        let cases: [(AssistantError, ConnectionTestResult)] = [
            (.authentication, .authentication), (.modelNotFound, .notFound),
            (.rateLimited(retryAfter: 3), .rateLimited(retryAfter: 3)),
            (.transport(.networkFailure), .network), (.transport(.deadlineExceeded), .timeout),
            (.providerFailure(statusCode: 405), .unsupportedListing), (.invalidOutput, .invalidResponse),
            (.providerFailure(statusCode: 503), .providerFailure(statusCode: 503))
        ]
        for (error, result) in cases {
            let h = try MacAssistantSettingsHarness()
            h.work.drain()
            h.presentation.addProfile()
            h.presentation.setModelID("manual-model")
            h.client.result = .failure(error)
            runTest(h, expecting: result)
            XCTAssertEqual(h.presentation.testMessage, SettingsAssistantStrings.testResult(result))
            XCTAssertEqual(h.presentation.state.draft?.modelID, "manual-model")
            XCTAssertTrue(h.presentation.canEditDraft)
            XCTAssertTrue(h.presentation.canTest)
        }
    }

    func testLocalTestFailureCancelAndRetirementNeverStartAClientRequest() throws {
        let h = try MacAssistantSettingsHarness()
        h.work.drain()
        let view = h.presentation
        view.addProfile()
        view.setBaseURL("invalid-url")
        runTest(h, expecting: .settings(.invalidBaseURL))
        XCTAssertEqual(view.testMessage, SettingsAssistantStrings.settingsError(.invalidBaseURL))
        XCTAssertEqual(h.client.calls, 0)
        view.setBaseURL(ProviderKind.anthropic.defaultBaseURL)
        view.testConnection()
        XCTAssertTrue(view.state.isTesting)
        view.cancelTest()
        XCTAssertFalse(view.state.isTesting)
        h.work.drain()
        XCTAssertEqual(h.client.calls, 0)
        view.testConnection()
        XCTAssertTrue(view.state.isTesting)
        weak var model = h.model
        h.model = nil
        view.retire()
        XCTAssertNil(model, "Retiring the view releases the model and its Test handle")
        h.work.drain()
        XCTAssertEqual(h.client.calls, 0)
        XCTAssertFalse(view.canChangeProfiles)
        view.save()
        view.testConnection()
        XCTAssertEqual(h.client.calls, 0)
    }

    func testReadOnlySettingsDisableMutationsAndDisplayFailure() throws {
        let h = try MacAssistantSettingsHarness(settingsData: Data(#"{"version":2}"#.utf8))
        h.work.drain()
        let view = h.presentation
        XCTAssertTrue(view.state.isReadOnly)
        XCTAssertFalse(view.canChangeProfiles)
        XCTAssertFalse(view.canSave)
        XCTAssertFalse(view.canEditDraft)
        XCTAssertFalse(view.errorMessages.isEmpty)
        view.addProfile()
        view.selectProfile(nil)
        view.save()
        view.testConnection()
        XCTAssertEqual(h.files.writes, 0)
        XCTAssertEqual(h.secrets.reads, 0)
        XCTAssertEqual(h.client.calls, 0)
    }

    func testDiscardAndReloadCancelsQueuedTestForTheDiscardedDraft() throws {
        let profile = ProviderDraft(displayName: "Saved")
        let h = try MacAssistantSettingsHarness(profiles: [profile])
        h.work.drain()
        let view = h.presentation
        view.renameProfile("Discarded")
        view.setModelID("discarded-model")
        view.setKeyInput("discarded-key")
        let reset = view.state.keyInputReset
        let writes = h.files.writes
        view.testConnection()
        XCTAssertTrue(view.state.isTesting)

        view.refresh()
        XCTAssertFalse(view.state.isTesting, "Reload cancels before queued Test work can run")
        XCTAssertEqual(view.state.operation, .loading)
        h.work.drain()
        XCTAssertEqual(view.state.draft?.displayName, "Saved")
        XCTAssertEqual(view.state.draft?.modelID, profile.modelID)
        XCTAssertEqual(view.state.keyEdit, .keep)
        XCTAssertNotEqual(view.state.keyInputReset, reset)
        XCTAssertNil(view.state.testResult)
        XCTAssertTrue(view.state.availableModels.isEmpty)
        XCTAssertEqual(h.client.calls, 0)
        XCTAssertEqual(h.files.writes, writes)
        XCTAssertEqual(h.secrets.writes, 0)
    }

    /// The controller tests use this public Core graph without native I/O.
    static func makeModel(work: BackgroundWork) -> AssistantSettingsModel {
        let files = MacAssistantSettingsFiles()
        let settings = ProviderSettingsService(store: ProviderSettingsStore(files: files),
            secrets: MacAssistantSettingsSecrets())
        let client = MacAssistantSettingsClient()
        let main = DispatchMainThread()
        let assistant = AssistantService(providerSettings: settings, anthropic: client,
            openAICompatible: client, work: work, main: main)
        return AssistantSettingsModel(settings: settings, assistant: assistant, work: work, mainThread: main)
    }

    private func runTest(_ h: MacAssistantSettingsHarness, expecting result: ConnectionTestResult,
                         file: StaticString = #filePath, line: UInt = #line) {
        let done = expectation(description: "Typed connection result")
        var completed = false
        let observation = h.presentation.$state.sink { state in
            XCTAssertTrue(Thread.isMainThread, file: file, line: line)
            if state.testResult == result, !state.isTesting, !completed {
                completed = true
                done.fulfill()
            }
        }
        h.presentation.testConnection()
        XCTAssertTrue(h.presentation.state.isTesting, file: file, line: line)
        XCTAssertEqual(h.presentation.progressMessage, SettingsAssistantStrings.testing, file: file, line: line)
        h.work.drain()
        wait(for: [done], timeout: 3)
        observation.cancel()
        XCTAssertEqual(h.presentation.state.testResult, result, file: file, line: line)
        XCTAssertNil(h.presentation.progressMessage, file: file, line: line)
    }

    private func assertNoKey(_ sentinel: String, state: AssistantSettingsModel.State,
                             file: StaticString = #filePath, line: UInt = #line) {
        var strings = [state.description, state.debugDescription,
            SettingsAssistantStrings.storage(state.keyStorage), SettingsAssistantStrings.keyEdit(state.keyEdit)]
        if let draft = state.draft {
            strings += [draft.displayName, draft.baseURL, draft.modelID, draft.description, draft.debugDescription]
        }
        for profile in state.profiles {
            strings += [profile.displayName, profile.baseURL.absoluteString, profile.modelID]
        }
        strings += state.availableModels.flatMap { [$0.id, $0.displayName ?? "", SettingsAssistantStrings.modelLabel($0)] }
        if let result = state.testResult { strings.append(SettingsAssistantStrings.testResult(result)) }
        for error in [state.error, state.readOnlyError].compactMap({ $0 }) {
            strings.append(SettingsAssistantStrings.settingsError(error))
        }
        XCTAssertFalse(strings.contains { $0.contains(sentinel) }, "A key entered rendered state", file: file, line: line)
    }
}

/// Public Core API, memory-only ports and an explicit serial work queue.
private final class MacAssistantSettingsHarness {
    let files = MacAssistantSettingsFiles()
    let secrets = MacAssistantSettingsSecrets()
    let client = MacAssistantSettingsClient()
    let work = MacAssistantSettingsWork()
    let settings: ProviderSettingsService
    var model: AssistantSettingsModel?
    let presentation: AssistantSettingsViewState

    init(profiles: [ProviderDraft] = [], settingsData: Data? = nil) throws {
        if let settingsData { files.contents["provider-settings.json"] = settingsData }
        let service = ProviderSettingsService(store: ProviderSettingsStore(files: files), secrets: secrets)
        settings = service
        for profile in profiles { try service.save(profile) }
        let main = DispatchMainThread()
        let assistant = AssistantService(providerSettings: service, anthropic: client,
            openAICompatible: client, work: work, main: main)
        let model = AssistantSettingsModel(settings: service, assistant: assistant, work: work, mainThread: main)
        self.model = model
        presentation = AssistantSettingsViewState(model: model, mainThread: main)
    }

    deinit { presentation.retire() }
}

private final class MacAssistantSettingsWork: BackgroundWork {
    private var pending: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { pending.append(work) }
    func drain(file: StaticString = #filePath, line: UInt = #line) {
        var processed = 0
        while !pending.isEmpty {
            guard processed < 10_000 else {
                pending.removeAll()
                XCTFail("Assistant work did not settle after 10,000 items", file: file, line: line)
                return
            }
            processed += 1
            pending.removeFirst()()
        }
    }
}

private final class MacAssistantSettingsSecrets: SecretStore {
    var tier = SecretTier.keychain
    var deleteError: SecretStoreError?
    private var values: [SecretAccount: SecretValue] = [:]
    private(set) var reads = 0
    private(set) var writes = 0

    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        reads += 1
        return values[account].map { StoredSecret(value: $0, tier: tier) }
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        writes += 1
        values[account] = value
        return tier
    }
    func delete(account: SecretAccount) throws {
        if let deleteError { throw deleteError }
        values[account] = nil
    }
}

private final class MacAssistantSettingsFiles: FileStore {
    var contents: [String: Data] = [:]
    private(set) var writes = 0
    func listFiles() throws -> [StoredFile] { [] }
    func stamp(at path: String) throws -> FileStamp? { nil }
    func read(at path: String) throws -> Data {
        guard let data = contents[path] else { throw FileStoreError.notFound }
        return data
    }
    func write(_ data: Data, at path: String) throws { writes += 1; contents[path] = data }
    func writePrivate(_ data: Data, at path: String) throws { try write(data, at: path) }
    func create(_ data: Data, at path: String) throws {
        guard contents[path] == nil else { throw FileStoreError.alreadyExists }
        try write(data, at: path)
    }
    func delete(at path: String) throws { contents[path] = nil }
    func move(from source: String, to destination: String) throws {
        guard contents[destination] == nil else { throw FileStoreError.alreadyExists }
        contents[destination] = try read(at: source)
        contents[source] = nil
    }
}

private final class MacAssistantSettingsClient: AssistantClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<AssistantModelPage, AssistantError> = .success(AssistantModelPage(models: []))
    private var storedCalls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return storedCalls }
    var result: Result<AssistantModelPage, AssistantError> {
        get { lock.lock(); defer { lock.unlock() }; return storedResult }
        set { lock.lock(); defer { lock.unlock() }; storedResult = newValue }
    }
    func perform(_ request: AssistantRequest, using connection: ProviderConnection) async throws -> AssistantResponse {
        throw AssistantError.notConfigured
    }
    func perform(_ request: AssistantRequest, using connection: ProviderConnection,
                 deadline: ContinuousClock.Instant) async throws -> AssistantResponse {
        throw AssistantError.notConfigured
    }
    func listModels(using connection: ProviderConnection) async throws -> AssistantModelPage { try next() }
    func listModels(using connection: ProviderConnection, afterID: String?,
                    deadline: ContinuousClock.Instant) async throws -> AssistantModelPage { try next() }
    private func next() throws -> AssistantModelPage {
        lock.lock()
        defer { lock.unlock() }
        storedCalls += 1
        return try storedResult.get()
    }
}
