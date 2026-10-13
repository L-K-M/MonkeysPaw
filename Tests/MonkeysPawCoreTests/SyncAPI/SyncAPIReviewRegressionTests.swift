import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncAPIReviewRegressionTests: XCTestCase {
    private let id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    func testRetryAfterRejectsOutOfRangeSecondsAtConstruction() throws {
        for seconds: Int64 in [.min, -1, 0, 901, .max] {
            XCTAssertThrowsError(try SyncAPI.RetryAfter(seconds: seconds), String(seconds))
        }
        for seconds: Int64 in [1, 30, 900] {
            let dto = try SyncAPI.RetryAfter(seconds: seconds)
            XCTAssertEqual(dto.headerValue, String(seconds))
            XCTAssertEqual(try JSONDecoder().decode(SyncAPI.RetryAfter.self, from: JSONEncoder().encode(dto)), dto)
        }
    }

    func testObjectSchemasRejectDuplicateFieldNames() throws {
        let schema = SyncAPISchema.object(fields: [.init("name", .name), .init("name", .name)])
        XCTAssertThrowsError(try schema.validate(.object(["name": .string("Team")])))
    }

    func testEveryPromptIssueCodeMatchesItsSchemaSeverity() throws {
        let codes: [PromptIssueCode] = [
            .sourceTooLarge, .invalidUTF8, .unclosedFrontMatter, .invalidYAML,
            .frontMatterNotMapping, .duplicateKey, .anchorOrAlias, .mergeKey,
            .nonPortableScalar, .nonPortableTag, .invalidID, .invalidMetadataType,
            .groupPrivateRemoved, .invalidFormat, .unsupportedFormat, .invalidFieldName,
            .reservedFieldName, .invalidFieldDeclaration, .unknownFieldType, .invalidFieldProperty,
            .invalidFieldBoolean, .invalidFieldOptions, .invalidFieldDefault, .unusedField,
            .invalidPlaceholder, .unbalancedOpener
        ]
        XCTAssertEqual(Set(codes.map(\.rawValue)).count, 26)
        for code in codes {
            let issue = PromptIssue(code)
            let dto = SyncAPI.Issue(issue)
            switch issue.severity {
            case .warning: XCTAssertEqual(dto.severity, .warning, code.rawValue)
            case .error: XCTAssertEqual(dto.severity, .error, code.rawValue)
            }
            XCTAssertEqual(try JSONDecoder().decode(SyncAPI.Issue.self, from: JSONEncoder().encode(dto)), dto)
            let opposite: SyncAPI.Severity = dto.severity == .warning ? .error : .warning
            XCTAssertThrowsError(try JSONEncoder().encode(SyncAPI.Issue(code: code.rawValue, severity: opposite)), code.rawValue)
            print("Issue pairing: \(code.rawValue) = \(dto.severity.rawValue)")
        }
        XCTAssertEqual(SyncAPI.Severity.allCases.map(\.rawValue).sorted(), ["error", "warning"])
    }

    func testFeedPromptPreservesPathOnStandaloneAndNestedRoundTrips() throws {
        let prompt = SyncAPI.FeedPrompt(id: id, rev: .max, path: "Notes/Café.md", content: "body\r\n")
        let bytes = try JSONEncoder().encode(prompt)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["path"] as? String, prompt.path)
        XCTAssertEqual(try JSONDecoder().decode(SyncAPI.FeedPrompt.self, from: bytes), prompt)
        let item = SyncAPI.FeedItem.upsert(seq: .max, prompt: prompt)
        XCTAssertEqual(try JSONDecoder().decode(SyncAPI.FeedItem.self, from: JSONEncoder().encode(item)), item)
    }

    func testMixedErrorEnvelopesAreRejectedBeforeVariantDispatch() throws {
        let issue = SyncAPI.Issue(code: "yaml.invalid", severity: .error)
        let validation = SyncAPI.ErrorResponse.validation(issues: [issue])
        let conflict = SyncAPI.ErrorResponse.conflict(head: .init(rev: 1, scope: .user, path: "a.md", content: ""))
        for valid in [validation, conflict] {
            XCTAssertEqual(try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: JSONEncoder().encode(valid)), valid)
        }
        for code in ["conflict", "rate_limited", "unauthorized"] {
            for issues: APIValue in [.dtos([issue]), .null] {
                let mixed = APIValue.object(["code": .string(code), "issues": issues])
                XCTAssertThrowsError(try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: JSONEncoder().encode(mixed)))
            }
        }
        var mixed = conflict.object
        mixed["issues"] = .dtos([issue])
        XCTAssertThrowsError(try JSONDecoder().decode(SyncAPI.ErrorResponse.self, from: JSONEncoder().encode(APIValue.object(mixed))))
    }

    func testUserKeyIsValidatedBeforeItsPrefixIsRemoved() throws {
        let valid = SyncAPI.ScopeIdentity.user(userID: id)
        XCTAssertEqual(try JSONDecoder().decode(SyncAPI.ScopeIdentity.self, from: JSONEncoder().encode(valid)), valid)
        for key in ["", "user:", "group:" + id, "other" + id, "user:" + id.lowercased(), "user:" + id + "a"] {
            let value = APIValue.object(["kind": .string("user"), "key": .string(key)])
            let bytes = try JSONEncoder().encode(value)
            XCTAssertThrowsError(try JSONDecoder().decode(SyncAPI.ScopeIdentity.self, from: bytes), key)
            var nested = SyncAPI.SyncScope(identity: valid, mode: .delta, head: 0, cursor: "0", hasMore: false, items: []).object
            nested["key"] = .string(key)
            XCTAssertThrowsError(try JSONDecoder().decode(SyncAPI.SyncScope.self, from: JSONEncoder().encode(APIValue.object(nested))), key)
        }
    }

    func testRequiredNullableAndOptionalNonnullableFieldsStayDistinct() throws {
        for segment: Int64? in [nil, 0, 1] {
            let location = SyncAPI.IssueLocation.path(segment: segment)
            let bytes = try JSONEncoder().encode(location)
            XCTAssertEqual(try JSONDecoder().decode(SyncAPI.IssueLocation.self, from: bytes), location)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["kind", "segment"])
        }
        XCTAssertThrowsError(try JSONDecoder().decode(SyncAPI.IssueLocation.self, from: Data(#"{"kind":"path"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(SyncAPI.GroupInviteRequest.self, from: Data(#"{"role":"viewer","expires_in":null}"#.utf8)))
        let invite = try JSONDecoder().decode(SyncAPI.GroupInviteRequest.self, from: Data(#"{"role":"viewer"}"#.utf8))
        XCTAssertNil(invite.expiresIn)
        XCTAssertThrowsError(try JSONDecoder().decode(SyncAPI.PullRequest.self, from: Data(#"{"cursors":{}}"#.utf8)))
        let initial = SyncAPI.PullRequest(databaseID: nil, cursors: [:])
        XCTAssertEqual(try JSONDecoder().decode(SyncAPI.PullRequest.self, from: JSONEncoder().encode(initial)), initial)
    }

    func testCreateBaseRevDiffersIntentionallyFromDeleteAndMove() throws {
        let encoder = JSONEncoder()
        XCTAssertNoThrow(try encoder.encode(SyncAPI.PutPromptRequest(baseRev: 0, scope: .user, path: "a.md", content: "")))
        XCTAssertThrowsError(try encoder.encode(SyncAPI.PutPromptRequest(baseRev: -1, scope: .user, path: "a.md", content: "")))
        XCTAssertThrowsError(try encoder.encode(SyncAPI.DeletePromptQuery(baseRev: 0)))
        XCTAssertThrowsError(try encoder.encode(SyncAPI.MovePromptRequest(baseRev: 0, scope: .user, path: "a.md")))
        XCTAssertNoThrow(try encoder.encode(SyncAPI.DeletePromptQuery(baseRev: 1)))
        XCTAssertNoThrow(try encoder.encode(SyncAPI.MovePromptRequest(baseRev: 1, scope: .user, path: "a.md")))
    }

    func testPatternsKeepWholeStringMatchingUnderConcurrentValidation() throws {
        let constraints: [(SyncAPIString, String, String)] = [
            (.init(pattern: "^[a-z0-9][a-z0-9._-]{0,63}$"), "alice", "Alice"),
            (.init(pattern: "^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$"), String(repeating: "A", count: 43), String(repeating: "A", count: 43) + "\n"),
            (.init(pattern: "^user:[0-7][0-9A-HJKMNP-TV-Z]{25}$"), "user:" + id, "group:" + id)
        ]
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let (constraint, valid, invalid) = constraints[index % constraints.count]
            let accepted: Void? = try? constraint.validate(valid)
            let rejected: Void? = try? constraint.validate(invalid)
            XCTAssertNotNil(accepted)
            XCTAssertNil(rejected)
        }
        XCTAssertThrowsError(try SyncAPIString(pattern: "[").validate("alice"))
    }
}
