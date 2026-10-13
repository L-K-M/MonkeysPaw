import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

enum PrivatePromptRelationship: Sendable, CaseIterable { case own, foreign }

@Suite(.serialized)
struct ServerPromptAccessTests {
    @Test(arguments: [SyncAPI.AccountKind.member, .admin].flatMap { kind in
        GroupTestRole.allCases.flatMap { role in PrivatePromptRelationship.allCases.map { (kind, role, $0) } }
    })
    func privatePromptAuthorityDependsOnlyOnActualOwner(
        combination: (SyncAPI.AccountKind, GroupTestRole, PrivatePromptRelationship)
    ) async throws {
        let (kind, role, relationship) = combination
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("actor", kind: kind)
            let group = try await fixture.group(owner: owner)
            if let role = role.role { try await fixture.member(groupID: group.id, user: actor, role: role) }
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(actor)
            let owns = relationship == .own
            let id = GroupTestFixture.livePrompt
            let content = promptContent(body: "private-head-sentinel\n")
            _ = try await fixture.writePrompt(content: content, session: owns ? session.identity : ownerSession.identity)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                for suffix in ["", "/revisions", "/revisions/1"] {
                    try await client.execute(uri: "/api/v1/prompts/\(id)\(suffix)", method: .get, headers: PromptHTTPTest.headers(session)) {
                        if !owns { try PromptHTTPTest.error($0, .failure(.notFound)); return }
                        #expect($0.status == .ok)
                        if suffix == "/revisions/1" {
                            let revision = try PromptHTTPTest.success($0, as: SyncAPI.Revision.self)
                            #expect(revision.authorID == actor.id && revision.content == content)
                        }
                    }
                }
                let create = SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "Example.md", content: content)
                try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(create))) {
                    try PromptHTTPTest.error($0, owns ? .conflict(head: .init(rev: 1, scope: .user, path: "Example.md", content: content)) : .failure(.notFound))
                }
                for (baseRev, path): (Int64, String) in [(1, "Example.md"), (2, "Renamed.md")] {
                    let request = SyncAPI.PutPromptRequest(baseRev: baseRev, scope: .user, path: path, content: content)
                    try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session),
                                             body: .init(bytes: JSONEncoder().encode(request))) {
                        if !owns { try PromptHTTPTest.error($0, .failure(.notFound)); return }
                        let write = try PromptHTTPTest.success($0, as: SyncAPI.WriteResponse.self)
                        #expect(write.rev == baseRev + 1)
                    }
                }
                // A foreign user's same path cannot become a path_taken disclosure.
                let newID = GroupTestFixture.secondLivePrompt
                let request = SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: owns ? "New.md" : "Example.md", content: promptContent(id: newID))
                try await client.execute(uri: "/api/v1/prompts/\(newID)", method: .put, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(request))) {
                    let write = try PromptHTTPTest.success($0, as: SyncAPI.WriteResponse.self)
                    #expect(write.rev == 1)
                }
                #expect(try await fixture.persistence.count("prompt_revisions") == (owns ? 4 : 2))
            }
        }
    }

    @Test(arguments: [SyncAPI.AccountKind.member, .admin])
    func forgedScopesNeverExposeForeignHeadsTombstonesOrPathClashes(kind: SyncAPI.AccountKind) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("actor", kind: kind)
            let foreignGroup = try await fixture.group(owner: owner)
            let ownGroup = try await fixture.group(owner: actor, id: PersistenceTestRepository.otherGroup)
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(actor)
            let foreignID = GroupTestFixture.livePrompt
            let privateID = GroupTestFixture.privatePrompt
            let foreignScope = SyncAPI.PromptScope.group(groupID: foreignGroup.id)
            let ownScope = SyncAPI.PromptScope.group(groupID: ownGroup.id)
            _ = try await fixture.writePrompt(scope: foreignScope, content: promptContent(body: "foreign-group-sentinel\n"), session: ownerSession.identity)
            _ = try await fixture.writePrompt(id: privateID, content: promptContent(id: privateID, body: "foreign-private-sentinel\n"), session: ownerSession.identity)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                for id in [foreignID, privateID] {
                    for scope in [SyncAPI.PromptScope.user, ownScope, foreignScope] {
                        for baseRev: Int64 in [0, 1, 99] {
                            let request = SyncAPI.PutPromptRequest(baseRev: baseRev, scope: scope, path: "Example.md", content: promptContent(id: id))
                            try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session),
                                                     body: .init(bytes: JSONEncoder().encode(request))) {
                                try PromptHTTPTest.error($0, .failure(.notFound))
                            }
                        }
                    }
                }
                let newID = GroupTestFixture.secondLivePrompt
                let inaccessible = SyncAPI.PutPromptRequest(baseRev: 0, scope: foreignScope, path: "EXAMPLE.md", content: promptContent(id: newID))
                try await client.execute(uri: "/api/v1/prompts/\(newID)", method: .put, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(inaccessible))) {
                    try PromptHTTPTest.error($0, .failure(.notFound))
                }
                let visible = SyncAPI.PutPromptRequest(baseRev: 0, scope: ownScope, path: "EXAMPLE.md", content: promptContent(id: newID))
                try await client.execute(uri: "/api/v1/prompts/\(newID)", method: .put, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(visible))) {
                    let write = try PromptHTTPTest.success($0, as: SyncAPI.WriteResponse.self)
                    #expect(write.rev == 1)
                }
                try await fixture.tombstonePrompt(id: privateID, actorID: owner.id)
                try await fixture.persistence.execute("DELETE FROM prompts WHERE id = \(bind: privateID)")
                let revive = SyncAPI.PutPromptRequest(baseRev: 0, scope: ownScope, path: "Revived.md", content: promptContent(id: privateID))
                try await client.execute(uri: "/api/v1/prompts/\(privateID)", method: .put, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(revive))) {
                    try PromptHTTPTest.error($0, .failure(.notFound))
                }
                try await fixture.service.delete(id: foreignGroup.id, session: ownerSession.identity)
                let reviveGroup = SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "Revived.md", content: promptContent())
                try await client.execute(uri: "/api/v1/prompts/\(foreignID)", method: .put, headers: PromptHTTPTest.headers(ownerSession),
                                         body: .init(bytes: JSONEncoder().encode(reviveGroup))) {
                    try PromptHTTPTest.error($0, .failure(.notFound))
                }
                for suffix in ["", "/revisions", "/revisions/1"] {
                    try await client.execute(uri: "/api/v1/prompts/\(foreignID)\(suffix)", method: .get, headers: PromptHTTPTest.headers(ownerSession)) {
                        try PromptHTTPTest.error($0, .failure(.notFound))
                    }
                }
            }
        }
    }

    @Test(arguments: [SyncAPI.AccountKind.member, .admin], GroupTestRole.allCases)
    func tombstoneAndRetiredIDAuthorizationUsesTheStoredScope(kind: SyncAPI.AccountKind, role: GroupTestRole) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("actor", kind: kind)
            let group = try await fixture.group(owner: owner)
            if let role = role.role { try await fixture.member(groupID: group.id, user: actor, role: role) }
            let ownerSession = try await fixture.account.session(owner)
            let session = try await fixture.account.session(actor)
            let scope = SyncAPI.PromptScope.group(groupID: group.id)
            _ = try await fixture.writePrompt(scope: scope, session: ownerSession.identity)
            try await fixture.tombstonePrompt(actorID: owner.id)
            let id = GroupTestFixture.livePrompt
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                try await client.execute(uri: "/api/v1/prompts/\(id)", method: .get, headers: PromptHTTPTest.headers(session)) {
                    try PromptHTTPTest.error($0, .failure(.notFound))
                }
                for suffix in ["/revisions", "/revisions/1", "/revisions/2"] {
                    try await client.execute(uri: "/api/v1/prompts/\(id)\(suffix)", method: .get, headers: PromptHTTPTest.headers(session)) {
                        if role == .nonMember { try PromptHTTPTest.error($0, .failure(.notFound)); return }
                        #expect($0.status == .ok)
                        if suffix == "/revisions" {
                            let list = try PromptHTTPTest.success($0, as: SyncAPI.RevisionsResponse.self)
                            #expect(list.revisions.map(\.rev) == [2, 1])
                        } else {
                            let revision = try PromptHTTPTest.success($0, as: SyncAPI.Revision.self)
                            #expect(revision.origin == (suffix == "/revisions/1" ? .edit : .delete))
                            #expect(revision.authorID == owner.id)
                            #expect(revision.scope == scope)
                            #expect(revision.content == promptContent())
                        }
                    }
                }
                let denied: SyncAPI.ErrorResponse
                switch role {
                case .owner, .editor: denied = .deleted
                case .viewer: denied = .failure(.forbidden)
                case .nonMember: denied = .failure(.notFound)
                }
                let before = try await fixture.persistence.promptStorageState()
                for baseRev: Int64 in [0, 1, 2, 99] {
                    let request = SyncAPI.PutPromptRequest(baseRev: baseRev, scope: .user, path: "Revived.md", content: promptContent())
                    try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session),
                                             body: .init(bytes: JSONEncoder().encode(request))) { try PromptHTTPTest.error($0, denied) }
                }
                #expect(try await fixture.persistence.promptStorageState() == before)
                // Content/history purge cannot allow base_rev=0 to resurrect the ID.
                try await fixture.persistence.execute("DELETE FROM prompts WHERE id = \(bind: id)")
                let request = SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "Revived.md", content: promptContent())
                try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(request))) { try PromptHTTPTest.error($0, denied) }
                for suffix in ["/revisions", "/revisions/1"] {
                    try await client.execute(uri: "/api/v1/prompts/\(id)\(suffix)", method: .get, headers: PromptHTTPTest.headers(session)) {
                        try PromptHTTPTest.error($0, .failure(.notFound))
                    }
                }
                #expect(try await fixture.persistence.count("prompts") == 0)
                #expect(try await fixture.persistence.count("retired_prompt_ids") == 1)
            }
        }
    }

    @Test func everyPromptRouteChecksAuthAndStrictIdentityGrammar() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let session = try await fixture.account.session(owner)
            let revoked = try await fixture.account.session(owner)
            try await fixture.account.sessions.logout(revoked.identity)
            let disabledUser = try await fixture.user("disabled")
            let disabled = try await fixture.account.session(disabledUser)
            try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at WHERE id = \(bind: disabledUser.id)")
            _ = try await fixture.writePrompt(session: session.identity)
            let id = GroupTestFixture.livePrompt
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            let put = try JSONEncoder().encode(SyncAPI.PutPromptRequest(baseRev: 1, scope: .user, path: "Example.md", content: promptContent()))
            try await app.test(.router) { client in
                let routeCases: [(String, HTTPRequest.Method)] = [("", .get), ("", .put), ("/revisions", .get), ("/revisions/1", .get)]
                for headers: HTTPFields in [[:], [.authorization: "Bearer invalid"], PromptHTTPTest.headers(revoked), PromptHTTPTest.headers(disabled)] {
                    for (suffix, method) in routeCases {
                        try await client.execute(uri: "/api/v1/prompts/\(id)\(suffix)", method: method, headers: headers, body: method == .put ? .init(bytes: put) : nil) {
                            try PromptHTTPTest.error($0, .failure(.unauthorized))
                            #expect($0.headers[.wwwAuthenticate] == "Bearer")
                        }
                    }
                }
                for badID in ["invalid", id.lowercased()] {
                    for (suffix, method) in routeCases {
                        try await client.execute(uri: "/api/v1/prompts/\(badID)\(suffix)", method: method, headers: PromptHTTPTest.headers(session),
                                                 body: method == .put ? .init(bytes: put) : nil) {
                            try PromptHTTPTest.error($0, .failure(.malformedRequest))
                        }
                    }
                }
                for rev in ["0", "-1", "+1", "01", "1.0", "9223372036854775808", "bad"] {
                    try await client.execute(uri: "/api/v1/prompts/\(id)/revisions/\(rev)", method: .get, headers: PromptHTTPTest.headers(session)) {
                        try PromptHTTPTest.error($0, .failure(.malformedRequest))
                    }
                }
                for rev in [Int64(2), Int64.max] {
                    try await client.execute(uri: "/api/v1/prompts/\(id)/revisions/\(rev)", method: .get, headers: PromptHTTPTest.headers(session)) {
                        try PromptHTTPTest.error($0, .failure(.notFound))
                    }
                }
                #expect(try await fixture.persistence.count("prompt_revisions") == 1)
            }
        }
    }
}
