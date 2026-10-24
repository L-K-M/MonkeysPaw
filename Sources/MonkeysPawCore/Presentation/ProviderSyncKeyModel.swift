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
        /// Native entry text belongs to the same account as the displayed state.
        public let inputReset: UUID

        public var canEdit: Bool {
            guard !busy else { return false }
            switch status { case .missing, .provisioned: return true; case .noAccount, .unavailable: return false }
        }
        public var description: String { "<provider sync key state redacted>" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["state": description]) }
    }

    public var onChange: (() -> Void)?
    public private(set) var state = State(status: .noAccount, busy: false,
        notice: nil, revealedKey: nil, inputReset: UUID())

    private struct Binding {
        let userID: ULID?
        let status: Status
    }
    /// UI invalidation and worker admission share only this small locked permit.
    /// Once admitted, a storage operation completes for its captured account.
    private final class OperationPermit {
        private let lock = NSLock()
        private var isValid = true

        func admit() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard isValid else { return false }
            isValid = false
            return true
        }

        func revoke() {
            lock.lock()
            isValid = false
            lock.unlock()
        }
    }
    private let keys: ProviderSyncKeyService
    private var accountUserID: () throws -> ULID?
    private let work: BackgroundWork
    private let mainThread: MainThread
    private var userID: ULID?
    private var revision = UUID()
    private var refreshRequest: UUID?
    private var operationRequest: UUID?
    private var operationPermit: OperationPermit?

    public init(keys: ProviderSyncKeyService, accountUserID: @escaping () throws -> ULID?,
                work: BackgroundWork, mainThread: MainThread) {
        self.keys = keys
        self.accountUserID = accountUserID
        self.work = work
        self.mainThread = mainThread
        refresh()
    }

    /// Same-account refreshes retain the one-time reveal and never preempt an
    /// admitted key operation. Its completion also rechecks the account.
    public func refresh() {
        mainThread.run { [weak self] in
            guard let self, self.operationRequest == nil else { return }
            self.startRefresh()
        }
    }

    /// Composition calls this when the account or library binding changes.
    /// Revoke presentation immediately, including while storage work finishes.
    public func accountDidChange(accountUserID: (() throws -> ULID?)? = nil) {
        mainThread.run { [weak self] in
            guard let self else { return }
            if let accountUserID { self.accountUserID = accountUserID }
            self.operationPermit?.revoke()
            self.revision = UUID()
            self.userID = nil
            self.state = State(status: .unavailable, busy: true, notice: nil,
                revealedKey: nil, inputReset: UUID())
            self.onChange?()
            self.startRefresh()
        }
    }

    private func startRefresh() {
        let current = UUID()
        let revision = revision
        refreshRequest = current
        state = State(status: state.status, busy: true, notice: nil,
            revealedKey: state.revealedKey, inputReset: state.inputReset)
        onChange?()
        work.run { [weak self, keys, accountUserID, mainThread] in
            let binding = Self.readBinding(keys: keys, accountUserID: accountUserID)
            mainThread.run { [weak self] in
                guard let self, self.revision == revision, self.refreshRequest == current else { return }
                self.refreshRequest = nil
                self.publish(binding, revealed: self.state.revealedKey)
            }
        }
    }

    /// Generates for the account displayed when the action was admitted.
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

    public func dismissRevealed() {
        mainThread.run { [weak self] in
            guard let self, self.state.revealedKey != nil else { return }
            self.state = State(status: self.state.status, busy: self.state.busy,
                notice: self.state.notice, revealedKey: nil, inputReset: self.state.inputReset)
            self.onChange?()
        }
    }

    private enum Entry: Error { case invalid }

    private static func readBinding(keys: ProviderSyncKeyService,
                                    accountUserID: () throws -> ULID?) -> Binding {
        do {
            guard let userID = try accountUserID() else { return Binding(userID: nil, status: .noAccount) }
            let status = try keys.tier(userID: userID).map(Status.provisioned) ?? .missing
            return Binding(userID: userID, status: status)
        } catch { return Binding(userID: nil, status: .unavailable) }
    }

    private func publish(_ binding: Binding, revealed: String?, notice: Notice? = nil) {
        let changed = userID != binding.userID || binding.status == .unavailable
        userID = binding.userID
        state = State(status: binding.status, busy: operationRequest != nil,
            notice: notice, revealedKey: changed ? nil : revealed,
            inputReset: changed ? UUID() : state.inputReset)
        onChange?()
    }

    private func perform(_ operation: @escaping (ProviderSyncKeyService, ULID) throws -> String?) {
        mainThread.run { [weak self] in
            guard let self, self.state.canEdit, let userID = self.userID else { return }
            let current = UUID()
            let revision = self.revision
            self.operationRequest = current
            let permit = OperationPermit()
            self.operationPermit = permit
            self.state = State(status: self.state.status, busy: true,
                notice: nil, revealedKey: nil, inputReset: UUID())
            self.onChange?()
            self.work.run { [weak self, keys, accountUserID, mainThread] in
                var revealed: String?
                var notice: Notice?
                do {
                    // A queued action cannot provision an account selected later.
                    if try accountUserID() == userID, permit.admit() { revealed = try operation(keys, userID) }
                } catch Entry.invalid { notice = .invalidKey }
                catch { notice = .operationFailed }
                let binding = Self.readBinding(keys: keys, accountUserID: accountUserID)
                mainThread.run { [weak self] in
                    guard let self, self.operationRequest == current else { return }
                    self.operationRequest = nil
                    self.operationPermit = nil
                    guard self.revision == revision else {
                        // A newer binding may already have rendered before this
                        // retired operation's UI reply. Release only its busy state.
                        self.state = State(status: self.state.status,
                            busy: self.refreshRequest != nil, notice: self.state.notice,
                            revealedKey: self.state.revealedKey, inputReset: self.state.inputReset)
                        self.onChange?()
                        return
                    }
                    self.publish(binding, revealed: binding.userID == userID ? revealed : nil,
                        notice: binding.userID == userID ? notice : nil)
                }
            }
        }
    }

    public var description: String { "<provider sync key model redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["model": description]) }
}
