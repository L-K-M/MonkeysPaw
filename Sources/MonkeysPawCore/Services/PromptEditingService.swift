import Foundation

/// One editor service per library graph. Requests, session retirement and
/// deactivate originate on the UI thread; all file/codec work uses the serial
/// work port. Completions and external changes use MainThread. The lock also
/// protects session membership from worker and index callback threads.
public final class PromptEditingService: @unchecked Sendable {
    private enum OpenFile {
        case unloaded, missing(previousStamp: FileStamp?), present(FileStamp)

        func matches(_ stamp: FileStamp?) -> Bool {
            switch self {
            case .unloaded: return true
            case .missing: return stamp == nil
            case .present(let loaded): return loaded == stamp
            }
        }
    }

    private struct Session {
        var path: String
        let onExternalChange: (PromptExternalChange) -> Void
        var file = OpenFile.unloaded
        var observedStamp: FileStamp?
        var indexVersion: UInt64 = 0
        // A publication after the initial checked read waits for its result.
        var pendingInitialChange: PromptExternalChange?
        var savesInFlight = 0
        var deferredChanges: [PromptExternalChange] = []
        var committedStamps: [FileStamp] = []
    }

    private struct LoadRead {
        let outcome: PromptLoadOutcome
        let indexVersion: UInt64
    }

    private enum CommittedFile { case unchanged, present(FileStamp), missing }

    private let library: LibraryService
    private let index: PromptIndex
    private let work: BackgroundWork
    private let main: MainThread
    private let lock = NSLock()
    private var isActive = true
    private var sessions: [PromptEditingSession: Session] = [:]
    private var indexObserver: UUID?

    public init(library: LibraryService, index: PromptIndex, work: BackgroundWork, main: MainThread) {
        self.library = library
        self.index = index
        self.work = work
        self.main = main
        indexObserver = index.addObserver { [weak self] change in self?.indexChanged(change) }
    }

    deinit {
        if let indexObserver { index.removeObserver(indexObserver) }
    }

    /// Binds a token to exact path bytes. Registration is quiet and does no I/O.
    /// A token created after deactivation immediately completes requests with
    /// failed(.library(.operationFailed)); previously live tokens stay retired.
    public func beginSession(at path: String,
                             onExternalChange: @escaping (PromptExternalChange) -> Void = { _ in }) -> PromptEditingSession {
        registerSession(at: path, stamp: nil, onExternalChange: onExternalChange)
    }

    /// Copy adoption already has a checked, committed entry. Register that
    /// baseline immediately so notifications need not wait for an initial load.
    func beginSession(forCommitted entry: LibraryEntry,
                      onExternalChange: @escaping (PromptExternalChange) -> Void) -> PromptEditingSession {
        registerSession(at: entry.relativePath, stamp: entry.stamp, onExternalChange: onExternalChange)
    }

    private func registerSession(at path: String, stamp: FileStamp?,
                                 onExternalChange: @escaping (PromptExternalChange) -> Void) -> PromptEditingSession {
        locked {
            let token = PromptEditingSession(token: UUID(), isInactive: !isActive)
            guard isActive else { return token }
            var state = Session(path: path, onExternalChange: onExternalChange)
            if let stamp { state.file = .present(stamp); state.observedStamp = stamp }
            sessions[token] = state
            return token
        }
    }

    /// Drops queued requests and replies. A write already executing may finish;
    /// its completion cannot reach a retired editor.
    public func retire(_ session: PromptEditingSession) { locked { sessions[session] = nil } }

    /// Composition retires the whole graph before replacing its library root.
    public func deactivate() {
        let observer = locked { () -> UUID? in
            isActive = false
            sessions.removeAll()
            let observer = indexObserver
            indexObserver = nil
            return observer
        }
        if let observer { index.removeObserver(observer) }
    }

    public func load(session: PromptEditingSession, completion: @escaping (PromptLoadOutcome) -> Void) {
        guard !session.isInactive else { return completion(.failed(.library(.operationFailed))) }
        submit(session, operation: { service, path in
            let snapshot = service.index.editingSnapshot(at: path)
            service.locked {
                // Only the initial load folds the cache baseline. Reloads still
                // read disk, but cannot supersede a publication newer than that read.
                guard var state = service.sessions[session], case .unloaded = state.file else { return }
                if state.indexVersion <= snapshot.version {
                    state.observedStamp = snapshot.stamp
                    state.indexVersion = snapshot.version
                    state.pendingInitialChange = nil
                }
                service.sessions[session] = state
            }
            return service.readForLoad(at: path, indexVersion: snapshot.version)
        }, completion: { service, read in
            let pending = service.locked { () -> PromptExternalChange? in
                guard var state = service.sessions[session] else { return nil }
                let hasNewerPublication = state.indexVersion > read.indexVersion
                switch read.outcome {
                case .loaded(let loaded):
                    if !hasNewerPublication {
                        state.file = .present(loaded.stamp)
                        if state.observedStamp == nil { state.observedStamp = loaded.stamp }
                        state.pendingInitialChange = nil
                    } else if case .unloaded = state.file {
                        state.file = .present(loaded.stamp)
                    }
                case .deleted:
                    if !hasNewerPublication {
                        state.file = .missing(previousStamp: state.observedStamp)
                        state.observedStamp = nil
                        state.indexVersion = read.indexVersion
                        state.pendingInitialChange = nil
                    } else if case .unloaded = state.file {
                        state.file = .missing(previousStamp: nil)
                    }
                case .failed: return nil
                }
                let pending = state.pendingInitialChange
                state.pendingInitialChange = nil
                service.sessions[session] = state
                return pending.flatMap { state.file.matches($0.newStamp) ? nil : $0 }
            }
            completion(read.outcome)
            if let pending { service.deliver(pending, to: session) }
        })
    }

    /// Saves at the session's bound path. Use its load stamp for normal saves;
    /// nil explicitly permits keep-mine overwrite or recreation (§5.5).
    public func save(_ source: String, session: PromptEditingSession, expectedStamp: FileStamp?,
                     completion: @escaping (PromptSaveOutcome) -> Void) {
        guard !session.isInactive else { return completion(.failed(.library(.operationFailed))) }
        let live = locked { () -> Bool in
            guard var state = sessions[session] else { return false }
            state.savesInFlight += 1
            sessions[session] = state
            return true
        }
        guard live else { return }
        submit(session, operation: { service, path in
            let previous = service.index.cachedEntry(at: path)
            let outcome = service.saveSource(source, at: path, expectedStamp: expectedStamp)
            if let entry = outcome.committedEntry, let previous {
                service.index.acceptSaved(entry, replacing: previous)
            }
            return outcome
        }, completion: { service, result in
            service.completeSave(result, session: session, completion: completion)
        })
    }

    /// Uses exclusive create with bounded alternate names and a fresh identity.
    /// A copy does not change the original session's path, stamp or history.
    public func createCopy(_ source: String, near path: String, session: PromptEditingSession,
                           completion: @escaping (PromptSaveOutcome) -> Void) {
        guard !session.isInactive else { return completion(.failed(.library(.operationFailed))) }
        submit(session, operation: { service, _ in
            service.writeSource(source, at: path) { document in
                try service.library.createCopyForEditing(document, near: path)
            }
        }, completion: { _, result in completion(result) })
    }

    public func history(for identity: PromptIdentity, session: PromptEditingSession,
                        completion: @escaping (PromptHistoryOutcome) -> Void) {
        guard !session.isInactive else { return completion(.failed(.library(.operationFailed))) }
        submit(session, operation: { service, path in
            do { return PromptHistoryOutcome.loaded(try service.library.historyForEditing(identity,
                filename: LibraryPath.filename(path))) }
            catch { return .failed(Self.failure(error)) }
        }, completion: { _, result in completion(result) })
    }

    public func restore(_ revision: HistoryRevision, session: PromptEditingSession, expectedStamp: FileStamp,
                        completion: @escaping (PromptCommandOutcome) -> Void) {
        command(session: session, expectedStamp: expectedStamp, completion: completion) { service, path in
            try service.library.restoreForEditing(revision, at: path, expectedStamp: expectedStamp)
        }
    }

    /// Filename only; the front matter and body move byte-for-byte.
    public func rename(to filename: String, session: PromptEditingSession, expectedStamp: FileStamp,
                       completion: @escaping (PromptCommandOutcome) -> Void) {
        command(session: session, expectedStamp: expectedStamp, completion: completion) { service, path in
            guard !filename.isEmpty, !filename.unicodeScalars.contains("/") else { throw FileStoreError.invalidPath }
            let scalars = path.unicodeScalars
            let directory = scalars.lastIndex(of: "/").map {
                String(path[..<scalars.index(after: $0)])
            } ?? ""
            return try service.library.moveForEditing(at: path, to: directory + filename, expectedStamp: expectedStamp)
        }
    }

    /// Empty folder means the library root. FileStore.move creates parents.
    public func move(to folder: String, session: PromptEditingSession, expectedStamp: FileStamp,
                     completion: @escaping (PromptCommandOutcome) -> Void) {
        command(session: session, expectedStamp: expectedStamp, completion: completion) { service, path in
            if !folder.isEmpty { try FileStorePath.validate(folder) }
            let destination = (folder.isEmpty ? "" : folder + "/") + LibraryPath.filename(path)
            return try service.library.moveForEditing(at: path, to: destination, expectedStamp: expectedStamp)
        }
    }

    public func delete(session: PromptEditingSession, expectedStamp: FileStamp,
                       completion: @escaping (PromptCommandOutcome) -> Void) {
        command(session: session, expectedStamp: expectedStamp, completion: completion) { service, path in
            try service.library.deleteForEditing(at: path, expectedStamp: expectedStamp)
        }
    }

    private func command(session: PromptEditingSession, expectedStamp: FileStamp,
                         completion: @escaping (PromptCommandOutcome) -> Void,
                         perform: @escaping (PromptEditingService, String) throws -> PromptCommandOutcome) {
        guard !session.isInactive else { return completion(.failed(.library(.operationFailed))) }
        let live = locked { () -> Bool in
            guard var state = sessions[session] else { return false }
            state.savesInFlight += 1
            sessions[session] = state
            return true
        }
        guard live else { return }
        submit(session, operation: { service, path in
            let version = service.index.editingSnapshot(at: path).version
            let outcome: PromptCommandOutcome
            do { outcome = try perform(service, path) }
            catch LibraryError.destinationOccupied { outcome = .destinationOccupied }
            catch FileStoreError.notFound {
                // A missing app-data file during migration is not deletion of
                // the library prompt. Recheck that path before classifying it.
                switch service.checkedLoad(at: path) {
                case .deleted: outcome = .missing
                case .loaded(let loaded):
                    outcome = loaded.stamp == expectedStamp ? .failed(.fileStore(.notFound))
                        : .conflict(currentStamp: loaded.stamp)
                case .failed(let failure): outcome = .failed(failure)
                }
            }
            catch LibraryError.conflict {
                switch service.checkedLoad(at: path) {
                case .loaded(let loaded): outcome = .conflict(currentStamp: loaded.stamp)
                case .deleted: outcome = .missing
                case .failed(let failure): outcome = .failed(failure)
                }
            }
            catch { outcome = .failed(Self.failure(error)) }
            if let entry = outcome.committedEntry {
                service.rebind(session, to: entry, file: .present(entry.stamp), indexVersion: version)
                service.index.acceptCommand(entry, at: path, expectedVersion: version, expectedSourceStamp: expectedStamp)
            } else if case .relocated(let baseline, let current) = outcome {
                let file: OpenFile
                switch current {
                case .loaded(let loaded): file = .present(loaded.stamp)
                case .deleted: file = .missing(previousStamp: baseline.stamp)
                case .failed: file = .unloaded
                }
                service.rebind(session, to: baseline, file: file, indexVersion: version)
                if case .loaded(let loaded) = current {
                    service.index.acceptCommand(loaded.entry, at: path, expectedVersion: version, expectedSourceStamp: expectedStamp)
                } else { service.index.acceptCommand(nil, at: path, expectedVersion: version, expectedSourceStamp: expectedStamp) }
            } else if case .deleted = outcome {
                service.locked {
                    guard var state = service.sessions[session] else { return }
                    state.file = .missing(previousStamp: state.observedStamp)
                    state.observedStamp = nil
                    state.indexVersion = max(state.indexVersion, version)
                    service.sessions[session] = state
                }
                service.index.acceptCommand(nil, at: path, expectedVersion: version, expectedSourceStamp: expectedStamp)
            }
            return outcome
        }, completion: { service, result in
            let file: CommittedFile
            if let entry = result.committedEntry { file = .present(entry.stamp) }
            else {
                switch result {
                case .missing, .deleted: file = .missing
                case .relocated(_, let current):
                    switch current {
                    case .loaded(let loaded): file = .present(loaded.stamp)
                    case .deleted: file = .missing
                    case .failed: file = .unchanged
                    }
                default: file = .unchanged
                }
            }
            service.completeWrite(file, session: session) { completion(result) }
        })
    }

    private func rebind(_ session: PromptEditingSession, to entry: LibraryEntry, file: OpenFile, indexVersion: UInt64) {
        locked {
            guard var state = sessions[session], !state.path.utf8.elementsEqual(entry.relativePath.utf8) else { return }
            state.path = entry.relativePath
            state.file = file
            if case .present(let stamp) = file { state.observedStamp = stamp }
            else { state.observedStamp = nil }
            state.pendingInitialChange = nil
            // These were accepted while the session still watched the old
            // path, including the watcher's publication of our own move.
            state.deferredChanges = []
            state.indexVersion = max(state.indexVersion, indexVersion)
            sessions[session] = state
        }
    }

    private func submit<Result>(_ session: PromptEditingSession,
                                operation: @escaping (PromptEditingService, String) -> Result,
                                completion: @escaping (PromptEditingService, Result) -> Void) {
        guard path(for: session) != nil else { return }
        work.run { [weak self] in
            guard let self, let path = self.path(for: session) else { return }
            let result = operation(self, path)
            self.main.run { [weak self] in
                guard let self, self.path(for: session) != nil else { return }
                completion(self, result)
            }
        }
    }

    private func readForLoad(at path: String, indexVersion: UInt64) -> LoadRead {
        let outcome = checkedLoad(at: path)
        guard case .deleted = outcome else { return LoadRead(outcome: outcome, indexVersion: indexVersion) }
        let snapshot = index.editingSnapshot(at: path)
        guard snapshot.version > indexVersion, snapshot.stamp != nil else {
            return LoadRead(outcome: .deleted, indexVersion: snapshot.version)
        }

        // A publication may follow the missing probe before its call returns.
        // Recheck once so an actual recreation is loaded and an older parked
        // publication is superseded only by a subsequent checked missing read.
        let rechecked = checkedLoad(at: path)
        guard case .deleted = rechecked else { return LoadRead(outcome: rechecked, indexVersion: snapshot.version) }
        let latest = index.editingSnapshot(at: path)
        if latest.version > snapshot.version, latest.stamp != nil, latest.stamp != snapshot.stamp {
            return LoadRead(outcome: .failed(.library(.conflict)), indexVersion: latest.version)
        }
        return LoadRead(outcome: .deleted, indexVersion: latest.version)
    }

    private func checkedLoad(at path: String) -> PromptLoadOutcome {
        do { return .loaded(try library.loadForEditing(at: path)) }
        catch FileStoreError.notFound { return .deleted }
        catch { return .failed(Self.failure(error)) }
    }

    private func saveSource(_ source: String, at path: String, expectedStamp: FileStamp?) -> PromptSaveOutcome {
        writeSource(source, at: path) { document in
            do { return try library.saveForEditing(document, at: path, expectedStamp: expectedStamp) }
            catch LibraryError.conflict {
                // Includes deletion during the library's stamp/read or staging
                // checks. Read again on this worker to distinguish the outcomes.
                do { return .conflict(currentStamp: try library.loadForEditing(at: path).stamp) }
                catch FileStoreError.notFound { return .deleted }
            }
        }
    }

    private func writeSource(_ source: String, at path: String,
                             write: (PromptDocument) throws -> PromptSaveOutcome) -> PromptSaveOutcome {
        let document = PromptCodec.parse(source, filename: LibraryPath.filename(path))
        if document.isReadOnly { return .readOnly(.unsupportedFormat(document.frontMatter.format)) }
        let issues = document.issues
        guard !issues.contains(where: { $0.severity == .error }) else { return .invalid(issues) }
        do { return try write(document) }
        catch PromptWriteError.sourceTooLarge { return .invalid([PromptIssue(.sourceTooLarge)]) }
        catch let error as PromptWriteError {
            if case .unsupportedFormat(let version) = error { return .readOnly(.unsupportedFormat(version)) }
            return .failed(.write(error))
        }
        catch { return .failed(Self.failure(error)) }
    }

    private func completeSave(_ result: PromptSaveOutcome, session: PromptEditingSession,
                              completion: (PromptSaveOutcome) -> Void) {
        let file: CommittedFile
        if let entry = result.committedEntry { file = .present(entry.stamp) }
        else if case .deleted = result { file = .missing }
        else { file = .unchanged }
        completeWrite(file, session: session) { completion(result) }
    }

    private func completeWrite(_ file: CommittedFile, session: PromptEditingSession,
                               completion: () -> Void) {
        let deferred = locked { () -> [PromptExternalChange] in
            guard var state = sessions[session] else { return [] }
            state.savesInFlight -= 1
            switch file {
            case .present(let stamp):
                state.file = .present(stamp)
                if state.observedStamp == nil { state.observedStamp = stamp }
                state.committedStamps.append(stamp)
            case .missing: state.file = .missing(previousStamp: state.observedStamp)
            case .unchanged: break
            }
            var changes: [PromptExternalChange] = []
            if state.savesInFlight == 0 {
                changes = state.deferredChanges.filter { change in
                    !state.committedStamps.contains { $0 == change.newStamp }
                }
                state.deferredChanges = []
                state.committedStamps = []
            }
            sessions[session] = state
            return changes
        }
        completion()
        for change in deferred { deliver(change, to: session) }
    }

    private func indexChanged(_ change: PromptIndexChange) {
        let paths = change.changes.created.union(change.changes.modified).union(change.changes.deleted)
        let watching = locked { sessions.compactMap { paths.contains(RelativePath($0.value.path)) ? $0.key : nil } }
        for session in watching {
            main.run { [weak self] in self?.observe(change, session: session) }
        }
    }

    private func observe(_ publication: PromptIndexChange, session: PromptEditingSession) {
        let change = locked { () -> PromptExternalChange? in
            guard var state = sessions[session], publication.version > state.indexVersion,
                  publication.changes.created.union(publication.changes.modified).union(publication.changes.deleted)
                    .contains(RelativePath(state.path)) else { return nil }
            state.indexVersion = publication.version
            defer { sessions[session] = state }
            let stamp = publication.stamps[RelativePath(state.path)]
            guard state.observedStamp != stamp else { return nil }
            let previousStamp = state.observedStamp
            let kind: PromptExternalChange.Kind
            if stamp == nil { kind = .deleted }
            else if state.observedStamp == nil { kind = .recreated }
            else if case .missing(let previous) = state.file, previous == state.observedStamp { kind = .recreated }
            else { kind = .modified }
            state.observedStamp = stamp
            let change = PromptExternalChange(kind: kind, newStamp: stamp)
            if case .unloaded = state.file {
                state.pendingInitialChange = change
                return nil
            }
            guard !state.file.matches(stamp) else { return nil }
            // Accepted deferred changes also advance the state to communicate:
            // a recreation must make a following deletion observable.
            state.file = stamp.map(OpenFile.present) ?? .missing(previousStamp: previousStamp)
            if state.savesInFlight > 0 {
                state.deferredChanges.append(change)
                return nil
            }
            return change
        }
        if let change { deliver(change, to: session) }
    }

    private func deliver(_ change: PromptExternalChange, to session: PromptEditingSession) {
        let callback = locked { () -> ((PromptExternalChange) -> Void)? in
            guard var state = sessions[session] else { return nil }
            if state.savesInFlight > 0 {
                state.deferredChanges.append(change)
                sessions[session] = state
                return nil
            }
            // A save outcome may have superseded the accepted state while this
            // notification waited. Reconcile it before calling into the editor.
            state.file = change.newStamp.map(OpenFile.present) ?? .missing(previousStamp: state.observedStamp)
            sessions[session] = state
            return state.onExternalChange
        }
        callback?(change)
    }

    private func path(for session: PromptEditingSession) -> String? { locked { sessions[session]?.path } }

    private static func failure(_ error: Error) -> PromptEditingFailure {
        switch error {
        case let error as FileStoreError: return .fileStore(error)
        case let error as LibraryError: return .library(error)
        case let error as PromptWriteError: return .write(error)
        case let error as ULIDGenerationError: return .identity(error)
        default: return .library(.operationFailed)
        }
    }

    private func locked<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}
