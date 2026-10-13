import Foundation
import MonkeysPawCore
import XCTest

final class SchemaTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testSchemaOutputIsDeterministicCompleteAndCommitted() throws {
        let temporary = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let first = temporary.appendingPathComponent("first")
        let second = temporary.appendingPathComponent("second")
        XCTAssertEqual(try runDumpSchema([first.path]).status, 0)
        XCTAssertEqual(try runDumpSchema([second.path]).status, 0)

        let names = SyncAPI.schemas.map { $0.name + ".json" }
        let expected = Set(names + ["README.md"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: first.path)), expected)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: second.path)), expected)
        let committed = root.appendingPathComponent("spec/schema")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: committed.path)), expected)
        for name in expected.sorted() {
            let data = try Data(contentsOf: first.appendingPathComponent(name))
            XCTAssertEqual(data, try Data(contentsOf: second.appendingPathComponent(name)), name)
            XCTAssertEqual(data, try Data(contentsOf: committed.appendingPathComponent(name)), name)
            XCTAssertEqual(data.last, 0x0A, name)
            XCTAssertNotEqual(data.dropLast().last, 0x0A, name)
            if name.hasSuffix(".json") {
                let json = try JSONSerialization.jsonObject(with: data)
                var sorted = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
                sorted.append(0x0A)
                XCTAssertEqual(data, sorted, name)
                let schema = try SchemaJSON(data: data)
                XCTAssertEqual(schema.object?["$schema"]?.string, SyncAPI.schemaDialect)
                XCTAssertEqual(schema.object?["$id"]?.string, "https://lkmc.ch/monkeyspaw/sync-api/schema/" + name)
            }
        }
    }

    func testSchemaCLIRejectsWrongArgumentsAndWriteFailures() throws {
        for arguments in [[], [""], ["one", "two"]] as [[String]] {
            let result = try runDumpSchema(arguments)
            XCTAssertEqual(result.status, 64)
            XCTAssertEqual(result.error, "Usage: dump-schema <output-dir>\n")
        }
        let temporary = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let file = temporary.appendingPathComponent("file")
        try Data().write(to: file)
        let result = try runDumpSchema([file.path])
        XCTAssertEqual(result.status, 1)
        let prefix = "dump-schema: could not write schemas: "
        XCTAssertTrue(result.error.hasPrefix(prefix), result.error)
        XCTAssertGreaterThan(result.error.utf8.count, prefix.utf8.count + 1, result.error)
        XCTAssertTrue(result.error.hasSuffix("\n"), result.error)
    }

    func testSchemaRendererBoundsBytesAndOmitsRedundantConstraints() throws {
        let temporary = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        XCTAssertEqual(try runDumpSchema([temporary.path]).status, 0)
        let validator = try loadValidator(at: temporary)
        var byteSchemas: [Int64: SchemaJSON] = [:]
        for (name, schema) in validator.schemas {
            visit(schema, path: name) { path, object in
                XCTAssertNotEqual(object["minLength"], .integer(0), path)
                XCTAssertNotEqual(object["minItems"], .integer(0), path)
                if let pattern = object["pattern"]?.string {
                    XCTAssertFalse(pattern.hasPrefix("^(?:^"), path)
                    XCTAssertFalse(pattern.hasSuffix("$)(?![\\s\\S])"), path)
                }
                if let maximum = object["x-max-utf8-bytes"]?.integer {
                    XCTAssertEqual(object["maxLength"]?.integer, maximum, path)
                    byteSchemas[maximum] = .object(object)
                }
            }
        }
        XCTAssertEqual(Set(byteSchemas.keys), [72, 1_024, 262_144])
        for (maximum, schema) in byteSchemas {
            let limit = Int(maximum)
            for text in [String(repeating: "a", count: limit), String(repeating: "é", count: limit / 2)] {
                XCTAssertEqual(text.utf8.count, limit)
                XCTAssertTrue(try validator.validate(.string(text), against: schema, mode: .schema), "\(limit)")
                XCTAssertTrue(try validator.validate(.string(text), against: schema), "\(limit)")
            }
            let tooManyScalars = SchemaJSON.string(String(repeating: "a", count: limit + 1))
            XCTAssertFalse(try validator.validate(tooManyScalars, against: schema, mode: .schema), "\(limit)")
            XCTAssertFalse(try validator.validate(tooManyScalars, against: schema), "\(limit)")
            let tooManyBytes = SchemaJSON.string(String(repeating: "é", count: limit / 2 + 1))
            XCTAssertTrue(try validator.validate(tooManyBytes, against: schema, mode: .schema), "\(limit)")
            XCTAssertFalse(try validator.validate(tooManyBytes, against: schema), "\(limit)")
        }
    }

    func testSchemaValidationAgreesWithStrictDTOFixtures() throws {
        let temporary = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        XCTAssertEqual(try runDumpSchema([temporary.path]).status, 0)
        let validator = try loadValidator(at: temporary)
        let types: [any SyncAPIDTO.Type] = [
            SyncAPI.HealthResponse.self, SyncAPI.EmptyResponse.self, SyncAPI.IDPath.self,
            SyncAPI.MemberPath.self, SyncAPI.RevisionPath.self, SyncAPI.LoginRequest.self,
            SyncAPI.RegisterRequest.self, SyncAPI.PasswordChangeRequest.self, SyncAPI.User.self,
            SyncAPI.AuthResponse.self, SyncAPI.Device.self, SyncAPI.MeResponse.self,
            SyncAPI.CreateUserRequest.self, SyncAPI.UpdateUserRequest.self, SyncAPI.FailureCode.self,
            SyncAPI.ErrorResponse.self, SyncAPI.RetryAfter.self, SyncAPI.PullRequest.self,
            SyncAPI.FeedItem.self, SyncAPI.ScopeIdentity.self, SyncAPI.SyncScope.self,
            SyncAPI.PullResponse.self, SyncAPI.Group.self, SyncAPI.GroupMembership.self,
            SyncAPI.CreateGroupRequest.self, SyncAPI.RenameGroupRequest.self, SyncAPI.Member.self,
            SyncAPI.MembersResponse.self, SyncAPI.MembershipRequest.self, SyncAPI.GroupInviteRequest.self,
            SyncAPI.JoinGroupRequest.self, SyncAPI.AdminInviteRequest.self, SyncAPI.InviteResponse.self,
            SyncAPI.IssueLocation.self, SyncAPI.Issue.self, SyncAPI.Prompt.self,
            SyncAPI.PutPromptRequest.self, SyncAPI.DeletePromptQuery.self, SyncAPI.MovePromptRequest.self,
            SyncAPI.WriteResponse.self, SyncAPI.ConflictHead.self, SyncAPI.ExistingPrompt.self,
            SyncAPI.RevisionSummary.self, SyncAPI.RevisionsResponse.self, SyncAPI.Revision.self,
            SyncAPI.FeedPrompt.self, SyncAPI.AccountKind.self, SyncAPI.Role.self,
            SyncAPI.InviteRole.self, SyncAPI.WriteOrigin.self, SyncAPI.RevisionOrigin.self,
            SyncAPI.Mode.self, SyncAPI.Severity.self, SyncAPI.PromptScope.self
        ]
        let readers = Dictionary(uniqueKeysWithValues: types.map { ($0.schemaName, $0) })
        XCTAssertEqual(Set(readers.keys), Set(SyncAPI.schemas.map(\.name)))
        let fixtures = root.appendingPathComponent("spec/fixtures/dto")
        var accepted = Set<String>(), rejected = Set<String>()
        for name in try FileManager.default.contentsOfDirectory(atPath: fixtures.path).sorted() where !name.hasPrefix(".") {
            let directory = fixtures.appendingPathComponent(name)
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("case.json")))
            let type = try XCTUnwrap(readers[fixture.dto], name)
            let schema = try XCTUnwrap(validator.schemas[fixture.dto + ".json"], name)
            let data = try Data(contentsOf: directory.appendingPathComponent(fixture.source))
            let decoded = (try? JSONDecoder().decode(type, from: data)) != nil
            let value = try? SchemaJSON(data: data)
            let validated = try value.map { try validator.validate($0, against: schema) } ?? false
            XCTAssertEqual(decoded, fixture.expected.valid, name)
            XCTAssertEqual(validated, decoded, name)
            if decoded { accepted.insert(fixture.dto) } else { rejected.insert(fixture.dto) }
        }
        XCTAssertEqual(accepted, Set(readers.keys))
        XCTAssertEqual(rejected, Set(readers.keys))
    }

    func testSchemaAnnotationsRequireAdditionalContractValidation() throws {
        let validator = try loadValidator(at: root.appendingPathComponent("spec/schema"))
        let cases = [
            ("ScopeIdentity", "{\"key\":\"group:01ARZ3NDEKTSV4RRFFQ69G5FAV\",\"kind\":\"group\",\"group_id\":\"01ARZ3NDEKTSV4RRFFQ69G5FAW\",\"name\":\"Group\",\"role\":\"viewer\"}"),
            ("Group", "{\"id\":\"01ARZ3NDEKTSV4RRFFQ69G5FAV\",\"name\":\"Group\",\"created_by\":\"01ARZ3NDEKTSV4RRFFQ69G5FAW\",\"created_at\":\"2025-02-29T12:00:00.000Z\"}"),
            ("FeedPrompt", "{\"id\":\"01ARZ3NDEKTSV4RRFFQ69G5FAV\",\"rev\":1,\"path\":\"a.md\",\"content\":\"" + String(repeating: "é", count: 131_073) + "\"}")
        ]
        for (name, source) in cases {
            let value = try SchemaJSON(data: Data(source.utf8))
            let schema = try XCTUnwrap(validator.schemas[name + ".json"])
            XCTAssertTrue(try validator.validate(value, against: schema, mode: .schema), name)
            XCTAssertFalse(try validator.validate(value, against: schema), name)
        }
    }

    private struct Fixture: Decodable {
        struct Expected: Decodable { let valid: Bool }
        let dto: String
        let source: String
        let expected: Expected
    }

    private func visit(_ value: SchemaJSON, path: String, check: (String, [String: SchemaJSON]) -> Void) {
        if let object = value.object {
            check(path, object)
            for (key, value) in object { visit(value, path: path + "." + key, check: check) }
        } else if let array = value.array {
            for (index, value) in array.enumerated() { visit(value, path: path + ".\(index)", check: check) }
        }
    }

    private func loadValidator(at directory: URL) throws -> SchemaValidator {
        let schemas = try SyncAPI.schemas.map { description in
            let name = description.name + ".json"
            return (name, try SchemaJSON(data: Data(contentsOf: directory.appendingPathComponent(name))))
        }
        return SchemaValidator(schemas: Dictionary(uniqueKeysWithValues: schemas))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-schema-" + UUID().uuidString)
    }

    private func runDumpSchema(_ arguments: [String]) throws -> (status: Int32, error: String) {
        // Find sibling products from this test bundle, including when XCTest
        // uses an external launcher. SwiftPM builds executable products with tests.
        var directory = Bundle(for: SchemaTests.self).bundleURL
        var executable: URL?
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("dump-schema")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { executable = candidate; break }
            directory.deleteLastPathComponent()
        }
        let process = Process()
        process.executableURL = try XCTUnwrap(executable, "SwiftPM must build dump-schema beside its test products")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let error = Pipe()
        process.standardError = error
        try process.run()
        let data = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
