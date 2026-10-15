import Foundation
import XCTest
@testable import MonkeysPawCore

final class ProviderSettingsServiceTests: XCTestCase {
    private enum Recovery: CaseIterable { case clear, delete, replace }
    private let readFailures: [Error] = [SecretStoreError.locked, SecretStoreError.unavailable,
                                       SecretStoreError.readFailed, NSError(domain: "private-driver-body", code: 1)]

    func testUnreadableCredentialClear() throws { try checkRecovery(.clear) }
    func testUnreadableCredentialDelete() throws { try checkRecovery(.delete) }
    func testUnreadableCredentialReplace() throws { try checkRecovery(.replace) }

    private func checkRecovery(_ operation: Recovery) throws {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            for failure in readFailures {
                let h = ProviderHarness()
                let oldKey = UUID().uuidString
                let otherKey = UUID().uuidString
                let draft = ProviderDraft(kind: kind, modelID: "test-model", key: .typed(oldKey))
                let other = ProviderDraft(displayName: "Other", key: .typed(otherKey))
                try h.service.save(draft)
                try h.service.save(other)
                try h.service.selectProfile(other.id)
                let account = SecretAccount.provider(draft.id)
                let retained = h.secrets.persisted[.provider(other.id)]
                h.secrets.accountReadErrors[account] = failure
                let bytes = try h.files.read(at: "provider-settings.json")
                XCTAssertThrowsError(try h.service.connection(for: draft.id)) {
                    XCTAssertEqual($0 as? ProviderSettingsError, .secret(failure as? SecretStoreError ?? .readFailed))
                }
                XCTAssertEqual(try h.files.read(at: "provider-settings.json"), bytes)
                XCTAssertTrue(h.secrets.deletions.isEmpty)

                try recover(operation, draft: draft, service: h.service)

                XCTAssertEqual(h.secrets.deletions, [account])
                XCTAssertEqual(h.secrets.persisted[.provider(other.id)], retained)
                XCTAssertEqual(h.service.snapshot.settings.selectedProfileID, other.id)
                h.secrets.accountReadErrors = [:]
                let reopened = h.reopen().service
                switch operation {
                case .delete:
                    XCTAssertFalse(reopened.snapshot.settings.profiles.contains { $0.id == draft.id })
                case .clear:
                    XCTAssertNil(try reopened.connection(for: draft.id).key)
                    XCTAssertNil(reopened.snapshot.settings.profiles.first { $0.id == draft.id }?.secretReference)
                case .replace:
                    XCTAssertEqual(try reopened.connection(for: draft.id).key, SecretValue("replacement"))
                }
                if operation != .replace { XCTAssertNil(h.secrets.persisted[account]) }
                XCTAssertTrue(h.log.lines.isEmpty)
                for key in [oldKey, otherKey, "replacement", "private-driver-body"] {
                    XCTAssertFalse(h.files.attemptedWrites.contains { String(decoding: $0, as: UTF8.self).contains(key) })
                }
            }
        }
    }

    func testUnreadableRecoveryMetadataFailureCleansReplacementAndAllowsExplicitRetry() throws {
        for operation in Recovery.allCases {
            for failure in readFailures {
                let h = ProviderHarness()
                let draft = ProviderDraft(key: .typed(UUID().uuidString))
                try h.service.save(draft)
                let account = SecretAccount.provider(draft.id)
                h.secrets.accountReadErrors[account] = failure
                let before = h.service.snapshot
                let bytes = try h.files.read(at: "provider-settings.json")
                h.files.memory.failNextWrite = true

                XCTAssertThrowsError(try recover(operation, draft: draft, service: h.service)) {
                    XCTAssertEqual($0 as? ProviderSettingsError, .writeFailed(.ioFailure))
                }
                XCTAssertEqual(h.service.snapshot, before)
                XCTAssertEqual(try h.files.read(at: "provider-settings.json"), bytes)
                XCTAssertNil(h.secrets.persisted[account])
                XCTAssertNil(try h.reopen().service.connection(for: draft.id).key)
                XCTAssertEqual(h.log.lines, ["warning: Provider settings write failed."])
                try recover(operation, draft: draft, service: h.service)
            }
        }
    }

    func testFailedRecoveryDeletePreventsReplacementAndMetadataPublication() throws {
        for operation in Recovery.allCases {
            let h = ProviderHarness()
            let draft = ProviderDraft(key: .typed(UUID().uuidString))
            try h.service.save(draft)
            let account = SecretAccount.provider(draft.id)
            h.secrets.accountReadErrors[account] = SecretStoreError.readFailed
            h.secrets.deleteError = NSError(domain: "private-driver-body", code: 2)
            let before = h.service.snapshot
            let bytes = try h.files.read(at: "provider-settings.json")
            let previous = h.secrets.persisted[account]
            let writes = h.secrets.writes.count

            XCTAssertThrowsError(try recover(operation, draft: draft, service: h.service)) {
                XCTAssertEqual($0 as? ProviderSettingsError, .secret(.deleteFailed))
            }
            XCTAssertEqual(h.service.snapshot, before)
            XCTAssertEqual(try h.files.read(at: "provider-settings.json"), bytes)
            XCTAssertEqual(h.secrets.persisted[account], previous)
            XCTAssertEqual(h.secrets.writes.count, writes)
            XCTAssertEqual(h.log.lines, ["warning: Provider secret update failed."])
        }
    }

    func testFailedRecoveryReplacementIsTypedAndRetainsMetadata() throws {
        let h = ProviderHarness()
        let draft = ProviderDraft(key: .typed(UUID().uuidString))
        try h.service.save(draft)
        let account = SecretAccount.provider(draft.id)
        h.secrets.accountReadErrors[account] = SecretStoreError.unavailable
        h.secrets.writeError = NSError(domain: "private-driver-body", code: 3)
        let before = h.service.snapshot
        let bytes = try h.files.read(at: "provider-settings.json")

        XCTAssertThrowsError(try recover(.replace, draft: draft, service: h.service)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .secret(.writeFailed))
        }
        XCTAssertEqual(h.service.snapshot, before)
        XCTAssertEqual(try h.files.read(at: "provider-settings.json"), bytes)
        XCTAssertNil(h.secrets.persisted[account])
        XCTAssertEqual(h.log.lines, ["warning: Provider secret update failed."])
    }

    func testFailedUnreadableReplacementCleanupDisablesInstance() throws {
        let h = ProviderHarness()
        let draft = ProviderDraft(key: .typed(UUID().uuidString))
        try h.service.save(draft)
        let account = SecretAccount.provider(draft.id)
        h.secrets.accountReadErrors[account] = SecretStoreError.readFailed
        // Initial recovery delete succeeds; only the compensating delete fails.
        h.secrets.failDeleteNumber = h.secrets.deletions.count + 2
        h.files.memory.failNextWrite = true
        let before = h.service.snapshot.settings

        XCTAssertThrowsError(try recover(.replace, draft: draft, service: h.service)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .secretRollbackFailed)
        }
        XCTAssertEqual(h.service.snapshot.settings, before)
        XCTAssertEqual(h.service.snapshot.readOnlyError, .secretRollbackFailed)
        let reads = h.secrets.reads.count
        XCTAssertThrowsError(try h.service.connection(for: draft.id)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .secretRollbackFailed)
        }
        XCTAssertThrowsError(try h.service.save(draft)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .secretRollbackFailed)
        }
        XCTAssertEqual(h.secrets.reads.count, reads)
        XCTAssertEqual(h.log.lines, ["warning: Provider settings write failed.", "error: Provider secret restoration failed."])
    }

    func testEnvironmentReplacementRemainsReadOnlyWhileClearDeletesUnreadablePersistedCopy() throws {
        let h = ProviderHarness()
        let draft = ProviderDraft(key: .typed(UUID().uuidString))
        try h.service.save(draft)
        let account = SecretAccount.provider(draft.id)
        h.secrets.accountReadErrors[account] = SecretStoreError.readFailed
        h.secrets.environment[account] = SecretValue("operator-override")
        let before = h.service.snapshot
        XCTAssertThrowsError(try recover(.replace, draft: draft, service: h.service)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .secret(.readOnly))
        }
        XCTAssertEqual(h.service.snapshot, before)
        XCTAssertTrue(h.secrets.deletions.isEmpty)
        try recover(.clear, draft: draft, service: h.service)
        XCTAssertNil(h.secrets.persisted[account])
        XCTAssertEqual(h.secrets.environment[account], SecretValue("operator-override"))
        XCTAssertNil(try h.service.connection(for: draft.id).key)
    }

    func testReadOnlyInvalidAccountAndCancellationNeverTriggerRecovery() throws {
        for operation in Recovery.allCases {
            for failure: Error in [SecretStoreError.readOnly, SecretStoreError.invalidAccount, CancellationError()] {
                let h = ProviderHarness()
                let draft = ProviderDraft(key: .typed(UUID().uuidString))
                try h.service.save(draft)
                let account = SecretAccount.provider(draft.id)
                h.secrets.accountReadErrors[account] = failure
                let before = h.service.snapshot
                let previous = h.secrets.persisted[account]
                XCTAssertThrowsError(try recover(operation, draft: draft, service: h.service)) {
                    if let failure = failure as? SecretStoreError {
                        XCTAssertEqual($0 as? ProviderSettingsError, .secret(failure))
                    } else { XCTAssertTrue($0 is CancellationError) }
                }
                XCTAssertEqual(h.service.snapshot, before)
                XCTAssertEqual(h.secrets.persisted[account], previous)
                XCTAssertTrue(h.secrets.deletions.isEmpty)
                XCTAssertEqual(h.secrets.writes.count, 1)
            }
        }
    }

    func testKeepAndCredentialReadsNeverDiscardAnUnreadableSecret() throws {
        let h = ProviderHarness()
        let draft = ProviderDraft(key: .typed(UUID().uuidString))
        try h.service.save(draft)
        let account = SecretAccount.provider(draft.id)
        let previous = h.secrets.persisted[account]
        h.secrets.accountReadErrors[account] = SecretStoreError.readFailed
        var keep = ProviderDraft(profile: h.service.snapshot.settings.profiles[0])
        keep.displayName = "Renamed"
        try h.service.save(keep)
        XCTAssertThrowsError(try h.service.resolveForTesting(keep)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .secret(.readFailed))
        }
        XCTAssertThrowsError(try h.service.secretTier(for: draft.id)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .secret(.readFailed))
        }
        XCTAssertEqual(h.secrets.persisted[account], previous)
        XCTAssertTrue(h.secrets.deletions.isEmpty)
        XCTAssertEqual(h.secrets.writes.count, 1)
        XCTAssertTrue(h.log.lines.isEmpty)
    }

    private func recover(_ operation: Recovery, draft: ProviderDraft, service: ProviderSettingsService) throws {
        if operation == .delete { try service.deleteProfile(draft.id); return }
        var edit = draft
        edit.displayName = "Changed"
        edit.key = operation == .clear ? .clear : .typed("replacement")
        try service.save(edit)
    }
}
