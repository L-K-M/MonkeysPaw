#if os(Linux)
import CGtk
import MonkeysPawCore

/// One reusable GTK 4.8 dialog, shared by Library and the tray.
final class LinuxAboutWindow {
    private let widget = gtk_about_dialog_new()!
    private var destroyed = false

    init(application: UnsafeMutablePointer<GtkApplication>) {
        gtk_window_set_application(mp_window(widget), application)
        gtk_window_set_title(mp_window(widget), LinuxAboutStrings.title)
        gtk_widget_set_name(widget, "monkeyspaw-about")
        GTK.hideOnClose(widget)
        let dialog = mp_about_dialog(widget)
        gtk_about_dialog_set_program_name(dialog, AppIdentity.displayName)
        gtk_about_dialog_set_version(dialog, LinuxEnvironment.packagedVersion ?? AppIdentity.fallbackVersion)
        gtk_about_dialog_set_comments(dialog, LinuxAboutStrings.comments)
        gtk_about_dialog_set_logo_icon_name(dialog, AppIdentity.linuxAppID)
        gtk_about_dialog_set_website(dialog, LinuxAboutStrings.repository)
        // GTK 4.8 has no Unlicense enum; display the repository's exact license.
        gtk_about_dialog_set_license_type(dialog, GTK_LICENSE_CUSTOM)
        gtk_about_dialog_set_license(dialog, LinuxAboutStrings.license)
        GTK.onSignal(widget, "destroy") { [weak self] in self?.destroyed = true }
    }

    func show(parent: GTK.Widget? = nil) {
        guard !destroyed else { return }
        gtk_window_set_transient_for(mp_window(widget), parent.flatMap { mp_window($0) })
        gtk_window_set_modal(mp_window(widget), parent == nil ? 0 : 1)
        gtk_window_present(mp_window(widget))
    }
}
#endif
