#if os(Linux)
import CGtk
import Foundation

enum LinuxImportSelectionMode: Equatable { case files, folder }

/// Native UI seam. GTK 4.8 needs SELECT_FOLDER to actually accept a folder.
protocol LinuxImportChoosing: AnyObject {
    func choose(parent: GTK.Widget, mode: LinuxImportSelectionMode, done: @escaping ([URL]) -> Void)
    func cancel()
}

final class GTKImportChooser: LinuxImportChoosing {
    private var dialog: OpaquePointer?
    private var completion: (([URL]) -> Void)?
    private let showDialog: (OpaquePointer) -> Void

    init(showDialog: @escaping (OpaquePointer) -> Void = { gtk_native_dialog_show(mp_native_dialog($0)) }) {
        self.showDialog = showDialog
    }

    deinit { cancel() }

    func choose(parent: GTK.Widget, mode: LinuxImportSelectionMode, done: @escaping ([URL]) -> Void) {
        cancel()
        let action = mode == .files ? GTK_FILE_CHOOSER_ACTION_OPEN : GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER
        let title = mode == .files ? LinuxImportStrings.chooseFiles : LinuxImportStrings.chooseFolder
        guard let dialog = gtk_file_chooser_native_new(title, mp_window(parent), action,
            LinuxImportStrings.importAction, LinuxStrings.cancel) else { done([]); return }
        self.dialog = dialog
        completion = done
        let chooser = mp_file_chooser(dialog)
        gtk_file_chooser_set_select_multiple(chooser, mode == .files ? 1 : 0)
        gtk_file_chooser_set_create_folders(chooser, 0)
        if mode == .files, let filter = gtk_file_filter_new() {
            gtk_file_filter_set_name(filter, LinuxImportStrings.fileTypes)
            for pattern in ["*.md", "*.prompt", "*.prompty"] { gtk_file_filter_add_pattern(filter, pattern) }
            gtk_file_chooser_add_filter(chooser, filter)
            gtk_file_chooser_set_filter(chooser, filter)
            g_object_unref(UnsafeMutableRawPointer(filter))
        }
        gtk_native_dialog_set_modal(mp_native_dialog(dialog), 1)
        GTK.onResponse(UnsafeMutableRawPointer(dialog)) { [weak self] response in
            guard let self, self.dialog == dialog else { return }
            self.respond(response)
        }
        showDialog(dialog)
    }

    func cancel() {
        guard let dialog else { return }
        self.dialog = nil
        completion = nil
        gtk_native_dialog_destroy(mp_native_dialog(dialog))
        g_object_unref(UnsafeMutableRawPointer(dialog))
    }

    private func respond(_ response: Int32) {
        guard let dialog else { return }
        var urls: [URL] = []
        if response == GTK_RESPONSE_ACCEPT.rawValue, let files = gtk_file_chooser_get_files(mp_file_chooser(dialog)) {
            defer { g_object_unref(UnsafeMutableRawPointer(files)) }
            for position in 0..<g_list_model_get_n_items(files) {
                guard let item = g_list_model_get_item(files, position) else { continue }
                defer { g_object_unref(item) }
                if let path = g_file_get_path(OpaquePointer(item)) {
                    urls.append(URL(fileURLWithPath: String(cString: path)))
                    g_free(path)
                }
            }
        }
        let done = completion
        cancel()
        done?(urls)
    }
}
#endif
