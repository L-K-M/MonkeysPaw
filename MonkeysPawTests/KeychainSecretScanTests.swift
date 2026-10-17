import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class KeychainSecretScanTests: XCTestCase {
    func testKeychainLifecycleLeavesNoSentinelOnDiskWithoutPrompts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-secret-scan-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        let data = root.appendingPathComponent("data")
        let temporary = root.appendingPathComponent("temporary")
        for directory in [config, data, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let sentinel = "sk-scan-\(UUID().uuidString)-\"\\/%+"
        let scan = try SecretScan(sentinel)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appendingPathComponent("Package.swift").path))
        let stderr = temporary.appendingPathComponent("stderr.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: stderr.path, contents: nil))
        let output = try FileHandle(forWritingTo: stderr)
        defer { try? output.close() }
        let log = CompositeLogSink(sinks: [KeychainScanLog(output: output), FileLogSink(dataDirectory: data)],
            policy: LogLevelPolicy(environmentValue: "debug"))
        log.write(.debug, "Secret scan lifecycle started.")
        // The service namespace is unique; never touch the app's real secret-map item.
        let itemService = "ch.lkmc.monkeyspaw.tests.scan." + UUID().uuidString
        let transport = KeychainScanTransport(key: SecretValue(sentinel))
        var graph = try self.graph(config: config, itemService: itemService, transport: transport, log: log)
        var draft = ProviderDraft(displayName: "Sentinel profile", kind: .anthropic,
            baseURL: "https://api.anthropic.com", modelID: "manual", key: .replace(SecretValue(sentinel)))
        let id = draft.id
        do { try worker { try graph.settings.save(draft) } }
        catch let error as ProviderSettingsError where error == .secret(.locked) || error == .secret(.unavailable) {
            throw XCTSkip("Login Keychain is unavailable or requires interaction; owner verification remains required")
        }
        defer {
            do { try worker { try graph.secrets.delete(account: .provider(id)) } }
            catch { XCTFail("Could not remove the uniquely named scan Keychain item") }
        }
        draft.key = .keep
        let roots = [repository, root, config, data, data.appendingPathComponent("logs"), temporary]
        func checkpoint(_ step: String) throws {
            log.write(.debug, "Secret scan checkpoint: \(step).")
            let matches = try scan.matches(in: roots)
            XCTAssertTrue(matches.isEmpty, "Unexpected secret copy after \(step): \(matches.map(\.path).sorted())")
        }

        try assertStorage(graph)
        try checkpoint("save")
        let metadata = try Data(contentsOf: config.appendingPathComponent("provider-settings.json"))
        try testConnection(graph, draft: draft, expected: .ok(models: []))
        try checkpoint("Test connection")
        try testConnection(graph, draft: draft, expected: .authentication)
        XCTAssertTrue(try Data(contentsOf: config.appendingPathComponent("provider-settings.json")) == metadata)
        try checkpoint("failed Test connection")
        graph = try self.graph(config: config, itemService: itemService, transport: transport, log: log)
        try worker {
            XCTAssertEqual(graph.settings.snapshot.settings.selectedProfileID, id)
            XCTAssertTrue(try graph.settings.connection(for: id).key == SecretValue(sentinel), "Restart lost the saved credential")
        }
        try assertStorage(graph)
        try checkpoint("restart")
        draft.displayName = "Renamed profile"
        try worker { try graph.settings.save(draft) }
        try checkpoint("rename")
        let other = ProviderDraft(displayName: "Keyless profile", kind: .anthropic,
            baseURL: "https://api.anthropic.com", modelID: "other", key: .clear)
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
        try checkpoint("delete sentinel profile")
        graph = try self.graph(config: config, itemService: itemService, transport: transport, log: log)
        XCTAssertTrue(graph.settings.snapshot.settings.profiles.isEmpty)
        try checkpoint("restart after deletion")
    }

    func testSyncDeviceLifecycleLeavesNoSentinelsAndPreservesOtherAccounts() throws {
        XCTAssertTrue(Thread.isMainThread)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-device-scan-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        let data = root.appendingPathComponent("data")
        let library = root.appendingPathComponent("library")
        let temporary = root.appendingPathComponent("temporary")
        for directory in [config, data.appendingPathComponent("logs"), library, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appendingPathComponent("Package.swift").path))
        let stderr = temporary.appendingPathComponent("stderr.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: stderr.path, contents: nil))
        let output = try FileHandle(forWritingTo: stderr)
        defer { try? output.close() }
        let log = CompositeLogSink(sinks: [KeychainScanLog(output: output), FileLogSink(dataDirectory: data)],
            policy: LogLevelPolicy(environmentValue: "debug"))
        let providerKey = "sk-scan-\(UUID().uuidString)-\"\\/%+"
        let password = "Runtime-password-\(UUID().uuidString)-\"\\/%+"
        let tokens = try (0..<6).map { _ in
            Data(try SystemEntropy().bytes(count: 32)).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let scans = try ([providerKey, password] + tokens).map(SecretScan.init)
        let allScans = try SecretScan(combining: scans)
        let roots = [repository, root, config, data, data.appendingPathComponent("logs"), temporary]
        // Both devices and the provider share one unique real Keychain map.
        let itemService = "ch.lkmc.monkeyspaw.tests.device-scan." + UUID().uuidString
        let audit = KeychainScanAudit()
        let provider = try graph(config: config, itemService: itemService,
            transport: KeychainScanTransport(key: SecretValue(providerKey)), log: log)
        let draft = ProviderDraft(displayName: "Unrelated provider", kind: .anthropic,
            baseURL: "https://api.anthropic.com", modelID: "manual", key: .replace(SecretValue(providerKey)))
        do { try worker { try provider.settings.save(draft) } }
        catch let error as ProviderSettingsError where error == .secret(.locked) || error == .secret(.unavailable) {
            throw XCTSkip("Login Keychain is unavailable or requires interaction; owner verification remains required")
        }
        defer {
            do {
                try worker {
                    for account in audit.writtenAccounts { try provider.secrets.delete(account: account) }
                    try provider.secrets.delete(account: .provider(draft.id))
                }
            } catch { XCTFail("Could not remove the uniquely named device-scan Keychain item") }
        }
        let server = "https://example.test/paw"
        let otherServer = "https://other.test/paw"
        let user = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!
        let otherUser = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAZ")!
        let device = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAW")!
        let otherDevice = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAX")!
        let transport = KeychainDeviceScanTransport(sessions: [
            .init(server: server, user: user, username: "person", device: device, token: SecretValue(tokens[0]), operation: .register),
            .init(server: server, user: user, username: "person", device: device, token: SecretValue(tokens[2]), operation: .login),
            .init(server: server, user: otherUser, username: "other", device: device, token: SecretValue(tokens[3]), operation: .login),
            .init(server: otherServer, user: otherUser, username: "other", device: device, token: SecretValue(tokens[4]), operation: .login)
        ], password: SecretValue(password), invite: SecretValue(tokens[5]))
        let otherTransport = KeychainDeviceScanTransport(sessions: [
            .init(server: server, user: user, username: "person", device: otherDevice, token: SecretValue(tokens[1]), operation: .login)
        ], password: SecretValue(password), invite: SecretValue(tokens[5]))
        var other = try syncGraph(library: root.appendingPathComponent("other-library"),
            data: root.appendingPathComponent("other-data"), itemService: itemService, audit: audit, transport: otherTransport)
        defer { retire(other) }
        try login(other, server: server, password: password)
        let otherSecret = try XCTUnwrap(audit.writtenAccounts.last)
        var primary = try syncGraph(library: library, data: data, itemService: itemService, audit: audit, transport: transport)
        defer { retire(primary) }

        func checkpoint(_ step: String) throws {
            try worker {
                XCTAssertTrue(try provider.settings.connection(for: draft.id).key == SecretValue(providerKey),
                    "An unrelated provider credential changed")
            }
            other.account.refresh()
            XCTAssertTrue(waitUntil { !other.account.state.isBusy })
            XCTAssertNil(other.account.state.error)
            XCTAssertTrue(other.account.state.enabled)
            try assertDevice(other.secrets, account: otherSecret, token: tokens[1], server: server, user: user)
            log.write(.debug, "Device secret scan checkpoint: \(step).")
            XCTAssertTrue(try allScans.matches(in: roots).isEmpty, "Unexpected secret copy after \(step)")
        }

        // Staging/dismissal is local; acceptance consumes the invite and password.
        XCTAssertTrue(waitUntil { !primary.account.state.isBusy })
        var input = "monkeyspaw://join?server=https%3A%2F%2Fexample.test%2Fpaw&token=" + tokens[5]
        primary.invites.stage(&input)
        XCTAssertTrue(input.isEmpty)
        XCTAssertTrue(waitUntil { !primary.invites.state.isBusy })
        XCTAssertTrue(primary.invites.state.canAccept)
        XCTAssertEqual(transport.requestCount, 0)
        try checkpoint("invite staged")
        primary.invites.dismiss()
        XCTAssertFalse(primary.invites.state.hasStagedInvite)
        var supplied = password
        primary.invites.accept(as: .newAccount, username: "person", password: &supplied, deviceName: "Mac")
        XCTAssertTrue(supplied.isEmpty)
        XCTAssertEqual(primary.invites.state.error, .noInvite)
        XCTAssertEqual(transport.requestCount, 0)
        try checkpoint("invite dismissed")

        // Reserved-folder preflight fails AFTER the real driver saves the token.
        let groups = library.appendingPathComponent("Groups")
        try FileManager.default.createDirectory(at: groups, withIntermediateDirectories: false)
        input = tokens[5]
        primary.invites.stage(&input, server: server)
        XCTAssertTrue(input.isEmpty)
        XCTAssertTrue(waitUntil { !primary.invites.state.isBusy })
        XCTAssertTrue(primary.invites.state.canAccept)
        audit.failDeletion = true
        supplied = password
        primary.invites.accept(as: .newAccount, username: "person", password: &supplied, deviceName: "Mac")
        XCTAssertTrue(supplied.isEmpty)
        XCTAssertTrue(waitUntil { !primary.invites.state.isBusy })
        XCTAssertEqual(primary.invites.state.error, .registrationIncomplete(.reservedFolders))
        XCTAssertFalse(primary.invites.state.hasStagedInvite)
        XCTAssertEqual(primary.invites.state.cleanup.remoteRevocation, .revoked)
        XCTAssertEqual(primary.invites.state.cleanup.failedSecretDeletions, 1)
        XCTAssertEqual(primary.invites.state.cleanup.secretIssue, .deleteFailed)
        XCTAssertFalse(primary.invites.state.cleanup.isComplete)
        primary.account.refresh()
        XCTAssertTrue(waitUntil { !primary.account.state.isBusy })
        XCTAssertFalse(primary.account.state.enabled)
        let failedSecret = try XCTUnwrap(audit.writtenAccounts.last)
        try assertDevice(primary.secrets, account: failedSecret, token: tokens[0], server: server, user: user)
        try checkpoint("failed activation and cleanup")
        retire(primary)
        primary = try syncGraph(library: library, data: data, itemService: itemService, audit: audit, transport: transport)
        XCTAssertTrue(waitUntil { !primary.account.state.isBusy })
        let inactiveRequests = transport.requestCount
        primary.account.startup()
        XCTAssertTrue(waitUntil { !primary.account.state.isBusy })
        XCTAssertFalse(primary.account.state.enabled)
        XCTAssertEqual(primary.account.state.cleanup.failedSecretDeletions, 1)
        XCTAssertEqual(transport.requestCount, inactiveRequests, "Failed activation must stay inactive after reconstruction")
        try assertDevice(primary.secrets, account: failedSecret, token: tokens[0], server: server, user: user)
        try checkpoint("reconstruction with pending cleanup")
        audit.failDeletion = false
        primary.account.signOut()
        XCTAssertTrue(waitUntil { !primary.account.state.isBusy })
        XCTAssertTrue(primary.account.state.cleanup.isComplete)
        try assertDeleted(primary.secrets, account: failedSecret)
        try checkpoint("cleanup retry")
        try FileManager.default.removeItem(at: groups)

        try login(primary, server: server, password: password)
        let firstSecret = try XCTUnwrap(audit.writtenAccounts.last)
        try assertDevice(primary.secrets, account: firstSecret, token: tokens[2], server: server, user: user)
        try checkpoint("login")
        retire(primary)
        primary = try syncGraph(library: library, data: data, itemService: itemService, audit: audit, transport: transport)
        XCTAssertTrue(waitUntil { !primary.account.state.isBusy })
        primary.account.startup()
        XCTAssertTrue(waitUntil { !primary.account.state.isBusy })
        XCTAssertNil(primary.account.state.error)
        XCTAssertTrue(primary.account.state.enabled)
        XCTAssertEqual(primary.account.state.secretTier, .keychain)
        XCTAssertTrue(waitUntil { primary.sync.report.lastSuccess != nil })
        XCTAssertEqual(transport.authenticationCount, 2, "Reconstruction must reuse the saved credential")
        try checkpoint("service and driver reconstruction")

        try login(primary, server: server, username: "other", password: password)
        let switchedSecret = try XCTUnwrap(audit.writtenAccounts.last)
        XCTAssertEqual(primary.account.state.connection?.userID, otherUser)
        try assertDeleted(primary.secrets, account: firstSecret)
        try assertDevice(primary.secrets, account: switchedSecret, token: tokens[3], server: server, user: otherUser)
        try checkpoint("user switch")
        try login(primary, server: otherServer, username: "other", password: password)
        let finalSecret = try XCTUnwrap(audit.writtenAccounts.last)
        XCTAssertTrue(primary.account.state.connection?.serverURL.absoluteString == otherServer)
        try assertDeleted(primary.secrets, account: switchedSecret)
        try assertDevice(primary.secrets, account: finalSecret, token: tokens[4], server: otherServer, user: otherUser)
        try checkpoint("server switch")
        primary.account.signOut()
        XCTAssertTrue(waitUntil { !primary.account.state.isBusy })
        XCTAssertNil(primary.account.state.connection)
        XCTAssertFalse(primary.account.state.enabled)
        XCTAssertTrue(primary.account.state.cleanup.isComplete)
        XCTAssertEqual(primary.account.state.cleanup.remoteRevocation, .revoked)
        try assertDeleted(primary.secrets, account: finalSecret)
        try checkpoint("sign-out")
        retire(primary)
        primary = try syncGraph(library: library, data: data, itemService: itemService, audit: audit, transport: transport)
        XCTAssertTrue(waitUntil { !primary.account.state.isBusy })
        let requests = transport.requestCount
        primary.account.startup()
        XCTAssertTrue(waitUntil { !primary.account.state.isBusy })
        XCTAssertNil(primary.account.state.connection)
        XCTAssertFalse(primary.account.state.enabled)
        XCTAssertEqual(transport.requestCount, requests, "Sign-out must prevent automatic authenticated startup")
        for account in [failedSecret, firstSecret, switchedSecret, finalSecret] {
            try assertDeleted(primary.secrets, account: account)
        }
        retire(other)
        other = try syncGraph(library: root.appendingPathComponent("other-library"),
            data: root.appendingPathComponent("other-data"), itemService: itemService, audit: audit, transport: otherTransport)
        XCTAssertTrue(waitUntil { !other.account.state.isBusy })
        other.account.startup()
        XCTAssertTrue(waitUntil { !other.account.state.isBusy })
        XCTAssertTrue(other.account.state.enabled)
        XCTAssertEqual(otherTransport.authenticationCount, 1)
        var savedDraft = draft
        savedDraft.key = .keep
        try testConnection(provider, draft: savedDraft, expected: .ok(models: []))
        try checkpoint("reconstruction after sign-out")
        XCTAssertTrue(audit.allWorkOffMain, "Keychain access must stay on workers")
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-scan-calibration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent(".hidden/nested")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let sentinel = "scan-\(UUID().uuidString)-\"\\/%+"
        let scan = try SecretScan(sentinel)
        let encodings = try scanEncodings(sentinel)
        var expected = Set<URL>()
        for (index, bytes) in encodings.enumerated() {
            let file = hidden.appendingPathComponent("copy-\(index)")
            try bytes.write(to: file)
            expected.insert(file.standardizedFileURL)
        }
        XCTAssertEqual(try scan.matches(in: [root, hidden]), expected)
        XCTAssertEqual(scan.copyCount(in: encodings[0] + encodings[4]), 2)
        for file in expected { try FileManager.default.removeItem(at: file) }
        XCTAssertTrue(try scan.matches(in: [root]).isEmpty)
    }

    func testCombinedScannerFindsEveryEncodingAndRejectsHiddenLeaks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-combined-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
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
        XCTAssertThrowsError(try combined.matches(in: [unreadable]))
    }

    private func scanEncodings(_ sentinel: String) throws -> [Data] {
        let credential = try JSONSerialization.data(withJSONObject: ["key": sentinel])
        let nested = try JSONSerialization.data(withJSONObject: ["secret": String(decoding: credential, as: UTF8.self)])
        return [Data(sentinel.utf8), Data(Data(sentinel.utf8).base64EncodedString().utf8),
            Data(sentinel.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!.utf8),
            credential, nested, Data(repeating: 0, count: 65_532) + Data(sentinel.utf8) + Data([255, 0])]
    }

    private struct Graph {
        let secrets: NoninteractiveKeychain
        let settings: ProviderSettingsService
        let assistant: AssistantService
        let work: DispatchBackgroundWork
    }

    private struct SyncScanGraph {
        let secrets: NoninteractiveKeychain
        let sync: SyncService
        let account: AccountModel
        let invites: InviteModel
        let scheduler: DispatchSyncScheduler
    }

    private func syncGraph(library root: URL, data: URL, itemService: String, audit: KeychainScanAudit,
                           transport: KeychainDeviceScanTransport) throws -> SyncScanGraph {
        let files = try RootedFileStore(root: root)
        let dataFiles = try RootedFileStore(root: data)
        try files.createRoot()
        try dataFiles.createRoot()
        try files.pinRoot()
        let library = LibraryService(library: files, data: dataFiles, clock: SystemClock(), entropy: SystemEntropy())
        let states = SyncStateStore(files: dataFiles, operations: dataFiles)
        let accounts = SyncAccountStore(files: dataFiles, operations: dataFiles)
        let scheduler = DispatchSyncScheduler()
        let main = DispatchMainThread()
        let sync = try SyncService(library: library, libraryOperations: files, dataFiles: dataFiles,
            dataOperations: dataFiles, states: states, accounts: accounts, scheduler: scheduler,
            mainThread: main, clock: SystemClock(), entropy: SystemEntropy())
        let secrets = NoninteractiveKeychain(store: KeychainSecretStore(service: itemService), audit: audit)
        let service = try SyncAccountService(sync: sync, accounts: accounts, secrets: secrets,
            transport: transport, libraryRoot: root.path)
        return SyncScanGraph(secrets: secrets, sync: sync, account: AccountModel(account: service, mainThread: main),
            invites: InviteModel(service: SyncInviteService(account: service, clipboard: KeychainScanClipboard()), mainThread: main),
            scheduler: scheduler)
    }

    private func login(_ graph: SyncScanGraph, server: String, username: String = "person", password: String) throws {
        XCTAssertTrue(waitUntil { !graph.account.state.isBusy })
        var supplied = password
        graph.account.login(server: server, username: username, password: &supplied, deviceName: "Mac")
        XCTAssertTrue(supplied.isEmpty, "Submission must consume the password synchronously")
        XCTAssertTrue(waitUntil { !graph.account.state.isBusy })
        XCTAssertNil(graph.account.state.error)
        XCTAssertTrue(graph.account.state.enabled)
        XCTAssertEqual(graph.account.state.secretTier, .keychain)
        XCTAssertTrue(waitUntil { graph.sync.report.lastSuccess != nil && graph.sync.report.phase == .idle })
    }

    private func assertDevice(_ secrets: NoninteractiveKeychain, account: SecretAccount,
                              token: String, server: String, user: ULID) throws {
        try worker {
            XCTAssertEqual(account.namespace, "device")
            for source in [SecretReadSource.effective, .persisted] {
                let stored = try secrets.read(account: account, source: source)
                XCTAssertEqual(stored?.tier, .keychain)
                let valid = stored?.value.withValue { value -> Bool in
                    guard let envelope = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { return false }
                    return envelope["version"] as? Int == 1 && envelope["token"] as? String == token
                        && envelope["server_url"] as? String == server && envelope["user_id"] as? String == user.rawValue
                        && envelope["connection_id"] as? String == account.name
                }
                XCTAssertTrue(valid == true, "The protected device credential lost its binding")
            }
        }
    }

    private func assertDeleted(_ secrets: NoninteractiveKeychain, account: SecretAccount) throws {
        try worker {
            XCTAssertTrue(try secrets.read(account: account, source: .effective) == nil)
            XCTAssertTrue(try secrets.read(account: account, source: .persisted) == nil)
        }
    }

    private func retire(_ graph: SyncScanGraph) {
        graph.account.retire()
        graph.invites.retire()
        graph.sync.stop()
        let done = expectation(description: "Device scan graph drained")
        Task.detached {
            await graph.account.drain()
            await graph.invites.drain()
            graph.sync.stop()
            await graph.sync.drain()
            XCTAssertEqual(graph.sync.retire(), .stopped)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        graph.scheduler.tearDown()
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 5)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
        return predicate()
    }

    private func graph(config: URL, itemService: String, transport: KeychainScanTransport, log: LogSink) throws -> Graph {
        let files = try RootedFileStore(root: config)
        let secrets = NoninteractiveKeychain(store: KeychainSecretStore(service: itemService))
        let settings = ProviderSettingsService(store: ProviderSettingsStore(files: files, log: log), secrets: secrets, log: log)
        let work = DispatchBackgroundWork()
        let assistant = AssistantService(providerSettings: settings, anthropic: AnthropicClient(transport: transport),
            openAICompatible: OpenAIClient(transport: transport, providerState: ProviderStateStore(files: files)),
            work: work, main: DispatchMainThread())
        return Graph(secrets: secrets, settings: settings, assistant: assistant, work: work)
    }

    private func assertStorage(_ graph: Graph) throws {
        let model = AssistantSettingsModel(settings: graph.settings, assistant: graph.assistant,
            work: graph.work, mainThread: DispatchMainThread())
        let deadline = Date(timeIntervalSinceNow: 5)
        while (model.state.operation != nil || model.state.keyStorage != .saved(.keychain)), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        XCTAssertNil(model.state.operation)
        XCTAssertEqual(model.state.keyStorage, .saved(.keychain))
    }

    private func testConnection(_ graph: Graph, draft: ProviderDraft, expected: ConnectionTestResult) throws {
        let done = expectation(description: "Connection test finished")
        var result: ConnectionTestResult?
        let test = graph.assistant.testConnection(draft: draft) { result = $0; done.fulfill() }
        defer { test.cancel() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result, expected)
    }

    private func worker(_ body: @escaping () throws -> Void) throws {
        final class Receipt {
            private let lock = NSLock()
            private var stored: Result<Void, Error>?
            var value: Result<Void, Error>? {
                get { lock.lock(); defer { lock.unlock() }; return stored }
                set { lock.lock(); defer { lock.unlock() }; stored = newValue }
            }
        }
        let receipt = Receipt()
        let done = expectation(description: "Background secret operation")
        DispatchQueue.global().async { receipt.value = Result { try body() }; done.fulfill() }
        wait(for: [done], timeout: 10)
        try XCTUnwrap(receipt.value).get()
    }
}

/// Scope interaction suppression per call: holding its lock across an async
/// connection test would deadlock the worker trying to read the Keychain.
private struct NoninteractiveKeychain: SecretStore {
    let store: KeychainSecretStore
    private let audit: KeychainScanAudit?

    init(store: KeychainSecretStore, audit: KeychainScanAudit? = nil) {
        self.store = store
        self.audit = audit
    }

    func read(account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        try access { try store.read(account: account, source: source) }
    }
    func write(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        let tier = try access { try store.write(value, account: account) }
        audit?.recordWrite(account)
        return tier
    }
    func delete(account: SecretAccount) throws {
        try access {
            if audit?.failDeletion == true { throw SecretStoreError.deleteFailed }
            try store.delete(account: account)
        }
    }

    private func access<T>(_ work: () throws -> T) throws -> T {
        audit?.recordAccess()
        do { return try SystemKeychainAccess.withoutUserInteraction(work) }
        catch KeychainAccessError.unavailable { throw SecretStoreError.unavailable }
    }
}

private final class KeychainScanAudit {
    private let lock = NSLock()
    private var accounts: [SecretAccount] = []
    private var offMain = true
    private var deniedDeletion = false
    var writtenAccounts: [SecretAccount] { locked { accounts } }
    var allWorkOffMain: Bool { locked { offMain } }
    var failDeletion: Bool { get { locked { deniedDeletion } } set { locked { deniedDeletion = newValue } } }
    func recordWrite(_ account: SecretAccount) { locked { accounts.append(account) } }
    func recordAccess() { locked { offMain = offMain && !Thread.isMainThread } }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }
}

private struct KeychainScanClipboard: Clipboard {
    func writeText(_ text: String) { XCTFail("Device privacy scans must not copy an invite") }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) { completion(nil) }
}

private final class KeychainDeviceScanTransport: HTTPTransporting, @unchecked Sendable {
    enum Operation: String { case login, register }
    struct Session {
        let server: String
        let user: ULID
        let username: String
        let device: ULID
        let token: SecretValue
        let operation: Operation
    }
    private let sessions: [Session]
    private let password: SecretValue
    private let invite: SecretValue
    private let lock = NSLock()
    private var issued = 0
    private var requests = 0
    private var revoked = Set<Int>()
    var requestCount: Int { locked { requests } }
    var authenticationCount: Int { locked { issued } }

    init(sessions: [Session], password: SecretValue, invite: SecretValue) {
        self.sessions = sessions
        self.password = password
        self.invite = invite
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try locked {
            XCTAssertFalse(Thread.isMainThread, "Account HTTP must run on a worker")
            requests += 1
            let authorization = request.headers.first { $0.key.lowercased() == "authorization" }?.value
            let path = request.url.path
            if path.hasSuffix("/login") || path.hasSuffix("/register") {
                guard issued < sessions.count else { throw HTTPTransportError.invalidRequest }
                let session = sessions[issued]
                var valid = request.method == .post && authorization == nil
                    && request.url.absoluteString == session.server + "/api/v1/auth/" + session.operation.rawValue
                switch session.operation {
                case .login:
                    let body = try? JSONDecoder().decode(SyncAPI.LoginRequest.self, from: request.body ?? Data())
                    valid = valid && body?.username == session.username && password.withValue { body?.password == $0 }
                case .register:
                    let body = try? JSONDecoder().decode(SyncAPI.RegisterRequest.self, from: request.body ?? Data())
                    valid = valid && body?.username == session.username
                        && password.withValue { body?.password == $0 } && invite.withValue { body?.inviteToken == $0 }
                }
                XCTAssertTrue(valid, "Authentication violated the selected destination or transient-input contract")
                guard valid else { throw HTTPTransportError.invalidRequest }
                issued += 1
                return try http(session.token.withValue { SyncAPI.AuthResponse(deviceToken: $0, user: user(session)) })
            }
            guard let index = (0..<issued).first(where: { index in
                sessions[index].token.withValue { authorization == "Bearer " + $0 }
            }), request.url.absoluteString.hasPrefix(sessions[index].server + "/api/v1/") else {
                XCTFail("A device credential was missing or crossed server boundaries")
                throw HTTPTransportError.invalidRequest
            }
            guard !revoked.contains(index) else {
                XCTFail("A retired device credential was reused")
                throw HTTPTransportError.invalidRequest
            }
            let session = sessions[index]
            if path.hasSuffix("/logout") {
                revoked.insert(index)
                return try http(SyncAPI.EmptyResponse())
            }
            if path.hasSuffix("/me") {
                let device = SyncAPI.Device(id: session.device.rawValue, name: "Mac", createdAt: "2026-10-14T00:00:00.000Z",
                    lastSeenAt: nil, revokedAt: nil, isCurrent: true)
                return try http(SyncAPI.MeResponse(user: user(session), groups: [], devices: [device]))
            }
            if path.hasSuffix("/sync/pull") {
                let scope = SyncAPI.SyncScope(identity: .user(userID: session.user.rawValue), mode: .snapshot,
                    head: 0, cursor: "opaque-user", hasMore: false, items: [])
                return try http(SyncAPI.PullResponse(databaseID: "11111111-1111-4111-8111-111111111111", scopes: [scope], removed: []))
            }
            throw HTTPTransportError.invalidRequest
        }
    }

    private func user(_ session: Session) -> SyncAPI.User {
        SyncAPI.User(id: session.user.rawValue, username: session.username, displayName: nil, accountKind: .member,
            createdAt: "2026-10-14T00:00:00.000Z", disabledAt: nil)
    }

    private func http<T: Encodable>(_ value: T) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(value))
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}

private actor KeychainScanTransport: HTTPTransporting {
    private let key: SecretValue
    private var requests = 0
    init(key: SecretValue) { self.key = key }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests += 1
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.path, "/v1/models")
        XCTAssertNil(request.body)
        XCTAssertTrue(key.withValue { request.headers["x-api-key"] == $0 }, "Test used the wrong key")
        if requests == 1 { return HTTPResponse(statusCode: 200, body: Data(#"{"data":[],"has_more":false}"#.utf8)) }
        return HTTPResponse(statusCode: 401, body: key.withValue { Data($0.utf8) })
    }
}

private struct KeychainScanLog: LogSink {
    let output: FileHandle
    func write(_ level: LogLevel, _ message: String) {
        do { try output.write(contentsOf: Data((message + "\n").utf8)) }
        catch { XCTFail("Could not capture secret-scan diagnostics") }
    }
}
