import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerPromptTransferValidationTests {
    @Test func deleteQueryMoveBodyAndBothRoutesEnforceWireAndSessionRules() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let group = try await fixture.group(owner: owner)
            let session = try await fixture.account.session(owner)
            let revoked = try await fixture.account.session(owner)
            try await fixture.account.sessions.logout(revoked.identity)
            let disabledUser = try await fixture.user("disabled")
            let disabled = try await fixture.account.session(disabledUser)
            try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at WHERE id = \(bind: disabledUser.id)")
            _ = try await fixture.writePrompt(session: session.identity)
            let id = GroupTestFixture.livePrompt
            let move = SyncAPI.MovePromptRequest(baseRev: 1, scope: .group(groupID: group.id), path: "Shared.md")
            let moveBody = try JSONEncoder().encode(move)
            let before = try await fixture.persistence.promptStorageState()
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                for headers: HTTPFields in [[:], [.authorization: "Bearer invalid"], PromptHTTPTest.headers(revoked), PromptHTTPTest.headers(disabled)] {
                    for (suffix, method) in [("?base_rev=1", HTTPRequest.Method.delete), ("/move", .post)] {
                        try await client.execute(uri: "/api/v1/prompts/\(id)\(suffix)", method: method, headers: headers,
                                                 body: method == .post ? .init(bytes: moveBody) : nil) {
                            try PromptHTTPTest.error($0, .failure(.unauthorized))
                            #expect($0.headers[.wwwAuthenticate] == "Bearer")
                        }
                    }
                }
                for badID in ["invalid", id.lowercased()] {
                    for (suffix, method) in [("?base_rev=1", HTTPRequest.Method.delete), ("/move", .post)] {
                        try await client.execute(uri: "/api/v1/prompts/\(badID)\(suffix)", method: method, headers: PromptHTTPTest.headers(session),
                                                 body: method == .post ? .init(bytes: moveBody) : nil) {
                            try PromptHTTPTest.error($0, .failure(.malformedRequest))
                        }
                    }
                }
                for query in ["", "?", "?other=1", "?base_rev=", "?base_rev=0", "?base_rev=-1", "?base_rev=+1",
                              "?base_rev=01", "?base_rev=1.0", "?base_rev=9223372036854775808", "?base_rev=bad",
                              "?base_rev=1&base_rev=1", "?base_rev=1&other=1", "?base_rev=%2B1"] {
                    try await client.execute(uri: "/api/v1/prompts/\(id)\(query)", method: .delete, headers: PromptHTTPTest.headers(session)) {
                        try PromptHTTPTest.error($0, .failure(.malformedRequest))
                    }
                }
                let bodies = [
                    "[]", "{}", "{\"base_rev\":0,\"scope\":\"user\",\"path\":\"Shared.md\"}",
                    "{\"base_rev\":1,\"scope\":\"group\",\"path\":\"Shared.md\"}",
                    "{\"base_rev\":1,\"scope\":\"user\",\"group_id\":\"\(group.id)\",\"path\":\"Shared.md\"}",
                    "{\"base_rev\":1,\"scope\":\"user\",\"path\":\"Shared.md\",\"owner_id\":\"\(owner.id)\"}",
                    "{\"base_rev\":1,\"scope\":\"user\",\"path\":\"Shared.md\",\"content\":\"forged\"}",
                    "{\"base_rev\":1,\"scope\":\"user\",\"path\":\"\"}",
                    "{\"base_rev\":1,\"scope\":\"user\",\"path\":\"\(String(repeating: "a", count: 1_025))\"}"
                ]
                for body in bodies {
                    try await client.execute(uri: "/api/v1/prompts/\(id)/move", method: .post, headers: PromptHTTPTest.headers(session),
                                             body: .init(bytes: body.utf8)) { try PromptHTTPTest.error($0, .failure(.malformedRequest)) }
                }
                try await client.execute(uri: "/api/v1/prompts/\(id)/move", method: .post, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: Data(repeating: 0x20, count: SyncAPI.requestEnvelopeMaxBytes + 1))) {
                    try PromptHTTPTest.error($0, .failure(.envelopeTooLarge))
                }
                let head = SyncAPI.ConflictHead(rev: 1, scope: .user, path: "Example.md", content: promptContent())
                var exact = try JSONEncoder().encode(SyncAPI.MovePromptRequest(baseRev: 99, scope: move.scope, path: move.path))
                exact.append(Data(repeating: 0x20, count: SyncAPI.requestEnvelopeMaxBytes - exact.count))
                try await client.execute(uri: "/api/v1/prompts/\(id)/move", method: .post, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: exact)) { try PromptHTTPTest.error($0, .conflict(head: head)) }
                try await client.execute(uri: "/api/v1/prompts/\(id)?base_rev=9223372036854775807", method: .delete, headers: PromptHTTPTest.headers(session)) {
                    try PromptHTTPTest.error($0, .conflict(head: head))
                }
                for (suffix, method) in [("?base_rev=1", HTTPRequest.Method.delete), ("/move", .post)] {
                    try await client.execute(uri: "/api/v1/prompts/\(GroupTestFixture.otherPrompt)\(suffix)", method: method,
                                             headers: PromptHTTPTest.headers(session), body: method == .post ? .init(bytes: moveBody) : nil) {
                        try PromptHTTPTest.error($0, .failure(.notFound))
                    }
                }
                #expect(try await fixture.persistence.promptStorageState() == before)
            }
        }
    }

    @Test func groupEntryCanonicalExpansionLeavesThePrivateHeadAndBothScopesUnchanged() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let group = try await fixture.group(owner: owner)
            let session = try await fixture.account.session(owner)
            let header = promptContent(metadata: "x: [a, b, c]\n", body: "")
            let source = header + String(repeating: "a", count: Limits.maxPromptBytes - header.utf8.count)
            _ = try await fixture.writePrompt(content: source, session: session.identity)
            let before = try await fixture.persistence.promptStorageState()
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                let move = SyncAPI.MovePromptRequest(baseRev: 1, scope: .group(groupID: group.id), path: "Shared.md")
                try await client.execute(uri: "/api/v1/prompts/\(GroupTestFixture.livePrompt)/move", method: .post,
                                         headers: PromptHTTPTest.headers(session), body: .init(bytes: JSONEncoder().encode(move))) {
                    try PromptHTTPTest.error($0, .validation(issues: [.init(code: PromptIssueCode.sourceTooLarge.rawValue, severity: .error)]))
                }
                #expect(try await fixture.persistence.promptStorageState() == before)
                #expect(try await fixture.prompts.get(id: GroupTestFixture.livePrompt, session: session.identity).content == source)
            }
        }
    }

    @Test(arguments: PromptTransferDirection.allCases)
    func staleRevisionsPrecedeTargetClashesAndScopeChangesStayOffPUT(direction: PromptTransferDirection) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            _ = try await fixture.group(owner: owner)
            _ = try await fixture.group(owner: owner, id: PersistenceTestRepository.otherGroup)
            let session = try await fixture.account.session(owner)
            let id = GroupTestFixture.livePrompt
            let existingID = GroupTestFixture.secondLivePrompt
            _ = try await fixture.writePrompt(scope: direction.sourceScope, session: session.identity)
            _ = try await fixture.writePrompt(id: existingID, scope: direction.destinationScope, path: "Straße/Café.md", session: session.identity)
            let before = try await fixture.persistence.promptStorageState()
            let conflict = SyncAPI.ErrorResponse.conflict(head: .init(rev: 1, scope: direction.sourceScope, path: "Example.md", content: promptContent()))
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                for path in ["STRASSE/Cafe\u{301}.md", "../invalid.md"] {
                    let request = SyncAPI.MovePromptRequest(baseRev: 99, scope: direction.destinationScope, path: path)
                    try await client.execute(uri: "/api/v1/prompts/\(id)/move", method: .post, headers: PromptHTTPTest.headers(session),
                                             body: .init(bytes: JSONEncoder().encode(request))) { try PromptHTTPTest.error($0, conflict) }
                }
                for rev: Int64 in [1, 99] {
                    let request = SyncAPI.MovePromptRequest(baseRev: rev, scope: .group(groupID: GroupTestFixture.otherPrompt), path: "Target.md")
                    try await client.execute(uri: "/api/v1/prompts/\(id)/move", method: .post, headers: PromptHTTPTest.headers(session),
                                             body: .init(bytes: JSONEncoder().encode(request))) {
                        try PromptHTTPTest.error($0, rev == 99 ? conflict : .failure(.notFound))
                    }
                }
                let collision = SyncAPI.MovePromptRequest(baseRev: 1, scope: direction.destinationScope, path: "STRASSE/Cafe\u{301}.md")
                try await client.execute(uri: "/api/v1/prompts/\(id)/move", method: .post, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(collision))) {
                    try PromptHTTPTest.error($0, .pathTaken(existing: .init(id: existingID, rev: 1, content: promptContent(id: existingID))))
                }
                try await client.execute(uri: "/api/v1/prompts/\(id)?base_rev=99", method: .delete, headers: PromptHTTPTest.headers(session)) {
                    try PromptHTTPTest.error($0, conflict)
                }
                let put = SyncAPI.PutPromptRequest(baseRev: 1, scope: direction.destinationScope, path: "Target.md", content: promptContent())
                try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(put))) { try PromptHTTPTest.error($0, conflict) }
                let same = SyncAPI.MovePromptRequest(baseRev: 1, scope: direction.sourceScope, path: "Rename.md")
                try await client.execute(uri: "/api/v1/prompts/\(id)/move", method: .post, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(same))) { try PromptHTTPTest.error($0, conflict) }
                #expect(try await fixture.persistence.promptStorageState() == before)
            }
            _ = try await fixture.prompts.delete(id: existingID, query: .init(baseRev: 1), session: session.identity)
            let moved = try await fixture.prompts.move(id: id, request: .init(baseRev: 1, scope: direction.destinationScope,
                                                                            path: "STRASSE/Cafe\u{301}.md"), session: session.identity)
            #expect(moved.rev == 2 && moved.seq == 5)
            #expect(try await fixture.prompts.get(id: id, session: session.identity).path == "STRASSE/Café.md")
            // Leaving a scope releases its path, just as tombstoning does.
            _ = try await fixture.writePrompt(id: GroupTestFixture.otherPrompt, scope: direction.sourceScope, path: "EXAMPLE.md", session: session.identity)
        }
    }

    @Test(arguments: PromptTransferDirection.allCases)
    func destinationUsesCorePathRulesAndGroupEntryAlwaysCanonicalizes(direction: PromptTransferDirection) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            _ = try await fixture.group(owner: owner)
            _ = try await fixture.group(owner: owner, id: PersistenceTestRepository.otherGroup)
            let session = try await fixture.account.session(owner)
            let source = promptContent(metadata: "favorite: true\nprivate: true\nx: [one, two]\n", body: "Keep body bytes\r\n")
            _ = try await fixture.writePrompt(scope: direction.sourceScope, content: source, session: session.identity)
            let stored = try await fixture.prompts.get(id: GroupTestFixture.livePrompt, session: session.identity).content
            let before = try await fixture.persistence.promptStorageState()
            var invalid = ["../Prompt.md", ".hidden/Prompt.md", "a//Prompt.md", "Prompt.txt", "a\\Prompt.md", "space /Prompt.md"]
            if direction.destinationScope == .user { invalid.append("gRoUpS/Prompt.md") }
            for path in invalid {
                let validatorScope: SyncPathValidator.Scope = direction.destinationScope == .user ? .user : .group
                do { _ = try SyncPathValidator.validate(path, scope: validatorScope); Issue.record("Expected invalid destination") }
                catch let issue as SyncPathIssue {
                    await #expect(throws: PromptError(.validation(issues: [.init(issue)]))) {
                        _ = try await fixture.prompts.move(id: GroupTestFixture.livePrompt,
                                                          request: .init(baseRev: 1, scope: direction.destinationScope, path: path), session: session.identity)
                    }
                }
            }
            #expect(try await fixture.persistence.promptStorageState() == before)
            let path = direction.destinationScope == .user ? "Conflicts/Cafe\u{301}.md" : "Groups/Cafe\u{301}.md"
            let write = try await fixture.prompts.move(id: GroupTestFixture.livePrompt,
                                                      request: .init(baseRev: 1, scope: direction.destinationScope, path: path), session: session.identity)
            let head = try await fixture.prompts.get(id: GroupTestFixture.livePrompt, session: session.identity)
            let canonical = try CanonicalForm.group(Data(stored.utf8), filename: "Café.md")
            #expect(head.content == (direction.destinationScope == .user ? stored : String(decoding: canonical.bytes, as: UTF8.self)))
            #expect(head.path == path.precomposedStringWithCanonicalMapping && head.rev == 2 && write.seq == 3)
            #expect(write.warnings == (canonical.warnings.isEmpty ? nil : canonical.warnings.map { SyncAPI.Issue($0) }))
            let record = try #require(await fixture.promptRepository.read { prompts, _, _, _ in try await prompts.head(id: head.id) })
            #expect(record.title == "Café")
        }
    }
}
