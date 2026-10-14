import Foundation
@testable import SyncScenarioSupport
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawServer

/// Extends Y12's real-router harness without another corpus or CI invocation.
final class SyncInviteIntegrationTests: XCTestCase {
    func testSingleUseInvitesRegisterJoinExpireAndRefreshNewGroupSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-sync-invites-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        let clock = ScenarioClock(now)
        let scenario = SyncScenario(id: "invites", now: now, servers: ["alpha", "beta"], users: ["owner", "member"],
            devices: [], prompts: [:], steps: [])
        try await SyncServerHarness.withServers(scenario, root: root, clock: clock, index: 0, clients: [:], symbols: [:]) { clients, _ in
            let transport = InProcessHTTPTransport(clients: clients)
            let owner = try ScenarioDevice(name: "Owner", directory: root.appendingPathComponent("owner"),
                clock: clock, entropy: ScenarioEntropy(seed: 1), transport: transport)
            let member = try ScenarioDevice(name: "Member", directory: root.appendingPathComponent("member"),
                clock: clock, entropy: ScenarioEntropy(seed: 2), transport: InProcessHTTPTransport(clients: clients))
            let newcomer = try ScenarioDevice(name: "New", directory: root.appendingPathComponent("new"),
                clock: clock, entropy: ScenarioEntropy(seed: 3), transport: InProcessHTTPTransport(clients: clients))
            let clipboard = InviteIntegrationClipboard()
            let ownerInvites = SyncInviteService(account: owner.account, clipboard: clipboard)
            let memberInvites = SyncInviteService(account: member.account, clipboard: clipboard)
            let newInvites = SyncInviteService(account: newcomer.account, clipboard: clipboard)
            do {
                try await self.login(owner, user: "owner", server: "alpha")
                try await self.login(member, user: "member", server: "alpha")
                let groupResponse = try await owner.request(method: .post, path: "/api/v1/groups",
                    body: .object(["name": .string("Invited team")]))
                XCTAssertEqual(groupResponse.statusCode, 200)
                let group = try JSONDecoder().decode(SyncAPI.Group.self, from: groupResponse.body)
                let groupID = try SyncIdentifiers.ulid(group.id)
                let promptID = try ULID.generate(at: now, entropy: Array(repeating: 9, count: 10))
                let content = "---\nformat: 1\nid: " + promptID.rawValue + "\ntitle: Shared\n---\nShared prompt.\n"
                let put = try await owner.request(method: .put, path: "/api/v1/prompts/" + promptID.rawValue,
                    body: .object(["scope": .string("group"), "group_id": .string(group.id), "path": .string("shared.md"),
                        "base_rev": .integer(0), "content": .string(content)]))
                XCTAssertEqual(put.statusCode, 200)
                owner.sync.syncNow()
                try await owner.settle()

                let first = try await ownerInvites.create(groupID: groupID, role: .viewer)
                XCTAssertTrue(clipboard.writes.isEmpty)
                XCTAssertEqual(first.expiresAt, ServerTimestamp.string(now.addingTimeInterval(7 * 24 * 60 * 60)))
                try ownerInvites.copy(first)
                XCTAssertEqual(clipboard.writes.count, 1)
                XCTAssertTrue(clipboard.writes[0] == first.link)
                member.transport.resetMetrics()
                let pending = try memberInvites.stage(first.link)
                XCTAssertTrue(pending.destination.canJoin)
                XCTAssertTrue(member.transport.traces.isEmpty, "Staging contacted the server")
                var password = ""
                let accepted = try await memberInvites.accept(pending, as: .existingAccount,
                    username: "", password: &password, deviceName: "")
                try await member.settle()
                XCTAssertNil(accepted.issue)
                XCTAssertTrue(accepted.snapshot.me?.groups.contains { $0.groupID == group.id && $0.role == .viewer } == true)
                XCTAssertTrue(member.transport.traces.prefix(2).map(\.path) == ["/api/v1/groups/join", "/api/v1/me"])
                XCTAssertTrue(member.transport.traces.contains { $0.path == "/api/v1/sync/pull" && $0.status == 200 })
                try self.assertGroupSnapshot(member, groupID: groupID, promptID: promptID)
                await self.assertUnavailable {
                    try await memberInvites.accept(pending, as: .existingAccount, username: "", password: &password, deviceName: "")
                }

                let registration = try await ownerInvites.create(groupID: groupID, role: .editor)
                let registerStage = try newInvites.stage(registration.link)
                XCTAssertNil(registerStage.destination.currentAccount)
                XCTAssertTrue(newcomer.transport.traces.isEmpty)
                password = SyncServerHarness.password
                let registered = try await newInvites.accept(registerStage, as: .newAccount,
                    username: "newmember", password: &password, deviceName: "New")
                XCTAssertTrue(password.isEmpty, "Password input was not consumed")
                XCTAssertTrue(registered.snapshot.enabled)
                XCTAssertNil(registered.issue)
                XCTAssertEqual(registered.snapshot.account?.username, "newmember")
                try await newcomer.settle()
                try self.assertGroupSnapshot(newcomer, groupID: groupID, promptID: promptID)
                XCTAssertTrue(registered.snapshot.me?.groups.contains { $0.groupID == group.id && $0.role == .editor } == true)
                // The server also consumed registration's token; a current user cannot join with it.
                let consumedRegistration = try memberInvites.stage(registration.link)
                await self.assertUnavailable {
                    try await memberInvites.accept(consumedRegistration, as: .existingAccount,
                        username: "", password: &password, deviceName: "")
                }

                // Redeeming a lower role retains the current editor role and still consumes the token.
                let lower = try await ownerInvites.create(groupID: groupID, role: .viewer)
                let lowerStage = try newInvites.stage(lower.link)
                let retained = try await newInvites.accept(lowerStage, as: .existingAccount,
                    username: "", password: &password, deviceName: "")
                try await newcomer.settle()
                XCTAssertTrue(retained.snapshot.me?.groups.contains { $0.groupID == group.id && $0.role == .editor } == true)
                await self.assertUnavailable {
                    try await newInvites.accept(lowerStage, as: .existingAccount, username: "", password: &password, deviceName: "")
                }

                let shortResponse = try await owner.request(method: .post, path: "/api/v1/groups/" + group.id + "/invites",
                    body: .object(["role": .string("editor"), "expires_in": .integer(1)]))
                XCTAssertEqual(shortResponse.statusCode, 200)
                let short = try JSONDecoder().decode(SyncAPI.InviteResponse.self, from: shortResponse.body)
                let expiredStage = try memberInvites.stage(short.inviteToken, server: "https://alpha.test")
                clock.advance(1)
                await self.assertUnavailable {
                    try await memberInvites.accept(expiredStage, as: .existingAccount, username: "", password: &password, deviceName: "")
                }

                let cross = try await ownerInvites.create(groupID: groupID, role: .editor)
                let staleAccountStage = try memberInvites.stage(cross.link)
                try await self.login(member, user: "member", server: "beta")
                member.transport.resetMetrics()
                do {
                    _ = try await memberInvites.accept(staleAccountStage, as: .existingAccount,
                        username: "", password: &password, deviceName: "")
                    XCTFail("Stale account redeemed an invite")
                } catch { XCTAssertTrue(error as? InviteIssue == .accountChanged) }
                let crossStage = try memberInvites.stage(cross.link)
                XCTAssertFalse(crossStage.destination.canJoin)
                do {
                    _ = try await memberInvites.accept(crossStage, as: .existingAccount,
                        username: "", password: &password, deviceName: "")
                    XCTFail("Cross-server credentials were used")
                } catch { XCTAssertTrue(error as? InviteIssue == .wrongServer) }
                XCTAssertTrue(member.transport.traces.isEmpty)
                try await self.login(member, user: "member", server: "alpha")
                let fresh = try memberInvites.stage(cross.link)
                _ = try await memberInvites.accept(fresh, as: .existingAccount, username: "", password: &password, deviceName: "")
                try await member.settle()
                XCTAssertTrue(member.account.snapshot.me?.groups.contains { $0.groupID == group.id && $0.role == .editor } == true)

                let secrets = [first.link, registration.link, lower.link, cross.link, short.inviteToken,
                    try SyncInviteLink(first.link).token.withValue { $0 },
                    try SyncInviteLink(registration.link).token.withValue { $0 },
                    try SyncInviteLink(lower.link).token.withValue { $0 },
                    try SyncInviteLink(cross.link).token.withValue { $0 }]
                try self.assertNoInviteOnDisk(root, secrets: secrets)
                for device in [owner, member, newcomer] { device.sync.stop(); await device.sync.drain() }
            } catch {
                for device in [owner, member, newcomer] { device.sync.stop(); await device.sync.drain() }
                throw error
            }
        }
    }

    private func login(_ device: ScenarioDevice, user: String, server: String) async throws {
        var password = SyncServerHarness.password
        _ = try await device.account.login(server: "https://" + server + ".test", username: user,
            password: &password, deviceName: device.name)
        XCTAssertTrue(password.isEmpty, "Password input was not consumed")
        try await device.settle()
    }

    private func assertUnavailable<T>(_ operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Unavailable invite was accepted") }
        catch { XCTAssertTrue(error as? InviteIssue == .unavailableInvite, "Unexpected invite failure") }
    }

    private func assertGroupSnapshot(_ device: ScenarioDevice, groupID: ULID, promptID: ULID) throws {
        let state = try XCTUnwrap(device.states.snapshot.value)
        let folder = try XCTUnwrap(state.groups[groupID]?.folder)
        XCTAssertNotNil(state.cursors[.group(groupID)])
        XCTAssertEqual(state.prompts[.assigned(promptID)]?.scope.rawValue, "group:" + groupID.rawValue)
        let bytes = try device.files.read(at: "Groups/" + folder + "/shared.md")
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Shared prompt."))
    }

    private func assertNoInviteOnDisk(_ root: URL, secrets: [String]) throws {
        let entries = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        while let file = entries.nextObject() as? URL {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let bytes = try Data(contentsOf: file)
            for secret in secrets { XCTAssertNil(bytes.range(of: Data(secret.utf8)), "Invite bytes persisted") }
        }
    }
}

private final class InviteIntegrationClipboard: Clipboard {
    var writes: [String] = []
    func writeText(_ text: String) { writes.append(text) }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { completion(writes.last) }
}
