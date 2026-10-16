import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncStatusModelTests: XCTestCase {
    func testFooterMatrixPreservesStatusPhaseCountsAndLastSuccess() {
        let (model, sync, main) = makeModel()
        let success = Date(timeIntervalSince1970: 42)
        let cases: [(SyncFooter, (inout SyncReport) -> Void)] = [
            (.disabled, { $0.enabled = false }),
            (.idle, { _ in }),
            (.syncing, { $0.phase = .collecting }),
            (.resyncing, { $0.phase = .resyncing }),
            (.offline, { $0.offline = true }),
            (.needsSignIn, { $0.needsSignIn = true }),
            (.hasConflicts, { $0.counts.conflicts = 3 }),
            (.syncError, { $0.counts.fileErrors = 2 }),
            (.syncError, { $0.counts.pending = 1 }),
            (.syncError, { $0.retrying = true })
        ]
        for (footer, edit) in cases {
            var report = SyncReport()
            report.enabled = true
            report.lastSuccess = success
            edit(&report)
            sync.send(report)
            main.flush()
            XCTAssertEqual(model.state.footer, footer)
            XCTAssertEqual(model.state.status, report.status)
            XCTAssertEqual(model.state.phase, report.phase)
            XCTAssertEqual(model.state.counts, report.counts)
            XCTAssertEqual(model.state.lastSuccess, success)
            XCTAssertEqual(model.state.retrying, report.retrying)
            XCTAssertFalse(model.state.footer.text.isEmpty)
        }
    }

    func testSignInRequiredRemainsVisibleWhenAccountServiceDisablesSync() {
        let (model, sync, main) = makeModel()
        var report = SyncReport()
        report.enabled = false // SyncAccountService.requireSignIn uses this state.
        report.needsSignIn = true
        report.blockingIssue = .recoveryRequired
        sync.send(report)
        main.flush()
        XCTAssertEqual(model.state.footer, .needsSignIn)
        XCTAssertEqual(model.state.action, .account)
        XCTAssertEqual(model.state.errorMessage, "Sign in again. Local changes remain queued.")
        XCTAssertFalse(model.state.canSyncNow)
    }

    func testIdleBeforeFirstSuccessDoesNotClaimItSynced() {
        let (model, sync, main) = makeModel()
        var report = SyncReport()
        report.enabled = true
        sync.send(report)
        main.flush()
        XCTAssertNil(model.state.lastSuccess)
        XCTAssertEqual(model.state.footer.text, "Sync idle")
    }

    func testPrecedenceAndActionsMatchReportWithoutClaimingPartialSuccess() {
        let (model, sync, main) = makeModel()
        var report = SyncReport()
        report.enabled = true
        report.counts.conflicts = 3
        report.counts.fileErrors = 2
        report.offline = true
        report.phase = .resyncing
        report.blockingIssue = .invalidProtocol
        report.needsSignIn = true
        let cases: [(SyncFooter, SyncStatusAction, (inout SyncReport) -> Void)] = [
            (.needsSignIn, .account, { _ in }),
            (.syncError, .errors, { $0.needsSignIn = false }),
            (.resyncing, .none, { $0.blockingIssue = nil }),
            (.offline, .syncNow, { $0.phase = .idle }),
            (.syncError, .errors, { $0.offline = false }),
            (.hasConflicts, .conflicts, { $0.counts.fileErrors = 0 }),
            (.idle, .syncNow, { $0.counts.conflicts = 0 })
        ]
        for (footer, action, edit) in cases {
            edit(&report)
            sync.send(report)
            main.flush()
            XCTAssertEqual(model.state.footer, footer)
            XCTAssertEqual(model.state.action, action)
            XCTAssertNil(model.state.lastSuccess)
        }
    }

    func testSyncNowRechecksLatestServiceReportAndBlocksUnsafeOrActiveWork() {
        let (model, sync, main) = makeModel()
        var enabled = SyncReport()
        enabled.enabled = true
        sync.send(enabled)
        main.flush()
        for edit in [
            { (r: inout SyncReport) in r.enabled = false },
            { (r: inout SyncReport) in r.needsSignIn = true },
            { (r: inout SyncReport) in r.phase = .pushing },
            { (r: inout SyncReport) in r.blockingIssue = .recoveryRequired }
        ] {
            model.syncNow()
            var blocked = enabled
            edit(&blocked)
            sync.report = blocked // No callback: intent must recheck the service.
            main.flush()
            XCTAssertEqual(sync.syncRequests, 0)
        }
        sync.report = enabled
        sync.onSync = { enabled.phase = .collecting; sync.send(enabled) }
        model.syncNow()
        model.syncNow()
        main.flush()
        main.flush()
        XCTAssertEqual(sync.syncRequests, 1)
        XCTAssertEqual(model.state.footer, .syncing)
    }

    func testSyncNowRechecksServiceAfterReentrantPublication() {
        let (model, sync, main) = makeModel()
        var report = SyncReport()
        report.enabled = true
        sync.report = report
        model.onChange = {
            report.needsSignIn = true
            sync.send(report)
        }
        model.syncNow()
        main.flush()
        XCTAssertEqual(sync.syncRequests, 0)
        main.flush()
        main.flush()
        XCTAssertEqual(model.state.footer, .needsSignIn)
    }

    func testErrorDetailsUseFixedReasonsAndNeverRetainUnknownBodyOrCode() {
        let (model, sync, main) = makeModel()
        let sentinel = "server-body-token-" + UUID().uuidString
        var report = SyncReport()
        report.enabled = true
        report.counts.fileErrors = 4
        report.details = [SyncFileDetail(path: "z.md", code: sentinel),
            SyncFileDetail(path: "a.md", code: PromptIssueCode.invalidYAML.rawValue),
            SyncFileDetail(path: "b.md", code: SyncPathIssueCode.segmentTooLong.rawValue),
            SyncFileDetail(path: "c.md", code: "forbidden")]
        sync.send(report)
        main.flush()
        model.showErrorDetails()
        main.flush()
        XCTAssertTrue(model.state.showsErrorDetails)
        XCTAssertEqual(model.state.fileErrors.map(\.path), ["a.md", "b.md", "c.md", "z.md"])
        XCTAssertEqual(model.state.fileErrors[0].reason, PromptIssue(.invalidYAML).message)
        XCTAssertEqual(model.state.fileErrors[1].reason, SyncPathIssueCode.segmentTooLong.message)
        XCTAssertTrue(model.state.fileErrors[2].reason.contains("Refresh group access"))
        XCTAssertFalse(model.state.fileErrors[2].reason.contains("viewer"))
        XCTAssertEqual(model.state.fileErrors[3].code, "sync.unknown")
        assertSyncPresentationRedacted(model.state, secrets: [sentinel])
        model.state.fileErrors.forEach {
            assertSyncPresentationRedacted([$0.path, $0.code, $0.reason] as [Any], secrets: [sentinel])
        }
        assertSyncPresentationRedacted(model, secrets: [sentinel])
        model.dismissErrorDetails()
        main.flush()
        XCTAssertFalse(model.state.showsErrorDetails)
        XCTAssertEqual(sync.syncRequests, 0)
    }

    func testBlockingErrorMessagesAndRetryingStateRemainActionable() {
        let (model, sync, main) = makeModel()
        for issue in [SyncBlockingIssue.rootUnavailable, .invalidState, .invalidProtocol, .recoveryRequired, .noProgress] {
            var report = SyncReport()
            report.enabled = true
            report.blockingIssue = issue
            sync.send(report)
            main.flush()
            XCTAssertEqual(model.state.footer, .syncError)
            XCTAssertEqual(model.state.blockingIssue, issue)
            XCTAssertNotNil(model.state.errorMessage)
            XCTAssertFalse(model.state.canSyncNow)
        }
    }

    func testOlderAndReplayedServiceCallbacksCannotRestoreStaleStatus() throws {
        let (model, sync, main) = makeModel()
        let callback = try XCTUnwrap(sync.observers.values.first)
        var older = SyncReport()
        older.enabled = true
        older.offline = true
        sync.send(older)
        var latest = SyncReport()
        latest.enabled = true
        latest.phase = .resyncing
        sync.send(latest)
        main.flush()
        main.flush()
        var notifications = 0
        model.onChange = { notifications += 1 }
        callback(older)
        callback(older)
        main.flush()
        main.flush()
        XCTAssertEqual(model.state.footer, .resyncing)
        XCTAssertEqual(notifications, 0)
    }

    func testIndependentObserversAndViewHookSurviveOtherSubscriberRemoval() {
        let (model, sync, main) = makeModel()
        var first = 0
        var second = 0
        var hook = 0
        let removed = model.addObserver { _ in first += 1 }
        let remaining = model.addObserver { _ in XCTAssertTrue(main.isUI); second += 1 }
        model.onChange = { XCTAssertTrue(main.isUI); hook += 1 }
        var report = SyncReport()
        report.enabled = true
        sync.send(report)
        main.flush()
        model.removeObserver(removed)
        main.flush()
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
        XCTAssertEqual(hook, 1)
        model.removeObserver(remaining)
        model.showErrorDetails()
        main.flush()
        main.flush()
        XCTAssertEqual(second, 1)
        XCTAssertEqual(hook, 2)
        XCTAssertEqual(sync.observers.count, 1)
    }

    func testRetirementAndDeinitRemoveServiceObserverAndFenceQueuedWork() throws {
        let main = SyncPresentationMain()
        let sync = StatusPresentationFake()
        var model: SyncStatusModel? = SyncStatusModel(sync: sync, mainThread: main)
        let callback = try XCTUnwrap(sync.observers.values.first)
        var notifications = 0
        model?.onChange = { notifications += 1 }
        model?.addObserver { _ in notifications += 1 }
        var report = SyncReport()
        report.enabled = true
        sync.send(report)
        model?.syncNow()
        model?.retire()
        callback(report)
        main.flush()
        main.flush()
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(sync.syncRequests, 0)
        XCTAssertTrue(sync.observers.isEmpty)
        XCTAssertEqual(sync.removed.count, 1)
        model = nil
        XCTAssertEqual(sync.removed.count, 1)
        model = SyncStatusModel(sync: sync, mainThread: main)
        weak var released = model
        model = nil
        main.flush()
        XCTAssertNil(released)
        XCTAssertTrue(sync.observers.isEmpty)
        XCTAssertEqual(sync.removed.count, 2)
    }

    func testActualSyncServiceReportObserverIsRemoved() throws {
        let rig = try SyncServiceRig(queuedUI: true)
        var model: SyncStatusModel? = SyncStatusModel(sync: rig.service, mainThread: rig.main)
        var changes = 0
        model?.onChange = { changes += 1 }
        rig.service.requireSignIn()
        model?.retire()
        rig.main.flush()
        rig.main.flush()
        XCTAssertEqual(changes, 0)
        weak var released = model
        model = nil
        XCTAssertNil(released)
    }

    private func makeModel() -> (SyncStatusModel, StatusPresentationFake, SyncPresentationMain) {
        let main = SyncPresentationMain()
        let sync = StatusPresentationFake()
        let model = SyncStatusModel(sync: sync, mainThread: main)
        main.flush()
        return (model, sync, main)
    }
}

private final class StatusPresentationFake: SyncStatusProviding {
    var report = SyncReport()
    private(set) var observers: [UUID: (SyncReport) -> Void] = [:]
    private(set) var removed: [UUID] = []
    private(set) var syncRequests = 0
    var onSync: (() -> Void)?

    func observe(_ observer: @escaping (SyncReport) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(report)
        return id
    }
    func removeObserver(_ id: UUID) { removed.append(id); observers[id] = nil }
    func syncNow() { syncRequests += 1; onSync?() }
    func send(_ report: SyncReport) {
        self.report = report
        Array(observers.values).forEach { $0(report) }
    }
}
