import Foundation
import XCTest
@testable import MonkeysPawCore

/// Work is delivered only when the test drains the UI queue. Captured closures
/// can be replayed to test completion fencing without over-fulfilling an expectation.
final class SyncPresentationMain: MainThread {
    private let lock = NSLock()
    private var pending: [() -> Void] = []
    var isUI: Bool { Thread.current.threadDictionary["y15-ui"] as? Bool == true }

    func run(_ work: @escaping () -> Void) {
        lock.lock(); pending.append(work); lock.unlock()
    }

    @discardableResult func flush() -> [() -> Void] {
        lock.lock(); let work = pending; pending.removeAll(); lock.unlock()
        replay(work)
        return work
    }

    func replay(_ work: [() -> Void]) {
        let previous = Thread.current.threadDictionary["y15-ui"]
        Thread.current.threadDictionary["y15-ui"] = true
        defer { Thread.current.threadDictionary["y15-ui"] = previous }
        work.forEach { $0() }
    }
}

final class AccountPresentationFake: AccountProviding {
    enum Call: Equatable {
        case startup, refresh, signOut
        case login(server: String, username: String, device: String)
        case revoke(ULID)
        case include(Set<PromptIdentity>)
    }

    let main: SyncPresentationMain
    private let lock = NSLock()
    private var cached = SyncAccountSnapshot()
    private var savedHolds: [SyncHeldPrompt] = []
    private var recorded: [Call] = []
    private var supplied: SecretValue?
    var handler: ((Call) async throws -> SyncAccountSnapshot)?
    var holdsError: Error?

    init(main: SyncPresentationMain) { self.main = main }

    var snapshot: SyncAccountSnapshot {
        get { XCTAssertFalse(main.isUI); return locked { cached } }
        set { locked { cached = newValue } }
    }
    var holds: [SyncHeldPrompt] {
        get { locked { savedHolds } }
        set { locked { savedHolds = newValue } }
    }
    var calls: [Call] { locked { recorded } }
    var password: SecretValue? { locked { supplied } }

    func login(server: String, username: String, password: inout String, deviceName: String) async throws -> SyncAccountSnapshot {
        XCTAssertFalse(main.isUI)
        let secret = SecretValue(password)
        password = ""
        locked { supplied = secret }
        return try await perform(.login(server: server, username: username, device: deviceName))
    }
    func startup() async throws -> SyncAccountSnapshot { try await perform(.startup) }
    func refresh() async throws -> SyncAccountSnapshot { try await perform(.refresh) }
    func revokeDevice(_ id: ULID) async throws -> SyncAccountSnapshot { try await perform(.revoke(id)) }
    func signOut() async throws -> SyncAccountCleanup { try await perform(.signOut).cleanup }
    func includeHeld(_ identities: Set<PromptIdentity>) async throws -> SyncAccountSnapshot {
        let result = try await perform(.include(identities))
        locked { savedHolds.removeAll { identities.contains($0.identity) } }
        return result
    }
    func heldPrompts() throws -> [SyncHeldPrompt] {
        XCTAssertFalse(main.isUI)
        if let holdsError { throw holdsError }
        return holds
    }

    private func perform(_ call: Call) async throws -> SyncAccountSnapshot {
        XCTAssertFalse(main.isUI)
        locked { recorded.append(call) }
        let result: SyncAccountSnapshot
        if let handler { result = try await handler(call) }
        else { result = snapshot }
        snapshot = result
        return result
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    static func signedIn(user: ULID = SyncTestValues.user, server: String = "https://example.test/paw",
                         tier: SecretTier = .secretService) throws -> SyncAccountSnapshot {
        let account = try SyncAccount(identity: SyncTestValues.account(userID: user, server: server),
            username: "person", deviceID: SyncTestValues.device, deviceName: "Desktop", connectionID: SyncTestValues.uuid)
        let devices = [device(SyncTestValues.device, current: true), device(SyncTestValues.group, current: false)]
        let person = SyncAPI.User(id: user.rawValue, username: "person", displayName: nil,
            accountKind: .member, createdAt: "2026-10-14T00:00:00.000Z", disabledAt: nil)
        return SyncAccountSnapshot(account: account,
            me: SyncAPI.MeResponse(user: person, groups: [SyncAPI.GroupMembership(
                groupID: SyncTestValues.group.rawValue, name: "Team", role: .viewer)], devices: devices),
            tier: tier, enabled: true)
    }

    static func device(_ id: ULID, current: Bool) -> SyncAPI.Device {
        SyncAPI.Device(id: id.rawValue, name: current ? "Desktop" : "Laptop",
            createdAt: "2026-10-14T00:00:00.000Z", lastSeenAt: nil, revokedAt: nil, isCurrent: current)
    }

    static func hold(_ id: ULID = SyncTestValues.personalPrompt, path: RelativePath = "old.md") throws -> SyncHeldPrompt {
        try SyncHeldPrompt(identity: .assigned(id), path: path, sourceAccount: SyncTestValues.account(),
            contentHash: SyncHash(bytes: Data("old account content".utf8)))
    }
}

func assertSyncPresentationRedacted(_ value: Any, secrets: [String],
                                     file: StaticString = #filePath, line: UInt = #line) {
    let output = String(describing: value) + String(reflecting: value)
        + Mirror(reflecting: value).children.map { String(reflecting: $0.value) }.joined()
    for secret in secrets {
        XCTAssertFalse(output.contains(secret), "Secret appeared in presentation diagnostics", file: file, line: line)
    }
}
