import Foundation
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerPromptTransferAccessTests {
    @Test(arguments: [SyncAPI.AccountKind.member, .admin], GroupTestRole.allCases)
    func groupDeleteAllowsEditorsAndOwnersRegardlessOfCreator(kind: SyncAPI.AccountKind, role: GroupTestRole) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("actor", kind: kind)
            let group = try await fixture.group(owner: owner)
            if let role = role.role { try await fixture.member(groupID: group.id, user: actor, role: role) }
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(actor)
            _ = try await fixture.writePrompt(scope: .group(groupID: group.id), session: ownerSession.identity)
            let before = try await fixture.persistence.promptStorageState()
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/prompts/\(GroupTestFixture.livePrompt)?base_rev=1", method: .delete,
                                         headers: PromptHTTPTest.headers(session)) {
                    if role == .viewer || role == .nonMember {
                        try PromptHTTPTest.error($0, .failure(role == .viewer ? .forbidden : .notFound))
                        #expect(try await fixture.persistence.promptStorageState() == before)
                        return
                    }
                    let write = try PromptHTTPTest.success($0, as: SyncAPI.WriteResponse.self)
                    #expect(write.rev == 2 && write.seq == 2)
                    let head = try #require(await fixture.promptRepository.read { prompts, _, _, _ in
                        try await prompts.head(id: GroupTestFixture.livePrompt)
                    })
                    #expect(head.createdBy == owner.id && head.updatedBy == actor.id && head.deletedAt == head.updatedAt)
                    let deletion = try await fixture.prompts.revision(id: head.id, rev: 2, session: session.identity)
                    #expect(deletion.origin == .delete && deletion.authorID == actor.id && deletion.scope == .group(groupID: group.id))
                }
            }
        }
    }

    @Test(arguments: [SyncAPI.AccountKind.member, .admin].flatMap { kind in
        GroupTestRole.allCases.flatMap { role in [false, true].map { (kind, role, $0) } }
    })
    func privateDeleteDependsOnlyOnActualOwnership(combination: (SyncAPI.AccountKind, GroupTestRole, Bool)) async throws {
        let (kind, role, owns) = combination
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("actor", kind: kind)
            let group = try await fixture.group(owner: owner)
            if let role = role.role { try await fixture.member(groupID: group.id, user: actor, role: role) }
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(actor)
            _ = try await fixture.writePrompt(session: owns ? session.identity : ownerSession.identity)
            let before = try await fixture.persistence.promptStorageState()
            if owns {
                let write = try await fixture.prompts.delete(id: GroupTestFixture.livePrompt, query: .init(baseRev: 1), session: session.identity)
                #expect(write.rev == 2 && write.seq == 2)
            } else {
                await #expect(throws: AccountError.notFound) {
                    _ = try await fixture.prompts.delete(id: GroupTestFixture.livePrompt, query: .init(baseRev: 1), session: session.identity)
                }
                #expect(try await fixture.persistence.promptStorageState() == before)
            }
        }
    }

    @Test(arguments: [SyncAPI.AccountKind.member, .admin].flatMap { kind in
        GroupTestRole.allCases.flatMap { target in [false, true].map { (kind, target, $0) } }
    })
    func privateToGroupRequiresActualOwnerAndTargetEditor(combination: (SyncAPI.AccountKind, GroupTestRole, Bool)) async throws {
        let (kind, target, owns) = combination
        try await Self.transfer(kind: kind, source: nil, target: target, creator: owns)
    }

    @Test(arguments: [SyncAPI.AccountKind.member, .admin].flatMap { kind in
        GroupTestRole.allCases.flatMap { source in [false, true].map { (kind, source, $0) } }
    })
    func groupToPrivateRequiresOwnerOrEditorCreator(combination: (SyncAPI.AccountKind, GroupTestRole, Bool)) async throws {
        let (kind, source, creator) = combination
        try await Self.transfer(kind: kind, source: source, target: nil, creator: creator)
    }

    @Test(arguments: [SyncAPI.AccountKind.member, .admin].flatMap { kind in
        GroupTestRole.allCases.flatMap { source in
            GroupTestRole.allCases.flatMap { target in [false, true].map { (kind, source, target, $0) } }
        }
    })
    func groupToGroupRequiresSourceTransferAndTargetWriteAuthority(
        combination: (SyncAPI.AccountKind, GroupTestRole, GroupTestRole, Bool)
    ) async throws {
        let (kind, source, target, creator) = combination
        try await Self.transfer(kind: kind, source: source, target: target, creator: creator)
    }

    private static func transfer(kind: SyncAPI.AccountKind, source: GroupTestRole?, target: GroupTestRole?, creator: Bool) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("actor", kind: kind)
            let first = try await fixture.group(owner: owner)
            let second = try await fixture.group(owner: owner, id: PersistenceTestRepository.otherGroup)
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(actor)
            let sourceScope: SyncAPI.PromptScope = source == nil ? .user : .group(groupID: first.id)
            let targetScope: SyncAPI.PromptScope = target == nil ? .user : .group(groupID: second.id)
            if source != nil && creator { try await fixture.member(groupID: first.id, user: actor, role: .editor) }
            _ = try await fixture.writePrompt(scope: sourceScope, session: creator ? session.identity : ownerSession.identity)
            if let source {
                if let role = source.role { try await fixture.member(groupID: first.id, user: actor, role: role) }
                else { try await fixture.persistence.execute("DELETE FROM memberships WHERE group_id = \(bind: first.id) AND user_id = \(bind: actor.id)") }
            }
            if let role = target?.role { try await fixture.member(groupID: second.id, user: actor, role: role) }
            let denied: SyncAPI.FailureCode?
            if source == nil && !creator || source == .nonMember { denied = .notFound }
            else if source == .viewer || source == .editor && !creator { denied = .forbidden }
            else if target == .nonMember { denied = .notFound }
            else if target == .viewer { denied = .forbidden }
            else { denied = nil }
            let before = try await fixture.persistence.promptStorageState()
            fixture.account.clock.advance(60)
            let at = ServerTimestamp.string(fixture.account.clock.now())
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                let request = SyncAPI.MovePromptRequest(baseRev: 1, scope: targetScope, path: "Moved.md")
                try await client.execute(uri: "/api/v1/prompts/\(GroupTestFixture.livePrompt)/move", method: .post,
                                         headers: PromptHTTPTest.headers(session), body: .init(bytes: JSONEncoder().encode(request))) {
                    if let denied {
                        try PromptHTTPTest.error($0, .failure(denied))
                        #expect(try await fixture.persistence.promptStorageState() == before)
                        return
                    }
                    let write = try PromptHTTPTest.success($0, as: SyncAPI.WriteResponse.self)
                    #expect(write.rev == 2 && write.seq == 3)
                    let head = try #require(await fixture.promptRepository.read { prompts, _, _, _ in
                        try await prompts.head(id: GroupTestFixture.livePrompt)
                    })
                    #expect(head.createdBy == (creator ? actor.id : owner.id) && head.createdAt == owner.createdAt)
                    #expect(head.updatedBy == actor.id && head.updatedAt == at && head.rev == 2 && head.deletedAt == nil)
                    #expect(head.identity == PromptOwnership(scope: targetScope, userID: actor.id))
                    let revision = try await fixture.prompts.revision(id: head.id, rev: 2, session: session.identity)
                    #expect(revision.origin == .move && revision.scope == targetScope && revision.path == head.path)
                    #expect(revision.authorID == actor.id && revision.createdAt == at && revision.content == head.content)
                    #expect(try await fixture.persistence.count("prompt_revisions") == 2)
                    #expect(try await fixture.persistence.count("changes") == 3)
                    #expect(try await fixture.persistence.count("retired_prompt_ids") == 0)
                }
            }
        }
    }
}
