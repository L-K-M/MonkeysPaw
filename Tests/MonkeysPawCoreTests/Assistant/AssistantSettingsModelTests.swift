import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantSettingsModelTests: XCTestCase {
    func testEmptyStateAndEveryDraftIntentStayLocalUntilSaveOrTest() throws {
        let h = try AssistantSettingsHarness()
        XCTAssertNil(h.model.state.draft)
        XCTAssertNil(h.model.state.selectedProfileID)
        XCTAssertEqual(h.model.state.keyStorage, .none)
        h.model.save()
        h.model.testConnection()
        h.model.keepKey()
        h.model.clearKey()
        h.model.renameProfile("ignored")
        XCTAssertEqual(h.states.count, 1)

        h.model.addProfile(kind: .openaiCompatible)
        let id = try XCTUnwrap(h.model.state.draft?.id)
        XCTAssertEqual(h.model.state.draft?.baseURL, ProviderKind.openaiCompatible.defaultBaseURL)
        XCTAssertEqual(h.model.state.draft?.modelID, "")
        XCTAssertTrue(h.model.state.isNewProfile)
        h.model.renameProfile("Local")
        h.model.setKind(.anthropic)
        h.model.setBaseURL("https://example.com/v1/messages/")
        h.model.setModelID("unlisted")
        h.model.setKeyInput(" key input ")
        XCTAssertEqual(h.model.state.keyEdit, .replace)
        h.model.keepKey()
        XCTAssertEqual(h.model.state.keyEdit, .keep)
        h.model.clearKey()
        XCTAssertEqual(h.model.state.keyEdit, .clear)
        h.model.setKeyInput("\n \t")
        XCTAssertEqual(h.model.state.keyEdit, .keep)
        XCTAssertEqual(h.model.state.draft?.id, id)
        XCTAssertTrue(h.provider.saves.isEmpty)
        XCTAssertTrue(h.provider.selections.isEmpty)
        XCTAssertTrue(h.provider.deletions.isEmpty)
        XCTAssertTrue(h.provider.tierReads.isEmpty)
        XCTAssertTrue(h.testing.tests.isEmpty)

        h.model.save()
        XCTAssertEqual(h.provider.saves.count, 1)
        XCTAssertEqual(h.model.state.profiles.map(\.displayName), ["Local"])
        XCTAssertEqual(h.model.state.draft?.baseURL, "https://example.com")
        XCTAssertEqual(h.model.state.selectedProfileID, id)
        XCTAssertEqual(h.model.state.draft?.modelID, "unlisted")
        XCTAssertFalse(h.model.state.isNewProfile)
        XCTAssertNil(h.model.state.error)
    }

    func testAddingAndSavingDoesNotReplaceAnExistingActiveProfile() throws {
        let saved = try AssistantSettingsHarness.profile(key: false)
        let h = try AssistantSettingsHarness(profiles: [saved], selected: saved.id)
        h.model.addProfile()
        let newID = try XCTUnwrap(h.model.state.draft?.id)
        h.model.save()
        XCTAssertEqual(h.model.state.selectedProfileID, saved.id)
        XCTAssertEqual(h.model.state.draft?.id, newID)
        XCTAssertEqual(Set(h.model.state.profiles.map(\.id)), [saved.id, newID])
        h.model.selectProfile(newID)
        XCTAssertEqual(h.model.state.selectedProfileID, newID)
        h.model.selectProfile(nil)
        XCTAssertNil(h.model.state.selectedProfileID)
        XCTAssertNil(h.model.state.draft)
        XCTAssertEqual(h.model.state.keyStorage, .none)
        h.model.testConnection()
        XCTAssertTrue(h.testing.tests.isEmpty)
    }

    func testSelectionDiscardsDraftAndRenameIsStagedUntilSave() throws {
        let first = try AssistantSettingsHarness.profile(name: "First")
        let second = try AssistantSettingsHarness.profile(name: "Second")
        let h = try AssistantSettingsHarness(profiles: [first, second], selected: first.id,
            tiers: [first.id: .file, second.id: .keychain])
        h.model.renameProfile("Renamed")
        h.model.setKeyInput("private staged key")
        let reset = h.model.state.keyInputReset
        XCTAssertEqual(h.model.state.profiles.map(\.displayName), ["First", "Second"])
        h.model.selectProfile(second.id)
        XCTAssertEqual(h.model.state.draft?.displayName, "Second")
        XCTAssertEqual(h.model.state.keyEdit, .keep)
        XCTAssertEqual(h.model.state.keyStorage, .saved(.keychain))
        XCTAssertNotEqual(h.model.state.keyInputReset, reset)
        h.model.renameProfile("Second renamed")
        h.model.save()
        XCTAssertEqual(h.model.state.profiles.first { $0.id == second.id }?.displayName, "Second renamed")
        XCTAssertEqual(h.model.state.selectedProfileID, second.id)
        XCTAssertTrue(h.testing.tests.isEmpty)
    }

    func testBlankKeepsClearIsStagedAndFailureKeepsSavedKeyStatus() throws {
        let profile = try AssistantSettingsHarness.profile()
        let h = try AssistantSettingsHarness(profiles: [profile], selected: profile.id,
            tiers: [profile.id: .secretService])
        h.model.setKeyInput("\n \t")
        h.model.save()
        XCTAssertEqual(h.provider.saves.last?.key, .keep)
        XCTAssertEqual(h.model.state.keyStorage, .saved(.secretService))
        h.model.setKeyInput("new key")
        h.model.setKeyInput("")
        h.model.clearKey()
        let reset = h.model.state.keyInputReset
        XCTAssertEqual(h.model.state.keyEdit, .clear)
        XCTAssertEqual(h.model.state.keyStorage, .saved(.secretService))
        h.model.testConnection()
        XCTAssertEqual(h.testing.tests.last?.draft.key, .clear)
        XCTAssertEqual(h.provider.saves.count, 1)
        h.provider.saveError = ProviderSettingsError.writeFailed(.ioFailure)
        h.model.save()
        XCTAssertEqual(h.model.state.keyEdit, .clear)
        XCTAssertEqual(h.model.state.keyStorage, .saved(.secretService))
        XCTAssertEqual(h.model.state.error, .writeFailed(.ioFailure))
        XCTAssertEqual(h.model.state.keyInputReset, reset)
        h.provider.saveError = nil
        h.model.save()
        XCTAssertEqual(h.model.state.keyEdit, .keep)
        XCTAssertEqual(h.model.state.keyStorage, .none)
        XCTAssertNil(h.model.state.profiles.first?.secretReference)
        XCTAssertNotEqual(h.model.state.keyInputReset, reset)
        h.model.clearKey()
        h.model.save()
        XCTAssertEqual(h.model.state.keyStorage, .none)
        XCTAssertTrue(h.testing.tests.count == 1)
    }

    func testEveryTypedSaveErrorPreservesDraftAndPublishedMetadata() throws {
        for failure in settingsErrors {
            let profile = try AssistantSettingsHarness.profile()
            let h = try AssistantSettingsHarness(profiles: [profile], selected: profile.id,
                tiers: [profile.id: .file])
            h.model.renameProfile("Staged")
            h.model.setModelID("new-manual-id")
            h.model.setKeyInput("new private key")
            let draft = h.model.state.draft
            let reset = h.model.state.keyInputReset
            h.provider.saveError = failure
            h.model.save()
            XCTAssertEqual(h.model.state.error, failure)
            XCTAssertEqual(h.model.state.requiresKeyReentry, failure == .keyRequiredForChangedDestination)
            XCTAssertNil(h.model.state.operation)
            XCTAssertEqual(h.model.state.profiles, [profile])
            XCTAssertEqual(h.model.state.selectedProfileID, profile.id)
            XCTAssertEqual(h.model.state.draft, draft)
            XCTAssertEqual(h.model.state.keyEdit, .replace)
            XCTAssertEqual(h.model.state.keyInputReset, reset)
            XCTAssertEqual(h.model.state.keyStorage, .saved(.file))
            h.provider.saveError = nil
            h.model.save()
            XCTAssertNil(h.model.state.error)
            XCTAssertEqual(h.model.state.keyEdit, .keep)
            XCTAssertNotEqual(h.model.state.keyInputReset, reset)
        }
    }

    func testDeleteAndSelectionFailuresPreserveCurrentDraftAndTier() throws {
        let profile = try AssistantSettingsHarness.profile()
        let h = try AssistantSettingsHarness(profiles: [profile], selected: profile.id,
            tiers: [profile.id: .environment])
        h.model.renameProfile("Unsaved")
        h.model.setKeyInput("replacement")
        let before = h.model.state
        h.provider.deleteError = ProviderSettingsError.secret(.deleteFailed)
        h.model.deleteProfile(profile.id)
        XCTAssertEqual(h.model.state.error, .secret(.deleteFailed))
        XCTAssertEqual(h.model.state.draft, before.draft)
        XCTAssertEqual(h.model.state.keyEdit, .replace)
        XCTAssertEqual(h.model.state.selectedProfileID, profile.id)
        XCTAssertEqual(h.model.state.keyStorage, .saved(.environment))
        h.provider.selectError = ProviderSettingsError.writeFailed(.ioFailure)
        h.model.selectProfile(nil)
        XCTAssertEqual(h.model.state.error, .writeFailed(.ioFailure))
        XCTAssertEqual(h.model.state.draft, before.draft)
        XCTAssertEqual(h.model.state.profiles, before.profiles)
        XCTAssertEqual(h.model.state.keyEdit, .replace)
    }

    func testDeletingNewInactiveAndActiveProfilesLeavesCoherentState() throws {
        let first = try AssistantSettingsHarness.profile()
        let second = try AssistantSettingsHarness.profile(name: "Other")
        let h = try AssistantSettingsHarness(profiles: [first, second], selected: first.id,
            tiers: [first.id: .file, second.id: .keychain])
        h.model.addProfile()
        let unsaved = try XCTUnwrap(h.model.state.draft?.id)
        h.model.setKeyInput("discarded")
        h.model.deleteProfile(unsaved)
        XCTAssertTrue(h.provider.deletions.isEmpty)
        XCTAssertEqual(h.model.state.draft?.id, first.id)
        XCTAssertEqual(h.model.state.keyEdit, .keep)
        h.model.setKeyInput("still staged")
        h.model.deleteProfile(second.id)
        XCTAssertEqual(h.model.state.profiles.map(\.id), [first.id])
        XCTAssertEqual(h.model.state.draft?.id, first.id)
        XCTAssertEqual(h.model.state.keyEdit, .replace)
        XCTAssertEqual(h.model.state.keyStorage, .saved(.file))
        h.model.deleteProfile(first.id)
        XCTAssertTrue(h.model.state.profiles.isEmpty)
        XCTAssertNil(h.model.state.draft)
        XCTAssertNil(h.model.state.selectedProfileID)
        XCTAssertEqual(h.model.state.keyEdit, .keep)
        XCTAssertEqual(h.model.state.keyStorage, .none)
        h.model.deleteProfile(first.id)
        XCTAssertEqual(h.model.state.error, .profileNotFound)
    }

    func testEveryStorageTierIsVisibleAndTierFailureIsExplicit() throws {
        let profile = try AssistantSettingsHarness.profile()
        for tier in [SecretTier.keychain, .secretService, .environment, .file] {
            let h = try AssistantSettingsHarness(profiles: [profile], selected: profile.id, tiers: [profile.id: tier])
            XCTAssertEqual(h.model.state.keyStorage.tier, tier)
            XCTAssertFalse(h.model.state.keyStorage.message.isEmpty)
            if tier == .file { XCTAssertTrue(h.model.state.keyStorage.message.contains("unencrypted")) }
            if tier == .environment { XCTAssertTrue(h.model.state.keyStorage.message.contains("read-only")) }
        }
        let h = try AssistantSettingsHarness(profiles: [profile], selected: profile.id, heldWork: true)
        XCTAssertEqual(h.model.state.keyStorage, .loading)
        h.provider.tierError = ProviderSettingsError.secret(.locked)
        h.settle()
        XCTAssertEqual(h.model.state.keyStorage, .failed(.secret(.locked)))
        XCTAssertNil(h.model.state.keyStorage.tier)
        h.provider.tierError = nil
        h.model.refresh()
        h.settle()
        XCTAssertEqual(h.model.state.keyStorage, .none)
    }

    func testReadOnlyFailureDoesNotDiscardStagedDraftOrPretendItSaved() throws {
        let h = try AssistantSettingsHarness()
        h.model.addProfile()
        h.model.setKeyInput("staged")
        let before = h.model.state.draft
        h.provider.saveError = ProviderSettingsError.secretRollbackFailed
        h.provider.failedSnapshot = ProviderSettingsSnapshot(settings: try ProviderSettings(),
            readOnlyError: .secretRollbackFailed)
        h.model.save()
        XCTAssertTrue(h.model.state.isReadOnly)
        XCTAssertEqual(h.model.state.readOnlyError, .secretRollbackFailed)
        XCTAssertEqual(h.model.state.error, .secretRollbackFailed)
        XCTAssertEqual(h.model.state.draft, before)
        XCTAssertEqual(h.model.state.keyEdit, .replace)
        XCTAssertTrue(h.model.state.isNewProfile)
        h.model.refresh()
        XCTAssertNil(h.model.state.draft)
        XCTAssertEqual(h.model.state.keyEdit, .keep)
        XCTAssertEqual(h.model.state.error, .secretRollbackFailed)
    }

    func testManualModelAndSuggestionsSurviveEveryFailedTestAndEmptyList() throws {
        let h = try AssistantSettingsHarness()
        h.model.addProfile(kind: .openaiCompatible)
        h.model.setModelID("manual-unlisted")
        let suggestions = [ModelDescriptor(id: "listed", displayName: "Listed model")]
        h.model.testConnection()
        h.testing.tests.last?.reply(.ok(models: suggestions))
        XCTAssertEqual(h.model.state.availableModels, suggestions)
        for result in testFailures {
            let calls = h.testing.tests.count
            h.model.testConnection()
            h.testing.tests.last?.reply(result)
            XCTAssertEqual(h.testing.tests.count, calls + 1)
            XCTAssertEqual(h.model.state.testResult, result)
            XCTAssertFalse(h.model.state.isTesting)
            XCTAssertEqual(h.model.state.availableModels, suggestions)
            XCTAssertEqual(h.model.state.draft?.modelID, "manual-unlisted")
            XCTAssertEqual(h.model.state.requiresKeyReentry,
                           result == .settings(.keyRequiredForChangedDestination))
        }
        h.model.testConnection()
        h.testing.tests.last?.reply(.ok(models: []))
        XCTAssertTrue(h.model.state.availableModels.isEmpty)
        XCTAssertEqual(h.model.state.draft?.modelID, "manual-unlisted")
        h.model.setModelID(suggestions[0].id)
        XCTAssertEqual(h.model.state.draft?.modelID, "listed")
        h.model.setModelID("another-unlisted")
        XCTAssertEqual(h.model.state.draft?.modelID, "another-unlisted")
        XCTAssertTrue(h.provider.saves.isEmpty)
    }

    func testEveryDraftEditCancelsTestAndRejectsLateAndRepeatedReplies() throws {
        let edits: [(AssistantSettingsModel) -> Void] = [
            { $0.renameProfile("Changed") }, { $0.setKind(.openaiCompatible) },
            { $0.setBaseURL("https://another.example") }, { $0.setModelID("changed-id") },
            { $0.setKeyInput("changed key") }, { $0.keepKey() }, { $0.clearKey() }
        ]
        for edit in edits {
            let h = try AssistantSettingsHarness()
            h.model.addProfile()
            h.model.setKeyInput("initial key")
            h.model.testConnection()
            h.testing.tests.last?.reply(.ok(models: [ModelDescriptor(id: "initial")]))
            h.model.testConnection()
            let old = try XCTUnwrap(h.testing.tests.last)
            edit(h.model)
            XCTAssertEqual(old.cancellations, 1)
            XCTAssertFalse(h.model.state.isTesting)
            XCTAssertNil(h.model.state.testResult)
            XCTAssertTrue(h.model.state.availableModels.isEmpty)
            old.reply(.ok(models: [ModelDescriptor(id: "stale")]))
            old.reply(.network)
            XCTAssertNil(h.model.state.testResult)
            XCTAssertTrue(h.model.state.availableModels.isEmpty)
        }
    }

    func testByteDistinctDraftAndKeyEditsInvalidateTestButIdenticalInputDoesNot() throws {
        let edits: [(AssistantSettingsModel, String) -> Void] = [
            { $0.renameProfile($1) }, { $0.setBaseURL("https://example.com/" + $1) },
            { $0.setModelID($1) }, { $0.setKeyInput($1) }
        ]
        for edit in edits {
            let h = try AssistantSettingsHarness()
            h.model.addProfile()
            edit(h.model, "é")
            h.model.testConnection()
            let test = try XCTUnwrap(h.testing.tests.last)
            edit(h.model, "é")
            XCTAssertTrue(h.model.state.isTesting)
            XCTAssertEqual(test.cancellations, 0)
            edit(h.model, "e\u{301}")
            XCTAssertFalse(h.model.state.isTesting)
            XCTAssertEqual(test.cancellations, 1)
            test.reply(.ok(models: [ModelDescriptor(id: "old")]))
            XCTAssertTrue(h.model.state.availableModels.isEmpty)
        }
    }

    func testProfileSwitchAwayAndBackAndQueuedReplyCannotReviveOldTest() throws {
        let first = try AssistantSettingsHarness.profile(key: false)
        let second = try AssistantSettingsHarness.profile(name: "Other", key: false)
        let h = try AssistantSettingsHarness(profiles: [first, second], selected: first.id)
        h.model.testConnection()
        let old = try XCTUnwrap(h.testing.tests.last)
        h.main.isHeld = true
        old.reply(.ok(models: [ModelDescriptor(id: "queued old")]))
        // Native UI intents may run inline ahead of an already enqueued reply.
        h.main.isHeld = false
        h.model.selectProfile(second.id)
        h.model.selectProfile(first.id)
        h.model.testConnection()
        let current = try XCTUnwrap(h.testing.tests.last)
        h.main.releaseAll()
        XCTAssertTrue(h.model.state.isTesting)
        XCTAssertNil(h.model.state.testResult)
        current.reply(.ok(models: [ModelDescriptor(id: "current")]))
        old.reply(.ok(models: [ModelDescriptor(id: "late")]))
        XCTAssertEqual(h.model.state.availableModels.map(\.id), ["current"])
    }

    func testCancelAndNewTestRejectOldResultsAndRetainManualIDSuggestions() throws {
        let h = try AssistantSettingsHarness()
        h.model.addProfile()
        h.model.setModelID("manual")
        h.model.testConnection()
        h.testing.tests.last?.reply(.ok(models: [ModelDescriptor(id: "suggestion")]))
        h.model.testConnection()
        let old = try XCTUnwrap(h.testing.tests.last)
        h.model.cancelTest()
        XCTAssertEqual(old.cancellations, 1)
        old.reply(.ok(models: []))
        XCTAssertEqual(h.model.state.testResult, .cancelled)
        XCTAssertEqual(h.model.state.availableModels.map(\.id), ["suggestion"])
        XCTAssertEqual(h.model.state.draft?.modelID, "manual")
        h.model.testConnection()
        let superseded = try XCTUnwrap(h.testing.tests.last)
        h.model.testConnection()
        XCTAssertEqual(superseded.cancellations, 1)
        superseded.reply(.network)
        XCTAssertTrue(h.model.state.isTesting)
        h.testing.tests.last?.reply(.ok(models: [ModelDescriptor(id: "new")]))
        XCTAssertEqual(h.model.state.availableModels.map(\.id), ["new"])
    }

    func testSaveDeleteRefreshAndAddAllInvalidatePendingTests() throws {
        let intents: [(AssistantSettingsModel, ProviderProfileID) -> Void] = [
            { model, _ in model.save() }, { $0.deleteProfile($1) },
            { model, _ in model.refresh() }, { model, _ in model.addProfile() }
        ]
        for intent in intents {
            let profile = try AssistantSettingsHarness.profile(key: false)
            let h = try AssistantSettingsHarness(profiles: [profile], selected: profile.id)
            h.model.testConnection()
            let test = try XCTUnwrap(h.testing.tests.last)
            intent(h.model, profile.id)
            XCTAssertEqual(test.cancellations, 1)
            test.reply(.ok(models: [ModelDescriptor(id: "stale")]))
            XCTAssertFalse(h.model.state.isTesting)
            XCTAssertTrue(h.model.state.availableModels.isEmpty)
        }
    }

    func testInlineCompletionAndReentrantCancellationDoNotRetainOrStartObsoleteTest() throws {
        let h = try AssistantSettingsHarness()
        h.model.addProfile()
        h.testing.inlineResult = .ok(models: [])
        h.model.testConnection()
        XCTAssertEqual(h.model.state.testResult, .ok(models: []))
        XCTAssertFalse(h.model.state.isTesting)
        let test = try XCTUnwrap(h.testing.tests.last)
        h.model.cancelTest()
        XCTAssertEqual(test.cancellations, 1, "The completed handle was already released")
        XCTAssertEqual(h.model.state.testResult, .ok(models: []))

        h.model.onChange = { [weak model = h.model] in
            if model?.state.isTesting == true { model?.cancelTest() }
        }
        h.model.testConnection()
        XCTAssertEqual(h.testing.tests.count, 1)
        XCTAssertEqual(h.model.state.testResult, .cancelled)
    }

    func testLateTierReplyCannotPopulateAnotherDraft() throws {
        let profile = try AssistantSettingsHarness.profile()
        let h = try AssistantSettingsHarness(profiles: [profile], selected: profile.id,
            tiers: [profile.id: .file], heldWork: true)
        h.model.addProfile()
        XCTAssertEqual(h.model.state.keyStorage, .none)
        h.settle()
        XCTAssertEqual(h.model.state.keyStorage, .none)
        XCTAssertTrue(h.model.state.isNewProfile)
    }

    func testSaveCompletionPreservesNewerEditsAndPersistenceCannotOverlap() throws {
        let h = try AssistantSettingsHarness()
        h.model.addProfile()
        h.model.setKeyInput("first key")
        let id = try XCTUnwrap(h.model.state.draft?.id)
        h.work.isHeld = true
        h.model.save()
        XCTAssertEqual(h.model.state.operation, .saving)
        h.model.save()
        h.model.selectProfile(nil)
        h.model.deleteProfile(id)
        h.model.addProfile()
        h.model.refresh()
        h.model.testConnection()
        XCTAssertEqual(h.work.pending.count, 1)
        XCTAssertTrue(h.testing.tests.isEmpty)
        h.model.renameProfile("newer name")
        h.model.setModelID("newer model")
        h.model.setKeyInput("newer key")
        let reset = h.model.state.keyInputReset
        h.settle()
        XCTAssertEqual(h.provider.saves.count, 1)
        XCTAssertEqual(h.model.state.profiles.first?.displayName, "Anthropic")
        XCTAssertEqual(h.model.state.draft?.displayName, "newer name")
        XCTAssertEqual(h.model.state.draft?.modelID, "newer model")
        XCTAssertEqual(h.model.state.keyEdit, .replace)
        XCTAssertEqual(h.model.state.keyInputReset, reset)
        XCTAssertEqual(h.model.state.keyStorage, .saved(.secretService))
        h.model.save()
        h.settle()
        XCTAssertEqual(h.model.state.profiles.first?.displayName, "newer name")
        XCTAssertEqual(h.model.state.keyEdit, .keep)
    }

    func testEveryIntentAndPublicationUseInlineAndQueuedMainThread() throws {
        for held in [false, true] {
            let h = try AssistantSettingsHarness(heldWork: true, heldMain: held)
            h.settle()
            let intents: [(AssistantSettingsModel) -> Void] = [
                { $0.addProfile() }, { $0.renameProfile("Renamed") }, { $0.setKind(.openaiCompatible) },
                { $0.setBaseURL("http://localhost:11434/v1") }, { $0.setModelID("manual") },
                { $0.setKeyInput("key") }, { $0.keepKey() }, { $0.clearKey() },
                { $0.setKeyInput("replacement") }, { $0.testConnection() }, { $0.cancelTest() },
                { $0.save() }, { $0.refresh() }, { $0.selectProfile(nil) }, { $0.addProfile() }
            ]
            for intent in intents {
                let before = h.model.state
                intent(h.model)
                if held { XCTAssertEqual(h.model.state, before) }
                h.settle()
            }
            let new = try XCTUnwrap(h.model.state.draft?.id)
            h.model.deleteProfile(new)
            h.settle()
            let saved = try XCTUnwrap(h.model.state.profiles.first?.id)
            h.model.deleteProfile(saved)
            h.settle()
            XCTAssertTrue(h.model.state.profiles.isEmpty)
            XCTAssertTrue(h.provider.selections.count == 1)
            XCTAssertTrue(h.provider.deletions.count == 1)
            XCTAssertTrue(h.testing.tests.count == 1)
        }
    }

    func testClosingCancelsTestAndQueuedSaveSurvivesClosing() throws {
        let h = try AssistantSettingsHarness()
        var model: AssistantSettingsModel? = AssistantSettingsModel(settings: h.provider, testing: h.testing,
            work: h.work, mainThread: h.main)
        let released = { [weak model] in model == nil }
        model?.addProfile()
        model?.testConnection()
        let test = try XCTUnwrap(h.testing.tests.last)
        model = nil
        XCTAssertTrue(released())
        XCTAssertEqual(test.cancellations, 1)
        test.reply(.ok(models: []))

        model = AssistantSettingsModel(settings: h.provider, testing: h.testing,
            work: h.work, mainThread: h.main)
        let releasedAfterSave = { [weak model] in model == nil }
        model?.addProfile()
        h.work.isHeld = true
        model?.save()
        model = nil
        XCTAssertFalse(releasedAfterSave())
        h.settle()
        XCTAssertTrue(releasedAfterSave())
        XCTAssertEqual(h.provider.saves.count, 1)
    }

    func testUnknownServiceErrorsAreSanitizedAndEveryPublishedStateExcludesKeyInput() throws {
        let sentinel = UUID().uuidString
        let profile = try AssistantSettingsHarness.profile()
        let h = try AssistantSettingsHarness(profiles: [profile], selected: profile.id,
            tiers: [profile.id: .file])
        h.model.setKeyInput(" \n" + sentinel + "\n ")
        h.model.testConnection()
        let test = try XCTUnwrap(h.testing.tests.last)
        XCTAssertTrue(test.draft.key == .replace(SecretValue(sentinel)))
        test.reply(.authentication)
        h.provider.saveError = SensitiveFailure(description: sentinel)
        h.model.save()
        XCTAssertEqual(h.model.state.error, .writeFailed(.ioFailure))
        h.provider.saveError = nil
        h.model.save()
        h.provider.tierError = SensitiveFailure(description: sentinel)
        h.model.refresh()
        XCTAssertEqual(h.model.state.keyStorage, .failed(.secret(.readFailed)))
        h.model.clearKey()
        h.model.keepKey()
        h.model.addProfile()
        h.model.setKeyInput(sentinel)
        h.model.deleteProfile(try XCTUnwrap(h.model.state.draft?.id))

        for state in h.states {
            assertRedacted(state, sentinel: sentinel)
            // Inspect all public fields independently of State's redacted mirror.
            let fields: [Any] = [state.profiles, state.selectedProfileID as Any, state.draft as Any,
                state.keyEdit, state.keyStorage, state.operation as Any, state.readOnlyError as Any,
                state.error as Any, state.availableModels, state.testResult as Any,
                state.isTesting, state.keyInputReset]
            for field in fields { assertRedacted(field, sentinel: sentinel) }
        }
        assertRedacted(h.model, sentinel: sentinel)
        XCTAssertTrue(h.provider.saves.contains { $0.key == .replace(SecretValue(sentinel)) })
    }

    func testProviderServiceEnforcesOriginKindReentryAndClearOrReplaceRepairsIt() throws {
        let edits: [(AssistantSettingsModel) -> Void] = [
            { $0.setKind(.openaiCompatible) }, { $0.setBaseURL("https://another.example") },
            { $0.setBaseURL("http://localhost") }, { $0.setBaseURL("https://localhost:8443") }
        ]
        for edit in edits {
            let h = try AssistantSettingsHarness()
            let provider = ProviderHarness()
            let saved = ProviderDraft(baseURL: "https://localhost", key: .replace(SecretValue(UUID().uuidString)))
            try provider.service.save(saved)
            let model = AssistantSettingsModel(settings: provider.service, testing: h.testing,
                work: h.work, mainThread: h.main)
            edit(model)
            model.save()
            XCTAssertEqual(model.state.error, .keyRequiredForChangedDestination)
            XCTAssertTrue(model.state.requiresKeyReentry)
            XCTAssertEqual(model.state.keyStorage, .saved(.secretService))
            model.setKeyInput(UUID().uuidString)
            model.save()
            XCTAssertNil(model.state.error)
            XCTAssertEqual(model.state.keyEdit, .keep)
            XCTAssertEqual(model.state.draft?.kind, model.state.profiles.first?.kind)
            edit(model)
            model.clearKey()
            model.save()
            XCTAssertNil(model.state.error)
            XCTAssertEqual(model.state.keyStorage, .none)
            XCTAssertNil(try provider.service.connection(for: saved.id).key)
        }
    }

    func testRealProviderClearFailureRestoresKeyAndEnvironmentRemainsReadOnly() throws {
        let h = try AssistantSettingsHarness()
        let provider = ProviderHarness()
        let draft = ProviderDraft(key: .replace(SecretValue(UUID().uuidString)))
        try provider.service.save(draft)
        let model = AssistantSettingsModel(settings: provider.service, testing: h.testing,
            work: h.work, mainThread: h.main)
        provider.files.memory.failNextWrite = true
        model.clearKey()
        model.save()
        XCTAssertEqual(model.state.error, .writeFailed(.ioFailure))
        XCTAssertEqual(model.state.keyEdit, .clear)
        XCTAssertEqual(model.state.keyStorage, .saved(.secretService))
        XCTAssertNotNil(try provider.service.connection(for: draft.id).key)
        provider.secrets.environment[.provider(draft.id)] = SecretValue(UUID().uuidString)
        model.refresh()
        XCTAssertEqual(model.state.keyStorage, .saved(.environment))
        model.setKeyInput("replacement")
        model.save()
        XCTAssertEqual(model.state.error, .secret(.readOnly))
        XCTAssertEqual(model.state.keyEdit, .replace)
        model.clearKey()
        model.save()
        XCTAssertEqual(model.state.keyStorage, .none)
        XCTAssertNotNil(provider.secrets.environment[.provider(draft.id)])
        XCTAssertNil(try provider.service.connection(for: draft.id).key)
    }

    func testPublicInitializerTestsThroughA8WithoutSavingOrExposingKey() async throws {
        let h = ConnectionHarness([.held])
        let model = AssistantSettingsModel(settings: h.provider.service, assistant: h.service,
            work: ConnectionBackground(), mainThread: h.main)
        h.main.drain()
        model.addProfile(kind: .openaiCompatible)
        model.setModelID("manual")
        let sentinel = UUID().uuidString
        model.setKeyInput(sentinel)
        h.main.drain()
        var states = [model.state]
        model.onChange = {
            XCTAssertTrue(h.main.isRunning)
            states.append(model.state)
        }
        model.testConnection()
        h.main.drain()
        await h.transport.waitUntilSent()
        let queued = expectation(description: "A8 result queued")
        h.main.onEnqueue = { queued.fulfill() }
        await h.transport.release(try ConnectionHarness.page([["id": "listed"]]))
        await fulfillment(of: [queued], timeout: 2)
        h.main.onEnqueue = nil
        h.main.drain()
        h.main.drain()
        XCTAssertEqual(model.state.testResult, .ok(models: [ModelDescriptor(id: "listed")]))
        XCTAssertEqual(model.state.draft?.modelID, "manual")
        XCTAssertEqual(model.state.keyEdit, .replace)
        XCTAssertTrue(h.provider.files.attemptedWrites.isEmpty)
        XCTAssertTrue(h.provider.secrets.writes.isEmpty)
        XCTAssertTrue(h.provider.service.snapshot.settings.profiles.isEmpty)
        let requests = await h.transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests.first?.headers["Authorization"] == "Bearer " + sentinel)
        for state in states { assertRedacted(state, sentinel: sentinel) }
        assertRedacted(model, sentinel: sentinel)
        model.onChange = nil
    }

    private var testFailures: [ConnectionTestResult] {
        [.authentication, .notFound, .rateLimited(retryAfter: 2), .network, .timeout, .unsupportedListing,
         .invalidResponse, .cancelled, .settings(.keyRequiredForChangedDestination), .providerFailure(statusCode: 503)]
    }

    private var settingsErrors: [ProviderSettingsError] {
        [.futureVersion(2), .unsupportedVersion(0), .corruptFile, .readFailed(.ioFailure), .writeFailed(.ioFailure),
         .invalidBaseURL, .insecureBaseURL, .credentialsInURL, .queryOrFragmentInURL, .invalidProfile, .invalidKey,
         .duplicateProfile, .profileNotFound, .keyRequiredForChangedDestination, .secret(.locked), .secretRollbackFailed]
    }

    private func assertRedacted(_ value: Any, sentinel: String, file: StaticString = #filePath, line: UInt = #line) {
        var dumped = ""
        dump(value, to: &dumped)
        for text in [String(describing: value), String(reflecting: value), dumped] {
            XCTAssertFalse(text.contains(sentinel), "Key escaped a diagnostic or state field", file: file, line: line)
        }
    }

    private struct SensitiveFailure: Error, CustomStringConvertible { let description: String }
}
