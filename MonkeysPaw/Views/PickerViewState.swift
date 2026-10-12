import AppKit
import MonkeysPawCore
import SwiftUI

/// Core owns fill.onChange and forwards it through picker.onChange. This adapter
/// is that hook's sole front-end owner and republishes on the injected UI thread.
final class PickerViewState: ObservableObject {
    @Published private(set) var state: PickerModel.State
    @Published private(set) var focusRevision: UInt64 = 0
    @Published private(set) var transientStatus: String?
    @Published var pasteTarget = Strings.noPasteTarget
    let model: PickerModel
    private let mainThread: MainThread
    private let isCurrent: () -> Bool
    private let requestedIntent: (PickerModel.Intent) -> Void
    private let createPrompt: (String) -> Void

    init(model: PickerModel, mainThread: MainThread,
         isCurrent: @escaping () -> Bool = { true },
         requestedIntent: @escaping (PickerModel.Intent) -> Void,
         createPrompt: @escaping (String) -> Void) {
        self.model = model
        self.mainThread = mainThread
        self.isCurrent = isCurrent
        self.requestedIntent = requestedIntent
        self.createPrompt = createPrompt
        state = model.state
        model.onChange = { [weak self] in
            self?.mainThread.run { [weak self] in self?.refresh() }
        }
    }

    private func refresh() {
        guard isCurrent() else { return }
        let intent = model.state == .picker ? model.takeRequestedIntent() : nil
        if state != model.state { focusRevision &+= 1 }
        state = model.state // Republishes field values, selection and preview too.
        if let intent { requestedIntent(intent) }
    }

    func didShow() {
        guard isCurrent() else { return }
        transientStatus = nil
        focusRevision &+= 1
    }

    func setQuery(_ query: String) {
        guard isCurrent() else { return }
        transientStatus = nil
        model.setQuery(query)
    }

    func createNoMatch() {
        guard isCurrent(), model.libraryAvailable, let noMatches = model.noMatches else { return }
        createPrompt(noMatches.createTitle)
    }

    func showStatus(_ message: String) {
        guard isCurrent() else { return }
        transientStatus = message
    }

    var showsForgetValues: Bool {
        if model.fillModel != nil { return true }
        guard let position = model.selectionIndex else { return false }
        return model.results.indices.contains(position)
    }

    var canForgetValues: Bool {
        showsForgetValues && forgetValuesState != .delivering
    }

    private var forgetValuesState: PickerModel.State {
        Self.forgetValuesState(picker: model.state, fill: model.fillModel?.state)
    }

    /// The action and its refusal copy must agree even if only the form is delivering.
    static func forgetValuesState(picker: PickerModel.State, fill: FillModel.State?) -> PickerModel.State {
        fill == .delivering ? .delivering : picker
    }

    func forgetSelectedValues() {
        guard isCurrent(), showsForgetValues else { return }
        transientStatus = nil
        model.forgetSelectedValues()
    }

    var status: String {
        var warnings = model.persistenceWarnings
        for warning in model.fillModel?.persistenceWarnings ?? [] where !warnings.contains(warning) {
            warnings.append(warning)
        }
        let resolving = model.isResolvingBuiltins
            || (model.state == .fill && model.fillModel?.builtinsResolved == false)
        var messages = [model.libraryAvailable ? nil : Strings.libraryUnavailable,
                        resolving ? Strings.preparingPreview : nil].compactMap { $0 }
        if let transientStatus, !messages.contains(transientStatus) { messages.append(transientStatus) }
        messages += warnings.map(Strings.persistenceWarning)
        if let error = model.forgetValuesError {
            messages.append(Strings.forgetValuesError(error, state: forgetValuesState))
        }
        return messages.joined(separator: "\n")
    }

    var preview: String {
        if let fill = model.fillModel {
            switch fill.preview {
            case .rendered(let text): return text
            case .blocked(let error, let issues):
                let message = fill.builtinsResolved ? error.description : Strings.preparingPreview
                return ([message] + issues.map(\.message)).joined(separator: "\n")
            }
        }
        switch model.selectedPreview {
        case .none: return ""
        case .body(let text): return text
        case .issues(let issues): return issues.map(\.message).joined(separator: "\n")
        }
    }

    var useEnabled: Bool {
        guard model.state == .picker, !model.isResolvingBuiltins,
              let position = model.selectionIndex, model.results.indices.contains(position) else { return false }
        return model.results[position].canRender
    }

    func route(_ event: NSEvent, fieldKind: FieldKind?) -> Bool {
        guard isCurrent() else { return false }
        guard let intent = MacPickerKeys.intent(keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags,
            state: model.state, fieldKind: fieldKind) else { return false }
        switch intent {
        case .moveUp: model.moveSelection(.up)
        case .moveDown: model.moveSelection(.down)
        case .use(let mode): model.use(mode: mode)
        case .edit: model.editSelected()
        case .openLibrary: model.openLibrary()
        case .escape: model.escape()
        case .focusNext: model.fillModel?.focusNext()
        case .focusPrevious: model.fillModel?.focusPrevious()
        case .deliverPreferred:
            if let fill = model.fillModel { fill.deliver(mode: fill.preferredMode) }
        case .deliver(let mode): model.fillModel?.deliver(mode: mode)
        }
        return true
    }
}
