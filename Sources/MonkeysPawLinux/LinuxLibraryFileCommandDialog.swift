#if os(Linux)
import CGtk
import MonkeysPawCore

enum LinuxLibraryFileCommand: CaseIterable {
    case rename, move, delete

    var label: String {
        switch self {
        case .rename: return LinuxEditorStrings.rename
        case .move: return LinuxEditorStrings.move
        case .delete: return LinuxEditorStrings.delete
        }
    }

    var buttonTitle: String {
        switch self {
        case .rename: return LinuxEditorStrings.renameButton
        case .move: return LinuxEditorStrings.moveButton
        case .delete: return LinuxEditorStrings.deleteButton
        }
    }

    var success: String {
        switch self {
        case .rename: return LinuxEditorStrings.renamed
        case .move: return LinuxEditorStrings.moved
        case .delete: return LinuxEditorStrings.deleted
        }
    }
}

/// Modal forms use GTK 4.8 controls and return input to the editor intent.
final class LinuxLibraryFileCommandDialog {
    private let window: GTK.Widget
    private var isDestroyed = false
    private var hasResponded = false
    private var hasPreedit = false

    init(parent: GTK.Widget, command: LinuxLibraryFileCommand, prompt: LibraryPromptSelection,
         folders: [String], respond: @escaping (String?) -> Void) {
        window = gtk_window_new()!
        gtk_widget_set_name(window, "library-file-command-dialog")
        let path = prompt.relativePath.string
        let slash = path.unicodeScalars.lastIndex(of: "/")
        let filename = slash.map { String(path[path.unicodeScalars.index(after: $0)...]) } ?? path
        let folder = slash.map { String(path[..<$0]) } ?? ""
        let title: String
        let hint: String
        switch command {
        case .rename: title = LinuxEditorStrings.renameTitle; hint = LinuxEditorStrings.renameHint
        case .move: title = LinuxEditorStrings.moveTitle; hint = LinuxEditorStrings.moveHint
        case .delete: title = LinuxEditorStrings.deleteTitle(path); hint = LinuxEditorStrings.deleteHint(path)
        }
        gtk_window_set_title(mp_window(window), title)
        gtk_window_set_transient_for(mp_window(window), mp_window(parent))
        gtk_window_set_modal(mp_window(window), 1)
        gtk_window_set_destroy_with_parent(mp_window(window), 1)
        GTK.onSignal(window, "destroy") { [weak self] in self?.isDestroyed = true }
        let respondOnce: (String?) -> Void = { [weak self] text in
            guard let self, !self.isDestroyed, !self.hasResponded else { return }
            self.hasResponded = true
            respond(text)
        }
        GTK.onCloseRequested(window) { respondOnce(nil) }
        GTK.observeKeys(window) { [weak self] key, modifiers in
            let relevant = GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue
                | GDK_SUPER_MASK.rawValue | GDK_META_MASK.rawValue | GDK_HYPER_MASK.rawValue
            guard self?.hasPreedit == false, key == UInt32(GDK_KEY_Escape), modifiers & relevant == 0 else { return false }
            respondOnce(nil)
            return true
        }
        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(content, 16) }
        let message = GTK.label(hint)
        gtk_widget_set_name(message, "library-command-message")
        gtk_label_set_max_width_chars(mp_label(message), 64)
        gtk_box_append(mp_box(content), message)
        let input: GTK.Widget?
        if command == .delete { input = nil }
        else {
            let entry = gtk_entry_new()!
            input = entry
            let label = command == .rename ? LinuxEditorStrings.filename : LinuxEditorStrings.folder
            gtk_widget_set_name(entry, "library-command-input")
            mp_accessible_label(entry, label)
            gtk_box_append(mp_box(content), GTK.label(label))
            mp_entry_set_text(entry, command == .rename ? filename : folder)
            gtk_box_append(mp_box(content), entry)
            if let delegate = mp_entry_text_delegate(entry) {
                GTK.onPreeditChanged(delegate) { [weak self] active in self?.hasPreedit = active }
            }
            GTK.onSignal(entry, "activate") { respondOnce(String(cString: mp_entry_text(entry))) }
            if command == .move {
                let chooser = gtk_combo_box_text_new()!
                gtk_widget_set_name(chooser, "library-command-folders")
                mp_accessible_label(chooser, LinuxEditorStrings.existingFolders)
                gtk_combo_box_text_append_text(mp_combo_box_text(chooser), LinuxEditorStrings.rootFolder)
                for folder in folders { gtk_combo_box_text_append_text(mp_combo_box_text(chooser), folder) }
                let options = [""] + folders
                gtk_combo_box_set_active(mp_combo_box(chooser), Int32(options.firstIndex { $0.utf8.elementsEqual(folder.utf8) } ?? -1))
                GTK.onSignal(chooser, "changed") {
                    let position = Int(gtk_combo_box_get_active(mp_combo_box(chooser)))
                    guard options.indices.contains(position) else { return }
                    mp_entry_set_text(entry, options[position])
                }
                gtk_box_append(mp_box(content), chooser)
            }
        }
        let buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let cancel = GTK.button(LinuxEditorStrings.cancel) { respondOnce(nil) }
        gtk_widget_set_name(cancel, "library-command-cancel")
        let confirm = GTK.button(command.buttonTitle) {
            respondOnce(input.map { String(cString: mp_entry_text($0)) } ?? "")
        }
        gtk_widget_set_name(confirm, "library-command-confirm")
        if command == .delete { gtk_widget_add_css_class(confirm, "destructive-action") }
        gtk_box_append(mp_box(buttons), cancel)
        gtk_box_append(mp_box(buttons), confirm)
        gtk_box_append(mp_box(content), buttons)
        gtk_window_set_child(mp_window(window), content)
        gtk_window_present(mp_window(window))
        gtk_widget_grab_focus(input ?? cancel)
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        gtk_window_destroy(mp_window(window))
    }
}
#endif
