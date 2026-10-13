import Foundation
import Testing
@testable import MonkeysPawServer

struct AdminCLIResult: Sendable {
    let status: Int32
    let exitedNormally: Bool
    let output: String
    let error: String

    func value<T: Decodable>(_ type: T.Type) throws -> T {
        let succeeded = exitedNormally && status == 0 && error.isEmpty
        #expect(succeeded)
        return try JSONDecoder().decode(type, from: Data(output.utf8))
    }

    func assertFailure(excluding secrets: [String] = [], expectedError: OperatorCommandError? = nil) {
        let messageIsCurated = expectedError.map { error == "Error: \($0.description)\n" } ?? true
        let failedSafely = exitedNormally && status != 0 && output.isEmpty && !error.isEmpty
            && error.utf8.count < 1_024 && secrets.allSatisfy { !error.contains($0) } && messageIsCurated
        #expect(failedSafely)
    }
}

struct AdminCLITestFixture: Sendable {
    let directory: URL
    let database: ServerDatabase
    var persistence: PersistenceTestRepository { .init(database: database) }
    var accounts: AccountTestFixture { .init(persistence: persistence) }

    func run(_ arguments: [String], input: Data = Data(), environment overrides: [String: String] = [:]) async throws -> AdminCLIResult {
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        var executable: URL?
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("monkeyspaw-server")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                executable = candidate
                break
            }
            directory.deleteLastPathComponent()
        }
        let path = try #require(executable)
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("MONKEYSPAW_") }
        environment["MONKEYSPAW_DATA_DIR"] = self.directory.path
        environment["MONKEYSPAW_LOG_LEVEL"] = "trace"
        environment.merge(overrides) { _, supplied in supplied }
        let commandEnvironment = environment

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = path
                process.arguments = arguments
                process.environment = commandEnvironment
                let stdin = Pipe()
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
                    defer { timeout.cancel() }
                    // Drain both streams before waiting; none can fill a pipe and block exit.
                    let errors = CapturedServerLogs()
                    let drain = DispatchGroup()
                    drain.enter()
                    DispatchQueue.global().async {
                        errors.write(stderr.fileHandleForReading.readDataToEndOfFile())
                        drain.leave()
                    }
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                    let bytes = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    drain.wait()
                    continuation.resume(returning: .init(status: process.terminationStatus,
                        exitedNormally: process.terminationReason == .exit,
                        output: String(decoding: bytes, as: UTF8.self), error: String(decoding: errors.snapshot(), as: UTF8.self)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

func withAdminCLI(_ operation: @Sendable (AdminCLITestFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s16-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await ServerDatabase.withMigratedDatabase(configuration: .init(environment: ["MONKEYSPAW_DATA_DIR": directory.path])) { database in
        try await operation(.init(directory: directory, database: database))
    }
}
