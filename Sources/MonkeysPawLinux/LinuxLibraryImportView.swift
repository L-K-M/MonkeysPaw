#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Widgets only: selections enter the graph's import state; report opens use
/// its composition callback and the Library editor's existing discard guard.
final class LinuxLibraryImportView {
    let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
    let report = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
    private let files = GTK.button(LinuxImportStrings.importAction) {}
    private let folder = GTK.button(LinuxImportStrings.importFolder) {}
    private let destination = gtk_combo_box_text_new()!
    private let progress = GTK.label("")
    private let message = GTK.label("")
    private let reportFiles = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
    private let summary = GTK.label("")
    private let parent: GTK.Widget
    private let chooser: LinuxImportChoosing
    private weak var state: LinuxLibraryImportState?
    private var renderedDestinations: [RelativePath] = []
    private var renderedReports: [ImportReport] = []
    private var openButtons: [GTK.Widget] = []
    private var isRendering = false

    init(parent: GTK.Widget, list: GTK.Widget, chooser: LinuxImportChoosing) {
        self.parent = parent
        self.chooser = chooser
        gtk_widget_set_name(files, "library-import")
        gtk_widget_set_name(folder, "library-import-folder")
        gtk_widget_set_name(destination, "library-import-destination")
        mp_accessible_label(destination, LinuxImportStrings.destination)
        for widget in [files, folder, GTK.label(LinuxImportStrings.destination), destination, progress] {
            gtk_box_append(mp_box(actions), widget)
        }
        gtk_widget_set_name(progress, "library-import-progress")
        GTK.onSignal(files, "clicked") { [weak self] in self?.state?.choose(.files) }
        GTK.onSignal(folder, "clicked") { [weak self] in self?.state?.choose(.folder) }
        GTK.onSignal(destination, "changed") { [weak self] in
            guard let self, !self.isRendering else { return }
            let position = Int(gtk_combo_box_get_active(mp_combo_box(self.destination)))
            guard self.renderedDestinations.indices.contains(position) else { return }
            self.state?.selectDestination(self.renderedDestinations[position])
        }
        gtk_widget_set_name(report, "library-import-report")
        mp_accessible_label(report, LinuxImportStrings.report)
        let heading = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(mp_box(heading), GTK.label(LinuxImportStrings.report))
        gtk_box_append(mp_box(heading), summary)
        let dismiss = GTK.button(LinuxImportStrings.dismiss) { [weak self] in self?.state?.dismissReport() }
        gtk_widget_set_name(dismiss, "library-import-dismiss")
        gtk_box_append(mp_box(heading), dismiss)
        gtk_box_append(mp_box(report), heading)
        let scroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_max_content_height(mp_scrolled_window(scroll), Int32(Limits.panelSize.height / 2))
        gtk_scrolled_window_set_propagate_natural_height(mp_scrolled_window(scroll), 1)
        gtk_scrolled_window_set_child(mp_scrolled_window(scroll), reportFiles)
        gtk_box_append(mp_box(report), scroll)
        gtk_widget_set_name(message, "library-import-message")
        gtk_box_append(mp_box(actions), message)
        installDropTarget(on: list)
    }

    func bind(_ state: LinuxLibraryImportState) {
        unbind()
        self.state = state
        state.onChange = { [weak self] in self?.render() }
        state.onChoose = { [weak self] mode, done in
            guard let self, gtk_widget_get_visible(self.parent) != 0 else { done([]); return {} }
            self.chooser.choose(parent: self.parent, mode: mode, done: done)
            return { [weak self] in self?.chooser.cancel() }
        }
        render()
    }

    func cancelChoosing() { state?.cancelChoosing() }

    func unbind() {
        state?.onChange = nil
        state?.onChoose = nil
        state?.cancelChoosing()
        state = nil
    }

    private func render() {
        guard let state else { return }
        isRendering = true
        defer { isRendering = false }
        for widget in [files, folder, destination] { gtk_widget_set_sensitive(widget, state.canImport ? 1 : 0) }
        if renderedDestinations != state.destinations {
            renderedDestinations = state.destinations
            gtk_combo_box_text_remove_all(mp_combo_box_text(destination))
            for path in renderedDestinations { gtk_combo_box_text_append_text(mp_combo_box_text(destination), path.string + "/") }
        }
        gtk_combo_box_set_active(mp_combo_box(destination), Int32(renderedDestinations.firstIndex(of: state.destination) ?? 0))
        gtk_label_set_text(mp_label(progress), LinuxImportStrings.progress(state.progress,
            selection: state.requestNumber, total: state.requestCount))
        gtk_widget_set_visible(progress, state.isBusy ? 1 : 0)
        gtk_label_set_text(mp_label(message), state.message ?? "")
        gtk_widget_set_visible(message, state.message == nil ? 0 : 1)
        gtk_widget_set_visible(report, state.hasReport ? 1 : 0)
        for button in openButtons { gtk_widget_set_sensitive(button, state.libraryAvailable ? 1 : 0) }
        let reports = state.reports.map(\.report)
        guard reports != renderedReports else { return }
        renderedReports = reports
        openButtons = []
        while let child = gtk_widget_get_first_child(reportFiles) { gtk_box_remove(mp_box(reportFiles), child) }
        gtk_label_set_text(mp_label(summary), LinuxImportStrings.summary(created: state.createdCount, skipped: state.skippedCount))
        for completed in state.reports {
            guard let failure = completed.report.failure else { continue }
            let source: String
            switch completed.request {
            case .files: source = LinuxImportStrings.selectedFiles
            case .folder(let path): source = path
            }
            append(source + "\n" + LinuxImportStrings.failed(failure))
        }
        for file in state.files {
            append(file.sourcePath)
            switch file.outcome {
            case .created(let path):
                let open = GTK.button(LinuxImportStrings.created(path)) { [weak self] in self?.state?.open(path) }
                gtk_widget_set_name(open, "library-import-open")
                gtk_widget_set_sensitive(open, state.libraryAvailable ? 1 : 0)
                openButtons.append(open)
                gtk_box_append(mp_box(reportFiles), open)
            case .skipped(let reason): append(LinuxImportStrings.skipped(reason))
            }
            for mapping in file.mapping.mappings { append(LinuxImportStrings.mapping(mapping)) }
            if !file.mapping.preservedKeys.isEmpty { append(LinuxImportStrings.preserved(file.mapping.preservedKeys)) }
            for loss in file.mapping.dropped { append(LinuxImportStrings.loss(loss)) }
            for warning in file.mapping.warnings { append(LinuxImportStrings.warning(warning)) }
        }
    }

    private func append(_ text: String) {
        let label = GTK.label(text)
        gtk_label_set_selectable(mp_label(label), 1)
        gtk_box_append(mp_box(reportFiles), label)
    }

    private final class DropHandler {
        let receive: ([URL]) -> Bool
        init(_ receive: @escaping ([URL]) -> Bool) { self.receive = receive }
    }

    private func installDropTarget(on list: GTK.Widget) {
        let target = gtk_drop_target_new(gdk_file_list_get_type(), GDK_ACTION_COPY)!
        let handler = Unmanaged.passRetained(DropHandler { [weak self] urls in
            guard let self, gtk_widget_get_visible(self.parent) != 0 else { return false }
            return self.state?.importURLs(urls) ?? false
        }).toOpaque()
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<GValue>?, Double, Double,
                                        UnsafeMutableRawPointer?) -> gboolean = { _, value, _, _, data in
            guard let value, let data, g_type_check_value_holds(value, gdk_file_list_get_type()) != 0,
                  let boxed = g_value_get_boxed(value) else { return 0 }
            var urls: [URL] = []
            var node = gdk_file_list_get_files(OpaquePointer(boxed))
            while let current = node {
                if let file = current.pointee.data, let uri = g_file_get_uri(OpaquePointer(file)) {
                    if let url = URL(string: String(cString: uri)) { urls.append(url) }
                    g_free(uri)
                }
                node = current.pointee.next
            }
            return Unmanaged<DropHandler>.fromOpaque(data).takeUnretainedValue().receive(urls) ? 1 : 0
        }
        let release: GClosureNotify = { data, _ in
            if let data { Unmanaged<DropHandler>.fromOpaque(data).release() }
        }
        mp_connect(UnsafeMutableRawPointer(target), "drop", unsafeBitCast(trampoline, to: GCallback.self), handler, release)
        gtk_widget_add_controller(list, target)
    }
}
#endif
