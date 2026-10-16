import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncPushEngineTests: XCTestCase {
    private let id = SyncScanTestSupport.id
    private let personal = SyncScanTestSupport.personal
    private let team = SyncScanTestSupport.team

    func testPushMetadataIODoesNotGrowWithUnrelatedLibraryFiles() async throws {
        var stateReads: [Int] = []
        var retainedInventories: [Int] = []
        for count in [0, 32] {
            let rig = try fixture()
            let change = try candidate(rig)
            for index in 0..<count {
                try rig.files.write(Data("Unrelated \(index)".utf8), at: "other-\(index).md")
            }
            let engine = try engine(rig, PushTransport { _ in try Self.ack(1) })
            var reads = 0
            rig.data.onRead = { if $0 == "sync/state.json" { reads += 1 } }
            let inventories = rig.data.listCount
            let result = try await engine.push(change, availability: .available)
            XCTAssertEqual(result, .acknowledged)
            stateReads.append(reads)
            retainedInventories.append(rig.data.listCount - inventories)
        }
        XCTAssertEqual(stateReads.first, stateReads.last, "State reads must not grow per file")
        XCTAssertEqual(retainedInventories.first, retainedInventories.last, "Retained inventories must not grow per file")
    }

    func testCreateRereadsDiskAndJournalsExactFreshBytesBeforeHTTP() async throws {
        let rig = try fixture()
        let change = try candidate(rig)
        let fresh = SyncScanTestSupport.bytes("Saved after scan\r\n", extra: "# verbatim\n")
        try rig.files.write(fresh, at: "a.md")
        let transport = PushTransport { request in
            let put = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self, from: XCTUnwrap(request.body))
            XCTAssertEqual(put.baseRev, 0)
            XCTAssertEqual(Data(put.content.utf8), fresh)
            let pending = try JSONDecoder().decode(SyncPendingOperation.self, from: rig.data.read(at: "sync/push.json"))
            XCTAssertEqual(pending.intent.sentBytes, fresh)
            XCTAssertEqual(pending.intent.sentHash, SyncHash(bytes: fresh))
            XCTAssertEqual(pending.intent.path, "a.md")
            XCTAssertEqual(pending.intent.scope, SyncScanTestSupport.personal)
            XCTAssertTrue(rig.data.isPrivate(at: "sync/push.json"))
            XCTAssertTrue(rig.dataOperations.flushedFiles.contains("sync/push.json"))
            XCTAssertTrue(rig.dataOperations.flushedDirectories.contains(nil))
            return try Self.ack(1)
        }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .acknowledged)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.canonicalHash, SyncHash(bytes: fresh))
        XCTAssertNil(try rig.data.stamp(at: "sync/push.json"))
    }

    func testUpdateAcknowledgesSentBytesAndLeavesInFlightEditDirty() async throws {
        let rig = try fixture(rev: 3)
        let sent = SyncScanTestSupport.bytes("Before request")
        let newer = SyncScanTestSupport.bytes("During request")
        try rig.files.write(sent, at: "a.md")
        let change = try candidate(rig)
        let transport = PushTransport { request in
            let put = try Self.put(request)
            XCTAssertEqual(put.baseRev, 3)
            XCTAssertEqual(Data(put.content.utf8), sent)
            try rig.files.write(newer, at: "a.md")
            return try Self.ack(4)
        }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .acknowledged)
        XCTAssertEqual(try rig.files.read(at: "a.md"), newer)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.canonicalHash, SyncHash(bytes: sent))
        guard case .update = try candidate(rig) else { return XCTFail("The newer saved bytes must remain dirty") }
    }

    func testCreateAndUpdateLostAcknowledgementsSurviveRestartWithoutCopies() async throws {
        for revision: Int64 in [0, 3] {
            let rig = try fixture(rev: revision)
            let sent = SyncScanTestSupport.bytes("Sent")
            let fresh = SyncScanTestSupport.bytes("Saved after losing acknowledgement")
            try rig.files.write(sent, at: "a.md")
            let change = try candidate(rig)
            let failing = PushTransport { _ in throw HTTPTransportError.networkFailure }
            await assertHTTPFailure {
                try await self.engine(rig, failing).push(change, availability: .available)
            }
            try rig.files.write(fresh, at: "a.md")
            let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
            let transport = PushTransport { request in
                XCTAssertEqual(request.method, .get)
                return try Self.http(Self.prompt(sent, rev: revision + 1))
            }
            let result = try await engine(restarted, transport).resume(availability: .available)
            XCTAssertEqual(result, .acknowledged)
            XCTAssertEqual(restarted.states.snapshot.value?.prompts[.assigned(id)]?.rev, revision + 1)
            XCTAssertEqual(restarted.states.snapshot.value?.prompts[.assigned(id)]?.canonicalHash, SyncHash(bytes: sent))
            XCTAssertEqual(try restarted.files.read(at: "a.md"), fresh)
            XCTAssertEqual(try restarted.files.listFiles().count, 1)
            XCTAssertNil(try restarted.data.stamp(at: "sync/push.json"))
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testIdenticalConflictHeadAcknowledgesExactSentVersion() async throws {
        let rig = try fixture(rev: 3)
        let sent = SyncScanTestSupport.bytes("Sent")
        let fresh = SyncScanTestSupport.bytes("Newer")
        try rig.files.write(sent, at: "a.md")
        let change = try candidate(rig)
        let transport = PushTransport { _ in
            try rig.files.write(fresh, at: "a.md")
            return try Self.conflict(sent, rev: 4)
        }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .acknowledged)
        XCTAssertEqual(try rig.files.listFiles().count, 1)
        XCTAssertEqual(try rig.files.read(at: "a.md"), fresh)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.canonicalHash, SyncHash(bytes: sent))
    }

    func testNewerLocalBytesMatchingHeadDoNotProveSentSuccess() async throws {
        let rig = try fixture(rev: 3)
        try rig.files.write(SyncScanTestSupport.bytes("Sent"), at: "a.md")
        let change = try candidate(rig)
        let transport = PushTransport { _ in
            let bytes = SyncScanTestSupport.bytes("Winning head")
            try rig.files.write(bytes, at: "a.md")
            return try Self.conflict(bytes, rev: 4)
        }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .replan)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.rev, 4)
    }

    func testPrivateFormattingOnlyConflictPreservesLosingLocalVersion() async throws {
        let rig = try fixture(rev: 3)
        try rig.files.write(SyncScanTestSupport.bytes(extra: "# exact sent comment\n"), at: "a.md")
        let change = try candidate(rig)
        let losing = SyncScanTestSupport.bytes(extra: "# comment saved during HTTP\n")
        let server = SyncScanTestSupport.bytes(extra: "# authoritative server comment\n")
        XCTAssertTrue(try CanonicalForm.equivalentForAdoption(losing, server, scope: .user, filename: "a.md"))
        XCTAssertNotEqual(losing, server)
        let transport = PushTransport { _ in
            try rig.files.write(losing, at: "a.md")
            return try Self.conflict(server, rev: 4)
        }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .replan)
        XCTAssertEqual(try rig.files.read(at: "a.md"), server)
        XCTAssertEqual(try rig.files.listFiles().filter { $0.relativePath.hasPrefix("Conflicts/") }.count, 1)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(SyncScanTestSupport.fresh)]?.origin, .conflictOf(id))
        let retained = try rig.data.listFiles().filter { $0.relativePath.hasSuffix(".bin") }
        XCTAssertTrue(try retained.contains { try rig.data.read(at: $0.relativePath) == losing })
    }

    func testUncommittedLostRequestIsReplannedWithFreshBytes() async throws {
        for revision: Int64 in [0, 3] {
            let rig = try fixture(rev: revision)
            let old = SyncScanTestSupport.bytes()
            try rig.files.write(SyncScanTestSupport.bytes("Uncommitted"), at: "a.md")
            let change = try candidate(rig)
            await assertHTTPFailure {
                try await self.engine(rig, PushTransport { _ in throw HTTPTransportError.networkFailure })
                    .push(change, availability: .available)
            }
            let fresh = SyncScanTestSupport.bytes("Repaired while offline")
            try rig.files.write(fresh, at: "a.md")
            let transport = PushTransport { request in
                if request.method == .get {
                    return revision == 0 ? try Self.failure(.notFound) : try Self.http(Self.prompt(old, rev: revision))
                }
                XCTAssertEqual(Data(try Self.put(request).content.utf8), fresh)
                return try Self.ack(revision + 1)
            }
            let engine = try engine(rig, transport)
            let recovered = try await engine.resume(availability: .available)
            XCTAssertEqual(recovered, .replan)
            let result = try await engine.push(change, availability: .available)
            XCTAssertEqual(result, .acknowledged)
            XCTAssertEqual(transport.requests.map(\.method), [.get, .put])
        }
    }

    func testDelete404And410AreSuccessAndPreserveRecreatedFiles() async throws {
        for deleted in [false, true] {
            let rig = try fixture(rev: 3)
            try rig.files.delete(at: "a.md")
            let change = try candidate(rig)
            let recreated = SyncScanTestSupport.bytes("Recreated in flight")
            let transport = PushTransport { request in
                XCTAssertEqual(request.method, .delete)
                XCTAssertEqual(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems,
                               [URLQueryItem(name: "base_rev", value: "3")])
                try rig.files.write(recreated, at: "a.md")
                return try deleted ? Self.http(SyncAPI.ErrorResponse.deleted, status: 410) : Self.failure(.notFound)
            }
            let result = try await engine(rig, transport).push(change, availability: .available)
            XCTAssertEqual(result, .acknowledged)
            XCTAssertNil(rig.states.snapshot.value?.prompts[.assigned(id)])
            XCTAssertEqual(try rig.files.read(at: "a.md"), recreated)
            XCTAssertTrue(rig.libraryOperations.trashed.isEmpty)
        }
    }

    func testDeleteRechecksLiveIdentityAcrossPathsAndDoesNotDeleteMovedFile() async throws {
        let rig = try fixture(rev: 3)
        try rig.files.delete(at: "a.md")
        let change = try candidate(rig)
        try rig.files.write(SyncScanTestSupport.bytes(), at: "renamed.md")
        let transport = PushTransport { _ in XCTFail("No deletion may be sent"); return try Self.ack(4) }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .replan)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testDeleteConflictRestoresWinningServerEdit() async throws {
        let rig = try fixture(rev: 3)
        try rig.files.delete(at: "a.md")
        let change = try candidate(rig)
        let bytes = SyncScanTestSupport.bytes("Server edit")
        let transport = PushTransport { _ in try Self.conflict(bytes, rev: 4) }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .replan)
        XCTAssertEqual(try rig.files.read(at: "a.md"), bytes)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.rev, 4)
    }

    func testMoveCanonicalizesKnownServerBaseThenRereadsAndPutsAtMovedRevision() async throws {
        let base = SyncScanTestSupport.bytes(extra: "favorite: true\nprivate: true\n")
        let rig = try fixture(rev: 3, base: base, groups: true)
        let edit = SyncScanTestSupport.bytes("First saved edit", extra: "favorite: true\nprivate: true\n")
        let newer = SyncScanTestSupport.bytes("Changed during move", extra: "favorite: false\nprivate: true\n")
        try rig.files.move(from: "a.md", to: "Groups/Team/a.md")
        try rig.files.write(edit, at: "Groups/Team/a.md")
        let change = try candidate(rig)
        let movedBase = try CanonicalForm.group(base, filename: "a.md").bytes
        let sentEdit = try CanonicalForm.group(newer, filename: "a.md").bytes
        let transport = PushTransport { request in
            if request.method == .post {
                let move = try JSONDecoder().decode(SyncAPI.MovePromptRequest.self, from: XCTUnwrap(request.body))
                XCTAssertEqual(move.baseRev, 3)
                XCTAssertEqual(move.scope, .group(groupID: SyncTestValues.group.rawValue))
                let pending = try JSONDecoder().decode(SyncPendingOperation.self, from: rig.data.read(at: "sync/push.json"))
                XCTAssertEqual(pending.intent.sentBytes, movedBase)
                XCTAssertNotEqual(pending.intent.sentBytes, edit)
                try rig.files.write(newer, at: "Groups/Team/a.md")
                return try Self.ack(4)
            }
            XCTAssertEqual(request.method, .put)
            let record = try XCTUnwrap(rig.states.snapshot.value?.prompts[.assigned(SyncScanTestSupport.id)])
            XCTAssertEqual(record.scope, SyncScanTestSupport.team)
            XCTAssertEqual(record.rev, 4)
            XCTAssertEqual(record.canonicalHash, SyncHash(bytes: movedBase))
            let put = try Self.put(request)
            XCTAssertEqual(put.baseRev, 4)
            XCTAssertEqual(Data(put.content.utf8), sentEdit)
            return try Self.ack(5)
        }
        let result = try await engine(rig, transport).push(change, availability: .available, baseBytes: base)
        XCTAssertEqual(result, .acknowledged)
        XCTAssertEqual(transport.requests.map(\.method), [.post, .put])
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.canonicalHash, SyncHash(bytes: sentEdit))
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), sentEdit)
        XCTAssertNil(rig.states.snapshot.value?.favorites[.assigned(id)])
    }

    func testMoveOnlyEnteringGroupCanonicalizesAndLiftsFavoriteWithoutPUT() async throws {
        let base = SyncScanTestSupport.bytes(extra: "favorite: true\nprivate: false\n")
        let rig = try fixture(rev: 3, base: base, groups: true)
        try rig.files.move(from: "a.md", to: "Groups/Team/a.md")
        let change = try candidate(rig)
        let transport = PushTransport { request in XCTAssertEqual(request.method, .post); return try Self.ack(4) }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .acknowledged)
        let canonical = try CanonicalForm.group(base, filename: "a.md").bytes
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), canonical)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.canonicalHash, SyncHash(bytes: canonical))
        XCTAssertEqual(rig.states.snapshot.value?.favorites[.assigned(id)], true)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testUnknownMoveBaseIsFetchedAndStaleProvidedBaseNeverUsed() async throws {
        let rig = try fixture(rev: 3, groups: true)
        let base = SyncScanTestSupport.bytes()
        try rig.files.move(from: "a.md", to: "Groups/Team/a.md")
        try rig.files.write(SyncScanTestSupport.bytes("Local edit"), at: "Groups/Team/a.md")
        let change = try candidate(rig)
        let transport = PushTransport { request in
            if request.method == .get { return try Self.http(Self.prompt(base, rev: 3)) }
            if request.method == .post { return try Self.ack(4) }
            XCTAssertEqual(try Self.put(request).baseRev, 4)
            return try Self.ack(5)
        }
        let result = try await engine(rig, transport).push(change, availability: .available,
            baseBytes: SyncScanTestSupport.bytes("Obsolete base"))
        XCTAssertEqual(result, .acknowledged)
        XCTAssertEqual(transport.requests.map(\.method), [.get, .post, .put])
    }

    func testGroupToPrivateKnownBaseDoesNotIntroduceStrippedPersonalMetadata() async throws {
        let raw = SyncScanTestSupport.bytes(extra: "favorite: true\nprivate: true\n")
        let base = try CanonicalForm.group(raw, filename: "a.md").bytes
        let rig = try fixture(rev: 3, base: base, groups: true, scope: team)
        try rig.files.move(from: "Groups/Team/a.md", to: "a.md")
        try rig.files.write(SyncScanTestSupport.bytes("Saved private edit"), at: "a.md")
        let change = try candidate(rig)
        let transport = PushTransport { request in
            if request.method == .post {
                let pending = try JSONDecoder().decode(SyncPendingOperation.self, from: rig.data.read(at: "sync/push.json"))
                XCTAssertEqual(pending.intent.sentBytes, base)
                return try Self.ack(4)
            }
            XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(SyncScanTestSupport.id)]?.canonicalHash, SyncHash(bytes: base))
            XCTAssertEqual(try Self.put(request).baseRev, 4)
            return try Self.ack(5)
        }
        _ = try await engine(rig, transport).push(change, availability: .available, baseBytes: raw)
    }

    func testMoveCommittedWhenPutFailsAndOldCandidateUsesNewRevision() async throws {
        let rig = try fixture(rev: 3, groups: true)
        let base = SyncScanTestSupport.bytes()
        try rig.files.move(from: "a.md", to: "Groups/Team/a.md")
        try rig.files.write(SyncScanTestSupport.bytes("Edited"), at: "Groups/Team/a.md")
        let change = try candidate(rig)
        let transport = PushTransport { request in
            if request.method == .post { return try Self.ack(4) }
            XCTAssertEqual(try Self.put(request).baseRev, 4)
            return try Self.failure(.internalError)
        }
        await assertHTTPFailure {
            try await self.engine(rig, transport).push(change, availability: .available, baseBytes: base)
        }
        let moved = try XCTUnwrap(rig.states.snapshot.value?.prompts[.assigned(id)])
        XCTAssertEqual(moved.scope, team)
        XCTAssertEqual(moved.rev, 4)
        let movedBytes = try CanonicalForm.group(base, filename: "a.md").bytes
        XCTAssertEqual(moved.canonicalHash, SyncHash(bytes: movedBytes))
        let retry = PushTransport { request in
            if request.method == .get { return try Self.http(Self.prompt(movedBytes, rev: 4, scope: .group(groupID: SyncTestValues.group.rawValue))) }
            XCTAssertEqual(request.method, .put)
            XCTAssertEqual(try Self.put(request).baseRev, 4)
            return try Self.ack(5)
        }
        let engine = try engine(rig, retry)
        let recovery = try await engine.resume(availability: .available)
        XCTAssertEqual(recovery, .replan)
        let result = try await engine.push(change, availability: .available, baseBytes: base)
        XCTAssertEqual(result, .acknowledged)
        XCTAssertEqual(retry.requests.map(\.method), [.get, .put])
    }

    func testLostMoveAcknowledgementUsesMovedBaseAndKeepsAccompanyingEdit() async throws {
        let rig = try fixture(rev: 3, groups: true)
        let base = SyncScanTestSupport.bytes()
        let edit = SyncScanTestSupport.bytes("Queued edit")
        try rig.files.move(from: "a.md", to: "Groups/Team/a.md")
        try rig.files.write(edit, at: "Groups/Team/a.md")
        let change = try candidate(rig)
        await assertHTTPFailure {
            try await self.engine(rig, PushTransport { _ in throw HTTPTransportError.networkFailure })
                .push(change, availability: .available, baseBytes: base)
        }
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        let moved = try CanonicalForm.group(base, filename: "a.md").bytes
        let transport = PushTransport { request in
            if request.method == .get { return try Self.http(Self.prompt(moved, rev: 4, scope: .group(groupID: SyncTestValues.group.rawValue))) }
            XCTAssertEqual(request.method, .put)
            XCTAssertEqual(try Self.put(request).baseRev, 4)
            XCTAssertEqual(Data(try Self.put(request).content.utf8), try CanonicalForm.group(edit, filename: "a.md").bytes)
            return try Self.ack(5)
        }
        let result = try await engine(restarted, transport).resume(availability: .available)
        XCTAssertEqual(result, .acknowledged)
        XCTAssertEqual(try restarted.files.listFiles().count, 1)
        XCTAssertEqual(transport.requests.map(\.method), [.get, .put])
    }

    func testMoveConflictAdoptsActualWinningScopeAndPreservesLocalVersionPrivately() async throws {
        let rig = try fixture(rev: 3, groups: true)
        let base = SyncScanTestSupport.bytes()
        try rig.files.move(from: "a.md", to: "Groups/Team/a.md")
        let local = SyncScanTestSupport.bytes("Losing local move/edit")
        try rig.files.write(local, at: "Groups/Team/a.md")
        let change = try candidate(rig)
        let server = SyncScanTestSupport.bytes("Winning server")
        let transport = PushTransport { _ in try Self.conflict(server, rev: 4, path: "winner.md") }
        let result = try await engine(rig, transport).push(change, availability: .available, baseBytes: base)
        XCTAssertEqual(result, .replan)
        XCTAssertEqual(try rig.files.read(at: "winner.md"), server)
        XCTAssertNil(try rig.files.stamp(at: "Groups/Team/a.md"))
        let copy = try XCTUnwrap(try rig.files.listFiles().first { $0.relativePath.hasPrefix("Conflicts/") })
        XCTAssertEqual(PromptCodec.parseFile(try rig.files.read(at: copy.relativePath), filename: "Copy.md").body,
                       "Losing local move/edit")
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.scope, personal)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.path, "winner.md")
    }

    func testMovePathTakenRenamesDestinationWithoutAdoptingUnrelatedOwner() async throws {
        let rig = try fixture(rev: 3, groups: true)
        let base = SyncScanTestSupport.bytes()
        try rig.files.move(from: "a.md", to: "Groups/Team/a.md")
        try rig.files.write(SyncScanTestSupport.bytes(id: SyncScanTestSupport.other), at: "Groups/Team/a (2).md")
        let change = try candidate(rig)
        let transport = PushTransport { _ in try Self.http(SyncAPI.ErrorResponse.pathTaken(existing: .init(
            id: SyncScanTestSupport.other.rawValue, rev: 9, content: String(decoding: base, as: UTF8.self))), status: 409) }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .replan)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a (3).md"), base)
        XCTAssertNil(try rig.files.stamp(at: "Groups/Team/a.md"))
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.scope, personal)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.rev, 3)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testCreatorDeniedMoveRestoresOriginalAndRequestsMembershipRefreshWithoutViewerInference() async throws {
        let base = try CanonicalForm.group(SyncScanTestSupport.bytes(), filename: "a.md").bytes
        let rig = try fixture(rev: 3, base: base, groups: true, scope: team)
        try rig.files.move(from: "Groups/Team/a.md", to: "a.md")
        try rig.files.write(SyncScanTestSupport.bytes("Noncreator's local edit"), at: "a.md")
        let change = try candidate(rig)
        let transport = PushTransport { request in
            if request.method == .post { return try Self.failure(.forbidden) }
            return try Self.http(Self.prompt(base, rev: 3, scope: .group(groupID: SyncTestValues.group.rawValue)))
        }
        let result = try await engine(rig, transport).push(change, availability: .available, baseBytes: base)
        XCTAssertEqual(result, .refreshMemberships)
        XCTAssertEqual(rig.states.snapshot.value?.groups[SyncTestValues.group]?.role, .editor)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.lastError?.code, .forbidden)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), base)
        XCTAssertNil(try rig.files.stamp(at: "a.md"))
        XCTAssertEqual(try rig.files.listFiles().filter { $0.relativePath.hasPrefix("Conflicts/") }.count, 1)
    }

    func testDeniedCreateAndUnavailableOrMismatchedOriginalRescuePrivately() async throws {
        for revision: Int64 in [0, 3] {
            let rig = try fixture(rev: revision)
            try rig.files.write(SyncScanTestSupport.bytes("Keep this local version"), at: "a.md")
            let change = try candidate(rig)
            let transport = PushTransport { request in
                if request.method == .put { return try Self.failure(.forbidden) }
                return try Self.http(Self.prompt(SyncScanTestSupport.bytes(), rev: 3, path: "mismatched.md"))
            }
            let result = try await engine(rig, transport).push(change, availability: .available)
            XCTAssertEqual(result, .refreshMemberships)
            XCTAssertNil(try rig.files.stamp(at: "a.md"))
            XCTAssertNil(rig.states.snapshot.value?.prompts[.assigned(id)])
            let copy = try XCTUnwrap(try rig.files.listFiles().first)
            XCTAssertTrue(copy.relativePath.hasPrefix("Conflicts/"))
            XCTAssertEqual(PromptCodec.parseFile(try rig.files.read(at: copy.relativePath), filename: "Copy.md").body,
                           "Keep this local version")
            XCTAssertEqual(transport.requests.count, revision == 0 ? 1 : 2)
        }
    }

    func test422FingerprintSkipsAfterRestartAndBytesOrAccessRepairAllowsRetry() async throws {
        let rig = try fixture(rev: 3)
        try rig.files.write(SyncScanTestSupport.bytes("Rejected input"), at: "a.md")
        let change = try candidate(rig)
        let transport = PushTransport { _ in try Self.http(SyncAPI.ErrorResponse.validation(issues: [
            .init(code: "metadata.invalid_type", severity: .error)]), status: 422) }
        let result = try await engine(rig, transport).push(change, availability: .available, accessGeneration: 7)
        XCTAssertEqual(result, .skipped)
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        let retry = PushTransport { _ in try Self.ack(4) }
        let engine = try engine(restarted, retry)
        let skipped = try await engine.push(change, availability: .available, accessGeneration: 7)
        XCTAssertEqual(skipped, .skipped)
        XCTAssertTrue(retry.requests.isEmpty)
        let repaired = try await engine.push(change, availability: .available, accessGeneration: 8)
        XCTAssertEqual(repaired, .acknowledged)
        XCTAssertNil(restarted.states.snapshot.value?.prompts[.assigned(id)]?.lastError)
    }

    func testUpdate404IsPerFileErrorRatherThanDeletionSuccess() async throws {
        let rig = try fixture(rev: 3)
        try rig.files.write(SyncScanTestSupport.bytes("Edit"), at: "a.md")
        let change = try candidate(rig)
        let result = try await engine(rig, PushTransport { _ in try Self.failure(.notFound) })
            .push(change, availability: .available)
        XCTAssertEqual(result, .skipped)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.rev, 3)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.lastError?.code, .notFound)
        XCTAssertNotNil(try rig.files.stamp(at: "a.md"))
    }

    func testDeniedWriteWithFailedGetRescuesAndRefreshesInsteadOfRetrying() async throws {
        let rig = try fixture(rev: 3)
        let local = SyncScanTestSupport.bytes("Offline denied edit")
        try rig.files.write(local, at: "a.md")
        let change = try candidate(rig)
        let transport = PushTransport { request in
            if request.method == .put { return try Self.failure(.forbidden) }
            throw HTTPTransportError.networkFailure
        }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .refreshMemberships)
        XCTAssertNil(try rig.files.stamp(at: "a.md"))
        let copy = try XCTUnwrap(try rig.files.listFiles().first)
        XCTAssertEqual(PromptCodec.parseFile(try rig.files.read(at: copy.relativePath), filename: "Copy.md").body,
                       "Offline denied edit")
        XCTAssertNil(try rig.data.stamp(at: "sync/push.json"))
    }

    func testCreatePathTakenWithNewEditAndExhaustedNamesPersistsFixedError() async throws {
        let rig = try fixture()
        let change = try candidate(rig)
        for number in 2...20 {
            try rig.files.write(SyncScanTestSupport.bytes(id: SyncScanTestSupport.other), at: "a (\(number)).md")
        }
        let transport = PushTransport { _ in
            try rig.files.write(SyncScanTestSupport.bytes("Changed in flight"), at: "a.md")
            let existing = SyncScanTestSupport.bytes(id: SyncScanTestSupport.other)
            return try Self.http(SyncAPI.ErrorResponse.pathTaken(existing: .init(id: SyncScanTestSupport.other.rawValue,
                rev: 7, content: String(decoding: existing, as: UTF8.self))), status: 409)
        }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .skipped)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.lastError?.code, .pathClash)
        XCTAssertNotNil(try rig.files.stamp(at: "a.md"))
        XCTAssertNil(try rig.data.stamp(at: "sync/push.json"))
    }

    func testGroupPutInFlightPersonalChangesStayOnDiskWithOnlySentHashAcknowledged() async throws {
        let base = try CanonicalForm.group(SyncScanTestSupport.bytes(), filename: "a.md").bytes
        let rig = try fixture(rev: 3, base: base, groups: true, scope: team)
        try rig.files.write(SyncScanTestSupport.bytes("First edit"), at: "Groups/Team/a.md")
        let change = try candidate(rig)
        let fresh = SyncScanTestSupport.bytes("Second edit", extra: "favorite: true\nprivate: true\n")
        let transport = PushTransport { _ in
            try rig.files.write(fresh, at: "Groups/Team/a.md")
            return try Self.ack(4)
        }
        _ = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(try rig.files.read(at: "Groups/Team/a.md"), fresh)
        XCTAssertNotEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.canonicalHash,
                          SyncHash(bytes: try CanonicalForm.group(fresh, filename: "a.md").bytes))
        guard case .update = try candidate(rig) else { return XCTFail("The saved edit still needs a PUT") }
        XCTAssertEqual(rig.states.snapshot.value?.favorites[.assigned(id)], true)
    }

    func testPut410PreservesVersionWithFreshPrivateIdentity() async throws {
        let rig = try fixture(rev: 3)
        try rig.files.write(SyncScanTestSupport.bytes("Deleted remotely"), at: "a.md")
        let change = try candidate(rig)
        let result = try await engine(rig, PushTransport { _ in try Self.http(SyncAPI.ErrorResponse.deleted, status: 410) })
            .push(change, availability: .available)
        XCTAssertEqual(result, .replan)
        XCTAssertNil(rig.states.snapshot.value?.prompts[.assigned(id)])
        XCTAssertNotNil(rig.states.snapshot.value?.prompts[.assigned(SyncScanTestSupport.fresh)])
        XCTAssertNil(try rig.files.stamp(at: "a.md"))
    }

    func testCreatePathTakenAdoptsEquivalentExistingIdentityWithKeyedHistory() async throws {
        let rig = try fixture()
        let change = try candidate(rig)
        try rig.usage.recordUse(identity: .assigned(id))
        let server = SyncScanTestSupport.bytes(id: SyncScanTestSupport.other)
        let transport = PushTransport { _ in try Self.http(SyncAPI.ErrorResponse.pathTaken(existing: .init(
            id: SyncScanTestSupport.other.rawValue, rev: 7, content: String(decoding: server, as: UTF8.self))), status: 409) }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .acknowledged)
        XCTAssertNil(rig.states.snapshot.value?.prompts[.assigned(id)])
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(SyncScanTestSupport.other)]?.rev, 7)
        XCTAssertEqual(try rig.files.read(at: "a.md"), server)
        XCTAssertEqual(try rig.usage.useEvents(for: .assigned(SyncScanTestSupport.other)).count, 1)
    }

    func testCreatePathTakenAfterInFlightEditClashesWithoutAdoptingUnsentBytes() async throws {
        let rig = try fixture()
        let change = try candidate(rig)
        let fresh = SyncScanTestSupport.bytes("Newer unsent edit")
        let transport = PushTransport { _ in
            try rig.files.write(fresh, at: "a.md")
            let existing = SyncScanTestSupport.bytes(id: SyncScanTestSupport.other)
            return try Self.http(SyncAPI.ErrorResponse.pathTaken(existing: .init(id: SyncScanTestSupport.other.rawValue,
                rev: 7, content: String(decoding: existing, as: UTF8.self))), status: 409)
        }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .replan)
        XCTAssertEqual(try rig.files.read(at: "a (2).md"), fresh)
        XCTAssertEqual(rig.states.snapshot.value?.prompts[.assigned(id)]?.rev, 0)
        XCTAssertNil(rig.states.snapshot.value?.prompts[.assigned(SyncScanTestSupport.other)])
    }

    func testPushesAndMovePutNeverAdvancePullCursorsOrDatabaseIdentity() async throws {
        let rig = try fixture(rev: 3, groups: true)
        try rig.states.update(for: rig.binding) {
            $0.databaseID = SyncTestValues.uuid
            $0.cursors = [.user(SyncTestValues.user): "opaque old /+==", .group(SyncTestValues.group): "group cursor"]
        }
        let before = try XCTUnwrap(rig.states.snapshot.value)
        try rig.files.move(from: "a.md", to: "Groups/Team/a.md")
        try rig.files.write(SyncScanTestSupport.bytes("Edit"), at: "Groups/Team/a.md")
        let change = try candidate(rig)
        let transport = PushTransport { request in try Self.ack(request.method == .post ? 4 : 5, seq: 999_999) }
        _ = try await engine(rig, transport).push(change, availability: .available, baseBytes: SyncScanTestSupport.bytes())
        XCTAssertEqual(rig.states.snapshot.value?.databaseID, before.databaseID)
        XCTAssertEqual(rig.states.snapshot.value?.cursors, before.cursors)
    }

    func testHeldAccountFilesNeverUploadEvenWhenScanPredatesHoldOrFileWasEditedAndRenamed() async throws {
        let rig = try fixture()
        let change = try candidate(rig)
        var ownership = try SyncLibraryBinding(root: rig.binding.root, owner: rig.binding.account)
        ownership.holds = [try SyncHeldPrompt(identity: .assigned(id), path: "old.md",
            sourceAccount: SyncTestValues.account(userID: SyncTestValues.otherUser), contentHash: SyncHash(bytes: Data()))]
        try rig.files.write(SyncScanTestSupport.bytes("Edited held content"), at: "a.md")
        let transport = PushTransport { _ in XCTFail("Held content must never reach HTTP"); return try Self.ack(1) }
        let result = try await engine(rig, transport, ownership: { ownership }).push(change, availability: .available)
        XCTAssertEqual(result, .held)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(try rig.data.stamp(at: "sync/push.json"))
    }

    func testDurableRawRescueHoldSuppressesCraftedCreateCandidate() async throws {
        let rig = try fixture()
        let change = try candidate(rig)
        let file = try XCTUnwrap(rig.mutations.read(at: "a.md"))
        let malformed = try SyncLibraryFile(path: "raw.md", stamp: file.stamp, bytes: Data([0xff]))
        let rescue = try rig.mutations.rescue(malformed, at: "Conflicts/raw.md", freshID: SyncScanTestSupport.fresh)
        XCTAssertEqual(try rig.journal.apply(SyncApplyPlan(expectedState: rig.states.snapshot.value,
            nextState: XCTUnwrap(rig.states.snapshot.value), edits: [rescue])), .committed)
        // Hold is still matched by path after an external repair; repair alone is no consent.
        try rig.files.delete(at: "Conflicts/raw.md")
        try rig.files.move(from: "a.md", to: "Conflicts/raw.md")
        guard case .create(let local) = change else { return XCTFail("Create") }
        let moved = SyncLocalPrompt(file: try XCTUnwrap(rig.mutations.read(at: "Conflicts/raw.md")),
            identity: local.identity, scope: local.scope, path: "Conflicts/raw.md", canonical: local.canonical, origin: nil)
        let transport = PushTransport { _ in XCTFail("Retained hold must block HTTP"); return try Self.ack(1) }
        let result = try await engine(rig, transport).push(.create(moved), availability: .available)
        XCTAssertEqual(result, .held)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testUnsavedBufferInCandidateNeverOverridesSavedDiskBytes() async throws {
        let rig = try fixture()
        guard case .create(let local) = try candidate(rig) else { return XCTFail("Create") }
        let draft = try CanonicalForm.user(SyncScanTestSupport.bytes("Unsaved editor buffer"), filename: "a.md")
        let crafted = SyncLocalPrompt(file: local.file, identity: local.identity, scope: local.scope,
            path: local.path, canonical: draft, origin: nil)
        let transport = PushTransport { request in
            XCTAssertEqual(Data(try Self.put(request).content.utf8), SyncScanTestSupport.bytes())
            return try Self.ack(1)
        }
        _ = try await engine(rig, transport).push(.create(crafted), availability: .available)
    }

    func testEditDuringJournalFlushReplansBeforeHTTPRequest() async throws {
        let rig = try fixture()
        let change = try candidate(rig)
        let fresh = SyncScanTestSupport.bytes("Changed while journaling")
        var changed = false
        rig.dataOperations.onOperation = { operation in
            if operation == "file:sync/push.json", !changed {
                changed = true
                try? rig.files.write(fresh, at: "a.md")
            }
        }
        let transport = PushTransport { _ in XCTFail("Earlier bytes cannot be sent"); return try Self.ack(1) }
        let result = try await engine(rig, transport).push(change, availability: .available)
        XCTAssertEqual(result, .replan)
        XCTAssertTrue(changed)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(try rig.files.read(at: "a.md"), fresh)
    }

    func testFailedPushJournalDurabilitySendsNothingAndRestartReadsIntent() async throws {
        let rig = try fixture()
        let change = try candidate(rig)
        rig.dataOperations.failFlushNumber = rig.dataOperations.flushCount + 1
        let transport = PushTransport { _ in XCTFail("Undurable intent must not be sent"); return try Self.ack(1) }
        do {
            _ = try await engine(rig, transport).push(change, availability: .available)
            XCTFail("Expected durability failure")
        } catch { XCTAssertEqual(error as? SyncError, .durabilityUncertain) }
        XCTAssertTrue(transport.requests.isEmpty)
        let restarted = SyncPendingOperationStore(files: rig.data, operations: MemorySyncFileOperations(files: rig.data))
        XCTAssertEqual(try restarted.load(for: rig.binding)?.intent.baseRev, 0)
    }

    func testRecoveryReplaysAcknowledgementApplicationBeforeClearingPushJournal() async throws {
        let rig = try fixture()
        let change = try candidate(rig)
        let transport = PushTransport { _ in
            rig.data.failNextDelete = true
            return try Self.ack(1)
        }
        do {
            _ = try await engine(rig, transport).push(change, availability: .available)
            XCTFail("Expected apply journal cleanup failure")
        } catch { XCTAssertEqual(error as? SyncError, .writeFailed(.ioFailure)) }
        let restarted = try SyncApplyTestRig(files: rig.files, data: rig.data)
        let recovery = PushTransport { _ in try Self.http(Self.prompt(SyncScanTestSupport.bytes(), rev: 1)) }
        let result = try await engine(restarted, recovery).resume(availability: .available)
        XCTAssertEqual(result, .acknowledged)
        XCTAssertNil(restarted.journal.pending)
        XCTAssertNil(try rig.data.stamp(at: "sync/push.json"))
    }

    func testUnavailableLibraryAndIdentityReplacementSendNothing() async throws {
        let rig = try fixture()
        let change = try candidate(rig)
        let transport = PushTransport { _ in XCTFail("No valid candidate"); return try Self.ack(1) }
        let engine = try engine(rig, transport)
        do { _ = try await engine.push(change, availability: .unavailable); XCTFail("Unavailable") }
        catch { XCTAssertEqual(error as? SyncReconciliationError, .unavailableLibrary) }
        try rig.files.write(SyncScanTestSupport.bytes(id: SyncScanTestSupport.other), at: "a.md")
        let result = try await engine.push(change, availability: .available)
        XCTAssertEqual(result, .replan)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testPendingJournalRejectsCorruptionForeignBindingAndRedactsPayloads() async throws {
        let rig = try fixture()
        let change = try candidate(rig)
        await assertHTTPFailure {
            try await self.engine(rig, PushTransport { _ in throw HTTPTransportError.networkFailure })
                .push(change, availability: .available)
        }
        let store = SyncPendingOperationStore(files: rig.data, operations: rig.dataOperations)
        let record = try XCTUnwrap(store.load(for: rig.binding))
        XCTAssertFalse(String(describing: record).contains("Body"))
        XCTAssertFalse(String(reflecting: record).contains("Body"))
        XCTAssertThrowsError(try store.load(for: SyncTestValues.binding(userID: SyncTestValues.otherUser))) {
            XCTAssertEqual($0 as? SyncError, .bindingMismatch)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: rig.data.read(at: "sync/push.json")) as? [String: Any])
        object["sentHash"] = String(repeating: "f", count: 64)
        try rig.data.writePrivate(JSONSerialization.data(withJSONObject: object), at: "sync/push.json")
        let corrupt = SyncPendingOperationStore(files: rig.data, operations: rig.dataOperations)
        XCTAssertThrowsError(try corrupt.load(for: rig.binding)) { XCTAssertEqual($0 as? SyncError, .corruptFile) }
    }

    private func fixture(rev: Int64 = 0, base: Data = SyncScanTestSupport.bytes(), groups: Bool = false,
                         scope: SyncScopeKey = SyncScanTestSupport.personal) throws -> SyncApplyTestRig {
        let rig = try SyncApplyTestRig()
        let folders = try groups ? SyncScanTestSupport.groups() : [:]
        let path = try SyncLocalScanner.rooted("a.md", scope: scope, groups: folders)
        try rig.files.write(base, at: path.string)
        let record = rev == 0 ? try SyncPromptState(scope: scope, path: "a.md", rev: 0)
            : try SyncScanTestSupport.record(base, scope: scope, rev: rev)
        try SyncScanTestSupport.installState(rig, groups: folders, prompts: [.assigned(id): record])
        return rig
    }

    private func candidate(_ rig: SyncApplyTestRig) throws -> SyncLocalChange {
        try XCTUnwrap(SyncScanTestSupport.prepare(rig).changes.first {
            switch $0 {
            case .create(let local), .update(let local, _), .rename(let local, _), .move(let local, _):
                return local.identity == .assigned(id)
            case .delete(let identity, _): return identity == .assigned(id)
            }
        })
    }

    private func engine(_ rig: SyncApplyTestRig, _ transport: PushTransport,
                        ownership: @escaping () throws -> SyncLibraryBinding? = { nil }) throws -> SyncPushEngine {
        let server = try SyncServerURL(rig.binding.account.serverURL.absoluteString)
        let client = SyncHTTPClient(server: server, transport: transport,
            credential: SyncCredential(server: server, token: SecretValue(String(repeating: "a", count: 42) + "A")))
        return try SyncPushEngine(binding: rig.binding, client: client, states: rig.states,
            pending: SyncPendingOperationStore(files: rig.data, operations: rig.dataOperations),
            mutations: rig.mutations, journal: rig.journal, ownership: ownership, device: "Test Device",
            freshID: { SyncScanTestSupport.fresh }, now: { Date(timeIntervalSince1970: 1_791_925_200) })
    }

    private static func put(_ request: HTTPRequest) throws -> SyncAPI.PutPromptRequest {
        XCTAssertEqual(request.method, .put)
        return try JSONDecoder().decode(SyncAPI.PutPromptRequest.self, from: XCTUnwrap(request.body))
    }

    private static func prompt(_ bytes: Data, rev: Int64, scope: SyncAPI.PromptScope = .user,
                               path: String = "a.md") -> SyncAPI.Prompt {
        .init(id: SyncScanTestSupport.id.rawValue, rev: rev, scope: scope, path: path, content: String(decoding: bytes, as: UTF8.self))
    }

    private static func ack(_ rev: Int64, seq: Int64 = 100) throws -> HTTPResponse {
        try http(SyncAPI.WriteResponse(rev: rev, seq: seq))
    }

    private static func conflict(_ bytes: Data, rev: Int64, scope: SyncAPI.PromptScope = .user,
                                 path: String = "a.md") throws -> HTTPResponse {
        try http(SyncAPI.ErrorResponse.conflict(head: .init(rev: rev, scope: scope, path: path,
            content: String(decoding: bytes, as: UTF8.self))), status: 409)
    }

    private static func failure(_ code: SyncAPI.FailureCode) throws -> HTTPResponse {
        let error = SyncAPI.ErrorResponse.failure(code)
        return try http(error, status: error.httpStatus)
    }

    private static func http<T: Encodable>(_ body: T, status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: try JSONEncoder().encode(body))
    }

    private func assertHTTPFailure(_ operation: () async throws -> SyncPushResult,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected HTTP failure", file: file, line: line) }
        catch { XCTAssertNotNil(error as? SyncHTTPClientError, file: file, line: line) }
    }
}

private final class PushTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private let handler: (HTTPRequest) async throws -> HTTPResponse

    init(_ handler: @escaping (HTTPRequest) async throws -> HTTPResponse) { self.handler = handler }

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        record(request)
        return try await handler(request)
    }

    private func record(_ request: HTTPRequest) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
    }
}
