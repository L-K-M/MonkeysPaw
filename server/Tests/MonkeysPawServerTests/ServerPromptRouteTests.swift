import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerPromptRouteTests {
    @Test func createReadEditRenameAndReadRevisions() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let session = try await fixture.account.session(owner)
            let id = PersistenceTestRepository.prompt
            let content = "---\nid: \(id)\ntitle: First\n---\nOriginal body\n"
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                let body = try JSONEncoder().encode(SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "First.md", content: content))
                try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: Self.headers(session), body: .init(bytes: body)) {
                    #expect($0.status == .ok)
                    guard $0.status == .ok else { return }
                    let write = try JSONDecoder().decode(SyncAPI.WriteResponse.self, from: Data($0.body.readableBytesView))
                    #expect(write.rev == 1 && write.seq == 1 && write.warnings == nil)
                }
                try await client.execute(uri: "/api/v1/prompts/\(id)", method: .get, headers: Self.headers(session)) {
                    #expect($0.status == .ok)
                    guard $0.status == .ok else { return }
                    let prompt = try JSONDecoder().decode(SyncAPI.Prompt.self, from: Data($0.body.readableBytesView))
                    #expect(prompt == .init(id: id, rev: 1, scope: .user, path: "First.md", content: content))
                }
                let edited = promptContent(id: id, metadata: "title: Second\n", body: "Edited body\n")
                for (baseRev, path, origin): (Int64, String, SyncAPI.WriteOrigin) in [(1, "First.md", .llm), (2, "Renamed.md", .restore)] {
                    fixture.account.clock.advance(60)
                    let body = try JSONEncoder().encode(SyncAPI.PutPromptRequest(baseRev: baseRev, scope: .user, path: path, content: edited, origin: origin))
                    try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: Self.headers(session), body: .init(bytes: body)) {
                        let write = try Self.success($0, as: SyncAPI.WriteResponse.self)
                        #expect(write.rev == baseRev + 1 && write.seq == baseRev + 1)
                    }
                }
                try await client.execute(uri: "/api/v1/prompts/\(id)/revisions", method: .get, headers: Self.headers(session)) {
                    let revisions = try Self.success($0, as: SyncAPI.RevisionsResponse.self).revisions
                    #expect(revisions.map(\.rev) == [3, 2, 1])
                    #expect(revisions.map(\.origin) == [.restore, .llm, .edit])
                    #expect(revisions.map(\.path) == ["Renamed.md", "First.md", "First.md"])
                    #expect(revisions.allSatisfy { $0.authorID == owner.id && $0.scope == .user })
                }
                for rev: Int64 in [1, 2, 3] {
                    try await client.execute(uri: "/api/v1/prompts/\(id)/revisions/\(rev)", method: .get, headers: Self.headers(session)) {
                        let revision = try Self.success($0, as: SyncAPI.Revision.self)
                        #expect(revision.id == id && revision.rev == rev && revision.content == (rev == 1 ? content : edited))
                        #expect(revision.authorID == owner.id)
                    }
                }
                try await client.execute(uri: "/api/v1/prompts/\(id)", method: .get, headers: Self.headers(session)) {
                    let prompt = try Self.success($0, as: SyncAPI.Prompt.self)
                    #expect(prompt.rev == 3 && prompt.path == "Renamed.md" && prompt.content == edited)
                }
                let head = try #require(await fixture.promptRepository.read { prompts, _, _, _ in try await prompts.head(id: id) })
                #expect(head.title == "Second" && head.pathKey == "renamed.md" && head.createdBy == owner.id)
                #expect(head.createdAt == owner.createdAt && head.updatedAt == ServerTimestamp.string(fixture.account.clock.now()))
                #expect(try await fixture.persistence.count("prompt_revisions") == 3)
                #expect(try await fixture.persistence.count("changes") == 3)
            }
        }
    }

    @Test(arguments: [SyncAPI.AccountKind.member, .admin], GroupTestRole.allCases)
    func groupPromptReadCreateEditRenameAndRevisionAuthorMatrix(kind: SyncAPI.AccountKind, role: GroupTestRole) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("actor", kind: kind)
            let group = try await fixture.group(owner: owner)
            if let role = role.role { try await fixture.member(groupID: group.id, user: actor, role: role) }
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(actor)
            let scope = SyncAPI.PromptScope.group(groupID: group.id)
            let id = GroupTestFixture.livePrompt
            _ = try await fixture.writePrompt(scope: scope, session: ownerSession.identity)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            let mayRead = role != .nonMember
            let mayWrite = role == .owner || role == .editor
            let denied = SyncAPI.ErrorResponse.failure(role == .nonMember ? .notFound : .forbidden)
            try await app.test(.router) { client in
                for suffix in ["", "/revisions", "/revisions/1"] {
                    try await client.execute(uri: "/api/v1/prompts/\(id)\(suffix)", method: .get, headers: Self.headers(session)) {
                        if !mayRead { try Self.error($0, .failure(.notFound)); return }
                        #expect($0.status == .ok)
                        if suffix == "/revisions" {
                            let summary = try #require(Self.success($0, as: SyncAPI.RevisionsResponse.self).revisions.first)
                            #expect(summary.authorID == owner.id && summary.scope == scope)
                        } else if suffix == "/revisions/1" {
                            let revision = try Self.success($0, as: SyncAPI.Revision.self)
                            #expect(revision.authorID == owner.id && revision.content == promptContent(id: id))
                        }
                    }
                }
                for (baseRev, path): (Int64, String) in [(1, "Example.md"), (2, "Renamed.md")] {
                    let content = promptContent(id: id, body: "Updated by member\n")
                    let body = try JSONEncoder().encode(SyncAPI.PutPromptRequest(baseRev: baseRev, scope: scope, path: path, content: content))
                    try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: Self.headers(session), body: .init(bytes: body)) {
                        if !mayWrite { try Self.error($0, denied); return }
                        #expect(try Self.success($0, as: SyncAPI.WriteResponse.self).rev == baseRev + 1)
                    }
                }
                let newID = GroupTestFixture.secondLivePrompt
                let body = try JSONEncoder().encode(SyncAPI.PutPromptRequest(baseRev: 0, scope: scope, path: "Created.md", content: promptContent(id: newID)))
                try await client.execute(uri: "/api/v1/prompts/\(newID)", method: .put, headers: Self.headers(session), body: .init(bytes: body)) {
                    if !mayWrite { try Self.error($0, denied); return }
                    #expect(try Self.success($0, as: SyncAPI.WriteResponse.self).rev == 1)
                }
                #expect(try await fixture.persistence.count("prompt_revisions") == (mayWrite ? 4 : 1))
                if mayWrite {
                    let summary = try await fixture.prompts.revisions(id: id, session: session.identity).revisions
                    #expect(summary.first?.authorID == actor.id && summary.last?.authorID == owner.id)
                }
            }
        }
    }

    @Test func hiddenDirectoryDiagnosticHasAWireRepresentation() throws {
        do {
            _ = try SyncPathValidator.validate(".hidden/Prompt.md", scope: .user)
            Issue.record("Expected hidden-directory rejection")
        } catch let issue as SyncPathIssue {
            let envelope = SyncAPI.ErrorResponse.validation(issues: [.init(issue)])
            let data = try JSONEncoder().encode(envelope)
            #expect(try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: data) == envelope)
        }
    }

    private static func headers(_ session: IssuedSession) -> HTTPFields {
        [.authorization: "Bearer \(session.token.value)", .contentType: "application/json"]
    }

    private static func success<T: Decodable>(_ response: TestResponse, as type: T.Type) throws -> T {
        #expect(response.status == .ok)
        return try JSONDecoder().decode(type, from: Data(response.body.readableBytesView))
    }

    private static func error(_ response: TestResponse, _ expected: SyncAPI.ErrorResponse) throws {
        #expect(response.status.code == expected.httpStatus)
        let decoded = try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: Data(response.body.readableBytesView))
        #expect(decoded == expected)
    }
}
