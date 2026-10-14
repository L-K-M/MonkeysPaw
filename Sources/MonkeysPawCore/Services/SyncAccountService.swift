import Foundation

enum SyncAccountIntent { case login, startup }

enum SyncAccountIssue: Equatable, Sendable {
    case busy, signedOut, credentialsRequired, invalidInput, tokenBindingMismatch, invalidAccount, recoveryRequired
    case reservedFolders([RelativePath])
    case secret(SecretStoreError)
    case metadata(SyncError)
    case http(SyncHTTPClientError)
}

enum SyncRemoteRevocation: Equatable, Sendable { case notNeeded, revoked, unconfirmed }

/// Partial logout/compensation is explicit, and cleanup UUIDs contain no token.
struct SyncAccountCleanup: Equatable, Sendable {
    var remote: SyncRemoteRevocation = .notNeeded
    var secretFailures: [UUID] = []
    var secretIssue: SecretStoreError?
    var metadataIssue: SyncError?
    var recoveryRequired = false

    var isComplete: Bool {
        remote != .unconfirmed && secretFailures.isEmpty && metadataIssue == nil && !recoveryRequired
    }
}

struct SyncAccountServiceError: Error, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let issue: SyncAccountIssue
    var cleanup = SyncAccountCleanup()
    var description: String { "<sync account error redacted>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["error": description]) }
}

/// Presentation sees only metadata, tier and fixed failures, never credentials.
struct SyncAccountSnapshot: Equatable, Sendable {
    var account: SyncAccount?
    var me: SyncAPI.MeResponse?
    var tier: SecretTier?
    var enabled = false
    var cleanup = SyncAccountCleanup()
}

/// Call async intents off UI. One admitted account operation owns all compound
/// secret/metadata edits; native composition must use this graph's account store.
public final class SyncAccountService: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private struct Session {
        let account: SyncAccount
        let client: SyncHTTPClient
        let tier: SecretTier
    }

    private struct DeviceSecret: Codable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let version: Int
        let server_url: String
        let user_id: String
        let connection_id: String
        let token: String
        var description: String { "<device secret redacted>" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["secret": description]) }
    }

    private let sync: SyncService
    private let accounts: SyncAccountStore
    private let secrets: SecretStore
    private let transport: HTTPTransporting
    private let root: SyncLibraryRoot
    private let connectionID: () -> UUID
    private let lock = NSLock()
    private var busy = false
    private var active: Session?
    private var cached = SyncAccountSnapshot()

    public init(sync: SyncService, accounts: SyncAccountStore, secrets: SecretStore,
                transport: HTTPTransporting, libraryRoot: String) throws {
        self.sync = sync
        self.accounts = accounts
        self.secrets = secrets
        self.transport = transport
        root = try SyncLibraryRoot(libraryRoot)
        connectionID = UUID.init
    }

    init(sync: SyncService, accounts: SyncAccountStore, secrets: SecretStore,
         transport: HTTPTransporting, root: SyncLibraryRoot, connectionID: @escaping () -> UUID) {
        self.sync = sync
        self.accounts = accounts
        self.secrets = secrets
        self.transport = transport
        self.root = root
        self.connectionID = connectionID
    }

    var snapshot: SyncAccountSnapshot { locked { cached } }
    var isBusy: Bool { locked { busy } }
    public var description: String { "<sync account service redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["service": description]) }

    /// Consume the caller's password on every path, including validation/busy
    /// failures. The sole plain request DTO is transient inside authentication.
    @discardableResult
    func login(server input: String, username: String, password: inout String, deviceName: String) async throws -> SyncAccountSnapshot {
        let supplied = SecretValue(password)
        password = ""
        try enter()
        defer { leave() }
        let previous: SyncConnectionDocument
        let server: SyncServerURL
        do {
            previous = try accounts.recoverConnection()
            server = try SyncServerURL(input)
        } catch { throw failure(error) }

        let authentication: SyncAuthentication
        do {
            authentication = try await SyncHTTPClient(server: server, transport: transport).login(
                supplied.withValue { SyncAPI.LoginRequest(username: username, password: $0, deviceName: deviceName) })
        } catch { throw failure(error) }
        let client = SyncHTTPClient(server: server, transport: transport, credential: authentication.credential)
        var candidate: SyncAccount?
        var staged = false
        var secretAttempted = false
        do {
            let me = try await client.me()
            let current = try Self.validate(me, userID: SyncIdentifiers.ulid(authentication.user.id))
            let id = connectionID()
            guard id != previous.account?.connectionID, !previous.cleanupConnections.contains(id) else {
                throw SyncAccountServiceError(issue: .invalidInput)
            }
            let account = try SyncAccount(identity: SyncAccountIdentity(serverURL: server.baseURL.absoluteString,
                userID: SyncIdentifiers.ulid(me.user.id)), username: me.user.username,
                deviceID: SyncIdentifiers.ulid(current.id), deviceName: current.name, connectionID: id)
            candidate = account
            // A UUID must never overwrite an orphan or an operator override.
            guard try readSecret(account.secretAccount, source: .effective) == nil,
                  try readSecret(account.secretAccount, source: .persisted) == nil else {
                throw SyncAccountServiceError(issue: .secret(.readOnly))
            }
            sync.stop()
            await sync.drain()
            staged = true
            try accounts.disableAutomaticResume()
            secretAttempted = true
            let tier = try writeSecret(bind(authentication.credential, to: account), account: account.secretAccount)
            try accounts.setAccount(account, activation: .inactive)
            let binding = SyncLibraryIdentity(account: account.identity, root: root)
            try await sync.prepareAccount(binding: binding, client: client, device: account.deviceName, intent: .login)
            try Task.checkCancellation()
            try accounts.setAccount(account, activation: .enabled)
            try sync.start(binding: binding, client: client, device: account.deviceName)
            let session = Session(account: account, client: client, tier: tier)
            let old = locked { active }
            locked { active = session; cached = SyncAccountSnapshot(account: account, me: me, tier: tier, enabled: true) }
            var cleanup = SyncAccountCleanup()
            if let previous = previous.account {
                do { try accounts.retireSecret(previous.connectionID) }
                catch { cleanup.metadataIssue = metadataError(error) }
                if let old, old.account == previous { cleanup.remote = await revoke(old.client) }
                else { cleanup.remote = .unconfirmed }
            }
            deleteSecrets(previous.cleanupConnections + [previous.account?.connectionID].compactMap { $0 }, cleanup: &cleanup)
            locked { cached.cleanup = cleanup }
            return snapshot
        } catch {
            var result = failure(error)
            if staged {
                sync.stop()
                await sync.drain()
                locked { active = nil; cached = SyncAccountSnapshot(account: previous.account) }
                do { try accounts.saveInactive(previous.account, retiring: secretAttempted ? [candidate?.connectionID].compactMap { $0 } : []) }
                catch { result.cleanup.metadataIssue = metadataError(error) }
            }
            result.cleanup.remote = await revoke(client)
            if secretAttempted, let candidate {
                deleteSecrets([candidate.connectionID], cleanup: &result.cleanup)
            }
            locked { cached.cleanup = result.cleanup }
            throw result
        }
    }

    /// No connection, or an inactive one, means no secret lookup or HTTP. Raw
    /// environment overrides still have to prove the stored user AND device via
    /// /me; they cannot authorize a server/user transition during startup.
    @discardableResult
    func startup() async throws -> SyncAccountSnapshot {
        try enter()
        defer { leave() }
        sync.stop()
        await sync.drain()
        do {
            let connection = try accounts.loadConnection()
            locked {
                cached = SyncAccountSnapshot(account: connection.account,
                    cleanup: SyncAccountCleanup(secretFailures: connection.cleanupConnections))
            }
            guard let account = connection.account, connection.activation == .enabled else {
                locked {
                    active = nil
                    cached = SyncAccountSnapshot(account: connection.account,
                        cleanup: SyncAccountCleanup(secretFailures: connection.cleanupConnections))
                }
                return snapshot
            }
            guard let resolved = try resolve(account) else { throw SyncAccountServiceError(issue: .credentialsRequired) }
            let me = try await resolved.client.me()
            let current = try Self.validate(me, userID: account.identity.userID)
            guard current.id == account.deviceID.rawValue else { throw SyncAccountServiceError(issue: .tokenBindingMismatch) }
            let binding = SyncLibraryIdentity(account: account.identity, root: root)
            try await sync.prepareAccount(binding: binding, client: resolved.client, device: account.deviceName, intent: .startup)
            try Task.checkCancellation()
            try sync.start(binding: binding, client: resolved.client, device: account.deviceName)
            locked {
                active = resolved
                cached = SyncAccountSnapshot(account: account, me: me, tier: resolved.tier, enabled: true,
                    cleanup: SyncAccountCleanup(secretFailures: connection.cleanupConnections))
            }
            return snapshot
        } catch {
            sync.stop()
            await sync.drain()
            locked { active = nil; cached.enabled = false }
            let result = failure(error)
            if Self.requiresSignIn(result.issue) { sync.requireSignIn() }
            throw result
        }
    }

    @discardableResult
    func refresh() async throws -> SyncAccountSnapshot {
        try enter()
        defer { leave() }
        do {
            let session = try session()
            let me = try await session.client.me()
            let current = try Self.validate(me, userID: session.account.identity.userID)
            guard current.id == session.account.deviceID.rawValue else { throw SyncAccountServiceError(issue: .tokenBindingMismatch) }
            locked { cached.me = me }
            return snapshot
        } catch {
            let result = failure(error)
            if Self.requiresSignIn(result.issue) {
                sync.requireSignIn()
                await sync.drain()
                locked { active = nil; cached.enabled = false; cached.me = nil }
            }
            throw result
        }
    }

    func devices() async throws -> [SyncAPI.Device] { try await refresh().me?.devices ?? [] }

    func heldPrompts() throws -> [SyncHeldPrompt] {
        do { return try accounts.binding(for: root)?.holds ?? [] }
        catch { throw failure(error) }
    }

    /// The selected identities are explicit upload consent. Editing, startup or
    /// reauthentication alone never removes an old account's durable holds.
    @discardableResult
    func includeHeld(_ identities: Set<PromptIdentity>) async throws -> SyncAccountSnapshot {
        try enter()
        defer { leave() }
        let session = try session()
        let binding = SyncLibraryIdentity(account: session.account.identity, root: root)
        do {
            sync.stop()
            await sync.drain()
            try accounts.disableAutomaticResume()
            try await sync.prepareAccount(binding: binding, client: session.client, device: session.account.deviceName, intent: .login)
            try accounts.updateBinding(for: root) { current in
                guard var current, current.owner == binding.account,
                      identities.isSubset(of: Set(current.holds.map(\.identity))) else { throw SyncError.bindingMismatch }
                current.holds.removeAll { identities.contains($0.identity) }
                return current
            }
            try Task.checkCancellation()
            try accounts.setAccount(session.account, activation: .enabled)
            try sync.start(binding: binding, client: session.client, device: session.account.deviceName)
            locked { cached.enabled = true }
            return snapshot
        } catch {
            sync.stop()
            await sync.drain()
            locked { cached.enabled = false }
            throw failure(error)
        }
    }

    /// An own non-current device keeps this connection. Current-device revoke
    /// always performs local sign-out, including after an uncertain HTTP result.
    @discardableResult
    func revokeDevice(_ id: ULID) async throws -> SyncAccountSnapshot {
        try enter()
        defer { leave() }
        let session = try session()
        if id == session.account.deviceID {
            let cleanup = await signOut(session: session, device: id)
            locked { cached.cleanup = cleanup }
            return snapshot
        }
        do { try await session.client.revokeDevice(id: id) }
        catch { throw failure(error) }
        locked { cached.me = nil }
        return snapshot
    }

    @discardableResult
    func signOut() async throws -> SyncAccountCleanup {
        try enter()
        defer { leave() }
        let session = locked { active }
        let cleanup = await signOut(session: session, device: nil)
        locked { cached.cleanup = cleanup }
        return cleanup
    }

    private func signOut(session: Session?, device: ULID?) async -> SyncAccountCleanup {
        sync.stop()
        await sync.drain()
        var cleanup = SyncAccountCleanup()
        var connection: SyncConnectionDocument?
        do { connection = try accounts.connectionForSignOut() }
        catch { cleanup.metadataIssue = metadataError(error) }
        do { try accounts.disableAutomaticResume() }
        catch { cleanup.metadataIssue = metadataError(error) }
        // Retire in-memory credentials before any suspension or cleanup error.
        locked { active = nil; cached = SyncAccountSnapshot() }
        var remote = session
        var unverified: SyncAccount?
        if remote == nil, let account = connection?.account {
            do { remote = try resolve(account); unverified = account }
            catch { cleanup.remote = .unconfirmed }
        }
        if let remote {
            cleanup.remote = await revoke(remote.client, device: device, validating: unverified)
        } else if connection?.account != nil { cleanup.remote = .unconfirmed }

        let ids = Set((connection?.cleanupConnections ?? []) + [connection?.account?.connectionID, session?.account.connectionID].compactMap { $0 })
        do { try accounts.saveInactive(nil, retiring: Array(ids)); cleanup.metadataIssue = nil }
        catch { cleanup.metadataIssue = metadataError(error) }
        do { try await sync.prepareSignOut(root: root) }
        catch { cleanup.recoveryRequired = true }
        deleteSecrets(Array(ids), cleanup: &cleanup)
        return cleanup
    }

    private static func validate(_ me: SyncAPI.MeResponse, userID: ULID) throws -> SyncAPI.Device {
        guard me.user.id == userID.rawValue, me.user.disabledAt == nil,
              Set(me.devices.map(\.id)).count == me.devices.count,
              me.devices.filter(\.isCurrent).count == 1,
              let current = me.devices.first(where: \.isCurrent), current.revokedAt == nil else {
            throw SyncAccountServiceError(issue: .invalidAccount)
        }
        return current
    }

    private func bind(_ credential: SyncCredential, to account: SyncAccount) throws -> SecretValue {
        try credential.token.withValue { token in
            let envelope = DeviceSecret(version: Limits.syncDeviceSecretVersion, server_url: account.identity.serverURL.absoluteString,
                user_id: account.identity.userID.rawValue, connection_id: account.connectionID.uuidString.lowercased(), token: token)
            return SecretValue(String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self))
        }
    }

    private func resolve(_ account: SyncAccount) throws -> Session? {
        guard let stored = try readSecret(account.secretAccount, source: .effective) else { return nil }
        let server = try SyncServerURL(account.identity.serverURL.absoluteString)
        let token: SecretValue
        if stored.tier == .environment { token = stored.value }
        else {
            let value = stored.value.withValue { try? JSONDecoder().decode(DeviceSecret.self, from: Data($0.utf8)) }
            guard let value, value.version == Limits.syncDeviceSecretVersion,
                  value.server_url == server.baseURL.absoluteString, value.user_id == account.identity.userID.rawValue,
                  value.connection_id == account.connectionID.uuidString.lowercased() else {
                throw SyncAccountServiceError(issue: .tokenBindingMismatch)
            }
            token = SecretValue(value.token)
        }
        guard token.withValue({ (try? SyncAPISchema.token.validate(.string($0))) != nil }) else {
            throw SyncAccountServiceError(issue: .tokenBindingMismatch)
        }
        return Session(account: account, client: SyncHTTPClient(server: server, transport: transport,
            credential: SyncCredential(server: server, token: token)), tier: stored.tier)
    }

    private func readSecret(_ account: SecretAccount, source: SecretReadSource) throws -> StoredSecret? {
        do { return try secrets.read(account: account, source: source) }
        catch { throw SyncAccountServiceError(issue: .secret(error as? SecretStoreError ?? .readFailed)) }
    }

    private func writeSecret(_ value: SecretValue, account: SecretAccount) throws -> SecretTier {
        do {
            let tier = try secrets.write(value, account: account)
            guard tier != .environment else { throw SecretStoreError.readOnly }
            return tier
        } catch { throw SyncAccountServiceError(issue: .secret(error as? SecretStoreError ?? .writeFailed)) }
    }

    private func deleteSecrets(_ ids: [UUID], cleanup: inout SyncAccountCleanup) {
        for id in Set(ids).sorted(by: { $0.uuidString < $1.uuidString }) {
            do { try secrets.delete(account: .device(id)) }
            catch {
                cleanup.secretFailures.append(id)
                cleanup.secretIssue = error as? SecretStoreError ?? .deleteFailed
                continue
            }
            do { try accounts.finishSecretCleanup(id) }
            catch { cleanup.metadataIssue = metadataError(error) }
        }
    }

    private func revoke(_ client: SyncHTTPClient, device: ULID? = nil, validating account: SyncAccount? = nil) async -> SyncRemoteRevocation {
        // Cleanup must get its bounded attempt even if login was cancelled.
        await Task.detached {
            do {
                let deadline = ContinuousClock.now.advanced(by: Limits.syncLogoutTimeout)
                if let account {
                    let me = try await client.me(deadline: deadline)
                    let current = try Self.validate(me, userID: account.identity.userID)
                    guard current.id == account.deviceID.rawValue else { return SyncRemoteRevocation.unconfirmed }
                }
                if let device { try await client.revokeDevice(id: device, deadline: deadline) }
                else { try await client.logout(deadline: deadline) }
                return SyncRemoteRevocation.revoked
            } catch SyncHTTPClientError.unauthorized { return SyncRemoteRevocation.revoked }
            catch { return SyncRemoteRevocation.unconfirmed }
        }.value
    }

    private static func requiresSignIn(_ issue: SyncAccountIssue) -> Bool {
        switch issue {
        case .http(.unauthorized), .invalidAccount, .tokenBindingMismatch, .credentialsRequired: return true
        default: return false
        }
    }

    private func session() throws -> Session {
        guard let value = locked({ active }) else { throw SyncAccountServiceError(issue: .signedOut) }
        return value
    }

    private func failure(_ error: Error) -> SyncAccountServiceError {
        if let error = error as? SyncAccountServiceError { return error }
        if let error = error as? SyncHTTPClientError { return SyncAccountServiceError(issue: .http(error)) }
        if let error = error as? SyncError { return SyncAccountServiceError(issue: .metadata(error)) }
        if let error = error as? SecretStoreError { return SyncAccountServiceError(issue: .secret(error)) }
        if let error = error as? SyncGroupFolderError, case .reservedFolders(let paths) = error {
            return SyncAccountServiceError(issue: .reservedFolders(paths))
        }
        if error is LibraryError || error is SyncFileOperationError || error is SyncCoordinatorError || error is SyncReconciliationError {
            return SyncAccountServiceError(issue: .recoveryRequired)
        }
        if error is SyncPushError { return SyncAccountServiceError(issue: .busy) }
        if error is CancellationError { return SyncAccountServiceError(issue: .http(.transport(.cancelled))) }
        return SyncAccountServiceError(issue: .invalidInput)
    }

    private func metadataError(_ error: Error) -> SyncError { error as? SyncError ?? .invalidState }

    private func enter() throws {
        try locked {
            guard !busy else { throw SyncAccountServiceError(issue: .busy) }
            busy = true
        }
    }

    private func leave() { locked { busy = false } }

    private func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
