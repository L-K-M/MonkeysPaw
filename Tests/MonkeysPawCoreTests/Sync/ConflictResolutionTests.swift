import Foundation
import XCTest
@testable import MonkeysPawCore

final class ConflictResolutionTests: XCTestCase {
    func testRescuedPromptOffersOnlyKeepBothWithoutInventingAnOriginal() async throws {
        let h = try await ConflictTestRig.make()
        let rescued = try SyncConflictMetadata.settingOrigin(.rescued, in: h.copyBytes, filename: "copy.md")
        try h.rig.base.files.write(rescued, at: h.path)
        let requests = h.rig.transport.requests.count
        let preview = try await h.service.preview(h.selection)
        XCTAssertNil(preview.originalID)
        XCTAssertNil(preview.serverBytes)
        XCTAssertFalse(preview.canKeepServer)
        XCTAssertFalse(preview.canKeepMine)
        XCTAssertEqual(h.rig.transport.requests.count, requests)
        _ = try await h.service.resolve(.keepBoth, preview: preview)
        XCTAssertNil(try SyncConflictMetadata.origin(in: h.rig.base.files.read(at: h.path), filename: "copy.md"))
    }

    func testChangedCopyAndClosedViewSurviveLateSuccessfulAcknowledgement() async throws {
        for close in [false, true] {
            let h = try await ConflictTestRig.make()
            let preview = try await h.service.preview(h.selection)
            let newer = h.copyBytes + Data("New edit".utf8)
            h.beforePut = {
                if close { preview.validity.invalidate() }
                else { try h.rig.base.files.write(newer, at: h.path) }
            }
            do { _ = try await h.service.resolve(.keepMine, preview: preview); XCTFail("Late ack discarded a changed session") }
            catch { XCTAssertEqual(error as? ConflictResolutionFailure, close ? .staleSession : .staleCopy) }
            XCTAssertEqual(h.serverBytes, preview.candidateBytes)
            XCTAssertEqual(try h.rig.base.files.read(at: h.path), close ? h.copyBytes : newer)
            XCTAssertEqual(try h.rig.base.files.listFiles().count, 2)
        }
    }

    func testCommittedAccessGenerationInvalidatesAPreviewBeforeAnyHTTP() async throws {
        let h = try await ConflictTestRig.make(group: true)
        let access = try GroupAccessService(library: h.rig.base.library, states: h.rig.base.states,
            accounts: h.rig.accounts, libraryRoot: h.rig.base.binding.root.path)
        let preview = try await h.service.preview(h.selection)
        let requests = h.rig.transport.requests.count
        try h.rig.base.states.update(for: h.rig.base.binding) { state in
            state.groups = try SyncScanTestSupport.groups(role: .viewer)
        }
        XCTAssertNotEqual(access.snapshot.generation, preview.accessGeneration)
        do { _ = try await h.service.resolve(.keepMine, preview: preview); XCTFail("Stale policy authorized a write") }
        catch { XCTAssertEqual(error as? ConflictResolutionFailure, .staleAccess) }
        XCTAssertEqual(h.rig.transport.requests.count, requests)
        XCTAssertEqual(try h.rig.base.files.read(at: h.path), h.copyBytes)
    }

    func testPreviewShowsExactValidatedCandidateWithOriginalIdentityAndNoMarkers() async throws {
        for group in [false, true] {
            let h = try await ConflictTestRig.make(group: group)
            let preview = try await h.service.preview(h.selection)
            let bytes = try XCTUnwrap(preview.candidateBytes)
            let document = PromptCodec.parseFile(bytes, filename: "original.md")
            XCTAssertEqual(document.frontMatter.id, h.original)
            XCTAssertEqual(Data(document.body.utf8), Data("Mine Cafe\u{301}\r\n{{new}}".utf8))
            XCTAssertNil(try SyncConflictMetadata.origin(in: document))
            XCTAssertTrue(preview.canKeepMine)
            let diff = try XCTUnwrap(preview.diff)
            let rendered = (diff.frontMatter + diff.body).filter { $0.kind != .removed }.reduce(Data()) { $0 + $1.bytes }
            XCTAssertEqual(rendered, bytes)
            if group {
                XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("favorite:"))
                XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private:"))
                XCTAssertEqual(try CanonicalForm.group(bytes, filename: "original.md").bytes, bytes)
            } else {
                XCTAssertTrue(document.frontMatter.favorite)
                XCTAssertTrue(document.frontMatter.isPrivate)
            }
        }
    }

    func testKeepMineSendsExactlyThePreviewAndRetainsDurableSentFacts() async throws {
        let h = try await ConflictTestRig.make()
        let preview = try await h.service.preview(h.selection)
        let expected = try XCTUnwrap(preview.candidateBytes)
        let result = try await h.service.resolve(.keepMine, preview: preview)
        guard case .resolved(.keepMine) = result else { return XCTFail("Resolution did not finish") }
        XCTAssertEqual(h.serverBytes, expected)
        XCTAssertEqual(h.revision, 2)
        XCTAssertNil(try h.rig.base.files.stamp(at: h.path))
        XCTAssertEqual(h.rig.base.libraryOperations.trashed[RelativePath(h.path)], h.copyBytes)
        XCTAssertNotNil(h.rig.base.states.snapshot.value?.prompts[.assigned(h.copyID)], "Personal DELETE remains pending")
        let retained = try h.rig.base.data.listFiles().filter { $0.relativePath.hasPrefix("sync/retained/resolution-") }
        XCTAssertEqual(retained.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: h.rig.base.data.read(at: retained[0].relativePath)) as? [String: Any])
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(object["candidateBytes"] as? String)), expected)
        XCTAssertEqual(object["baseRev"] as? Int, 1)
        XCTAssertEqual(try h.rig.base.files.read(at: h.originalPath), h.initialServerBytes, "Pull owns original installation")
    }

    func testChangedHeadRefreshesDiffWithoutSendingOrDiscardingCopy() async throws {
        let h = try await ConflictTestRig.make()
        let preview = try await h.service.preview(h.selection)
        h.revision = 2
        h.serverBytes = SyncScanTestSupport.bytes("Newest\n", id: h.original)
        let result = try await h.service.resolve(.keepMine, preview: preview)
        guard case .refreshed(let refreshed) = result else { return XCTFail("Expected fresh diff") }
        XCTAssertEqual(refreshed.serverBytes, h.serverBytes)
        XCTAssertEqual(refreshed.candidateBytes, preview.candidateBytes)
        XCTAssertEqual(h.putCount, 0)
        XCTAssertEqual(try h.rig.base.files.read(at: h.path), h.copyBytes)
    }

    func testFailedCASRefreshesAndKeepsTheOneExactCandidate() async throws {
        let h = try await ConflictTestRig.make()
        let preview = try await h.service.preview(h.selection)
        h.beforePut = {
            h.revision = 2
            h.serverBytes = SyncScanTestSupport.bytes("Racing writer", id: h.original)
        }
        let result = try await h.service.resolve(.keepMine, preview: preview)
        guard case .refreshed(let refreshed) = result else { return XCTFail("Expected CAS refusal") }
        XCTAssertEqual(refreshed.serverBytes, h.serverBytes)
        XCTAssertEqual(try h.rig.base.files.read(at: h.path), h.copyBytes)
        XCTAssertEqual(try h.rig.base.files.listFiles().count, 2)
        XCTAssertEqual(h.putCount, 1)
    }

    func testMissingOrForbiddenOriginalRetainsCopyAndOffersKeepBoth() async throws {
        for failure in [SyncAPI.ErrorResponse.failure(.notFound), .failure(.forbidden), .deleted] {
            let h = try await ConflictTestRig.make()
            let preview = try await h.service.preview(h.selection)
            h.getFailure = failure
            let result = try await h.service.resolve(.keepMine, preview: preview)
            guard case .refreshed(let updated) = result else { return XCTFail("Expected unavailable head") }
            XCTAssertFalse(updated.canKeepMine)
            XCTAssertNil(updated.serverBytes)
            XCTAssertEqual(try h.rig.base.files.read(at: h.path), h.copyBytes)
            XCTAssertEqual(h.putCount, 0)
            _ = try await h.service.resolve(.keepBoth, preview: updated)
            XCTAssertNil(try SyncConflictMetadata.origin(in: h.rig.base.files.read(at: h.path), filename: "copy.md"))
        }
    }

    func testAuthoritativeViewerAndRemovalDenyMineWithoutInferringFrom403() async throws {
        for role in [SyncAPI.Role.viewer, nil] {
            let h = try await ConflictTestRig.make(group: true)
            let preview = try await h.service.preview(h.selection)
            h.remoteRole = role
            do {
                _ = try await h.service.resolve(.keepMine, preview: preview)
                XCTFail("Changed access authorized overwrite")
            } catch { XCTAssertEqual(error as? ConflictResolutionFailure, .staleAccess) }
            let updated = try await h.service.preview(h.selection)
            XCTAssertEqual(updated.mineRefusal, .accessDenied)
            XCTAssertEqual(h.putCount, 0)
            XCTAssertEqual(try h.rig.base.files.read(at: h.path), h.copyBytes)
        }
    }

    func test403AfterValidationKeepsExactPrivateCopy() async throws {
        let h = try await ConflictTestRig.make(group: true)
        let preview = try await h.service.preview(h.selection)
        h.putFailure = .forbidden
        do { _ = try await h.service.resolve(.keepMine, preview: preview); XCTFail("Denied request succeeded") }
        catch { XCTAssertEqual(ConflictResolutionService.failure(error), .accessDenied) }
        XCTAssertEqual(h.putCount, 1)
        XCTAssertEqual(try h.rig.base.files.read(at: h.path), h.copyBytes)
        XCTAssertEqual(try h.rig.base.files.listFiles().count, 2)
    }

    func testRenamedCopyLoadsByIdentityButAnOldPreviewCannotDeleteIt() async throws {
        let h = try await ConflictTestRig.make()
        let preview = try await h.service.preview(h.selection)
        try h.rig.base.files.move(from: h.path, to: "elsewhere.md")
        do { _ = try await h.service.resolve(.keepServer, preview: preview); XCTFail("Stale path was accepted") }
        catch { XCTAssertEqual(error as? ConflictResolutionFailure, .staleCopy) }
        let renamed = try await h.service.preview(h.selection)
        XCTAssertEqual(renamed.copy.relativePath, "elsewhere.md")
        _ = try await h.service.resolve(.keepServer, preview: renamed)
        XCTAssertNil(try h.rig.base.files.stamp(at: "elsewhere.md"))
    }

    func testEditedOrDuplicateCopyRefusesResolution() async throws {
        for duplicate in [false, true] {
            let h = try await ConflictTestRig.make()
            let preview = try await h.service.preview(h.selection)
            try h.rig.base.files.write(h.copyBytes + Data("new".utf8), at: duplicate ? "duplicate.md" : h.path)
            do { _ = try await h.service.resolve(.keepMine, preview: preview); XCTFail("Stale copy was sent") }
            catch { XCTAssertTrue([.invalidCopy, .staleCopy].contains(try XCTUnwrap(error as? ConflictResolutionFailure))) }
            XCTAssertEqual(h.putCount, 0)
        }
    }

    func testKeepBothPreservesIdentityBodyAndAcknowledgedHashForPersonalUpdate() async throws {
        let h = try await ConflictTestRig.make()
        let preview = try await h.service.preview(h.selection)
        _ = try await h.service.resolve(.keepBoth, preview: preview)
        let bytes = try h.rig.base.files.read(at: h.path)
        let document = PromptCodec.parseFile(bytes, filename: "copy.md")
        XCTAssertEqual(document.frontMatter.id, h.copyID)
        XCTAssertEqual(Data(document.body.utf8), Data("Mine Cafe\u{301}\r\n{{new}}".utf8))
        XCTAssertNil(try SyncConflictMetadata.origin(in: document))
        let record = try XCTUnwrap(h.rig.base.states.snapshot.value?.prompts[.assigned(h.copyID)])
        XCTAssertNil(record.origin)
        XCTAssertEqual(record.canonicalHash, SyncHash(bytes: h.copyBytes))
        XCTAssertEqual(record.rev, 1)
        XCTAssertEqual(h.putCount, 0)
    }

    func testJournalFailureRecoversMarkerClearingAndDeletionWithoutAcknowledgingEarly() async throws {
        for action in [ConflictResolutionAction.keepBoth, .keepServer] {
            let h = try await ConflictTestRig.make()
            let preview = try await h.service.preview(h.selection)
            h.rig.base.libraryOperations.failFlushNumber = h.rig.base.libraryOperations.flushCount + 1
            do { _ = try await h.service.resolve(action, preview: preview); XCTFail("Undurable mutation was reported successful") }
            catch { XCTAssertNotNil(h.rig.journal.pending) }
            h.rig.base.libraryOperations.failFlushNumber = nil
            XCTAssertEqual(try h.rig.journal.replay(), .committed)
            if action == .keepBoth {
                XCTAssertNil(try SyncConflictMetadata.origin(in: h.rig.base.files.read(at: h.path), filename: "copy.md"))
            } else { XCTAssertNil(try h.rig.base.files.stamp(at: h.path)) }
        }
    }

    func testOldAccountEpochAndRevokedViewCannotMutate() async throws {
        let h = try await ConflictTestRig.make()
        let first = try await h.service.preview(h.selection)
        first.validity.invalidate()
        do { _ = try await h.service.resolve(.keepBoth, preview: first); XCTFail("Closed view mutated") }
        catch { XCTAssertEqual(error as? ConflictResolutionFailure, .staleSession) }
        let second = try await h.service.preview(h.selection)
        _ = h.rig.service.stop()
        try h.rig.start()
        await h.rig.settle()
        do { _ = try await h.service.resolve(.keepMine, preview: second); XCTFail("Old epoch mutated") }
        catch { XCTAssertEqual(error as? ConflictResolutionFailure, .staleSession) }
        XCTAssertEqual(h.putCount, 0)
        XCTAssertEqual(try h.rig.base.files.read(at: h.path), h.copyBytes)
    }

    func testStopAndDrainDuringGETPreventsLateCASAndDeletion() async throws {
        let h = try await ConflictTestRig.make()
        let preview = try await h.service.preview(h.selection)
        let gate = SyncTransportGate()
        let started = SyncTransportGate()
        h.beforeGet = { await started.open(); await gate.wait() }
        let resolve = Task { try await h.service.resolve(.keepMine, preview: preview) }
        await started.wait()
        XCTAssertEqual(h.rig.service.stop(), .busy)
        await gate.open()
        do { _ = try await resolve.value; XCTFail("Stopped operation succeeded") } catch {}
        await h.rig.service.drain()
        XCTAssertEqual(h.rig.service.retire(), .stopped)
        XCTAssertEqual(h.putCount, 0)
        XCTAssertEqual(try h.rig.base.files.read(at: h.path), h.copyBytes)
    }
}

final class ConflictTestRig {
    let rig: SyncServiceRig
    let service: ConflictResolutionService
    let original = SyncTestValues.personalPrompt
    let copyID = SyncTestValues.device
    let path = "Conflicts/Personal/copy.md"
    let group: Bool
    let initialServerBytes: Data
    let copyBytes: Data
    var serverBytes: Data
    var revision: Int64 = 1
    var remoteRole: SyncAPI.Role? = .editor
    var getFailure: SyncAPI.ErrorResponse?
    var putFailure: SyncAPI.FailureCode?
    var beforePut: (() throws -> Void)?
    var beforeGet: (() async -> Void)?
    var putCount = 0
    var originalPath: String { group ? "Groups/Team/original.md" : "original.md" }
    var selection: LibraryPromptSelection { .init(identity: .assigned(copyID), relativePath: RelativePath(path)) }

    private init(group: Bool) throws {
        self.group = group
        rig = try SyncServiceRig()
        service = ConflictResolutionService(sync: rig.service)
        let initial = SyncScanTestSupport.bytes("Server Caf\u{e9}\n{{old}}", id: original)
        initialServerBytes = try group ? CanonicalForm.group(initial, filename: "original.md").bytes : initial
        serverBytes = initialServerBytes
        copyBytes = try SyncConflictMetadata.settingOrigin(.conflictOf(original), in:
            SyncScanTestSupport.bytes("Mine Cafe\u{301}\r\n{{new}}", id: copyID, extra: "favorite: true\nprivate: true\n"), filename: "copy.md")
    }

    static func make(group: Bool = false) async throws -> ConflictTestRig {
        let h = try ConflictTestRig(group: group)
        try h.rig.base.files.write(h.initialServerBytes, at: h.originalPath)
        try h.rig.base.files.write(h.copyBytes, at: h.path)
        let groups = try group ? SyncScanTestSupport.groups() : [:]
        try SyncScanTestSupport.installState(h.rig.base, groups: groups, prompts: [
            .assigned(h.original): SyncPromptState(scope: group ? SyncScanTestSupport.team : SyncScanTestSupport.personal,
                path: "original.md", rev: 1, canonicalHash: SyncHash(bytes: h.initialServerBytes)),
            .assigned(h.copyID): SyncPromptState(scope: SyncScanTestSupport.personal, path: RelativePath(h.path), rev: 1,
                canonicalHash: SyncHash(bytes: h.copyBytes), origin: .conflictOf(h.original))
        ])
        let owned = try SyncLibraryBinding(root: h.rig.base.binding.root, owner: h.rig.base.binding.account,
            managedFolders: group ? [SyncTestValues.group: SyncManagedFolder(owner: h.rig.base.binding.account, folder: "Team")] : [:])
        try h.rig.accounts.updateBinding(for: h.rig.base.binding.root) { _ in owned }
        h.rig.transport.handler = { [unowned h] _, request in
            switch request.method {
            case .get:
                if request.url.path.hasSuffix("/me") {
                    let me = try XCTUnwrap(AccountPresentationFake.signedIn().me)
                    return try SyncServiceRig.http(SyncAPI.MeResponse(user: me.user, groups: (group ? h.remoteRole : nil).map {
                        [.init(groupID: SyncTestValues.group.rawValue, name: "Team", role: $0)]
                    } ?? [], devices: me.devices))
                }
                await h.beforeGet?()
                if let failure = h.getFailure {
                    return HTTPResponse(statusCode: failure.httpStatus, body: try JSONEncoder().encode(failure))
                }
                return try SyncServiceRig.http(SyncAPI.Prompt(id: h.original.rawValue, rev: h.revision,
                    scope: group ? .group(groupID: SyncTestValues.group.rawValue) : .user,
                    path: "original.md", content: String(decoding: h.serverBytes, as: UTF8.self)))
            case .put:
                h.putCount += 1
                try h.beforePut?()
                if let failure = h.putFailure { return try SyncServiceRig.failure(failure) }
                let put = try JSONDecoder().decode(SyncAPI.PutPromptRequest.self, from: XCTUnwrap(request.body))
                if put.baseRev != h.revision {
                    let error = SyncAPI.ErrorResponse.conflict(head: .init(rev: h.revision,
                        scope: group ? .group(groupID: SyncTestValues.group.rawValue) : .user,
                        path: "original.md", content: String(decoding: h.serverBytes, as: UTF8.self)))
                    return HTTPResponse(statusCode: 409, body: try JSONEncoder().encode(error))
                }
                h.revision += 1
                h.serverBytes = Data(put.content.utf8)
                return try SyncServiceRig.http(SyncAPI.WriteResponse(rev: h.revision, seq: h.revision))
            default:
                let original = SyncAPI.FeedItem.upsert(seq: h.revision, prompt: .init(id: h.original.rawValue, rev: h.revision,
                    path: "original.md", content: String(decoding: h.serverBytes, as: UTF8.self)))
                let copy = SyncAPI.FeedItem.upsert(seq: h.revision, prompt: .init(id: h.copyID.rawValue, rev: 1, path: h.path,
                    content: String(decoding: h.copyBytes, as: UTF8.self)))
                let groups: [SyncAPI.SyncScope] = group ? [.init(identity: .group(groupID: SyncTestValues.group.rawValue,
                    name: "Team", role: .editor), mode: .snapshot, head: 1, cursor: "team", hasMore: false, items: [original])] : []
                return try SyncServiceRig.pull(items: group ? [copy] : [original, copy], groups: groups)
            }
        }
        try h.rig.start()
        await h.rig.settle()
        let requests = h.rig.transport.requests.map { $0.method.rawValue + " " + $0.url.path }
        XCTAssertEqual(h.rig.service.report.status, .hasConflicts,
            "Report: \(h.rig.service.report); requests: \(requests)")
        guard h.rig.service.report.status == .hasConflicts else { throw ConflictResolutionFailure.operationFailed }
        return h
    }
}
