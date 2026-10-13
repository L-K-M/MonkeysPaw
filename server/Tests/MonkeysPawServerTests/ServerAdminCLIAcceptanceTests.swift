import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerAdminCLIAcceptanceTests {
    private static let password = "s22-cli-password"

    @Test func plainMutationsPrintExactlyTheStoredULIDAndNoLogs() async throws {
        try await withAdminCLI { fixture in
            let added = try await fixture.run(["user", "add", "owner"], input: Data(Self.password.utf8))
            let ownerID = try await fixture.persistence.string("SELECT id FROM users WHERE username = 'owner'", column: "id")
            Self.expectPlain(added, text: ownerID)
            #expect(ULID(ownerID)?.rawValue == ownerID)

            let group = try await fixture.run(["group", "add", "Plain group", "--owner", ownerID])
            let groupID = try await fixture.persistence.string("SELECT id FROM groups WHERE name = 'Plain group'", column: "id")
            Self.expectPlain(group, text: groupID)
            #expect(ULID(groupID)?.rawValue == groupID)

            let member = try await fixture.accounts.user(username: "member")
            Self.expectPlain(try await fixture.run(["group", "add-member", groupID, member.id]), text: member.id)
            Self.expectPlain(try await fixture.run(["user", "reset-password", member.id], input: Data(Self.password.utf8)), text: member.id)
            Self.expectPlain(try await fixture.run(["user", "disable", member.id]), text: member.id)
        }
    }

    @Test func configuredPlainInvitePrintsExactlyOneEncodedJoinLink() async throws {
        try await withAdminCLI { fixture in
            let issuer = try await fixture.accounts.user(username: "issuer", kind: .admin)
            let publicURL = "https://sync.example.test:8443/paw?value=a+b&next=%2F"
            let result = try await fixture.run(["invite", "create", "--issuer", issuer.id],
                environment: ["MONKEYSPAW_PUBLIC_URL": publicURL])
            let components = try #require(URLComponents(string: String(result.output.dropLast())))
            let token = try #require(components.queryItems?.first { $0.name == "token" }?.value)
            #expect(DeviceToken(value: token).isValid)
            Self.expectPlain(result, text: "monkeyspaw://join?server=https%3A%2F%2Fsync.example.test%3A8443%2Fpaw%3Fvalue%3Da%2Bb%26next%3D%252F&token=\(token)")
            #expect(try await fixture.persistence.storedInvite(token).createdBy == issuer.id)
        }
    }

    @Test(arguments: ["\n\n\n", "\r\n\r\n\r\n", "\n\r\n"], [false, true])
    func passwordSourcesRemoveOnlyOneTerminalSequence(suffix: String, fromFile: Bool) async throws {
        try await withAdminCLI { fixture in
            let input = "  \(Self.password)  " + suffix
            let expected = String(decoding: Data(input.utf8).dropLast(suffix.hasSuffix("\r\n") ? 2 : 1), as: UTF8.self)
            let file = fixture.directory.appendingPathComponent("password.txt")
            try Data(input.utf8).write(to: file)
            let source = fromFile ? ["--password-file", file.path] : []
            let added = try await fixture.run(["user", "add", "new", "--json"] + source,
                input: Data((fromFile ? "ignored-stdin-password" : input).utf8))
            _ = try added.value(SyncAPI.User.self)
            _ = try await fixture.accounts.accounts.verifyCredentials(username: "new", password: expected)
            await #expect(throws: AccountError.unauthorized) {
                _ = try await fixture.accounts.accounts.verifyCredentials(username: "new", password: "  \(Self.password)  ")
            }
            await #expect(throws: AccountError.unauthorized) {
                _ = try await fixture.accounts.accounts.verifyCredentials(username: "new", password: input)
            }

            let target = try await fixture.accounts.user(username: "reset")
            let reset = try await fixture.run(["user", "reset-password", target.id, "--json"] + source,
                input: Data((fromFile ? "ignored-stdin-password" : input).utf8))
            _ = try reset.value(SyncAPI.User.self)
            _ = try await fixture.accounts.accounts.verifyCredentials(username: "reset", password: expected)
            await #expect(throws: AccountError.unauthorized) {
                _ = try await fixture.accounts.accounts.verifyCredentials(username: "reset", password: "  \(Self.password)  ")
            }
            await #expect(throws: AccountError.unauthorized) {
                _ = try await fixture.accounts.accounts.verifyCredentials(username: "reset", password: input)
            }
        }
    }

    @Test func administrationMigratesAFreshDirectoryWithoutBootstrap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s22-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let result = try await AdminCLITestFixture.run(["user", "add", "explicit", "--json"], dataDirectory: directory,
            input: Data(Self.password.utf8), environment: ["MONKEYSPAW_ADMIN_USERNAME": "implicit-admin",
                "MONKEYSPAW_ADMIN_PASSWORD": "valid-bootstrap-password"])
        let created = try result.value(SyncAPI.User.self)
        #expect(created.username == "explicit" && created.accountKind == .member)

        // Open without migrating: inspecting through withMigratedDatabase would hide this defect.
        let database = try await ServerDatabase.open(configuration: .init(environment: ["MONKEYSPAW_DATA_DIR": directory.path]))
        do {
            let repository = PersistenceTestRepository(database: database)
            let names = try await database.read { sql in
                try await sql.raw("SELECT name FROM schema_migrations ORDER BY name").all().map {
                    try $0.decode(column: "name", as: String.self)
                }
            }
            #expect(names == ServerMigration.current.map(\.name))
            #expect(try await repository.count("users") == 1)
            #expect(try await repository.string("SELECT id FROM users", column: "id") == created.id)
            #expect(try await repository.count("devices") == 0)
            #expect(try await repository.auditEvents().map(\.action) == ["user.create"])
            await database.shutdown()
        } catch {
            await database.shutdown()
            throw error
        }
    }

    @Test func omittedInviteLifetimeIsExactlySevenDaysInCLIOutputAndStorage() async throws {
        try await withAdminCLI { fixture in
            let issuer = try await fixture.accounts.user(username: "issuer", kind: .admin)
            let result = try await fixture.run(["invite", "create", "--issuer", issuer.id, "--json"])
            let output = try result.value(InviteJSON.self)
            let issuance = try #require(await fixture.persistence.auditEvents().first { $0.action == "invite.create" })
            let issuedAt = try #require(ServerTimestamp.date(issuance.at))
            let expiresAt = try #require(ServerTimestamp.date(output.expiresAt))
            #expect(expiresAt.timeIntervalSince(issuedAt) == 7 * 24 * 60 * 60)
            #expect(try await fixture.persistence.storedInvite(output.secret).expiresAt == output.expiresAt)
        }
    }

    private static func expectPlain(_ result: AdminCLIResult, text: String) {
        #expect(result.exitedNormally && result.status == 0 && result.error.isEmpty)
        #expect(result.output == text + "\n")
    }
}
