import Foundation
import Hummingbird
import HummingbirdTesting
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerPromptValidationTests {
    @Test func invalidPathsReturnCoreIssuesAndLeaveStorageUntouched() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let session = try await fixture.account.session(owner)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            let cases: [(String, SyncPathIssueCode, Int64?)] = [
                ("/Example.md", .absolutePath, nil), ("../Example.md", .dotSegment, 0),
                (".hidden/Example.md", .hiddenDirectory, 0), ("a//Example.md", .emptySegment, 1),
                ("a\\Example.md", .backslash, 0), ("a\u{0}/Example.md", .controlCharacter, 0),
                ("a /Example.md", .trailingDotOrSpace, 0), ("a./Example.md", .trailingDotOrSpace, 0),
                (String(repeating: "x", count: 256) + ".md", .segmentTooLong, 0),
                ("Example.MD", .invalidExtension, nil), ("gRoUpS/Example.md", .reservedGroupsPrefix, nil)
            ]
            let before = try await fixture.persistence.promptStorageState()
            try await app.test(.router) { client in
                for (path, code, segment) in cases {
                    let request = SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: path, content: promptContent())
                    try await client.execute(uri: "/api/v1/prompts/\(GroupTestFixture.livePrompt)", method: .put, headers: PromptHTTPTest.headers(session),
                                             body: .init(bytes: JSONEncoder().encode(request))) {
                        try PromptHTTPTest.error($0, .validation(issues: [.init(code: code.rawValue, severity: .error, location: .path(segment: segment))]))
                    }
                }
                #expect(try await fixture.persistence.promptStorageState() == before)
            }
        }
    }

    @Test(arguments: PromptTestScope.allCases)
    func invalidContentAndURLIdentityReturnOnlyErrorIssues(scopeKind: PromptTestScope) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let group = try await fixture.group(owner: owner)
            let session = try await fixture.account.session(owner)
            let scope = scopeKind.wire(groupID: group.id)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            let cases: [(String, String)] = [
                ("No front matter\n", "prompt.id_mismatch"),
                (promptContent(id: GroupTestFixture.secondLivePrompt), "prompt.id_mismatch"),
                ("---\nid: invalid\n---\nBody\n", PromptIssueCode.invalidID.rawValue),
                (promptContent(metadata: "title: [broken\n"), PromptIssueCode.invalidYAML.rawValue),
                (promptContent(metadata: "format: 99\n"), PromptIssueCode.unsupportedFormat.rawValue),
                (promptContent(metadata: "title: 42\n"), PromptIssueCode.invalidMetadataType.rawValue),
                (promptContent(metadata: "x: &value hello\ny: *value\n"), PromptIssueCode.anchorOrAlias.rawValue),
                (promptContent(metadata: "fields:\n  field:\n    type: unknown\n", body: "{{field}}\n"), PromptIssueCode.unknownFieldType.rawValue),
                (promptContent(body: "é {{unclosed\n"), PromptIssueCode.unbalancedOpener.rawValue)
            ]
            let before = try await fixture.persistence.promptStorageState()
            try await app.test(.router) { client in
                for (content, code) in cases {
                    let request = SyncAPI.PutPromptRequest(baseRev: 0, scope: scope, path: "Example.md", content: content)
                    try await client.execute(uri: "/api/v1/prompts/\(GroupTestFixture.livePrompt)", method: .put, headers: PromptHTTPTest.headers(session),
                                             body: .init(bytes: JSONEncoder().encode(request))) {
                        #expect($0.status == .unprocessableContent)
                        let error = try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: Data($0.body.readableBytesView))
                        guard case .validation(let issues) = error else { Issue.record("Expected validation issues"); return }
                        #expect(issues.contains { $0.code == code })
                        #expect(issues.allSatisfy { $0.severity == .error })
                        if code == PromptIssueCode.unbalancedOpener.rawValue {
                            #expect(issues.first?.location == .body(byteOffset: 3))
                        }
                    }
                }
                #expect(try await fixture.persistence.promptStorageState() == before)
                // Failed edits preserve the live head, earlier history and immutable event.
                _ = try await fixture.writePrompt(scope: scope, session: session.identity)
                let validState = try await fixture.persistence.promptStorageState()
                let edit = SyncAPI.PutPromptRequest(baseRev: 1, scope: scope, path: "Renamed.md", content: promptContent(id: GroupTestFixture.secondLivePrompt))
                try await client.execute(uri: "/api/v1/prompts/\(GroupTestFixture.livePrompt)", method: .put, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: JSONEncoder().encode(edit))) {
                    try PromptHTTPTest.error($0, .validation(issues: [.init(code: "prompt.id_mismatch", severity: .error)]))
                }
                #expect(try await fixture.persistence.promptStorageState() == validState)
            }
        }
    }

    @Test func warningsCanonicalizationNormalizedPathsAndTitleExtraction() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let group = try await fixture.group(owner: owner)
            let session = try await fixture.account.session(owner)
            let source = promptContent(metadata: "# preserved privately\ntitle: 'Shared'\nfavorite: true\nprivate: true\nfields:\n  unused:\n    type: text\nx: [a, b]\n", body: "Body {{123}}.\r\n")
            let canonical = try CanonicalForm.group(Data(source.utf8), filename: "Café.md")
            let privateWrite = try await fixture.writePrompt(path: "Cafe\u{301}.md", content: source, session: session.identity)
            let validatorWarnings = PromptValidator.validate(PromptCodec.parse(source, filename: "Café.md"))
                .filter { $0.severity == .warning }.map { SyncAPI.Issue($0) }
            #expect(privateWrite.warnings == validatorWarnings)
            #expect(Set(validatorWarnings.map(\.code)) == Set([PromptIssueCode.unusedField.rawValue, PromptIssueCode.invalidPlaceholder.rawValue]))
            let privateHead = try #require(await fixture.promptRepository.read { prompts, _, _, _ in try await prompts.head(id: GroupTestFixture.livePrompt) })
            #expect(privateHead.path == "Café.md")
            #expect(privateHead.pathKey == "café.md")
            #expect(privateHead.content == source)
            #expect(privateHead.title == "Shared")
            let scope = SyncAPI.PromptScope.group(groupID: group.id)
            let id = GroupTestFixture.secondLivePrompt
            let groupSource = source.replacingOccurrences(of: GroupTestFixture.livePrompt, with: id)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                let body = try JSONEncoder().encode(SyncAPI.PutPromptRequest(baseRev: 0, scope: scope, path: "Cafe\u{301}.md", content: groupSource))
                try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session), body: .init(bytes: body)) {
                    let write = try PromptHTTPTest.success($0, as: SyncAPI.WriteResponse.self)
                    #expect(write.rev == 1)
                    #expect(write.warnings == canonical.warnings.map { SyncAPI.Issue($0) })
                    #expect(write.warnings?.allSatisfy { $0.severity == .warning } == true)
                }
                let head = try await fixture.prompts.get(id: id, session: session.identity)
                let expected = try CanonicalForm.group(Data(groupSource.utf8), filename: "Café.md")
                #expect(head.content == String(decoding: expected.bytes, as: UTF8.self))
                #expect(head.path == "Café.md")
                let doc = PromptCodec.parse(head.content, filename: "Café.md")
                #expect(!doc.frontMatter.favorite)
                #expect(!doc.frontMatter.isPrivate)
                #expect(doc.body == "Body {{123}}.\r\n")
                // Reserved Groups is a private restriction; fallback title uses the basename.
                let thirdID = GroupTestFixture.otherPrompt
                _ = try await fixture.writePrompt(id: thirdID, scope: scope, path: "Groups/Fallback.md",
                                                 content: promptContent(id: thirdID, metadata: ""), session: session.identity)
                let fallback = try #require(await fixture.promptRepository.read { prompts, _, _, _ in try await prompts.head(id: thirdID) })
                #expect(fallback.title == "Fallback")
            }
        }
    }

    @Test func decodedContentAndEnvelopeCapsHaveIndependentExactBoundaries() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let session = try await fixture.account.session(owner)
            let id = GroupTestFixture.livePrompt
            let prefix = promptContent(body: "")
            let remaining = Limits.maxPromptBytes - prefix.utf8.count
            let exact = prefix + String(repeating: "é", count: remaining / 2) + (remaining % 2 == 1 ? "x" : "")
            #expect(exact.utf8.count == Limits.maxPromptBytes && exact.unicodeScalars.count < Limits.maxPromptBytes)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                let body = try JSONEncoder().encode(SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "Exact.md", content: exact))
                try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session), body: .init(bytes: body)) {
                    let write = try PromptHTTPTest.success($0, as: SyncAPI.WriteResponse.self)
                    #expect(write.rev == 1)
                }
                #expect(try await fixture.prompts.get(id: id, session: session.identity).content == exact)
                let before = try await fixture.persistence.promptStorageState()
                let overflow = try JSONSerialization.data(withJSONObject: ["base_rev": 1, "scope": "user", "path": "Exact.md", "content": exact + "x"])
                try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session), body: .init(bytes: overflow)) {
                    try PromptHTTPTest.error($0, .failure(.malformedRequest))
                }
                #expect(try await fixture.persistence.promptStorageState() == before)
                let secondID = GroupTestFixture.secondLivePrompt
                let valid = try JSONEncoder().encode(SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "Envelope.md",
                                                                            content: promptContent(id: secondID, body: String(repeating: "\t\n", count: 1_000))))
                let exactEnvelope = valid + Data(repeating: 32, count: SyncAPI.requestEnvelopeMaxBytes - valid.count)
                try await client.execute(uri: "/api/v1/prompts/\(secondID)", method: .put, headers: PromptHTTPTest.headers(session), body: .init(bytes: exactEnvelope)) {
                    let write = try PromptHTTPTest.success($0, as: SyncAPI.WriteResponse.self)
                    #expect(write.rev == 1)
                }
                let accepted = try await fixture.persistence.promptStorageState()
                try await client.execute(uri: "/api/v1/prompts/\(secondID)", method: .put, headers: PromptHTTPTest.headers(session),
                                         body: .init(bytes: exactEnvelope + Data([32]))) { try PromptHTTPTest.error($0, .failure(.envelopeTooLarge)) }
                #expect(try await fixture.persistence.promptStorageState() == accepted)
            }
        }
    }

    @Test func canonicalExpansionCannotExceedTheStoredContentCap() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let group = try await fixture.group(owner: owner)
            let session = try await fixture.account.session(owner)
            let header = promptContent(metadata: "x: [a, b, c]\n", body: "")
            let source = header + String(repeating: "a", count: Limits.maxPromptBytes - header.utf8.count)
            #expect(source.utf8.count == Limits.maxPromptBytes)
            let scope = SyncAPI.PromptScope.group(groupID: group.id)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            let before = try await fixture.persistence.promptStorageState()
            try await app.test(.router) { client in
                let body = try JSONEncoder().encode(SyncAPI.PutPromptRequest(baseRev: 0, scope: scope, path: "Example.md", content: source))
                try await client.execute(uri: "/api/v1/prompts/\(GroupTestFixture.livePrompt)", method: .put, headers: PromptHTTPTest.headers(session), body: .init(bytes: body)) {
                    try PromptHTTPTest.error($0, .validation(issues: [.init(code: PromptIssueCode.sourceTooLarge.rawValue, severity: .error)]))
                }
                #expect(try await fixture.persistence.promptStorageState() == before)
                _ = try await fixture.writePrompt(content: source, session: session.identity)
                #expect(try await fixture.prompts.get(id: GroupTestFixture.livePrompt, session: session.identity).content == source)
            }
        }
    }

    @Test func strictBodiesAndPathByteBoundsUseThePinnedS1Contract() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let session = try await fixture.account.session(owner)
            let id = GroupTestFixture.livePrompt
            let quoted = String(decoding: try JSONEncoder().encode(promptContent()), as: UTF8.self)
            let app = makeApplication(configuration: try .init(environment: [:]), accounts: fixture.account.accounts, sessions: fixture.account.sessions)
            try await app.test(.router) { client in
                for body in ["{", "{}", """
                    {"base_rev":-1,"scope":"user","path":"Example.md","content":\(quoted)}
                    """, """
                    {"base_rev":0,"scope":"group","path":"Example.md","content":\(quoted)}
                    """, """
                    {"base_rev":0,"scope":"user","group_id":"\(PersistenceTestRepository.group)","path":"Example.md","content":\(quoted)}
                    """, """
                    {"base_rev":0,"scope":"user","path":"Example.md","content":\(quoted),"extra":1}
                    """, """
                    {"base_rev":0,"scope":"user","path":"Example.md","content":\(quoted),"origin":"delete"}
                    """] {
                    try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session), body: .init(string: body)) {
                        try PromptHTTPTest.error($0, .failure(.malformedRequest))
                    }
                }
                let exactPath = [String(repeating: "x", count: 255), String(repeating: "x", count: 255),
                                 String(repeating: "x", count: 255), String(repeating: "x", count: 251), "p.md"].joined(separator: "/")
                #expect(exactPath.utf8.count == Limits.maxPathBytes)
                for path in ["", exactPath + "x"] {
                    let body = try JSONSerialization.data(withJSONObject: ["base_rev": 0, "scope": "user", "path": path, "content": promptContent()])
                    try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session), body: .init(bytes: body)) {
                        try PromptHTTPTest.error($0, .failure(.malformedRequest))
                    }
                }
                let body = try JSONEncoder().encode(SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: exactPath, content: promptContent()))
                try await client.execute(uri: "/api/v1/prompts/\(id)", method: .put, headers: PromptHTTPTest.headers(session), body: .init(bytes: body)) {
                    let write = try PromptHTTPTest.success($0, as: SyncAPI.WriteResponse.self)
                    #expect(write.rev == 1)
                }
                #expect(try await fixture.persistence.count("prompts") == 1)
            }
        }
    }
}
