#if os(Linux)
import CGtk
import MonkeysPawCore

/// A thin Setup view: all checks, fixes and verification flow through SetupModel.
final class LinuxSetupWindow {
    private let window: GTK.Widget
    private let model: SetupModel
    private var labels: [SetupRow.Kind: GTK.Widget] = [:]
    private var fixes: [SetupRow.Kind: GTK.Widget] = [:]
    private let report: GTK.Widget

    init(application: UnsafeMutablePointer<GtkApplication>, model: SetupModel) {
        self.model = model
        window = gtk_application_window_new(application)!
        report = GTK.label("")
        GTK.hideOnClose(window)
        gtk_window_set_title(mp_window(window), LinuxStrings.setup)
        gtk_window_set_default_size(mp_window(window), Int32(Limits.panelSize.width), Int32(Limits.panelSize.height))
        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!

        for kind in SetupRow.Kind.allCases {
            let label = GTK.label("")
            labels[kind] = label
            gtk_box_append(mp_box(content), label)
            let fix = GTK.button(LinuxStrings.fix) { [weak model] in model?.fix(kind) }
            fixes[kind] = fix
            gtk_box_append(mp_box(content), fix)
        }
        gtk_box_append(mp_box(content), GTK.button(LinuxStrings.verifyShortcut) { [weak model] in
            model?.beginHotkeyVerification()
        })
        gtk_box_append(mp_box(content), GTK.button(LinuxStrings.testPaste) { [weak model] in model?.runSelfTest() })
        gtk_box_append(mp_box(content), GTK.button(LinuxStrings.refresh) { [weak model] in model?.refresh() })
        gtk_box_append(mp_box(content), report)
        let scroller = gtk_scrolled_window_new()!
        // GtkScrolledWindow's upcast is private to this view's layout.
        gtk_scrolled_window_set_child(mp_scrolled_window(scroller), content)
        gtk_window_set_child(mp_window(window), scroller)

        model.onChange = { [weak self] in self?.render() }
        render()
    }

    func show() {
        model.refresh()
        gtk_window_present(mp_window(window))
    }

    private func render() {
        for row in model.rows {
            guard let label = labels[row.kind], let fix = fixes[row.kind] else { continue }
            let detail: String
            let needsFix: Bool
            switch row.status {
            case .ok:
                detail = LinuxStrings.ready
                needsFix = false
            case .notApplicable:
                detail = LinuxStrings.notApplicable
                needsFix = false
            case .unknown:
                detail = LinuxStrings.unknown
                needsFix = false
            case .needsAction(let text):
                detail = text
                needsFix = true
            }
            let registration = row.registration.map { " [\($0.mechanism.rawValue): \($0.detail)]" } ?? ""
            gtk_label_set_text(mp_label(label), LinuxStrings.rowTitle(row.kind) + ": " + detail + registration)
            let canConfigure = row.registration?.configuration != nil
            let title = canConfigure ? LinuxStrings.configureShortcuts
                : (row.kind == .portal || row.registration?.mechanism == .globalShortcutsPortal
                    ? LinuxStrings.allow : LinuxStrings.fix)
            gtk_button_set_label(mp_button(fix), title)
            gtk_widget_set_sensitive(fix, needsFix || canConfigure ? 1 : 0)
        }

        let text: String
        switch model.state {
        case .idle: text = ""
        case .testing: text = LinuxStrings.selfTestWorking
        case .tested(let result):
            text = result.results.map { item in
                let status: String
                switch item.status {
                case .pasted: status = "pasted"
                case .sentButNotReceived: status = "sent, but text was not received"
                case .failed(let reason): status = reason.rawValue
                }
                return item.backend.rawValue + ": " + status
            }.joined(separator: "\n")
        }
        gtk_label_set_text(mp_label(report), text)
    }
}
#endif
