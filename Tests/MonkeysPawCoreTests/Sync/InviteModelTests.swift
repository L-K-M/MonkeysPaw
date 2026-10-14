import Foundation
import XCTest
@testable import MonkeysPawCore

final class InviteModelTests: XCTestCase {
    func testStagingPublishesDestinationOnlyAndDoesNotAccept() async throws {
        let (model, fake, main) = makeModel()
        var input = try fake.link.text
        let fullLink = input
        model.stage(&input)
        XCTAssertEqual(input, "")
        await settle(model, main)
        XCTAssertEqual(fake.stageCalls, 1)
        XCTAssertEqual(fake.acceptCalls, 0)
        XCTAssertEqual(fake.createCalls, 0)
        XCTAssertEqual(model.state.destination?.serverURL.host, "example.test")
        XCTAssertTrue(model.state.destination?.canJoin == true)
        XCTAssertFalse(model.state.accepted)
        XCTAssertTrue(model.state.canAccept)
        assertSyncPresentationRedacted(model, secrets: [fake.token, fullLink])
        assertSyncPresentationRedacted(model.state, secrets: [fake.token, fullLink])
        assertSyncPresentationRedacted(model.state.destination as Any, secrets: [fake.token, fullLink])
    }

    func testBareTokenPassesOnlyExplicitServerAndInvalidInputIsVisible() async throws {
        let (model, fake, main) = makeModel()
        var input = fake.token
        model.stage(&input)
        await settle(model, main)
        XCTAssertEqual(model.state.error, .serverRequired)
        input = fake.token
        model.stage(&input, server: "http://192.168.1.2/paw")
        await settle(model, main)
        XCTAssertTrue(model.state.destination?.usesHTTP == true)
        XCTAssertFalse(model.state.destination?.canJoin == true)
        input = "invalid"
        model.stage(&input)
        await settle(model, main)
        XCTAssertEqual(model.state.error, .invalidLink)
        XCTAssertNil(model.state.destination)
        XCTAssertEqual(fake.acceptCalls, 0)
    }

    func testAcceptConsumesPasswordAndStageAndRequiresExplicitRestage() async throws {
        let (model, fake, main) = makeModel()
        var input = try fake.link.text
        model.stage(&input)
        await settle(model, main)
        var password = "sensitive-password"
        model.accept(as: .newAccount, username: "newperson", password: &password, deviceName: "Desktop")
        XCTAssertEqual(password, "")
        await settle(model, main)
        XCTAssertEqual(fake.acceptCalls, 1)
        XCTAssertTrue(fake.password == SecretValue("sensitive-password"))
        XCTAssertTrue(model.state.accepted)
        XCTAssertFalse(model.state.canAccept)
        model.accept(as: .existingAccount, password: &password)
        await settle(model, main)
        XCTAssertEqual(fake.acceptCalls, 1)
        XCTAssertEqual(model.state.error, .noInvite)
        assertSyncPresentationRedacted(model.state, secrets: ["sensitive-password", fake.token])
    }

    func testBusyRejectsConcurrentCommandsAndStillConsumesInput() async throws {
        let (model, fake, main) = makeModel()
        let gate = SyncTransportGate()
        fake.createGate = gate
        model.create(groupID: SyncTestValues.group, role: .viewer)
        main.flush()
        await waitCreate(fake)
        var input = try fake.link.text, password = "rejected"
        model.stage(&input)
        model.accept(as: .newAccount, password: &password)
        model.create(groupID: SyncTestValues.group, role: .editor)
        model.copyCreatedLink()
        main.flush()
        XCTAssertEqual(input, "")
        XCTAssertEqual(password, "")
        XCTAssertEqual(fake.createCalls, 1)
        XCTAssertEqual(fake.stageCalls, 0)
        XCTAssertEqual(fake.acceptCalls, 0)
        XCTAssertEqual(fake.clipboard.writes.count, 0)
        await gate.open()
        await settle(model, main)
    }

    func testCreationIsDisplayedOnceCopyIsExplicitAndDismissClearsIt() async throws {
        let (model, fake, main) = makeModel()
        model.create(groupID: SyncTestValues.group, role: .editor)
        await settle(model, main)
        XCTAssertNotNil(model.state.created)
        XCTAssertTrue(fake.clipboard.writes.isEmpty)
        assertSyncPresentationRedacted(model.state, secrets: [fake.token, try fake.link.text])
        model.copyCreatedLink()
        main.flush()
        XCTAssertEqual(fake.clipboard.writes.count, 1)
        model.dismiss()
        main.flush()
        XCTAssertNil(model.state.created)
        XCTAssertNil(model.state.destination)
        model.copyCreatedLink()
        main.flush()
        XCTAssertEqual(fake.clipboard.writes.count, 1)
        XCTAssertEqual(model.state.error, .noInvite)
    }

    func testDismissDropsInFlightCreationAndQueuedStaging() async throws {
        let (model, fake, main) = makeModel()
        let gate = SyncTransportGate()
        fake.createGate = gate
        model.create(groupID: SyncTestValues.group, role: .viewer)
        main.flush()
        await waitCreate(fake)
        model.dismiss()
        main.flush()
        await gate.open()
        await settle(model, main)
        XCTAssertNil(model.state.created)
        var input = try fake.link.text
        model.stage(&input)
        main.flush()
        await model.drain() // UI completion stays queued.
        model.dismiss()
        main.flush()
        XCTAssertNil(model.state.destination)
        var password = ""
        model.accept(as: .existingAccount, password: &password)
        await settle(model, main)
        XCTAssertEqual(fake.acceptCalls, 0)
    }

    func testRetirementRejectsQueuedAndReplayedCompletionsAndInput() async throws {
        let (model, fake, main) = makeModel()
        var input = try fake.link.text
        model.stage(&input)
        main.flush()
        await model.drain()
        let completions = main.flush()
        XCTAssertNotNil(model.state.destination)
        model.retire()
        main.replay(completions)
        input = try fake.link.text
        var password = "password"
        model.stage(&input)
        model.accept(as: .newAccount, password: &password)
        main.flush()
        XCTAssertEqual(input, "")
        XCTAssertEqual(password, "")
        XCTAssertNil(model.state.destination)
        XCTAssertEqual(fake.stageCalls, 1)
        XCTAssertEqual(fake.acceptCalls, 0)
    }

    func testIndependentObserversCanBeRemovedBeforeQueuedDelivery() async throws {
        let (model, _, main) = makeModel()
        var first = 0, second = 0, native = 0
        let id = model.addObserver { _ in XCTAssertTrue(main.isUI); first += 1 }
        model.addObserver { _ in XCTAssertTrue(main.isUI); second += 1 }
        model.onChange = { XCTAssertTrue(main.isUI); native += 1 }
        model.create(groupID: SyncTestValues.group, role: .viewer)
        main.flush()
        model.removeObserver(id)
        await model.drain()
        main.flush(); main.flush()
        XCTAssertEqual(first, 0)
        XCTAssertGreaterThan(second, 0)
        XCTAssertGreaterThan(native, 0)
    }

    func testFailedAcceptIsGenericConsumesStageAndDoesNotReflectUnknownError() async throws {
        let (model, fake, main) = makeModel()
        fake.acceptIssue = .unavailableInvite
        var input = try fake.link.text
        model.stage(&input)
        await settle(model, main)
        var password = ""
        model.accept(as: .existingAccount, password: &password)
        await settle(model, main)
        XCTAssertEqual(model.state.error, .unavailableInvite)
        XCTAssertFalse(model.state.accepted)
        XCTAssertFalse(model.state.canAccept)
        model.accept(as: .existingAccount, password: &password)
        await settle(model, main)
        XCTAssertEqual(fake.acceptCalls, 1)
        fake.createFailure = NSError(domain: fake.token, code: 1)
        model.create(groupID: SyncTestValues.group, role: .viewer)
        await settle(model, main)
        XCTAssertEqual(model.state.error, .account(.invalidResponse))
        assertSyncPresentationRedacted(model.state, secrets: [fake.token])
    }

    func testAcceptedRefreshAndRegistrationFailureRemainVisibleWithCleanup() async throws {
        for issue in [InviteIssue.refreshIncomplete(.offline), .registrationIncomplete(.storageWrite)] {
            let (model, fake, main) = makeModel()
            fake.acceptedIssue = issue
            fake.cleanup = SyncAccountCleanup(remote: .unconfirmed)
            var input = try fake.link.text
            model.stage(&input)
            await settle(model, main)
            var password = "password"
            model.accept(as: .newAccount, password: &password)
            await settle(model, main)
            XCTAssertTrue(model.state.accepted)
            XCTAssertEqual(model.state.error, issue)
            XCTAssertFalse(model.state.cleanup.isComplete)
        }
    }

    func testAdmittedRedemptionFinishesAfterModelRelease() async throws {
        let main = SyncPresentationMain()
        let fake = InvitePresentationFake(main: main)
        var model: InviteModel? = InviteModel(service: fake, mainThread: main)
        var input = try fake.link.text
        model?.stage(&input)
        main.flush()
        await model?.drain()
        main.flush()
        let gate = SyncTransportGate()
        fake.acceptGate = gate
        var password = "password"
        model?.accept(as: .newAccount, password: &password)
        main.flush()
        weak var weakModel = model
        model = nil
        XCTAssertNil(weakModel)
        await gate.open()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if fake.finishedAccept { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(fake.finishedAccept)
        main.flush()
    }

    func testActualServicePublishesOnlyAfterExplicitAcceptAndCopy() async throws {
        let rig = try SyncInviteRig()
        try await rig.login()
        let main = SyncPresentationMain()
        let actual = InviteModel(service: rig.invites, mainThread: main)
        var input = rig.link.text
        actual.stage(&input)
        await settle(actual, main)
        XCTAssertEqual(rig.joinCalls, 0)
        var password = ""
        actual.accept(as: .existingAccount, password: &password)
        await settle(actual, main)
        await rig.sync.settle()
        XCTAssertTrue(actual.state.accepted)
        XCTAssertEqual(rig.joinCalls, 1)
        actual.create(groupID: SyncTestValues.group, role: .viewer)
        await settle(actual, main)
        XCTAssertTrue(rig.clipboard.writes.isEmpty)
        actual.copyCreatedLink()
        main.flush()
        XCTAssertEqual(rig.clipboard.writes.count, 1)
        try rig.assertNoInvitePersistence()
    }

    private func makeModel() -> (InviteModel, InvitePresentationFake, SyncPresentationMain) {
        let main = SyncPresentationMain()
        let fake = InvitePresentationFake(main: main)
        return (InviteModel(service: fake, mainThread: main), fake, main)
    }

    private func settle(_ model: InviteModel, _ main: SyncPresentationMain) async {
        main.flush()
        await model.drain()
        main.flush(); main.flush()
    }

    private func waitCreate(_ fake: InvitePresentationFake) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if fake.createCalls > 0 { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Create was not admitted")
    }
}

private final class InvitePresentationFake: InviteProviding {
    let main: SyncPresentationMain
    let token = String(repeating: "A", count: 43)
    let clipboard = InviteTestClipboard()
    private let lock = NSLock()
    private var stages = 0, accepts = 0, creates = 0
    private var suppliedPassword: SecretValue?
    private var finished = false
    var createGate: SyncTransportGate?
    var acceptGate: SyncTransportGate?
    var acceptIssue: InviteIssue?
    var createFailure: Error?
    var acceptedIssue: InviteIssue?
    var cleanup = SyncAccountCleanup()
    var stageCalls: Int { locked { stages } }
    var acceptCalls: Int { locked { accepts } }
    var createCalls: Int { locked { creates } }
    var password: SecretValue? { locked { suppliedPassword } }
    var finishedAccept: Bool { locked { finished } }
    var link: SyncInviteLink { get throws { try SyncInviteLink(token, server: "https://example.test/paw") } }

    init(main: SyncPresentationMain) { self.main = main }

    func stage(_ input: String, server: String?) throws -> SyncStagedInvite {
        XCTAssertFalse(main.isUI)
        locked { stages += 1 }
        let link: SyncInviteLink
        do { link = try SyncInviteLink(input, server: server) }
        catch SyncInviteLinkError.serverRequired { throw InviteIssue.serverRequired }
        catch { throw InviteIssue.invalidLink }
        let account = try XCTUnwrap(AccountPresentationFake.signedIn().account)
        return SyncStagedInvite(link: link, account: account, destination: InviteDestination(serverURL: link.server.baseURL,
            currentAccount: AccountConnection(account), canJoin: account.identity.serverURL == link.server.baseURL))
    }

    func accept(_ staged: SyncStagedInvite, as mode: InviteAcceptance, username: String,
                password: inout String, deviceName: String) async throws -> SyncInviteAcceptance {
        XCTAssertFalse(main.isUI)
        let value = SecretValue(password)
        password = ""
        locked { accepts += 1; suppliedPassword = value }
        if let acceptGate { await acceptGate.wait() }
        if let acceptIssue { throw acceptIssue }
        locked { finished = true }
        return SyncInviteAcceptance(snapshot: try AccountPresentationFake.signedIn(), issue: acceptedIssue, cleanup: cleanup)
    }

    func create(groupID: ULID, role: SyncAPI.InviteRole) async throws -> SyncInviteCreation {
        XCTAssertFalse(main.isUI)
        locked { creates += 1 }
        if let createGate { await createGate.wait() }
        if let createFailure { throw createFailure }
        return SyncInviteCreation(link: try link.text, expiresAt: "2026-10-21T00:00:00.000Z",
            target: .group(groupID: groupID.rawValue, role: role), account: try XCTUnwrap(AccountPresentationFake.signedIn().account))
    }

    func copy(_ created: SyncInviteCreation) throws {
        XCTAssertTrue(main.isUI)
        clipboard.writeText(created.link)
    }

    private func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
}
