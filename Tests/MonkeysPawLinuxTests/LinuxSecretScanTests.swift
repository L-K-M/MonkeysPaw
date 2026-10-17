#if os(Linux)
import CGtk
import Foundation
import Glibc
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawLinux

final class LinuxSecretScanTests: XCTestCase {
    func testSecretServiceLifecycleLeavesNoSentinelOnDisk() throws {
        let portal = try FakePortal(address: FakePortal.requirePrivateBus(),
                                    globalShortcuts: nil, remoteDesktop: nil)
        defer { portal.shutdown() }
        try portal.exportSecretStore()
        try portal.ownName()
        try lifecycle(tier: .secretService)
        XCTAssertTrue(portal.secretMethods.contains("Store"))
        XCTAssertTrue(portal.secretMethods.contains("Lookup"))
        XCTAssertTrue(portal.secretMethods.contains("Clear"))
    }

    func testFileLifecycleLeavesOnlyOneUnencryptedPrivateCopy() throws {
        try lifecycle(tier: .file)
    }

    func testDeviceSecretServiceLifecycleLeavesNoSentinelOnDisk() throws {
        let portal = try FakePortal(address: FakePortal.requirePrivateBus(),
                                    globalShortcuts: nil, remoteDesktop: nil)
        defer { portal.shutdown() }
        try portal.exportSecretStore()
        try portal.ownName()
        try deviceLifecycle(tier: .secretService)
        for method in ["Store", "Lookup", "Clear"] {
            XCTAssertTrue(portal.secretMethods.contains(method), "Native secret driver boundary was not exercised")
        }
    }

    func testDeviceFileLifecycleLeavesOnlyOneUnencryptedPrivateCopy() throws {
        try deviceLifecycle(tier: .file)
    }

    func testMissingScanRootFailsInsteadOfPassingVacuously() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("mp-scan-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try SecretScan("sentinel-\(UUID().uuidString)").matches(in: [missing]))
    }

    func testScanTreatsOnlyMissingPathsAsVanished() {
        let missingUnderlying = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))])
        XCTAssertTrue(SecretScan.isVanished(CocoaError(.fileNoSuchFile)))
        XCTAssertTrue(SecretScan.isVanished(CocoaError(.fileReadNoSuchFile)))
        XCTAssertTrue(SecretScan.isVanished(missingUnderlying))
        XCTAssertFalse(SecretScan.isVanished(CocoaError(.fileReadNoPermission)))
        XCTAssertFalse(SecretScan.isVanished(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    func testScannerFindsRawEncodedAndNestedJSONInHiddenDirectories() throws {
        let tools = try FakeLinuxTools()
        let sentinel = "scan-\(UUID().uuidString)-\"\\/%+"
        let scan = try SecretScan(sentinel)
        let hidden = tools.directory.appendingPathComponent(".hidden/nested")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let encodings = try scanEncodings(sentinel)
        var expected = Set<URL>()
        for (index, bytes) in encodings.enumerated() {
            let file = hidden.appendingPathComponent("copy-\(index)")
            try bytes.write(to: file)
            expected.insert(file.standardizedFileURL)
        }
        XCTAssertEqual(try scan.matches(in: [tools.directory, hidden]), expected)
        XCTAssertEqual(scan.copyCount(in: encodings[0] + encodings[4]), 2)
        for file in expected { try FileManager.default.removeItem(at: file) }
        XCTAssertTrue(try scan.matches(in: [tools.directory]).isEmpty)
    }

    func testCombinedScannerFindsEveryEncodingAndRejectsHiddenLeaks() throws {
        let tools = try FakeLinuxTools()
        let root = tools.directory
        let first = root.appendingPathComponent(".first/nested")
        let second = root.appendingPathComponent(".second")
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let sentinels = ["scan-\(UUID().uuidString)-\"\\/%+", "longer-scan-\(UUID().uuidString)-\"\\/%+"]
        let scans = try sentinels.map(SecretScan.init)
        let combined = try SecretScan(combining: scans)
        var expected = Set<URL>()
        for (index, sentinel) in sentinels.enumerated() {
            let directory = index == 0 ? first : second
            var individual = Set<URL>()
            for (encoding, bytes) in try scanEncodings(sentinel).enumerated() {
                let file = directory.appendingPathComponent("copy-\(index)-\(encoding)")
                // Every representation crosses a read boundary, including nested JSON.
                try (Data(repeating: 0, count: 65_500) + bytes).write(to: file)
                individual.insert(file.standardizedFileURL)
            }
            XCTAssertTrue(try scans[index].matches(in: [directory]) == individual, "Single scan calibration failed at index \(index)")
            expected.formUnion(individual)
        }
        XCTAssertTrue(try combined.matches(in: [first, second]) == expected, "Disjoint roots lost a sentinel")
        XCTAssertTrue(try combined.matches(in: [root, first, second]) == expected, "Overlapping roots lost a sentinel")
        for file in expected { try FileManager.default.removeItem(at: file) }
        XCTAssertTrue(try combined.matches(in: [root]).isEmpty, "Removed calibration copies remained")

        let vault = first.appendingPathComponent("secrets-unencrypted.json").standardizedFileURL
        let saved = Data(sentinels[0].utf8)
        try saved.write(to: vault)
        XCTAssertTrue(try combined.matches(in: [root]) == [vault])
        for (index, scan) in scans.enumerated() {
            XCTAssertEqual(scan.copyCount(in: try Data(contentsOf: vault)), index == 0 ? 1 : 0)
        }
        let leak = second.appendingPathComponent("leak").standardizedFileURL
        let retired = Data(Data(sentinels[1].utf8).base64EncodedString().utf8)
        try (Data(repeating: 0, count: 65_532) + retired).write(to: leak)
        let leakedPaths = try combined.matches(in: [root, first, second])
        XCTAssertTrue(leakedPaths == [vault, leak], "Non-first sentinel escaped the combined scan")
        XCTAssertFalse(leakedPaths == [vault], "Wrong-file leak satisfied the fallback allowance")
        try FileManager.default.removeItem(at: leak)
        try (saved + Data([0]) + retired).write(to: vault)
        XCTAssertTrue(try combined.matches(in: [root]) == [vault])
        let bytes = try Data(contentsOf: vault)
        XCTAssertEqual(scans[0].copyCount(in: bytes), 1)
        XCTAssertEqual(scans[1].copyCount(in: bytes), 1)
        XCTAssertFalse(scans[1].copyCount(in: bytes) == 0, "Retired fallback copy satisfied the zero-copy allowance")
        XCTAssertThrowsError(try combined.matches(in: [vault]))
        try FileManager.default.removeItem(at: vault)
        XCTAssertTrue(try combined.matches(in: [root]).isEmpty)
        XCTAssertThrowsError(try SecretScan(combining: []))
        XCTAssertThrowsError(try combined.matches(in: [first, root.appendingPathComponent("missing")]))
        let unreadable = root.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        // CI runs as root, which can read chmod-000 directories.
        if FileManager.default.isReadableFile(atPath: unreadable.path) {
            XCTAssertTrue(try combined.matches(in: [unreadable]).isEmpty)
        } else {
            XCTAssertThrowsError(try combined.matches(in: [unreadable]))
        }
    }

    private func scanEncodings(_ sentinel: String) throws -> [Data] {
        let credential = try JSONSerialization.data(withJSONObject: ["key": sentinel])
        let nested = try JSONSerialization.data(withJSONObject: ["secret": String(decoding: credential, as: UTF8.self)])
        return [Data(sentinel.utf8), Data(Data(sentinel.utf8).base64EncodedString().utf8),
            Data(sentinel.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!.utf8),
            credential, nested, Data(repeating: 0, count: 65_532) + Data(sentinel.utf8) + Data([255, 0])]
    }

    private func lifecycle(tier: SecretTier) throws {
        try GTKTestSupport.requireDisplay()
        let tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        let temporary = tools.directory.appendingPathComponent("temporary")
        tools.environment["TMPDIR"] = temporary.path
        let paths = LinuxPaths(environment: tools.environment)
        for directory in [paths.configDirectory, paths.dataDirectory, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        if tier == .secretService {
            try installSecretBridge(tools)
        }
        let sentinel = "sk-scan-\(UUID().uuidString)-\"\\/%+"
        let scan = try SecretScan(sentinel)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appendingPathComponent("Package.swift").path))
        let stderr = temporary.appendingPathComponent("stderr.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: stderr.path, contents: nil))
        let output = try FileHandle(forWritingTo: stderr)
        defer { try? output.close() }
        let log = CompositeLogSink(sinks: [StandardErrorLog(output: output),
            FileLogSink(dataDirectory: paths.dataDirectory)], policy: LogLevelPolicy(environmentValue: "debug"))
        log.write(.debug, "Secret scan lifecycle started.")
        let transport = SecretScanTransport(key: SecretValue(sentinel))
        var graph = try self.graph(tools, transport: transport, log: log)
        var draft = ProviderDraft(displayName: "Sentinel profile", kind: .openaiCompatible,
            baseURL: "http://localhost:11434/v1", modelID: "manual",
            key: .replace(SecretValue(sentinel)))
        let id = draft.id
        let file = paths.configDirectory.appendingPathComponent("secrets-unencrypted.json").standardizedFileURL
        let roots = [repository, tools.directory, paths.configDirectory, paths.dataDirectory,
            paths.dataDirectory.appendingPathComponent("logs"), temporary]

        func checkpoint(_ step: String, hasKey: Bool = true) throws {
            log.write(.debug, "Secret scan checkpoint: \(step).")
            let expected: Set<URL> = tier == .file && hasKey ? [file] : []
            XCTAssertEqual(try scan.matches(in: roots), expected, "Unexpected secret copy after \(step)")
            if tier == .file && hasKey {
                var info = stat()
                XCTAssertEqual(lstat(file.path, &info), 0)
                XCTAssertEqual(info.st_mode & 0o777, 0o600)
                XCTAssertEqual(info.st_nlink, 1)
                XCTAssertEqual(info.st_uid, geteuid())
                let bytes = try Data(contentsOf: file)
                XCTAssertEqual(scan.copyCount(in: bytes), 1, "Fallback must contain exactly one sentinel")
                let map = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                XCTAssertEqual(map["storage"] as? String, "unencrypted")
                let secrets = try XCTUnwrap(map["secrets"] as? [String: String])
                XCTAssertEqual(Set(secrets.keys), [SecretAccount.provider(id).rawValue])
                let bound = try XCTUnwrap(secrets[SecretAccount.provider(id).rawValue])
                let credential = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bound.utf8)) as? [String: Any])
                XCTAssertTrue(credential["key"] as? String == sentinel, "Saved credential changed")
            }
        }

        try worker { try graph.settings.save(draft) }
        draft.key = .keep
        try assertStorage(graph, tier: tier)
        try checkpoint("save")
        let metadata = try Data(contentsOf: paths.configDirectory.appendingPathComponent("provider-settings.json"))
        try testConnection(graph, draft: draft, expected: .ok(models: []))
        try checkpoint("Test connection")
        try testConnection(graph, draft: draft, expected: .authentication)
        XCTAssertTrue(try Data(contentsOf: paths.configDirectory.appendingPathComponent("provider-settings.json")) == metadata)
        try checkpoint("failed Test connection")

        graph = try self.graph(tools, transport: transport, log: log)
        try worker {
            XCTAssertEqual(graph.settings.snapshot.settings.selectedProfileID, id)
            let key = try graph.settings.connection(for: id).key
            XCTAssertTrue(key == SecretValue(sentinel), "Restart lost the saved credential")
        }
        try assertStorage(graph, tier: tier)
        try checkpoint("restart")
        draft.displayName = "Renamed profile"
        try worker { try graph.settings.save(draft) }
        try checkpoint("rename")
        let other = ProviderDraft(displayName: "Keyless profile", kind: .openaiCompatible,
            baseURL: "http://localhost:11434/v1", modelID: "other", key: .clear)
        try worker {
            try graph.settings.save(other)
            try graph.settings.selectProfile(other.id)
            XCTAssertNil(try graph.settings.connection(for: other.id).key)
        }
        try checkpoint("switch away")
        try worker {
            try graph.settings.selectProfile(id)
            XCTAssertTrue(try graph.settings.connection(for: id).key == SecretValue(sentinel))
        }
        try checkpoint("switch back")
        try worker {
            try graph.settings.deleteProfile(other.id)
            XCTAssertTrue(try graph.settings.connection(for: id).key == SecretValue(sentinel))
        }
        try checkpoint("delete other profile")
        try worker {
            try graph.settings.deleteProfile(id)
            XCTAssertNil(try graph.secrets.read(account: .provider(id), source: .persisted))
        }
        try checkpoint("delete sentinel profile", hasKey: false)
        graph = try self.graph(tools, transport: transport, log: log)
        XCTAssertTrue(graph.settings.snapshot.settings.profiles.isEmpty)
        try checkpoint("restart after deletion", hasKey: false)
    }

    private func deviceLifecycle(tier: SecretTier) throws {
        let application = try GTKTestSupport.application()
        defer { GTKTestSupport.destroy(application) }
        let tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        tools.environment["XDG_CURRENT_DESKTOP"] = "sway"
        tools.environment["MONKEYSPAW_LOG"] = "debug"
        let temporary = tools.directory.appendingPathComponent("temporary")
        tools.environment["TMPDIR"] = temporary.path
        if tier == .secretService { try installSecretBridge(tools) }
        let paths = LinuxPaths(environment: tools.environment)
        let logs = paths.dataDirectory.appendingPathComponent("logs")
        for directory in [paths.configDirectory, paths.dataDirectory, logs, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appendingPathComponent("Package.swift").path))
        let roots = [repository, tools.directory, paths.configDirectory, paths.dataDirectory, logs, temporary]
        let fallback = paths.configDirectory.appendingPathComponent("secrets-unencrypted.json").standardizedFileURL
        let passwordSentinel = "password-\(UUID().uuidString)-\"\\/%+"
        let providerSentinel = "provider-\(UUID().uuidString)-\"\\/%+"
        let tokens = (0..<7).map { _ in Self.deviceToken() }
        let scans = try ([providerSentinel] + tokens + [passwordSentinel]).map(SecretScan.init)
        let allScans = try SecretScan(combining: scans)
        // Calibrate the actual roots with this run's valid token, across a read boundary.
        let calibration = temporary.appendingPathComponent(".calibration")
        let calibrationBytes = Data(repeating: 0, count: 65_532) + Data(tokens[0].utf8)
            + Data([0]) + Data(Data(tokens[0].utf8).base64EncodedString().utf8)
        try calibrationBytes.write(to: calibration)
        XCTAssertTrue(try scans[1].matches(in: roots) == [calibration.standardizedFileURL], "Device scanner calibration failed")
        XCTAssertEqual(scans[1].copyCount(in: calibrationBytes), 2)
        try FileManager.default.removeItem(at: calibration)

        let http = DeviceScanTransport(password: passwordSentinel)
        var environments: [LinuxEnvironment] = []
        func compose(_ values: [String: String]) -> LinuxEnvironment {
            let environment = LinuxEnvironment(application: application, environment: values, syncTransport: http)
            environments.append(environment)
            _ = environment.libraryStatusModel
            return environment
        }
        func stop(_ environment: LinuxEnvironment) throws {
            environment.shutdown()
            try worker { await environment.drainSync() }
        }
        defer {
            for environment in environments { try? stop(environment) }
        }
        func account(_ environment: LinuxEnvironment) throws -> AccountModel {
            let model = try XCTUnwrap(environment.accountModel)
            XCTAssertTrue(GTKTestSupport.spin { !model.state.isBusy })
            return model
        }
        func accountIntent(_ model: AccountModel, _ intent: () -> Void) {
            var completed = false
            let observer = model.addObserver { if !$0.isBusy { completed = true } }
            defer { model.removeObserver(observer) }
            intent()
            XCTAssertTrue(GTKTestSupport.spin(until: { completed }, timeout: .seconds(15)), "Account intent did not complete")
        }
        func login(_ environment: LinuxEnvironment, token: String, username: String = "person",
                   user: String = DeviceScanTransport.firstUser, server: String = DeviceScanTransport.firstServer,
                   issue: AccountIssue? = nil) throws -> AccountModel {
            http.candidate = .init(token: token, username: username, user: user, server: server)
            let model = try account(environment)
            var password = passwordSentinel
            accountIntent(model) {
                model.login(server: server, username: username, password: &password, deviceName: "Linux scan")
            }
            XCTAssertTrue(password.isEmpty, "Login retained secure input")
            XCTAssertEqual(model.state.error, issue)
            XCTAssertEqual(model.state.enabled, issue == nil)
            if issue == nil {
                XCTAssertEqual(model.state.secretTier, tier)
                if tier == .file { XCTAssertTrue(model.state.secretStorageMessage.contains("unencrypted")) }
            }
            return model
        }
        func savedAccount(_ data: URL) throws -> SyncAccount {
            let files = try RootedFileStore(root: data)
            return try XCTUnwrap(SyncAccountStore(files: files, operations: files).cachedAccount)
        }
        let store = LinuxSecretStore(paths: paths, runner: tools.runner)
        var environment = compose(tools.environment)
        let provider = ProviderDraft(displayName: "Unrelated provider", kind: .openaiCompatible,
            baseURL: "http://localhost:11434/v1", modelID: "manual", key: .replace(SecretValue(providerSentinel)))
        let settings = environment.providerSettingsService
        try worker { try settings.save(provider) }
        // Another real account graph shares the native vault, with independent metadata/library roots.
        var otherValues = tools.environment
        otherValues["HOME"] = tools.directory.appendingPathComponent("other-home").path
        otherValues["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("other-data").path
        var other = compose(otherValues)
        _ = try login(other, token: tokens[0], username: "other", user: DeviceScanTransport.otherUser)
        let otherPaths = LinuxPaths(environment: otherValues)
        let otherAccount = try savedAccount(otherPaths.dataDirectory)
        try stop(other)

        func checkpoint(_ step: String, saved: Set<Int> = []) throws {
            environment.log.write(.debug, "Device privacy checkpoint: \(step).")
            let persisted = Set([0, 1]).union(saved)
            let expected: Set<URL> = tier == .file ? [fallback] : []
            // The union forbids other paths; individual counts discriminate every saved/retired secret.
            XCTAssertTrue(try allScans.matches(in: roots) == expected, "Unexpected \(tier) disk copies at \(step)")
            if tier == .file {
                let bytes = try Data(contentsOf: fallback)
                for (index, scan) in scans.enumerated() {
                    XCTAssertEqual(scan.copyCount(in: bytes), persisted.contains(index) ? 1 : 0,
                        "Unexpected fallback copy count at \(step), sentinel index \(index)")
                }
                var info = stat()
                XCTAssertEqual(lstat(fallback.path, &info), 0)
                XCTAssertEqual(info.st_mode & mode_t(Glibc.S_IFMT), mode_t(Glibc.S_IFREG))
                XCTAssertEqual(info.st_mode & 0o777, 0o600)
                XCTAssertEqual(info.st_nlink, 1)
                XCTAssertEqual(info.st_uid, geteuid())
                let map = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                XCTAssertTrue(map?["storage"] as? String == "unencrypted", "Fallback storage label changed")
            }
            try worker {
                XCTAssertTrue(try settings.connection(for: provider.id).key == SecretValue(providerSentinel), "Unrelated provider was lost")
                let retained = try store.read(account: otherAccount.secretAccount, source: .persisted)
                XCTAssertEqual(retained?.tier, tier)
                XCTAssertTrue(retained?.value.withValue { $0.contains(tokens[0]) } == true, "Unrelated device was lost")
            }
        }

        try checkpoint("unrelated credentials saved")
        let reserved = paths.documentsDirectory.appendingPathComponent("MonkeysPaw/Groups")
        try FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: true)
        let failed = try login(environment, token: tokens[1], issue: .reservedFolders)
        XCTAssertTrue(failed.state.cleanup.isComplete)
        XCTAssertEqual(failed.state.cleanup.remoteRevocation, .revoked)
        XCTAssertEqual(http.logoutCount, 1)
        try checkpoint("failed activation compensated")
        try FileManager.default.removeItem(at: reserved)

        var model = try login(environment, token: tokens[2])
        let first = try savedAccount(paths.dataDirectory)
        try checkpoint("login saved", saved: [3])
        try stop(environment)
        environment = compose(tools.environment)
        model = try account(environment)
        accountIntent(model) { model.startup() }
        XCTAssertTrue(model.state.enabled)
        XCTAssertEqual(model.state.secretTier, tier)
        XCTAssertTrue(try savedAccount(paths.dataDirectory) == first)
        try checkpoint("reconstructed persisted account", saved: [3])

        let invite = try XCTUnwrap(environment.inviteModel)
        func stage() throws {
            let before = http.inviteCount
            var input = try SyncInviteLink(tokens[6], server: DeviceScanTransport.firstServer).text
            invite.stage(&input)
            XCTAssertTrue(input.isEmpty, "Invite input was retained")
            XCTAssertTrue(GTKTestSupport.spin { !invite.state.isBusy && invite.state.canAccept })
            XCTAssertEqual(http.inviteCount, before, "Staging redeemed an invite")
        }
        try stage()
        try checkpoint("invite staged in memory", saved: [3])
        invite.dismiss()
        XCTAssertTrue(GTKTestSupport.spin { !invite.state.hasStagedInvite && invite.state.destination == nil })
        try checkpoint("invite dismissed", saved: [3])
        try stage()
        var invitePassword = passwordSentinel
        invite.accept(as: .existingAccount, password: &invitePassword)
        XCTAssertTrue(invitePassword.isEmpty, "Invite acceptance retained secure input")
        XCTAssertTrue(GTKTestSupport.spin { !invite.state.isBusy && invite.state.error != nil })
        XCTAssertFalse(invite.state.hasStagedInvite)
        XCTAssertFalse(invite.state.canAccept)
        try checkpoint("invite dismissed and failed redemption cleared", saved: [3])

        model = try login(environment, token: tokens[3], username: "second", user: DeviceScanTransport.otherUser)
        XCTAssertTrue(model.state.connection?.userID.rawValue == DeviceScanTransport.otherUser)
        try checkpoint("user switched", saved: [4])
        model = try login(environment, token: tokens[4], username: "second", user: DeviceScanTransport.otherUser,
            server: DeviceScanTransport.secondServer)
        XCTAssertTrue(model.state.connection?.serverURL.absoluteString == DeviceScanTransport.secondServer)
        let current = try savedAccount(paths.dataDirectory)
        try checkpoint("server switched", saved: [5])
        let variable = "MONKEYSPAW_DEVICE_" + current.connectionID.uuidString.replacingOccurrences(of: "-", with: "") + "_TOKEN"
        tools.environment[variable] = tokens[5]
        http.allowOverride(tokens[5], for: tokens[4])
        try stop(environment)
        environment = compose(tools.environment)
        model = try account(environment)
        accountIntent(model) { model.startup() }
        XCTAssertTrue(model.state.enabled)
        XCTAssertEqual(model.state.secretTier, .environment)
        XCTAssertTrue(model.state.secretStorageMessage.contains("read-only"))
        try checkpoint("read-only override reconstructed", saved: [5])

        // The real driver's shared-map mutation guard refuses cleanup, without corrupting any secret.
        let directory = Glibc.open(paths.configDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(directory, 0)
        defer { _ = Glibc.close(directory) }
        XCTAssertEqual(flock(directory, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(directory, LOCK_UN) }
        accountIntent(model) { model.signOut() }
        XCTAssertNil(model.state.connection)
        XCTAssertFalse(model.state.enabled)
        XCTAssertEqual(model.state.cleanup.failedSecretDeletions, 1)
        XCTAssertFalse(model.state.cleanup.isComplete)
        try checkpoint("failed sign-out cleanup retained for retry", saved: [5])
        try stop(environment)
        environment = compose(tools.environment)
        model = try account(environment)
        let beforeStartup = http.requestCount
        accountIntent(model) { model.startup() }
        XCTAssertFalse(model.state.enabled)
        XCTAssertEqual(http.requestCount, beforeStartup, "Inactive connection used a surviving override")
        XCTAssertEqual(model.state.cleanup.failedSecretDeletions, 1)
        XCTAssertEqual(flock(directory, LOCK_UN), 0)
        accountIntent(model) { model.signOut() }
        XCTAssertTrue(model.state.cleanup.isComplete)
        let overriddenStore = LinuxSecretStore(paths: paths, runner: tools.runner)
        try worker {
            XCTAssertTrue(try overriddenStore.read(account: current.secretAccount, source: .persisted) == nil, "Persisted token survived cleanup")
            let effective = try overriddenStore.read(account: current.secretAccount, source: .effective)
            XCTAssertEqual(effective?.tier, .environment)
            XCTAssertTrue(effective?.value == SecretValue(tokens[5]), "Read-only override was changed")
        }
        XCTAssertTrue(tools.environment[variable] == tokens[5], "Persisted cleanup changed the parent environment")
        try checkpoint("successful cleanup preserved override only in memory")
        try stop(environment)
        environment = compose(tools.environment)
        model = try account(environment)
        let afterCleanup = http.requestCount
        accountIntent(model) { model.startup() }
        XCTAssertFalse(model.state.enabled)
        XCTAssertNil(model.state.connection)
        XCTAssertEqual(http.requestCount, afterCleanup)
        let registration = try XCTUnwrap(environment.inviteModel)
        var input = try SyncInviteLink(tokens[6], server: DeviceScanTransport.firstServer).text
        registration.stage(&input)
        XCTAssertTrue(input.isEmpty, "Registration retained invite input")
        XCTAssertTrue(GTKTestSupport.spin { registration.state.canAccept && !registration.state.isBusy })
        var registrationPassword = passwordSentinel
        registration.accept(as: .newAccount, username: "new-person", password: &registrationPassword, deviceName: "Linux")
        XCTAssertTrue(registrationPassword.isEmpty, "Registration retained secure input")
        XCTAssertTrue(GTKTestSupport.spin { !registration.state.isBusy && registration.state.error != nil })
        XCTAssertFalse(registration.state.hasStagedInvite)
        XCTAssertFalse(registration.state.canAccept)
        try checkpoint("failed registration cleared invite and password")
        other = compose(otherValues)
        let retained = try account(other)
        accountIntent(retained) { retained.startup() }
        XCTAssertTrue(retained.state.enabled)
        XCTAssertEqual(retained.state.secretTier, tier)
        XCTAssertTrue(try savedAccount(otherPaths.dataDirectory) == otherAccount)
        try checkpoint("signed-out reconstruction and unrelated account restart")
        XCTAssertFalse(http.sentOnMain, "HTTP work ran on the GLib thread")
    }

    private static func deviceToken() -> String {
        let value = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertTrue((try? SyncAPISchema.token.validate(.string(value))) != nil, "Runtime token is invalid")
        return value
    }

    private func installSecretBridge(_ tools: FakeLinuxTools) throws {
        tools.environment["DBUS_SESSION_BUS_ADDRESS"] = try FakePortal.requirePrivateBus()
        // The implementation host supplies GIO in its userland sysroot.
        tools.environment["LD_LIBRARY_PATH"] = ProcessInfo.processInfo.environment["MONKEYSPAW_HOST_X11_LIBRARIES"]
            ?? ProcessInfo.processInfo.environment["LD_LIBRARY_PATH"]
        try tools.install("secret-tool", script: "exec /usr/bin/python3 \"$SCAN_BRIDGE\" \"$@\"")
        let bridge = tools.directory.appendingPathComponent("bridge.py")
        try Data(Self.bridge.utf8).write(to: bridge)
        tools.environment["SCAN_BRIDGE"] = bridge.path
    }

    private struct Graph {
        let secrets: LinuxSecretStore
        let settings: ProviderSettingsService
        let assistant: AssistantService
        let work: LinuxBackgroundWork
    }

    private func graph(_ tools: FakeLinuxTools, transport: SecretScanTransport, log: LogSink) throws -> Graph {
        let paths = LinuxPaths(environment: tools.environment)
        let files = try RootedFileStore(root: paths.configDirectory)
        let secrets = LinuxSecretStore(paths: paths, runner: tools.runner)
        let settings = ProviderSettingsService(store: ProviderSettingsStore(files: files, log: log), secrets: secrets, log: log)
        let work = LinuxBackgroundWork()
        let assistant = AssistantService(providerSettings: settings, anthropic: AnthropicClient(transport: transport),
            openAICompatible: OpenAIClient(transport: transport, providerState: ProviderStateStore(files: files)),
            work: work, main: GLibMainThread())
        return Graph(secrets: secrets, settings: settings, assistant: assistant, work: work)
    }

    private func assertStorage(_ graph: Graph, tier: SecretTier) throws {
        let model = AssistantSettingsModel(settings: graph.settings, assistant: graph.assistant,
            work: graph.work, mainThread: GLibMainThread())
        XCTAssertTrue(GTKTestSupport.spin { model.state.operation == nil && model.state.keyStorage == .saved(tier) })
        XCTAssertEqual(model.state.keyStorage, .saved(tier))
        if tier == .file {
            XCTAssertTrue(LinuxAssistantSettingsStrings.storage(model.state.keyStorage).contains("unencrypted"))
            XCTAssertTrue(LinuxAssistantSettingsStrings.unencrypted.contains("unencrypted"))
        }
    }

    private func testConnection(_ graph: Graph, draft: ProviderDraft, expected: ConnectionTestResult) throws {
        var result: ConnectionTestResult?
        let test = graph.assistant.testConnection(draft: draft) { result = $0 }
        defer { test.cancel() }
        XCTAssertTrue(GTKTestSupport.spin { result != nil })
        XCTAssertEqual(result, expected)
    }

    private func worker(_ body: @escaping () async throws -> Void) throws {
        final class Receipt {
            private let lock = NSLock()
            private var stored: Result<Void, Error>?
            var value: Result<Void, Error>? {
                get { lock.lock(); defer { lock.unlock() }; return stored }
                set { lock.lock(); defer { lock.unlock() }; stored = newValue }
            }
        }
        let receipt = Receipt()
        Task.detached {
            do { try await body(); receipt.value = .success(()) }
            catch { receipt.value = .failure(error) }
        }
        // The worker's fake service calls need this thread to drain GLib.
        XCTAssertTrue(GTKTestSupport.spin(until: { receipt.value != nil }, timeout: .seconds(15)))
        try XCTUnwrap(receipt.value).get()
    }

    /// Implements only secret-tool's CLI boundary, using the existing private
    /// portal fixture's test interface rather than a disk-backed fake vault.
    private static let bridge = #"""
    import ctypes as c
    import sys
    gio = c.CDLL("libgio-2.0.so.0")
    glib = c.CDLL("libglib-2.0.so.0")
    def api(lib, name, result, *args):
        fn = getattr(lib, name)
        fn.restype, fn.argtypes = result, args
        return fn
    ptr, text, integer = c.c_void_p, c.c_char_p, c.c_int
    bus_get = api(gio, "g_bus_get_sync", ptr, integer, ptr, ptr)
    call = api(gio, "g_dbus_connection_call_sync", ptr, ptr, text, text, text, text, ptr, ptr, integer, integer, ptr, ptr)
    string = api(glib, "g_variant_new_string", ptr, text)
    tuple_value = api(glib, "g_variant_new_tuple", ptr, c.POINTER(ptr), c.c_size_t)
    child = api(glib, "g_variant_get_child_value", ptr, ptr, c.c_size_t)
    boolean = api(glib, "g_variant_get_boolean", integer, ptr)
    value_text = api(glib, "g_variant_get_string", text, ptr, ptr)
    unref = api(glib, "g_variant_unref", None, ptr)
    object_unref = api(gio, "g_object_unref", None, ptr)
    try:
        args = sys.argv[1:]
        action = args[0]
        account = args[args.index("account") + 1]
        values = [account.encode()]
        if action == "store":
            values.append(sys.stdin.buffer.read())
        children = (ptr * len(values))(*(string(value) for value in values))
        parameters = tuple_value(children, len(values))
        bus = bus_get(2, None, None)
        if not bus:
            sys.exit(2)
        reply = call(bus, b"org.freedesktop.portal.Desktop", b"/org/freedesktop/portal/desktop",
            b"ch.lkmc.monkeyspaw.tests.SecretStore", action.capitalize().encode(), parameters,
            None, 0, 1500, None, None)
        if not reply:
            sys.exit(2)
        status = 0
        if action in ("lookup", "search"):
            found, value = child(reply, 0), child(reply, 1)
            present = boolean(found)
            if action == "lookup":
                if present:
                    sys.stdout.buffer.write(value_text(value, None))
                else:
                    status = 1
            elif present:
                sys.stdout.write("[item]")
            unref(found)
            unref(value)
        unref(reply)
        object_unref(bus)
        sys.exit(status)
    except Exception:
        sys.exit(2)
    """#
}

private actor SecretScanTransport: HTTPTransporting {
    private let key: SecretValue
    private var requests = 0
    init(key: SecretValue) { self.key = key }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests += 1
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.path, "/v1/models")
        XCTAssertNil(request.body)
        XCTAssertTrue(key.withValue { request.headers["Authorization"] == "Bearer " + $0 }, "Test used the wrong key")
        if requests == 1 { return HTTPResponse(statusCode: 200, body: Data(#"{"data":[]}"#.utf8)) }
        return HTTPResponse(statusCode: 401, body: key.withValue { Data($0.utf8) })
    }
}

/// Only the HTTP boundary is simulated; no credentials or request/error bodies
/// are retained in diagnostics. Each bearer is checked against its destination.
private final class DeviceScanTransport: HTTPTransporting, @unchecked Sendable {
    static let firstServer = "https://sync.example.test/paw"
    static let secondServer = "https://other.example.test/paw"
    static let firstUser = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    static let otherUser = "01ARZ3NDEKTSV4RRFFQ69G5FAX"
    private static let device = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
    struct Session {
        let token: String
        let username: String
        let user: String
        let server: String
    }
    private let lock = NSLock()
    private let password: String
    private var next: Session?
    private var sessions: [String: Session] = [:]
    private var requests = 0
    private var logouts = 0
    private var invites = 0
    private var onMain = false
    var candidate: Session? { get { locked { next } } set { locked { next = newValue } } }
    var requestCount: Int { locked { requests } }
    var logoutCount: Int { locked { logouts } }
    var inviteCount: Int { locked { invites } }
    var sentOnMain: Bool { locked { onMain } }

    init(password: String) { self.password = password }

    func allowOverride(_ token: String, for persisted: String) {
        locked {
            guard let saved = sessions["Bearer " + persisted] else { XCTFail("Missing persisted HTTP session"); return }
            sessions["Bearer " + token] = Session(token: token, username: saved.username, user: saved.user, server: saved.server)
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        locked { requests += 1; onMain = onMain || Thread.isMainThread }
        if request.url.path.hasSuffix("/login") {
            let body = request.body.flatMap { try? JSONDecoder().decode(SyncAPI.LoginRequest.self, from: $0) }
            guard let session = candidate else { throw HTTPTransportError.invalidRequest }
            XCTAssertTrue(body?.password == password, "Login password changed at the HTTP boundary")
            XCTAssertTrue(body?.username == session.username, "Login account changed at the HTTP boundary")
            XCTAssertTrue(request.headers["Authorization"] == nil, "Login sent an existing credential")
            XCTAssertTrue(request.url.absoluteString == session.server + "/api/v1/auth/login", "Login destination changed")
            locked { sessions["Bearer " + session.token] = session }
            return try response(SyncAPI.AuthResponse(deviceToken: session.token, user: user(session)))
        }
        if request.url.path.hasSuffix("/register") {
            locked { invites += 1 }
            let body = request.body.flatMap { try? JSONDecoder().decode(SyncAPI.RegisterRequest.self, from: $0) }
            XCTAssertTrue(body?.password == password, "Registration password changed at the HTTP boundary")
            XCTAssertTrue(request.headers["Authorization"] == nil, "Registration sent an existing credential")
            // Deliberately hostile error payloads must not reach persistence or logs.
            return HTTPResponse(statusCode: 400, body: request.body ?? Data())
        }
        guard let session = locked({ sessions[request.headers["Authorization"] ?? ""] }) else {
            XCTFail("Authenticated request used an unknown credential")
            throw HTTPTransportError.invalidRequest
        }
        XCTAssertTrue(request.url.absoluteString.hasPrefix(session.server + "/api/v1/"), "Credential crossed its server binding")
        if request.url.path.hasSuffix("/me") {
            return try response(SyncAPI.MeResponse(user: user(session), groups: [], devices: [
                .init(id: Self.device, name: "Linux scan", createdAt: timestamp, lastSeenAt: nil, revokedAt: nil, isCurrent: true)]))
        }
        if request.url.path.hasSuffix("/sync/pull") {
            return try response(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: [
                .init(identity: .user(userID: session.user), mode: .snapshot, head: 0, cursor: "empty", hasMore: false, items: [])], removed: []))
        }
        if request.url.path.hasSuffix("/groups/join") {
            locked { invites += 1 }
            return HTTPResponse(statusCode: 400, body: request.body ?? Data())
        }
        guard request.url.path.hasSuffix("/logout") else {
            XCTFail("Unexpected sync HTTP endpoint")
            throw HTTPTransportError.invalidRequest
        }
        locked { logouts += 1 }
        return try response(SyncAPI.EmptyResponse())
    }

    private let timestamp = "2026-10-17T00:00:00.000Z"
    private func user(_ session: Session) -> SyncAPI.User {
        .init(id: session.user, username: session.username, displayName: nil, accountKind: .member, createdAt: timestamp, disabledAt: nil)
    }
    private func response<T: APIObjectDTO>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value))
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}
#endif
