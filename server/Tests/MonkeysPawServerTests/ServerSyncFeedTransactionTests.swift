import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerSyncFeedTransactionTests {
    enum FailurePoint: CaseIterable { case beforeEntry, afterEntry, interleaved, both }
    private enum InjectedFailure: Error { case worker, interleaved }

    @Test(arguments: FailurePoint.allCases)
    func throwingStepsReleaseAndDrainTheWorker(failure: FailurePoint) async throws {
        let entered = LoginTestLatch(), release = LoginTestLatch()
        let completed = LoginTestLatch(), workerFinished = LoginTestLatch()
        let pending = Task {
            let result: Result<Void, any Error>
            do {
                result = .success(try await Self.withInterleavedTask(entered: entered, release: release, operation: {
                    do {
                        if failure == .beforeEntry { throw InjectedFailure.worker }
                        await entered.open()
                        await release.wait()
                        if failure == .afterEntry || failure == .both { throw InjectedFailure.worker }
                        await workerFinished.open()
                    } catch {
                        await workerFinished.open()
                        throw error
                    }
                }, interleaved: {
                    if failure == .interleaved || failure == .both { throw InjectedFailure.interleaved }
                }))
            } catch { result = .failure(error) }
            await completed.open()
            return result
        }
        do {
            try await completed.wait(timeout: .seconds(10))
            try await release.wait(timeout: .zero)
            try await workerFinished.wait(timeout: .zero)
        } catch {
            Issue.record("Interleaving failed to release and drain its worker at \(failure)")
        }
        // Rescue a broken helper so its regression test cannot hang the suite.
        await entered.open()
        await release.open()
        let expected: InjectedFailure = failure == .interleaved ? .interleaved : .worker
        await #expect(throws: expected) { try await pending.value.get() }
        try await workerFinished.wait(timeout: .seconds(10))
    }

    @Test(arguments: ["rename", "remove", "delete", "disable", "revoke"])
    func authorityMetadataAndEventsShareOneReadSnapshot(change: String) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let reader = try await fixture.user("reader")
            let group = try await fixture.group(owner: owner)
            try await fixture.member(groupID: group.id, user: reader, role: .viewer)
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(reader)
            let personal = PromptOwnership.user(ownerID: reader.id), shared = PromptOwnership.group(groupID: group.id)
            let privateCursor = try #require(await fixture.seedFeed(identity: personal, count: 1).last)
            let groupSeqs = try await fixture.seedFeed(identity: shared, count: 2, startingID: 10)
            let request = try await fixture.feedRequest(cursors: [personal.key: privateCursor, shared.key: groupSeqs[0]])
            let entered = LoginTestLatch(), release = LoginTestLatch()
            let (before, after, item) = try await Self.withInterleavedTask(entered: entered, release: release, operation: {
                try await fixture.feedRepository.read { feed, accounts, devices in
                    _ = try await SessionService.requireSession(session.identity, accounts: accounts, devices: devices)
                    let before = try await feed.scopes(userID: reader.id)
                    let head = try #require(before.first { $0.identity.key == shared.key }).head
                    await entered.open()
                    await release.wait()
                    let after = try await feed.scopes(userID: reader.id)
                    let next = try #require(await feed.nextSequence(key: shared.key, after: groupSeqs[0], through: head))
                    let item = try await feed.item(key: shared.key, seq: next)
                    // Revocation/disable committed after this snapshot cannot split its authorization.
                    _ = try await SessionService.requireSession(session.identity, accounts: accounts, devices: devices)
                    return (before, after, item)
                }
            }, interleaved: {
                switch change {
                case "rename":
                    _ = try await fixture.service.rename(id: group.id, request: .init(name: "Changed"), session: ownerSession.identity)
                    _ = try await fixture.service.upsertMember(id: group.id, userID: reader.id, request: .init(role: .editor), session: ownerSession.identity)
                    _ = try await fixture.seedFeed(identity: shared, count: 1, startingID: 99)
                case "remove": try await fixture.service.removeMember(id: group.id, userID: reader.id, session: ownerSession.identity)
                case "delete": try await fixture.service.delete(id: group.id, session: ownerSession.identity)
                case "disable": try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at WHERE id = \(bind: reader.id)")
                default: try await fixture.account.sessions.logout(session.identity)
                }
            })
            for scopes in [before, after] {
                #expect(scopes.count == 2)
                let scope = try #require(scopes.first { $0.identity.key == shared.key })
                #expect(scope.identity == .group(groupID: group.id, name: "Original", role: .viewer))
                #expect(scope.head == groupSeqs[1])
            }
            #expect(item.seq == groupSeqs[1])
            if change == "disable" || change == "revoke" {
                await #expect(throws: AccountError.unauthorized) { _ = try await fixture.feed.pull(request: request, session: session.identity) }
            } else {
                let current = try await fixture.feed.pull(request: request, session: session.identity)
                if change == "rename" {
                    let scope = try current.scope(shared.key)
                    #expect(scope.identity == .group(groupID: group.id, name: "Changed", role: .editor))
                    #expect(scope.items.count == 2 && scope.head > groupSeqs[1])
                } else { #expect(current.scopes.count == 1 && current.removed == [shared.key]) }
            }
        }
    }

    @Test func pullNeverObservesAnUncommittedHalfOfAMovePair() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("owner")
            let group = try await fixture.group(owner: user)
            let session = try await fixture.account.session(user)
            let personal = PromptOwnership.user(ownerID: user.id), shared = PromptOwnership.group(groupID: group.id)
            let privateCursor = try await fixture.writePrompt(session: session.identity).seq
            let groupCursor = try #require(await fixture.seedFeed(identity: shared, count: 1).last)
            let request = try await fixture.feedRequest(cursors: [personal.key: privateCursor, shared.key: groupCursor])
            let source = try #require(await fixture.promptRepository.read { prompts, _, _, _ in try await prompts.head(id: GroupTestFixture.livePrompt) })
            let destination = PromptRecord(id: source.id, identity: shared, path: "Moved.md", pathKey: "moved.md", content: source.content,
                                           title: source.title, rev: 2, createdBy: source.createdBy, createdAt: source.createdAt,
                                           updatedBy: user.id, updatedAt: user.createdAt, deletedAt: nil)
            let entered = LoginTestLatch(), release = LoginTestLatch()
            let (out, upsert) = try await Self.withInterleavedTask(entered: entered, release: release, operation: {
                try await fixture.promptRepository.write { prompts, _, _, _ in
                    try await prompts.update(destination, baseRev: 1)
                    try await prompts.appendRevision(destination, origin: .move)
                    let out = try await prompts.appendRemoval(source, kind: .moveOut, rev: 2, at: user.createdAt)
                    await entered.open()
                    await release.wait()
                    let upsert = try await prompts.appendUpsert(destination)
                    return (out, upsert)
                }
            }, interleaved: {
                let before = try await fixture.feed.pull(request: request, session: session.identity)
                #expect(before.scopes.allSatisfy { $0.items.isEmpty && !$0.hasMore })
                #expect(try before.scope(personal.key).head == privateCursor)
                #expect(try before.scope(shared.key).head == groupCursor)
            })
            let after = try await fixture.feed.pull(request: request, session: session.identity)
            #expect(try after.scope(personal.key).items == [.moveOut(seq: out, id: source.id)])
            #expect(try after.scope(shared.key).items == [.upsert(seq: upsert, prompt: .init(id: source.id, rev: 2, path: "Moved.md", content: source.content))])
            #expect(upsert == out + 1 && after.scopes.allSatisfy { !$0.hasMore })
        }
    }

    private static func withInterleavedTask<Value: Sendable>(
        entered: LoginTestLatch, release: LoginTestLatch,
        operation: @escaping @Sendable () async throws -> Value,
        interleaved: @Sendable () async throws -> Void
    ) async throws -> Value {
        let pending = Task {
            do {
                let value = try await operation()
                await entered.open()
                return value
            } catch {
                await entered.open()
                throw error
            }
        }
        do {
            try await entered.wait(timeout: .seconds(10))
            try await interleaved()
        } catch {
            await release.open()
            // Drain the worker and surface its error even when the interleaved step also fails.
            _ = try await pending.value
            throw error
        }
        await release.open()
        return try await pending.value
    }
}
