import Foundation
import SQLKit
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawServer

/// Y12's production router, authentication and serialized SQLite transactions.
/// Setup uses SQL only for account kind and an audit-failure injection.
final class SyncGroupIntegrationTests: XCTestCase {
    func testGroupLifecycleMembersAuthorizationAndTransactionalRejections() async throws {
        try await withGroups { devices, symbols in
            let owner = try XCTUnwrap(devices["owner"])
            let editor = try XCTUnwrap(devices["editor"])
            let viewer = try XCTUnwrap(devices["viewer"])
            let admin = try XCTUnwrap(devices["admin"])
            let outsider = try XCTUnwrap(devices["outsider"])
            let ownerService = SyncGroupService(account: owner.account, clipboard: GroupIntegrationClipboard())
            let created = await self.execute(ownerService, owner, .create("Managed team"))
            let group = try XCTUnwrap(created.selectedGroupID)
            XCTAssertTrue(created.changeConfirmed)
            XCTAssertNil(created.issue)
            XCTAssertEqual(created.snapshot.me?.groups.first?.role, .owner)
            XCTAssertEqual(created.members.count, 1)
            XCTAssertEqual(created.members.first?.userID, owner.account.snapshot.account?.identity.userID.rawValue)
            try await owner.settle()
            XCTAssertEqual(owner.states.snapshot.value?.groups[group]?.role, .owner)

            let editorID = try self.user("editor", symbols)
            let viewerID = try self.user("viewer", symbols)
            let ownerID = try self.user("owner", symbols)
            let adminID = try self.user("admin", symbols)
            _ = await self.execute(ownerService, owner, .setRole(group, editorID, .editor))
            let joined = await self.execute(ownerService, owner, .setRole(group, viewerID, .viewer))
            XCTAssertEqual(joined.members.count, 3)
            let joinedAt = try XCTUnwrap(joined.members.first { $0.userID == viewerID.rawValue }?.joinedAt)
            let changed = await self.execute(ownerService, owner, .setRole(group, viewerID, .editor))
            XCTAssertEqual(changed.members.first { $0.userID == viewerID.rawValue }?.joinedAt, joinedAt)
            _ = await self.execute(ownerService, owner, .setRole(group, viewerID, .viewer))

            for device in [editor, viewer] {
                let service = SyncGroupService(account: device.account, clipboard: GroupIntegrationClipboard())
                let list = await self.execute(service, device, .refresh(group))
                XCTAssertNil(list.issue)
                XCTAssertEqual(list.members.count, 3)
                for command in [SyncGroupCommand.rename(group, "Denied"), .delete(group),
                    .setRole(group, ownerID, .viewer), .removeMember(group, ownerID), .createInvite(group, .viewer)] {
                    let result = await self.execute(service, device, command)
                    XCTAssertEqual(result.issue, .forbidden)
                    XCTAssertFalse(result.changeConfirmed)
                    XCTAssertEqual(result.snapshot.me?.groups.first?.name, "Managed team")
                }
                try await device.settle()
                XCTAssertTrue(device.transport.traces.contains { $0.status == 403 && $0.path.hasPrefix("/api/v1/groups/") })
            }

            for command in [SyncGroupCommand.setRole(group, ownerID, .viewer), .removeMember(group, ownerID)] {
                let denied = await self.execute(ownerService, owner, command)
                XCTAssertEqual(denied.issue, .forbidden)
                XCTAssertFalse(denied.changeConfirmed)
                XCTAssertEqual(denied.members.first { $0.userID == ownerID.rawValue }?.role, .owner)
            }

            // Admin status permits metadata management but cannot self-grant
            // membership, including through an existing viewer membership.
            let adminService = SyncGroupService(account: admin.account, clipboard: GroupIntegrationClipboard())
            let selfAdd = await self.execute(adminService, admin, .setRole(group, adminID, .viewer))
            XCTAssertEqual(selfAdd.issue, .forbidden)
            XCTAssertTrue(selfAdd.snapshot.me?.groups.isEmpty == true)
            _ = await self.execute(ownerService, owner, .setRole(group, adminID, .viewer))
            for role in [SyncAPI.Role.editor, .owner] {
                let denied = await self.execute(adminService, admin, .setRole(group, adminID, role))
                XCTAssertEqual(denied.issue, .forbidden)
                XCTAssertEqual(denied.snapshot.me?.groups.first?.role, .viewer)
            }
            let sameRole = await self.execute(adminService, admin, .setRole(group, adminID, .viewer))
            XCTAssertNil(sameRole.issue)
            XCTAssertTrue(sameRole.changeConfirmed)

            let outsiderService = SyncGroupService(account: outsider.account, clipboard: GroupIntegrationClipboard())
            let invisible = await self.execute(outsiderService, outsider, .rename(group, "Invisible"))
            XCTAssertEqual(invisible.issue, .notFound)
            XCTAssertNil(invisible.selectedGroupID)
            XCTAssertTrue(invisible.members.isEmpty)

            // Audit insert failure occurs inside the actual server transaction.
            // The membership rolls back and remains visibly failed on the client.
            let blockedID = try self.user("blocked", symbols)
            let failed = await self.execute(ownerService, owner, .setRole(group, blockedID, .editor))
            XCTAssertEqual(failed.issue, .account(.serverFailure))
            XCTAssertFalse(failed.changeConfirmed)
            XCTAssertFalse(failed.members.contains { $0.userID == blockedID.rawValue })
            XCTAssertTrue(owner.transport.traces.contains { $0.status == 500 && $0.path.hasSuffix("/members/" + blockedID.rawValue) })

            let promoted = await self.execute(ownerService, owner, .setRole(group, editorID, .owner))
            XCTAssertNil(promoted.issue)
            let demoted = await self.execute(ownerService, owner, .setRole(group, ownerID, .viewer))
            XCTAssertNil(demoted.issue)
            XCTAssertEqual(demoted.snapshot.me?.groups.first?.role, .viewer)
            let editorService = SyncGroupService(account: editor.account, clipboard: GroupIntegrationClipboard())
            let renamed = await self.execute(editorService, editor, .rename(group, "Renamed team"))
            XCTAssertNil(renamed.issue)
            XCTAssertEqual(renamed.snapshot.me?.groups.first?.name, "Renamed team")
            let removed = await self.execute(editorService, editor, .removeMember(group, viewerID))
            XCTAssertNil(removed.issue)
            XCTAssertFalse(removed.members.contains { $0.userID == viewerID.rawValue })
            let deleted = await self.execute(editorService, editor, .delete(group))
            XCTAssertTrue(deleted.changeConfirmed)
            XCTAssertNil(deleted.issue)
            XCTAssertNil(deleted.selectedGroupID)
            try await editor.settle()
            XCTAssertNil(editor.states.snapshot.value?.groups[group])
            let gone = await self.execute(ownerService, owner, .rename(group, "Gone"))
            XCTAssertEqual(gone.issue, .notFound)
        }
    }

    func testModelsRefreshCommittedRolesModesDraftsAndRemovedScope() async throws {
        try await withGroups { devices, symbols in
            let owner = try XCTUnwrap(devices["owner"])
            let editor = try XCTUnwrap(devices["editor"])
            let viewer = try XCTUnwrap(devices["viewer"])
            let clipboard = GroupIntegrationClipboard()
            let ownerMain = GroupIntegrationMain()
            let ownerModel = GroupManagementModel(service: SyncGroupService(account: owner.account, clipboard: clipboard), mainThread: ownerMain)
            await self.settle(ownerModel, ownerMain)
            owner.transport.resetMetrics()
            ownerModel.create(name: "Model team")
            await self.settle(ownerModel, ownerMain)
            try await owner.settle()
            let group = try XCTUnwrap(ownerModel.state.selectedGroupID)
            XCTAssertTrue(ownerModel.state.canManage)
            XCTAssertTrue(ownerModel.state.changeConfirmed)
            XCTAssertTrue(owner.transport.traces.prefix(3).map(\.path) == ["/api/v1/groups", "/api/v1/me", "/api/v1/groups/" + group.rawValue + "/members"])
            XCTAssertTrue(owner.transport.traces.contains { $0.path == "/api/v1/sync/pull" })
            ownerModel.setRole(userID: try self.user("editor", symbols).rawValue, role: .editor)
            await self.settle(ownerModel, ownerMain)
            ownerModel.setRole(userID: try self.user("viewer", symbols).rawValue, role: .viewer)
            await self.settle(ownerModel, ownerMain)
            let prompt = try ULID.generate(at: owner.clock.now(), entropy: Array(repeating: 7, count: 10))
            let source = "---\nformat: 1\nid: " + prompt.rawValue + "\ntitle: Shared\n---\nShared group prompt.\n"
            let put = try await owner.request(method: .put, path: "/api/v1/prompts/" + prompt.rawValue,
                body: .object(["scope": .string("group"), "group_id": .string(group.rawValue), "base_rev": .integer(0),
                    "path": .string("shared.md"), "content": .string(source)]))
            XCTAssertEqual(put.statusCode, 200)

            let editorMain = GroupIntegrationMain(), viewerMain = GroupIntegrationMain()
            let editorModel = GroupManagementModel(service: SyncGroupService(account: editor.account, clipboard: clipboard), mainThread: editorMain)
            let viewerModel = GroupManagementModel(service: SyncGroupService(account: viewer.account, clipboard: clipboard), mainThread: viewerMain)
            for (model, main) in [(editorModel, editorMain), (viewerModel, viewerMain)] {
                await self.settle(model, main)
                model.refresh()
                await self.settle(model, main)
                model.selectGroup(group)
                await self.settle(model, main)
                XCTAssertEqual(model.state.members.count, 3)
                XCTAssertFalse(model.state.canManage)
            }
            try await editor.settle(); try await viewer.settle()
            let editorFolder = try XCTUnwrap(editor.states.snapshot.value?.groups[group]?.folder)
            let viewerFolder = try XCTUnwrap(viewer.states.snapshot.value?.groups[group]?.folder)
            XCTAssertEqual(try editor.files.mode(at: "Groups/" + editorFolder + "/shared.md"), .normal)
            XCTAssertEqual(try viewer.files.mode(at: "Groups/" + viewerFolder + "/shared.md"), .readOnly)
            let draftGeneration = editorModel.state.inputReset
            ownerModel.setRole(userID: try self.user("editor", symbols).rawValue, role: .viewer)
            await self.settle(ownerModel, ownerMain)
            editorModel.refresh()
            await self.settle(editorModel, editorMain)
            try await editor.settle()
            XCTAssertEqual(editorModel.state.selectedGroup?.role, .viewer)
            XCTAssertNotEqual(editorModel.state.inputReset, draftGeneration)
            XCTAssertEqual(editor.states.snapshot.value?.groups[group]?.role, .viewer)
            XCTAssertEqual(try editor.files.mode(at: "Groups/" + editorFolder + "/shared.md"), .readOnly)

            let removalGeneration = editorModel.state.inputReset
            ownerModel.removeMember(userID: try self.user("editor", symbols).rawValue)
            await self.settle(ownerModel, ownerMain)
            editorModel.refresh()
            await self.settle(editorModel, editorMain)
            try await editor.settle()
            XCTAssertNil(editorModel.state.selectedGroupID)
            XCTAssertTrue(editorModel.state.members.isEmpty)
            XCTAssertNotEqual(editorModel.state.inputReset, removalGeneration)
            XCTAssertNil(editor.states.snapshot.value?.groups[group])
            XCTAssertNil(editor.states.snapshot.value?.prompts[.assigned(prompt)])
            XCTAssertNil(try editor.files.stamp(at: "Groups/" + editorFolder + "/shared.md"))
            let deniedRead = try await editor.request(method: .get, path: "/api/v1/prompts/" + prompt.rawValue, body: nil)
            XCTAssertEqual(deniedRead.statusCode, 404)

            ownerModel.createInvite(role: .viewer)
            await self.settle(ownerModel, ownerMain)
            XCTAssertNotNil(ownerModel.state.createdInvite)
            XCTAssertTrue(clipboard.writes.isEmpty)
            ownerModel.copyCreatedInvite()
            ownerMain.flush()
            XCTAssertEqual(clipboard.writes.count, 1)
            ownerModel.dismiss()
            ownerMain.flush()
            XCTAssertNil(ownerModel.state.createdInvite)

            // Rejection reaches the model without changing the last owner.
            ownerModel.removeMember(userID: try self.user("owner", symbols).rawValue)
            await self.settle(ownerModel, ownerMain)
            XCTAssertEqual(ownerModel.state.error, .forbidden)
            XCTAssertFalse(ownerModel.state.changeConfirmed)
            XCTAssertEqual(ownerModel.state.selectedGroup?.role, .owner)
            ownerModel.deleteGroup()
            await self.settle(ownerModel, ownerMain)
            XCTAssertTrue(ownerModel.state.changeConfirmed)
            viewerModel.refresh()
            await self.settle(viewerModel, viewerMain)
            try await viewer.settle()
            XCTAssertNil(viewer.states.snapshot.value?.groups[group])
            XCTAssertNil(viewerModel.state.selectedGroupID)
            for model in [ownerModel, editorModel, viewerModel] { model.retire(); await model.drain() }
        }
    }

    private func withGroups(_ operation: @escaping ([String: ScenarioDevice], [String: String]) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-sync-groups-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        let clock = ScenarioClock(now)
        let scenario = SyncScenario(id: "groups", now: now, servers: ["alpha"],
            users: ["owner", "editor", "viewer", "admin", "outsider", "blocked"], devices: [], prompts: [:], steps: [])
        try await withScenarioDeadline(ContinuousClock.now.advanced(by: .seconds(120))) {
            try await SyncServerHarness.withServers(scenario, root: root, clock: clock, index: 0, clients: [:], symbols: [:],
                configureDatabase: { database, symbols in
                    let blocked = try XCTUnwrap(symbols["user.alpha.blocked"])
                    try await database.write { sql in
                        try await sql.raw("UPDATE users SET account_kind = 'admin' WHERE username = 'admin'").run()
                        try await sql.raw("""
                            CREATE TRIGGER reject_group_test_audit BEFORE INSERT ON audit_events
                            WHEN NEW.action = 'membership.upsert' AND NEW.target = \(literal: blocked)
                            BEGIN SELECT RAISE(ABORT, 'group-test-audit-failure'); END
                            """).run()
                    }
                }) { clients, symbols in
                    var devices: [String: ScenarioDevice] = [:]
                    do {
                        for (index, user) in ["owner", "editor", "viewer", "admin", "outsider"].enumerated() {
                            let device = try ScenarioDevice(name: user, directory: root.appendingPathComponent(user),
                                clock: clock, entropy: ScenarioEntropy(seed: UInt64(index + 1)), transport: InProcessHTTPTransport(clients: clients))
                            devices[user] = device
                            var password = SyncServerHarness.password
                            _ = try await device.account.login(server: "https://alpha.test", username: user, password: &password, deviceName: user)
                            XCTAssertTrue(password.isEmpty, "Password input was not consumed")
                            try await device.settle()
                        }
                        try await operation(devices, symbols)
                        for device in devices.values { device.sync.stop(); await device.sync.drain() }
                    } catch {
                        for device in devices.values { device.sync.stop(); await device.sync.drain() }
                        throw error
                    }
                }
        }
    }

    private func execute(_ service: SyncGroupService, _ device: ScenarioDevice, _ command: SyncGroupCommand) async -> SyncGroupResult {
        await service.execute(command, expectedAccount: device.account.snapshot.account)
    }

    private func user(_ name: String, _ symbols: [String: String]) throws -> ULID {
        try SyncIdentifiers.ulid(XCTUnwrap(symbols["user.alpha." + name]))
    }

    private func settle(_ model: GroupManagementModel, _ main: GroupIntegrationMain) async {
        main.flush(); await model.drain(); main.flush(); main.flush()
    }
}

private final class GroupIntegrationClipboard: Clipboard {
    var writes: [String] = []
    func writeText(_ text: String) { writes.append(text) }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { completion(writes.last) }
}

private final class GroupIntegrationMain: MainThread {
    private let lock = NSLock()
    private var pending: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { lock.lock(); pending.append(work); lock.unlock() }
    func flush() {
        lock.lock(); let work = pending; pending.removeAll(); lock.unlock()
        work.forEach { $0() }
    }
}
