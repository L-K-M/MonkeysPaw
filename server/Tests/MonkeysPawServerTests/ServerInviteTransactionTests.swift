import FluentSQLiteDriver
import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerInviteTransactionTests {
    @Test func auditFailureRollsBackIssuanceRegistrationAndJoin() async throws {
        try await withGroupFixture { fixture in
            let admin = try await fixture.user("admin", kind: .admin)
            let member = try await fixture.user("member")
            let group = try await fixture.group(owner: admin)
            let issuer = try await fixture.account.session(admin)
            let session = try await fixture.account.session(member)
            let service = fixture.inviteService()
            let failedCreate = fixture.inviteService { audit, event in
                try await audit.insert(event)
                throw InjectedAuditError.failure
            }
            await #expect(throws: InjectedAuditError.failure) {
                _ = try await failedCreate.createAdmin(.init(target: .account), session: issuer.identity)
            }
            await #expect(throws: InjectedAuditError.failure) {
                _ = try await failedCreate.createGroup(id: group.id, request: .init(role: .viewer), session: issuer.identity)
            }
            #expect(try await fixture.persistence.count("invites") == 0)
            #expect(try await fixture.persistence.count("audit_events") == 0)

            for (index, action) in [AuditAction.userCreate, .membershipUpsert, .inviteConsume].enumerated() {
                let issued = try await service.createGroup(id: group.id, request: .init(role: .editor), session: issuer.identity)
                let failed = fixture.inviteService { audit, event in
                    try await audit.insert(event)
                    if event.action == action { throw InjectedAuditError.failure }
                }
                let users = try await fixture.persistence.count("users")
                let devices = try await fixture.persistence.count("devices")
                let members = try await fixture.persistence.count("memberships")
                let audits = try await fixture.persistence.count("audit_events")
                let request = SyncAPI.RegisterRequest(inviteToken: issued.response.inviteToken, username: "rollback-\(index)",
                                                      password: AccountTestFixture.password, deviceName: "Rollback device")
                await #expect(throws: InjectedAuditError.failure) { _ = try await failed.register(request) }
                #expect(try await fixture.persistence.storedInvite(issued.response.inviteToken).consumedAt == nil)
                #expect(try await fixture.persistence.count("users") == users)
                #expect(try await fixture.persistence.count("devices") == devices)
                #expect(try await fixture.persistence.count("memberships") == members)
                #expect(try await fixture.persistence.count("audit_events") == audits)
                _ = try await service.register(request)
            }

            for action in [AuditAction.membershipUpsert, .inviteConsume] {
                let issued = try await service.createGroup(id: group.id, request: .init(role: .viewer), session: issuer.identity)
                let before = try await fixture.repository.read { groups, _, _ in try await groups.member(groupID: group.id, userID: member.id) }
                let audits = try await fixture.persistence.count("audit_events")
                let failed = fixture.inviteService { audit, event in
                    try await audit.insert(event)
                    if event.action == action { throw InjectedAuditError.failure }
                }
                let request = SyncAPI.JoinGroupRequest(inviteToken: issued.response.inviteToken)
                await #expect(throws: InjectedAuditError.failure) { _ = try await failed.join(request, session: session.identity) }
                #expect(try await fixture.persistence.storedInvite(issued.response.inviteToken).consumedAt == nil)
                #expect(try await fixture.repository.read { groups, _, _ in try await groups.member(groupID: group.id, userID: member.id) } == before)
                #expect(try await fixture.persistence.count("audit_events") == audits)
                _ = try await service.join(request, session: session.identity)
            }
        }
    }

    @Test func deviceFailureRollsBackTheConsumedInviteAndAccount() async throws {
        try await withGroupFixture { fixture in
            let admin = try await fixture.user("admin", kind: .admin)
            let group = try await fixture.group(owner: admin)
            let issuer = try await fixture.account.session(admin)
            let service = fixture.inviteService()
            let issued = try await service.createGroup(id: group.id, request: .init(role: .editor), session: issuer.identity)
            try await fixture.persistence.execute("""
                CREATE TRIGGER s10_fail_device BEFORE INSERT ON devices
                WHEN NEW.name = 'Broken device' BEGIN SELECT RAISE(ABORT, 'injected device failure'); END
                """)
            let request = SyncAPI.RegisterRequest(inviteToken: issued.response.inviteToken, username: "retry",
                                                  password: AccountTestFixture.password, deviceName: "Broken device")
            do {
                _ = try await service.register(request)
                Issue.record("Device insert should fail")
            } catch {
                #expect((error as? any DatabaseError)?.isConstraintFailure == true)
            }
            #expect(try await fixture.persistence.count("users") == 1)
            #expect(try await fixture.persistence.count("devices") == 1)
            #expect(try await fixture.persistence.count("memberships") == 1)
            #expect(try await fixture.persistence.count("audit_events") == 1)
            #expect(try await fixture.persistence.storedInvite(issued.response.inviteToken).consumedAt == nil)
            try await fixture.persistence.execute("DROP TRIGGER s10_fail_device")
            _ = try await service.register(request)
            #expect(try await fixture.persistence.count("users") == 2)
            #expect(try await fixture.persistence.count("devices") == 2)
        }
    }

    @Test(arguments: ["expire", "consume", "delete"])
    func registrationRechecksInviteAndGroupAfterBcrypt(change: String) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let member = try await fixture.user("member")
            let group = try await fixture.group(owner: owner)
            let issuer = try await fixture.account.session(owner)
            let session = try await fixture.account.session(member)
            let issued = try await fixture.inviteService().createGroup(id: group.id, request: .init(role: .viewer, expiresIn: 1), session: issuer.identity)
            let entered = LoginTestLatch()
            let release = LoginTestLatch()
            let service = fixture.inviteService(passwords: InviteTestHasher(entered: entered, release: release))
            let pending = Task {
                try await service.register(.init(inviteToken: issued.response.inviteToken, username: "pending",
                                                 password: AccountTestFixture.password, deviceName: "Pending device"))
            }
            await entered.wait()
            switch change {
            case "expire": fixture.account.clock.advance(1)
            case "consume": _ = try await fixture.inviteService().join(.init(inviteToken: issued.response.inviteToken), session: session.identity)
            default: try await fixture.service.delete(id: group.id, session: issuer.identity)
            }
            await release.open()
            await #expect(throws: change == "delete" ? AccountError.notFound : .malformedRequest) { _ = try await pending.value }
            #expect(try await fixture.persistence.count("users") == 2)
            #expect(try await fixture.persistence.count("devices") == 2)
            let stored = try await fixture.persistence.storedInvite(issued.response.inviteToken)
            #expect((stored.consumedAt != nil) == (change == "consume"))
        }
    }

    @Test(arguments: ["demote", "remove", "disable", "revoke", "admin_demote", "delete"])
    func queuedIssuanceRechecksAuthority(change: String) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("actor", kind: change == "admin_demote" ? .admin : .member)
            let group = try await fixture.group(owner: owner)
            if change != "admin_demote" { try await fixture.member(groupID: group.id, user: actor, role: .owner) }
            let session = try await fixture.account.session(actor)
            let entered = LoginTestLatch()
            let release = LoginTestLatch()
            let blocker = Task {
                try await fixture.persistence.database.write { sql in
                    switch change {
                    case "demote": try await sql.raw("UPDATE memberships SET role = 'editor' WHERE user_id = \(bind: actor.id)").run()
                    case "remove": try await sql.raw("DELETE FROM memberships WHERE user_id = \(bind: actor.id)").run()
                    case "disable": try await sql.raw("UPDATE users SET disabled_at = created_at WHERE id = \(bind: actor.id)").run()
                    case "revoke": try await sql.raw("UPDATE devices SET revoked_at = created_at WHERE id = \(bind: session.identity.deviceID)").run()
                    case "delete": try await sql.raw("UPDATE groups SET deleted_at = created_at WHERE id = \(bind: group.id)").run()
                    default: try await sql.raw("UPDATE users SET account_kind = 'member' WHERE id = \(bind: actor.id)").run()
                    }
                    await entered.open()
                    await release.wait()
                }
            }
            await entered.wait()
            let pending = Task { try await fixture.inviteService().createGroup(id: group.id, request: .init(role: .viewer), session: session.identity) }
            await release.open()
            try await blocker.value
            let expected: AccountError = change == "demote" ? .forbidden : (["disable", "revoke"].contains(change) ? .unauthorized : .notFound)
            await #expect(throws: expected) { _ = try await pending.value }
            #expect(try await fixture.persistence.count("invites") == 0)
            #expect(try await fixture.persistence.count("audit_events") == 0)
        }
    }

    @Test(arguments: ["disable", "revoke", "admin_promote", "delete"])
    func queuedJoinRechecksSessionAccountKindAndGroup(change: String) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let member = try await fixture.user("member")
            let group = try await fixture.group(owner: owner)
            let issuer = try await fixture.account.session(owner)
            let session = try await fixture.account.session(member)
            let issued = try await fixture.inviteService().createGroup(id: group.id, request: .init(role: .editor), session: issuer.identity)
            let entered = LoginTestLatch()
            let release = LoginTestLatch()
            let blocker = Task {
                try await fixture.persistence.database.write { sql in
                    switch change {
                    case "disable": try await sql.raw("UPDATE users SET disabled_at = created_at WHERE id = \(bind: member.id)").run()
                    case "revoke": try await sql.raw("UPDATE devices SET revoked_at = created_at WHERE id = \(bind: session.identity.deviceID)").run()
                    case "delete": try await sql.raw("UPDATE groups SET deleted_at = created_at WHERE id = \(bind: group.id)").run()
                    default: try await sql.raw("UPDATE users SET account_kind = 'admin' WHERE id = \(bind: member.id)").run()
                    }
                    await entered.open()
                    await release.wait()
                }
            }
            await entered.wait()
            let pending = Task { try await fixture.inviteService().join(.init(inviteToken: issued.response.inviteToken), session: session.identity) }
            await release.open()
            try await blocker.value
            let expected: AccountError = change == "admin_promote" ? .forbidden : (change == "delete" ? .notFound : .unauthorized)
            await #expect(throws: expected) { _ = try await pending.value }
            #expect(try await fixture.persistence.storedInvite(issued.response.inviteToken).consumedAt == nil)
            #expect(try await fixture.persistence.count("memberships") == 1)
            #expect(try await fixture.persistence.count("audit_events") == 1)
        }
    }

    @Test func hashOnlyStorageAndSingleUseSurviveRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s10-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = DatabaseConfiguration(environment: ["MONKEYSPAW_DATA_DIR": directory.path])
        let tokens = try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            let fixture = GroupTestFixture(account: .init(persistence: .init(database: database)))
            let admin = try await fixture.user("admin", kind: .admin)
            let session = try await fixture.account.session(admin)
            let service = fixture.inviteService(publicURL: nil)
            var tokens: [String] = []
            for index in 0..<64 {
                let issued = try await service.createAdmin(.init(target: .account, expiresIn: index == 0 ? 604_800 : nil), session: session.identity)
                let token = DeviceToken(value: issued.response.inviteToken)
                #expect(token.isValid && token.hash.count == 64 && issued.link == nil)
                let decoded = Data(base64Encoded: token.value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
                #expect(decoded?.count == 32)
                let stored = try await fixture.persistence.storedInvite(token.value)
                #expect(stored.tokenHash == token.hash && stored.target == .account && stored.consumedAt == nil)
                #expect(stored.createdBy == admin.id && stored.expiresAt == issued.response.expiresAt)
                #expect(String(reflecting: stored) == "InviteRecord(<redacted>)")
                tokens.append(token.value)
            }
            #expect(Set(tokens).count == tokens.count)
            try await fixture.account.assertNoPlaintext(tokens)
            return tokens
        }
        try AccountTestFixture.scan(directory, excluding: tokens)
        try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            let fixture = GroupTestFixture(account: .init(persistence: .init(database: database)))
            let service = fixture.inviteService()
            let token = try #require(tokens.first)
            let request = SyncAPI.RegisterRequest(inviteToken: token, username: "restarted", password: AccountTestFixture.password, deviceName: "Restart device")
            _ = try await service.register(request)
            await #expect(throws: AccountError.malformedRequest) { _ = try await service.register(request) }
            #expect(try await fixture.persistence.count("invites") == 64)
            try await fixture.account.assertNoPlaintext(tokens)
        }
        try AccountTestFixture.scan(directory, excluding: tokens)
    }
}
