import Foundation
import MonkeysPawCore
import SwiftUI

/// Each surface owns a removable subscription. Reports only render state;
/// window navigation belongs to explicit actions supplied by composition.
final class SyncStatusViewState: ObservableObject {
    enum Surface { case picker, library }
    @Published private(set) var state: SyncStatusState?
    let surface: Surface
    private let main: MainThread
    private let makeModel: () -> SyncStatusModel?
    private let navigate: (SyncStatusAction) -> Void
    private let openFile: (RelativePath) -> Void
    private weak var model: SyncStatusModel?
    private var observer: UUID?
    private var binding: UInt64 = 0
    private var active = false
    private var retired = false

    init(surface: Surface, main: MainThread, makeModel: @escaping () -> SyncStatusModel?,
         navigate: @escaping (SyncStatusAction) -> Void, openFile: @escaping (RelativePath) -> Void = { _ in }) {
        self.surface = surface
        self.main = main
        self.makeModel = makeModel
        self.navigate = navigate
        self.openFile = openFile
    }

    deinit { if let observer { model?.removeObserver(observer) } }

    var summary: String { state.map(SyncStatusStrings.summary) ?? SyncStatusStrings.unavailable }
    var lastSuccess: String { SyncStatusStrings.lastSuccess(state?.lastSuccess) }
    var primaryAction: SyncStatusAction { state?.action ?? .none }
    var additionalActions: [SyncStatusAction] {
        guard surface == .library, let state else { return [] }
        var actions: [SyncStatusAction] = []
        if state.canSyncNow, state.action != .syncNow { actions.append(.syncNow) }
        if !state.fileErrors.isEmpty, state.action != .errors { actions.append(.errors) }
        if state.counts.conflicts > 0, state.action != .conflicts { actions.append(.conflicts) }
        return actions
    }

    func show() {
        guard !retired else { return }
        active = true
        refreshBinding()
    }

    func hide() {
        active = false
        detach()
    }

    func retire() {
        retired = true
        hide()
        state = nil
    }

    func refreshBinding() {
        guard active, !retired else { return }
        let next = makeModel()
        if model !== next {
            detach()
            model = next
        }
        if observer == nil, let model {
            let binding = self.binding
            observer = model.addObserver { [weak self, weak model] _ in
                self?.main.run { [weak self, weak model] in
                    guard let self, let model, self.active, !self.retired,
                          self.binding == binding, self.model === model else { return }
                    self.refreshBinding()
                }
            }
        }
        state = next?.state
    }

    func performPrimaryAction() {
        guard let model = currentModel() else { return }
        perform(model.state.action)
    }

    func perform(_ action: SyncStatusAction) {
        guard let model = currentModel() else { return }
        switch action {
        case .syncNow:
            if model.state.footer == .needsSignIn { navigate(.account) }
            else if model.state.canSyncNow { model.syncNow() }
        case .errors:
            model.showErrorDetails()
            if surface == .picker { navigate(.errors) }
        case .conflicts:
            if model.state.counts.conflicts > 0 { navigate(.conflicts) }
        case .account: navigate(.account)
        case .none: break
        }
    }

    func dismissErrors() { currentModel()?.dismissErrorDetails() }

    func openError(_ error: SyncStatusFileError) {
        guard let model = currentModel(), model.state.fileErrors.contains(error) else { return }
        openFile(error.path)
    }

    private func currentModel() -> SyncStatusModel? {
        guard active, !retired, let model else { return nil }
        guard makeModel() === model else {
            // A click from an obsolete graph must not run on its replacement.
            refreshBinding()
            return nil
        }
        return model
    }

    private func detach() {
        binding &+= 1
        if let observer { model?.removeObserver(observer) }
        observer = nil
        model = nil
    }
}

struct SyncStatusView: View {
    @ObservedObject var presentation: SyncStatusViewState

    private var prefix: String { presentation.surface == .picker ? "picker-sync" : "library-sync" }

    @ViewBuilder var body: some View {
        if presentation.surface == .library { libraryBody } else { compactPicker }
    }

    /// The picker footer shows one summary line; its menu holds the details and actions.
    private var compactPicker: some View {
        Menu {
            Text(presentation.lastSuccess).accessibilityIdentifier(prefix + "-last-success")
            if let message = presentation.state?.errorMessage {
                Text(message).accessibilityIdentifier(prefix + "-message")
            }
            if presentation.primaryAction != .none {
                Button(SyncStatusStrings.action(presentation.primaryAction), action: presentation.performPrimaryAction)
                    .accessibilityIdentifier(prefix + "-action")
            }
        } label: {
            Text(presentation.summary).lineLimit(1).truncationMode(.tail)
                .accessibilityIdentifier(prefix + "-summary")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .controlSize(.small)
        .font(.caption).foregroundStyle(.secondary)
        .help(([presentation.summary, presentation.lastSuccess] + [presentation.state?.errorMessage].compactMap { $0 })
            .joined(separator: "\n"))
    }

    /// Library footers get one summary/action line; the last-success and
    /// error text stay reachable in the tooltip and the details expansion.
    private var libraryBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(presentation.summary).lineLimit(1).truncationMode(.tail)
                    .help(libraryHelp)
                    .accessibilityIdentifier(prefix + "-summary")
                Spacer(minLength: 4)
                libraryActions
            }
            if presentation.state?.showsErrorDetails == true {
                errorDetails
            }
        }
        .font(.caption)
    }

    private var libraryActions: some View {
        HStack(spacing: 6) {
            if presentation.primaryAction != .none {
                Button(SyncStatusStrings.action(presentation.primaryAction), action: presentation.performPrimaryAction)
                    .accessibilityIdentifier(prefix + "-action")
            }
            if !presentation.additionalActions.isEmpty {
                Menu {
                    ForEach(Array(presentation.additionalActions.enumerated()), id: \.offset) { item in
                        Button(SyncStatusStrings.action(item.element)) { presentation.perform(item.element) }
                            .accessibilityIdentifier(prefix + "-" + actionID(item.element))
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(SyncStatusStrings.moreActions)
                .accessibilityIdentifier(prefix + "-more-actions")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .lineLimit(1)
    }

    private var libraryHelp: String {
        var parts = [presentation.summary, presentation.lastSuccess]
        if let message = presentation.state?.errorMessage { parts.append(message) }
        return parts.joined(separator: "\n")
    }

    private var errorDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(SyncStatusStrings.hideErrors, action: presentation.dismissErrors)
                .accessibilityIdentifier(prefix + "-hide-errors")
            if let message = presentation.state?.errorMessage {
                Text(message).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(prefix + "-message")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if presentation.state?.fileErrors.isEmpty != false {
                        Text(SyncStatusStrings.noFileErrors)
                    }
                    ForEach(Array((presentation.state?.fileErrors ?? []).enumerated()), id: \.offset) { item in
                        errorRow(item.element)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
        .accessibilityIdentifier(prefix + "-file-errors")
    }

    private func errorRow(_ error: SyncStatusFileError) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { presentation.openError(error) } label: {
                Text(verbatim: error.path.string).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help(error.path.string)
            .accessibilityLabel(error.path.string + ". " + error.reason)
            Text(error.reason).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionID(_ action: SyncStatusAction) -> String {
        switch action {
        case .syncNow: return "now"
        case .account: return "account"
        case .conflicts: return "conflicts"
        case .errors: return "errors"
        case .none: return "none"
        }
    }
}
