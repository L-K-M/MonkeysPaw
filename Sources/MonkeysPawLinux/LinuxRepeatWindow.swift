#if os(Linux)
import CGtk
import MonkeysPawCore

/// Refusals and persistence warnings do not open or reset hidden picker drafts.
final class LinuxRepeatWindow {
    private let window: GTK.Widget
    private let message: GTK.Widget
    private let reopen: GTK.Widget
    private let model: RepeatModel
    private var isDestroyed = false

    init(application: UnsafeMutablePointer<GtkApplication>, model: RepeatModel,
         openPrompt: @escaping (RepeatPromptReference) -> Void) {
        self.model = model
        window = gtk_application_window_new(application)!
        GTK.hideOnClose(window)
        gtk_window_set_title(mp_window(window), LinuxStrings.repeatLast)
        gtk_window_set_default_size(mp_window(window), Int32(Limits.panelSize.width), -1)
        let page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(page, 12) }
        message = GTK.label("")
        gtk_widget_set_name(message, "repeat-message")
        gtk_box_append(mp_box(page), message)
        reopen = GTK.button(LinuxStrings.openRepeatPrompt) { [weak model] in
            guard let model, case .reviewRequired(let reference, _) = model.result else { return }
            openPrompt(reference)
        }
        gtk_widget_set_name(reopen, "repeat-open-prompt")
        gtk_box_append(mp_box(page), reopen)
        gtk_window_set_child(mp_window(window), page)
        GTK.onSignal(window, "destroy") { [weak self] in self?.isDestroyed = true }
        GTK.onSignal(reopen, "clicked") { [weak self] in self?.hide() }
    }

    func showResult(activationToken: String?) {
        guard !isDestroyed, let result = model.result,
              let text = LinuxStrings.repeatMessage(result) else { return }
        gtk_label_set_text(mp_label(message), text)
        let canReopen: Bool
        if case .reviewRequired = result { canReopen = true } else { canReopen = false }
        gtk_widget_set_visible(reopen, canReopen ? 1 : 0)
        if let activationToken { gtk_window_set_startup_id(mp_window(window), activationToken) }
        gtk_window_present(mp_window(window))
    }

    func hide() {
        guard !isDestroyed else { return }
        gtk_widget_set_visible(window, 0)
    }

    func tearDown() {
        guard !isDestroyed else { return }
        gtk_window_destroy(mp_window(window))
        isDestroyed = true
    }
}
#endif
