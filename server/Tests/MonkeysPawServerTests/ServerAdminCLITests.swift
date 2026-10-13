import Foundation
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerAdminCLITests {
    private static let password = "s16-password-from-stdin"
    private static let missingID = "01ARZ3NDEKTSV4RRFFQ69G5FZZ"

    @Test func userAddReadsStdinAndFileAndAuditsTheOperator() async throws {
        try await withAdminCLI { fixture in
            let first = try await fixture.run(["user", "add", "admin", "--kind", "admin", "--json"], input: Data("\(Self.password)\r\n".utf8))
            let admin = try first.value(SyncAPI.User.self)
            #expect(admin.username == "admin" && admin.accountKind == .admin)
            let file = fixture.directory.appendingPathComponent("password.txt")
            let password = "  s16-password-spaces  "
            try Data("\(password)\n".utf8).write(to: file)
            let second = try await fixture.run(["user", "add", "member", "--password-file", file.path, "--display-name", "Member", "--json"],
                                               input: Data("ignored-stdin-password".utf8))
            let member = try second.value(SyncAPI.User.self)
            #expect(member.accountKind == .member && member.displayName == "Member")
            _ = try await fixture.accounts.accounts.verifyCredentials(username: "admin", password: Self.password)
            _ = try await fixture.accounts.accounts.verifyCredentials(username: "member", password: password)
            let events = try await fixture.persistence.auditEvents()
            #expect(events.map(\.action) == ["user.create", "user.create"])
            #expect(events.map(\.targetID) == [admin.id, member.id])
            #expect(events.allSatisfy { $0.actorID == nil && $0.groupID == nil && ServerTimestamp.date($0.at) != nil })
            let outputIsSafe = !first.output.contains(Self.password) && !second.output.contains(password)
                && !first.error.contains(Self.password) && !second.error.contains(password)
            #expect(outputIsSafe)
            try FileManager.default.removeItem(at: file)
            try await fixture.accounts.assertNoPlaintext([Self.password, password])
        }
    }

    @Test func userAddRejectsInvalidUsernamesKindsPasswordsAndDuplicates() async throws {
        try await withAdminCLI { fixture in
            for username in ["Uppercase", ".start", "has space", String(repeating: "a", count: 65)] {
                try await fixture.run(["user", "add", username], input: Data(Self.password.utf8)).assertFailure(excluding: [username, Self.password])
            }
            for password in ["short", String(repeating: "p", count: 73), "valid-password\0suffix"] {
                try await fixture.run(["user", "add", "invalid"], input: Data(password.utf8)).assertFailure(excluding: [password])
            }
            try await fixture.run(["user", "add", "invalid", "--kind", "s16-kind-secret"], input: Data(Self.password.utf8))
                .assertFailure(excluding: ["s16-kind-secret", Self.password], expectedError: .invalidInput)
            #expect(try await fixture.persistence.count("users") == 0)
            let first = try await fixture.run(["user", "add", "unique"], input: Data(Self.password.utf8))
            #expect(first.status == 0 && first.error.isEmpty)
            try await fixture.run(["user", "add", "unique"], input: Data(Self.password.utf8)).assertFailure(excluding: [Self.password])
            #expect(try await fixture.persistence.count("users") == 1)
            #expect(try await fixture.persistence.auditEvents().count == 1)
        }
    }

    @Test func disablePreservesDataRevokesDevicesAndKeepsAnEnabledAdmin() async throws {
        try await withAdminCLI { fixture in
            let admin = try await fixture.accounts.user(username: "admin", kind: .admin)
            let target = try await fixture.accounts.user(username: "target")
            let session = try await fixture.accounts.session(target)
            try await fixture.persistence.seedAccountData(target)
            let result = try await fixture.run(["user", "disable", target.id, "--json"])
            let disabled = try result.value(SyncAPI.User.self)
            #expect(disabled.disabledAt != nil)
            #expect(try await fixture.persistence.count("prompts") == 1)
            #expect(try await fixture.persistence.count("memberships") == 1)
            await #expect(throws: AccountError.unauthorized) { try await fixture.accounts.sessions.authenticate(token: session.token.value) }
            #expect(try await fixture.run(["user", "disable", target.id]).status == 0)
            #expect(try await fixture.persistence.auditEvents().count == 1)
            try await fixture.run(["user", "disable", admin.id]).assertFailure(expectedError: .forbidden)
            try await fixture.run(["user", "disable", Self.missingID]).assertFailure(expectedError: .notFound)
            try await fixture.run(["user", "disable", "s16-id-secret"]).assertFailure(excluding: ["s16-id-secret"])
            let backup = try await fixture.accounts.user(username: "backup", kind: .admin)
            #expect(try await fixture.run(["user", "disable", backup.id]).status == 0)
            // A disabled admin does not make removing the last enabled admin safe.
            try await fixture.run(["user", "disable", admin.id]).assertFailure()
            _ = try await fixture.accounts.user(username: "replacement", kind: .admin)
            #expect(try await fixture.run(["user", "disable", admin.id]).status == 0)
            let events = try await fixture.persistence.auditEvents()
            #expect(events.map(\.action) == Array(repeating: "user.disable", count: 3))
            #expect(events.allSatisfy { $0.actorID == nil })
        }
    }

    @Test func passwordResetUsesSecretFileRevokesEveryDeviceAndRejectsFailures() async throws {
        try await withAdminCLI { fixture in
            let user = try await fixture.accounts.user(username: "admin", kind: .admin)
            let first = try await fixture.accounts.session(user)
            let second = try await fixture.accounts.session(user)
            let file = fixture.directory.appendingPathComponent("reset.txt")
            try Data("\(Self.password)\n".utf8).write(to: file)
            let result = try await fixture.run(["user", "reset-password", user.id, "--password-file", file.path, "--json"])
            #expect(try result.value(SyncAPI.User.self).disabledAt == nil)
            for session in [first, second] {
                await #expect(throws: AccountError.unauthorized) { try await fixture.accounts.sessions.authenticate(token: session.token.value) }
            }
            _ = try await fixture.accounts.accounts.verifyCredentials(username: user.username, password: Self.password)
            try await fixture.run(["user", "reset-password", user.id], input: Data("short".utf8)).assertFailure(excluding: ["short"])
            try await fixture.run(["user", "reset-password", Self.missingID], input: Data(Self.password.utf8))
                .assertFailure(excluding: [Self.password], expectedError: .notFound)
            try await fixture.run(["user", "reset-password", "invalid-secret-id"], input: Data(Self.password.utf8))
                .assertFailure(excluding: ["invalid-secret-id", Self.password])
            let events = try await fixture.persistence.auditEvents()
            #expect(events.count == 1 && events.first?.action == "user.reset_password" && events.first?.actorID == nil)
            try FileManager.default.removeItem(at: file)
            try await fixture.accounts.assertNoPlaintext([Self.password])
        }
    }

    @Test func groupCreationAndMembershipChangesUseOperatorAuditsAndKeepLastOwner() async throws {
        try await withAdminCLI { fixture in
            let owner = try await fixture.accounts.user(username: "owner")
            let member = try await fixture.accounts.user(username: "member")
            let created = try await fixture.run(["group", "add", "Group", "--owner", owner.id, "--json"])
            let group = try created.value(SyncAPI.Group.self)
            #expect(group.createdBy == owner.id && group.name == "Group")
            let added = try await fixture.run(["group", "add-member", group.id, member.id, "--json"])
            let viewer = try added.value(SyncAPI.Member.self)
            #expect(viewer.role == .viewer)
            for role in ["editor", "owner"] {
                let changed = try await fixture.run(["group", "add-member", group.id, member.id, "--role", role, "--json"])
                let metadata = try changed.value(SyncAPI.Member.self)
                #expect(metadata.role.rawValue == role && metadata.joinedAt == viewer.joinedAt)
            }
            #expect(try await fixture.run(["group", "add-member", group.id, owner.id, "--role", "editor"]).status == 0)
            try await fixture.run(["group", "add-member", group.id, member.id, "--role", "viewer"]).assertFailure()
            for arguments in [["group", "add-member", group.id, Self.missingID],
                              ["group", "add-member", Self.missingID, member.id],
                              ["group", "add-member", group.id, member.id, "--role", "s16-role-secret"],
                              ["group", "add", "", "--owner", owner.id],
                              ["group", "add", "Missing", "--owner", Self.missingID]] {
                try await fixture.run(arguments).assertFailure(excluding: ["s16-role-secret"])
            }
            #expect(try await fixture.run(["user", "disable", owner.id]).status == 0)
            try await fixture.run(["group", "add", "Disabled", "--owner", owner.id]).assertFailure()
            let events = try await fixture.persistence.auditEvents()
            #expect(events.map(\.action) == ["group.create", "membership.upsert", "membership.upsert", "membership.upsert",
                                            "membership.upsert", "membership.upsert", "user.disable"])
            #expect(events.allSatisfy { $0.actorID == nil })
            #expect(events.dropFirst().dropLast().allSatisfy { $0.groupID == group.id })
        }
    }

    @Test func invitesPrintOneSecretForAllRolesAndAnOwnerTokenRedeemsOnlyOnce() async throws {
        try await withAdminCLI { fixture in
            let issuer = try await fixture.accounts.user(username: "issuer", kind: .admin)
            let owner = try await fixture.accounts.user(username: "owner")
            let groupFixture = GroupTestFixture(account: fixture.accounts)
            let group = try await groupFixture.group(owner: owner)
            // The subprocess uses wall time, so redemption must use the same clock.
            let invites = InviteService(accounts: .init(database: fixture.database, passwords: InviteTestHasher()),
                                        sessions: .init(database: fixture.database))
            let accountOnly = try await fixture.run(["invite", "create", "--issuer", issuer.id])
            let accountToken = accountOnly.output.trimmingCharacters(in: .newlines)
            let once = accountOnly.status == 0 && accountOnly.error.isEmpty && accountOnly.output.split(separator: "\n").count == 1
                && DeviceToken(value: accountToken).isValid
            #expect(once)
            #expect(try await fixture.persistence.storedInvite(accountToken).target == .account)
            var secrets = [accountToken]
            for role in SyncAPI.Role.allCases {
                let result = try await fixture.run(["invite", "create", "--issuer", issuer.id, "--group", group.id, "--role", role.rawValue, "--json"])
                let output = try result.value(InviteJSON.self)
                let token = output.secret
                secrets.append(token)
                #expect(output.groupID == group.id && output.role == role)
                let onlyOnce = result.output.components(separatedBy: token).count == 2
                #expect(onlyOnce)
                let stored = try await fixture.persistence.storedInvite(token)
                #expect(stored.target == .group(groupID: group.id, role: role) && stored.createdBy == issuer.id)
                let echoedTarget = InviteRecord.Target.group(groupID: try #require(output.groupID), role: try #require(output.role))
                #expect(stored.target == echoedTarget)
                if role == .owner {
                    let issued = try await invites.register(.init(inviteToken: token, username: "redeemed", password: Self.password, deviceName: "CLI test"))
                    let membership = try await fixture.accounts.accounts.me(issued.identity).groups.first
                    #expect(membership?.role == .owner)
                    await #expect(throws: AccountError.malformedRequest) {
                        try await invites.register(.init(inviteToken: token, username: "second", password: Self.password, deviceName: "CLI test"))
                    }
                }
            }
            let issuance = try await fixture.persistence.auditEvents().filter { $0.action == "invite.create" }
            #expect(issuance.count == 4 && issuance.allSatisfy { $0.actorID == nil })
            #expect(issuance.first?.targetID == issuer.id && issuance.first?.groupID == nil)
            #expect(issuance.dropFirst().allSatisfy { $0.targetID == group.id && $0.groupID == group.id })
            try await fixture.accounts.assertNoPlaintext(secrets + [Self.password])
        }
    }

    @Test(arguments: [Int64(1), 604_800])
    func configuredInviteLinkContainsTheTokenOnceAndDescriptionsAreRedacted(expiresIn: Int64) async throws {
        try await withAdminCLI { fixture in
            let issuer = try await fixture.accounts.user(username: "issuer", kind: .admin)
            let publicURL = "https://sync.example.test:8443/paw?value=a+b&next=%2F"
            let result = try await fixture.run(["invite", "create", "--issuer", issuer.id, "--expires-in", String(expiresIn), "--json"],
                                               environment: ["MONKEYSPAW_PUBLIC_URL": publicURL])
            let output = try result.value(InviteJSON.self)
            let components = try #require(URLComponents(string: output.secret))
            #expect(components.scheme == "monkeyspaw" && components.host == "join")
            #expect(components.queryItems?.first { $0.name == "server" }?.value == publicURL)
            let token = try #require(components.queryItems?.first { $0.name == "token" }?.value)
            let once = result.output.components(separatedBy: token).count == 2 && result.error.isEmpty
            #expect(once)
            let events = try await fixture.persistence.auditEvents()
            let issuance = try #require(events.first { $0.action == "invite.create" })
            let issuedAt = try #require(ServerTimestamp.date(issuance.at))
            let expiresAt = try #require(ServerTimestamp.date(output.expiresAt))
            #expect(expiresAt.timeIntervalSince(issuedAt) == TimeInterval(expiresIn))
            #expect(try await fixture.persistence.storedInvite(token).expiresAt == output.expiresAt)
            let configuration = try ServerConfiguration(environment: ["MONKEYSPAW_PUBLIC_URL": publicURL])
            let invite = try await OperatorAdminService(database: fixture.database, configuration: configuration)
                .createInvite(issuerID: issuer.id, groupID: nil, role: nil, expiresIn: nil)
            let redacted = !String(describing: invite).contains(invite.secret) && !String(reflecting: invite).contains(invite.secret)
                && Mirror(reflecting: invite).children.isEmpty
            #expect(redacted)
            let inProcessLink = try #require(URLComponents(string: invite.secret))
            let inProcessToken = try #require(inProcessLink.queryItems?.first { $0.name == "token" }?.value)
            try await fixture.accounts.assertNoPlaintext([token, invite.secret, inProcessToken])
        }
    }

    @Test func inviteFailuresEnforceIssuerShapeLifetimeAndLiveGroupRules() async throws {
        try await withAdminCLI { fixture in
            let issuer = try await fixture.accounts.user(username: "issuer", kind: .admin)
            let member = try await fixture.accounts.user(username: "member")
            let group = try await GroupTestFixture(account: fixture.accounts).group(owner: member)
            for arguments in [["--issuer", member.id], ["--issuer", Self.missingID], ["--issuer", "s16-issuer-secret"],
                              ["--issuer", issuer.id, "--group", group.id], ["--issuer", issuer.id, "--role", "owner"],
                              ["--issuer", issuer.id, "--group", Self.missingID, "--role", "owner"],
                              ["--issuer", issuer.id, "--group", group.id, "--role", "s16-role-secret"],
                              ["--issuer", issuer.id, "--expires-in", "0"], ["--issuer", issuer.id, "--expires-in", "604801"],
                              ["--issuer", issuer.id, "--expires-in", "s16-expiry-secret"]] {
                try await fixture.run(["invite", "create"] + arguments).assertFailure(excluding: ["s16-issuer-secret", "s16-role-secret", "s16-expiry-secret"])
            }
            let session = try await fixture.accounts.session(member)
            try await GroupService(database: fixture.database).delete(id: group.id, session: session.identity)
            try await fixture.run(["invite", "create", "--issuer", issuer.id, "--group", group.id, "--role", "owner"]).assertFailure()
            _ = try await fixture.accounts.user(username: "backup", kind: .admin)
            #expect(try await fixture.run(["user", "disable", issuer.id]).status == 0)
            try await fixture.run(["invite", "create", "--issuer", issuer.id]).assertFailure()
            #expect(try await fixture.persistence.count("invites") == 0)
            #expect(try await fixture.persistence.auditEvents().filter { $0.action == "invite.create" }.isEmpty)
        }
    }
}

struct InviteJSON: Decodable {
    let secret: String
    let expiresAt: String
    let groupID: String?
    let role: SyncAPI.Role?
    private enum CodingKeys: String, CodingKey {
        case secret, role
        case expiresAt = "expires_at"
        case groupID = "group_id"
    }
}
