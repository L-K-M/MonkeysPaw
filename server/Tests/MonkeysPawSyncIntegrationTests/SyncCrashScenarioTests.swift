import Foundation
@testable import SyncScenarioSupport
import XCTest
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import MonkeysPawCore

enum ScenarioCrashAction {
    case kill(device: String, checkpoint: String, files: Int)
    case resume(device: String)

    static func decode(_ action: String, device: String, object: inout ScenarioObject) throws -> Self? {
        switch action {
        case "kill_client":
            let checkpoint = try object.string("checkpoint")
            guard ["after_files", "before_state", "after_state"].contains(checkpoint) else {
                throw ScenarioFailure.invalid("unknown kill checkpoint")
            }
            let files = try object.required("file_count").integer()
            guard files > 0 else { throw ScenarioFailure.invalid("kill requires committed files") }
            return .kill(device: device, checkpoint: checkpoint, files: files)
        case "resume_client": return .resume(device: device)
        default: return nil
        }
    }
}

/// A real child with a hard watchdog, closed stdin and redacted output. Every
/// path, including startup/read/assertion failures, kills and reaps the child.
final class SyncCrashChild {
    let process = Process()
    private let finished = DispatchSemaphore(value: 0)
    private let stdout = Pipe()
    private var watchdog: DispatchWorkItem?
    private var started = false
    private var reaped = false

    deinit { try? killAndReap() }

    static func launch(input: Data, marker: String, timeout: TimeInterval = 30) async throws -> SyncCrashChild {
        let child = SyncCrashChild()
        child.process.executableURL = try executable()
        child.process.arguments = []
        // Preserve only the dynamic-loader setting needed on the sysroot host.
        child.process.environment = ProcessInfo.processInfo.environment.filter { $0.key == "LD_LIBRARY_PATH" }
        let stdin = Pipe()
        child.process.standardInput = stdin
        child.process.standardOutput = child.stdout
        child.process.standardError = FileHandle.nullDevice
        child.process.terminationHandler = { [finished = child.finished] _ in finished.signal() }
        do {
            try scenarioCheck(input.count <= 64 * 1024, "worker input cap")
            try child.process.run()
            child.started = true
            let watchdog = DispatchWorkItem { [process = child.process] in
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
            child.watchdog = watchdog
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
            try? stdin.fileHandleForReading.close()
            try? child.stdout.fileHandleForWriting.close()
            try await child.readMarker(marker)
            return child
        } catch {
            try? stdin.fileHandleForWriting.close()
            try? stdin.fileHandleForReading.close()
            try? child.killAndReap()
            throw (error as? ScenarioFailure) ?? .invalid("worker did not reach its checkpoint")
        }
    }

    func killAndReap() throws {
        guard started, !reaped else { return }
        if process.isRunning {
            guard kill(process.processIdentifier, SIGKILL) == 0 else { throw ScenarioFailure.invalid("child kill failed") }
        }
        try reap()
    }

    func reap() throws {
        guard started, !reaped else { return }
        if process.isRunning {
            guard finished.wait(timeout: .now() + 35) == .success else { throw ScenarioFailure.invalid("child was not reaped") }
        }
        // No pipe is left undrained while waiting for process termination.
        let tail = stdout.fileHandleForReading.readDataToEndOfFile()
        try? stdout.fileHandleForReading.close()
        process.waitUntilExit()
        reaped = true
        watchdog?.cancel()
        watchdog = nil
        try scenarioCheck(tail.isEmpty, "unexpected worker output")
    }

    private func readMarker(_ marker: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { [self] in
                do {
                    var bytes = Data()
                    while !bytes.contains(10) {
                        // corelibs FileHandle can fill the requested length;
                        // one POSIX read returns the live child's short marker.
                        var buffer = [UInt8](repeating: 0, count: 32)
                        let count = read(stdout.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else {
                            throw ScenarioFailure.invalid("worker exited before checkpoint")
                        }
                        bytes.append(contentsOf: buffer.prefix(count))
                        try scenarioCheck(bytes.count <= 32, "worker output cap")
                    }
                    try scenarioCheck(bytes == Data((marker + "\n").utf8), "unexpected worker checkpoint")
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func executable() throws -> URL {
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("SyncCrashWorker")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw ScenarioFailure.invalid("required SyncCrashWorker is missing")
    }
}

extension ScenarioRunner {
    func executeCrash(_ action: ScenarioCrashAction) async throws {
        switch action {
        case .kill(let name, let checkpoint, let fileCount):
            let device = try device(name)
            device.sync.stop()
            await device.sync.drain()
            try check(crashPlans[name] == nil, "client already killed")
            let before = try JSONDecoder().decode(SyncState.self, from: device.data.read(at: "sync/state.json"))
            let child = try await SyncCrashChild.launch(input: workerInput(device, checkpoint: checkpoint, files: fileCount), marker: "paused")
            defer { try? child.killAndReap() }
            try check(child.process.isRunning, "checkpoint must belong to a live child")
            let record = try JSONDecoder().decode(SyncApplyRecord.self, from: device.data.read(at: "sync/apply.json"))
            let state = try JSONDecoder().decode(SyncState.self, from: device.data.read(at: "sync/state.json"))
            let publications = record.steps.filter { $0.edit.bytes != nil && $0.edit.kind != .mode }
            let installed = try publications.filter { step in
                try device.files.stamp(at: step.edit.path) != nil && device.files.read(at: step.edit.path) == step.edit.bytes
            }.count
            try check(record.expectedState == before && record.nextState.cursors != before.cursors, "crash journal has a new cursor intent")
            if checkpoint == "after_files" {
                try check(installed == fileCount && installed < publications.count && state == before, "partial files with uncommitted state")
            } else {
                try check(installed == publications.count && installed >= fileCount, "all files precede state commit")
                try check(state == (checkpoint == "after_state" ? record.nextState : before), "state commit boundary")
            }
            try child.killAndReap()
            try check(child.process.terminationReason == .uncaughtSignal && child.process.terminationStatus == SIGKILL,
                      "actual SIGKILL termination")
            crashPlans[name] = record
        case .resume(let name):
            let old = try device(name)
            guard let record = crashPlans[name] else { throw ScenarioFailure.invalid("resume requires killed client") }
            let child = try await SyncCrashChild.launch(input: workerInput(old, checkpoint: "none", files: 1), marker: "complete")
            defer { try? child.killAndReap() }
            try child.reap()
            try check(child.process.terminationReason == .exit && child.process.terminationStatus == 0, "fresh worker recovery")
            let replacement = try ScenarioDevice(name: name, directory: old.directory, clock: old.clock, entropy: old.entropy, transport: old.transport)
            devices[name] = replacement
            try check(replacement.data.stamp(at: "sync/apply.json") == nil, "recovery removed journal")
            let state = try replacement.states.loadForAccountTransition()
            try check(state?.cursors == record.nextState.cursors && state?.databaseID == record.nextState.databaseID, "recovered cursor and UUID")
            for step in record.steps where step.edit.copyID != nil {
                try check(replacement.files.read(at: step.edit.path) == step.edit.bytes, "stable losing-copy identity and bytes")
            }
            crashPlans[name] = nil
        }
    }

    private func workerInput(_ device: ScenarioDevice, checkpoint: String, files: Int) throws -> Data {
        guard let account = try device.accounts.loadAccount(),
              let secret = try device.secrets.read(account: account.secretAccount, source: .effective),
              let host = account.identity.serverURL.host, let port = deployments[host]?.port else {
            throw ScenarioFailure.invalid("killed client requires a live loopback deployment")
        }
        return try secret.value.withValue { envelope in
            try JSONSerialization.data(withJSONObject: ["directory": device.directory.path, "endpoint": "http://127.0.0.1:\(port)",
                "secret": envelope, "now": device.clock.now().timeIntervalSince1970,
                "seed": 5000, "checkpoint": checkpoint, "fileCount": files])
        }
    }
}

final class SyncCrashScenarioTests: XCTestCase {
    func testChildCheckpointFailuresKeepSanitizedReasons() async throws {
        let sentinel = "runtime-only-secret-" + UUID().uuidString
        let stalled = try JSONSerialization.data(withJSONObject: ["directory": "/unused", "endpoint": "http://127.0.0.1:1",
            "secret": sentinel, "now": 0, "seed": 1, "checkpoint": "stall", "fileCount": 1])
        let cases: [(Data, String, String)] = [
            (Data(repeating: 0, count: 64 * 1024 + 1), "paused", "worker input cap"),
            (stalled, "complete", "unexpected worker checkpoint"),
            (Data("{}".utf8), "paused", "worker exited before checkpoint")
        ]
        for (input, marker, reason) in cases {
            do {
                _ = try await SyncCrashChild.launch(input: input, marker: marker, timeout: 2)
                XCTFail("Invalid child checkpoint passed")
            } catch let error as ScenarioFailure {
                XCTAssertEqual(error.description, "Sync scenario: " + reason)
                XCTAssertFalse(error.description.contains(sentinel))
            }
        }
    }

    func testFinalCrashCheckpointRejectsLostCursor() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures/sync/17-crash-apply.json")
        let baseline = try XCTUnwrap(ScenarioDecoder.decode(Data(contentsOf: file)).first)
        var steps = baseline.steps
        steps.insert(.maintenance(device: "a", .cursor(device: "a", scope: "user:${user.main.alice}", value: nil)),
                     at: steps.count - 1)
        let scenario = SyncScenario(id: "negative-crash-cursor", now: baseline.now, servers: baseline.servers,
            users: baseline.users, devices: baseline.devices, prompts: baseline.prompts, steps: steps)
        do {
            try await SyncServerHarness.run(scenario)
            XCTFail("Lost cursor passed the final crash checkpoint")
        } catch let error as ScenarioFailure {
            XCTAssertTrue(error.description.contains("scope cursor"), error.description)
        }
    }

    func testWatchdogKillsAndReapsAStalledChildWithSecretFreeArguments() async throws {
        let sentinel = "runtime-only-secret-" + UUID().uuidString
        let input = try JSONSerialization.data(withJSONObject: ["directory": "/unused", "endpoint": "http://127.0.0.1:1",
            "secret": sentinel, "now": 0, "seed": 1, "checkpoint": "stall", "fileCount": 1])
        let child = try await SyncCrashChild.launch(input: input, marker: "paused", timeout: 1)
        defer { try? child.killAndReap() }
        XCTAssertTrue(child.process.isRunning)
        XCTAssertEqual(child.process.arguments, [])
        XCTAssertFalse(child.process.environment?.values.contains(sentinel) ?? true)
        try child.reap()
        XCTAssertFalse(child.process.isRunning)
        XCTAssertEqual(child.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.process.terminationStatus, SIGKILL)
    }

    func testCrashDecoderRejectsUnknownStagesAndZeroFiles() {
        for (checkpoint, count) in [("unknown", 1), ("after_files", 0)] {
            let object: ScenarioValue = .object(["action": .string("kill_client"), "device": .string("a"),
                "checkpoint": .string(checkpoint), "file_count": .integer(Int64(count))])
            XCTAssertThrowsError(try ScenarioDecoder.decodeStep(object))
        }
    }
}
