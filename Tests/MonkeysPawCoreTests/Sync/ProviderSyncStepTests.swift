import Foundation
import XCTest
@testable import MonkeysPawCore

/// The transport routes GET/PUT on one in-memory document; revisions tick up
/// per write like the server contract.
private final class ProviderRemote: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var document: String?
    private var rev: Int64 = 0
    private(set) var puts = 0
    private(set) var putBodies = [String]()
    private(set) var gets = 0
    var failTransport: HTTPTransportError?

    func setDocument(_ document: String?, rev: Int64) {
        lock.lock()
        defer { lock.unlock() }
        self.document = document
        self.rev = rev
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        if let failTransport { throw failTransport }
        if request.method == .get {
            gets += 1
            let response = SyncAPI.ProviderSettingsDocument(rev: rev, document: document, updatedAt: nil)
            return HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(response))
        }
        puts += 1
        let body = try JSONDecoder().decode(SyncAPI.PutProviderSettingsRequest.self, from: request.body ?? Data())
        putBodies.append(body.document)
        rev += 1
        document = body.document
        return HTTPResponse(statusCode: 200, body: try JSONEncoder().encode(SyncAPI.ProviderSettingsResponse(rev: rev)))
    }

    var currentDocument: String? {
        lock.lock()
        defer { lock.unlock() }
        return document
    }
    var currentRev: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return rev
    }
}

private final class CountedEntropy: EntropySource {
    var next: [UInt8] = Array(11..<43).map { UInt8($0) }
    func bytes(count: Int) throws -> [UInt8] { Array(next.prefix(count)) + [UInt8](repeating: 0, count: max(0, count - next.count)) }
}

private final class ProviderStepRig {
    let files: ProviderRecordingFiles
    let data: MemoryFileStore
    let secrets: FakeProviderSecrets
    let log = ProviderCapturedLog()
    let remote: ProviderRemote
    let entropy = CountedEntropy()
    let identity: SyncAccountIdentity
    let permit: SyncWorkPermit
    let client: SyncHTTPClient
    let providers: ProviderSettingsService
    let keys: ProviderSyncKeyService
    let step: ProviderSyncStep

    init(userID: ULID = SyncTestValues.user, server: String = "https://example.test/paw",
         files: ProviderRecordingFiles = ProviderRecordingFiles(), data: MemoryFileStore = MemoryFileStore(),
         secrets: FakeProviderSecrets = FakeProviderSecrets(), remote: ProviderRemote = ProviderRemote()) throws {
        self.files = files
        self.data = data
        self.secrets = secrets
        self.remote = remote
        identity = try SyncAccountIdentity(serverURL: server, userID: userID)
        let binding = try SyncLibraryIdentity(account: identity, root: SyncLibraryRoot("/library"))
        permit = SyncWorkPermit(binding: binding, epoch: 1)
        let endpoint = try SyncServerURL(server)
        client = SyncHTTPClient(server: endpoint, transport: remote,
            credential: SyncCredential(server: endpoint,
                token: SecretValue(String(repeating: "a", count: 42) + "A")))
        providers = ProviderSettingsService(store: ProviderSettingsStore(files: files, log: log), secrets: secrets, log: log)
        keys = ProviderSyncKeyService(secrets: secrets, entropy: entropy)
        step = ProviderSyncStep(files: data, operations: MemorySyncFileOperations(files: data),
            providers: providers, keys: keys, entropy: entropy)
    }

    func run() async throws -> ProviderSyncOutcome {
        try await step.run(client: client, identity: identity, permit: permit)
    }

    /// A sealed remote document in the wire form, as another device would write it.
    func remoteDocument(settings: [String: Any], secrets: [String: String], key: Data, rev: Int64) throws -> String {
        let plaintext = try ProviderSyncPayload(settings: settings, secrets: secrets).encode()
        let document = try ProviderSyncCipher.seal(key: key, userID: identity.userID, plaintext: plaintext) {
            Data((0..<12).map { UInt8(200 + $0) })
        }
        remote.setDocument(document, rev: rev)
        return document
    }

    func keyData() -> Data { Data(Array(0..<32).map { UInt8(50 + $0) }) }

    @discardableResult
    func provisionKey() throws -> Data {
        let key = keyData()
        _ = try keys.enterKey(userID: identity.userID, text: Base64URL.encode([UInt8](key)))
        return key
    }

    func settingsObject(profileID: UUID, name: String = "Remote") -> [String: Any] {
        ["version": 1,
         "profiles": [["id": profileID.uuidString.lowercased(), "displayName": name,
                       "kind": "anthropic", "baseURL": "https://api.anthropic.com",
                       "modelID": "m", "secretReference": "provider:\(profileID.uuidString.lowercased())"]],
         "selectedProfileID": NSNull()]
    }

    func record() throws -> ProviderSyncRecord? {
        try SyncPersistence<ProviderSyncRecord>(files: data,
            operations: MemorySyncFileOperations(files: data),
            path: "sync/provider-settings.json", version: Limits.providerSyncRecordVersion).load()
    }
}

final class ProviderSyncStepTests: XCTestCase {
    func testMissingKeyReportsKeyRequiredWithoutNetworkOrFileWrites() async throws {
        let rig = try ProviderStepRig()
        let before = rig.files.attemptedWrites.count
        await expect(.keyRequired, from: rig)
        XCTAssertEqual(rig.remote.puts, 0)
        XCTAssertEqual(rig.remote.gets, 0)
        XCTAssertEqual(rig.files.attemptedWrites.count, before)
        XCTAssertNil(try rig.record())
    }

    func testEmptyRemoteUploadsTheExportedDocument() async throws {
        let rig = try ProviderStepRig()
        let key = try rig.provisionKey()
        let profileID = UUID()
        try rig.providers.save(ProviderDraft(id: ProviderProfileID(profileID), displayName: "Claude",
            baseURL: "https://api.anthropic.com", modelID: "m", key: .replace(SecretValue("sk-test"))))
        await expect(.synced, from: rig)
        XCTAssertEqual(rig.remote.puts, 1)
        let record = try XCTUnwrap(rig.record())
        XCTAssertEqual(record.rev, 1)
        XCTAssertEqual(record.serverURL, rig.identity.serverURL.absoluteString)
        XCTAssertEqual(record.userID, rig.identity.userID.rawValue)

        // The stored document decrypts to the exported payload under the key.
        let plaintext = try ProviderSyncCipher.open(rig.remote.putBodies[0], key: key, userID: rig.identity.userID)
        let payload = try ProviderSyncPayload(plaintext: plaintext)
        XCTAssertEqual((payload.settings["profiles"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(payload.secrets.count, 1)
        XCTAssertEqual(record.payloadHash, SHA256.hexDigest(plaintext))

        // Second pass over the same server state is unchanged.
        await expect(.unchanged, from: rig)
        XCTAssertEqual(rig.remote.puts, 1)
    }

    func testRemoteDocumentAppliesSettingsAndSecretsVerbatim() async throws {
        let rig = try ProviderStepRig()
        let key = try rig.provisionKey()
        let profileID = UUID()
        var settings = rig.settingsObject(profileID: profileID)
        settings["futureRoot"] = ["keep": 1]
        let account = "provider:\(profileID.uuidString.lowercased())"
        _ = try rig.remoteDocument(settings: settings, secrets: [account: "{\"version\":1,\"origin\":\"o\"}"], key: key, rev: 7)

        await expect(.unchanged, from: rig)
        XCTAssertEqual(rig.remote.puts, 0)
        let stored = try rig.files.memory.text(at: "provider-settings.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
        XCTAssertEqual(object as NSDictionary, settings as NSDictionary)
        var storedSecret: String?
        rig.secrets.persisted[try XCTUnwrap(SecretAccount(coding: account))]?.value.withValue { storedSecret = $0 }
        XCTAssertEqual(storedSecret, "{\"version\":1,\"origin\":\"o\"}")
        XCTAssertEqual(try rig.record()?.rev, 7)
    }

    func testLocalEditAfterRemoteApplyUploadsLastWriterWins() async throws {
        let rig = try ProviderStepRig()
        let key = try rig.provisionKey()
        _ = try rig.remoteDocument(settings: rig.settingsObject(profileID: UUID()), secrets: [:], key: key, rev: 3)
        await expect(.unchanged, from: rig)

        try rig.providers.save(ProviderDraft(displayName: "Local add", baseURL: "https://api.anthropic.com"))
        await expect(.synced, from: rig)
        XCTAssertEqual(rig.remote.puts, 1)
        XCTAssertEqual(try rig.record()?.rev, 4)
        let plaintext = try ProviderSyncCipher.open(rig.remote.putBodies[0], key: key, userID: rig.identity.userID)
        XCTAssertEqual(try (try ProviderSyncPayload(plaintext: plaintext).settings["profiles"] as? [[String: Any]])?.count, 2)
    }

    func testDecryptFailureLeavesLocalUntouchedAndDoesNotUpload() async throws {
        let rig = try ProviderStepRig()
        _ = try rig.provisionKey()
        try rig.providers.save(ProviderDraft(displayName: "Mine", baseURL: "https://api.anthropic.com"))
        let before = rig.files.attemptedWrites.count
        let wrongKey = Data([UInt8](repeating: 9, count: 32))
        _ = try rig.remoteDocument(settings: rig.settingsObject(profileID: UUID()), secrets: [:], key: wrongKey, rev: 2)

        await expect(.decryptFailed, from: rig)
        XCTAssertEqual(rig.remote.puts, 0)
        XCTAssertEqual(rig.files.attemptedWrites.count, before)
        XCTAssertNil(try rig.record())
        XCTAssertEqual(rig.providers.snapshot.settings.profiles.count, 1)
    }

    func testMalformedRemoteDocumentFailsClosed() async throws {
        let rig = try ProviderStepRig()
        _ = try rig.provisionKey()
        // A document failing the wire schema is a malformed HTTP response.
        rig.remote.setDocument("not a document", rev: 1)
        await expectThrow(rig)
        // A well-formed envelope that does not open fails non-destructively.
        rig.remote.setDocument(Base64URL.encode([0x09] + [UInt8](repeating: 0, count: 40)), rev: 1)
        await expect(.decryptFailed, from: rig)
        rig.remote.setDocument(Base64URL.encode([0x01] + [UInt8](repeating: 9, count: 40)), rev: 1)
        await expect(.decryptFailed, from: rig)
        XCTAssertEqual(rig.remote.puts, 0)
    }

    func testEnvironmentSecretsSurviveRemoteApplyAndNeverExport() async throws {
        let rig = try ProviderStepRig()
        let key = try rig.provisionKey()
        let profileID = UUID()
        let account = try SecretAccount(namespace: "provider", name: profileID.uuidString.lowercased())
        rig.secrets.environment[account] = SecretValue("env-key")
        _ = try rig.remoteDocument(settings: rig.settingsObject(profileID: profileID),
            secrets: ["provider:\(profileID.uuidString.lowercased())": "remote-envelope"], key: key, rev: 5)
        await expect(.unchanged, from: rig)
        XCTAssertNil(rig.secrets.persisted[account])
        // The carried remote envelope still uploads so another device gets it.
        try rig.providers.save(ProviderDraft(displayName: "Second", baseURL: "https://api.anthropic.com"))
        await expect(.synced, from: rig)
        let plaintext = try ProviderSyncCipher.open(rig.remote.putBodies[0], key: key, userID: rig.identity.userID)
        XCTAssertEqual(try ProviderSyncPayload(plaintext: plaintext).secrets["provider:\(profileID.uuidString.lowercased())"], "remote-envelope")
        XCTAssertNil(rig.secrets.persisted[account])
    }

    func testMissingPersistedSecretCarriesTheRemoteEnvelopeForward() async throws {
        let rig = try ProviderStepRig()
        let key = try rig.provisionKey()
        let profileID = UUID()
        let account = "provider:\(profileID.uuidString.lowercased())"
        _ = try rig.remoteDocument(settings: rig.settingsObject(profileID: profileID),
            secrets: [account: "carried"], key: key, rev: 2)
        await expect(.unchanged, from: rig)

        // The stored secret is lost out-of-band; a metadata-only edit still
        // uploads the carried envelope rather than dropping the key.
        rig.secrets.persisted[try SecretAccount(coding: account)] = nil
        try rig.providers.save(ProviderDraft(displayName: "Local", baseURL: "https://api.anthropic.com"))
        await expect(.synced, from: rig)
        let plaintext = try ProviderSyncCipher.open(rig.remote.putBodies[0], key: key, userID: rig.identity.userID)
        XCTAssertEqual(try ProviderSyncPayload(plaintext: plaintext).secrets[account], "carried")
    }

    func testRecordSurvivesANewStepInstanceAndAccountMismatchesReset() async throws {
        let rig = try ProviderStepRig()
        _ = try rig.provisionKey()
        try rig.providers.save(ProviderDraft(displayName: "A", baseURL: "https://api.anthropic.com"))
        await expect(.synced, from: rig)

        // A fresh step and provider service over the same directories sees the
        // durable record and reports unchanged without another write.
        let restarted = try ProviderStepRig(files: rig.files, data: rig.data,
            secrets: rig.secrets, remote: rig.remote)
        await expect(.unchanged, from: restarted)
        XCTAssertEqual(restarted.remote.puts, 1)

        // A different account resets the baseline; its key cannot open a
        // document sealed for the first account, so nothing is applied.
        _ = try restarted.keys.enterKey(userID: SyncTestValues.otherUser,
            text: Base64URL.encode([UInt8](repeating: 3, count: 32)))
        let shared = try ProviderStepRig(userID: SyncTestValues.otherUser, files: rig.files,
            data: rig.data, secrets: rig.secrets, remote: rig.remote)
        await expect(.decryptFailed, from: shared)
        XCTAssertEqual(rig.remote.puts, 1)
    }

    func testReadOnlyProviderStoreReportsApplyFailed() async throws {
        let rig = try ProviderStepRig()
        let key = try rig.provisionKey()
        // Corrupt settings file makes the store fail closed.
        try rig.files.memory.writePrivate(Data("not json".utf8), at: "provider-settings.json")
        _ = try rig.remoteDocument(settings: rig.settingsObject(profileID: UUID()), secrets: [:], key: key, rev: 1)
        await expect(.applyFailed, from: rig)
        XCTAssertEqual(rig.remote.puts, 0)
    }

    func testRevokedPermitAndTransportErrorsPropagate() async throws {
        let rig = try ProviderStepRig()
        _ = try rig.provisionKey()
        rig.remote.failTransport = .networkFailure
        await expectThrow(rig)
        rig.remote.failTransport = nil
        rig.permit.revoke()
        await expectThrow(rig)
        XCTAssertEqual(rig.remote.puts, 0)
    }
}

private func expect(_ expected: ProviderSyncOutcome, from rig: ProviderStepRig,
                    file: StaticString = #filePath, line: UInt = #line) async {
    do {
        let outcome = try await rig.run()
        XCTAssertEqual(outcome, expected, file: file, line: line)
    } catch { XCTFail("unexpected error \(error)", file: file, line: line) }
}

private func expectThrow(_ rig: ProviderStepRig, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await rig.run(); XCTFail("expected throw", file: file, line: line) }
    catch {}
}
