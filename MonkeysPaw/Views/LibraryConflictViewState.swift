import Foundation
import MonkeysPawCore
import SwiftUI

/// A binding to the graph's resolver. Core owns exact bytes, CAS and permissions.
final class LibraryConflictViewState: ObservableObject {
    enum RefreshReason { case requested, afterEditing }

    @Published private(set) var state: ConflictState?
    @Published private(set) var selection: LibraryPromptSelection?
    @Published private(set) var available = false
    @Published private(set) var opening = false
    @Published private(set) var refreshPending = false
    @Published private(set) var submitting = false
    @Published private(set) var notice: String?
    var onResolve: ((ConflictResolutionAction) -> Void)?
    var onChange: (() -> Void)?
    private weak var model: ConflictModel?
    private var observer: UUID?
    private var stamp: FileStamp?
    private let main: MainThread
    private var active = true
    private var binding = UUID()

    init(main: MainThread) { self.main = main }

    deinit { if let observer { model?.removeObserver(observer) } }

    var isResolving: Bool { submitting || state?.operation == .resolving }
    var diff: ArtifactDiff? {
        guard !opening, !refreshPending, state?.preview?.copy == selection else { return nil }
        return state?.preview?.diff
    }
    var canRefresh: Bool { active && available && model != nil && !opening && !submitting && state?.isBusy == false }
    var message: String {
        if model == nil { return LibraryConflictStrings.unavailable }
        if opening || refreshPending || state?.operation == .loading { return LibraryConflictStrings.loading }
        if isResolving { return LibraryConflictStrings.resolving }
        if let failure = state?.error ?? state?.preview?.mineRefusal { return LibraryConflictStrings.failure(failure) }
        if let action = state?.resolved { return LibraryConflictStrings.resolved(action) }
        return notice ?? LibraryConflictStrings.choose
    }

    func bind(model: ConflictModel?, selection: LibraryPromptSelection, stamp: FileStamp, available: Bool) {
        guard active else { return }
        if self.model !== model {
            detach()
            self.model = model
            state = model?.state
            let binding = self.binding
            observer = model?.addObserver { [weak self, weak model] state in
                self?.main.run { [weak self, weak model] in
                    guard let self, let model, self.active, self.binding == binding,
                          self.model === model, self.selection != nil else { return }
                    self.state = model.state
                    self.opening = false
                    self.submitting = false
                    self.loadPending()
                    self.onChange?()
                }
            }
            refreshPending = true
        }
        self.available = available
        if self.selection != selection || self.stamp != stamp {
            self.selection = selection
            self.stamp = stamp
            notice = nil
            refreshPending = true
        }
        loadPending()
    }

    func canResolve(_ action: ConflictResolutionAction) -> Bool {
        guard active, available, !refreshPending, !opening, !submitting,
              let selection, let state, state.preview?.copy == selection,
              model?.state.isBusy == false, model?.state.preview?.id == state.preview?.id else { return false }
        switch action {
        case .keepServer: return state.canKeepServer
        case .keepMine: return state.canKeepMine
        case .keepBoth: return state.canKeepBoth
        }
    }

    func requestResolution(_ action: ConflictResolutionAction) {
        if canResolve(action) { onResolve?(action) }
    }

    func resolve(_ action: ConflictResolutionAction) {
        guard canResolve(action), let model else { return }
        notice = nil
        // Revoke native edit/action gates before a queued Core publication.
        submitting = true
        onChange?()
        model.resolve(action)
    }

    func refreshComparison(_ reason: RefreshReason = .requested) {
        guard active, selection != nil, !isResolving,
              reason == .afterEditing || canRefresh else { return }
        notice = reason == .afterEditing ? LibraryConflictStrings.chooseAgain : nil
        refreshPending = true
        loadPending()
    }

    func retire() {
        guard active else { return }
        active = false
        onResolve = nil
        onChange = nil
        detach()
        selection = nil
        state = nil
        available = false
    }

    private func detach() {
        binding = UUID()
        if let observer { model?.removeObserver(observer) }
        observer = nil
        model?.close()
        model = nil
        opening = false
        submitting = false
    }

    private func loadPending() {
        guard refreshPending, !opening, !submitting, let selection, let model, !model.state.isBusy else { return }
        refreshPending = false
        opening = true
        model.open(selection)
    }
}
