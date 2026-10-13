import Foundation
import XCTest
import MonkeysPawCore

final class SyncAPITests: XCTestCase {
    private let id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    func testTypedDTOsRoundTripWithoutLosingInt64Precision() throws {
        let prompt = SyncAPI.Prompt(id: id, rev: .max, scope: .group(groupID: id), path: "Café.md", content: "\u{feff}a\r\n\\{{name}}\n")
        let encoded = try JSONEncoder().encode(prompt)
        XCTAssertEqual(try JSONDecoder().decode(SyncAPI.Prompt.self, from: encoded), prompt)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("9223372036854775807"))
        requireSendable(prompt)
        requireSendable(SyncAPI.ErrorResponse.conflict(head: .init(rev: 1, scope: .user, path: "a.md", content: "")))
    }

    func testExplicitNullAndOmittedPatchMembersRemainDistinct() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let omitted = try decoder.decode(SyncAPI.UpdateUserRequest.self, from: Data("{\"disabled\":true}".utf8))
        let cleared = try decoder.decode(SyncAPI.UpdateUserRequest.self, from: Data("{\"display_name\":null}".utf8))
        XCTAssertEqual(omitted.displayName, .omitted)
        XCTAssertEqual(cleared.displayName, .null)
        XCTAssertEqual(try decoder.decode(SyncAPI.UpdateUserRequest.self, from: encoder.encode(omitted)), omitted)
        XCTAssertEqual(try decoder.decode(SyncAPI.UpdateUserRequest.self, from: encoder.encode(cleared)), cleared)
        let userScope = String(decoding: try encoder.encode(SyncAPI.PromptScope.user), as: UTF8.self)
        XCTAssertEqual(userScope, "{\"scope\":\"user\"}")
    }

    func testOpaqueCursorsAreNotParsedByDTOs() throws {
        for cursor in ["0", "snap:not-the-server-grammar", "opaque 🐒", "9223372036854775808"] {
            let request = SyncAPI.PullRequest(databaseID: nil, cursors: ["user:" + id: cursor])
            XCTAssertEqual(try JSONDecoder().decode(SyncAPI.PullRequest.self, from: JSONEncoder().encode(request)), request)
        }
        XCTAssertThrowsError(try JSONEncoder().encode(SyncAPI.PullRequest(databaseID: nil, cursors: ["user:" + id: ""])))
    }

    func testConstructedInvalidValuesCannotBeEncoded() throws {
        let encoder = JSONEncoder()
        XCTAssertThrowsError(try encoder.encode(SyncAPI.LoginRequest(username: "Alice", password: "x", deviceName: "Desktop")))
        XCTAssertThrowsError(try encoder.encode(SyncAPI.Prompt(id: id.lowercased(), rev: 1, scope: .user, path: "a.md", content: "")))
        XCTAssertThrowsError(try encoder.encode(SyncAPI.WriteResponse(rev: 0, seq: 1)))
        XCTAssertThrowsError(try encoder.encode(SyncAPI.GroupInviteRequest(role: .viewer, expiresIn: 604_801)))
        XCTAssertThrowsError(try encoder.encode(SyncAPI.ErrorResponse.validation(issues: [.init(code: "field.unused", severity: .warning)])))
        XCTAssertThrowsError(try encoder.encode(SyncAPI.WriteResponse(rev: 1, seq: 1, warnings: [.init(code: "yaml.invalid", severity: .error)])))
        XCTAssertThrowsError(try encoder.encode(SyncAPI.UpdateUserRequest()))
    }

    func testContentLimitUsesUTF8BytesAndLeaves422ValidationToServices() throws {
        let encoder = JSONEncoder()
        let maximum = String(repeating: "é", count: Limits.maxPromptBytes / 2)
        let valid = SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "../invalid.MD", content: maximum)
        XCTAssertNoThrow(try encoder.encode(valid))
        XCTAssertThrowsError(try encoder.encode(SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "a.md", content: maximum + "é")))
        // DTOs accept content/path strings before the shared semantic validators
        // produce 422 issues, rather than turning their errors into malformed JSON.
        let request = SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "../invalid.MD", content: "invalid YAML")
        XCTAssertNoThrow(try encoder.encode(request))
    }

    func testPasswordByteLimitAppliesToEveryCredentialField() throws {
        let encoder = JSONEncoder()
        for password in [String(repeating: "a", count: 72), String(repeating: "é", count: 36)] {
            XCTAssertEqual(password.utf8.count, 72)
            for dto in credentialDTOs(password: password) {
                XCTAssertNoThrow(try encoder.encode(dto), type(of: dto).schemaName)
            }
            let oversized = password + "a"
            XCTAssertEqual(oversized.utf8.count, 73)
            for dto in credentialDTOs(password: oversized) {
                XCTAssertThrowsError(try encoder.encode(dto), type(of: dto).schemaName)
            }
        }
    }

    func testPathBoundsUseUTF8BytesWithoutApplyingSemanticRules() throws {
        let encoder = JSONEncoder()
        for path in [String(repeating: "a", count: Limits.maxPathBytes),
                     String(repeating: "é", count: Limits.maxPathBytes / 2)] {
            let request = SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: path, content: "")
            XCTAssertNoThrow(try encoder.encode(request))
            let oversized = SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: path + "a", content: "")
            XCTAssertThrowsError(try encoder.encode(oversized))
        }
        XCTAssertThrowsError(try encoder.encode(SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "", content: "")))
    }

    func testPullBudgetIsSharedAcrossScopes() throws {
        let item = SyncAPI.FeedItem.delete(seq: 1, id: id)
        let privateScope = SyncAPI.SyncScope(identity: .user(userID: id), mode: .delta, head: 1, cursor: "1", hasMore: true, items: Array(repeating: item, count: 100))
        let groupScope = SyncAPI.SyncScope(identity: .group(groupID: id, name: "Team", role: .viewer), mode: .delta, head: 1, cursor: "1", hasMore: true, items: Array(repeating: item, count: 101))
        let response = SyncAPI.PullResponse(databaseID: "92b192ab-a06f-4d6d-a21a-13c7756b3e6e", scopes: [privateScope, groupScope], removed: [])
        XCTAssertThrowsError(try JSONEncoder().encode(response))
        let boundary = SyncAPI.SyncScope(identity: groupScope.identity, mode: .delta, head: 1, cursor: "1", hasMore: true, items: Array(repeating: item, count: 100))
        XCTAssertNoThrow(try JSONEncoder().encode(SyncAPI.PullResponse(databaseID: response.databaseID, scopes: [privateScope, boundary], removed: [])))
    }

    func testIssueMappingPreservesCoordinatesAndSanitizedCodes() throws {
        let document = PromptCodec.parse("---\nfields:\n  unused:\n    type: text\n---\n{{bad name}}", filename: "a.md")
        XCTAssertFalse(document.issues.isEmpty)
        for issue in document.issues {
            let dto = SyncAPI.Issue(issue)
            XCTAssertEqual(dto.code, issue.code.rawValue)
            XCTAssertEqual(dto.severity.rawValue, issue.severity.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(SyncAPI.Issue.self, from: JSONEncoder().encode(dto)), dto)
        }
        do {
            _ = try SyncPathValidator.validate("a/../b.md", scope: .user)
            XCTFail("Expected invalid path")
        } catch let issue as SyncPathIssue {
            let dto = SyncAPI.Issue(issue)
            XCTAssertEqual(dto.location, .path(segment: 1))
            XCTAssertEqual(dto.severity, .error)
        }
    }

    func testRetryAfterIsAnHTTPSecondsHeader() throws {
        for seconds: Int64 in [1, 30, 900] {
            let dto = try SyncAPI.RetryAfter(headerValue: String(seconds))
            XCTAssertEqual(dto.seconds, seconds)
            XCTAssertEqual(dto.headerValue, String(seconds))
        }
        for invalid in ["0", "901", "-1", "030", "+30", "30.0", " 30", "Mon, 12 Oct 2026 20:10:56 GMT"] {
            XCTAssertThrowsError(try SyncAPI.RetryAfter(headerValue: invalid), invalid)
        }
        XCTAssertEqual(SyncAPI.rateLimitHeaders.map(\.name), ["Retry-After"])
    }

    func testEveryRouteHasResolvableRequestResponseAndParameterSchemas() throws {
        let names = Set(SyncAPI.schemas.map(\.name))
        XCTAssertEqual(names.count, SyncAPI.schemas.count)
        XCTAssertEqual(SyncAPI.endpoints.count, 25)
        XCTAssertEqual(Set(SyncAPI.endpoints.map { $0.method + " " + $0.path }).count, 25)
        for route in SyncAPI.endpoints {
            for name in [route.requestBody, route.pathParameters, route.query, route.responseBody].compactMap({ $0 }) {
                XCTAssertTrue(names.contains(name), name)
            }
            XCTAssertEqual(route.successStatus, 200)
        }
        XCTAssertEqual(SyncAPI.schemaDialect, "https://json-schema.org/draft/2020-12/schema")
        XCTAssertEqual(SyncAPI.requestEnvelopeMaxBytes, 2_097_152)
        XCTAssertEqual(SyncAPI.responseEnvelopeMaxBytes, 16_777_216)
    }

    private func credentialDTOs(password: String) -> [any SyncAPIDTO] {
        [
            SyncAPI.LoginRequest(username: "alice", password: password, deviceName: "Desktop"),
            SyncAPI.RegisterRequest(inviteToken: String(repeating: "A", count: 43), username: "alice", password: password, deviceName: "Desktop"),
            SyncAPI.CreateUserRequest(username: "alice", password: password),
            SyncAPI.UpdateUserRequest(password: password),
            SyncAPI.PasswordChangeRequest(currentPassword: password, newPassword: "long-enough-password"),
            SyncAPI.PasswordChangeRequest(currentPassword: "x", newPassword: password)
        ]
    }

    private func requireSendable<T: Sendable>(_ value: T) {}
}
