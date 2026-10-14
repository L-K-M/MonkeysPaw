import Foundation
import XCTest
@testable import MonkeysPawCore

final class ConflictModelTests: XCTestCase {
    func testReplayedLoadCompletionDoesNotInvalidateAcceptedPreviewOrPublishTwice() async throws {
        let h = try await ConflictTestRig.make()
        let main = SyncPresentationMain()
        let model = ConflictModel(service: h.service, mainThread: main)
        var ready = 0
        _ = model.addObserver { if $0.preview != nil && !$0.isBusy { ready += 1 } }
        model.open(h.selection); main.flush()
        await model.drain()
        let callbacks = main.flush()
        main.replay(callbacks)
        main.flush()
        XCTAssertEqual(ready, 1)
        model.resolve(.keepMine); main.flush()
        await settle(model, main)
        XCTAssertEqual(model.state.resolved, .keepMine)
        XCTAssertEqual(h.putCount, 1)
    }

    func testLoadingAndSuccessfulDecisionPublishOnlyThroughMainThread() async throws {
        let h = try await ConflictTestRig.make()
        let main = SyncPresentationMain()
        let model = ConflictModel(service: h.service, mainThread: main)
        var observed: [ConflictState] = []
        _ = model.addObserver { state in XCTAssertTrue(main.isUI); observed.append(state) }
        model.open(h.selection)
        XCTAssertNil(model.state.preview)
        main.flush()
        XCTAssertEqual(model.state.operation, .loading)
        await settle(model, main)
        XCTAssertTrue(model.state.canKeepMine)
        XCTAssertTrue(model.state.canKeepServer)
        XCTAssertTrue(model.state.canKeepBoth)
        model.resolve(.keepBoth)
        main.flush()
        await settle(model, main)
        XCTAssertEqual(model.state.resolved, .keepBoth)
        XCTAssertNil(model.state.preview)
        XCTAssertFalse(model.state.isBusy)
        XCTAssertEqual(observed.filter { $0.resolved == .keepBoth }.count, 1)
    }

    func testChangedHeadRefreshRequiresAnotherChoiceAndKeepsMineEnabled() async throws {
        let h = try await ConflictTestRig.make()
        let main = SyncPresentationMain()
        let model = ConflictModel(service: h.service, mainThread: main)
        model.open(h.selection); main.flush()
        await settle(model, main)
        h.revision = 2
        h.serverBytes = SyncScanTestSupport.bytes("Newest", id: h.original)
        model.resolve(.keepMine); main.flush()
        await settle(model, main)
        XCTAssertEqual(model.state.error, .headChanged)
        XCTAssertEqual(model.state.preview?.serverBytes, h.serverBytes)
        XCTAssertTrue(model.state.canKeepMine)
        XCTAssertEqual(h.putCount, 0)
        model.resolve(.keepMine); main.flush()
        await settle(model, main)
        XCTAssertEqual(model.state.resolved, .keepMine)
        XCTAssertEqual(h.putCount, 1)
    }

    func testBusyActionsCoalesceAndRetirementRevokesInFlightDecision() async throws {
        let h = try await ConflictTestRig.make()
        let main = SyncPresentationMain()
        let model = ConflictModel(service: h.service, mainThread: main)
        model.open(h.selection); main.flush()
        await settle(model, main)
        let gate = SyncTransportGate(), entered = SyncTransportGate()
        h.beforeGet = { await entered.open(); await gate.wait() }
        var notifications = 0
        _ = model.addObserver { _ in notifications += 1 }
        model.resolve(.keepMine)
        model.resolve(.keepServer)
        main.flush()
        await entered.wait()
        XCTAssertTrue(model.state.isBusy)
        model.retire()
        let before = notifications
        await gate.open()
        await model.drain()
        main.flush()
        XCTAssertEqual(notifications, before)
        XCTAssertEqual(h.putCount, 0)
        XCTAssertEqual(try h.rig.base.files.read(at: h.path), h.copyBytes)
    }

    func testCloseRejectsQueuedLoadRepliesAndReplayCannotPublishTwice() async throws {
        let h = try await ConflictTestRig.make()
        let main = SyncPresentationMain()
        let model = ConflictModel(service: h.service, mainThread: main)
        var states: [ConflictState] = []
        let token = model.addObserver { states.append($0) }
        model.open(h.selection); main.flush()
        await model.drain()
        model.close()
        main.flush(); main.flush()
        XCTAssertNil(model.state.preview)
        XCTAssertFalse(model.state.isBusy)
        let count = states.count
        model.removeObserver(token)
        model.open(h.selection); main.flush()
        await model.drain()
        let callbacks = main.flush()
        main.replay(callbacks)
        main.flush()
        XCTAssertEqual(states.count, count)
        XCTAssertNotNil(model.state.preview)
    }

    func testFailedCASOrAccessKeepsPreviewAndCopyForRetryOrKeepBoth() async throws {
        let h = try await ConflictTestRig.make(group: true)
        let main = SyncPresentationMain()
        let model = ConflictModel(service: h.service, mainThread: main)
        model.open(h.selection); main.flush()
        await settle(model, main)
        h.putFailure = .forbidden
        model.resolve(.keepMine); main.flush()
        await settle(model, main)
        XCTAssertEqual(model.state.error, .accessDenied)
        XCTAssertFalse(model.state.canKeepMine)
        XCTAssertTrue(model.state.canKeepBoth)
        XCTAssertNotNil(model.state.preview)
        XCTAssertEqual(try h.rig.base.files.read(at: h.path), h.copyBytes)
        model.resolve(.keepBoth); main.flush()
        await settle(model, main)
        XCTAssertEqual(model.state.resolved, .keepBoth)
    }

    private func settle(_ model: ConflictModel, _ main: SyncPresentationMain) async {
        await model.drain()
        main.flush()
        main.flush()
    }
}
