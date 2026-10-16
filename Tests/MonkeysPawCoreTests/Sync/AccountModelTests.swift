import Foundation
import XCTest
@testable import MonkeysPawCore

final class AccountModelTests: XCTestCase {
    func testInitialLoadReadsMetadataOffUIWithoutStartupOrHTTP() async throws {
        let (model, fake, main) = makeModel()
        fake.snapshot = try AccountPresentationFake.signedIn()
        XCTAssertEqual(model.state.operation, .loading)
        await settle(model, main)
        XCTAssertFalse(model.state.isBusy)
        XCTAssertEqual(model.state.connection?.userID, SyncTestValues.user)
        XCTAssertEqual(model.state.devices.count, 2)
        XCTAssertEqual(model.state.groups.first?.role, .viewer)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testLoginConsumesPasswordBeforeQueuedAdmissionAndPublishesMetadata() async throws {
        let (model, fake, main) = makeModel()
        await settle(model, main)
        fake.handler = { _ in try AccountPresentationFake.signedIn(tier: .file) }
        let reset = model.state.passwordInputReset
        var password = "typed-password-" + UUID().uuidString
        let supplied = password
        model.login(server: "https://example.test/paw", username: "person", password: &password, deviceName: "Desktop")
        XCTAssertEqual(password, "")
        XCTAssertTrue(fake.calls.isEmpty)
        main.flush()
        XCTAssertEqual(model.state.operation, .signingIn)
        let submitted = model.state.passwordInputReset
        XCTAssertNotEqual(reset, submitted)
        await settle(model, main)
        XCTAssertEqual(fake.password, SecretValue(supplied))
        XCTAssertEqual(fake.calls, [.login(server: "https://example.test/paw", username: "person", device: "Desktop")])
        XCTAssertTrue(model.state.enabled)
        XCTAssertNil(model.state.error)
        XCTAssertEqual(model.state.secretTier, .file)
        XCTAssertTrue(model.state.secretStorageMessage.contains("unencrypted"))
        XCTAssertNotEqual(submitted, model.state.passwordInputReset)
    }

    func testBusyIntentsCannotOverlapAndRejectedPasswordStillClears() async throws {
        let (model, fake, main) = makeModel()
        await settle(model, main)
        let gate = SyncTransportGate()
        fake.handler = { _ in await gate.wait(); return try AccountPresentationFake.signedIn() }
        var password = "first"
        model.login(server: "https://example.test/paw", username: "person", password: &password, deviceName: "Desktop")
        main.flush()
        await waitCalls(1, fake)
        var rejected = "second"
        model.login(server: "https://other.test", username: "other", password: &rejected, deviceName: "Other")
        model.refresh()
        model.startup()
        model.signOut()
        model.revokeDevice(SyncTestValues.device)
        main.flush()
        XCTAssertEqual(rejected, "")
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(model.state.operation, .signingIn)
        await gate.open()
        await settle(model, main)
        XCTAssertEqual(fake.calls.count, 1)
    }

    func testFailureIsVisibleAndCannotReflectPasswordOrHTTPPayloads() async throws {
        let (model, fake, main) = makeModel()
        await settle(model, main)
        let passwordSentinel = "password-" + UUID().uuidString
        let tokenSentinel = "token-" + UUID().uuidString
        fake.handler = { _ in
            throw SyncAccountServiceError(issue: .http(.validation(issues: [SyncAPI.Issue(
                code: tokenSentinel + passwordSentinel, severity: .error)])))
        }
        var states: [AccountState] = []
        model.onChange = { XCTAssertTrue(main.isUI); states.append(model.state) }
        var password = passwordSentinel
        model.login(server: "https://example.test", username: "person", password: &password, deviceName: "Desktop")
        await settle(model, main)
        XCTAssertEqual(model.state.error, .invalidInput)
        XCTAssertFalse(model.state.isBusy)
        XCTAssertFalse(model.state.enabled)
        for state in states {
            assertSyncPresentationRedacted(state, secrets: [passwordSentinel, tokenSentinel])
            // Inspect public fields independently of State's redacted Mirror.
            let fields: [Any] = [state.connection as Any, state.devices, state.groups, state.secretTier as Any,
                state.enabled, state.operation as Any, state.error as Any, state.cleanup,
                state.reservedFolders, state.heldPrompts, state.keptLocal, state.passwordInputReset]
            fields.forEach { assertSyncPresentationRedacted($0, secrets: [passwordSentinel, tokenSentinel]) }
        }
        assertSyncPresentationRedacted(model, secrets: [passwordSentinel, tokenSentinel])
    }

    func testUnknownErrorsDiscardDescriptionsAndKeepPartialCleanupVisible() async throws {
        let (model, fake, main) = makeModel()
        var cached = try AccountPresentationFake.signedIn()
        cached.cleanup = SyncAccountCleanup(remote: .unconfirmed, secretFailures: [UUID()], secretIssue: .deleteFailed)
        fake.snapshot = cached
        await settle(model, main)
        let sentinel = UUID().uuidString
        fake.handler = { _ in throw AccountSensitiveFailure(description: sentinel) }
        model.refresh()
        await settle(model, main)
        XCTAssertEqual(model.state.error, .invalidResponse)
        XCTAssertFalse(model.state.cleanup.isComplete)
        XCTAssertEqual(model.state.cleanup.failedSecretDeletions, 1)
        assertSyncPresentationRedacted(model.state, secrets: [sentinel])
    }

    func testReservedFolderDecisionLeavesSyncDisabledAndNeedsFreshLogin() async throws {
        let (model, fake, main) = makeModel()
        await settle(model, main)
        fake.handler = { _ in
            throw SyncAccountServiceError(issue: .reservedFolders(["Groups", "Conflicts"]))
        }
        var password = "submitted"
        model.login(server: "https://example.test", username: "person", password: &password, deviceName: "Desktop")
        await settle(model, main)
        XCTAssertEqual(model.state.error, .reservedFolders)
        XCTAssertEqual(model.state.reservedFolders, ["Conflicts", "Groups"])
        XCTAssertFalse(model.state.enabled)
        XCTAssertEqual(password, "")
        fake.handler = { _ in try AccountPresentationFake.signedIn() }
        model.refresh()
        await settle(model, main)
        XCTAssertTrue(fake.calls.count == 1)
        XCTAssertFalse(model.state.enabled)
        var newPassword = "fresh"
        model.login(server: "https://example.test", username: "person", password: &newPassword, deviceName: "Desktop")
        await settle(model, main)
        XCTAssertTrue(model.state.enabled)
        XCTAssertTrue(model.state.reservedFolders.isEmpty)
        XCTAssertEqual(fake.password, SecretValue("fresh"))
    }

    func testStartupAndDeviceRefreshAreExplicitUIIntents() async throws {
        let (model, fake, main) = makeModel()
        await settle(model, main)
        fake.handler = { _ in try AccountPresentationFake.signedIn() }
        model.startup()
        await settle(model, main)
        model.refresh()
        await settle(model, main)
        XCTAssertEqual(fake.calls, [.startup, .refresh])
        XCTAssertEqual(model.state.devices.map(\.isCurrent), [true, false])
    }

    func testOtherDeviceRevokeRefreshesAndCurrentDeviceRevokeSignsOut() async throws {
        let (model, fake, main) = makeModel()
        let signedIn = try AccountPresentationFake.signedIn()
        fake.snapshot = signedIn
        await settle(model, main)
        fake.handler = { call in
            if call == .revoke(SyncTestValues.device) { return SyncAccountSnapshot() }
            return signedIn
        }
        model.revokeDevice(SyncTestValues.group)
        await settle(model, main)
        XCTAssertEqual(fake.calls, [.revoke(SyncTestValues.group), .refresh])
        XCTAssertTrue(model.state.enabled)
        model.revokeDevice(SyncTestValues.device)
        await settle(model, main)
        XCTAssertEqual(fake.calls.last, .revoke(SyncTestValues.device))
        XCTAssertFalse(model.state.enabled)
        XCTAssertNil(model.state.connection)
        XCTAssertTrue(model.state.devices.isEmpty)
    }

    func testUnknownDeviceAndHeldSelectionsAreRejectedLocally() async throws {
        let (model, fake, main) = makeModel()
        fake.snapshot = try AccountPresentationFake.signedIn()
        await settle(model, main)
        model.revokeDevice(SyncTestValues.personalPrompt)
        await settle(model, main)
        XCTAssertEqual(model.state.error, .invalidSelection)
        model.decideHeld([.assigned(SyncTestValues.personalPrompt)], decision: .include)
        await settle(model, main)
        XCTAssertEqual(model.state.error, .invalidSelection)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testHeldFilesRemainLocalUntilExplicitInclusion() async throws {
        let (model, fake, main) = makeModel()
        let first = try AccountPresentationFake.hold()
        let second = try AccountPresentationFake.hold(SyncTestValues.groupPrompt, path: "rescued.md")
        fake.snapshot = try AccountPresentationFake.signedIn(user: SyncTestValues.otherUser)
        fake.holds = [second, first]
        await settle(model, main)
        XCTAssertTrue(model.state.needsHeldDecision)
        XCTAssertEqual(model.state.heldPrompts.map(\.path), ["old.md", "rescued.md"])
        model.decideHeld([first.identity, second.identity], decision: .keepLocal)
        await settle(model, main)
        XCTAssertFalse(model.state.needsHeldDecision)
        XCTAssertEqual(fake.holds.count, 2)
        XCTAssertTrue(fake.calls.isEmpty)
        model.refresh()
        await settle(model, main)
        XCTAssertFalse(model.state.needsHeldDecision)
        model.decideHeld([first.identity], decision: .include)
        main.flush()
        XCTAssertEqual(model.state.operation, .includingHeld)
        await settle(model, main)
        XCTAssertEqual(fake.calls, [.refresh, .include([first.identity])])
        XCTAssertEqual(model.state.heldPrompts.map(\.identity), [second.identity])
        XCTAssertEqual(fake.holds.map(\.identity), [second.identity])
    }

    func testFailedInclusionPreservesHoldAndCannotClaimConsentSucceeded() async throws {
        let (model, fake, main) = makeModel()
        let hold = try AccountPresentationFake.hold()
        fake.snapshot = try AccountPresentationFake.signedIn(user: SyncTestValues.otherUser)
        fake.holds = [hold]
        await settle(model, main)
        fake.handler = { _ in throw SyncAccountServiceError(issue: .metadata(.writeFailed(.ioFailure))) }
        model.decideHeld([hold.identity], decision: .include)
        await settle(model, main)
        XCTAssertEqual(model.state.error, .storageWrite)
        XCTAssertTrue(model.state.needsHeldDecision)
        XCTAssertEqual(model.state.heldPrompts.map(\.identity), [hold.identity])
        XCTAssertEqual(fake.holds, [hold])
    }

    func testFailedIntentAndHoldReadPreserveLastKnownHeldDecisions() async throws {
        let readFailures: [Error] = [SyncAccountServiceError(issue: .metadata(.readFailed(.ioFailure))),
            AccountSensitiveFailure(description: UUID().uuidString)]
        for failure in readFailures {
            let (model, fake, main) = makeModel()
            let first = try AccountPresentationFake.hold()
            let second = try AccountPresentationFake.hold(SyncTestValues.groupPrompt, path: "rescued.md")
            fake.snapshot = try AccountPresentationFake.signedIn(user: SyncTestValues.otherUser)
            fake.holds = [first, second]
            await settle(model, main)
            model.decideHeld([first.identity], decision: .keepLocal)
            await settle(model, main)
            let previous = model.state.heldPrompts
            fake.handler = { _ in throw SyncAccountServiceError(issue: .http(.transport(.networkFailure))) }
            fake.holdsError = failure
            model.refresh()
            await settle(model, main)
            XCTAssertEqual(model.state.error, .offline)
            XCTAssertEqual(model.state.heldPrompts, previous)
            XCTAssertEqual(model.state.keptLocal, [first.identity])
            XCTAssertTrue(model.state.needsHeldDecision)

            fake.holdsError = nil
            fake.handler = nil
            model.decideHeld([second.identity], decision: .include)
            await settle(model, main)
            XCTAssertEqual(fake.calls, [.refresh, .include([second.identity])])
            XCTAssertNil(model.state.error)
            XCTAssertEqual(model.state.heldPrompts.map(\.identity), [first.identity])
            XCTAssertEqual(model.state.keptLocal, [first.identity])
            XCTAssertFalse(model.state.needsHeldDecision)
        }
    }

    func testSuccessfulInclusionWithFailedHoldReadDoesNotRestoreOldHolds() async throws {
        let (model, fake, main) = makeModel()
        let hold = try AccountPresentationFake.hold()
        fake.snapshot = try AccountPresentationFake.signedIn(user: SyncTestValues.otherUser)
        fake.holds = [hold]
        await settle(model, main)
        fake.holdsError = SyncAccountServiceError(issue: .metadata(.readFailed(.ioFailure)))
        model.decideHeld([hold.identity], decision: .include)
        await settle(model, main)
        XCTAssertEqual(fake.calls, [.include([hold.identity])])
        XCTAssertTrue(fake.holds.isEmpty)
        XCTAssertEqual(model.state.error, .storageRead)
        XCTAssertTrue(model.state.heldPrompts.isEmpty)
        XCTAssertTrue(model.state.keptLocal.isEmpty)
    }

    func testAccountChangeAndNewHoldsRequireAnotherDecision() async throws {
        let (model, fake, main) = makeModel()
        let hold = try AccountPresentationFake.hold()
        fake.snapshot = try AccountPresentationFake.signedIn()
        fake.holds = [hold]
        await settle(model, main)
        model.decideHeld([hold.identity], decision: .keepLocal)
        await settle(model, main)
        fake.holds += [try AccountPresentationFake.hold(SyncTestValues.groupPrompt, path: "new.md")]
        model.refresh()
        await settle(model, main)
        XCTAssertTrue(model.state.needsHeldDecision)
        fake.handler = { _ in try AccountPresentationFake.signedIn(user: SyncTestValues.otherUser) }
        var password = "new-account"
        model.login(server: "https://example.test/paw", username: "other", password: &password, deviceName: "Desktop")
        await settle(model, main)
        XCTAssertTrue(model.state.keptLocal.isEmpty)
        XCTAssertTrue(model.state.needsHeldDecision)
        XCTAssertEqual(fake.holds.count, 2)
        XCTAssertFalse(fake.calls.contains { if case .include = $0 { return true }; return false })
    }

    func testSignOutPublishesPartialCleanupEvenWithoutAThrownError() async throws {
        let (model, fake, main) = makeModel()
        fake.snapshot = try AccountPresentationFake.signedIn()
        await settle(model, main)
        fake.handler = { _ in SyncAccountSnapshot(cleanup: SyncAccountCleanup(remote: .unconfirmed,
            secretFailures: [UUID()], secretIssue: .locked, metadataIssue: .durabilityUncertain, recoveryRequired: true)) }
        model.signOut()
        main.flush()
        XCTAssertEqual(model.state.operation, .signingOut)
        await settle(model, main)
        XCTAssertNil(model.state.connection)
        XCTAssertFalse(model.state.enabled)
        XCTAssertNil(model.state.error)
        XCTAssertFalse(model.state.cleanup.isComplete)
        XCTAssertEqual(model.state.cleanup.remoteRevocation, .unconfirmed)
        XCTAssertEqual(model.state.cleanup.secretIssue, .locked)
        XCTAssertEqual(model.state.cleanup.metadataIssue, .durabilityUncertain)
        XCTAssertTrue(model.state.cleanup.recoveryRequired)
    }

    func testStorageTierLabelsAndLoadingFailureAreActionable() async throws {
        for tier in [SecretTier.keychain, .secretService, .environment, .file] {
            let (model, fake, main) = makeModel()
            fake.snapshot = try AccountPresentationFake.signedIn(tier: tier)
            fake.holdsError = SyncAccountServiceError(issue: .metadata(.readFailed(.ioFailure)))
            await settle(model, main)
            XCTAssertEqual(model.state.error, .storageRead)
            XCTAssertEqual(model.state.secretTier, tier)
            XCTAssertFalse(model.state.isBusy)
            if tier == .environment { XCTAssertTrue(model.state.secretStorageMessage.contains("read-only")) }
            if tier == .file { XCTAssertTrue(model.state.secretStorageMessage.contains("unencrypted")) }
        }
    }

    func testReplayedCompletionCannotOverwriteANewerOperationOrRepublish() async throws {
        let (model, fake, main) = makeModel()
        main.flush()
        await model.drain()
        let completion = main.flush()
        main.flush()
        fake.handler = { _ in try AccountPresentationFake.signedIn() }
        var password = "login"
        model.login(server: "https://example.test", username: "person", password: &password, deviceName: "Desktop")
        main.flush()
        XCTAssertEqual(model.state.operation, .signingIn)
        main.replay(completion)
        XCTAssertEqual(model.state.operation, .signingIn)
        await settle(model, main)
        let expected = model.state
        main.replay(completion)
        XCTAssertEqual(model.state, expected)
    }

    func testIndependentObserversRemoveBeforeQueuedDelivery() async throws {
        let (model, _, main) = makeModel()
        var first = 0
        var second = 0
        var hook = 0
        let removed = model.addObserver { _ in first += 1 }
        let remaining = model.addObserver { _ in XCTAssertTrue(main.isUI); second += 1 }
        model.onChange = { XCTAssertTrue(main.isUI); hook += 1 }
        main.flush()
        await model.drain()
        main.flush() // completion schedules observers
        model.removeObserver(removed)
        main.flush()
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
        XCTAssertEqual(hook, 1)
        model.removeObserver(remaining)
        model.clearPasswordInput()
        await settle(model, main)
        XCTAssertEqual(second, 1)
        XCTAssertEqual(hook, 2)
    }

    func testRetirementFencesQueuedIntentsAndCompletionsButDrainsAcceptedCleanup() async throws {
        let (model, fake, main) = makeModel()
        await settle(model, main)
        let gate = SyncTransportGate()
        fake.handler = { _ in await gate.wait(); return SyncAccountSnapshot() }
        model.signOut()
        main.flush()
        await waitCalls(1, fake)
        var notifications = 0
        model.addObserver { _ in notifications += 1 }
        model.onChange = { notifications += 1 }
        let before = model.state
        model.retire()
        model.startup()
        model.refresh()
        var password = "retired"
        model.login(server: "https://example.test", username: "person", password: &password, deviceName: "Desktop")
        XCTAssertEqual(password, "")
        await gate.open()
        await model.drain()
        main.flush()
        main.flush()
        XCTAssertEqual(fake.calls, [.signOut])
        XCTAssertEqual(model.state, before)
        XCTAssertEqual(notifications, 0)
    }

    func testQueuedCallbacksDoNotRetainAReleasedModel() async throws {
        let main = SyncPresentationMain()
        let fake = AccountPresentationFake(main: main)
        var model: AccountModel? = AccountModel(account: fake, mainThread: main)
        weak var released = model
        model = nil
        main.flush()
        XCTAssertNil(released)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testAcceptedSignOutFinishesAfterModelIsReleased() async throws {
        let main = SyncPresentationMain()
        let fake = AccountPresentationFake(main: main)
        fake.snapshot = try AccountPresentationFake.signedIn()
        var model: AccountModel? = AccountModel(account: fake, mainThread: main)
        await settle(try XCTUnwrap(model), main)
        let gate = SyncTransportGate()
        fake.handler = { _ in await gate.wait(); return SyncAccountSnapshot() }
        model?.signOut()
        main.flush()
        await waitCalls(1, fake)
        let released = { [weak model] in model == nil }
        model = nil
        XCTAssertTrue(released())
        await gate.open()
        for _ in 0..<2_000 {
            if fake.snapshot.account == nil { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        main.flush()
        XCTAssertNil(fake.snapshot.account)
        XCTAssertEqual(fake.calls, [.signOut])
    }

    func testActualAccountServiceLoginAndUnconfirmedSignOutPublishNoSecrets() async throws {
        let rig = try SyncServiceRig()
        let secrets = FakeProviderSecrets()
        let account = try SyncAccountService(sync: rig.service, accounts: rig.accounts,
            secrets: secrets, transport: rig.transport, libraryRoot: "/library")
        let main = SyncPresentationMain()
        let model = AccountModel(account: account, mainThread: main)
        await settle(model, main)
        let fixture = try XCTUnwrap(AccountPresentationFake.signedIn().me)
        let token = String(repeating: "q", count: 42) + "A"
        rig.transport.handler = { _, request in
            if request.url.path.hasSuffix("/login") {
                return try SyncServiceRig.http(SyncAPI.AuthResponse(deviceToken: token, user: fixture.user))
            }
            if request.url.path.hasSuffix("/me") {
                return try SyncServiceRig.http(SyncAPI.MeResponse(user: fixture.user, groups: [], devices: fixture.devices))
            }
            if request.url.path.hasSuffix("/sync/pull") { return try SyncServiceRig.pull() }
            throw HTTPTransportError.networkFailure
        }
        let supplied = "password-" + UUID().uuidString
        var password = supplied
        model.login(server: "https://example.test/paw", username: "person", password: &password, deviceName: "Desktop")
        await settle(model, main)
        await rig.settle()
        XCTAssertNil(model.state.error)
        XCTAssertTrue(model.state.enabled)
        XCTAssertEqual(model.state.devices, fixture.devices)
        XCTAssertEqual(model.state.secretTier, .secretService)
        XCTAssertEqual(secrets.persisted.count, 1)
        assertSyncPresentationRedacted(model, secrets: [supplied, token])
        assertSyncPresentationRedacted(model.state, secrets: [supplied, token])
        for file in try rig.base.data.listFiles() {
            let bytes = String(decoding: try rig.base.data.read(at: file.relativePath), as: UTF8.self)
            XCTAssertFalse(bytes.contains(supplied))
            XCTAssertFalse(bytes.contains(token))
        }
        model.signOut()
        await settle(model, main)
        XCTAssertNil(model.state.connection)
        XCTAssertFalse(model.state.enabled)
        XCTAssertEqual(model.state.cleanup.remoteRevocation, .unconfirmed)
        XCTAssertFalse(model.state.cleanup.isComplete)
        XCTAssertTrue(secrets.persisted.isEmpty)
        XCTAssertFalse(rig.service.report.enabled)
        assertSyncPresentationRedacted(model.state, secrets: [supplied, token])
    }

    private func makeModel() -> (AccountModel, AccountPresentationFake, SyncPresentationMain) {
        let main = SyncPresentationMain()
        let fake = AccountPresentationFake(main: main)
        return (AccountModel(account: fake, mainThread: main), fake, main)
    }

    private func settle(_ model: AccountModel, _ main: SyncPresentationMain) async {
        main.flush()
        await model.drain()
        main.flush()
        main.flush()
    }

    private func waitCalls(_ count: Int, _ fake: AccountPresentationFake) async {
        for _ in 0..<2_000 {
            if fake.calls.count >= count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Account intent was not admitted")
    }
}

private struct AccountSensitiveFailure: Error, CustomStringConvertible { let description: String }
