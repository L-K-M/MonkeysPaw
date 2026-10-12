#if os(Linux)
import CGtk

/// Native UI operation, injectable so Settings tests never open a dialog.
/// Construct, choose, cancel and release on the GTK thread.
protocol LinuxFolderChoosing: AnyObject {
    func chooseFolder(parent: GTK.Widget, currentPath: String, done: @escaping (String?) -> Void)
    func cancel()
}

/// GtkFileChooserNative also works on GTK 4.8; GtkFileDialog requires 4.10.
final class GTKFolderChooser: LinuxFolderChoosing {
    // Unlike a GtkWindow, GTK does not keep a native dialog alive for us.
    private var dialog: OpaquePointer?
    private var completion: ((String?) -> Void)?
    private let showDialog: (OpaquePointer) -> Void

    init(showDialog: @escaping (OpaquePointer) -> Void = { gtk_native_dialog_show(mp_native_dialog($0)) }) {
        self.showDialog = showDialog
    }

    deinit { cancel() }

    func chooseFolder(parent: GTK.Widget, currentPath: String, done: @escaping (String?) -> Void) {
        cancel()
        guard let dialog = gtk_file_chooser_native_new(LinuxStrings.chooseLibraryFolder, mp_window(parent),
            GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER, LinuxStrings.choose, LinuxStrings.cancel) else {
            done(nil)
            return
        }
        self.dialog = dialog
        completion = done
        let chooser = mp_file_chooser(dialog)
        gtk_file_chooser_set_select_multiple(chooser, 0)
        gtk_file_chooser_set_create_folders(chooser, 0)
        let folder = g_file_new_for_path(currentPath)!
        var error: UnsafeMutablePointer<GError>?
        _ = gtk_file_chooser_set_current_folder(chooser, folder, &error)
        g_object_unref(UnsafeMutableRawPointer(folder))
        if let error { g_error_free(error) }
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
        var path: String?
        if response == GTK_RESPONSE_ACCEPT.rawValue, let file = gtk_file_chooser_get_file(mp_file_chooser(dialog)) {
            if let raw = g_file_get_path(file) {
                path = String(cString: raw)
                g_free(raw)
            }
            g_object_unref(UnsafeMutableRawPointer(file))
        }
        let done = completion
        cancel()
        done?(path)
    }
}
#endif
