import Foundation
import XCTest
@testable import MonkeysPawCore

final class ProviderKeyRulesTests: XCTestCase {
    func testBlankKeepsStoredValueAndExplicitClearDeletesIt() throws {
        let harness = ProviderHarness()
        let original = ProviderDraft(key: .typed("stored"))
        try harness.service.save(original)
        var edit = ProviderDraft(profile: harness.service.snapshot.settings.profiles[0])
        edit.key = .typed(" \t\n")
        edit.displayName = "Renamed"
        try harness.service.save(edit)
        XCTAssertEqual(harness.secrets.writes.count, 1)
        XCTAssertEqual(try harness.service.connection(for: edit.id).key, SecretValue("stored"))
        XCTAssertEqual(harness.service.snapshot.settings.profiles[0].id, original.id)

        edit.key = .clear
        try harness.service.save(edit)
        XCTAssertNil(harness.secrets.persisted[.provider(edit.id)])
        XCTAssertNil(harness.service.snapshot.settings.profiles[0].secretReference)
        XCTAssertNil(try harness.service.connection(for: edit.id).key)
        XCTAssertEqual(harness.secrets.deletions, [.provider(edit.id)])
        XCTAssertNil(try harness.reopen().service.connection(for: edit.id).key)
    }

    func testChangedKindHostSchemeOrPortCannotReuseStoredKeyForSaveOrTest() throws {
        let modifications: [(inout ProviderDraft) -> Void] = [
            { $0.kind = .openaiCompatible },
            { $0.baseURL = "https://other.example" },
            { $0.baseURL = "http://localhost" },
            { $0.baseURL = "https://api.anthropic.com:8443" }
        ]
        for modify in modifications {
            let harness = ProviderHarness()
            try harness.service.save(ProviderDraft(key: .typed("stored")))
            let before = harness.service.snapshot
            var edit = ProviderDraft(profile: before.settings.profiles[0])
            modify(&edit)
            let reads = harness.secrets.reads.count
            XCTAssertThrowsError(try harness.service.resolveForTesting(edit)) {
                XCTAssertEqual($0 as? ProviderSettingsError, .keyRequiredForChangedDestination)
            }
            XCTAssertThrowsError(try harness.service.save(edit)) {
                XCTAssertEqual($0 as? ProviderSettingsError, .keyRequiredForChangedDestination)
            }
            XCTAssertEqual(harness.secrets.reads.count, reads)
            XCTAssertEqual(harness.service.snapshot, before)
            XCTAssertEqual(harness.secrets.writes.count, 1)

            edit.key = .typed("reentered")
            XCTAssertEqual(try harness.service.resolveForTesting(edit).key, SecretValue("reentered"))
            try harness.service.save(edit)
            XCTAssertEqual(try harness.service.connection(for: edit.id).key, SecretValue("reentered"))
            XCTAssertEqual(harness.service.snapshot.settings.profiles[0].id, edit.id)
        }
    }

    func testClearWithoutPersistedSecretNeverCallsDelete() throws {
        for environmentActive in [false, true] {
            let harness = ProviderHarness()
            var draft = ProviderDraft()
            if environmentActive { harness.secrets.environment[.provider(draft.id)] = SecretValue("env") }
            harness.secrets.deleteError = SecretStoreError.deleteFailed
            draft.key = .clear

            XCTAssertNoThrow(try harness.service.save(draft), "New profile, environment: \(environmentActive)")
            XCTAssertNoThrow(try harness.service.save(draft), "Repeated Clear, environment: \(environmentActive)")
            XCTAssertNil(try harness.service.connection(for: draft.id).key)
            XCTAssertNil(try harness.reopen().service.connection(for: draft.id).key)
            XCTAssertTrue(harness.secrets.deletions.isEmpty)
            XCTAssertTrue(harness.secrets.writes.isEmpty)
            XCTAssertEqual(harness.secrets.environment[.provider(draft.id)], environmentActive ? SecretValue("env") : nil)
            XCTAssertNoThrow(try harness.service.deleteProfile(draft.id))
            XCTAssertTrue(harness.secrets.deletions.isEmpty)
        }
    }

    func testKeylessClearMetadataFailureNeedsNoSecretCompensation() throws {
        let harness = ProviderHarness()
        var draft = ProviderDraft()
        harness.secrets.environment[.provider(draft.id)] = SecretValue("env")
        try harness.service.save(draft)
        let before = harness.service.snapshot
        let bytes = try harness.files.read(at: "provider-settings.json")
        harness.secrets.deleteError = SecretStoreError.deleteFailed
        harness.files.memory.failNextWrite = true
        draft.key = .clear

        XCTAssertThrowsError(try harness.service.save(draft)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .writeFailed(.ioFailure))
        }
        XCTAssertEqual(harness.service.snapshot, before)
        XCTAssertEqual(try harness.files.read(at: "provider-settings.json"), bytes)
        XCTAssertEqual(try harness.service.connection(for: draft.id).key, SecretValue("env"))
        XCTAssertTrue(harness.secrets.deletions.isEmpty)
        XCTAssertTrue(harness.secrets.writes.isEmpty)
        XCTAssertNoThrow(try harness.service.save(draft))
        XCTAssertNil(try harness.reopen().service.connection(for: draft.id).key)
        XCTAssertTrue(harness.secrets.deletions.isEmpty)
    }

    func testExistingKeylessProfilesDoNotAdoptLaterEnvironmentOverrides() throws {
        let cases: [(String, ProviderKeyEdit)] = [("Initially keyless", .keep), ("Cleared", .typed("stored"))]
        for (context, key) in cases {
            let harness = ProviderHarness()
            var draft = ProviderDraft(key: key)
            try harness.service.save(draft)
            if case .replace = key {
                draft.key = .clear
                try harness.service.save(draft)
            }
            harness.secrets.environment[.provider(draft.id)] = SecretValue("later-env")
            let reads = harness.secrets.reads.count
            draft.key = .keep

            XCTAssertNil(try harness.service.resolveForTesting(draft).key, context)
            try harness.service.save(draft)
            XCTAssertNil(try harness.service.connection(for: draft.id).key, context)
            XCTAssertNil(try harness.reopen().service.connection(for: draft.id).key, context)
            XCTAssertNil(harness.service.snapshot.settings.profiles.first?.secretReference, context)
            XCTAssertEqual(harness.secrets.reads.count, reads, context)
            XCTAssertEqual(harness.secrets.environment[.provider(draft.id)], SecretValue("later-env"), context)
        }
    }

    func testChangedDestinationCanBeExplicitlyClearedForKeylessLocalUse() throws {
        let harness = ProviderHarness()
        try harness.service.save(ProviderDraft(key: .typed("stored")))
        var edit = ProviderDraft(profile: harness.service.snapshot.settings.profiles[0])
        edit.kind = .openaiCompatible
        edit.baseURL = "http://localhost:11434"
        edit.modelID = "local-model"
        edit.key = .clear
        XCTAssertNil(try harness.service.resolveForTesting(edit).key)
        XCTAssertNotNil(harness.secrets.persisted[.provider(edit.id)])
        try harness.service.save(edit)
        XCTAssertNil(try harness.service.connection(for: edit.id).key)
        XCTAssertNil(harness.secrets.persisted[.provider(edit.id)])
    }

    func testNormalizedEquivalentHostAndChangedPathModelKeepKeyButSeparateCache() throws {
        let harness = ProviderHarness()
        try harness.service.save(ProviderDraft(key: .typed("stored")))
        let profile = harness.service.snapshot.settings.profiles[0]
        var edit = ProviderDraft(profile: profile)
        edit.baseURL = "HTTPS://API.ANTHROPIC.COM:443/v1/messages/"
        try harness.service.save(edit)
        XCTAssertEqual(harness.service.snapshot.settings.profiles[0].cacheKey, profile.cacheKey)
        edit.baseURL = "https://api.anthropic.com/proxy"
        edit.modelID = "other-model"
        try harness.service.save(edit)
        XCTAssertEqual(try harness.service.connection(for: edit.id).key, SecretValue("stored"))
        XCTAssertNotEqual(harness.service.snapshot.settings.profiles[0].cacheKey, profile.cacheKey)
        XCTAssertEqual(harness.secrets.writes.count, 1)
    }

    func testProfilesNeverBorrowSelectedOrOtherProfileKeysAndTestDoesNotPersist() throws {
        let harness = ProviderHarness()
        let first = ProviderDraft(displayName: "One", key: .typed("one"))
        let second = ProviderDraft(displayName: "Two", key: .typed("two"))
        try harness.service.save(first)
        try harness.service.save(second)
        try harness.service.selectProfile(first.id)
        let before = harness.service.snapshot
        let writes = harness.files.attemptedWrites.count
        let secretWrites = harness.secrets.writes.count
        var draft = ProviderDraft(profile: before.settings.profiles[1])
        XCTAssertEqual(try harness.service.resolveForTesting(draft).key, SecretValue("two"))
        draft.key = .typed("draft-only")
        draft.baseURL = "https://draft.example"
        XCTAssertEqual(try harness.service.resolveForTesting(draft).key, SecretValue("draft-only"))
        draft.key = .clear
        XCTAssertNil(try harness.service.resolveForTesting(draft).key)
        let new = ProviderDraft(displayName: "New", kind: .openaiCompatible, baseURL: "http://localhost:8080")
        XCTAssertEqual(try harness.service.resolveForTesting(new).modelID, "")
        XCTAssertNil(try harness.service.resolveForTesting(new).key)
        XCTAssertEqual(harness.service.snapshot, before)
        XCTAssertEqual(harness.files.attemptedWrites.count, writes)
        XCTAssertEqual(harness.secrets.writes.count, secretWrites)
        XCTAssertEqual(try harness.service.connection(for: first.id).key, SecretValue("one"))
        XCTAssertEqual(try harness.service.connection(for: second.id).key, SecretValue("two"))
    }

    func testDeleteProfileOnlyDeletesItsOwnKeyAndKeepsOtherProfileAndSelection() throws {
        let harness = ProviderHarness()
        let one = ProviderDraft(displayName: "One", key: .typed("one"))
        let two = ProviderDraft(displayName: "Two", key: .typed("two"))
        try harness.service.save(one)
        try harness.service.save(two)
        try harness.service.selectProfile(two.id)
        try harness.service.deleteProfile(one.id)
        XCTAssertEqual(harness.secrets.deletions, [.provider(one.id)])
        XCTAssertEqual(harness.service.snapshot.settings.profiles.map(\.id), [two.id])
        XCTAssertEqual(harness.service.snapshot.settings.selectedProfileID, two.id)
        XCTAssertEqual(try harness.service.connection(for: two.id).key, SecretValue("two"))
        try harness.service.deleteProfile(two.id)
        XCTAssertNil(harness.service.snapshot.settings.selectedProfileID)
        XCTAssertThrowsError(try harness.service.deleteProfile(two.id)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .profileNotFound)
        }
    }

    func testEnvironmentOverrideIsIsolatedReadOnlyAndClearDoesNotMutateEnvironment() throws {
        let harness = ProviderHarness()
        let draft = ProviderDraft()
        harness.secrets.environment[.provider(draft.id)] = SecretValue("env")
        XCTAssertEqual(try harness.service.resolveForTesting(draft).key, SecretValue("env"))
        try harness.service.save(draft)
        XCTAssertEqual(try harness.service.secretTier(for: draft.id), .environment)
        XCTAssertEqual(harness.secrets.writes.count, 0)
        var edit = draft
        edit.key = .typed("typed")
        XCTAssertEqual(try harness.service.resolveForTesting(edit).key, SecretValue("typed"))
        XCTAssertThrowsError(try harness.service.save(edit)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .secret(.readOnly))
        }
        XCTAssertEqual(try harness.service.connection(for: draft.id).key, SecretValue("env"))
        edit.key = .clear
        try harness.service.save(edit)
        XCTAssertNil(try harness.service.connection(for: draft.id).key)
        XCTAssertEqual(harness.secrets.environment[.provider(draft.id)], SecretValue("env"))
        XCTAssertNil(try harness.service.resolveForTesting(ProviderDraft()).key)
    }

    func testNewProfileDoesNotAdoptOrphanedPersistentSecrets() throws {
        let harness = ProviderHarness()
        let draft = ProviderDraft()
        harness.secrets.persisted[.provider(draft.id)] = StoredSecret(value: SecretValue("orphan"), tier: .file)
        XCTAssertNil(try harness.service.resolveForTesting(draft).key)
        try harness.service.save(draft)
        XCTAssertNil(try harness.service.connection(for: draft.id).key)
    }

    func testSecretReadWriteAndDeleteFailuresKeepMetadataAndUseTypedErrors() throws {
        let harness = ProviderHarness()
        let draft = ProviderDraft(key: .typed("old"))
        try harness.service.save(draft)
        let previousSecret = harness.secrets.persisted[.provider(draft.id)]
        let before = harness.service.snapshot
        let bytes = try harness.files.read(at: "provider-settings.json")
        var edit = ProviderDraft(profile: before.settings.profiles[0])
        edit.key = .typed("new")
        harness.secrets.readError = SecretStoreError.locked
        harness.secrets.deleteError = SecretStoreError.locked
        XCTAssertThrowsError(try harness.service.save(edit)) { XCTAssertEqual($0 as? ProviderSettingsError, .secret(.locked)) }
        harness.secrets.readError = nil
        harness.secrets.deleteError = nil
        harness.secrets.writeError = NSError(domain: "untrusted provider body", code: 1)
        XCTAssertThrowsError(try harness.service.save(edit)) { XCTAssertEqual($0 as? ProviderSettingsError, .secret(.writeFailed)) }
        harness.secrets.writeError = nil
        harness.secrets.deleteError = SecretStoreError.deleteFailed
        edit.key = .clear
        XCTAssertThrowsError(try harness.service.save(edit)) { XCTAssertEqual($0 as? ProviderSettingsError, .secret(.deleteFailed)) }
        XCTAssertEqual(harness.service.snapshot, before)
        XCTAssertEqual(try harness.files.read(at: "provider-settings.json"), bytes)
        XCTAssertEqual(harness.secrets.persisted[.provider(draft.id)], previousSecret)
    }

    func testMetadataFailureRestoresPreviousKeyForReplaceClearAndDelete() throws {
        enum Operation: CaseIterable { case replace, clear, delete }
        for operation in Operation.allCases {
            let harness = ProviderHarness()
            let draft = ProviderDraft(key: .typed("old"))
            try harness.service.save(draft)
            let account = SecretAccount.provider(draft.id)
            let stored = try XCTUnwrap(harness.secrets.persisted[account])
            var payload = try stored.value.withValue {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
            payload["unknown"] = ["opaque", "雪"]
            let opaque = " \n" + String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self) + "\n "
            harness.secrets.persisted[account] = StoredSecret(value: SecretValue(opaque), tier: .secretService)
            let previousSecret = harness.secrets.persisted[.provider(draft.id)]
            let before = harness.service.snapshot
            let bytes = try harness.files.read(at: "provider-settings.json")
            var edit = ProviderDraft(profile: before.settings.profiles[0])
            edit.displayName = "Changed"
            edit.key = operation == .replace ? .typed("new") : .clear
            harness.files.memory.failNextWrite = true
            switch operation {
            case .delete:
                XCTAssertThrowsError(try harness.service.deleteProfile(draft.id), "\(operation)") {
                    XCTAssertEqual($0 as? ProviderSettingsError, .writeFailed(.ioFailure), "\(operation)")
                }
            case .replace, .clear:
                XCTAssertThrowsError(try harness.service.save(edit), "\(operation)") {
                    XCTAssertEqual($0 as? ProviderSettingsError, .writeFailed(.ioFailure), "\(operation)")
                }
            }
            XCTAssertEqual(harness.service.snapshot, before, "\(operation)")
            XCTAssertEqual(try harness.files.read(at: "provider-settings.json"), bytes, "\(operation)")
            XCTAssertEqual(harness.secrets.persisted[.provider(draft.id)], previousSecret, "\(operation)")
            XCTAssertEqual(try harness.service.connection(for: draft.id).key, SecretValue("old"), "\(operation)")
            XCTAssertEqual(try harness.reopen().service.connection(for: draft.id).key, SecretValue("old"), "\(operation)")
        }
    }

    func testFailedInitialMetadataCommitRemovesNewKeyAndCanRetry() throws {
        let harness = ProviderHarness()
        let draft = ProviderDraft(key: .typed("new"))
        harness.files.memory.failNextWrite = true
        XCTAssertThrowsError(try harness.service.save(draft)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .writeFailed(.ioFailure))
        }
        XCTAssertNil(harness.secrets.persisted[.provider(draft.id)])
        XCTAssertNil(try harness.files.stamp(at: "provider-settings.json"))
        try harness.service.save(draft)
        XCTAssertEqual(try harness.service.connection(for: draft.id).key, SecretValue("new"))
    }

    func testFailedCompensationReportsAnExplicitPartialFailure() throws {
        let harness = ProviderHarness()
        let draft = ProviderDraft(key: .typed("old"))
        try harness.service.save(draft)
        let previousSecret = harness.secrets.persisted[.provider(draft.id)]
        var edit = ProviderDraft(profile: harness.service.snapshot.settings.profiles[0])
        edit.displayName = "Changed"
        edit.key = .typed("new")
        harness.secrets.failWriteNumber = harness.secrets.writes.count + 2
        harness.files.memory.failNextWrite = true
        XCTAssertThrowsError(try harness.service.save(edit)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .secretRollbackFailed)
        }
        XCTAssertEqual(harness.service.snapshot.settings.profiles[0].displayName, draft.displayName)
        XCTAssertNotEqual(harness.secrets.persisted[.provider(draft.id)], previousSecret)
        XCTAssertTrue(harness.log.lines.contains("error: Provider secret restoration failed."))
        XCTAssertTrue(harness.service.snapshot.isReadOnly)
        XCTAssertEqual(harness.service.snapshot.readOnlyError, .secretRollbackFailed)
        XCTAssertThrowsError(try harness.service.connection(for: draft.id)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .secretRollbackFailed)
        }
        XCTAssertThrowsError(try harness.service.resolveForTesting(ProviderDraft(profile:
            harness.service.snapshot.settings.profiles[0]))) {
            XCTAssertEqual($0 as? ProviderSettingsError, .secretRollbackFailed)
        }
    }

    func testRestartCannotSendNewDestinationKeyAfterFailedCommitAndRestoration() throws {
        let harness = ProviderHarness()
        let draft = ProviderDraft(key: .typed(UUID().uuidString))
        try harness.service.save(draft)
        let bytes = try harness.files.read(at: "provider-settings.json")
        var edit = ProviderDraft(profile: harness.service.snapshot.settings.profiles[0])
        edit.baseURL = "https://other.example"
        edit.key = .typed(UUID().uuidString)
        harness.secrets.failWriteNumber = harness.secrets.writes.count + 2
        harness.files.memory.failNextWrite = true
        XCTAssertThrowsError(try harness.service.save(edit)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .secretRollbackFailed)
        }
        XCTAssertEqual(try harness.files.read(at: "provider-settings.json"), bytes)

        let reopened = harness.reopen()
        let savedDraft = ProviderDraft(profile: reopened.service.snapshot.settings.profiles[0])
        XCTAssertThrowsError(try reopened.service.connection(for: draft.id)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .keyRequiredForChangedDestination)
        }
        XCTAssertThrowsError(try reopened.service.resolveForTesting(savedDraft)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .keyRequiredForChangedDestination)
        }
    }

    func testExternalDestinationEditCannotRebindTheStoredCredential() throws {
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["kind"] = ProviderKind.openaiCompatible.rawValue },
            { $0["baseURL"] = "https://other.example" },
            { $0["baseURL"] = "http://localhost" },
            { $0["baseURL"] = "https://localhost:8443" }
        ]
        for change in changes {
            let harness = ProviderHarness()
            let draft = ProviderDraft(baseURL: "https://localhost", key: .typed(UUID().uuidString))
            try harness.service.save(draft)
            var object = try harness.json()
            var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]], "provider-settings fixture missing a profiles array")
            var profile = try XCTUnwrap(profiles.first, "provider-settings fixture missing its profile")
            change(&profile)
            profiles[0] = profile
            object["profiles"] = profiles
            try harness.files.memory.write(JSONSerialization.data(withJSONObject: object), at: "provider-settings.json")

            for current in [harness, harness.reopen()] {
                XCTAssertThrowsError(try current.service.connection(for: draft.id)) {
                    XCTAssertEqual($0 as? ProviderSettingsError, .keyRequiredForChangedDestination)
                }
                let savedDraft = ProviderDraft(profile: current.service.snapshot.settings.profiles[0])
                XCTAssertThrowsError(try current.service.resolveForTesting(savedDraft)) {
                    XCTAssertEqual($0 as? ProviderSettingsError, .keyRequiredForChangedDestination)
                }
            }
            XCTAssertEqual(harness.secrets.writes.count, 1)

            let reopened = harness.reopen()
            var repair = ProviderDraft(profile: reopened.service.snapshot.settings.profiles[0])
            repair.key = .typed(UUID().uuidString)
            try reopened.service.save(repair)
            guard case .replace(let key) = repair.key else {
                XCTFail("Expected replacement intent")
                continue
            }
            XCTAssertEqual(try reopened.service.connection(for: draft.id).key, key)
        }
    }

    func testUnboundMalformedAndUnsupportedPersistentCredentialsRequireReentry() throws {
        let harness = ProviderHarness()
        let draft = ProviderDraft(key: .typed(UUID().uuidString))
        try harness.service.save(draft)
        let account = SecretAccount.provider(draft.id)
        let persisted = try XCTUnwrap(harness.secrets.persisted[account])
        var unsupported = try persisted.value.withValue {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any],
                          "persisted secret is not a JSON envelope")
        }
        unsupported["version"] = 2
        let unsupportedValue = SecretValue(String(decoding: try JSONSerialization.data(withJSONObject: unsupported), as: UTF8.self))
        for tier in [SecretTier.keychain, .secretService, .file] {
            for value in [SecretValue(UUID().uuidString), SecretValue("{"), unsupportedValue] {
                harness.secrets.persisted[account] = StoredSecret(value: value, tier: tier)
                XCTAssertThrowsError(try harness.service.connection(for: draft.id), "\(tier)") {
                    XCTAssertEqual($0 as? ProviderSettingsError, .keyRequiredForChangedDestination, "\(tier)")
                }
                XCTAssertThrowsError(try harness.service.resolveForTesting(ProviderDraft(profile:
                    harness.service.snapshot.settings.profiles[0])), "\(tier)") {
                    XCTAssertEqual($0 as? ProviderSettingsError, .keyRequiredForChangedDestination, "\(tier)")
                }
            }
            harness.secrets.persisted[account] = StoredSecret(value: persisted.value, tier: tier)
            guard case .replace(let key) = draft.key else {
                XCTFail("Expected replacement intent for \(tier)")
                continue
            }
            XCTAssertEqual(try harness.service.connection(for: draft.id).key, key, "\(tier)")
        }

        // Even an envelope-shaped operator override stays raw.
        harness.secrets.environment[account] = persisted.value
        XCTAssertEqual(try harness.service.connection(for: draft.id).key, persisted.value)
        let savedDraft = ProviderDraft(profile: harness.service.snapshot.settings.profiles[0])
        XCTAssertEqual(try harness.service.resolveForTesting(savedDraft).key, persisted.value)
    }

    func testClearCanRestorePersistedKeyAfterMetadataFailureWithEnvironmentActive() throws {
        let harness = ProviderHarness()
        let draft = ProviderDraft(key: .typed("persisted"))
        try harness.service.save(draft)
        let previousSecret = harness.secrets.persisted[.provider(draft.id)]
        harness.secrets.environment[.provider(draft.id)] = SecretValue("environment")
        var edit = ProviderDraft(profile: harness.service.snapshot.settings.profiles[0])
        edit.key = .clear
        harness.files.memory.failNextWrite = true
        XCTAssertThrowsError(try harness.service.save(edit)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .writeFailed(.ioFailure))
        }
        XCTAssertEqual(harness.secrets.persisted[.provider(draft.id)], previousSecret)
        XCTAssertEqual(try harness.service.connection(for: draft.id).key, SecretValue("environment"))
        XCTAssertFalse(harness.service.snapshot.isReadOnly)
    }

    func testInvalidDraftsDoNotChangeMetadataOrSecrets() throws {
        let harness = ProviderHarness()
        let invalid: [(ProviderDraft, ProviderSettingsError)] = [
            (ProviderDraft(displayName: "", key: .typed("key")), .invalidProfile),
            (ProviderDraft(baseURL: "https://user:password@example.com", key: .typed("key")), .credentialsInURL),
            (ProviderDraft(baseURL: "https://example.com?key=value", key: .typed("key")), .queryOrFragmentInURL),
            (ProviderDraft(modelID: "", key: .typed("key")), .invalidProfile),
            (ProviderDraft(key: .replace(SecretValue("\nkey"))), .invalidKey),
            (ProviderDraft(key: .replace(SecretValue("   "))), .invalidKey)
        ]
        for (index, testCase) in invalid.enumerated() {
            let (draft, expected) = testCase
            XCTAssertThrowsError(try harness.service.save(draft), "Invalid draft \(index)") {
                XCTAssertEqual($0 as? ProviderSettingsError, expected, "Invalid draft \(index)")
            }
        }
        XCTAssertTrue(harness.secrets.writes.isEmpty)
        XCTAssertTrue(harness.files.attemptedWrites.isEmpty)
        XCTAssertEqual(harness.service.snapshot.settings.profiles, [])
    }

    func testSentinelNeverAppearsInAnyAttemptedSettingsWriteDescriptionsOrCapturedLogs() throws {
        let harness = ProviderHarness()
        let sentinel = UUID().uuidString
        let draft = ProviderDraft(key: .typed(sentinel))
        try harness.service.save(draft)
        var edit = ProviderDraft(profile: harness.service.snapshot.settings.profiles[0])
        edit.displayName = "Edited"
        try harness.service.resolveForTesting(edit).key?.withValue { XCTAssertEqual($0, sentinel) }
        harness.files.memory.failNextWrite = true
        XCTAssertThrowsError(try harness.service.save(edit))
        edit.key = .typed(sentinel)
        harness.secrets.writeError = NSError(domain: sentinel, code: 1, userInfo: [NSLocalizedDescriptionKey: sentinel])
        XCTAssertThrowsError(try harness.service.save(edit))
        harness.secrets.writeError = nil
        harness.secrets.readError = NSError(domain: sentinel, code: 1)
        XCTAssertThrowsError(try harness.service.connection(for: edit.id))
        harness.secrets.readError = nil
        edit.key = .clear
        try harness.service.save(edit)
        XCTAssertFalse(harness.log.lines.isEmpty)
        for bytes in harness.files.attemptedWrites { XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(sentinel)) }
        for file in try harness.files.listFiles() {
            XCTAssertFalse(String(decoding: try harness.files.read(at: file.relativePath), as: UTF8.self).contains(sentinel))
        }
        XCTAssertFalse(harness.log.lines.joined().contains(sentinel))
        for value: Any in [draft, harness.service.snapshot, ProviderSettingsError.secret(.writeFailed)] {
            XCTAssertFalse(String(describing: value).contains(sentinel))
            XCTAssertFalse(String(reflecting: value).contains(sentinel))
        }
    }
}
