import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantSettingsWork: BackgroundWork {
    let marker: EditingThreadMarker
    var isHeld = false
    private(set) var pending: [() -> Void] = []

    init(_ marker: EditingThreadMarker) { self.marker = marker }

    func run(_ work: @escaping () -> Void) {
        if isHeld { pending.append(work) }
        else { marker.worker(work) }
    }

    func releaseNext() { marker.worker(pending.removeFirst()) }
    func releaseAll() { while !pending.isEmpty { releaseNext() } }
}

final class AssistantSettingsProviderFake: AssistantSettingsProviding {
    private var cached: ProviderSettingsSnapshot
    var onSnapshot: (() -> Void)?
    var snapshot: ProviderSettingsSnapshot {
        get { onSnapshot?(); return cached }
        set { cached = newValue }
    }
    var tiers: [ProviderProfileID: SecretTier] = [:]
    var persistentTier = SecretTier.secretService
    var saveError: Error?
    var selectError: Error?
    var deleteError: Error?
    var tierError: Error?
    var failedSnapshot: ProviderSettingsSnapshot?
    private(set) var saves: [ProviderDraft] = []
    private(set) var selections: [ProviderProfileID?] = []
    private(set) var deletions: [ProviderProfileID] = []
    private(set) var tierReads: [ProviderProfileID] = []
    private let marker: EditingThreadMarker

    init(_ marker: EditingThreadMarker, profiles: [ProviderProfile], selected: ProviderProfileID?) throws {
        self.marker = marker
        cached = ProviderSettingsSnapshot(settings: try ProviderSettings(profiles: profiles,
            selectedProfileID: selected), readOnlyError: nil)
    }

    func save(_ draft: ProviderDraft) throws {
        XCTAssertFalse(marker.isUI)
        saves.append(draft)
        if let saveError {
            if let failedSnapshot { snapshot = failedSnapshot }
            throw saveError
        }
        let previous = snapshot.settings.profiles.first { $0.id == draft.id }
        let reference: SecretAccount?
        switch draft.key {
        case .keep: reference = previous?.secretReference
        case .replace: reference = .provider(draft.id)
        case .clear: reference = nil
        }
        let profile = try ProviderProfile(id: draft.id, displayName: draft.displayName, kind: draft.kind,
            baseURL: draft.baseURL, modelID: draft.modelID, secretReference: reference)
        let profiles = snapshot.settings.profiles.filter { $0.id != draft.id } + [profile]
        snapshot = ProviderSettingsSnapshot(settings: try ProviderSettings(profiles: profiles,
            selectedProfileID: snapshot.settings.selectedProfileID ?? draft.id), readOnlyError: nil)
        switch draft.key {
        case .keep: break
        case .replace: tiers[draft.id] = persistentTier
        case .clear: tiers[draft.id] = nil
        }
    }

    func selectProfile(_ id: ProviderProfileID?) throws {
        XCTAssertFalse(marker.isUI)
        selections.append(id)
        if let selectError { throw selectError }
        snapshot = ProviderSettingsSnapshot(settings: try ProviderSettings(profiles: snapshot.settings.profiles,
            selectedProfileID: id), readOnlyError: nil)
    }

    func deleteProfile(_ id: ProviderProfileID) throws {
        XCTAssertFalse(marker.isUI)
        deletions.append(id)
        if let deleteError { throw deleteError }
        guard snapshot.settings.profiles.contains(where: { $0.id == id }) else {
            throw ProviderSettingsError.profileNotFound
        }
        snapshot = ProviderSettingsSnapshot(settings: try ProviderSettings(
            profiles: snapshot.settings.profiles.filter { $0.id != id },
            selectedProfileID: snapshot.settings.selectedProfileID == id ? nil : snapshot.settings.selectedProfileID),
            readOnlyError: nil)
        tiers[id] = nil
    }

    func secretTier(for id: ProviderProfileID) throws -> SecretTier? {
        XCTAssertFalse(marker.isUI)
        tierReads.append(id)
        if let tierError { throw tierError }
        return tiers[id]
    }

    private var observers: [UUID: @Sendable () -> Void] = [:]

    func observe(_ observer: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    /// Simulates a committed write landing while the model is open.
    func notifyChanged() { observers.values.forEach { $0() } }
}

final class AssistantSettingsTestFake: AssistantSettingsTest {
    let draft: ProviderDraft
    private let completion: (ConnectionTestResult) -> Void
    private(set) var cancellations = 0

    init(draft: ProviderDraft, completion: @escaping (ConnectionTestResult) -> Void) {
        self.draft = draft
        self.completion = completion
    }

    // Deliberately deliver even after cancellation to exercise stale guards.
    func reply(_ result: ConnectionTestResult) { completion(result) }
    func cancel() { cancellations += 1; completion(.cancelled) }
}

final class AssistantSettingsTestingFake: AssistantSettingsTesting {
    private(set) var tests: [AssistantSettingsTestFake] = []
    var inlineResult: ConnectionTestResult?

    func startTest(draft: ProviderDraft,
                   completion: @escaping (ConnectionTestResult) -> Void) -> AssistantSettingsTest {
        let test = AssistantSettingsTestFake(draft: draft, completion: completion)
        tests.append(test)
        if let inlineResult { completion(inlineResult) }
        return test
    }
}

final class AssistantSettingsHarness {
    let marker = EditingThreadMarker()
    let main: EditingMainThread
    let work: AssistantSettingsWork
    let provider: AssistantSettingsProviderFake
    let testing = AssistantSettingsTestingFake()
    let model: AssistantSettingsModel
    private(set) var states: [AssistantSettingsModel.State] = []

    init(profiles: [ProviderProfile] = [], selected: ProviderProfileID? = nil,
         tiers: [ProviderProfileID: SecretTier] = [:], heldWork: Bool = false, heldMain: Bool = false) throws {
        main = EditingMainThread(marker)
        main.isHeld = heldMain
        work = AssistantSettingsWork(marker)
        work.isHeld = heldWork
        provider = try AssistantSettingsProviderFake(marker, profiles: profiles, selected: selected)
        provider.tiers = tiers
        model = AssistantSettingsModel(settings: provider, testing: testing, work: work, mainThread: main)
        states = [model.state]
        model.onChange = { [weak self] in
            guard let self else { return }
            XCTAssertTrue(self.marker.isUI)
            self.states.append(self.model.state)
        }
    }

    func settle() {
        while !main.pending.isEmpty || !work.pending.isEmpty {
            main.releaseAll()
            work.releaseAll()
        }
    }

    static func profile(name: String = "Saved", kind: ProviderKind = .anthropic,
                        baseURL: String? = nil, modelID: String = "manual", key: Bool = true) throws -> ProviderProfile {
        let id = ProviderProfileID()
        return try ProviderProfile(id: id, displayName: name, kind: kind,
            baseURL: baseURL ?? kind.defaultBaseURL, modelID: modelID, secretReference: key ? .provider(id) : nil)
    }
}
