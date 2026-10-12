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
        XCTAssertThrowsError(try harness.service.deleteProfile(two.id))
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
        let before = harness.service.snapshot
        let bytes = try harness.files.read(at: "provider-settings.json")
        var edit = ProviderDraft(profile: before.settings.profiles[0])
        edit.key = .typed("new")
        harness.secrets.readError = SecretStoreError.locked
        XCTAssertThrowsError(try harness.service.save(edit)) { XCTAssertEqual($0 as? ProviderSettingsError, .secret(.locked)) }
        harness.secrets.readError = nil
        harness.secrets.writeError = NSError(domain: "untrusted provider body", code: 1)
        XCTAssertThrowsError(try harness.service.save(edit)) { XCTAssertEqual($0 as? ProviderSettingsError, .secret(.writeFailed)) }
        harness.secrets.writeError = nil
        harness.secrets.deleteError = SecretStoreError.deleteFailed
        edit.key = .clear
        XCTAssertThrowsError(try harness.service.save(edit)) { XCTAssertEqual($0 as? ProviderSettingsError, .secret(.deleteFailed)) }
        XCTAssertEqual(harness.service.snapshot, before)
        XCTAssertEqual(try harness.files.read(at: "provider-settings.json"), bytes)
        XCTAssertEqual(harness.secrets.persisted[.provider(draft.id)]?.value, SecretValue("old"))
    }

    func testMetadataFailureRestoresPreviousKeyForReplaceClearAndDelete() throws {
        for operation in 0..<3 {
            let harness = ProviderHarness()
            let draft = ProviderDraft(key: .typed("old"))
            try harness.service.save(draft)
            let before = harness.service.snapshot
            let bytes = try harness.files.read(at: "provider-settings.json")
            var edit = ProviderDraft(profile: before.settings.profiles[0])
            edit.displayName = "Changed"
            edit.key = operation == 0 ? .typed("new") : .clear
            harness.files.memory.failNextWrite = true
            XCTAssertThrowsError(try operation == 2 ? harness.service.deleteProfile(draft.id) : harness.service.save(edit)) {
                XCTAssertEqual($0 as? ProviderSettingsError, .writeFailed(.ioFailure))
            }
            XCTAssertEqual(harness.service.snapshot, before)
            XCTAssertEqual(try harness.files.read(at: "provider-settings.json"), bytes)
            XCTAssertEqual(try harness.service.connection(for: draft.id).key, SecretValue("old"))
        }
    }

    func testFailedInitialMetadataCommitRemovesNewKeyAndCanRetry() throws {
        let harness = ProviderHarness()
        let draft = ProviderDraft(key: .typed("new"))
        harness.files.memory.failNextWrite = true
        XCTAssertThrowsError(try harness.service.save(draft))
        XCTAssertNil(harness.secrets.persisted[.provider(draft.id)])
        XCTAssertNil(try harness.files.stamp(at: "provider-settings.json"))
        try harness.service.save(draft)
        XCTAssertEqual(try harness.service.connection(for: draft.id).key, SecretValue("new"))
    }

    func testFailedCompensationReportsAnExplicitPartialFailure() throws {
        let harness = ProviderHarness()
        let draft = ProviderDraft(key: .typed("old"))
        try harness.service.save(draft)
        var edit = ProviderDraft(profile: harness.service.snapshot.settings.profiles[0])
        edit.displayName = "Changed"
        edit.key = .typed("new")
        harness.secrets.failWriteNumber = harness.secrets.writes.count + 2
        harness.files.memory.failNextWrite = true
        XCTAssertThrowsError(try harness.service.save(edit)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .secretRollbackFailed)
        }
        XCTAssertEqual(harness.service.snapshot.settings.profiles[0].displayName, draft.displayName)
        XCTAssertEqual(harness.secrets.persisted[.provider(draft.id)]?.value, SecretValue("new"))
        XCTAssertTrue(harness.log.lines.contains("error: Provider secret restoration failed."))
        XCTAssertTrue(harness.service.snapshot.isReadOnly)
        XCTAssertEqual(harness.service.snapshot.readOnlyError, .secretRollbackFailed)
        XCTAssertThrowsError(try harness.service.connection(for: draft.id))
        XCTAssertThrowsError(try harness.service.resolveForTesting(ProviderDraft(profile:
            harness.service.snapshot.settings.profiles[0])))
    }

    func testClearCanRestorePersistedKeyAfterMetadataFailureWithEnvironmentActive() throws {
        let harness = ProviderHarness()
        let draft = ProviderDraft(key: .typed("persisted"))
        try harness.service.save(draft)
        harness.secrets.environment[.provider(draft.id)] = SecretValue("environment")
        var edit = ProviderDraft(profile: harness.service.snapshot.settings.profiles[0])
        edit.key = .clear
        harness.files.memory.failNextWrite = true
        XCTAssertThrowsError(try harness.service.save(edit)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .writeFailed(.ioFailure))
        }
        XCTAssertEqual(harness.secrets.persisted[.provider(draft.id)]?.value, SecretValue("persisted"))
        XCTAssertEqual(try harness.service.connection(for: draft.id).key, SecretValue("environment"))
        XCTAssertFalse(harness.service.snapshot.isReadOnly)
    }

    func testInvalidDraftsDoNotChangeMetadataOrSecrets() throws {
        let harness = ProviderHarness()
        let invalid: [ProviderDraft] = [
            ProviderDraft(displayName: "", key: .typed("key")),
            ProviderDraft(baseURL: "https://user:password@example.com", key: .typed("key")),
            ProviderDraft(baseURL: "https://example.com?key=value", key: .typed("key")),
            ProviderDraft(modelID: "", key: .typed("key")),
            ProviderDraft(key: .replace(SecretValue("\nkey"))),
            ProviderDraft(key: .replace(SecretValue("   ")))
        ]
        for draft in invalid { XCTAssertThrowsError(try harness.service.save(draft)) }
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
