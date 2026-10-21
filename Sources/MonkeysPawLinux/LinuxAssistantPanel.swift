#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// A view of one editor session's AssistantModel. GTK owns all widgets;
/// retirement removes timers and callbacks before borrowed pointers expire.
final class LinuxAssistantPanel {
    enum Flow { case write, review, improve }
    let widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
    var onHighlight: ((Range<Int>?) -> Void)?
    var onOutcome: ((AssistantAcceptanceOutcome) -> Void)?
    var onAvailabilityChange: (() -> Void)?
    private weak var model: AssistantModel?
    private weak var editor: EditorModel?
    private var available = true
    private var isDestroyed = false
    private var isRendering = false
    private var flow: Flow?
    private var timer: guint?
    private var renderedReview: LlmReview?
    private var checks: [GTK.Widget] = []
    private var quoteButtons: [GTK.Widget] = []
    private var highlightedFinding: Int?
    private var renderedArtifact: LlmArtifact?
    private var preeditEntries = Set<GTK.Widget>()

    private let brief = gtk_entry_new()!
    private let instruction = gtk_entry_new()!
    private let feedback = gtk_entry_new()!
    private let findings = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
    private let summary = GTK.label("")
    private let draft = gtk_text_view_new()!
    private let notes = GTK.label("")
    private let issues = GTK.label("")
    private let explanation = GTK.label("")
    private let status = GTK.label("")
    private let footer = GTK.label("")
    private let diff = LinuxDiffView()
    private var write: GTK.Widget!
    private var review: GTK.Widget!
    private var improve: GTK.Widget!
    private var showDiff: GTK.Widget!
    private var accept: GTK.Widget!
    private var reject: GTK.Widget!
    private var retry: GTK.Widget!
    private var cancel: GTK.Widget!

    var isVisible: Bool { !isDestroyed && gtk_widget_get_visible(widget) != 0 }

    var hasPreedit: Bool {
        guard isVisible, let root = gtk_widget_get_root(widget), let focus = gtk_root_get_focus(root) else { return false }
        return preeditEntries.contains { focus == $0 || gtk_widget_is_ancestor(focus, $0) != 0 }
    }

    init() {
        gtk_widget_set_name(widget, "library-assistant-panel")
        let heading = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let title = GTK.label(LinuxAssistantStrings.title)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(mp_box(heading), title)
        let close = GTK.button("Close Assistant") { [weak self] in self?.close() }
        gtk_widget_set_name(close, "assistant-close")
        gtk_box_append(mp_box(heading), close)
        gtk_box_append(mp_box(widget), heading)
        let page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        let scroll = gtk_scrolled_window_new()!
        gtk_widget_set_size_request(scroll, -1, 240)
        gtk_widget_set_vexpand(scroll, 1)
        gtk_scrolled_window_set_child(mp_scrolled_window(scroll), page)
        gtk_box_append(mp_box(widget), scroll)
        for (entry, name, title) in [(brief, "brief", "Write brief"), (instruction, "instruction", "Improve instruction"),
                                     (feedback, "feedback", "Retry feedback")] {
            gtk_widget_set_name(entry, "assistant-" + name)
            gtk_entry_set_placeholder_text(mp_entry(entry), title)
            mp_accessible_label(entry, title)
            if let delegate = mp_entry_text_delegate(entry) {
                GTK.onPreeditChanged(delegate) { [weak self] active in
                    guard let self else { return }
                    if active { self.preeditEntries.insert(entry) }
                    else { self.preeditEntries.remove(entry) }
                    self.onAvailabilityChange?()
                }
            }
        }
        gtk_box_append(mp_box(page), brief)
        let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        write = button("write", "Write", in: actions) { $0.start(.write) }
        review = button("review", "Review", in: actions) { $0.start(.review) }
        improve = button("improve", "Improve", in: actions) { $0.start(.improve) }
        gtk_box_append(mp_box(page), actions)
        gtk_box_append(mp_box(page), instruction)
        GTK.onSignal(UnsafeMutableRawPointer(instruction), "changed") { [weak self] in
            guard let self, !self.isRendering, self.isVisible else { return }
            self.model?.editInstruction(String(cString: mp_entry_text(self.instruction)))
        }
        for (label, name) in [(explanation, "explanation"), (status, "status"), (summary, "review-summary")] {
            gtk_widget_set_name(label, "assistant-" + name)
            gtk_box_append(mp_box(page), label)
        }
        gtk_widget_set_name(findings, "assistant-findings")
        gtk_box_append(mp_box(page), findings)
        gtk_widget_set_name(draft, "assistant-draft")
        mp_accessible_label(draft, "Generated draft")
        gtk_text_view_set_editable(mp_text_view(draft), 0)
        gtk_text_view_set_monospace(mp_text_view(draft), 1)
        gtk_text_view_set_wrap_mode(mp_text_view(draft), GTK_WRAP_WORD_CHAR)
        gtk_box_append(mp_box(page), draft)
        gtk_widget_set_name(notes, "assistant-notes")
        gtk_box_append(mp_box(page), notes)
        gtk_box_append(mp_box(page), diff.widget)
        gtk_widget_set_name(issues, "assistant-issues")
        gtk_label_set_selectable(mp_label(issues), 1)
        gtk_box_append(mp_box(page), issues)
        let decisions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        showDiff = button("show-diff", "Show diff", in: decisions) { $0.model?.showDiff() }
        accept = button("accept", "Accept", in: decisions) { $0.acceptCandidate() }
        reject = button("reject", "Reject", in: decisions) { $0.reset(.reject) }
        cancel = button("cancel", "Cancel", in: decisions) { $0.reset(.cancel) }
        gtk_box_append(mp_box(page), decisions)
        gtk_box_append(mp_box(page), feedback)
        retry = button("retry", "Retry with feedback", in: page) {
            $0.onHighlight?(nil)
            $0.model?.retryWithFeedback(String(cString: mp_entry_text($0.feedback)))
        }
        gtk_widget_set_name(footer, "assistant-footer")
        gtk_box_append(mp_box(widget), footer)
        gtk_widget_set_visible(widget, 0)
    }

    deinit { stopTimer(); model?.onChange = nil }

    func bind(model: AssistantModel?, editor: EditorModel, available: Bool) {
        guard !isDestroyed else { return }
        if self.model !== model {
            self.model?.onChange = nil
            stopTimer()
            self.model = nil
            flow = nil
            highlightedFinding = nil
            preeditEntries.removeAll()
            onHighlight?(nil)
            mp_entry_set_text(brief, "")
            mp_entry_set_text(feedback, "")
            mp_entry_set_text(instruction, "")
            self.model = model
            model?.onChange = { [weak self, weak model] in
                guard let self, let model, !self.isDestroyed, self.model === model else { return }
                self.render()
            }
        }
        self.editor = editor
        self.available = available
        if isVisible { render() }
    }

    func show() {
        guard !isDestroyed else { return }
        model?.contextChanged()
        gtk_widget_set_visible(widget, 1)
        render()
    }

    func close() {
        guard !isDestroyed else { return }
        model?.close()
        stopTimer()
        flow = nil
        highlightedFinding = nil
        preeditEntries.removeAll()
        onHighlight?(nil)
        mp_entry_set_text(brief, "")
        mp_entry_set_text(instruction, "")
        mp_entry_set_text(feedback, "")
        gtk_widget_set_visible(widget, 0)
    }

    func retire(destroyed: Bool) {
        if destroyed {
            isDestroyed = true
            model?.close()
            if highlightedFinding != nil { onHighlight?(nil) }
            highlightedFinding = nil
        } else { close() }
        stopTimer()
        model?.onChange = nil
        model = nil
        editor = nil
        onOutcome = nil
        if destroyed { onHighlight = nil }
    }

    @discardableResult
    func start(_ flow: Flow) -> Bool {
        guard !isDestroyed, let model else { return false }
        model.contextChanged()
        guard canStart(flow) else { return false }
        gtk_widget_set_visible(widget, 1)
        self.flow = flow
        highlightedFinding = nil
        onHighlight?(nil)
        switch flow {
        case .write: model.write(brief: String(cString: mp_entry_text(brief)))
        case .review: model.review()
        case .improve: model.improve()
        }
        render()
        return true
    }

    func canStart(_ flow: Flow) -> Bool {
        guard !isDestroyed, let model, let editor,
              commonRefusal(model.state, editor.state) == nil else { return false }
        return flow == .write || templateRefusal(editor.state) == nil
    }

    private enum Reset { case cancel, reject }
    private func reset(_ intent: Reset) {
        if intent == .reject { model?.reject() } else { model?.cancel() }
        flow = nil
        highlightedFinding = nil
        onHighlight?(nil)
        stopTimer()
        render()
    }

    private func acceptCandidate() {
        guard let model, let editor, model.canAccept else { return }
        // Keep the authoritative outcome callback even if adoption retires the
        // Assistant session. The Library binding checks its graph generation.
        let report = onOutcome
        let session = editor.assistantSnapshot?.session
        model.accept(using: editor) { [weak editor] outcome in
            guard outcome.committed != nil || editor?.assistantSnapshot?.session == session else { return }
            report?(outcome)
        }
    }

    private func render() {
        guard !isDestroyed, isVisible, let model, let editor else { return }
        isRendering = true
        defer { isRendering = false }
        let state = model.state
        let editorState = editor.state
        let common = commonRefusal(state, editorState)
        let template = templateRefusal(editorState)
        var messages = [common, template].compactMap { $0 }
        if state.mutationAccess == .privateCopy { messages.append(LinuxAssistantStrings.viewer) }
        if state.isStale { messages.append(LinuxAssistantStrings.stale) }
        setLabel(explanation, messages.joined(separator: "\n"))
        setLabel(status, state.acceptanceOutcome.map(LinuxAssistantStrings.outcome)
            ?? state.failure.map(LinuxAssistantStrings.failure) ?? LinuxAssistantStrings.phase(state))
        setLabel(footer, LinuxAssistantStrings.footer(state))
        if !String(cString: mp_entry_text(instruction)).utf8.elementsEqual(state.instruction.utf8) {
            mp_entry_set_text(instruction, state.instruction)
        }
        let improveTitle = state.mutationAccess == .privateCopy ? "Improve a private copy" : "Improve"
        gtk_button_set_label(mp_button(improve), improveTitle)
        mp_accessible_label(improve, improveTitle)
        gtk_widget_set_sensitive(write, common == nil ? 1 : 0)
        for control in [review!, improve!] { gtk_widget_set_sensitive(control, common == nil && template == nil ? 1 : 0) }
        let editorIO = editorState.status == .loading || editorState.status == .saving || editorState.status == .commandRunning
        gtk_widget_set_sensitive(accept, available && !editorIO && state.phase != .working && model.canAccept ? 1 : 0)
        gtk_widget_set_sensitive(showDiff, common == nil && state.artifact != nil && (flow == .write || template == nil) ? 1 : 0)
        gtk_widget_set_sensitive(retry, common == nil && flow != nil && state.phase != .idle && (flow == .write || template == nil) ? 1 : 0)
        gtk_widget_set_sensitive(reject, state.artifact != nil || state.review != nil ? 1 : 0)
        gtk_widget_set_sensitive(cancel, state.phase == .working || state.isAccepting ? 1 : 0)
        renderFindings(state, model: model)
        renderDraft(state.artifact, hasDiff: state.diff != nil)
        onAvailabilityChange?()
        diff.update(state.diff)
        let warnings = state.diff?.placeholderWarnings.map(LinuxAssistantStrings.placeholder) ?? []
        setLabel(issues, (state.issues.map(LinuxEditorStrings.issue) + warnings).joined(separator: "\n"))
        if let highlightedFinding, state.phase == .working || model.highlightFinding(at: highlightedFinding) == nil {
            self.highlightedFinding = nil
            onHighlight?(nil)
        }
        if state.phase == .working { startTimer() } else { stopTimer() }
    }

    private func commonRefusal(_ state: AssistantState, _ editor: EditorState) -> String? {
        if !available || state.mutationAccess == .unavailable { return LinuxAssistantStrings.unavailable }
        if state.providerHost == nil || state.modelID == nil { return LinuxAssistantStrings.setup }
        if state.phase == .working || state.isAccepting { return LinuxAssistantStrings.waitingForAction }
        if editor.conflict != nil { return LinuxAssistantStrings.conflict }
        if editor.status == .loading || editor.status == .saving || editor.status == .commandRunning
            || editor.pendingDecision != nil || !editor.queuedActions.isEmpty { return LinuxAssistantStrings.busy }
        return nil
    }

    private func templateRefusal(_ state: EditorState) -> String? {
        if let reason = state.readOnlyReason { return LinuxEditorStrings.readOnly(reason) }
        if state.prompt == nil || state.source == nil { return LinuxAssistantStrings.noEditor }
        if state.isPrivate { return LinuxAssistantStrings.privatePrompt }
        if state.issues.contains(where: { $0.severity == .error }) { return LinuxAssistantStrings.fixValidationErrors }
        return nil
    }

    private func renderFindings(_ state: AssistantState, model: AssistantModel) {
        setLabel(summary, state.review?.summary ?? "")
        if renderedReview != state.review {
            renderedReview = state.review
            checks = []
            quoteButtons = []
            while let child = gtk_widget_get_first_child(findings) { gtk_box_remove(mp_box(findings), child) }
            for (index, finding) in (state.review?.findings ?? []).enumerated() {
                let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
                let check = gtk_check_button_new_with_label("\(finding.severity.rawValue.capitalized) · \(finding.criterion.rawValue)")!
                gtk_widget_set_name(check, "assistant-finding-\(index)")
                GTK.onSignal(check, "toggled") { [weak self] in
                    guard let self, !self.isRendering, self.isVisible else { return }
                    self.model?.toggleFinding(at: index)
                }
                checks.append(check)
                gtk_box_append(mp_box(box), check)
                gtk_box_append(mp_box(box), GTK.label(finding.problem + "\n" + finding.suggestion))
                gtk_box_append(mp_box(box), GTK.label(finding.quote))
                let quote = GTK.button("Highlight quote") { [weak self] in
                    guard let self, self.isVisible else { return }
                    self.highlightedFinding = index
                    self.onHighlight?(self.model?.highlightFinding(at: index))
                }
                gtk_widget_set_name(quote, "assistant-quote-\(index)")
                quoteButtons.append(quote)
                gtk_box_append(mp_box(box), quote)
                if case .unmatched = finding.quoteMatch { gtk_box_append(mp_box(box), GTK.label("Quote not found in the reviewed source.")) }
                gtk_box_append(mp_box(findings), box)
            }
        }
        for (index, check) in checks.enumerated() {
            gtk_check_button_set_active(mp_check_button(check), state.selectedFindings.contains(index) ? 1 : 0)
            gtk_widget_set_sensitive(check, state.phase != .working && !state.isStale ? 1 : 0)
            gtk_widget_set_sensitive(quoteButtons[index], state.phase != .working && model.highlightFinding(at: index) != nil ? 1 : 0)
        }
    }

    private func renderDraft(_ artifact: LlmArtifact?, hasDiff: Bool) {
        if renderedArtifact != artifact {
            renderedArtifact = artifact
            let text = artifact.map { value in
                "Title: \(value.title)\nDescription: \(value.description)\nTags: \(value.tags.joined(separator: ", "))\nFields: "
                    + value.fields.map { "\($0.name) (\($0.type.rawValue))" }.joined(separator: ", ") + "\n\n" + value.body
            } ?? ""
            gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(draft)), text, Int32(text.utf8.count))
        }
        gtk_widget_set_visible(draft, artifact != nil && !hasDiff ? 1 : 0)
        setLabel(notes, artifact?.notes ?? "")
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = GTK.after(1) { [weak self, weak model] in
            guard let self else { return }
            self.timer = nil
            guard !self.isDestroyed, self.isVisible, let model, self.model === model, model.state.phase == .working else { return }
            model.updateElapsed()
        }
    }

    private func stopTimer() {
        if let timer { g_source_remove(timer); self.timer = nil }
    }

    private func setLabel(_ label: GTK.Widget, _ text: String) {
        gtk_label_set_text(mp_label(label), text)
        gtk_widget_set_visible(label, text.isEmpty ? 0 : 1)
    }

    private func button(_ name: String, _ title: String, in box: GTK.Widget,
                        action: @escaping (LinuxAssistantPanel) -> Void) -> GTK.Widget {
        let button = GTK.button(title) { [weak self] in
            guard let self, self.isVisible else { return }
            action(self)
        }
        gtk_widget_set_name(button, "assistant-" + name)
        mp_accessible_label(button, title)
        gtk_box_append(mp_box(box), button)
        return button
    }
}
#endif
