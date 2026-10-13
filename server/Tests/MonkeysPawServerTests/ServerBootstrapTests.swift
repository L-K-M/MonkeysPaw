import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import SQLKit
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerBootstrapTests {
    @Test func bootstrapCreatesOneAdminAndIgnoresEveryInputAfterward() async throws {
        try await withAccountFixture { fixture in
            let configuration = BootstrapConfiguration(environment: [
                "MONKEYSPAW_ADMIN_USERNAME": "ROOT", "MONKEYSPAW_ADMIN_PASSWORD": AccountTestFixture.password
            ])
            #expect(try await fixture.accounts.bootstrap(configuration))
            let user = try #require(await fixture.accounts.repository.read { accounts, _ in try await accounts.user(username: "root") })
            #expect(user.accountKind == .admin)
            #expect(user.displayName == nil)
            #expect(try await BcryptPasswordHasher().verify(AccountTestFixture.password, hash: user.passwordHash))
            let verified = try await fixture.accounts.verifyCredentials(username: "root", password: AccountTestFixture.password)
            #expect(verified.user.id == user.id)
            let safeConfiguration = !String(reflecting: configuration).contains(AccountTestFixture.password)
            #expect(safeConfiguration)
            try await fixture.persistence.execute("UPDATE users SET disabled_at = created_at")
            let ignored = BootstrapConfiguration(environment: [
                "MONKEYSPAW_ADMIN_USERNAME": "INVALID USER", "MONKEYSPAW_ADMIN_PASSWORD_FILE": "/missing/secret"
            ])
            let neverHash = AccountService(database: fixture.persistence.database, passwords: UnavailablePasswordHasher())
            #expect(try await !neverHash.bootstrap(ignored))
            #expect(try await fixture.persistence.count("users") == 1)
            #expect(try await fixture.persistence.count("devices") == 0)
        }
    }

    @Test func secretFileSizeLimitFailsWithATypedErrorAndNeverFallsBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s6-secret-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("admin.secret")
        for (size, expected) in [
            (ServerLimits.bootstrapSecretFileMaximumBytes, BootstrapError.invalidCredentials),
            (ServerLimits.bootstrapSecretFileMaximumBytes + 1, .secretFileTooLarge)
        ] {
            try Data(repeating: 97, count: size).write(to: file)
            try await withAccountFixture { fixture in
                do {
                    _ = try await fixture.accounts.bootstrap(.init(environment: [
                        "MONKEYSPAW_ADMIN_PASSWORD_FILE": file.path,
                        "MONKEYSPAW_ADMIN_PASSWORD": AccountTestFixture.password
                    ]))
                    Issue.record("An invalid secret file must fail bootstrap")
                } catch let error as BootstrapError {
                    #expect(error == expected)
                }
                #expect(try await fixture.persistence.count("users") == 0)
                #expect(try await fixture.persistence.count("devices") == 0)
            }
        }
        let boundary = String(repeating: "a", count: 72)
        for ending in ["", "\n", "\r\n"] {
            try Data((boundary + ending).utf8).write(to: file)
            let credentials = try BootstrapConfiguration(environment: ["MONKEYSPAW_ADMIN_PASSWORD_FILE": file.path]).credentials()
            #expect(credentials.password == boundary)
        }
        let link = directory.appendingPathComponent("admin.secret.link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let credentials = try BootstrapConfiguration(environment: ["MONKEYSPAW_ADMIN_PASSWORD_FILE": link.path]).credentials()
        #expect(credentials.password == boundary)
    }

    @Test func serveRejectsAFIFOSecretBeforeListening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s6-secret-fifo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("admin.secret")
        try #require(mkfifo(file.path, 0o600) == 0)
        let result = try await ServerDatabaseLifecycleTests.runCLI("serve", dataDirectory: directory, overrides: [
            "MONKEYSPAW_ADMIN_PASSWORD_FILE": file.path, "MONKEYSPAW_ADMIN_PASSWORD": AccountTestFixture.password
        ])
        #expect(result.exitedNormally)
        #expect(result.status != 0)
        #expect(result.error.contains("Bootstrap admin credentials are missing, unreadable, or invalid."))
    }

    @Test func bootstrapFailsClosedForMissingUnreadableEmptyAndInvalidSecrets() async throws {
        try await withAccountFixture { fixture async throws -> Void in
            let cases: [[String: String]] = [
                [:], ["MONKEYSPAW_ADMIN_PASSWORD_FILE": "/missing/secret"],
                ["MONKEYSPAW_ADMIN_PASSWORD_FILE": "/missing/secret", "MONKEYSPAW_ADMIN_PASSWORD": AccountTestFixture.password],
                ["MONKEYSPAW_ADMIN_PASSWORD": ""], ["MONKEYSPAW_ADMIN_PASSWORD": "short"],
                ["MONKEYSPAW_ADMIN_PASSWORD": AccountTestFixture.password, "MONKEYSPAW_ADMIN_USERNAME": "invalid user"]
            ]
            for environment in cases {
                await #expect(throws: BootstrapError.self) { _ = try await fixture.accounts.bootstrap(.init(environment: environment)) }
                #expect(try await fixture.persistence.count("users") == 0)
            }
        }
    }

    @Test func fileIsAuthoritativeAndOnlyItsTerminalNewlineIsRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s6-secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("admin.secret")
        let secret = " space-sensitive password "
        try Data((secret + "\r\n").utf8).write(to: file)
        let preservesSpaces = try BootstrapConfiguration(environment: ["MONKEYSPAW_ADMIN_PASSWORD_FILE": file.path]).credentials().password == secret
        #expect(preservesSpaces)
        try await withAccountFixture { fixture in
            #expect(try await fixture.accounts.bootstrap(.init(environment: [
                "MONKEYSPAW_ADMIN_PASSWORD_FILE": file.path, "MONKEYSPAW_ADMIN_PASSWORD": "ignored"
            ])))
            _ = try await fixture.accounts.verifyCredentials(username: "ADMIN", password: secret)
            await #expect(throws: AccountError.unauthorized) {
                _ = try await fixture.accounts.verifyCredentials(username: "admin", password: secret.trimmingCharacters(in: .whitespaces))
            }
        }
        for bytes in [Data(), Data([0xff, 0xfe])] {
            try bytes.write(to: file)
            try await withAccountFixture { fixture in
                await #expect(throws: BootstrapError.self) {
                    _ = try await fixture.accounts.bootstrap(.init(environment: ["MONKEYSPAW_ADMIN_PASSWORD_FILE": file.path]))
                }
            }
        }
        // A directory is unreadable as a secret file even for root, which
        // ignores permission bits (CI's server job runs as root).
        let unreadable = file.deletingLastPathComponent().appendingPathComponent("secret-directory")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unreadable) }
        try await withAccountFixture { fixture in
            await #expect(throws: BootstrapError.self) {
                _ = try await fixture.accounts.bootstrap(.init(environment: ["MONKEYSPAW_ADMIN_PASSWORD_FILE": unreadable.path]))
            }
        }
    }

    @Test func concurrentBootstrapAndReopenNeverReplaceTheFirstAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s6-bootstrap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = DatabaseConfiguration(environment: ["MONKEYSPAW_DATA_DIR": directory.path])
        let id = try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database in
            let accounts = AccountService(database: database)
            let created = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<4 {
                    group.addTask { try await accounts.bootstrap(.init(environment: ["MONKEYSPAW_ADMIN_PASSWORD": AccountTestFixture.password])) }
                }
                var count = 0
                for try await result in group { if result { count += 1 } }
                return count
            }
            #expect(created == 1)
            return try #require(await accounts.repository.read { accounts, _ in try await accounts.user(username: "admin") }).id
        }
        try await ServerDatabase.withMigratedDatabase(configuration: configuration) { database async throws -> Void in
            let accounts = AccountService(database: database)
            #expect(try await !accounts.bootstrap(.init(environment: [:])))
            #expect(try await accounts.repository.read { accounts, _ in try await accounts.user(username: "admin")?.id } == id)
        }
    }

    @Test func serveExitsBeforeListeningOnMissingOrUnreadableBootstrapSecret() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monkeyspaw-s6-startup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for environment in [[:], ["MONKEYSPAW_ADMIN_PASSWORD_FILE": "/missing/secret",
                                  "MONKEYSPAW_ADMIN_PASSWORD": AccountTestFixture.password]] {
            let result = try await ServerDatabaseLifecycleTests.runCLI("serve", dataDirectory: directory, overrides: environment)
            #expect(result.exitedNormally)
            #expect(result.status != 0)
            #expect(result.error.contains("Bootstrap admin credentials are missing, unreadable, or invalid."))
            let safeError = !result.error.contains(AccountTestFixture.password) && !result.error.contains("/missing/secret")
            #expect(safeError)
        }
        try await ServerDatabase.withMigratedDatabase(configuration: .init(environment: ["MONKEYSPAW_DATA_DIR": directory.path])) { database async throws -> Void in
            #expect(try await PersistenceTestRepository(database: database).count("users") == 0)
        }
    }
}

private struct UnavailablePasswordHasher: PasswordHashing {
    func hash(_ password: String) async throws -> String { throw BootstrapError.invalidCredentials }
    func verify(_ password: String, hash: String) async throws -> Bool { throw BootstrapError.invalidCredentials }
}
