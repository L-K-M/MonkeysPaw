import AppKit
import MonkeysPawCore
import SwiftUI

/// Core owns fill.onChange and forwards it through picker.onChange. This adapter
/// is that hook's sole front-end owner and republishes on the injected UI thread.
final class PickerViewState: ObservableObject {
    @Published private(set) var state: PickerModel.State
    @Published private(set) var focusRevision: UInt64 = 0
    @Published private(set) var inputResetRevision: UInt64 = 0
    @Published private(set) var transientStatus: String?
    @Published var pasteTarget = Strings.noPasteTarget
    @Published private(set) var proofShown = false
    @Published private(set) var nudgeIndex: Int?
    @Published private(set) var nudgeRevision: UInt64 = 0
    @Published private(set) var sheenRevision: UInt64 = 0
    @Published private(set) var wetFields = Set<String>()
    @Published private var drying: [String: Double] = [:]
    private(set) var clipboardSlip = WishCardSlip.Content(mode: .thumbnail)
    let take = WishCardTake()
    var reduceMotion: () -> Bool
    private let playCue: (WishCardCue) -> Void
    private var wasReady = false
    private var observedResolved = false
    private var editedFill = false
    private var inkGeneration: UInt64 = 0
    private var observedFocus: Int?
    private weak var observedFill: FillModel?
    private var inkRevisions: [String: UInt64] = [:]
    private var takingFill: FillModel?
    private var takingCard: PromptCard?
    private var takingSelection: PromptIdentity?
    private var takingValues: [String: String]?
    let model: PickerModel
    let syncStatus: SyncStatusViewState?
    private let mainThread: MainThread
    private let isCurrent: () -> Bool
    private let requestedIntent: (PickerModel.Intent) -> Void
    private let createPrompt: (String) -> Void
    private let openSetup: () -> Void
    private let openSettings: () -> Void

    init(model: PickerModel, mainThread: MainThread,
         isCurrent: @escaping () -> Bool = { true },
         syncStatus: SyncStatusViewState? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         playCue: @escaping (WishCardCue) -> Void = { _ in },
         openSetup: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {},
         requestedIntent: @escaping (PickerModel.Intent) -> Void,
         createPrompt: @escaping (String) -> Void) {
        self.reduceMotion = reduceMotion
        self.playCue = playCue
        self.model = model
        self.syncStatus = syncStatus
        self.mainThread = mainThread
        self.isCurrent = isCurrent
        self.requestedIntent = requestedIntent
        self.createPrompt = createPrompt
        self.openSetup = openSetup
        self.openSettings = openSettings
        state = model.state
        if let fill = model.fillModel {
            observedFill = fill
            observedResolved = fill.builtinsResolved
            wasReady = fill.deliverEnabled
            clipboardSlip = WishCardSlip.Content(mode: .fill, text: fill.builtinText(.clipboard), summary: fill.clipboardSummary)
        }
        take.onChange = { [weak self] in self?.objectWillChange.send() }
        take.playCue = playCue
        model.onChange = { [weak self] in
            self?.mainThread.run { [weak self] in self?.refresh() }
        }
    }

    private func refresh() {
        guard isCurrent() else { return }
        if take.isPlaying && !takeBindingMatches { cancelTake() }
        if take.holdsCard && !take.isPlaying && model.state == .picker && !model.isResolvingBuiltins { cancelTake() }
        if observedFill !== model.fillModel {
            observedFill = model.fillModel
            clipboardSlip = model.fillModel.map {
                WishCardSlip.Content(mode: .fill, text: $0.builtinText(.clipboard), summary: $0.clipboardSummary)
            } ?? WishCardSlip.Content(mode: .thumbnail)
            editedFill = false
            inkGeneration &+= 1
            wasReady = model.fillModel?.deliverEnabled ?? false
            observedResolved = model.fillModel?.builtinsResolved ?? false
            wetFields = []
            drying = [:]
            inkRevisions = [:]
            nudgeIndex = nil
        } else if let fill = model.fillModel {
            if !observedResolved && fill.builtinsResolved {
                clipboardSlip = WishCardSlip.Content(mode: .fill, text: fill.builtinText(.clipboard), summary: fill.clipboardSummary)
            }
            if (observedResolved || editedFill) && fill.deliverEnabled && !wasReady {
                if !reduceMotion() { sheenRevision &+= 1 }
                playCue(.ready)
            }
            wasReady = fill.deliverEnabled
            observedResolved = fill.builtinsResolved
        }
        if model.state == .closed { cancelTake() }
        if observedFocus != model.fillModel?.focusIndex {
            observedFocus = model.fillModel?.focusIndex
            if nudgeIndex != observedFocus { nudgeIndex = nil }
        }
        syncStatus?.refreshBinding()
        let intent = model.state == .picker ? model.takeRequestedIntent() : nil
        if state != model.state { focusRevision &+= 1 }
        state = model.state // Republishes field values, selection and preview too.
        if let intent { requestedIntent(intent) }
    }

    func didShow() {
        guard isCurrent() else { return }
        cancelTake()
        proofShown = false
        syncStatus?.show()
        transientStatus = nil
        focusRevision &+= 1
    }

    func didHide() { cancelTake(); syncStatus?.hide() }
    func didLoseKey() { cancelTake() }

    func cancelTake() {
        take.cancel()
        takingFill = nil
        takingCard = nil
        takingSelection = nil
        takingValues = nil
        focusRevision &+= 1
    }

    func escape() {
        guard isCurrent() else { return }
        if take.holdsCard { cancelTake(); return }
        if proofShown { toggleProof(); return }
        model.escape()
    }

    func focusField(at index: Int) {
        guard isCurrent(), !take.holdsCard else { return }
        proofShown = false
        model.fillModel?.focusField(at: index)
        focusRevision &+= 1
    }

    func toggleProof() {
        guard isCurrent(), !take.holdsCard, model.state != .delivering else { return }
        proofShown.toggle()
        if proofShown { take.surface?.window?.makeFirstResponder(nil) }
        if !proofShown { focusRevision &+= 1 }
    }

    func setValue(_ value: String, field: FillFieldState) {
        guard isCurrent(), !take.holdsCard, let fill = model.fillModel, fill.state == .editing,
              let previous = fill.fields.first(where: { $0.name == field.name }) else { return }
        nudgeIndex = nil
        editedFill = true
        // Native edits can arrive before SwiftUI republishes the control's
        // captured field. Compare with Core's current value for sound feedback.
        if field.kind == .text, value.count > previous.value.count,
           value.split(whereSeparator: \.isWhitespace).count > previous.value.split(whereSeparator: \.isWhitespace).count {
            playCue(.tick)
        }
        if field.kind == .choice, value != previous.value { playCue(.tick) }
        let generation = inkGeneration
        let revision = (inkRevisions[field.name] ?? 0) &+ 1
        inkRevisions[field.name] = revision
        if !reduceMotion() { wetFields.insert(field.name); drying[field.name] = 0 }
        fill.setValue(value, name: field.name)
        guard !reduceMotion() else { return }
        for step in 1...10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * WishCardStyle.dry / 10) { [weak self] in
                guard let self, self.inkGeneration == generation,
                      self.inkRevisions[field.name] == revision else { return }
                self.drying[field.name] = Double(step) / 10
                if step == 10 { self.wetFields.remove(field.name); self.drying.removeValue(forKey: field.name) }
            }
        }
    }

    func inkPhase(_ name: String) -> WishInkPhase {
        guard !reduceMotion(), wetFields.contains(name) else { return .dry }
        return .drying(drying[name] ?? 0)
    }

    var gloss: String {
        guard let fill = model.fillModel else { return "" }
        if fill.builtinsResolved, case .blocked(let error, _) = fill.preview, nudgeIndex != nil || blockingIndex == nil {
            return error.description
        }
        guard let index = fill.focusIndex, fill.fields.indices.contains(index) else { return "" }
        let field = fill.fields[index]
        var note = field.description ?? ""
        if field.optional && field.value.isEmpty { note += note.isEmpty ? "Optional." : " Optional." }
        return field.label.uppercased() + (note.isEmpty ? "" : "  —  " + note)
    }

    private var blockingIndex: Int? {
        guard let fill = model.fillModel else { return nil }
        return fill.missingRequiredFieldIndex ?? fill.fields.firstIndex { field in
            field.kind == .choice && !field.value.isEmpty && !field.options.contains { $0.value == field.value }
        }
    }

    private var selectedIdentity: PromptIdentity? {
        guard let index = model.selectionIndex, model.results.indices.contains(index) else { return nil }
        return model.results[index].identity
    }

    private var takeBindingMatches: Bool {
        isCurrent() && model.fillModel === takingFill && model.selectedCard == takingCard
            && selectedIdentity == takingSelection && model.fillModel?.values == takingValues
            && (model.state == .picker || model.state == .fill)
    }

    func use(mode: DeliveryMode) {
        guard isCurrent(), !take.holdsCard else { return }
        if let fill = model.fillModel {
            guard fill.state == .editing, fill.builtinsResolved else { return }
            guard fill.deliverEnabled else {
                proofShown = false
                nudgeIndex = blockingIndex
                if let index = nudgeIndex { fill.focusField(at: index) }
                focusRevision &+= 1
                nudgeRevision &+= 1
                playCue(.nudge)
                return
            }
        } else {
            guard useEnabled else { return }
            guard model.selectedCard?.hasFields == false else { model.use(mode: mode); return }
        }
        proofShown = false
        takingFill = model.fillModel
        takingCard = model.selectedCard
        takingSelection = selectedIdentity
        takingValues = model.fillModel?.values
        let deliver: () -> Void = { [weak self] in
            guard let self, self.takeBindingMatches else { self?.cancelTake(); return }
            if let fill = self.model.fillModel { fill.deliver(mode: mode) }
            else { self.model.use(mode: mode) }
        }
        if reduceMotion() || !take.start(deliver: deliver) { deliver() }
    }

    /// This runs before marked-text and focused-button routing during a take.
    func interceptTakeKey(_ event: NSEvent) -> Bool {
        guard isCurrent(), take.holdsCard else { return false }
        guard take.isPlaying else { return true }
        if event.keyCode == 53 { cancelTake() }
        else if (event.keyCode == 36 || event.keyCode == 76) && !event.isARepeat { take.finish() }
        return true
    }

    func showSetup() { if isCurrent() { openSetup() } }
    func showSettings() { if isCurrent() { openSettings() } }

    deinit { syncStatus?.retire() }

    func setQuery(_ query: String) {
        guard isCurrent(), !take.holdsCard else { return }
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
        showsForgetValues && forgetValuesState != .delivering && !take.holdsCard
    }

    private var forgetValuesState: PickerModel.State {
        Self.forgetValuesState(picker: model.state, fill: model.fillModel?.state)
    }

    /// The action and its refusal copy must agree even if only the form is delivering.
    static func forgetValuesState(picker: PickerModel.State, fill: FillModel.State?) -> PickerModel.State {
        fill == .delivering ? .delivering : picker
    }

    func forgetSelectedValues() {
        guard isCurrent(), canForgetValues else { return }
        transientStatus = nil
        model.forgetSelectedValues()
        // A reset can return to the last rendered value before SwiftUI echoes
        // native typing. Invalidate controls even when their values compare equal.
        if model.forgetValuesError == nil { inputResetRevision &+= 1 }
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
        case .renderFailure(let error): return error.description
        }
    }

    /// Footer buttons perform the same intents as their keys.
    enum FooterAction: CaseIterable { case paste, copy, edit, library, deliver, copyFilled, back, proof }

    func perform(_ action: FooterAction) {
        guard isCurrent(), !take.holdsCard, model.state != .delivering else { return }
        switch action {
        case .paste: use(mode: .paste(.standard))
        case .copy: use(mode: .copyOnly)
        case .edit: model.editSelected()
        case .library: model.openLibrary()
        case .deliver:
            guard let fill = model.fillModel else { return }
            use(mode: fill.preferredMode)
        case .copyFilled:
            guard model.fillModel != nil else { return }
            use(mode: .copyOnly)
        case .back: escape()
        case .proof: toggleProof()
        }
    }

    var useEnabled: Bool {
        guard model.state == .picker, !model.isResolvingBuiltins,
              let position = model.selectionIndex, model.results.indices.contains(position) else { return false }
        return model.results[position].canRender
    }

    func route(_ event: NSEvent, fieldKind: FieldKind?) -> Bool {
        guard isCurrent() else { return false }
        if interceptTakeKey(event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "p" {
            toggleProof()
            return true
        }
        guard let intent = MacPickerKeys.intent(keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags,
            state: model.state, fieldKind: fieldKind) else { return false }
        switch intent {
        case .moveUp: model.moveSelection(.up)
        case .moveDown: model.moveSelection(.down)
        case .use(let mode): use(mode: mode)
        case .edit: model.editSelected()
        case .openLibrary: model.openLibrary()
        case .escape: escape()
        case .focusNext: model.fillModel?.focusNext()
        case .focusPrevious: model.fillModel?.focusPrevious()
        case .deliverPreferred:
            if let fill = model.fillModel { use(mode: fill.preferredMode) }
        case .deliver(let mode): use(mode: mode)
        }
        return true
    }
}
