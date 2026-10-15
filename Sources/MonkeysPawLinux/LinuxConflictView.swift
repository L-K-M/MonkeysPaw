#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// The model owns comparison and resolution. This view only renders UI-thread
/// publications and forwards explicit choices through Library's draft guard.
final class LinuxConflictView {
    enum RefreshReason { case requested, afterEditing }
    enum Teardown { case rebind, destroyed }
    let widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
    var onResolve: ((ConflictResolutionAction) -> Void)?
    var onChange: (() -> Void)?
    private weak var model: ConflictModel?
    private var observer: UUID?
    private var selection: LibraryPromptSelection?
    private var stamp: FileStamp?
    private var refreshPending = false
    private var opening = false
    private var available = true
    private var isDestroyed = false
    private var notice: String?
    private let status = GTK.label("")
    private let diff = LinuxDiffView(name: "conflict-diff", before: LinuxConflictStrings.serverVersion,
                                    after: LinuxConflictStrings.myVersion)
    private let keepServer = GTK.button(LinuxConflictStrings.keepServer) {}
    private let keepMine = GTK.button(LinuxConflictStrings.keepMine) {}
    private let keepBoth = GTK.button(LinuxConflictStrings.keepBoth) {}
    private let refresh = GTK.button(LinuxConflictStrings.refresh) {}

    var isResolving: Bool { selection != nil && model?.state.operation == .resolving }

    init() {
        gtk_widget_set_name(widget, "library-conflict")
        gtk_box_append(mp_box(widget), GTK.label(LinuxConflictStrings.title))
        let scroll = gtk_scrolled_window_new()!
        gtk_widget_set_size_request(scroll, -1, 240)
        gtk_widget_set_vexpand(scroll, 1)
        gtk_scrolled_window_set_child(mp_scrolled_window(scroll), diff.widget)
        gtk_box_append(mp_box(widget), scroll)
        gtk_widget_set_name(status, "conflict-status")
        gtk_label_set_selectable(mp_label(status), 1)
        gtk_box_append(mp_box(widget), status)
        let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        for (button, name, action) in [(keepServer, "keep-server", ConflictResolutionAction.keepServer),
                                      (keepMine, "keep-mine", .keepMine), (keepBoth, "keep-both", .keepBoth)] {
            gtk_widget_set_name(button, "conflict-" + name)
            GTK.onSignal(button, "clicked") { [weak self] in
                guard let self, self.canResolve(action) else { return }
                self.onResolve?(action)
            }
            gtk_box_append(mp_box(actions), button)
        }
        gtk_widget_set_name(refresh, "conflict-refresh")
        GTK.onSignal(refresh, "clicked") { [weak self] in self?.refreshComparison() }
        gtk_box_append(mp_box(actions), refresh)
        gtk_box_append(mp_box(widget), actions)
        gtk_widget_set_visible(widget, 0)
    }

    deinit { if let observer { model?.removeObserver(observer) } }

    func bind(model: ConflictModel?, selection: LibraryPromptSelection?, stamp: FileStamp?, available: Bool) {
        guard !isDestroyed else { return }
        if self.model !== model {
            close()
            if let observer { self.model?.removeObserver(observer) }
            self.model = model
            observer = model?.addObserver { [weak self, weak model] _ in
                guard let self, let model, !self.isDestroyed, self.model === model, self.selection != nil else { return }
                self.opening = false
                self.loadPending()
                self.render()
                self.onChange?()
            }
        }
        self.available = available
        guard let selection else { close(); return }
        if self.selection != selection || self.stamp != stamp {
            self.selection = selection
            self.stamp = stamp
            notice = nil
            refreshPending = true
        }
        gtk_widget_set_visible(widget, 1)
        loadPending()
        render()
    }

    func resolve(_ action: ConflictResolutionAction) {
        guard canResolve(action) else { return }
        notice = nil
        model?.resolve(action)
    }

    func refreshComparison(_ reason: RefreshReason = .requested) {
        guard !isDestroyed, available || reason == .afterEditing, selection != nil, model?.state.isBusy == false else { return }
        notice = reason == .afterEditing ? LinuxConflictStrings.chooseAgain : nil
        refreshPending = true
        loadPending()
    }

    func close() {
        guard !isDestroyed else { return }
        if selection != nil { model?.close() }
        selection = nil
        stamp = nil
        refreshPending = false
        opening = false
        notice = nil
        diff.update(nil)
        gtk_widget_set_visible(widget, 0)
    }

    func unbind(_ mode: Teardown = .rebind) {
        // Native destruction can precede Swift ownership teardown. Never touch
        // borrowed widgets after GTK has destroyed the window hierarchy.
        if mode == .destroyed { isDestroyed = true; model?.close() }
        else { close() }
        if let observer { model?.removeObserver(observer) }
        observer = nil
        model = nil
        selection = nil
        onResolve = nil
        onChange = nil
    }

    private func loadPending() {
        guard refreshPending, !opening, let selection, let model, !model.state.isBusy else { return }
        refreshPending = false
        opening = true
        model.open(selection)
    }

    private func canResolve(_ action: ConflictResolutionAction) -> Bool {
        guard !isDestroyed, available, !refreshPending, !opening, selection != nil,
              gtk_widget_get_visible(widget) != 0, let state = model?.state,
              state.preview?.copy == selection else { return false }
        switch action {
        case .keepServer: return state.canKeepServer
        case .keepMine: return state.canKeepMine
        case .keepBoth: return state.canKeepBoth
        }
    }

    private func render() {
        guard !isDestroyed, selection != nil else { return }
        let state = model?.state
        diff.update(refreshPending || opening || state?.preview?.copy != selection ? nil : state?.preview?.diff)
        let text: String
        if model == nil { text = LinuxConflictStrings.unavailable }
        else if state?.operation == .loading || refreshPending || opening { text = LinuxConflictStrings.loading }
        else if state?.operation == .resolving { text = LinuxConflictStrings.resolving }
        else if let failure = state?.error ?? state?.preview?.mineRefusal { text = LinuxConflictStrings.failure(failure) }
        else if let action = state?.resolved { text = LinuxConflictStrings.resolved(action) }
        else { text = notice ?? LinuxConflictStrings.choose }
        gtk_label_set_text(mp_label(status), text)
        gtk_widget_set_sensitive(keepServer, canResolve(.keepServer) ? 1 : 0)
        gtk_widget_set_sensitive(keepMine, canResolve(.keepMine) ? 1 : 0)
        gtk_widget_set_sensitive(keepBoth, canResolve(.keepBoth) ? 1 : 0)
        gtk_widget_set_sensitive(refresh, available && model != nil && state?.isBusy == false ? 1 : 0)
    }
}
#endif
