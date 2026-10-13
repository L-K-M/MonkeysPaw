#if os(Linux)
import CGtk
import Foundation
import Glibc
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawLinux

final class LinuxSecretStoreTests: XCTestCase {
    private final class WorkerResult { var value: Result<Void, Error>? }
    private let profile = ProviderProfileID(UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!)

    func testEnvironmentPrecedenceIsolationAndPersistedCompensation() throws {
        let tools = try toolsWithPaths()
        let account = SecretAccount.provider(profile)
        let device = try SecretAccount(namespace: "device", name: profile.rawValue)
        tools.environment[profile.environmentVariable] = "operator-key"
        let store = makeStore(tools)
        XCTAssertEqual(try store.read(account: account, source: .effective)?.tier, .environment)
        XCTAssertEqual(try store.read(account: account, source: .effective)?.value, SecretValue("operator-key"))
        XCTAssertTrue(tools.arguments.isEmpty)

        try worker {
            XCTAssertNil(try store.read(account: account, source: .persisted))
            XCTAssertNil(try store.read(account: .provider(ProviderProfileID()), source: .effective))
            XCTAssertNil(try store.read(account: device, source: .effective))
            XCTAssertEqual(try store.write(SecretValue("persisted-key"), account: account), .file)
            XCTAssertEqual(try store.read(account: account, source: .persisted)?.value, SecretValue("persisted-key"))
            try store.delete(account: account)
            try store.delete(account: account)
            XCTAssertNil(try store.read(account: account, source: .persisted))
        }
        XCTAssertEqual(try store.read(account: account, source: .effective)?.value, SecretValue("operator-key"))
        XCTAssertEqual(tools.environment[profile.environmentVariable], "operator-key")
    }

    func testProviderServiceRejectsEnvironmentReplacementButClearDeletesPersistedKey() throws {
        let tools = try toolsWithPaths()
        tools.environment[profile.environmentVariable] = "operator-key"
        let store = makeStore(tools)
        try worker {
            let files = try RootedFileStore(root: LinuxPaths(environment: tools.environment).configDirectory)
            let service = ProviderSettingsService(store: ProviderSettingsStore(files: files), secrets: store)
            var draft = ProviderDraft(id: self.profile, displayName: "test", kind: .openaiCompatible,
                baseURL: "http://localhost:11434", modelID: "local")
            try service.save(draft)
            XCTAssertEqual(try service.secretTier(for: self.profile), .environment)
            try store.write(SecretValue("compensation"), account: .provider(self.profile))
            draft.key = .replace(SecretValue("new-key"))
            XCTAssertThrowsError(try service.save(draft)) { error in
                XCTAssertEqual(error as? ProviderSettingsError, .secret(.readOnly))
            }
            XCTAssertEqual(try store.read(account: .provider(self.profile), source: .persisted)?.value,
                SecretValue("compensation"))
            draft.key = .clear
            try service.save(draft)
            XCTAssertNil(try service.connection(for: self.profile).key)
            XCTAssertNil(try store.read(account: .provider(self.profile), source: .persisted))
            XCTAssertEqual(try store.read(account: .provider(self.profile), source: .effective)?.tier, .environment)
        }
    }

    func testSecretServiceUsesLabelAttributesStdinAndExactBytes() throws {
        let tools = try toolsWithPaths()
        try installService(tools)
        let store = makeStore(tools)
        let account = SecretAccount.provider(profile)
        let value = SecretValue("  secret\nwith trailing whitespace \n")
        try worker {
            XCTAssertEqual(try store.write(value, account: account), .secretService)
            XCTAssertEqual(try store.read(account: account, source: .persisted), StoredSecret(value: value, tier: .secretService))
            try store.delete(account: account)
            try store.delete(account: account)
            XCTAssertNil(try store.read(account: account, source: .effective))
        }
        let attributes = ["service", "ch.lkmc.monkeyspaw", "account", account.rawValue]
        XCTAssertTrue(tools.arguments.contains(["store", "--label", "Monkey's Paw: \(account.rawValue)"] + attributes))
        XCTAssertTrue(tools.arguments.contains(["lookup"] + attributes))
        XCTAssertTrue(tools.arguments.contains(["clear"] + attributes))
        XCTAssertFalse(tools.log.joined().contains("secret\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secretFile(tools).path))
    }

    func testFallbackMigrationRemovesOnlyTheMigratedAccountAndClearRemovesBothCopies() throws {
        let tools = try toolsWithPaths()
        let account = SecretAccount.provider(profile)
        let device = try SecretAccount(namespace: "device", name: "sync")
        try worker {
            let fallback = self.makeStore(tools)
            try fallback.write(SecretValue("old-file-key"), account: account)
            try fallback.write(SecretValue("device-key"), account: device)
        }
        try installService(tools)
        let store = makeStore(tools)
        try worker {
            XCTAssertEqual(try store.read(account: account, source: .persisted)?.tier, .file)
            XCTAssertEqual(try store.write(SecretValue("new-service-key"), account: account), .secretService)
            XCTAssertEqual(try store.read(account: account, source: .persisted)?.value, SecretValue("new-service-key"))
            XCTAssertEqual(try store.read(account: device, source: .persisted)?.value, SecretValue("device-key"))
            try LinuxSecretFile(paths: LinuxPaths(environment: tools.environment)).write(SecretValue("duplicate"), account: account)
            try store.delete(account: account)
            XCTAssertNil(try store.read(account: account, source: .persisted))
        }
        let data = try Data(contentsOf: secretFile(tools))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("old-file-key"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("new-service-key"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("duplicate"))
    }

    func testUnavailableAndLockedReadsFallBackButMutationsFailClosed() throws {
        for (script, expected) in [
            ("printf 'private-tool-error' >&2\nexit 1", SecretStoreError.unavailable),
            (#"if [ "$1" = search ]; then printf '[locked-item]\nlabel = item'; exit 0; fi"#
                + "\nexit 1", .locked)
        ] {
            let tools = try toolsWithPaths()
            let account = SecretAccount.provider(profile)
            try worker { try self.makeStore(tools).write(SecretValue("fallback-key"), account: account) }
            let original = try Data(contentsOf: secretFile(tools))
            try tools.install("secret-tool", script: script)
            let store = makeStore(tools)
            try worker {
                XCTAssertEqual(try store.read(account: account, source: .effective)?.tier, .file)
                XCTAssertThrowsError(try store.read(account: .provider(ProviderProfileID()), source: .persisted)) {
                    XCTAssertEqual($0 as? SecretStoreError, expected)
                }
                XCTAssertThrowsError(try store.write(SecretValue("replacement"), account: account)) {
                    XCTAssertEqual($0 as? SecretStoreError, expected)
                }
                XCTAssertThrowsError(try store.delete(account: account)) {
                    XCTAssertEqual($0 as? SecretStoreError, expected)
                }
            }
            XCTAssertEqual(try Data(contentsOf: secretFile(tools)), original)
        }
    }

    func testDeadlineReturnsUnavailableAndDoesNotCreatePlaintext() throws {
        let tools = try toolsWithPaths()
        try tools.install("secret-tool", script: "exec /bin/sleep 5")
        let store = makeStore(tools, timeout: .milliseconds(75))
        let start = ContinuousClock.now
        try worker {
            XCTAssertThrowsError(try store.write(SecretValue("key"), account: .provider(self.profile))) {
                XCTAssertEqual($0 as? SecretStoreError, .unavailable)
            }
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secretFile(tools).path))
    }

    func testFailedStoreOrClearPreservesOldServiceKey() throws {
        let tools = try toolsWithPaths()
        let account = SecretAccount.provider(profile)
        try installService(tools)
        try worker { try self.makeStore(tools).write(SecretValue("old-key"), account: account) }
        try tools.install("secret-tool", script: FakeLinuxTools.recordArguments + "\n"
            + #"if [ "$1" = lookup ]; then /bin/cat "$FAKE_ITEMS/$5"; exit 0; fi"#
            + "\nprintf 'private-tool-error' >&2\nexit 1")
        let store = makeStore(tools)
        try worker {
            XCTAssertThrowsError(try store.write(SecretValue("new-key"), account: account)) {
                XCTAssertEqual($0 as? SecretStoreError, .writeFailed)
            }
            XCTAssertThrowsError(try store.delete(account: account)) {
                XCTAssertEqual($0 as? SecretStoreError, .deleteFailed)
            }
            XCTAssertEqual(try store.read(account: account, source: .persisted)?.value, SecretValue("old-key"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: secretFile(tools).path))
    }

    func testFailureAfterServiceMutationCompensatesTheOldValue() throws {
        for operation in ["store", "clear"] {
            for ending in ["exit 1", "exec /bin/sleep 5"] {
                let tools = try toolsWithPaths()
                try installService(tools)
                let account = SecretAccount.provider(profile)
                try worker { try self.makeStore(tools).write(SecretValue("old-key"), account: account) }
                tools.environment["FAKE_OPERATION"] = operation
                try tools.install("secret-tool", script: #"""
                case "$1" in
                  lookup) if [ -f "$FAKE_ITEMS/$5" ]; then /bin/cat "$FAKE_ITEMS/$5"; else exit 1; fi ;;
                  search) exit 0 ;;
                  store) /bin/cat > "$FAKE_ITEMS/$7" ;;
                  clear) /bin/rm -f "$FAKE_ITEMS/$5" ;;
                esac
                if [ "$1" = "$FAKE_OPERATION" ]; then
                """# + "\n" + ending + "\nfi")
                let store = makeStore(tools, timeout: .milliseconds(200))
                let start = ContinuousClock.now
                try worker {
                    if operation == "store" {
                        XCTAssertThrowsError(try store.write(SecretValue("new-key"), account: account)) {
                            XCTAssertEqual($0 as? SecretStoreError, ending == "exit 1" ? .writeFailed : .unavailable)
                        }
                    } else {
                        XCTAssertThrowsError(try store.delete(account: account)) {
                            XCTAssertEqual($0 as? SecretStoreError, ending == "exit 1" ? .deleteFailed : .unavailable)
                        }
                    }
                    XCTAssertEqual(try store.read(account: account, source: .persisted)?.value, SecretValue("old-key"))
                }
                XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
                XCTAssertFalse(FileManager.default.fileExists(atPath: secretFile(tools).path))
            }
        }
    }

    func testToolInputCapRejectsRatherThanTruncates() throws {
        let tools = try toolsWithPaths()
        try installService(tools)
        let store = makeStore(tools)
        let account = SecretAccount.provider(profile)
        try worker {
            try store.write(SecretValue("old-key"), account: account)
            XCTAssertThrowsError(try store.write(SecretValue(String(repeating: "s", count: 8_192)), account: account)) {
                XCTAssertEqual($0 as? SecretStoreError, .writeFailed)
            }
            XCTAssertEqual(try store.read(account: account, source: .persisted)?.value, SecretValue("old-key"))
        }
        XCTAssertEqual(tools.arguments.filter { $0.first == "store" }.count, 1)
    }

    func testFailedFileCleanupRestoresThePreviousServiceValue() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        let tools = try toolsWithPaths()
        try installService(tools)
        let account = SecretAccount.provider(profile)
        let store = makeStore(tools)
        let paths = LinuxPaths(environment: tools.environment)
        try worker {
            try store.write(SecretValue("old-service-key"), account: account)
            try LinuxSecretFile(paths: paths).write(SecretValue("old-file-key"), account: account)
        }
        let original = try Data(contentsOf: secretFile(tools))
        tools.environment["FAKE_CONFIG"] = paths.configDirectory.path
        defer { _ = chmod(paths.configDirectory.path, 0o700) }
        try tools.install("secret-tool", script: #"""
        case "$1" in
          lookup) /bin/cat "$FAKE_ITEMS/$5" ;;
          store) /bin/cat > "$FAKE_ITEMS/$7"; /bin/chmod 0500 "$FAKE_CONFIG" ;;
          clear) /bin/rm -f "$FAKE_ITEMS/$5"; /bin/chmod 0500 "$FAKE_CONFIG" ;;
          *) exit 2 ;;
        esac
        """#)
        let failing = makeStore(tools)
        try worker {
            XCTAssertThrowsError(try failing.write(SecretValue("new-key"), account: account)) {
                XCTAssertEqual($0 as? SecretStoreError, .writeFailed)
            }
            XCTAssertEqual(try failing.read(account: account, source: .persisted)?.value, SecretValue("old-service-key"))
            XCTAssertThrowsError(try failing.delete(account: account)) {
                XCTAssertEqual($0 as? SecretStoreError, .deleteFailed)
            }
            XCTAssertEqual(try failing.read(account: account, source: .persisted)?.value, SecretValue("old-service-key"))
        }
        XCTAssertEqual(try Data(contentsOf: secretFile(tools)), original)
    }

    func testFailedFileCleanupClearsANewServiceItemWhenThePreviousTierWasFile() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses directory permissions.") }
        let tools = try toolsWithPaths()
        let account = SecretAccount.provider(profile)
        try worker { try self.makeStore(tools).write(SecretValue("old-file-key"), account: account) }
        let original = try Data(contentsOf: secretFile(tools))
        try installService(tools)
        let paths = LinuxPaths(environment: tools.environment)
        tools.environment["FAKE_CONFIG"] = paths.configDirectory.path
        defer { _ = chmod(paths.configDirectory.path, 0o700) }
        try tools.install("secret-tool", script: FakeLinuxTools.recordArguments + "\n" + #"""
        case "$1" in
          lookup) if [ -f "$FAKE_ITEMS/$5" ]; then /bin/cat "$FAKE_ITEMS/$5"; else exit 1; fi ;;
          search) exit 0 ;;
          store) /bin/cat > "$FAKE_ITEMS/$7"; /bin/chmod 0500 "$FAKE_CONFIG" ;;
          clear) /bin/rm -f "$FAKE_ITEMS/$5" ;;
        esac
        """#)
        let store = makeStore(tools)
        try worker {
            XCTAssertThrowsError(try store.write(SecretValue("new-key"), account: account)) {
                XCTAssertEqual($0 as? SecretStoreError, .writeFailed)
            }
            XCTAssertEqual(try store.read(account: account, source: .persisted),
                StoredSecret(value: SecretValue("old-file-key"), tier: .file))
        }
        XCTAssertTrue(tools.arguments.contains(["clear", "service", "ch.lkmc.monkeyspaw", "account", account.rawValue]))
        XCTAssertEqual(try Data(contentsOf: secretFile(tools)), original)
    }

    func testServiceWriteAlsoRemovesAbandonedFileTemporaries() throws {
        let tools = try toolsWithPaths()
        try installService(tools)
        let paths = LinuxPaths(environment: tools.environment)
        try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let abandoned = paths.configDirectory.appendingPathComponent(".secrets-\(UUID().uuidString)")
        try Data("abandoned-key".utf8).write(to: abandoned)
        XCTAssertEqual(chmod(abandoned.path, 0o600), 0)
        let store = makeStore(tools)
        try worker { XCTAssertEqual(try store.write(SecretValue("new-key"), account: .provider(self.profile)), .secretService) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.configDirectory.path).isEmpty)
    }

    func testNeitherSecretNorToolErrorsReachStderrOrFileLogs() throws {
        let tools = try toolsWithPaths()
        try installService(tools)
        let paths = LinuxPaths(environment: tools.environment)
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let log = CompositeLogSink(sinks: [StandardErrorLog(output: pipe.fileHandleForWriting),
            FileLogSink(dataDirectory: paths.dataDirectory)], policy: LogLevelPolicy(environmentValue: "debug"))
        let secret = "key-sentinel-\(UUID().uuidString)"
        let toolError = "tool-error-sentinel-\(UUID().uuidString)"
        let store = makeStore(tools)
        try worker {
            let service = ProviderSettingsService(store: ProviderSettingsStore(
                files: try RootedFileStore(root: paths.configDirectory)), secrets: store, log: log)
            let draft = ProviderDraft(id: self.profile, displayName: "test", kind: .openaiCompatible,
                baseURL: "http://localhost:11434", modelID: "local", key: .replace(SecretValue(secret)))
            try service.save(draft)
        }
        tools.environment["FAKE_ERROR"] = toolError
        try tools.install("secret-tool", script: #"""
        if [ "$1" = lookup ]; then /bin/cat "$FAKE_ITEMS/$5"; exit 0; fi
        printf '%s' "$FAKE_ERROR"
        printf '%s' "$FAKE_ERROR" >&2
        exit 1
        """#)
        try worker {
            let service = ProviderSettingsService(store: ProviderSettingsStore(
                files: try RootedFileStore(root: paths.configDirectory)), secrets: self.makeStore(tools), log: log)
            let draft = ProviderDraft(id: self.profile, displayName: "test", kind: .openaiCompatible,
                baseURL: "http://localhost:11434", modelID: "local", key: .replace(SecretValue(secret)))
            XCTAssertThrowsError(try service.save(draft)) { error in
                XCTAssertFalse(String(reflecting: error).contains(secret))
                XCTAssertFalse(String(reflecting: error).contains(toolError))
            }
        }
        try pipe.fileHandleForWriting.close()
        let stderr = String(decoding: try pipe.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        let fileLog = try String(contentsOf: paths.dataDirectory.appendingPathComponent("logs/monkeyspaw.log"), encoding: .utf8)
        for output in [stderr, fileLog] {
            XCTAssertTrue(output.contains("Provider secret update failed."))
            XCTAssertFalse(output.contains(secret))
            XCTAssertFalse(output.contains(toolError))
        }
        let settings = try String(contentsOf: paths.configDirectory.appendingPathComponent("provider-settings.json"), encoding: .utf8)
        XCTAssertFalse(settings.contains(secret))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secretFile(tools).path))
    }

    func testMainThreadCannotStartSecretTool() throws {
        let tools = try toolsWithPaths()
        try installService(tools)
        let store = makeStore(tools)
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertThrowsError(try store.read(account: .provider(profile), source: .persisted)) {
            XCTAssertEqual($0 as? SecretStoreError, .unavailable)
        }
        XCTAssertThrowsError(try store.write(SecretValue("key"), account: .provider(profile)))
        XCTAssertThrowsError(try store.delete(account: .provider(profile)))
        XCTAssertTrue(tools.arguments.isEmpty)
    }

    func testCompositionInjectsTheDriverWithoutStartingSubprocesses() throws {
        let application = try GTKTestSupport.application()
        defer { GTKTestSupport.destroy(application) }
        let tools = try toolsWithPaths()
        tools.environment[profile.environmentVariable] = "operator-key"
        let environment = LinuxEnvironment(application: application, environment: tools.environment)
        defer { environment.shutdown() }
        let service = environment.providerSettingsService
        XCTAssertTrue(tools.arguments.isEmpty)
        try worker {
            let draft = ProviderDraft(id: self.profile, displayName: "test", kind: .openaiCompatible,
                baseURL: "http://localhost:11434", modelID: "local")
            try service.save(draft)
            XCTAssertEqual(try service.secretTier(for: self.profile), .environment)
        }
    }

    private func toolsWithPaths() throws -> FakeLinuxTools {
        let tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        return tools
    }

    private func makeStore(_ tools: FakeLinuxTools, timeout: Duration = Limits.linuxToolTimeout) -> LinuxSecretStore {
        LinuxSecretStore(paths: LinuxPaths(environment: tools.environment), runner: tools.runner, timeout: timeout)
    }

    private func secretFile(_ tools: FakeLinuxTools) -> URL {
        LinuxPaths(environment: tools.environment).configDirectory.appendingPathComponent("secrets-unencrypted.json")
    }

    private func installService(_ tools: FakeLinuxTools) throws {
        let items = tools.directory.appendingPathComponent("service")
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        tools.environment["FAKE_ITEMS"] = items.path
        try tools.install("secret-tool", script: FakeLinuxTools.recordArguments + "\n" + #"""
        case "$1" in
          lookup) if [ -f "$FAKE_ITEMS/$5" ]; then /bin/cat "$FAKE_ITEMS/$5"; else exit 1; fi ;;
          search) exit 0 ;; # All normal fixture searches are for absent items; real matches also print secret data.
          store) /bin/cat > "$FAKE_ITEMS/$7" ;;
          clear) /bin/rm -f "$FAKE_ITEMS/$5" ;;
          *) exit 2 ;;
        esac
        """#)
    }

    private func worker(_ body: @escaping () throws -> Void) throws {
        let done = expectation(description: "Background secret operation")
        let result = WorkerResult()
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            result.value = Result { try body() }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        try XCTUnwrap(result.value).get()
    }
}
#endif
