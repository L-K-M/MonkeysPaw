import Foundation
import XCTest
@testable import MonkeysPawCore

final class ProviderSyncKeyModelTests: XCTestCase {
    func testRefreshPreservesRevealOnlyForTheSameAccount() throws {
        let h = SyncKeyModelHarness()
        h.model.generate()
        let revealed = h.model.state.revealedKey
        XCTAssertNotNil(revealed)
        h.model.refresh()
        XCTAssertTrue(h.model.state.revealedKey == revealed)

        h.account.userID = SyncTestValues.otherUser
        h.model.refresh()
        XCTAssertEqual(h.model.state.status, .missing)
        XCTAssertTrue(h.model.state.revealedKey == nil, "A key for a previous account must stay hidden")

        h.account.userID = nil
        h.model.refresh()
        XCTAssertEqual(h.model.state.status, .noAccount)
        XCTAssertTrue(h.model.state.revealedKey == nil, "A key for a previous account must stay hidden")
    }

    func testSameAccountTierReadFailurePreservesRevealedKey() {
        let h = SyncKeyModelHarness()
        h.model.generate()
        let revealed = h.model.state.revealedKey
        XCTAssertNotNil(revealed)
        h.secrets.readError = .locked

        h.model.refresh()

        XCTAssertEqual(h.model.state.status, .unavailable)
        XCTAssertFalse(h.model.state.canEdit)
        XCTAssertTrue(h.model.state.revealedKey == revealed, "A tier read failure must not lose the same account's only reveal")

        h.secrets.readError = nil
        h.model.refresh()
        XCTAssertEqual(h.model.state.status, .provisioned(.secretService))
        XCTAssertTrue(h.model.state.revealedKey == revealed)
    }

    func testGeneratePreservesRevealedKeyWhenPostWriteTierReadFails() {
        let h = SyncKeyModelHarness()
        h.secrets.onWrite = { h.secrets.readError = .locked }

        h.model.generate()

        XCTAssertEqual(h.secrets.writes, [.providerSync(SyncTestValues.user)])
        XCTAssertEqual(h.model.state.status, .unavailable)
        XCTAssertFalse(h.model.state.busy)
        XCTAssertFalse(h.model.state.canEdit)
        XCTAssertNotNil(h.model.state.revealedKey, "A committed key must remain available when only its tier read fails")
    }

    func testUnresolvedAccountStillClearsRevealedKey() {
        let h = SyncKeyModelHarness()
        h.model.generate()
        XCTAssertNotNil(h.model.state.revealedKey)
        h.account.isUnavailable = true

        h.model.refresh()

        XCTAssertEqual(h.model.state.status, .unavailable)
        XCTAssertFalse(h.model.state.canEdit)
        XCTAssertTrue(h.model.state.revealedKey == nil, "An unresolved account must not retain a previous account's reveal")

        h.account.isUnavailable = false
        h.model.refresh()
        XCTAssertEqual(h.model.state.status, .provisioned(.secretService))
        XCTAssertTrue(h.model.state.revealedKey == nil, "Resolving the account again must not restore a retired reveal")
    }

    func testQueuedGenerateCannotMoveToANewerAccount() {
        let h = SyncKeyModelHarness()
        h.work.isHeld = true
        h.model.generate()
        h.account.userID = SyncTestValues.otherUser
        h.model.refresh()
        h.work.releaseAll()

        XCTAssertTrue(h.secrets.writes.isEmpty, "An action from the old account must not provision the new account")
        XCTAssertEqual(h.model.state.status, .missing)
        XCTAssertFalse(h.model.state.busy)
        XCTAssertTrue(h.model.state.revealedKey == nil, "A key for a previous account must stay hidden")
    }

    func testAccountChangeDuringWriteCannotPublishTheOldReveal() {
        let h = SyncKeyModelHarness()
        h.secrets.onWrite = { h.account.userID = SyncTestValues.otherUser }
        h.model.generate()

        XCTAssertEqual(h.secrets.writes, [.providerSync(SyncTestValues.user)])
        XCTAssertEqual(h.model.state.status, .missing)
        XCTAssertFalse(h.model.state.busy)
        XCTAssertTrue(h.model.state.revealedKey == nil, "A key for a previous account must stay hidden")
    }

    func testAccountInvalidationClearsRevealAndEntryBeforeResolvingTheNewAccount() {
        let h = SyncKeyModelHarness()
        h.model.generate()
        let reset = h.model.state.inputReset
        h.work.isHeld = true
        h.account.userID = SyncTestValues.otherUser
        h.model.accountDidChange()
        XCTAssertTrue(h.model.state.revealedKey == nil, "The previous key must be hidden immediately")
        XCTAssertNotEqual(h.model.state.inputReset, reset)
        XCTAssertFalse(h.model.state.canEdit)
        h.work.releaseAll()
        XCTAssertEqual(h.model.state.status, .missing)
        XCTAssertFalse(h.model.state.busy)
    }

    func testNewBindingReplyBeforeRetiredOperationReplyDoesNotLeaveBusy() {
        let h = SyncKeyModelHarness()
        h.work.isHeld = true
        h.model.generate()
        h.account.userID = SyncTestValues.otherUser
        h.model.accountDidChange()
        h.main.isHeld = true
        h.work.releaseAll()
        XCTAssertEqual(h.main.pending.count, 2)
        h.main.releaseLast()
        XCTAssertTrue(h.model.state.busy)
        h.main.releaseNext()
        XCTAssertFalse(h.model.state.busy)
        XCTAssertEqual(h.model.state.status, .missing)
        XCTAssertTrue(h.model.state.revealedKey == nil, "Retired replies must not reveal a key")
        XCTAssertTrue(h.secrets.writes.isEmpty)
    }

    func testRetiredOperationReplyBeforeNewBindingReplyDoesNotRestoreItsReveal() {
        let h = SyncKeyModelHarness()
        h.work.isHeld = true
        h.model.generate()
        h.work.releaseNext()
        h.model.generate()
        h.account.userID = SyncTestValues.otherUser
        h.model.accountDidChange()
        h.main.isHeld = true
        h.work.releaseAll()
        h.main.releaseNext()
        XCTAssertTrue(h.model.state.busy)
        XCTAssertTrue(h.model.state.revealedKey == nil, "Retired replies must not reveal a key")
        h.main.releaseNext()
        XCTAssertFalse(h.model.state.busy)
        XCTAssertEqual(h.model.state.status, .missing)
    }

    func testRetiredStatusReadCannotOverwriteANewerAccount() {
        let h = SyncKeyModelHarness()
        h.work.isHeld = true
        h.model.refresh()
        h.main.isHeld = true
        h.work.releaseNext()
        h.main.isHeld = false
        h.account.userID = nil
        h.model.accountDidChange()
        h.work.releaseAll()
        h.main.releaseNext()
        XCTAssertEqual(h.model.state.status, .noAccount)
        XCTAssertFalse(h.model.state.busy)
    }

    func testBindingInvalidationRevokesAQueuedOperationEvenForTheSameUser() {
        let h = SyncKeyModelHarness()
        h.work.isHeld = true
        h.model.generate()
        h.model.accountDidChange()
        h.work.releaseAll()
        XCTAssertTrue(h.secrets.writes.isEmpty, "A retired queued action must not replace a key whose reveal was revoked")
        XCTAssertEqual(h.model.state.status, .missing)
        XCTAssertFalse(h.model.state.busy)
        XCTAssertTrue(h.model.state.revealedKey == nil, "A retired queued action must remain hidden")
    }

    func testRebindingReplacesTheRetiredAccountResolver() {
        let h = SyncKeyModelHarness()
        h.model.generate()
        h.model.accountDidChange(accountUserID: { SyncTestValues.otherUser })
        XCTAssertEqual(h.model.state.status, .missing)
        XCTAssertTrue(h.model.state.revealedKey == nil, "Rebinding must retire the previous reveal")
        h.model.generate()
        XCTAssertEqual(h.secrets.writes, [.providerSync(SyncTestValues.user), .providerSync(SyncTestValues.otherUser)])
        XCTAssertEqual(h.model.state.status, .provisioned(.secretService))
    }

    func testSameAccountRefreshDuringGeneratePreservesItsCompletion() {
        let h = SyncKeyModelHarness()
        h.work.isHeld = true
        h.model.generate()
        h.model.refresh()
        h.work.releaseAll()

        XCTAssertEqual(h.model.state.status, .provisioned(.secretService))
        XCTAssertFalse(h.model.state.busy)
        XCTAssertNotNil(h.model.state.revealedKey)
        XCTAssertEqual(h.secrets.writes, [.providerSync(SyncTestValues.user)])
    }
}

private final class SyncKeyAccount {
    var userID: ULID? = SyncTestValues.user
    var isUnavailable = false
}

private final class SyncKeyModelHarness {
    let account = SyncKeyAccount()
    let marker = EditingThreadMarker()
    let main: SyncKeyModelMain
    let work: AssistantSettingsWork
    let secrets = SyncKeyModelSecrets()
    let model: ProviderSyncKeyModel

    init() {
        main = SyncKeyModelMain(marker)
        work = AssistantSettingsWork(marker)
        let account = account
        let marker = marker
        let entropy = LibraryEntropy()
        entropy.value = Array(0..<32).map(UInt8.init)
        model = ProviderSyncKeyModel(keys: ProviderSyncKeyService(secrets: secrets, entropy: entropy),
            accountUserID: {
                XCTAssertFalse(marker.isUI, "Account metadata must be read away from the UI thread")
                if account.isUnavailable { throw FileStoreError.ioFailure }
                return account.userID
            }, work: work, mainThread: main)
    }
}

private final class SyncKeyModelSecrets: SecretStore {
    var onWrite: (() -> Void)?
    var readError: SecretStoreError?
    private var values: [SecretAccount: StoredSecret] = [:]
    private(set) var writes: [SecretAccount] = []

    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        if let readError { throw readError }
        return values[account]
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        writes.append(account)
        values[account] = StoredSecret(value: value, tier: .secretService)
        onWrite?()
        return .secretService
    }
    func delete(account: SecretAccount) throws { values[account] = nil }
}

private final class SyncKeyModelMain: MainThread {
    private let marker: EditingThreadMarker
    var isHeld = false
    private(set) var pending: [() -> Void] = []

    init(_ marker: EditingThreadMarker) { self.marker = marker }
    func run(_ work: @escaping () -> Void) {
        if isHeld { pending.append(work) }
        else { marker.ui(work) }
    }
    func releaseNext() { marker.ui(pending.removeFirst()) }
    func releaseLast() { marker.ui(pending.removeLast()) }
}
