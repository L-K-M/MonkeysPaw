import Foundation
import MonkeysPawCore
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerGroupServiceTests {
    @Test func ownerPromotionSelfDemotionAndRejoiningPreserveTheRightTimes() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let target = try await fixture.user("target")
            let group = try await fixture.group(owner: owner)
            let ownerSession = try await fixture.account.session(owner)
            let targetSession = try await fixture.account.session(target)
            let added = try await fixture.service.upsertMember(id: group.id, userID: target.id, request: .init(role: .viewer), session: ownerSession.identity)
            fixture.account.clock.advance(60)
            let promoted = try await fixture.service.upsertMember(id: group.id, userID: target.id, request: .init(role: .owner), session: ownerSession.identity)
            #expect(promoted.role == .owner && promoted.joinedAt == added.joinedAt)
            let demoted = try await fixture.service.upsertMember(id: group.id, userID: owner.id, request: .init(role: .editor), session: ownerSession.identity)
            #expect(demoted.role == .editor && demoted.joinedAt == owner.createdAt)
            await #expect(throws: AccountError.forbidden) {
                _ = try await fixture.service.upsertMember(id: group.id, userID: owner.id, request: .init(role: .owner), session: ownerSession.identity)
            }
            try await fixture.service.removeMember(id: group.id, userID: owner.id, session: targetSession.identity)
            #expect(try await fixture.account.accounts.me(ownerSession.identity).groups.isEmpty)
            await #expect(throws: AccountError.notFound) { _ = try await fixture.service.members(id: group.id, session: ownerSession.identity) }
            fixture.account.clock.advance(60)
            try await fixture.persistence.execute("UPDATE users SET display_name = '' WHERE id = \(bind: owner.id)")
            let rejoined = try await fixture.service.upsertMember(id: group.id, userID: owner.id, request: .init(role: .viewer), session: targetSession.identity)
            #expect(rejoined.joinedAt == ServerTimestamp.string(fixture.account.clock.now()))
            #expect(rejoined.joinedAt != owner.createdAt && rejoined.displayName == "")
            let events = try await fixture.persistence.auditEvents()
            #expect(events.map(\.action) == ["membership.upsert", "membership.upsert", "membership.upsert", "membership.remove", "membership.upsert"])
            #expect(events.map(\.actorID) == [owner.id, owner.id, owner.id, target.id, target.id])
            #expect(events.map(\.targetID) == [target.id, target.id, owner.id, owner.id, owner.id])
            #expect(events.allSatisfy { $0.groupID == group.id && ULID($0.id)?.rawValue == $0.id })
            #expect(Set(events.map(\.id)).count == events.count)
            #expect(events.last?.at == ServerTimestamp.string(fixture.account.clock.now()))
        }
    }

    @Test(arguments: GroupTestRole.allCases)
    func adminsCannotSelfAddOrElevateButCanSafelyDemoteOrRemove(role: GroupTestRole) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let actor = try await fixture.user("admin", kind: .admin)
            let group = try await fixture.group(owner: owner)
            let session = try await fixture.account.session(actor)
            if let role = role.role { try await fixture.member(groupID: group.id, user: actor, role: role) }
            let denied: [SyncAPI.Role]
            let allowed: [SyncAPI.Role]
            switch role {
            case .nonMember: denied = [.owner, .editor, .viewer]; allowed = []
            case .viewer: denied = [.owner, .editor]; allowed = [.viewer]
            case .editor: denied = [.owner]; allowed = [.editor, .viewer]
            case .owner: denied = []; allowed = [.owner, .editor, .viewer]
            }
            for requested in denied {
                await #expect(throws: AccountError.forbidden) {
                    _ = try await fixture.service.upsertMember(id: group.id, userID: actor.id, request: .init(role: requested), session: session.identity)
                }
            }
            #expect(try await fixture.persistence.count("audit_events") == 0)
            for requested in allowed {
                let member = try await fixture.service.upsertMember(id: group.id, userID: actor.id, request: .init(role: requested), session: session.identity)
                #expect(member.role == requested && member.joinedAt == actor.createdAt)
            }
            if role == .nonMember {
                await #expect(throws: AccountError.notFound) { try await fixture.service.removeMember(id: group.id, userID: actor.id, session: session.identity) }
                let ownGroups = try await fixture.account.accounts.me(session.identity).groups
                #expect(ownGroups.isEmpty)
            } else {
                try await fixture.service.removeMember(id: group.id, userID: actor.id, session: session.identity)
                #expect(try await fixture.account.accounts.me(session.identity).groups.isEmpty)
            }
            #expect(try await fixture.service.members(id: group.id, session: session.identity).members.map(\.userID) == [owner.id])
        }
    }

    @Test(arguments: ["demote", "remove", "mixed"])
    func parallelOwnerChangesCannotRemoveTheLastOwner(operation: String) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let second = try await fixture.user("second")
            let admin = try await fixture.user("admin", kind: .admin)
            let ownerSession = try await fixture.account.session(owner)
            let adminSession = try await fixture.account.session(admin)
            for _ in 0..<5 {
                let group = try await fixture.service.create(.init(name: "Race"), session: ownerSession.identity)
                _ = try await fixture.service.upsertMember(id: group.id, userID: second.id, request: .init(role: .owner), session: ownerSession.identity)
                let start = LoginTestLatch()
                let successes = try await withThrowingTaskGroup(of: Bool.self) { tasks in
                    for (index, target) in [owner, second].enumerated() {
                        tasks.addTask {
                            await start.wait()
                            do {
                                if operation == "remove" || (operation == "mixed" && index == 0) {
                                    try await fixture.service.removeMember(id: group.id, userID: target.id, session: adminSession.identity)
                                } else {
                                    _ = try await fixture.service.upsertMember(id: group.id, userID: target.id, request: .init(role: .viewer), session: adminSession.identity)
                                }
                                return true
                            } catch AccountError.forbidden { return false }
                        }
                    }
                    await start.open()
                    var count = 0
                    for try await success in tasks { if success { count += 1 } }
                    return count
                }
                #expect(successes == 1)
                let members = try await fixture.service.members(id: group.id, session: adminSession.identity).members
                #expect(members.filter { $0.role == .owner }.count == 1)
                let events = try await fixture.persistence.auditEvents().filter { $0.groupID == group.id }
                #expect(events.count == 3)
            }
        }
    }

    @Test(arguments: ["demote", "remove"])
    func parallelSelfChangesKeepOneOwner(operation: String) async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let second = try await fixture.user("second")
            let group = try await fixture.group(owner: owner)
            try await fixture.member(groupID: group.id, user: second, role: .owner)
            let sessions = try await [fixture.account.session(owner), fixture.account.session(second)]
            let start = LoginTestLatch()
            let successes = try await withThrowingTaskGroup(of: Bool.self) { tasks in
                for session in sessions {
                    tasks.addTask {
                        await start.wait()
                        do {
                            if operation == "remove" {
                                try await fixture.service.removeMember(id: group.id, userID: session.user.id, session: session.identity)
                            } else {
                                _ = try await fixture.service.upsertMember(id: group.id, userID: session.user.id, request: .init(role: .editor), session: session.identity)
                            }
                            return true
                        } catch AccountError.forbidden { return false }
                    }
                }
                await start.open()
                var count = 0
                for try await success in tasks { if success { count += 1 } }
                return count
            }
            #expect(successes == 1)
            #expect(try await fixture.repository.read { groups, _, _ in try await groups.ownerCount(groupID: group.id) } == 1)
            #expect(try await fixture.persistence.count("audit_events") == 1)
        }
    }

    @Test func auditFailureRollsBackCreationRenameUpsertAndRemoval() async throws {
        try await withGroupFixture { fixture in
            let owner = try await fixture.user("owner")
            let target = try await fixture.user("target")
            let session = try await fixture.account.session(owner)
            for action in [AuditAction.groupCreate, .membershipUpsert] {
                let failing = GroupService(database: fixture.persistence.database, clock: fixture.account.clock.now) { audit, event in
                    try await audit.insert(event)
                    if event.action == action { throw InjectedAuditError.failure }
                }
                await #expect(throws: InjectedAuditError.failure) { _ = try await failing.create(.init(name: "Rollback"), session: session.identity) }
                #expect(try await fixture.persistence.count("groups") == 0)
                #expect(try await fixture.persistence.count("memberships") == 0)
                #expect(try await fixture.persistence.count("audit_events") == 0)
            }
            let group = try await fixture.group(owner: owner)
            let failing = GroupService(database: fixture.persistence.database, clock: fixture.account.clock.now) { audit, event in
                try await audit.insert(event)
                throw InjectedAuditError.failure
            }
            await #expect(throws: InjectedAuditError.failure) { _ = try await failing.rename(id: group.id, request: .init(name: "Rollback"), session: session.identity) }
            #expect(try await fixture.repository.read { groups, _, _ in try await groups.group(id: group.id) } == group)
            await #expect(throws: InjectedAuditError.failure) {
                _ = try await failing.upsertMember(id: group.id, userID: target.id, request: .init(role: .owner), session: session.identity)
            }
            #expect(try await fixture.persistence.count("memberships") == 1)
            try await fixture.member(groupID: group.id, user: target, role: .viewer)
            await #expect(throws: InjectedAuditError.failure) {
                _ = try await failing.upsertMember(id: group.id, userID: target.id, request: .init(role: .owner), session: session.identity)
            }
            await #expect(throws: InjectedAuditError.failure) { try await failing.removeMember(id: group.id, userID: target.id, session: session.identity) }
            let preserved = try await fixture.repository.read { groups, _, _ in try await groups.member(groupID: group.id, userID: target.id) }
            #expect(preserved?.role == .viewer && preserved?.joinedAt == target.createdAt)
            #expect(try await fixture.persistence.count("audit_events") == 0)
        }
    }

    @Test(arguments: ["demote", "remove", "disable", "revoke", "admin_demote"])
    func queuedWriteRechecksCurrentAuthority(change: String) async throws {
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
                    default: try await sql.raw("UPDATE users SET account_kind = 'member' WHERE id = \(bind: actor.id)").run()
                    }
                    await entered.open()
                    await release.wait()
                }
            }
            await entered.wait()
            let pending = Task { try await fixture.service.rename(id: group.id, request: .init(name: "Denied"), session: session.identity) }
            await release.open()
            try await blocker.value
            let expected: AccountError = change == "demote" ? .forbidden : (change == "remove" || change == "admin_demote" ? .notFound : .unauthorized)
            await #expect(throws: expected) { _ = try await pending.value }
            #expect(try await fixture.persistence.count("audit_events") == 0)
            #expect(try await fixture.repository.read { groups, _, _ in try await groups.group(id: group.id)?.name } == "Original")
        }
    }
}
