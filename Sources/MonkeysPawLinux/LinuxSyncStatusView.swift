#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Independent subscriptions let the picker and Library share the model.
/// Only explicit actions navigate; reports never present or focus a window.
final class LinuxSyncStatusView {
    enum Surface { case picker, library }
    enum Teardown { case rebind, destroyed }
    let widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
    private let surface: Surface
    private let summary = GTK.label("")
    private let lastSuccess = GTK.label("")
    private let message = GTK.label("")
    private let primary = GTK.button("") {}
    private let syncNow = GTK.button(LinuxSyncStatusStrings.syncNow) {}
    private let errors = GTK.button(LinuxSyncStatusStrings.errors) {}
    private let conflicts = GTK.button(LinuxSyncStatusStrings.conflicts) {}
    private let details: GTK.Widget?
    private let detailsScroll: GTK.Widget?
    private weak var model: SyncStatusModel?
    private var observer: UUID?
    private var active = false
    private var destroyed = false
    private var renderedErrors: [SyncStatusFileError]?
    private var navigate: ((SyncStatusAction) -> Void)?
    private var openFile: ((RelativePath) -> Void)?

    init(surface: Surface) {
        self.surface = surface
        details = surface == .library ? gtk_box_new(GTK_ORIENTATION_VERTICAL, 4) : nil
        detailsScroll = surface == .library ? gtk_scrolled_window_new() : nil
        let prefix = surface == .picker ? "picker-sync" : "library-sync"
        gtk_widget_set_name(widget, prefix)
        let footer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        let menu = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(mp_menu_button(menu), "view-more-symbolic")
        mp_accessible_label(menu, LinuxSyncStatusStrings.actions)
        gtk_widget_add_css_class(menu, "flat")
        let popover = gtk_popover_new()!
        let contents = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(contents, 8) }
        gtk_popover_set_child(mp_popover(popover), contents)
        gtk_menu_button_set_popover(mp_menu_button(menu), popover)
        gtk_widget_add_css_class(summary, "dim-label")
        gtk_widget_add_css_class(summary, "caption")
        gtk_widget_set_hexpand(summary, 1)
        gtk_box_append(mp_box(footer), summary)
        gtk_box_append(mp_box(footer), menu)
        gtk_box_append(mp_box(widget), footer)
        for (child, suffix) in [(summary, "summary"), (lastSuccess, "last-success"), (message, "message")] {
            gtk_widget_set_name(child, prefix + "-" + suffix)
            if child != summary { gtk_box_append(mp_box(contents), child) }
        }
        let actions = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
        for (button, suffix) in [(primary, "action"), (syncNow, "now"), (errors, "errors"), (conflicts, "conflicts")] {
            gtk_widget_set_name(button, prefix + "-" + suffix)
            gtk_box_append(mp_box(actions), button)
        }
        GTK.onSignal(primary, "clicked") { [weak self] in
            guard let self, let state = self.model?.state else { return }
            self.perform(state.action)
        }
        GTK.onSignal(syncNow, "clicked") { [weak self] in self?.perform(.syncNow) }
        GTK.onSignal(errors, "clicked") { [weak self] in self?.perform(.errors) }
        GTK.onSignal(conflicts, "clicked") { [weak self] in self?.perform(.conflicts) }
        gtk_box_append(mp_box(contents), actions)
        if let details, let detailsScroll {
            gtk_widget_set_name(details, prefix + "-file-errors")
            gtk_scrolled_window_set_policy(mp_scrolled_window(detailsScroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_min_content_height(mp_scrolled_window(detailsScroll), 100)
            gtk_scrolled_window_set_max_content_height(mp_scrolled_window(detailsScroll), 180)
            gtk_scrolled_window_set_propagate_natural_height(mp_scrolled_window(detailsScroll), 1)
            gtk_scrolled_window_set_child(mp_scrolled_window(detailsScroll), details)
            gtk_box_append(mp_box(widget), detailsScroll)
            let dismiss = GTK.button(LinuxSyncStatusStrings.hideErrors) { [weak self] in
                guard let self, self.active, !self.destroyed else { return }
                self.model?.dismissErrorDetails()
            }
            gtk_widget_set_name(dismiss, prefix + "-hide-errors")
            gtk_box_append(mp_box(details), dismiss)
        }
    }

    deinit { suspend() }

    func bind(_ model: SyncStatusModel?, navigate: @escaping (SyncStatusAction) -> Void,
              openFile: ((RelativePath) -> Void)? = nil) {
        guard !destroyed else { return }
        suspend()
        self.model = model
        self.navigate = navigate
        self.openFile = openFile
        renderedErrors = nil
    }

    func show() {
        guard !destroyed else { return }
        active = true
        if observer == nil, let model {
            observer = model.addObserver { [weak self, weak model] _ in
                guard let self, let model, self.active, !self.destroyed, self.model === model else { return }
                self.render()
            }
        }
        render()
    }

    func suspend() {
        active = false
        if let observer { model?.removeObserver(observer) }
        observer = nil
    }

    func retire(_ mode: Teardown = .rebind) {
        suspend()
        if mode == .destroyed { destroyed = true }
        model = nil
        navigate = nil
        openFile = nil
    }

    private func perform(_ action: SyncStatusAction) {
        guard active, !destroyed, let model else { return }
        switch action {
        case .syncNow:
            if model.state.footer == .needsSignIn { navigate?(.account) }
            else if model.state.canSyncNow { model.syncNow() }
        case .errors:
            model.showErrorDetails()
            if surface == .picker { navigate?(.errors) }
        case .conflicts:
            if model.state.counts.conflicts > 0 { navigate?(.conflicts) }
        case .account: navigate?(.account)
        case .none: break
        }
    }

    private func render() {
        guard active, !destroyed else { return }
        let state = model?.state
        gtk_label_set_text(mp_label(summary), state.map(LinuxSyncStatusStrings.summary) ?? LinuxSyncStatusStrings.unavailable)
        gtk_label_set_text(mp_label(lastSuccess), LinuxSyncStatusStrings.lastSuccess(state?.lastSuccess))
        gtk_label_set_text(mp_label(message), state?.errorMessage ?? "")
        gtk_widget_set_visible(message, state?.errorMessage == nil ? 0 : 1)
        let action = state?.action ?? .none
        gtk_button_set_label(mp_button(primary), LinuxSyncStatusStrings.action(action))
        gtk_widget_set_visible(primary, action == .none ? 0 : 1)
        gtk_widget_set_visible(syncNow, state?.canSyncNow == true && action != .syncNow ? 1 : 0)
        gtk_widget_set_visible(errors, state?.fileErrors.isEmpty == false && action != .errors ? 1 : 0)
        gtk_widget_set_visible(conflicts, (state?.counts.conflicts ?? 0) > 0 && action != .conflicts ? 1 : 0)
        guard let details, let detailsScroll else { return }
        gtk_widget_set_visible(detailsScroll, state?.showsErrorDetails == true ? 1 : 0)
        let fileErrors = state?.fileErrors ?? []
        guard renderedErrors != fileErrors else { return }
        renderedErrors = fileErrors
        // Keep the dismiss control stable across reports and keyboard use.
        while let child = gtk_widget_get_next_sibling(gtk_widget_get_first_child(details)) {
            gtk_box_remove(mp_box(details), child)
        }
        if fileErrors.isEmpty { gtk_box_append(mp_box(details), GTK.label(LinuxSyncStatusStrings.noFileErrors)) }
        for error in fileErrors {
            let row = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
            let button = GTK.button(error.path.string) { [weak self] in
                guard let self, self.active, !self.destroyed,
                      self.model?.state.fileErrors.contains(error) == true else { return }
                self.openFile?(error.path)
            }
            if let label = gtk_button_get_child(mp_button(button)) {
                gtk_label_set_ellipsize(mp_label(label), PANGO_ELLIPSIZE_END)
                gtk_label_set_xalign(mp_label(label), 0)
            }
            gtk_widget_set_tooltip_text(button, error.path.string)
            mp_accessible_label(button, error.path.string + ". " + error.reason)
            gtk_box_append(mp_box(row), button)
            gtk_box_append(mp_box(row), GTK.label(error.reason))
            gtk_box_append(mp_box(details), row)
        }
    }
}
#endif
