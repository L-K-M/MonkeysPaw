import Foundation
import XCTest
@testable import MonkeysPawCore

final class ConflictResolutionServerTests: XCTestCase {
    private let original = ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PD")!

    func testGroupDecisionsSurviveZeroCursorSnapshotWithoutCascade() async throws {
        for action in [ConflictResolutionAction.keepServer, .keepMine, .keepBoth] {
            try await groupDecision(action)
        }
    }

    private func groupDecision(_ action: ConflictResolutionAction) async throws {
        try await withDevices(differentUsers: true) { owner, editor, symbols in
            let response = try await owner.request(method: .post, path: "/api/v1/groups", body: .object(["name": .string("Team")]))
            XCTAssertEqual(response.statusCode, 200)
            let group = try JSONDecoder().decode(SyncAPI.Group.self, from: response.body)
            let member = try XCTUnwrap(symbols["user.server.bob"])
            let added = try await owner.request(method: .put,
                path: "/api/v1/groups/" + group.id + "/members/" + member, body: .object(["role": .string("editor")]))
            XCTAssertEqual(added.statusCode, 200)
            for device in [owner, editor] { device.sync.syncNow(); try await device.settle() }
            try owner.files.write(self.bytes("Server", id: self.original), at: "Groups/Team/original.md")
            owner.sync.syncNow(); try await owner.settle()
            editor.sync.syncNow(); try await editor.settle()
            let baseline = try editor.files.read(at: "Groups/Team/original.md")

            let copyID = ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PF")!
            let body = "Mine Cafe\u{301}\r\n{{topic}}"
            let source = "---\nid: " + copyID.rawValue + "\ntitle: Exact\nfavorite: true\nprivate: true\nx-extra: {nested: [1, false]}\n---\n" + body
            let marked = try SyncConflictMetadata.settingOrigin(.conflictOf(self.original),
                in: Data(source.utf8), filename: "copy.md")
            try editor.files.write(marked, at: "Conflicts/Team/copy.md")
            editor.sync.syncNow(); try await editor.settle()
            let service = ConflictResolutionService(sync: editor.sync)
            let preview = try await service.preview(.init(identity: .assigned(copyID), relativePath: "Conflicts/Team/copy.md"))
            XCTAssertTrue(preview.canKeepMine)
            let candidate = try XCTUnwrap(preview.candidateBytes)
            XCTAssertEqual(candidate, try CanonicalForm.group(candidate, filename: "original.md").bytes)
            let document = PromptCodec.parseFile(candidate, filename: "original.md")
            XCTAssertEqual(document.frontMatter.id, self.original)
            XCTAssertEqual(Data(document.body.utf8), Data(body.utf8))
            XCTAssertFalse(String(decoding: candidate, as: UTF8.self).contains("favorite:"))
            XCTAssertFalse(String(decoding: candidate, as: UTF8.self).contains("private:"))
            XCTAssertNil(try SyncConflictMetadata.origin(in: document))
            let result = try await service.resolve(action, preview: preview)
            guard case .resolved(let resolved) = result else { return XCTFail("Writable group resolution failed") }
            XCTAssertEqual(resolved, action)
            let editorCount = action == .keepBoth ? 2 : 1
            XCTAssertEqual(try editor.files.listFiles().count, editorCount, "Immediately after resolution")
            for device in [editor, owner, editor] {
                device.sync.syncNow(); try await device.settle()
                let paths = try device.files.listFiles().map(\.relativePath)
                XCTAssertEqual(paths.count, device === editor ? editorCount : 1,
                    device.name + ": " + paths.joined(separator: ", "))
                let origins = device.states.snapshot.value?.prompts.values.compactMap(\.origin) ?? []
                XCTAssertTrue(origins.isEmpty, device.name + ": " + String(describing: origins))
            }
            for device in [editor, owner] {
                XCTAssertEqual(try device.files.read(at: "Groups/Team/original.md"), action == .keepMine ? candidate : baseline)
                XCTAssertEqual(try device.files.listFiles().count, device === editor ? editorCount : 1, device.name)
                XCTAssertTrue(device.states.snapshot.value?.prompts.values.allSatisfy { $0.origin == nil } == true)
                XCTAssertEqual(device.sync.report.counts.conflicts, 0)
            }
            if action == .keepBoth {
                let kept = PromptCodec.parseFile(try editor.files.read(at: "Conflicts/Team/copy.md"), filename: "copy.md")
                XCTAssertEqual(kept.frontMatter.id, copyID)
                XCTAssertEqual(Data(kept.body.utf8), Data(body.utf8))
                XCTAssertTrue(kept.frontMatter.favorite)
                XCTAssertTrue(kept.frontMatter.isPrivate)
                XCTAssertNil(try SyncConflictMetadata.origin(in: kept))
            } else { XCTAssertNil(try editor.files.stamp(at: "Conflicts/Team/copy.md")) }
        }
    }

    func testLostResolutionAcknowledgementRetainsCopyAndDoesNotCascadeOnPull() async throws {
        try await withDevices { a, b, _ in
            let selection = try await self.conflict(a, b)
            let service = ConflictResolutionService(sync: a.sync)
            let preview = try await service.preview(selection)
            let copy = try a.files.read(at: selection.relativePath.string)
            a.transport.rewrite(.init(device: a.name, phase: .response, method: .put,
                path: "/api/v1/prompts/" + self.original.rawValue, patch: ["/rev": .integer(0)]))
            do { _ = try await service.resolve(.keepMine, preview: preview); XCTFail("Invalid acknowledgement was accepted") }
            catch { XCTAssertEqual(error as? SyncHTTPClientError, .malformedResponse) }
            XCTAssertEqual(try a.files.read(at: selection.relativePath.string), copy)
            a.sync.syncNow(); try await a.settle()
            b.sync.syncNow(); try await b.settle()
            XCTAssertEqual(try a.files.listFiles().count, 2)
            XCTAssertEqual(try b.files.listFiles().count, 2)
            XCTAssertEqual(try a.files.read(at: "original.md"), preview.candidateBytes)
            XCTAssertEqual(try a.files.read(at: selection.relativePath.string), copy)
            let refreshed = try await service.preview(selection)
            XCTAssertEqual(refreshed.serverBytes, refreshed.candidateBytes)
            _ = try await service.resolve(.keepMine, preview: refreshed)
            a.sync.syncNow(); try await a.settle()
            b.sync.syncNow(); try await b.settle()
            XCTAssertEqual(try a.files.listFiles().count, 1)
            XCTAssertEqual(try b.files.listFiles().count, 1)
        }
    }

    func testAllThreeDecisionsPropagateExactBytesWithoutConflictCascades() async throws {
        for action in [ConflictResolutionAction.keepServer, .keepMine, .keepBoth] {
            try await withDevices { a, b, _ in
                let selection = try await self.conflict(a, b)
                let service = ConflictResolutionService(sync: a.sync)
                let preview = try await service.preview(selection)
                let candidate = try XCTUnwrap(preview.candidateBytes)
                let baseline = try a.files.read(at: "original.md")
                let result = try await service.resolve(action, preview: preview)
                guard case .resolved(let resolved) = result else { return XCTFail("Resolution refreshed unexpectedly") }
                XCTAssertEqual(resolved, action)
                a.sync.syncNow(); try await a.settle()
                b.sync.syncNow(); try await b.settle()
                a.sync.syncNow(); try await a.settle()
                let expected = action == .keepMine ? candidate : baseline
                XCTAssertEqual(try a.files.read(at: "original.md"), expected)
                XCTAssertEqual(try b.files.read(at: "original.md"), expected)
                for device in [a, b] {
                    let files = try device.files.listFiles()
                    XCTAssertEqual(files.count, action == .keepBoth ? 2 : 1)
                    XCTAssertTrue(device.states.snapshot.value?.prompts.values.allSatisfy { $0.origin == nil } == true)
                    if action == .keepBoth {
                        let kept = try device.files.read(at: selection.relativePath.string)
                        let document = PromptCodec.parseFile(kept, filename: "copy.md")
                        XCTAssertEqual(document.frontMatter.id, { if case .assigned(let id) = selection.identity { return id }; return nil }())
                        XCTAssertEqual(Data(document.body.utf8), Data("Mine Cafe\u{301}\r\n{{topic}}".utf8))
                        XCTAssertNil(try SyncConflictMetadata.origin(in: document))
                    } else {
                        XCTAssertNil(try device.files.stamp(at: selection.relativePath.string))
                        XCTAssertNil(device.states.snapshot.value?.prompts[selection.identity])
                    }
                }
                XCTAssertEqual(a.sync.report.counts.conflicts, 0)
                XCTAssertEqual(b.sync.report.counts.conflicts, 0)
            }
        }
    }

    func testRemoteCopyRenameAndMarkerRemovalSurviveRestart() async throws {
        try await withDevices { a, b, _ in
            let selection = try await self.conflict(a, b)
            b.sync.syncNow(); try await b.settle()
            try b.files.move(from: selection.relativePath.string, to: "renamed.md")
            b.sync.syncNow(); try await b.settle()
            a.sync.syncNow(); try await a.settle()
            _ = a.sync.stop(); await a.sync.drain()
            let restarted = try ScenarioDevice(name: a.name, directory: a.directory, clock: a.clock,
                entropy: a.entropy, transport: a.transport)
            do {
                _ = try await restarted.account.startup()
                try await restarted.settle()
                let service = ConflictResolutionService(sync: restarted.sync)
                let preview = try await service.preview(selection)
                XCTAssertEqual(preview.copy.relativePath, "renamed.md")
                XCTAssertEqual(preview.originalID, self.original)
                _ = try await service.resolve(.keepBoth, preview: preview)
                restarted.sync.syncNow(); try await restarted.settle()
                b.sync.syncNow(); try await b.settle()
                XCTAssertNil(try SyncConflictMetadata.origin(in: b.files.read(at: "renamed.md"), filename: "renamed.md"))
                XCTAssertEqual(try b.files.listFiles().count, 2)
                _ = restarted.sync.stop(); await restarted.sync.drain()
            } catch {
                _ = restarted.sync.stop(); await restarted.sync.drain()
                throw error
            }
        }
    }

    func testRealCASRacePreservesCandidateAndRequiresFreshChoice() async throws {
        try await withDevices { a, b, _ in
            let selection = try await self.conflict(a, b)
            let service = ConflictResolutionService(sync: a.sync)
            let preview = try await service.preview(selection)
            let copy = try a.files.read(at: selection.relativePath.string)
            let path = "/api/v1/prompts/" + self.original.rawValue
            a.transport.before(method: .put, path: path) {
                try b.files.write(self.bytes("Racing server edit", id: self.original), at: "original.md")
                b.sync.syncNow(); try await b.settle()
            }
            let result = try await service.resolve(.keepMine, preview: preview)
            guard case .refreshed(let refreshed) = result else { return XCTFail("Real stale CAS was accepted") }
            XCTAssertNotEqual(refreshed.serverBytes, preview.serverBytes)
            XCTAssertEqual(refreshed.candidateBytes, preview.candidateBytes)
            XCTAssertEqual(try a.files.read(at: selection.relativePath.string), copy)
            XCTAssertEqual(try a.files.listFiles().count, 2)
            XCTAssertEqual(a.transport.traces.last { $0.method == "PUT" && $0.path == path }?.status, 409)
            _ = try await service.resolve(.keepMine, preview: refreshed)
            a.sync.syncNow(); try await a.settle()
            b.sync.syncNow(); try await b.settle()
            XCTAssertEqual(try b.files.read(at: "original.md"), refreshed.candidateBytes)
            XCTAssertEqual(try a.files.listFiles().count, 1)
        }
    }

    func testDeletedOriginalDoesNotResurrectAndViewerCannotResolveIntoGroup() async throws {
        try await withDevices { a, b, _ in
            let selection = try await self.conflict(a, b)
            let service = ConflictResolutionService(sync: a.sync)
            let preview = try await service.preview(selection)
            try b.files.delete(at: "original.md")
            b.sync.syncNow(); try await b.settle()
            let result = try await service.resolve(.keepMine, preview: preview)
            guard case .refreshed(let refreshed) = result else { return XCTFail("Deleted original was overwritten") }
            XCTAssertEqual(refreshed.mineRefusal, .originalUnavailable)
            XCTAssertNotNil(try a.files.stamp(at: selection.relativePath.string))
            XCTAssertFalse(a.transport.traces.contains { $0.method == "PUT" && $0.path.hasSuffix(self.original.rawValue) && $0.status == 410 })
        }
        try await withDevices(differentUsers: true) { owner, editor, symbols in
            let groupResponse = try await owner.request(method: .post, path: "/api/v1/groups", body: .object(["name": .string("Team")]))
            XCTAssertEqual(groupResponse.statusCode, 200)
            let group = try JSONDecoder().decode(SyncAPI.Group.self, from: groupResponse.body)
            let member = try XCTUnwrap(symbols["user.server.bob"])
            let memberPath = "/api/v1/groups/" + group.id + "/members/" + member
            let added = try await owner.request(method: .put, path: memberPath, body: .object(["role": .string("editor")]))
            XCTAssertEqual(added.statusCode, 200)
            owner.sync.syncNow(); try await owner.settle()
            editor.sync.syncNow(); try await editor.settle()
            try owner.files.write(self.bytes("Server", id: self.original), at: "Groups/Team/original.md")
            owner.sync.syncNow(); try await owner.settle()
            editor.sync.syncNow(); try await editor.settle()
            let copyID = ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PE")!
            let marked = try SyncConflictMetadata.settingOrigin(.conflictOf(self.original),
                in: self.bytes("Private candidate", id: copyID), filename: "copy.md")
            try editor.files.write(marked, at: "Conflicts/Team/copy.md")
            editor.sync.syncNow(); try await editor.settle()
            let service = ConflictResolutionService(sync: editor.sync)
            let selection = LibraryPromptSelection(identity: .assigned(copyID), relativePath: "Conflicts/Team/copy.md")
            let preview = try await service.preview(selection)
            XCTAssertTrue(preview.canKeepMine)
            let downgraded = try await owner.request(method: .put, path: memberPath, body: .object(["role": .string("viewer")]))
            XCTAssertEqual(downgraded.statusCode, 200)
            do { _ = try await service.resolve(.keepMine, preview: preview); XCTFail("Viewer overwrote group") }
            catch { XCTAssertEqual(error as? ConflictResolutionFailure, .staleAccess) }
            XCTAssertEqual(try editor.files.read(at: selection.relativePath.string), marked)
            let denied = try await service.preview(selection)
            XCTAssertEqual(denied.mineRefusal, .accessDenied)
            let removed = try await owner.request(method: .delete, path: memberPath, body: nil)
            XCTAssertEqual(removed.statusCode, 200)
            let unavailable = try await service.preview(selection)
            XCTAssertFalse(unavailable.canKeepMine)
            XCTAssertNil(unavailable.serverBytes)
            XCTAssertEqual(try editor.files.listFiles().count, 2)
        }
    }

    private func bytes(_ body: String, id: ULID) -> Data {
        Data(("---\nid: " + id.rawValue + "\ntitle: Exact\n---\n" + body).utf8)
    }

    private func conflict(_ a: ScenarioDevice, _ b: ScenarioDevice) async throws -> LibraryPromptSelection {
        try a.files.write(bytes("Initial", id: original), at: "original.md")
        a.sync.syncNow(); try await a.settle()
        b.sync.syncNow(); try await b.settle()
        try a.files.write(bytes("Mine Cafe\u{301}\r\n{{topic}}", id: original), at: "original.md")
        try b.files.write(bytes("Server Caf\u{e9}\n{{topic}}", id: original), at: "original.md")
        b.sync.syncNow(); try await b.settle()
        a.sync.syncNow(); try await a.settle()
        let copies = try XCTUnwrap(a.states.snapshot.value).prompts.filter { $0.value.origin == .conflictOf(original) }
        XCTAssertEqual(copies.count, 1)
        let copy = try XCTUnwrap(copies.first)
        return .init(identity: copy.key, relativePath: copy.value.path)
    }

    private func withDevices(differentUsers: Bool = false,
        operation: @escaping (ScenarioDevice, ScenarioDevice, [String: String]) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-y17-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_797_000_000)
        let clock = ScenarioClock(date)
        let scenario = SyncScenario(id: "y17", now: date, servers: ["server"], users: ["alice", "bob"], devices: [], prompts: [:], steps: [])
        try await SyncServerHarness.withServers(scenario, root: root, clock: clock, index: 0, clients: [:], symbols: [:]) { clients, symbols in
            let a = try ScenarioDevice(name: "a", directory: root.appendingPathComponent("a"), clock: clock,
                entropy: ScenarioEntropy(seed: 1), transport: InProcessHTTPTransport(clients: clients))
            let b = try ScenarioDevice(name: "b", directory: root.appendingPathComponent("b"), clock: clock,
                entropy: ScenarioEntropy(seed: 2), transport: InProcessHTTPTransport(clients: clients))
            do {
                for (device, user) in [(a, "alice"), (b, differentUsers ? "bob" : "alice")] {
                    var password = SyncServerHarness.password
                    _ = try await device.account.login(server: "https://server.test", username: user, password: &password, deviceName: device.name)
                    try await device.settle()
                }
                try await operation(a, b, symbols)
                for device in [a, b] { _ = device.sync.stop(); await device.sync.drain() }
            } catch {
                for device in [a, b] { _ = device.sync.stop(); await device.sync.drain() }
                throw error
            }
        }
    }
}
