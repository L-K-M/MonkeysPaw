import FluentSQLiteDriver
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import SQLKit
import Testing
@testable import MonkeysPawServer

struct BackupMetadata: Decodable, Sendable {
    let path: String
    let databaseID: String
    let previousPath: String?

    private enum CodingKeys: String, CodingKey {
        case path
        case databaseID = "database_id"
        case previousPath = "previous_path"
    }
}

func withBackupDirectory(_ operation: @Sendable (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s17-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await operation(directory)
}

func withBackupDatabase<T: Sendable>(
    _ directory: URL, migrations: [ServerMigration] = ServerMigration.current,
    _ operation: @Sendable (ServerDatabase) async throws -> T
) async throws -> T {
    let database = try await ServerDatabase.open(configuration: .init(environment: ["MONKEYSPAW_DATA_DIR": directory.path]))
    do {
        try await database.migrate(migrations)
        let result = try await operation(database)
        await database.shutdown()
        return result
    } catch {
        await database.shutdown()
        throw error
    }
}

func editBackup(_ file: URL, _ query: SQLQueryString) async throws {
    let connection = try await SQLiteConnection.open(storage: .file(path: file.path),
                                                     logger: ServerLogging.logger(level: .critical)).get()
    do {
        try await connection.sql(queryLogLevel: nil).raw(query).run()
        try await connection.close()
    } catch {
        try? await connection.close()
        throw error
    }
}

actor BackupTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// A real serve process is the only lock owner in the live-server tests.
struct BackupTestServer {
    let process: Process

    static func start(directory: URL) async throws -> Self {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw BackupRestoreError.failed }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        close(fd)
        try #require(bound == 0 && named == 0)
        let port = UInt16(bigEndian: address.sin_port)
        let process = Process()
        process.executableURL = try AdminCLITestFixture.executableURL()
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("MONKEYSPAW_") }
        environment["MONKEYSPAW_DATA_DIR"] = directory.path
        environment["MONKEYSPAW_HTTP_HOST"] = "127.0.0.1"
        environment["MONKEYSPAW_HTTP_PORT"] = String(port)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let server = Self(process: process)
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/health")!)
            request.timeoutInterval = ServerLimits.healthcheckTimeout
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 { return server }
                guard process.isRunning else { throw BackupRestoreError.failed }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw BackupRestoreError.failed
        } catch {
            server.stop()
            throw error
        }
    }

    func stop() {
        if process.isRunning { process.terminate() }
        reap()
    }

    func crash() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        reap()
    }

    private func reap() {
        let timeout = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        process.waitUntilExit()
    }
}
