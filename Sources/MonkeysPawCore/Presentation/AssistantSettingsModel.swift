import Foundation

// Settings-only seams keep test doubles independent of drivers and A10 actions.
protocol AssistantSettingsProviding {
    var snapshot: ProviderSettingsSnapshot { get }
    func save(_ draft: ProviderDraft) throws
    func selectProfile(_ id: ProviderProfileID?) throws
    func deleteProfile(_ id: ProviderProfileID) throws
    func secretTier(for id: ProviderProfileID) throws -> SecretTier?
    func observe(_ observer: @escaping @Sendable () -> Void) -> UUID
    func removeObserver(_ id: UUID)
}

extension ProviderSettingsService: AssistantSettingsProviding {}

protocol AssistantSettingsTest: AnyObject {
    func cancel()
}

extension AssistantConnectionTest: AssistantSettingsTest {}

protocol AssistantSettingsTesting {
    func startTest(draft: ProviderDraft,
                   completion: @escaping (ConnectionTestResult) -> Void) -> AssistantSettingsTest
}

extension AssistantService: AssistantSettingsTesting {
    func startTest(draft: ProviderDraft,
                   completion: @escaping (ConnectionTestResult) -> Void) -> AssistantSettingsTest {
        testConnection(draft: draft, completion: completion)
    }
}

/// Settings → Assistant (§7/§11). Construct, release and call intents on the UI
/// thread. Inject the same serial BackgroundWork used by the provider service.
public final class AssistantSettingsModel: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    /// Published metadata deliberately has no ProviderKeyEdit/SecretValue field.
    public struct Draft: Equatable, Sendable, CustomStringConvertible,
        CustomDebugStringConvertible, CustomReflectable {
        public let id: ProviderProfileID
        public let displayName: String
        public let kind: ProviderKind
        public let baseURL: String
        public let modelID: String

        fileprivate init(_ draft: ProviderDraft) {
            id = draft.id
            displayName = draft.displayName
            kind = draft.kind
            baseURL = draft.baseURL
            modelID = draft.modelID
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.kind == rhs.kind
                && lhs.displayName.utf8.elementsEqual(rhs.displayName.utf8)
                && lhs.baseURL.utf8.elementsEqual(rhs.baseURL.utf8)
                && lhs.modelID.utf8.elementsEqual(rhs.modelID.utf8)
        }

        public var description: String { "<assistant settings draft redacted>" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["draft": description]) }
    }

    public enum KeyEdit: Equatable, Sendable {
        case keep, replace, clear
    }

    public enum KeyStorage: Equatable, Sendable {
        case none
        case loading
        case saved(SecretTier)
        case failed(ProviderSettingsError)

        public var tier: SecretTier? {
            guard case .saved(let tier) = self else { return nil }
            return tier
        }

        public var message: String {
            switch self {
            case .none: return "No key is saved."
            case .loading: return "Checking saved key."
            case .saved(.keychain): return "A key is saved in Keychain."
            case .saved(.secretService): return "A key is saved in Secret Service."
            case .saved(.environment): return "A key is provided by the environment (read-only)."
            case .saved(.file): return "A key is saved in an unencrypted file."
            case .failed: return "Could not check the saved key."
            }
        }
    }

    public enum Operation: Equatable, Sendable {
        case loading, saving, selecting, deleting
    }

    private enum KeyInputHandling { case preserve, reset }

    public struct State: Equatable, Sendable, CustomStringConvertible,
        CustomDebugStringConvertible, CustomReflectable {
        public let profiles: [ProviderProfile]
        /// Persisted active profile; a new unsaved draft can have another ID.
        public let selectedProfileID: ProviderProfileID?
        public let draft: Draft?
        public let keyEdit: KeyEdit
        public let keyStorage: KeyStorage
        public let operation: Operation?
        public let readOnlyError: ProviderSettingsError?
        public let error: ProviderSettingsError?
        public let availableModels: [ModelDescriptor]
        public let testResult: ConnectionTestResult?
        public let isTesting: Bool
        /// Changes when typed key input is committed/discarded. Native secure
        /// fields clear on this token, even when the profile ID stays the same.
        public let keyInputReset: UUID

        public var isReadOnly: Bool { readOnlyError != nil }
        public var isNewProfile: Bool {
            guard let draft else { return false }
            return !profiles.contains { $0.id == draft.id }
        }

        public var requiresKeyReentry: Bool {
            error == .keyRequiredForChangedDestination
                || testResult == .settings(.keyRequiredForChangedDestination)
        }

        public var description: String { "<assistant settings state redacted>" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["state": description]) }
    }

    public var onChange: (() -> Void)?
    /// Composition invalidates live Assistant sessions even for credential-only
    /// edits and accepted mutations that finish after Settings closes.
    public var onProfilesChanged: (() -> Void)?
    /// §26 sync-key provisioning; nil where sync is not composed.
    public let syncKey: ProviderSyncKeyModel?
    public private(set) var state: State

    private let settings: AssistantSettingsProviding
    private let testing: AssistantSettingsTesting
    private let work: BackgroundWork
    private let mainThread: MainThread
    private var snapshot: ProviderSettingsSnapshot
    private var draft: ProviderDraft?
    private var picker: AssistantModelPickerState?
    private var keyStorage = KeyStorage.none
    private var operation: Operation?
    private var error: ProviderSettingsError?
    private var editRevision = UUID()
    private var storageRevision = UUID()
    private var keyInputReset = UUID()
    private var activeTestID: ConnectionTestRequestID?
    private var test: AssistantSettingsTest?
    private var storeObserver: UUID?

    public convenience init(settings: ProviderSettingsService, assistant: AssistantService,
                            work: BackgroundWork, mainThread: MainThread,
                            syncKey: ProviderSyncKeyModel? = nil) {
        self.init(settings: settings, testing: assistant, work: work, mainThread: mainThread, syncKey: syncKey)
    }

    init(settings: AssistantSettingsProviding, testing: AssistantSettingsTesting,
         work: BackgroundWork, mainThread: MainThread, syncKey: ProviderSyncKeyModel? = nil) {
        self.settings = settings
        self.testing = testing
        self.work = work
        self.mainThread = mainThread
        self.syncKey = syncKey
        // Even a cached snapshot's lock can wait for a native secret operation.
        snapshot = ProviderSettingsSnapshot(settings: try! ProviderSettings(), readOnlyError: nil)
        state = State(profiles: [], selectedProfileID: nil, draft: nil,
            keyEdit: .keep, keyStorage: .none, operation: .loading, readOnlyError: nil,
            error: nil, availableModels: [], testResult: nil, isTesting: false, keyInputReset: keyInputReset)
        // A remote apply rewrites the file out-of-band; the open page reloads.
        storeObserver = settings.observe { [weak self, mainThread] in
            mainThread.run { [weak self] in
                guard let self else { return }
                self.loadSettings()
                self.syncKey?.refresh()
            }
        }
        mainThread.run { [weak self] in self?.loadSettings() }
    }

    deinit { test?.cancel(); storeObserver.map(settings.removeObserver) }

    /// Discards staged edits and returns to the active saved profile.
    public func refresh() {
        mainThread.run { self.loadSettings() }
    }

    public func addProfile(kind: ProviderKind = .anthropic) {
        mainThread.run {
            guard self.operation == nil else { return }
            self.error = nil
            self.useDraft(ProviderDraft(kind: kind))
            self.reloadStorage()
        }
    }

    public func selectProfile(_ id: ProviderProfileID?) {
        mainThread.run {
            self.perform(.selecting, edit: { try $0.selectProfile(id) }) { success in
                if success { self.useDraft(self.selectedDraft()) }
            }
        }
    }

    public func renameProfile(_ name: String) { editDraft { $0.displayName = name } }
    public func setKind(_ kind: ProviderKind) { editDraft { $0.kind = kind } }
    public func setBaseURL(_ url: String) { editDraft { $0.baseURL = url } }
    /// Both manual entry and picker selection use this intent; IDs need not be listed.
    public func setModelID(_ id: String) { editDraft { $0.modelID = id } }

    public func setKeyInput(_ input: String) { editDraft { $0.key = .typed(input) } }
    public func keepKey() { editDraft({ $0.key = .keep }, keyInput: .reset) }
    /// Staged until Save. Test can explicitly exercise keyless auth beforehand.
    public func clearKey() { editDraft({ $0.key = .clear }, keyInput: .reset) }

    public func save() {
        mainThread.run {
            guard let draft = self.draft else { return }
            let revision = self.editRevision
            self.perform(.saving, edit: { try $0.save(draft) }) { success in
                guard success else { return }
                if self.editRevision == revision {
                    self.useDraft(self.snapshot.settings.profiles.first { $0.id == draft.id }
                        .map(ProviderDraft.init(profile:)))
                    return
                }
                // A committed key must not remain a replacement that bypasses
                // re-entry for a newer destination. Preserve newer key input.
                guard var current = self.draft, current.id == draft.id,
                      Self.sameKey(current.key, draft.key) else { return }
                current.key = .keep
                self.draft = current
                self.editRevision = UUID()
                self.keyInputReset = UUID()
                self.picker?.update(draft: current)
            }
        }
    }

    public func deleteProfile(_ id: ProviderProfileID) {
        mainThread.run {
            guard self.operation == nil else { return }
            if self.draft?.id == id, !self.snapshot.settings.profiles.contains(where: { $0.id == id }) {
                self.error = nil
                self.useDraft(self.selectedDraft())
                self.reloadStorage()
                return
            }
            self.perform(.deleting, edit: { try $0.deleteProfile(id) }) { success in
                if success, self.draft?.id == id { self.useDraft(self.selectedDraft()) }
            }
        }
    }

    public func testConnection() {
        mainThread.run { [self] in
            guard self.operation == nil, let draft = self.draft,
                  let request = self.picker?.beginTest() else { return }
            self.activeTestID = request
            let previous = self.test
            self.test = nil
            previous?.cancel()
            self.error = nil
            self.publish()
            // onChange may synchronously edit/cancel/start a different Test.
            guard self.activeTestID == request else { return }
            let handle = self.testing.startTest(draft: draft) { [weak self, mainThread = self.mainThread] result in
                mainThread.run { [weak self] in
                    guard let self, self.activeTestID == request,
                          self.picker?.receive(result, for: request) == true else { return }
                    self.activeTestID = nil
                    self.test = nil
                    self.publish()
                }
            }
            if self.activeTestID == request { self.test = handle }
            else { handle.cancel() }
        }
    }

    public func cancelTest() {
        mainThread.run {
            self.stopTest()
            self.publish()
        }
    }

    private func editDraft(_ edit: @escaping (inout ProviderDraft) -> Void, keyInput: KeyInputHandling = .preserve) {
        mainThread.run {
            guard self.operation == nil || self.operation == .saving, let current = self.draft else { return }
            var next = current
            edit(&next)
            if keyInput == .reset { self.keyInputReset = UUID() }
            guard Draft(current) != Draft(next) || !Self.sameKey(current.key, next.key) else {
                self.publish()
                return
            }
            self.draft = next
            self.editRevision = UUID()
            self.picker?.update(draft: next)
            self.stopTest()
            self.error = nil
            self.publish()
        }
    }

    private static func sameKey(_ lhs: ProviderKeyEdit, _ rhs: ProviderKeyEdit) -> Bool {
        switch (lhs, rhs) {
        case (.keep, .keep), (.clear, .clear): return true
        case (.replace(let left), .replace(let right)):
            return left.withValue { value in right.withValue { value.utf8.elementsEqual($0.utf8) } }
        default: return false
        }
    }

    private func loadSettings() {
        perform(.loading, edit: { _ in }) { _ in
            self.error = self.snapshot.readOnlyError
            self.useDraft(self.selectedDraft())
        }
    }

    private func selectedDraft() -> ProviderDraft? {
        snapshot.settings.profiles.first { $0.id == snapshot.settings.selectedProfileID }
            .map(ProviderDraft.init(profile:))
    }

    private func useDraft(_ next: ProviderDraft?) {
        picker = next.map(AssistantModelPickerState.init(draft:))
        stopTest()
        draft = next
        editRevision = UUID()
        keyInputReset = UUID()
    }

    private func stopTest() {
        picker?.cancelTest()
        activeTestID = nil
        let handle = test
        test = nil
        handle?.cancel()
    }

    private func perform(_ operation: Operation, edit: @escaping (AssistantSettingsProviding) throws -> Void,
                         finish: @escaping (Bool) -> Void) {
        guard self.operation == nil else { return }
        self.operation = operation
        error = nil
        stopTest()
        if operation != .loading { onProfilesChanged?() }
        publish()
        // Retain accepted mutations until their completion, even if Settings closes.
        work.run { [settings, mainThread] in
            let failure: ProviderSettingsError?
            do { try edit(settings); failure = nil }
            catch let error as ProviderSettingsError { failure = error }
            catch { failure = .writeFailed(.ioFailure) }
            let snapshot = settings.snapshot
            mainThread.run {
                self.snapshot = snapshot
                self.operation = nil
                self.error = failure
                if operation != .loading { self.onProfilesChanged?() }
                finish(failure == nil)
                self.reloadStorage()
            }
        }
    }

    private func reloadStorage() {
        let revision = UUID()
        storageRevision = revision
        guard let id = draft?.id else {
            keyStorage = .none
            publish()
            return
        }
        if let error = snapshot.readOnlyError {
            keyStorage = .failed(error)
            publish()
            return
        }
        guard snapshot.settings.profiles.contains(where: { $0.id == id && $0.secretReference != nil }) else {
            keyStorage = .none
            publish()
            return
        }
        keyStorage = .loading
        publish()
        work.run { [settings, mainThread, weak self] in
            let storage: KeyStorage
            do { storage = try settings.secretTier(for: id).map(KeyStorage.saved) ?? .none }
            catch let error as ProviderSettingsError { storage = .failed(error) }
            catch { storage = .failed(.secret(.readFailed)) }
            mainThread.run { [weak self] in
                guard let self, self.storageRevision == revision, self.draft?.id == id else { return }
                self.keyStorage = storage
                self.publish()
            }
        }
    }

    private func publish() {
        let keyEdit: KeyEdit
        switch draft?.key ?? .keep {
        case .keep: keyEdit = .keep
        case .replace: keyEdit = .replace
        case .clear: keyEdit = .clear
        }
        let next = State(profiles: snapshot.settings.profiles,
            selectedProfileID: snapshot.settings.selectedProfileID, draft: draft.map(Draft.init),
            keyEdit: keyEdit, keyStorage: keyStorage, operation: operation, readOnlyError: snapshot.readOnlyError,
            error: error, availableModels: picker?.availableModels ?? [], testResult: picker?.lastResult,
            isTesting: picker?.isTesting ?? false, keyInputReset: keyInputReset)
        guard next != state else { return }
        state = next
        onChange?()
    }

    public var description: String { "<assistant settings model redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["model": description]) }
}
