import Foundation

/// §26 S12: key provisioning for the current sync account inside Assistant
/// settings. State holds the one-time reveal only after Generate/Enter; the
/// model's own descriptions stay redacted like other secret-adjacent models.
public final class ProviderSyncKeyModel: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public enum Status: Equatable, Sendable {
        case noAccount
        case missing
        case provisioned(SecretTier)
        case unavailable
    }

    public enum Notice: Equatable, Sendable {
        case invalidKey, operationFailed
    }

    public struct State: Equatable, Sendable, CustomStringConvertible,
        CustomDebugStringConvertible, CustomReflectable {
        public let status: Status
        public let busy: Bool
        public let notice: Notice?
        /// Set once by Generate/Enter until the view dismisses or replaces it.
        public let revealedKey: String?

        public var description: String { "<provider sync key state redacted>" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["state": description]) }
    }

    public var onChange: (() -> Void)?
    public private(set) var state = State(status: .noAccount, busy: false,
        notice: nil, revealedKey: nil)

    private let keys: ProviderSyncKeyService
    private let accountUserID: () throws -> ULID?
    private let work: BackgroundWork
    private let mainThread: MainThread
    private var revision = UUID()

    public init(keys: ProviderSyncKeyService, accountUserID: @escaping () throws -> ULID?,
                work: BackgroundWork, mainThread: MainThread) {
        self.keys = keys
        self.accountUserID = accountUserID
        self.work = work
        self.mainThread = mainThread
        refresh()
    }

    /// Re-reads the account binding and stored tier; call when the account or
    /// library may have changed.
    public func refresh() {
        mainThread.run { [weak self] in
            guard let self else { return }
            let current = UUID()
            self.revision = current
            self.work.run { [keys, accountUserID, mainThread] in
                let status = Self.readStatus(keys: keys, accountUserID: accountUserID)
                mainThread.run { [weak self] in
                    guard let self, self.revision == current else { return }
                    self.state = State(status: status, busy: false, notice: nil, revealedKey: nil)
                    self.onChange?()
                }
            }
        }
    }

    /// Replaces any stored key. The revealed text is the only copy; the store
    /// already persisted it.
    public func generate() {
        perform { service, userID in try service.generateKey(userID: userID) }
    }

    /// Validates and stores the pasted key; `.invalidKey` rejects non-key text.
    public func enterKey(_ text: String) {
        perform { service, userID in
            do { return try service.enterKey(userID: userID, text: text) }
            catch let error as ProviderSyncKeyError where error == .invalidKey { throw Entry.invalid }
        }
    }

    public func remove() {
        perform { service, userID in
            try service.removeKey(userID: userID)
            return nil
        }
    }

    /// The view cleared its copy of the reveal.
    public func dismissRevealed() {
        mainThread.run { [weak self] in
            guard let self, self.state.revealedKey != nil else { return }
            self.state = State(status: self.state.status, busy: self.state.busy,
                notice: self.state.notice, revealedKey: nil)
            self.onChange?()
        }
    }

    private enum Entry: Error { case invalid }

    private static func readStatus(keys: ProviderSyncKeyService,
                                   accountUserID: () throws -> ULID?) -> Status {
        do {
            guard let userID = try accountUserID() else { return .noAccount }
            return try keys.tier(userID: userID).map(Status.provisioned) ?? .missing
        } catch { return .unavailable }
    }

    private func perform(_ operation: @escaping (ProviderSyncKeyService, ULID) throws -> String?) {
        mainThread.run { [weak self] in
            guard let self, !self.state.busy else { return }
            let current = UUID()
            self.revision = current
            self.state = State(status: self.state.status, busy: true,
                notice: nil, revealedKey: nil)
            self.onChange?()
            self.work.run { [keys, accountUserID, mainThread] in
                var status = Self.readStatus(keys: keys, accountUserID: accountUserID)
                var revealed: String?
                var notice: Notice?
                do {
                    if let userID = try accountUserID() {
                        revealed = try operation(keys, userID)
                        status = Self.readStatus(keys: keys, accountUserID: accountUserID)
                    } else { status = .noAccount }
                } catch Entry.invalid { notice = .invalidKey }
                catch { notice = .operationFailed }
                mainThread.run { [weak self] in
                    guard let self, self.revision == current else { return }
                    self.state = State(status: status, busy: false,
                        notice: notice, revealedKey: revealed)
                    self.onChange?()
                }
            }
        }
    }

    public var description: String { "<provider sync key model redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["model": description]) }
}
