import Foundation
import XCTest
@testable import MonkeysPawCore

/// Owns DTO corpus strictness; the generic dispatcher delegates and accounts
/// for the returned files rather than treating these as prompt envelopes.
enum DTOFixtureCorpus {
    enum Failure: Error { case invalidCorpus, invalidFixture(String) }

    private struct Outcome {
        let bytes: Data
        let status: Int?
        let headerValue: String?
    }

    private static func reader<T: SyncAPIDTO>(_ type: T.Type) -> (Data) throws -> Outcome {
        { data in
            let dto = try JSONDecoder().decode(type, from: data)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return Outcome(bytes: try encoder.encode(dto), status: (dto as? SyncAPI.ErrorResponse)?.httpStatus,
                           headerValue: (dto as? SyncAPI.RetryAfter)?.headerValue)
        }
    }

    private static let readers: [String: (Data) throws -> Outcome] = {
        return [
            SyncAPI.HealthResponse.schemaName: reader(SyncAPI.HealthResponse.self),
            SyncAPI.EmptyResponse.schemaName: reader(SyncAPI.EmptyResponse.self),
            SyncAPI.IDPath.schemaName: reader(SyncAPI.IDPath.self),
            SyncAPI.MemberPath.schemaName: reader(SyncAPI.MemberPath.self),
            SyncAPI.RevisionPath.schemaName: reader(SyncAPI.RevisionPath.self),
            SyncAPI.LoginRequest.schemaName: reader(SyncAPI.LoginRequest.self),
            SyncAPI.RegisterRequest.schemaName: reader(SyncAPI.RegisterRequest.self),
            SyncAPI.PasswordChangeRequest.schemaName: reader(SyncAPI.PasswordChangeRequest.self),
            SyncAPI.User.schemaName: reader(SyncAPI.User.self),
            SyncAPI.AuthResponse.schemaName: reader(SyncAPI.AuthResponse.self),
            SyncAPI.Device.schemaName: reader(SyncAPI.Device.self),
            SyncAPI.MeResponse.schemaName: reader(SyncAPI.MeResponse.self),
            SyncAPI.CreateUserRequest.schemaName: reader(SyncAPI.CreateUserRequest.self),
            SyncAPI.UpdateUserRequest.schemaName: reader(SyncAPI.UpdateUserRequest.self),
            SyncAPI.FailureCode.schemaName: reader(SyncAPI.FailureCode.self),
            SyncAPI.ErrorResponse.schemaName: reader(SyncAPI.ErrorResponse.self),
            SyncAPI.RetryAfter.schemaName: reader(SyncAPI.RetryAfter.self),
            SyncAPI.PullRequest.schemaName: reader(SyncAPI.PullRequest.self),
            SyncAPI.FeedItem.schemaName: reader(SyncAPI.FeedItem.self),
            SyncAPI.ScopeIdentity.schemaName: reader(SyncAPI.ScopeIdentity.self),
            SyncAPI.SyncScope.schemaName: reader(SyncAPI.SyncScope.self),
            SyncAPI.PullResponse.schemaName: reader(SyncAPI.PullResponse.self),
            SyncAPI.Group.schemaName: reader(SyncAPI.Group.self),
            SyncAPI.GroupMembership.schemaName: reader(SyncAPI.GroupMembership.self),
            SyncAPI.CreateGroupRequest.schemaName: reader(SyncAPI.CreateGroupRequest.self),
            SyncAPI.RenameGroupRequest.schemaName: reader(SyncAPI.RenameGroupRequest.self),
            SyncAPI.Member.schemaName: reader(SyncAPI.Member.self),
            SyncAPI.MembersResponse.schemaName: reader(SyncAPI.MembersResponse.self),
            SyncAPI.MembershipRequest.schemaName: reader(SyncAPI.MembershipRequest.self),
            SyncAPI.GroupInviteRequest.schemaName: reader(SyncAPI.GroupInviteRequest.self),
            SyncAPI.JoinGroupRequest.schemaName: reader(SyncAPI.JoinGroupRequest.self),
            SyncAPI.AdminInviteRequest.schemaName: reader(SyncAPI.AdminInviteRequest.self),
            SyncAPI.InviteResponse.schemaName: reader(SyncAPI.InviteResponse.self),
            SyncAPI.IssueLocation.schemaName: reader(SyncAPI.IssueLocation.self),
            SyncAPI.Issue.schemaName: reader(SyncAPI.Issue.self),
            SyncAPI.Prompt.schemaName: reader(SyncAPI.Prompt.self),
            SyncAPI.PutPromptRequest.schemaName: reader(SyncAPI.PutPromptRequest.self),
            SyncAPI.DeletePromptQuery.schemaName: reader(SyncAPI.DeletePromptQuery.self),
            SyncAPI.MovePromptRequest.schemaName: reader(SyncAPI.MovePromptRequest.self),
            SyncAPI.WriteResponse.schemaName: reader(SyncAPI.WriteResponse.self),
            SyncAPI.ConflictHead.schemaName: reader(SyncAPI.ConflictHead.self),
            SyncAPI.ExistingPrompt.schemaName: reader(SyncAPI.ExistingPrompt.self),
            SyncAPI.RevisionSummary.schemaName: reader(SyncAPI.RevisionSummary.self),
            SyncAPI.RevisionsResponse.schemaName: reader(SyncAPI.RevisionsResponse.self),
            SyncAPI.Revision.schemaName: reader(SyncAPI.Revision.self),
            SyncAPI.FeedPrompt.schemaName: reader(SyncAPI.FeedPrompt.self),
            SyncAPI.AccountKind.schemaName: reader(SyncAPI.AccountKind.self),
            SyncAPI.Role.schemaName: reader(SyncAPI.Role.self),
            SyncAPI.InviteRole.schemaName: reader(SyncAPI.InviteRole.self),
            SyncAPI.WriteOrigin.schemaName: reader(SyncAPI.WriteOrigin.self),
            SyncAPI.RevisionOrigin.schemaName: reader(SyncAPI.RevisionOrigin.self),
            SyncAPI.Mode.schemaName: reader(SyncAPI.Mode.self),
            SyncAPI.Severity.schemaName: reader(SyncAPI.Severity.self),
            SyncAPI.PromptScope.schemaName: reader(SyncAPI.PromptScope.self),
            SyncAPI.ProviderSettingsDocument.schemaName: reader(SyncAPI.ProviderSettingsDocument.self),
            SyncAPI.PutProviderSettingsRequest.schemaName: reader(SyncAPI.PutProviderSettingsRequest.self),
            SyncAPI.ProviderSettingsResponse.schemaName: reader(SyncAPI.ProviderSettingsResponse.self)
        ]
    }()

    static func consume(at root: URL) throws -> (cases: Int, files: [String]) {
        try require(.typeDirectory, at: root)
        let names = try visibleNames(root)
        guard !names.isEmpty, Set(readers.keys) == Set(SyncAPI.schemas.map(\.name)) else { throw Failure.invalidCorpus }
        var consumed = [String](), validDTOs = Set<String>(), invalidDTOs = Set<String>()
        for name in names {
            let directory = root.appendingPathComponent(name)
            try require(.typeDirectory, at: directory)
            let files = try visibleNames(directory)
            for file in files { try require(.typeRegular, at: directory.appendingPathComponent(file)) }
            guard files.contains("case.json") else { throw Failure.invalidCorpus }
            let envelope = try object(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("case.json"))))
            try keys(envelope, ["schema", "category", "dto", "source", "expected"])
            guard let schema = envelope["schema"] as? NSNumber, String(cString: schema.objCType) != "c", schema.doubleValue == 1,
                  envelope["category"] as? String == "dto", let dto = envelope["dto"] as? String, let read = readers[dto] else {
                throw Failure.invalidCorpus
            }
            let source = try sourceName(envelope["source"])
            guard Set(files.map { RelativePath($0) }) == Set(["case.json", source].map { RelativePath($0) }) else { throw Failure.invalidCorpus }
            let expected = try object(envelope["expected"])
            let valid = try boolean(expected["valid"])
            var expectedKeys: Set<String> = ["valid"]
            if valid && dto == "ErrorResponse" { expectedKeys.insert("http_status") }
            if valid && dto == "RetryAfter" { expectedKeys.insert("header_value") }
            try keys(expected, expectedKeys)
            let data = try Data(contentsOf: directory.appendingPathComponent(source))
            var outcome: Outcome?
            do {
                outcome = try read(data)
            } catch is DecodingError {
                guard !valid else { throw Failure.invalidFixture(name) }
            }
            if valid {
                guard let outcome, outcome.bytes == data else { throw Failure.invalidFixture(name) }
                if let status = outcome.status {
                    guard let number = expected["http_status"] as? NSNumber, String(cString: number.objCType) != "c",
                          number.doubleValue == Double(status) else { throw Failure.invalidFixture(name) }
                }
                if let header = outcome.headerValue {
                    guard expected["header_value"] as? String == header else { throw Failure.invalidFixture(name) }
                }
                validDTOs.insert(dto)
            } else {
                guard outcome == nil else { throw Failure.invalidFixture(name) }
                invalidDTOs.insert(dto)
            }
            consumed += ["case.json", source].map { name + "/" + $0 }
        }
        guard validDTOs == Set(readers.keys), invalidDTOs == Set(readers.keys),
              Set(consumed.map { RelativePath($0) }).count == consumed.count else { throw Failure.invalidCorpus }
        return (names.count, consumed)
    }

    private static func visibleNames(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    private static func object(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw Failure.invalidCorpus }
        return value
    }

    private static func keys(_ object: [String: Any], _ required: Set<String>) throws {
        guard Set(object.keys) == required else { throw Failure.invalidCorpus }
    }

    private static func boolean(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else { throw Failure.invalidCorpus }
        return number.boolValue
    }

    private static func sourceName(_ value: Any?) throws -> String {
        guard let value = value as? String, !value.hasPrefix("."), value != "case.json", value.hasSuffix(".json"),
              !value.contains("/"), !value.contains("\\") else { throw Failure.invalidCorpus }
        return value
    }

    private static func require(_ type: FileAttributeType, at url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == type else {
            throw Failure.invalidCorpus
        }
    }
}

final class DTOConformanceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/dto")
    }

    func testEveryPortableDTOFixture() throws {
        let result = try DTOFixtureCorpus.consume(at: root)
        XCTAssertGreaterThan(result.cases, 0)
        XCTAssertEqual(result.files.count, result.cases * 2)
        print("Consumed \(result.cases) DTO fixtures (\(result.files.count) files).")
    }

    func testInviteFixturesMatchExactlyOneClosedBranch() throws {
        let schemas = [SyncAPI.AdminInviteRequest.schemaName: SyncAPI.AdminInviteRequest.schema,
                       SyncAPI.InviteResponse.schemaName: SyncAPI.InviteResponse.schema]
        var acceptedTargets = [String: Set<String>]()
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path).filter({ !$0.hasPrefix(".") }).sorted() {
            let directory = root.appendingPathComponent(name)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("case.json"))) as? [String: Any])
            let dto = try XCTUnwrap(envelope["dto"] as? String)
            guard let schema = schemas[dto], case .oneOf(let branches) = schema else { continue }
            let expected = try XCTUnwrap(envelope["expected"] as? [String: Any])
            let valid = try XCTUnwrap(expected["valid"] as? Bool)
            let bytes = try Data(contentsOf: directory.appendingPathComponent("body.json"))
            let value: APIValue
            do { value = try JSONDecoder().decode(APIValue.self, from: bytes) } catch is DecodingError {
                XCTAssertFalse(valid, name)
                continue
            }
            let matches = branches.filter { (try? $0.validate(value)) != nil }.count
            XCTAssertEqual(matches, valid ? 1 : 0, name)
            for (index, branch) in branches.enumerated() {
                guard case .object(let fields, _, _) = branch else { return XCTFail("Invite branch must be a closed object") }
                let required = Set(fields.filter(\.required).map(\.name))
                XCTAssertEqual(required.contains("group_id"), index == 1)
                XCTAssertEqual(required.contains("role"), index == 1)
                if index == 0 { XCTAssertFalse(fields.contains { ["group_id", "role"].contains($0.name) }) }
            }
            if valid, case .object(let object) = value {
                acceptedTargets[dto, default: []].insert(object["group_id"] == nil ? "account" : "group")
            }
            print("Invite branch matches: \(name) = \(matches)")
        }
        for dto in schemas.keys { XCTAssertEqual(acceptedTargets[dto], ["account", "group"]) }
    }

    func testBoundaryFixtureNamesPinExactScalarAndByteCounts() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path).filter({ !$0.hasPrefix(".") }).sorted() {
            guard let suffix = name.components(separatedBy: "-path-").dropFirst().first,
                  let expected = suffix.split(separator: "-").first.flatMap({ Int($0) }) else { continue }
            let bytes = try Data(contentsOf: root.appendingPathComponent(name + "/body.json"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let nested = object["prompt"] as? [String: Any]
            let path = try XCTUnwrap(object["path"] as? String ?? nested?["path"] as? String)
            XCTAssertEqual(path.utf8.count, expected, name)
        }
        for (name, key, expected) in [("create-group-request-name-255", "name", 255),
                                      ("create-group-request-name-overflow", "name", 256),
                                      ("create-user-request-username-64", "username", 64),
                                      ("create-user-request-long-username", "username", 65)] {
            let bytes = try Data(contentsOf: root.appendingPathComponent(name + "/body.json"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(try XCTUnwrap(object[key] as? String).unicodeScalars.count, expected, name)
        }
    }

    func testOversizedPullFixtureFailsOnlyTheSharedBudgetRule() throws {
        let bytes = try Data(contentsOf: root.appendingPathComponent("pull-response-over-shared-budget/body.json"))
        let value = try JSONDecoder().decode(APIValue.self, from: bytes)
        guard case .object(let fields, let minimum, _) = SyncAPI.PullResponse.schema,
              case .object(var object) = value,
              case .array(var scopes) = object["scopes"],
              case .object(var lastScope) = scopes.last,
              case .array(var items) = lastScope["items"] else { return XCTFail("Expected pull object and scopes") }
        XCTAssertNoThrow(try SyncAPISchema.object(fields: fields, minimumProperties: minimum).validate(value))
        XCTAssertThrowsError(try JSONDecoder().decode(SyncAPI.PullResponse.self, from: bytes))
        items.removeLast()
        lastScope["items"] = .array(items)
        scopes[scopes.count - 1] = .object(lastScope)
        object["scopes"] = .array(scopes)
        let boundary = try JSONDecoder().decode(SyncAPI.PullResponse.self, from: JSONEncoder().encode(APIValue.object(object)))
        XCTAssertEqual(boundary.scopes.reduce(0) { $0 + $1.items.count }, 200)
    }

    func testMixedUnionFixturesIsolateForeignFieldsInCompleteVariants() throws {
        for (name, schema, foreignKey) in [("feed-item-mixed-union", SyncAPI.FeedItem.schema, "id"),
                                           ("issue-location-mixed-union", SyncAPI.IssueLocation.schema, "line")] {
            let bytes = try Data(contentsOf: root.appendingPathComponent(name + "/body.json"))
            let value = try JSONDecoder().decode(APIValue.self, from: bytes)
            XCTAssertThrowsError(try schema.validate(value), name)
            guard case .object(var object) = value else { return XCTFail("Expected union object") }
            XCTAssertNotNil(object.removeValue(forKey: foreignKey))
            XCTAssertNoThrow(try schema.validate(.object(object)), name)
        }
    }

    func testLiveSymlinksToOtherwiseValidCorpusEntriesAreRejected() throws {
        for name in ["body.json", "case.json", "directory", "root"] {
            try withCopy { copy in
                let link: URL
                if name == "root" {
                    link = copy.appendingPathComponent(".root-link")
                    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: ".")
                } else {
                    link = name == "directory" ? copy.appendingPathComponent("login-request-valid")
                        : copy.appendingPathComponent("login-request-valid/" + name)
                    let target = link.deletingLastPathComponent().appendingPathComponent(".original-" + name)
                    try FileManager.default.moveItem(at: link, to: target)
                    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.lastPathComponent)
                }
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType, .typeSymbolicLink)
                XCTAssertThrowsError(try DTOFixtureCorpus.consume(at: name == "root" ? link : copy), name) { error in
                    guard case DTOFixtureCorpus.Failure.invalidCorpus = error else { return XCTFail("Expected file-type rejection for \(name), got \(error)") }
                }
            }
        }
    }

    func testEnvelopeVersionUsesNumericValueWithoutLexicalTokenRules() throws {
        for token in ["1.0", "1e0"] {
            try withCopy { copy in
                let file = copy.appendingPathComponent("login-request-valid/case.json")
                let text = try String(contentsOf: file, encoding: .utf8)
                let changed = text.replacingOccurrences(of: "\"schema\": 1,", with: "\"schema\": " + token + ",")
                XCTAssertNotEqual(changed, text)
                try Data(changed.utf8).write(to: file)
                XCTAssertNoThrow(try DTOFixtureCorpus.consume(at: copy))
            }
        }
        try withCopy { copy in
            try Data("[]".utf8).write(to: copy.appendingPathComponent("login-request-valid/case.json"))
            XCTAssertThrowsError(try DTOFixtureCorpus.consume(at: copy))
        }
    }

    func testHiddenMetadataIsIgnoredWithoutWeakeningDispatch() throws {
        let original = try DTOFixtureCorpus.consume(at: root)
        try withCopy { copy in
            try FileManager.default.copyItem(at: copy.appendingPathComponent("login-request-valid"), to: copy.appendingPathComponent(".hidden"))
            for directory in [copy, copy.appendingPathComponent("login-request-valid")] {
                for name in [".DS_Store", "._body.json", ".gitattributes"] {
                    try Data([0xff]).write(to: directory.appendingPathComponent(name))
                }
                try FileManager.default.createDirectory(at: directory.appendingPathComponent(".hidden-directory"), withIntermediateDirectories: false)
                try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent(".hidden-link").path, withDestinationPath: "missing")
            }
            let result = try DTOFixtureCorpus.consume(at: copy)
            XCTAssertEqual(result.cases, original.cases)
            XCTAssertEqual(result.files, original.files)
            try Data().write(to: copy.appendingPathComponent("login-request-valid/orphan.json"))
            XCTAssertThrowsError(try DTOFixtureCorpus.consume(at: copy))
        }
    }

    func testRejectsOrphanMissingNestedAndLinkedFiles() throws {
        let mutations: [(URL) throws -> Void] = [
            { try Data().write(to: $0.appendingPathComponent("unknown.txt")) },
            { try Data().write(to: $0.appendingPathComponent("login-request-valid/unknown.txt")) },
            { try Data().write(to: $0.appendingPathComponent("login-request-valid/orphan.json")) },
            { try FileManager.default.removeItem(at: $0.appendingPathComponent("login-request-valid/body.json")) },
            { try FileManager.default.removeItem(at: $0.appendingPathComponent("login-request-valid/case.json")) },
            { try FileManager.default.createDirectory(at: $0.appendingPathComponent("login-request-valid/nested"), withIntermediateDirectories: false) },
            { try FileManager.default.createDirectory(at: $0.appendingPathComponent("empty-case"), withIntermediateDirectories: false) },
            { copy in
                let source = copy.appendingPathComponent("login-request-valid/body.json")
                try FileManager.default.removeItem(at: source)
                try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "case.json")
            },
            { copy in
                let directory = copy.appendingPathComponent("login-request-valid")
                try FileManager.default.removeItem(at: directory)
                try FileManager.default.createSymbolicLink(atPath: directory.path, withDestinationPath: "login-request-wrong-type")
            },
            { copy in
                for name in try FileManager.default.contentsOfDirectory(atPath: copy.path) where name.hasPrefix("login-request-") {
                    try FileManager.default.removeItem(at: copy.appendingPathComponent(name))
                }
            }
        ]
        for (index, mutation) in mutations.enumerated() {
            try withCopy { copy in
                try mutation(copy)
                XCTAssertThrowsError(try DTOFixtureCorpus.consume(at: copy), "mutation \(index)")
            }
        }
    }

    func testRejectsUnknownMissingAndWronglyTypedEnvelopeMembers() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["schema"] = 2 }, { $0["schema"] = true }, { $0["schema"] = 1.5 },
            { $0["category"] = "canonical" }, { $0["dto"] = "UnknownDTO" }, { $0["unknown"] = 1 },
            { $0.removeValue(forKey: "source") }, { $0["source"] = "../body.json" },
            { $0["source"] = "nested\\body.json" }, { $0["source"] = "case.json" },
            { $0["expected"] = ["valid": 1] }, { $0["expected"] = ["valid": true, "unknown": 1] },
            { $0["expected"] = ["valid": true, "http_status": 200] }, { $0["expected"] = [:] },
            { $0["expected"] = ["valid": false] }
        ]
        for mutation in mutations {
            try withCopy { copy in
                let file = copy.appendingPathComponent("login-request-valid/case.json")
                var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                mutation(&envelope)
                try JSONSerialization.data(withJSONObject: envelope).write(to: file)
                XCTAssertThrowsError(try DTOFixtureCorpus.consume(at: copy))
            }
        }
    }

    func testValidGoldenBytesMustAlreadyBeCanonical() throws {
        try withCopy { copy in
            let file = copy.appendingPathComponent("login-request-valid/body.json")
            var data = try Data(contentsOf: file)
            data.append(10)
            try data.write(to: file)
            XCTAssertThrowsError(try DTOFixtureCorpus.consume(at: copy))
        }
    }

    func testEverySchemaReferenceAndFieldDescriptionIsResolvable() throws {
        let names = Set(SyncAPI.schemas.map(\.name))
        func check(_ schema: SyncAPISchema) {
            switch schema {
            case .reference(let name): XCTAssertTrue(names.contains(name), name)
            case .array(let item, _, _, _): check(item)
            case .map(_, let value): check(value)
            case .oneOf(let alternatives):
                XCTAssertGreaterThan(alternatives.count, 1)
                alternatives.forEach(check)
            case .object(let fields, _, _):
                XCTAssertEqual(Set(fields.map(\.name)).count, fields.count)
                for field in fields { check(field.schema) }
            default: break
            }
        }
        SyncAPI.schemas.forEach { check($0.schema) }
    }

    private func withCopy(_ work: (URL) throws -> Void) throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("dto-contract-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: root, to: copy)
        try work(copy)
    }
}
