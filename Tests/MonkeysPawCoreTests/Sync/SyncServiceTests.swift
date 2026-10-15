import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncServiceTests: XCTestCase {
    func testDisabledServiceDoesNoIOOrScheduling() async throws {
        let rig = try SyncServiceRig()
        let writes = rig.base.data.writeCount
        rig.service.syncNow()
        rig.service.localSave()
        rig.scheduler.advance(.seconds(600))
        await rig.service.drain()
        XCTAssertFalse(rig.service.report.enabled)
        XCTAssertEqual(rig.service.report.status, .idle)
        XCTAssertEqual(rig.transport.requests.count, 0)
        XCTAssertEqual(rig.scheduler.timers.count, 0)
        XCTAssertEqual(rig.base.data.writeCount, writes)
    }

    func testPullAdoptsBeforeScanAndPushesOnlyUnmatchedFiles() async throws {
        let rig = try SyncServiceRig()
        let remote = SyncScanTestSupport.bytes("Copied", id: SyncTestValues.personalPrompt)
        try rig.base.files.write(SyncScanTestSupport.bytes("Copied", id: nil), at: "a.md")
        try rig.base.files.write(SyncScanTestSupport.bytes("New", id: nil), at: "b.md")
        rig.transport.handler = { _, request in
            if request.method == .post { return try SyncServiceRig.pull(items: [.upsert(seq: 1,
                prompt: .init(id: SyncTestValues.personalPrompt.rawValue, rev: 1, path: "a.md",
                    content: String(decoding: remote, as: UTF8.self)))]) }
            let put = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self, from: XCTUnwrap(request.body))
            XCTAssertEqual(put.path, "b.md")
            XCTAssertEqual(put.baseRev, 0)
            return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: 2, seq: 2))
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.map(\.method), [.post, .put])
        XCTAssertEqual(try rig.base.files.read(at: "a.md"), remote)
        XCTAssertEqual(rig.service.report.status, .idle)
        XCTAssertNotNil(rig.service.report.lastSuccess)
        XCTAssertEqual(rig.service.report.counts.pushed, 1)
        XCTAssertEqual(rig.base.states.snapshot.value?.cursors[SyncScanTestSupport.personal], "cursor")
    }

    func testViewerGroupPullIsFiniteAndKeepsReadOnlyMode() async throws {
        let rig = try SyncServiceRig()
        let bytes = try CanonicalForm.group(SyncScanTestSupport.bytes("Team", id: SyncTestValues.groupPrompt), filename: "a.md").bytes
        let group = SyncAPI.SyncScope(identity: .group(groupID: SyncTestValues.group.rawValue, name: "Team", role: .viewer),
            mode: .snapshot, head: 1, cursor: "group", hasMore: false,
            items: [.upsert(seq: 1, prompt: .init(id: SyncTestValues.groupPrompt.rawValue, rev: 1, path: "a.md",
                content: String(decoding: bytes, as: UTF8.self)))])
        rig.transport.handler = { _, _ in try SyncServiceRig.pull(groups: [group]) }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 1)
        XCTAssertEqual(try rig.base.files.read(at: "Groups/Team/a.md"), bytes)
        XCTAssertEqual(rig.base.libraryOperations.modes["Groups/Team/a.md"], .readOnly)
        XCTAssertEqual(rig.service.report.status, .idle)
    }

    func testRemovedGroupInstallsAccessibleMoveBeforeRescue() async throws {
        let rig = try SyncServiceRig()
        let bytes = SyncScanTestSupport.bytes("Moved", id: SyncTestValues.groupPrompt)
        let canonical = try CanonicalForm.group(bytes, filename: "a.md").bytes
        try rig.base.files.write(canonical, at: "Groups/Team/a.md")
        let state = try SyncState(binding: rig.base.binding, databaseID: SyncTestValues.uuid,
            cursors: [SyncScanTestSupport.personal: "old", SyncScanTestSupport.team: "group-old"],
            groups: SyncScanTestSupport.groups(), prompts: [.assigned(SyncTestValues.groupPrompt):
                SyncPromptState(scope: SyncScanTestSupport.team, path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: canonical))])
        try rig.base.states.update(for: rig.base.binding) { $0 = state }
        let owned = try SyncLibraryBinding(root: rig.base.binding.root, owner: rig.base.binding.account,
            managedFolders: [SyncTestValues.group: SyncManagedFolder(owner: rig.base.binding.account, folder: "Team")])
        try rig.accounts.updateBinding(for: rig.base.binding.root) { _ in owned }
        rig.transport.handler = { _, _ in try SyncServiceRig.pull(items: [.upsert(seq: 2,
            prompt: .init(id: SyncTestValues.groupPrompt.rawValue, rev: 2, path: "moved.md",
                content: String(decoding: bytes, as: UTF8.self)))], mode: .delta, removed: [SyncScanTestSupport.team.rawValue]) }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.service.report.status, .idle)
        XCTAssertEqual(try rig.base.files.read(at: "moved.md"), bytes)
        XCTAssertNil(try rig.base.files.stamp(at: "Groups/Team/a.md"))
        XCTAssertEqual(try rig.base.files.listFiles().count, 1)
        XCTAssertEqual(rig.base.states.snapshot.value?.prompts[.assigned(SyncTestValues.groupPrompt)]?.scope, SyncScanTestSupport.personal)
        XCTAssertNil(rig.base.states.snapshot.value?.groups[SyncTestValues.group])
        XCTAssertEqual(rig.service.report.counts.conflicts, 0)
    }

    func testStopAtEveryPhasePreventsLaterMutations() async throws {
        for phase in [SyncPhase.recovering, .collecting, .resyncing, .reconciling, .scanning, .groupFolders, .pushing] {
            let rig = try SyncServiceRig()
            if phase == .collecting {
                let state = try SyncState(binding: rig.base.binding, databaseID: SyncTestValues.uuid,
                    cursors: [SyncScanTestSupport.personal: "before"])
                try rig.base.states.update(for: rig.base.binding) { $0 = state }
            }
            try rig.base.files.write(SyncScanTestSupport.bytes("Local", id: nil), at: "a.md")
            let probe = SyncStopProbe()
            let observer = rig.service.observe { report in
                if report.enabled && report.phase == phase && probe.once() {
                    probe.result = rig.service.stop()
                    probe.libraryWrites = rig.base.files.writeCount
                    probe.stateBytes = try? rig.base.data.read(at: "sync/state.json")
                }
            }
            try rig.start()
            await rig.settle()
            XCTAssertTrue(probe.fired, "Did not reach \(phase)")
            XCTAssertEqual(rig.base.files.writeCount, probe.libraryWrites, "Late write after \(phase)")
            XCTAssertEqual(try? rig.base.data.read(at: "sync/state.json"), probe.stateBytes)
            XCTAssertFalse(rig.service.report.enabled)
            XCTAssertNil(rig.service.report.lastSuccess)
            rig.service.removeObserver(observer)
        }
    }

    func testRetiredPullReplyCannotWriteFilesStateOrQueuedUI() async throws {
        let rig = try SyncServiceRig(queuedUI: true)
        let gate = SyncTransportGate()
        rig.transport.handler = { _, _ in
            await gate.wait()
            return try SyncServiceRig.pull(items: [.upsert(seq: 1, prompt: .init(id: SyncTestValues.personalPrompt.rawValue,
                rev: 1, path: "a.md", content: String(decoding: SyncScanTestSupport.bytes(), as: UTF8.self)))])
        }
        let reports = SyncReportProbe()
        _ = rig.service.observe { reports.append($0) }
        try rig.start()
        await rig.waitRequests(1)
        XCTAssertEqual(rig.service.retire(), .busy)
        let writes = rig.base.data.writeCount
        await gate.open()
        await rig.settle()
        rig.main.flush()
        XCTAssertEqual(rig.base.files.writeCount, 0)
        XCTAssertEqual(rig.base.data.writeCount, writes)
        XCTAssertEqual(reports.values.count, 1)
        XCTAssertFalse(reports.values[0].enabled)
        XCTAssertEqual(rig.service.retire(), .stopped)
    }

    func testRootLostDuringPushRetainsIntentAndResumeUsesExactSentFacts() async throws {
        let rig = try SyncServiceRig()
        try rig.base.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        let gate = SyncTransportGate()
        rig.transport.handler = { _, request in
            if request.method == .post { return try SyncServiceRig.pull() }
            await gate.wait()
            return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: 1, seq: 1))
        }
        try rig.start()
        await rig.waitRequests(2)
        XCTAssertEqual(rig.service.rootHealthChanged(.unavailable), .busy)
        let state = rig.base.states.snapshot.value
        let writes = rig.base.data.writeCount
        await gate.open()
        await rig.settle()
        XCTAssertEqual(rig.base.states.snapshot.value, state)
        XCTAssertEqual(rig.base.data.writeCount, writes)
        XCTAssertNotNil(try rig.pending.load(for: rig.base.binding))
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertEqual(rig.service.report.blockingIssue, .rootUnavailable)
        let sent = SyncScanTestSupport.bytes()
        rig.transport.handler = { _, request in
            if request.method == .get { return try SyncServiceRig.http(SyncAPI.Prompt(id: SyncTestValues.personalPrompt.rawValue,
                rev: 1, scope: .user, path: "a.md", content: String(decoding: sent, as: UTF8.self))) }
            XCTAssertEqual(request.method, .post)
            return try SyncServiceRig.pull(mode: .delta)
        }
        _ = rig.service.rootHealthChanged(.available)
        await rig.settle()
        XCTAssertNil(try rig.pending.load(for: rig.base.binding))
        XCTAssertEqual(rig.base.states.snapshot.value?.prompts[.assigned(SyncTestValues.personalPrompt)]?.rev, 1)
        XCTAssertEqual(rig.transport.requests.filter { $0.method == .put }.count, 1)
    }

    func testBusyMutationDrainsDurablyBeforeReplacement() async throws {
        let rig = try SyncServiceRig()
        let probe = SyncStopProbe()
        rig.base.dataOperations.onOperation = { operation in
            if operation == "file:sync/apply.json", probe.once() { probe.result = rig.service.retire() }
        }
        try rig.start()
        await rig.settle()
        XCTAssertTrue(probe.fired)
        XCTAssertEqual(probe.result, .busy)
        XCTAssertNil(rig.journal.pending)
        XCTAssertFalse(rig.service.report.enabled)
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertEqual(rig.service.retire(), .stopped)
    }

    func testOwnWritesAreSuppressedIndividuallyAndExternalChangesDebounce() async throws {
        let rig = try SyncServiceRig()
        rig.transport.handler = { _, _ in try SyncServiceRig.pull(items: [.upsert(seq: 1,
            prompt: .init(id: SyncTestValues.personalPrompt.rawValue, rev: 1, path: "a.md",
                content: String(decoding: SyncScanTestSupport.bytes(), as: UTF8.self)))]) }
        try rig.start()
        await rig.settle()
        let file = try XCTUnwrap(rig.base.mutations.read(at: "a.md"))
        let own = SyncFileChange(path: "a.md", stamp: file.stamp, hash: file.hash.rawValue)
        rig.service.filesChanged([own])
        rig.scheduler.advance(.seconds(3))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 1)
        // A stale watcher event still matching the receipt cannot suppress a
        // subsequent external incarnation with identical bytes.
        try rig.base.files.write(file.bytes, at: "a.md")
        rig.service.filesChanged([own])
        rig.scheduler.advance(.seconds(3))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
        XCTAssertEqual(rig.transport.requests.filter { $0.method == .put }.count, 0)
    }

    func testProtocolFailureNeverAdvancesCursorOrSuccess() async throws {
        let rig = try SyncServiceRig()
        rig.transport.handler = { _, _ in HTTPResponse(statusCode: 200, body: Data("{}".utf8)) }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.service.report.status, .syncError)
        XCTAssertEqual(rig.service.report.blockingIssue, .invalidProtocol)
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertNil(rig.base.states.snapshot.value)
        rig.service.syncNow()
        rig.scheduler.advance(.seconds(600))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 1)
    }

    func testStatusPrecedence() {
        var report = SyncReport()
        XCTAssertEqual(report.status, .idle)
        report.counts.conflicts = 1
        XCTAssertEqual(report.status, .hasConflicts)
        report.counts.fileErrors = 1
        XCTAssertEqual(report.status, .syncError)
        report.offline = true
        XCTAssertEqual(report.status, .offline)
        report.phase = .resyncing
        XCTAssertEqual(report.status, .syncing)
        report.blockingIssue = .recoveryRequired
        XCTAssertEqual(report.status, .syncError)
        report.needsSignIn = true
        XCTAssertEqual(report.status, .needsSignIn)
    }

    func testUnreadableJournalRequiresRecoveryWithoutPendingSnapshots() throws {
        let rig = try SyncServiceRig()
        try rig.base.data.put("corrupt", at: "sync/apply.json")
        XCTAssertThrowsError(try rig.journal.replay()) { XCTAssertEqual($0 as? SyncError, .corruptFile) }
        XCTAssertTrue(rig.base.mutations.hasUnreadableJournal)
        XCTAssertNil(rig.base.mutations.pendingPermit)
        XCTAssertNil(rig.journal.pending)
        XCTAssertNil(rig.pending.snapshot.value)
        XCTAssertNil(rig.pending.snapshot.error)

        XCTAssertEqual(rig.service.stop(), .recoveryRequired)
        XCTAssertEqual(rig.service.rootHealthChanged(.available), .recoveryRequired)
        XCTAssertEqual(rig.service.retire(), .recoveryRequired)
    }

    func testStoppedPendingPushRequiresRecoveryBeforeRetirement() async throws {
        let rig = try SyncServiceRig()
        try rig.base.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        let gate = SyncTransportGate()
        rig.transport.handler = { _, request in
            if request.method == .post { return try SyncServiceRig.pull() }
            await gate.wait()
            return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: 1, seq: 1))
        }
        try rig.start()
        await rig.waitRequests(2)
        XCTAssertEqual(rig.service.stop(), .busy)
        await gate.open()
        await rig.settle()
        XCTAssertEqual(rig.service.retire(), .recoveryRequired)
        rig.transport.handler = { _, request in
            XCTAssertEqual(request.method, .get)
            return try SyncServiceRig.http(SyncAPI.Prompt(id: SyncTestValues.personalPrompt.rawValue,
                rev: 1, scope: .user, path: "a.md", content: String(decoding: SyncScanTestSupport.bytes(), as: UTF8.self)))
        }
        try await rig.service.recoverJournal()
        XCTAssertEqual(rig.service.retire(), .stopped)
        XCTAssertFalse(rig.service.report.enabled)
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertNil(try rig.pending.load(for: rig.base.binding))
        XCTAssertEqual(rig.transport.requests.count, 3)
    }

    func testStaleRecordedGroupFileRequestsSnapshotAndNeverDeletesServerHead() async throws {
        let rig = try SyncServiceRig()
        let bytes = SyncScanTestSupport.bytes()
        try rig.base.files.write(bytes, at: "Groups/Old/a.md")
        let old = try SyncState(binding: rig.base.binding, databaseID: SyncTestValues.uuid,
            cursors: [SyncScanTestSupport.personal: "old"], prompts: [.assigned(SyncTestValues.personalPrompt):
                SyncPromptState(scope: SyncScanTestSupport.personal, path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: bytes))])
        try rig.base.states.update(for: rig.base.binding) { $0 = old }
        let owned = try SyncLibraryBinding(root: rig.base.binding.root, owner: rig.base.binding.account)
        try rig.accounts.updateBinding(for: rig.base.binding.root) { _ in owned }
        rig.transport.handler = { index, request in
            if request.method == .post {
                let pull = try JSONDecoder().decode(SyncAPI.PullRequest.self, from: XCTUnwrap(request.body))
                if index == 0 { return try SyncServiceRig.pull(mode: .delta) }
                XCTAssertEqual(pull.cursors[SyncScanTestSupport.personal.rawValue], "0")
                return try SyncServiceRig.pull(items: [.upsert(seq: 1,
                    prompt: .init(id: SyncTestValues.personalPrompt.rawValue, rev: 1, path: "a.md",
                        content: String(decoding: bytes, as: UTF8.self)))])
            }
            XCTAssertEqual(request.method, .put)
            return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: 1, seq: 2))
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(try rig.base.files.read(at: "a.md"), bytes)
        XCTAssertNil(try rig.base.files.stamp(at: "Groups/Old/a.md"))
        XCTAssertEqual(try rig.base.files.listFiles().count, 2)
        XCTAssertFalse(rig.transport.requests.contains { $0.method == .delete })
        XCTAssertEqual(rig.service.report.status, .hasConflicts)
    }

    func testWritablePathClashPreservesIDAndKeyedState() async throws {
        let rig = try SyncServiceRig()
        let local = SyncScanTestSupport.bytes("Occupant", id: SyncTestValues.groupPrompt)
        try rig.base.files.write(local, at: "a.md")
        try rig.base.values.record(identity: .assigned(SyncTestValues.groupPrompt), values: ["field": "value"])
        let remote = SyncScanTestSupport.bytes("Remote")
        rig.transport.handler = { _, request in
            if request.method == .post { return try SyncServiceRig.pull(items: [.upsert(seq: 1,
                prompt: .init(id: SyncTestValues.personalPrompt.rawValue, rev: 1, path: "a.md",
                    content: String(decoding: remote, as: UTF8.self)))]) }
            return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: 1, seq: 2))
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.service.report.status, .idle)
        XCTAssertEqual(try rig.base.files.read(at: "a.md"), remote)
        XCTAssertEqual(try rig.base.files.read(at: "a (2).md"), local)
        XCTAssertEqual(try rig.base.values.rememberedValues(for: .assigned(SyncTestValues.groupPrompt)), ["field": "value"])
    }

    func testInterruptedApplyResumesStableChoicesBeforeNewPull() async throws {
        let base = try SyncApplyTestRig()
        let accountStore = SyncAccountStore(files: base.data, operations: base.dataOperations)
        let journal = try SyncApplyJournal(files: base.data, operations: base.dataOperations,
            mutations: base.mutations, states: base.states, accounts: accountStore)
        let bytes = SyncScanTestSupport.bytes()
        let edit = try base.mutations.publication(bytes, at: "a.md", expecting: nil,
            transition: SyncIdentityTransition(from: nil, to: .assigned(SyncTestValues.personalPrompt)))
        let state = try SyncState(binding: base.binding, databaseID: SyncTestValues.uuid,
            cursors: [SyncScanTestSupport.personal: "before"], prompts: [.assigned(SyncTestValues.personalPrompt):
                SyncPromptState(scope: SyncScanTestSupport.personal, path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: bytes))])
        base.libraryOperations.failMode = true
        XCTAssertThrowsError(try journal.apply(SyncApplyPlan(expectedState: nil, nextState: state, edits: [edit])))
        let operation = try XCTUnwrap(journal.pending).id
        base.libraryOperations.failMode = false
        let rig = try SyncServiceRig(base: base)
        rig.transport.handler = { _, request in
            XCTAssertEqual(try base.files.read(at: "a.md"), bytes)
            XCTAssertNil(rig.journal.pending)
            let pull = try JSONDecoder().decode(SyncAPI.PullRequest.self, from: XCTUnwrap(request.body))
            XCTAssertEqual(pull.cursors[SyncScanTestSupport.personal.rawValue], "before")
            return try SyncServiceRig.pull(mode: .delta)
        }
        try rig.start()
        await rig.settle()
        XCTAssertNil(rig.journal.pending)
        XCTAssertEqual(try base.files.read(at: "a.md"), bytes)
        XCTAssertNotNil(rig.service.report.lastSuccess)
        XCTAssertNil(try base.data.stamp(at: "sync/retained/" + operation.uuidString.lowercased() + "-journal.json"))
    }

    func testFailedPushDoesNotReportPriorPullAsSuccess() async throws {
        let rig = try SyncServiceRig()
        try rig.base.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        rig.transport.handler = { _, request in
            if request.method == .post { return try SyncServiceRig.pull() }
            throw HTTPTransportError.networkFailure
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.service.report.status, .offline)
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertEqual(rig.base.states.snapshot.value?.databaseID, SyncTestValues.uuid)
        XCTAssertNotNil(try rig.pending.load(for: rig.base.binding))
    }

    func testUnavailableRootCannotInferDeletionsOrResumeAnApply() async throws {
        let rig = try SyncServiceRig()
        let record = try SyncPromptState(scope: SyncScanTestSupport.personal, path: "missing.md", rev: 1,
            canonicalHash: SyncHash(bytes: SyncScanTestSupport.bytes()))
        let state = try SyncState(binding: rig.base.binding, databaseID: SyncTestValues.uuid,
            cursors: [SyncScanTestSupport.personal: "before"], prompts: [.assigned(SyncTestValues.personalPrompt): record])
        try rig.base.states.update(for: rig.base.binding) { $0 = state }
        _ = rig.service.rootHealthChanged(.unavailable)
        let reads = rig.base.files.accessCount
        let writes = rig.base.data.writeCount
        try rig.start()
        rig.service.syncNow()
        rig.scheduler.advance(.seconds(600))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 0)
        XCTAssertEqual(rig.base.files.accessCount, reads)
        XCTAssertEqual(rig.base.data.writeCount, writes)
        XCTAssertEqual(rig.base.states.snapshot.value, state)
        XCTAssertEqual(rig.service.report.blockingIssue, .rootUnavailable)
    }

    func testRootRecoveryWhileOldReplyIsInFlightStartsOnlyAfterItDrains() async throws {
        let rig = try SyncServiceRig()
        let gate = SyncTransportGate()
        rig.transport.handler = { index, _ in
            if index == 0 {
                await gate.wait()
                return try SyncServiceRig.failure(.unauthorized)
            }
            return try SyncServiceRig.pull()
        }
        try rig.start()
        await rig.waitRequests(1)
        XCTAssertEqual(rig.service.rootHealthChanged(.unavailable), .busy)
        XCTAssertEqual(rig.service.rootHealthChanged(.available), .busy)
        XCTAssertEqual(rig.transport.requests.count, 1)
        await gate.open()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
        XCTAssertEqual(rig.service.report.status, .idle)
        XCTAssertFalse(rig.service.report.needsSignIn)
        XCTAssertNotNil(rig.service.report.lastSuccess)
    }

    func testMixedWatcherBatchAndOldEpochReceiptRemainEligible() async throws {
        let rig = try SyncServiceRig()
        rig.transport.handler = { _, _ in try SyncServiceRig.pull(items: [.upsert(seq: 1,
            prompt: .init(id: SyncTestValues.personalPrompt.rawValue, rev: 1, path: "a.md",
                content: String(decoding: SyncScanTestSupport.bytes(), as: UTF8.self)))]) }
        try rig.start()
        await rig.settle()
        let file = try XCTUnwrap(rig.base.mutations.read(at: "a.md"))
        let own = SyncFileChange(path: "a.md", stamp: file.stamp, hash: file.hash.rawValue)
        rig.service.filesChanged([own, SyncFileChange(path: "external.md", stamp: nil, hash: nil)])
        rig.scheduler.advance(.seconds(3))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
        XCTAssertEqual(rig.service.stop(), .stopped)
        try rig.start()
        await rig.settle()
        rig.service.filesChanged([own])
        rig.scheduler.advance(.seconds(3))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 4)
    }

    func testPartialPassRetainsCountsButNeverReportsSuccess() async throws {
        let rig = try SyncServiceRig()
        try rig.base.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        try rig.base.files.write(SyncScanTestSupport.bytes("Second", id: SyncTestValues.groupPrompt), at: "b.md")
        rig.transport.handler = { index, request in
            if request.method == .post { return try SyncServiceRig.pull() }
            if index == 1 { return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: 1, seq: 1)) }
            throw HTTPTransportError.networkFailure
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.service.report.counts.pushed, 1)
        XCTAssertEqual(rig.service.report.status, .offline)
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertEqual(rig.base.states.snapshot.value?.prompts[.assigned(SyncTestValues.personalPrompt)]?.rev, 1)
        XCTAssertEqual(rig.base.states.snapshot.value?.prompts[.assigned(SyncTestValues.groupPrompt)]?.rev, 0)
    }

    func testVisibilityErrorsAreRecordedWithoutAcknowledgingOrLooping() async throws {
        let rig = try SyncServiceRig()
        rig.transport.handler = { _, _ in try SyncServiceRig.pull(items: [.upsert(seq: 1,
            prompt: .init(id: SyncTestValues.personalPrompt.rawValue, rev: 1, path: "README.md",
                content: String(decoding: SyncScanTestSupport.bytes(), as: UTF8.self)))]) }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.service.report.status, .syncError)
        XCTAssertEqual(rig.service.report.details.first?.code, "sync.local_visibility")
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertNil(rig.base.states.snapshot.value?.databaseID)
        XCTAssertEqual(rig.base.files.writeCount, 0)
        rig.scheduler.advance(.seconds(60))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
        XCTAssertNil(rig.service.report.blockingIssue)
    }

    func testRemovedObserverReceivesNoQueuedCallbacks() async throws {
        let rig = try SyncServiceRig(queuedUI: true)
        let reports = SyncReportProbe()
        let id = rig.service.observe { reports.append($0) }
        try rig.start()
        await rig.settle()
        rig.service.removeObserver(id)
        rig.main.flush()
        XCTAssertTrue(reports.values.isEmpty)
    }

    func testGroupFavoriteIngestAndRemodingCauseNoRepeatedPush() async throws {
        let rig = try SyncServiceRig()
        let input = SyncScanTestSupport.bytes("Team", id: SyncTestValues.groupPrompt, extra: "favorite: true\n")
        let canonical = try CanonicalForm.group(input, filename: "a.md").bytes
        try rig.base.files.write(input, at: "Groups/Team/a.md")
        let state = try SyncState(binding: rig.base.binding, databaseID: SyncTestValues.uuid,
            cursors: [SyncScanTestSupport.personal: "old", SyncScanTestSupport.team: "team-old"],
            groups: SyncScanTestSupport.groups(role: .viewer), prompts: [.assigned(SyncTestValues.groupPrompt):
                SyncPromptState(scope: SyncScanTestSupport.team, path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: canonical))])
        try rig.base.states.update(for: rig.base.binding) { $0 = state }
        let owned = try SyncLibraryBinding(root: rig.base.binding.root, owner: rig.base.binding.account,
            managedFolders: [SyncTestValues.group: SyncManagedFolder(owner: rig.base.binding.account, folder: "Team")])
        try rig.accounts.updateBinding(for: rig.base.binding.root) { _ in owned }
        let group = SyncAPI.SyncScope(identity: .group(groupID: SyncTestValues.group.rawValue, name: "Team", role: .viewer),
            mode: .snapshot, head: 1, cursor: "team-current", hasMore: false,
            items: [.upsert(seq: 1, prompt: .init(id: SyncTestValues.groupPrompt.rawValue, rev: 1, path: "a.md",
                content: String(decoding: canonical, as: UTF8.self)))])
        rig.transport.handler = { _, request in
            XCTAssertEqual(request.method, .post)
            return try SyncServiceRig.pull(groups: [group])
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.base.states.snapshot.value?.favorites[.assigned(SyncTestValues.groupPrompt)], true)
        XCTAssertEqual(try rig.base.files.read(at: "Groups/Team/a.md"), canonical)
        let file = try XCTUnwrap(rig.base.mutations.read(at: "Groups/Team/a.md"))
        rig.service.filesChanged([SyncFileChange(path: "Groups/Team/a.md", stamp: file.stamp, hash: file.hash.rawValue)])
        rig.scheduler.advance(.seconds(3))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 1)
        rig.scheduler.advance(.seconds(57))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
        XCTAssertEqual(rig.service.report.status, .idle)
        XCTAssertEqual(rig.base.libraryOperations.modes["Groups/Team/a.md"], .readOnly)
    }

    func testCaseInsensitiveAdoptionPublishesExactSpellingAndMigratesLocalKey() async throws {
        let rig = try SyncServiceRig(base: SyncApplyTestRig(files: MemoryFileStore(pathMatching: .caseInsensitive)))
        let local = SyncScanTestSupport.bytes("Copied", id: nil)
        let remote = SyncScanTestSupport.bytes("Copied")
        try rig.base.files.write(local, at: "a.md")
        let key = PromptIdentity(path: "a.md", id: nil)
        try rig.base.values.record(identity: key, values: ["name": "kept"])
        rig.transport.handler = { _, request in
            XCTAssertEqual(request.method, .post)
            return try SyncServiceRig.pull(items: [.upsert(seq: 1,
                prompt: .init(id: SyncTestValues.personalPrompt.rawValue, rev: 1, path: "A.md",
                    content: String(decoding: remote, as: UTF8.self)))])
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.service.report.status, .idle)
        XCTAssertEqual(try rig.base.files.listFiles().map(\.relativePath), ["A.md"])
        XCTAssertEqual(try rig.base.files.read(at: "A.md"), remote)
        XCTAssertEqual(try rig.base.values.rememberedValues(for: .assigned(SyncTestValues.personalPrompt)), ["name": "kept"])
    }

    func testPushConflictRelocatesOccupiedHeadBeforeResumingExactIntent() async throws {
        let rig = try SyncServiceRig()
        let baseline = SyncScanTestSupport.bytes("Baseline")
        let losing = SyncScanTestSupport.bytes("Saved")
        let winner = SyncScanTestSupport.bytes("Winning head")
        let occupant = SyncScanTestSupport.bytes("Other", id: SyncTestValues.groupPrompt)
        try rig.base.files.write(losing, at: "a.md")
        try rig.base.files.write(occupant, at: "b.md")
        let old = try SyncState(binding: rig.base.binding, databaseID: SyncTestValues.uuid,
            cursors: [SyncScanTestSupport.personal: "old"], prompts: [.assigned(SyncTestValues.personalPrompt):
                SyncPromptState(scope: SyncScanTestSupport.personal, path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: baseline))])
        try rig.base.states.update(for: rig.base.binding) { $0 = old }
        rig.transport.handler = { _, request in
            if request.method == .post { return try SyncServiceRig.pull(mode: .delta) }
            if request.method == .get { return try SyncServiceRig.http(SyncAPI.Prompt(id: SyncTestValues.personalPrompt.rawValue,
                rev: 2, scope: .user, path: "b.md", content: String(decoding: winner, as: UTF8.self))) }
            if request.url.path.hasSuffix(SyncTestValues.personalPrompt.rawValue) {
                return HTTPResponse(statusCode: 409, body: try JSONEncoder().encode(SyncAPI.ErrorResponse.conflict(
                    head: .init(rev: 2, scope: .user, path: "b.md", content: String(decoding: winner, as: UTF8.self)))))
            }
            return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: 1, seq: 10))
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(try rig.base.files.read(at: "b.md"), winner)
        XCTAssertEqual(try rig.base.files.read(at: "b (2).md"), occupant)
        XCTAssertNil(try rig.base.files.stamp(at: "a.md"))
        XCTAssertEqual(rig.base.states.snapshot.value?.prompts[.assigned(SyncTestValues.personalPrompt)]?.rev, 2)
        XCTAssertNil(try rig.pending.load(for: rig.base.binding))
        XCTAssertEqual(rig.service.report.status, .hasConflicts)
        XCTAssertNotNil(rig.service.report.lastSuccess)
    }

    func testPendingConflictAllocatesNewHeadGroupBeforeCollectingAgain() async throws {
        let rig = try SyncServiceRig()
        let baseline = SyncScanTestSupport.bytes("Baseline")
        let winning = try CanonicalForm.group(SyncScanTestSupport.bytes("Moved head"), filename: "a.md").bytes
        try rig.base.files.write(SyncScanTestSupport.bytes("Saved"), at: "a.md")
        let old = try SyncState(binding: rig.base.binding, databaseID: SyncTestValues.uuid,
            cursors: [SyncScanTestSupport.personal: "before"], prompts: [.assigned(SyncTestValues.personalPrompt):
                SyncPromptState(scope: SyncScanTestSupport.personal, path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: baseline))])
        try rig.base.states.update(for: rig.base.binding) { $0 = old }
        let scope: SyncAPI.PromptScope = .group(groupID: SyncTestValues.group.rawValue)
        rig.transport.handler = { _, request in
            if request.url.path.hasSuffix("/me") {
                XCTAssertNotNil(try rig.pending.load(for: rig.base.binding))
                return try SyncServiceRig.http(SyncAPI.MeResponse(user: .init(id: SyncTestValues.user.rawValue,
                    username: "alice", displayName: nil, accountKind: .member,
                    createdAt: "2026-10-14T00:00:00.000Z", disabledAt: nil),
                    groups: [.init(groupID: SyncTestValues.group.rawValue, name: "Team", role: .editor)], devices: []))
            }
            if request.method == .post {
                let group: [SyncAPI.SyncScope]
                if rig.base.states.snapshot.value?.groups[SyncTestValues.group] == nil { group = [] }
                else {
                    XCTAssertNil(try rig.pending.load(for: rig.base.binding))
                    group = [.init(identity: .group(groupID: SyncTestValues.group.rawValue, name: "Team", role: .editor),
                        mode: .snapshot, head: 2, cursor: "group", hasMore: false,
                        items: [.upsert(seq: 2, prompt: .init(id: SyncTestValues.personalPrompt.rawValue, rev: 2, path: "a.md",
                            content: String(decoding: winning, as: UTF8.self)))])]
                }
                return try SyncServiceRig.pull(mode: .delta, groups: group)
            }
            if request.method == .get { return try SyncServiceRig.http(SyncAPI.Prompt(id: SyncTestValues.personalPrompt.rawValue,
                rev: 2, scope: scope, path: "a.md", content: String(decoding: winning, as: UTF8.self))) }
            if request.url.path.hasSuffix(SyncTestValues.personalPrompt.rawValue) {
                return HTTPResponse(statusCode: 409, body: try JSONEncoder().encode(SyncAPI.ErrorResponse.conflict(
                    head: .init(rev: 2, scope: scope, path: "a.md", content: String(decoding: winning, as: UTF8.self)))))
            }
            return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: 1, seq: 10))
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(try rig.base.files.read(at: "Groups/Team/a.md"), winning)
        XCTAssertEqual(rig.base.states.snapshot.value?.prompts[.assigned(SyncTestValues.personalPrompt)]?.scope, SyncScanTestSupport.team)
        XCTAssertNil(try rig.pending.load(for: rig.base.binding))
        XCTAssertEqual(rig.transport.requests.filter { $0.url.path.hasSuffix("/me") }.count, 1)
        XCTAssertEqual(rig.service.report.status, .hasConflicts)
    }

    func testExternalEditDuringStateCommitIsNeverRecordedAsOwnWrite() async throws {
        let rig = try SyncServiceRig()
        let server = SyncScanTestSupport.bytes("Server")
        let external = SyncScanTestSupport.bytes("External")
        let probe = SyncStopProbe()
        rig.base.data.onWrite = { path in
            if path == "sync/state.json", (try? rig.base.files.stamp(at: "a.md")) != nil, probe.once() {
                do { try rig.base.files.write(external, at: "a.md") }
                catch { XCTFail("External fixture write failed") }
            }
        }
        rig.transport.handler = { index, request in
            if request.method == .post {
                return index == 0 ? try SyncServiceRig.pull(items: [.upsert(seq: 1,
                    prompt: .init(id: SyncTestValues.personalPrompt.rawValue, rev: 1, path: "a.md",
                        content: String(decoding: server, as: UTF8.self)))]) : try SyncServiceRig.pull(mode: .delta)
            }
            return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: 2, seq: 2))
        }
        try rig.start()
        await rig.settle()
        XCTAssertTrue(probe.fired)
        let actual = try XCTUnwrap(rig.base.mutations.read(at: "a.md"))
        XCTAssertEqual(actual.bytes, external)
        let requests = rig.transport.requests.count
        rig.service.filesChanged([SyncFileChange(path: "a.md", stamp: actual.stamp, hash: actual.hash.rawValue)])
        rig.scheduler.advance(.seconds(3))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, requests + 1)
    }

    func testExhaustedIncomingClashRemainsRepairableWithoutCursorCommit() async throws {
        let rig = try SyncServiceRig()
        try rig.base.files.write(SyncScanTestSupport.bytes("Occupant", id: SyncTestValues.groupPrompt), at: "a.md")
        for number in 2...20 { try rig.base.files.write(SyncScanTestSupport.bytes("Other", id: nil), at: "a (\(number)).md") }
        rig.transport.handler = { _, request in
            XCTAssertEqual(request.method, .post)
            return try SyncServiceRig.pull(items: [.upsert(seq: 1,
                prompt: .init(id: SyncTestValues.personalPrompt.rawValue, rev: 1, path: "a.md",
                    content: String(decoding: SyncScanTestSupport.bytes(), as: UTF8.self)))])
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.service.report.status, .syncError)
        XCTAssertNil(rig.service.report.blockingIssue)
        XCTAssertEqual(rig.service.report.details.first?.code, "sync.path_clash")
        XCTAssertNil(rig.base.states.snapshot.value?.databaseID)
        rig.service.syncNow()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
        XCTAssertNil(rig.service.report.lastSuccess)
    }

    func testPartialPassRetainsFileErrorDetails() async throws {
        let rig = try SyncServiceRig()
        try rig.base.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        try rig.base.files.write(SyncScanTestSupport.bytes("Second", id: SyncTestValues.groupPrompt), at: "b.md")
        rig.transport.handler = { index, request in
            if request.method == .post { return try SyncServiceRig.pull() }
            if index == 1 { return try SyncServiceRig.failure(.notFound) }
            throw HTTPTransportError.networkFailure
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.service.report.status, .offline)
        XCTAssertEqual(rig.service.report.counts.fileErrors, 1)
        XCTAssertEqual(rig.service.report.details.first?.path, "a.md")
        XCTAssertEqual(rig.service.report.details.first?.code, "not_found")
        XCTAssertNil(rig.service.report.lastSuccess)
    }

    func testMalformedIncomingOccupantIsHeldRawBeforeServerPublication() async throws {
        let rig = try SyncServiceRig()
        let raw = Data([0xff, 0x00, 0xfe])
        let server = SyncScanTestSupport.bytes("Server")
        try rig.base.files.write(raw, at: "a.md")
        rig.transport.handler = { _, request in
            XCTAssertEqual(request.method, .post)
            return try SyncServiceRig.pull(items: [.upsert(seq: 1,
                prompt: .init(id: SyncTestValues.personalPrompt.rawValue, rev: 1, path: "a.md",
                    content: String(decoding: server, as: UTF8.self)))])
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(try rig.base.files.read(at: "a.md"), server)
        let copies = try rig.base.files.listFiles().filter { $0.relativePath.hasPrefix("Conflicts/") }
        XCTAssertEqual(copies.count, 1)
        let copy = try XCTUnwrap(copies.first)
        XCTAssertEqual(try rig.base.files.read(at: copy.relativePath), raw)
        XCTAssertEqual(rig.service.report.status, .syncError)
        XCTAssertEqual(rig.service.report.counts.held, 1)
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertEqual(rig.transport.requests.count, 1)
    }

    func testRootRecoveryDuringInlinePublicationUsesAdmittedEpoch() async throws {
        let rig = try SyncServiceRig()
        let probe = SyncStopProbe()
        _ = rig.service.observe { report in
            if report.enabled && report.phase == .recovering && probe.once() {
                _ = rig.service.rootHealthChanged(.unavailable)
                _ = rig.service.rootHealthChanged(.available)
            }
        }
        try rig.start()
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 1)
        XCTAssertNotNil(rig.service.report.lastSuccess)
        rig.scheduler.advance(.seconds(60))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.count, 2)
    }

    func testReusedOwnDeletionPathCannotSuppressLaterUserDeletion() async throws {
        let rig = try SyncServiceRig()
        let bytes = SyncScanTestSupport.bytes()
        try rig.base.files.write(bytes, at: "a.md")
        let old = try SyncState(binding: rig.base.binding, databaseID: SyncTestValues.uuid,
            cursors: [SyncScanTestSupport.personal: "before"], prompts: [.assigned(SyncTestValues.personalPrompt):
                SyncPromptState(scope: SyncScanTestSupport.personal, path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: bytes))])
        try rig.base.states.update(for: rig.base.binding) { $0 = old }
        rig.transport.handler = { index, request in
            if request.method == .post {
                return try SyncServiceRig.pull(items: index == 0 ? [.delete(seq: 2, id: SyncTestValues.personalPrompt.rawValue)] : [], mode: .delta)
            }
            return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: request.method == .delete ? 2 : 1, seq: 4))
        }
        try rig.start()
        await rig.settle()
        XCTAssertNil(try rig.base.files.stamp(at: "a.md"))
        try rig.base.files.write(SyncScanTestSupport.bytes("New identity", id: SyncTestValues.groupPrompt), at: "a.md")
        rig.service.localSave()
        rig.scheduler.advance(.seconds(3))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.filter { $0.method == .put }.count, 1)
        try rig.base.files.delete(at: "a.md")
        rig.service.filesChanged([SyncFileChange(path: "a.md", stamp: nil, hash: nil)])
        rig.scheduler.advance(.seconds(3))
        await rig.settle()
        XCTAssertEqual(rig.transport.requests.filter { $0.method == .delete }.count, 1)
        XCTAssertNil(rig.base.states.snapshot.value?.prompts[.assigned(SyncTestValues.groupPrompt)])
    }

    func testHeldPendingIntentIsRetainedPrivatelyWithoutBlockingOtherFiles() async throws {
        let rig = try SyncServiceRig()
        try rig.base.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        try rig.base.files.write(SyncScanTestSupport.bytes("Other", id: SyncTestValues.groupPrompt), at: "b.md")
        rig.transport.handler = { _, request in
            if request.method == .post { return try SyncServiceRig.pull() }
            throw HTTPTransportError.networkFailure
        }
        try rig.start()
        await rig.settle()
        let original = try XCTUnwrap(rig.pending.load(for: rig.base.binding))
        _ = rig.service.stop()
        try holdFirstFile(rig)
        rig.transport.handler = { _, request in
            if request.method == .post { return try SyncServiceRig.pull(mode: .delta) }
            XCTAssertTrue(request.url.path.hasSuffix(SyncTestValues.groupPrompt.rawValue))
            return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: 1, seq: 2))
        }
        try rig.start()
        await rig.settle()
        XCTAssertNil(rig.service.report.blockingIssue)
        XCTAssertNil(try rig.pending.load(for: rig.base.binding))
        XCTAssertEqual(rig.base.states.snapshot.value?.prompts[.assigned(SyncTestValues.groupPrompt)]?.rev, 1)
        XCTAssertEqual(try rig.base.files.read(at: "a.md"), original.file?.bytes)
        let archive = try XCTUnwrap(rig.base.data.listFiles().first { $0.relativePath.hasPrefix("sync/retained/push-") })
        let retained = try JSONDecoder().decode(SyncPendingOperation.self, from: rig.base.data.read(at: archive.relativePath))
        XCTAssertEqual(retained.intent.sentBytes, original.intent.sentBytes)
        XCTAssertEqual(retained.intent.fingerprint, original.intent.fingerprint)
        XCTAssertTrue(rig.base.data.isPrivate(at: archive.relativePath))
        XCTAssertTrue(rig.base.dataOperations.flushedFiles.contains(RelativePath(archive.relativePath)))
        XCTAssertEqual(rig.service.retire(), .stopped)
    }

    func testFailedHeldIntentRetentionKeepsActiveIntentAndCanRecover() async throws {
        let rig = try SyncServiceRig()
        try rig.base.files.write(SyncScanTestSupport.bytes(), at: "a.md")
        rig.transport.handler = { _, request in
            if request.method == .post { return try SyncServiceRig.pull() }
            throw HTTPTransportError.networkFailure
        }
        try rig.start()
        await rig.settle()
        _ = rig.service.stop()
        try holdFirstFile(rig)
        rig.base.dataOperations.failFlushNumber = rig.base.dataOperations.flushCount + 1
        let requests = rig.transport.requests.count
        try rig.start()
        await rig.settle()
        XCTAssertNotNil(try rig.pending.load(for: rig.base.binding))
        XCTAssertNotNil(rig.service.report.blockingIssue)
        XCTAssertNil(rig.service.report.lastSuccess)
        XCTAssertEqual(rig.transport.requests.count, requests)
        rig.base.dataOperations.failFlushNumber = nil
        _ = rig.service.stop()
        try await rig.service.recoverJournal()
        XCTAssertNil(try rig.pending.load(for: rig.base.binding))
        XCTAssertEqual(rig.service.retire(), .stopped)
    }

    private func holdFirstFile(_ rig: SyncServiceRig) throws {
        let hash = try XCTUnwrap(rig.base.mutations.read(at: "a.md")).hash
        try rig.accounts.updateBinding(for: rig.base.binding.root) { current in
            var next = try XCTUnwrap(current)
            next.holds.append(try SyncHeldPrompt(identity: .assigned(SyncTestValues.personalPrompt), path: "a.md",
                sourceAccount: rig.base.binding.account, contentHash: hash))
            return next
        }
    }

    func testAcknowledgedAdoptionOccupantUsesLocalPreparation() async throws {
        let rig = try SyncServiceRig()
        let local = SyncScanTestSupport.bytes("Equivalent", id: SyncTestValues.groupPrompt)
        let server = SyncScanTestSupport.bytes("Equivalent")
        try rig.base.files.write(local, at: "a.md")
        let old = try SyncState(binding: rig.base.binding, prompts: [.assigned(SyncTestValues.groupPrompt):
            SyncPromptState(scope: SyncScanTestSupport.personal, path: "a.md", rev: 1, canonicalHash: SyncHash(bytes: local))])
        try rig.base.states.update(for: rig.base.binding) { $0 = old }
        rig.transport.handler = { _, request in
            XCTAssertEqual(request.method, .post)
            return try SyncServiceRig.pull(items: [
                .upsert(seq: 2, prompt: .init(id: SyncTestValues.personalPrompt.rawValue, rev: 1, path: "a.md",
                    content: String(decoding: server, as: UTF8.self))),
                .upsert(seq: 2, prompt: .init(id: SyncTestValues.groupPrompt.rawValue, rev: 2, path: "other.md",
                    content: String(decoding: local, as: UTF8.self)))])
        }
        try rig.start()
        await rig.settle()
        XCTAssertNil(rig.service.report.blockingIssue)
        XCTAssertEqual(rig.service.report.status, .idle)
        XCTAssertEqual(try rig.base.files.read(at: "a.md"), server)
        XCTAssertEqual(try rig.base.files.read(at: "other.md"), local)
        XCTAssertNotNil(rig.service.report.lastSuccess)
    }
}

final class SyncServiceRig {
    let base: SyncApplyTestRig
    let accounts: SyncAccountStore
    let journal: SyncApplyJournal
    let pending: SyncPendingOperationStore
    let clock = SyncTestClock()
    let scheduler: SyncTestScheduler
    let main: SyncTestMainThread
    let transport = SyncTestTransport()
    let service: SyncService

    init(base: SyncApplyTestRig? = nil, queuedUI: Bool = false) throws {
        let base = try base ?? SyncApplyTestRig()
        self.base = base
        accounts = SyncAccountStore(files: base.data, operations: base.dataOperations)
        journal = try SyncApplyJournal(files: base.data, operations: base.dataOperations,
            mutations: base.mutations, states: base.states, accounts: accounts)
        pending = SyncPendingOperationStore(files: base.data, operations: base.dataOperations)
        scheduler = SyncTestScheduler(clock: clock)
        main = SyncTestMainThread(queued: queuedUI)
        var sequence: UInt64 = 100
        service = SyncService(files: base.data, states: base.states, accounts: accounts, mutations: base.mutations,
            journal: journal, pending: pending, scheduler: scheduler, mainThread: main, clock: clock,
            freshID: {
                sequence += 1
                return try ULID.generate(at: Date(timeIntervalSince1970: 1),
                    entropy: [0, 0] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) })
            }, now: clock.instant)
        transport.handler = { _, request in
            if request.method == .post { return try Self.pull() }
            return try Self.http(SyncAPI.WriteResponse(rev: 1, seq: 1))
        }
    }

    func start() throws {
        let server = try SyncServerURL(base.binding.account.serverURL.absoluteString)
        let credential = SyncCredential(server: server, token: SecretValue(String(repeating: "a", count: 42) + "A"))
        try service.start(binding: base.binding, client: SyncHTTPClient(server: server, transport: transport, credential: credential), device: "Desktop")
    }

    func settle(file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            await service.drain()
            if service.report.phase == .idle { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Pass did not settle", file: file, line: line)
    }

    func waitRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if transport.requests.count >= count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Expected \(count) requests", file: file, line: line)
    }

    static func pull(items: [SyncAPI.FeedItem] = [], mode: SyncAPI.Mode = .snapshot,
                     groups: [SyncAPI.SyncScope] = [], removed: [String] = [], more: Bool = false,
                     cursor: String = "cursor", database: UUID = SyncTestValues.uuid) throws -> HTTPResponse {
        let scope = SyncAPI.SyncScope(identity: .user(userID: SyncTestValues.user.rawValue), mode: mode,
            head: max(1, items.map(\.seq).max() ?? 1), cursor: cursor, hasMore: more, items: items)
        return try http(SyncAPI.PullResponse(databaseID: database.uuidString.lowercased(), scopes: [scope] + groups, removed: removed))
    }

    static func http<Value: Encodable>(_ value: Value) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value))
    }

    static func failure(_ code: SyncAPI.FailureCode) throws -> HTTPResponse {
        let error = SyncAPI.ErrorResponse.failure(code)
        return HTTPResponse(statusCode: error.httpStatus, body: try JSONEncoder().encode(error))
    }
}

final class SyncTestClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    private var date = Date(timeIntervalSince1970: 1_797_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func instant() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        current = current.advanced(by: duration)
        date.addTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
}

final class SyncTestScheduler: Scheduler {
    struct Timer { let id: Int; let deadline: ContinuousClock.Instant; let delay: Duration; let fire: () -> Void }
    let clock: SyncTestClock
    private let lock = NSLock()
    private var entries: [Timer] = []
    private var fired = Set<Int>()
    init(clock: SyncTestClock) { self.clock = clock }
    var timers: [Timer] { lock.lock(); defer { lock.unlock() }; return entries }
    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Timer(id: entries.count, deadline: clock.instant().advanced(by: delay), delay: delay, fire: work))
    }
    func advance(_ delay: Duration) {
        clock.advance(delay)
        while true {
            lock.lock()
            let next = entries.filter { $0.deadline <= clock.instant() && !fired.contains($0.id) }
                .min { $0.deadline == $1.deadline ? $0.id < $1.id : $0.deadline < $1.deadline }
            lock.unlock()
            guard let next else { return }
            fire(next.id)
        }
    }
    func fire(_ id: Int) {
        lock.lock()
        let timer = entries[id]
        let first = fired.insert(id).inserted
        lock.unlock()
        if first { timer.fire() }
    }
}

final class SyncTestTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    var handler: (Int, HTTPRequest) async throws -> HTTPResponse = { _, _ in throw HTTPTransportError.networkFailure }
    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let index = record(request)
        return try await handler(index, request)
    }
    private func record(_ request: HTTPRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        let index = recorded.count
        recorded.append(request)
        return index
    }
}

actor SyncTransportGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !opened { await withCheckedContinuation { waiter = $0 } } }
    func open() { opened = true; waiter?.resume(); waiter = nil }
}

final class SyncTestMainThread: MainThread {
    private let queued: Bool
    private let lock = NSLock()
    private var work: [() -> Void] = []
    init(queued: Bool) { self.queued = queued }
    func run(_ body: @escaping () -> Void) {
        if !queued { body(); return }
        lock.lock(); work.append(body); lock.unlock()
    }
    func flush() {
        lock.lock(); let pending = work; work.removeAll(); lock.unlock()
        pending.forEach { $0() }
    }
}

final class SyncStopProbe {
    var fired = false
    var result: SyncStopResult?
    var libraryWrites = 0
    var stateBytes: Data?
    func once() -> Bool { if fired { return false }; fired = true; return true }
}

final class SyncReportProbe {
    private let lock = NSLock()
    private var reports: [SyncReport] = []
    var values: [SyncReport] { lock.lock(); defer { lock.unlock() }; return reports }
    func append(_ report: SyncReport) { lock.lock(); reports.append(report); lock.unlock() }
}
