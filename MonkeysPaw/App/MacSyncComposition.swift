import CryptoKit
import Foundation
import MonkeysPawCore

/// One replaceable library graph. AppDelegate supplies every service and
/// driver; this owner retires native models before draining admitted work.
final class MacSyncComposition {
    let sync: SyncService
    let accounts: SyncAccountStore
    let states: SyncStateStore
    let access: GroupAccessService
    let rootIssue: MacSyncRootIssue?
    private(set) var status: SyncStatusModel
    private(set) var conflicts: ConflictModel
    var onAccountChange: (() -> Void)?
    var onStatusChange: ((SyncStatusState) -> Void)?

    private let accountService: SyncAccountService
    private let inviteService: SyncInviteService
    private let groupService: SyncGroupService
    private let conflictService: ConflictResolutionService
    private let scheduler: DispatchSyncScheduler
    private let main: MainThread
    private var accountStorage: AccountModel?
    private var inviteStorage: InviteModel?
    private var groupStorage: GroupManagementModel?
    private var active = true
    private var startupPending = false
    private var lastConnection: AccountConnection?

    init(sync: SyncService, accounts: SyncAccountStore, states: SyncStateStore, access: GroupAccessService,
         accountService: SyncAccountService, inviteService: SyncInviteService, groupService: SyncGroupService,
         conflictService: ConflictResolutionService, scheduler: DispatchSyncScheduler, main: MainThread,
         rootIssue: MacSyncRootIssue?) {
        self.sync = sync
        self.accounts = accounts
        self.states = states
        self.access = access
        self.rootIssue = rootIssue
        self.accountService = accountService
        self.inviteService = inviteService
        self.groupService = groupService
        self.conflictService = conflictService
        self.scheduler = scheduler
        self.main = main
        status = SyncStatusModel(sync: sync, mainThread: main)
        conflicts = ConflictModel(service: conflictService, mainThread: main)
        observeStatus()
    }

    private func observeStatus() {
        status.addObserver { [weak self] state in self?.onStatusChange?(state) }
    }

    var account: AccountModel? {
        guard active else { return nil }
        if accountStorage == nil {
            let model = AccountModel(account: accountService, mainThread: main)
            accountStorage = model
            model.addObserver { [weak self, weak model] state in
                guard let self, self.active else { return }
                if self.lastConnection != state.connection {
                    self.lastConnection = state.connection
                    self.groupStorage?.dismiss()
                    self.inviteStorage?.dismiss()
                    self.conflicts.close()
                }
                self.onAccountChange?()
                // The initial cached read must finish before explicit startup.
                if self.startupPending, !state.isBusy {
                    self.startupPending = false
                    model?.startup()
                }
            }
        }
        return accountStorage
    }

    var invites: InviteModel? {
        guard active else { return nil }
        if inviteStorage == nil { inviteStorage = InviteModel(service: inviteService, mainThread: main) }
        return inviteStorage
    }

    var groups: GroupManagementModel? {
        guard active else { return nil }
        if groupStorage == nil { groupStorage = GroupManagementModel(service: groupService, mainThread: main) }
        return groupStorage
    }

    /// Production launch calls this. Hosted tests explicitly opt into network
    /// startup on their injected graph; ordinary hosted launch does not.
    func startup() {
        guard active, rootIssue == nil, sync.report.blockingIssue != .rootUnavailable else { return }
        startupPending = true
        if let account, !account.state.isBusy {
            startupPending = false
            account.startup()
        }
    }

    /// Fast synchronous replacement remains possible for an unused local graph.
    /// Busy and journal-bearing graphs must take the async drain path.
    func retireIfIdle() -> SyncStopResult {
        let stopped = sync.stop()
        guard stopped != .busy, accountStorage?.state.isBusy != true,
              inviteStorage?.state.isBusy != true, groupStorage?.state.isBusy != true,
              !conflicts.state.isBusy else { return .busy }
        guard stopped == .stopped else { return stopped }
        retireModels()
        let result = sync.retire()
        if result == .stopped { scheduler.tearDown() }
        return result
    }

    func retireModels() {
        active = false
        startupPending = false
        accountStorage?.retire()
        inviteStorage?.retire()
        groupStorage?.retire()
        conflicts.retire()
        status.retire()
        sync.stop()
    }

    /// Capture model references on UI before awaiting their admitted work off UI.
    func accountDrain() -> () async -> Void {
        let account = accountStorage
        let invites = inviteStorage
        return { await account?.drain(); await invites?.drain() }
    }

    /// Run off UI. Account compensation can restart sync, so stop AGAIN after
    /// draining all model admissions. Never discard an unsettled apply journal.
    func drainAndRetire() async -> SyncStopResult {
        await accountStorage?.drain()
        await inviteStorage?.drain()
        await groupStorage?.drain()
        await conflicts.drain()
        sync.stop()
        await sync.drain()
        var result = sync.retire()
        if result == .recoveryRequired {
            do { try await sync.recoverJournal(); result = sync.retire() }
            catch { return .recoveryRequired }
        }
        if result == .stopped { scheduler.tearDown() }
        return result
    }

    /// A refused drain keeps the original service/journal recoverable. Old
    /// native model references stay retired; consumers bind these fresh ones.
    func restoreModelsAfterFailedDrain() {
        accountStorage = nil
        inviteStorage = nil
        groupStorage = nil
        status = SyncStatusModel(sync: sync, mainThread: main)
        conflicts = ConflictModel(service: conflictService, mainThread: main)
        active = true
        observeStatus()
    }

    func filesChanged(_ changes: LibraryChangeSet, files: RootedFileStore, work: BackgroundWork) {
        let sync = self.sync
        work.run {
            do {
                try files.requireRoot()
                let paths = changes.created.union(changes.modified).union(changes.deleted)
                let events = try paths.sorted().map { path -> SyncFileChange in
                    guard let before = try files.stamp(at: path.string) else {
                        return SyncFileChange(path: path, stamp: nil, hash: nil)
                    }
                    let bytes = try files.read(at: path.string)
                    let after = try files.stamp(at: path.string)
                    let hash = after == before ? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() : nil
                    return SyncFileChange(path: path, stamp: after, hash: hash)
                }
                try files.requireRoot()
                sync.filesChanged(events)
            } catch {
                if (try? files.requireRoot()) == nil { sync.rootHealthChanged(.unavailable) }
                else { sync.localSave() }
            }
        }
    }
}
