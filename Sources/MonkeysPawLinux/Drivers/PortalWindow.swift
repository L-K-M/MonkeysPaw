#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Native window identity is a lease: a Wayland export outlives its dialog.
final class PortalParent {
    let identifier: String
    private var release: (() -> Void)?

    init(_ identifier: String = "", release: @escaping () -> Void = {}) {
        self.identifier = identifier
        self.release = release
    }

    func close() { release?(); release = nil }
    deinit { close() }
}

typealias PortalParentProvider = (@escaping (PortalParent) -> Void) -> Void

final class PortalWindow {
    private final class Export {
        var surface: OpaquePointer?
        var completion: ((PortalParent) -> Void)?
        var timer: guint = 0
        let onClose: () -> Void

        init(_ completion: @escaping (PortalParent) -> Void, onClose: @escaping () -> Void) {
            self.completion = completion
            self.onClose = onClose
        }

        func finish(_ identifier: String) {
            guard let completion else { return }
            self.completion = nil
            if timer != 0 { g_source_remove(timer); timer = 0 }
            completion(PortalParent(identifier) { [self] in close() })
        }

        func close() {
            guard let surface else { return }
            self.surface = nil
            mp_portal_unexport(surface)
            g_object_unref(UnsafeMutableRawPointer(surface))
            onClose()
        }
    }

    private var isExporting = false
    private let application: UnsafeMutablePointer<GtkApplication>
    init(application: UnsafeMutablePointer<GtkApplication>) { self.application = application }

    func parent(_ completion: @escaping (PortalParent) -> Void) {
        guard let window = gtk_application_get_active_window(application),
              gtk_widget_get_visible(mp_window_widget(window)) != 0 else {
            completion(PortalParent())
            return
        }
        if let xid = mp_portal_x11_parent(window) {
            defer { g_free(xid) }
            completion(PortalParent(String(cString: xid)))
            return
        }
        // GTK forbids exporting a surface twice. A concurrent interaction uses
        // the deliberate unparented fallback until the existing lease closes.
        guard !isExporting else { completion(PortalParent()); return }
        isExporting = true
        let export = Export(completion) { [weak self] in self?.isExporting = false }
        let data = Unmanaged.passRetained(export).toOpaque()
        export.surface = mp_portal_export(window, { _, handle, data in
            guard let handle, let data else { return }
            Unmanaged<Export>.fromOpaque(data).takeUnretainedValue()
                .finish("wayland:" + String(cString: handle))
        }, data, { data in
            guard let data else { return }
            Unmanaged<Export>.fromOpaque(data).release()
        })
        guard export.surface != nil else {
            isExporting = false
            Unmanaged<Export>.fromOpaque(data).release()
            completion(PortalParent())
            return
        }
        export.timer = GTK.after(Limits.portalCallTimeout.timeInterval) { [weak export] in
            guard let export else { return }
            export.timer = 0
            export.finish("")
        }
    }
}
#endif
