import Foundation
import MonkeysPawCore
import SQLKit
import Testing
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerAdminCLISecurityTests {
    @Test func passwordSourcesFailSafelyAndAConfiguredFileIsAuthoritative() async throws {
        try await withAdminCLI { fixture in
            let secret = "s16-private-password-sentinel"
            for input in [Data(), Data([0xff, 0xfe]), Data(repeating: 65, count: ServerLimits.operatorPasswordInputMaximumBytes + 1)] {
                try await fixture.run(["user", "add", "invalid"], input: input)
                    .assertFailure(excluding: [secret], expectedError: .passwordInput)
            }
            let file = fixture.directory.appendingPathComponent(secret)
            try await fixture.run(["user", "add", "invalid", "--password-file", file.path], input: Data(secret.utf8))
                .assertFailure(excluding: [secret, file.path])
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            try await fixture.run(["user", "add", "invalid", "--password-file", file.path], input: Data(secret.utf8))
                .assertFailure(excluding: [secret, file.path])
            try FileManager.default.removeItem(at: file)
            try #require(mkfifo(file.path, 0o600) == 0)
            try await fixture.run(["user", "add", "invalid", "--password-file", file.path], input: Data(secret.utf8))
                .assertFailure(excluding: [secret, file.path])
            try FileManager.default.removeItem(at: file)
            for bytes in [Data(), Data([0xff]), Data(repeating: 65, count: ServerLimits.operatorPasswordInputMaximumBytes + 1)] {
                try bytes.write(to: file)
                try await fixture.run(["user", "add", "invalid", "--password-file", file.path], input: Data(secret.utf8))
                    .assertFailure(excluding: [secret, file.path])
            }
            try FileManager.default.removeItem(at: file)
            // Bootstrap environment credentials never supply an administration password.
            try await fixture.run(["user", "add", "invalid"], environment: ["MONKEYSPAW_ADMIN_PASSWORD": secret])
                .assertFailure(excluding: [secret])
            #expect(try await fixture.persistence.count("users") == 0)
            #expect(try await fixture.persistence.auditEvents().isEmpty)
        }
    }

    @Test func parserNeverEchoesInvalidValuesExtraArgumentsOrPasswordOptions() async throws {
        try await withAdminCLI { fixture in
            // Deliberate non-credential sentinels exercise ArgumentParser's argv diagnostics.
            let sentinel = "s16-argv-secret-sentinel"
            for arguments in [["user", "add", "valid", "--password", sentinel],
                              ["user", "add", "valid", sentinel],
                              ["user", "reset-password", "id", "--password=\(sentinel)"],
                              ["user", "disable", "id", "--\(sentinel)"],
                              ["invite", "create", "--issuer", "id", "--expires-in", sentinel],
                              [sentinel], ["backup", sentinel, sentinel], ["restore", sentinel, sentinel],
                              ["group", "\(sentinel)"]] {
                try await fixture.run(arguments).assertFailure(excluding: [sentinel])
            }
            let help = try await fixture.run(["--help"])
            #expect(help.status == 0 && help.error.isEmpty)
            for command in ["serve", "healthcheck", "migrate", "user", "group", "invite", "backup", "restore"] {
                #expect(help.output.contains(command))
            }
            for (command, leaves) in [("user", ["add", "disable", "reset-password"]),
                                      ("group", ["add", "add-member"]), ("invite", ["create"])] {
                let help = try await fixture.run([command, "--help"])
                #expect(help.status == 0 && help.error.isEmpty)
                for leaf in leaves { #expect(help.output.contains(leaf)) }
            }
            #expect(try await fixture.persistence.count("users") == 0)
        }
    }

    @Test func configurationAndDatabaseFailuresNeverExposeTheirValues() async throws {
        try await withAdminCLI { fixture in
            let sentinel = "s16-private-configuration-sentinel"
            for key in ["MONKEYSPAW_PUBLIC_URL", "MONKEYSPAW_HTTP_PORT", "MONKEYSPAW_TRUSTED_PROXIES"] {
                try await fixture.run(["user", "add", "valid"], input: Data("valid-cli-password".utf8), environment: [key: sentinel])
                    .assertFailure(excluding: [sentinel])
            }
            let file = fixture.directory.appendingPathComponent(sentinel)
            try Data("s16-invalid-database-file".utf8).write(to: file)
            try await fixture.run(["group", "add", "Group", "--owner", PersistenceTestRepository.user],
                                   environment: ["MONKEYSPAW_DATA_DIR": file.path]).assertFailure(excluding: [sentinel, file.path])
            try FileManager.default.removeItem(at: file)
            #expect(try await fixture.persistence.count("users") == 0)
        }
    }

    @Test(arguments: CLIAtomicAction.allCases)
    func auditFailureRollsBackTheWholeCommandAndHasNoSecretOutput(action: CLIAtomicAction) async throws {
        try await withAdminCLI { fixture in
            let groupFixture = GroupTestFixture(account: fixture.accounts)
            let admin = try await groupFixture.user("admin", kind: .admin)
            let target = try await groupFixture.user("target")
            let session = try await fixture.accounts.session(target)
            let group = try await groupFixture.group(owner: admin)
            let password = "s16-rollback-password-sentinel"
            let errorSecret = "s16-backend-secret-sentinel"
            let before = try await fixture.persistence.auditEvents().count
            let actionName = action.auditAction
            try await fixture.persistence.execute("""
                CREATE TRIGGER fail_operator_audit AFTER INSERT ON audit_events
                WHEN NEW.action = \(literal: actionName)
                BEGIN SELECT RAISE(ABORT, \(literal: errorSecret)); END
                """)
            let arguments = action.arguments(adminID: admin.id, targetID: target.id, groupID: group.id)
            try await fixture.run(arguments, input: Data(password.utf8))
                .assertFailure(excluding: [password, errorSecret, "group-fixture-hash"], expectedError: .failed)
            #expect(try await fixture.persistence.auditEvents().count == before)
            #expect(try await fixture.persistence.count("users") == 2)
            #expect(try await fixture.persistence.count("groups") == 1)
            #expect(try await fixture.persistence.count("memberships") == 1)
            #expect(try await fixture.persistence.count("invites") == 0)
            let stored = try await fixture.accounts.accounts.repository.read { accounts, _ in try #require(await accounts.user(id: target.id)) }
            #expect(stored.disabledAt == nil && stored.passwordHash == target.passwordHash)
            #expect(try await fixture.accounts.sessions.authenticate(token: session.token.value) == session.identity)
            try await fixture.persistence.execute("DROP TRIGGER fail_operator_audit")
            let retry = try await fixture.run(arguments, input: Data(password.utf8))
            #expect(retry.status == 0 && retry.error.isEmpty)
            #expect(try await fixture.persistence.auditEvents().count > before)
            #expect(try await fixture.persistence.auditEvents().allSatisfy { $0.actorID == nil })
            try await fixture.accounts.assertNoPlaintext([password])
        }
    }

    @Test func independentCLIProcessesSerializeLastAdminAndLastOwnerChecks() async throws {
        try await withAdminCLI { fixture in
            let groups = GroupTestFixture(account: fixture.accounts)
            let first = try await groups.user("first", kind: .admin)
            let second = try await groups.user("second", kind: .admin)
            async let disableFirst = fixture.run(["user", "disable", first.id])
            async let disableSecond = fixture.run(["user", "disable", second.id])
            let disables = try await [disableFirst, disableSecond]
            #expect(disables.filter { $0.status == 0 }.count == 1)
            #expect(disables.filter { $0.status != 0 }.count == 1)
            #expect(disables.allSatisfy { $0.exitedNormally })
            let owner = try await groups.user("owner")
            let coOwner = try await groups.user("coowner")
            let group = try await groups.group(owner: owner)
            try await groups.member(groupID: group.id, user: coOwner, role: .owner)
            async let demoteFirst = fixture.run(["group", "add-member", group.id, owner.id, "--role", "viewer"])
            async let demoteSecond = fixture.run(["group", "add-member", group.id, coOwner.id, "--role", "viewer"])
            let demotions = try await [demoteFirst, demoteSecond]
            #expect(demotions.filter { $0.status == 0 }.count == 1)
            #expect(demotions.filter { $0.status != 0 }.count == 1)
            #expect(demotions.allSatisfy { $0.exitedNormally })
            let owners = try await groups.repository.read { groups, _, _ in try await groups.ownerCount(groupID: group.id) }
            #expect(owners == 1)
            let events = try await fixture.persistence.auditEvents()
            #expect(events.map(\.action) == ["user.disable", "membership.upsert"])
            #expect(events.allSatisfy { $0.actorID == nil })
        }
    }
}

enum CLIAtomicAction: Sendable, CaseIterable {
    case addUser, disableUser, resetPassword, addGroup, addMember, createInvite

    var auditAction: String {
        switch self {
        case .addUser: return "user.create"
        case .disableUser: return "user.disable"
        case .resetPassword: return "user.reset_password"
        // Fail the second group-create event, after the group and first audit insert.
        case .addGroup, .addMember: return "membership.upsert"
        case .createInvite: return "invite.create"
        }
    }

    func arguments(adminID: String, targetID: String, groupID: String) -> [String] {
        switch self {
        case .addUser: return ["user", "add", "created"]
        case .disableUser: return ["user", "disable", targetID]
        case .resetPassword: return ["user", "reset-password", targetID]
        case .addGroup: return ["group", "add", "Created", "--owner", targetID]
        case .addMember: return ["group", "add-member", groupID, targetID, "--role", "owner"]
        case .createInvite: return ["invite", "create", "--issuer", adminID, "--group", groupID, "--role", "owner"]
        }
    }
}
