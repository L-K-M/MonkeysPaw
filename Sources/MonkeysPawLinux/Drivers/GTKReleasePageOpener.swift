#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// GTK uses the desktop's URI launcher, including OpenURI in a sandbox.
final class GTKReleasePageOpener: ReleasePageOpening {
    private final class Completion {
        let call: (ReleasePageOpenOutcome) -> Void
        init(_ call: @escaping (ReleasePageOpenOutcome) -> Void) { self.call = call }
    }

    private let showURI: (URL, @escaping (ReleasePageOpenOutcome) -> Void) -> Void

    init(showURI: @escaping (URL, @escaping (ReleasePageOpenOutcome) -> Void) -> Void = GTKReleasePageOpener.launch) {
        self.showURI = showURI
    }

    func openReleasePage(_ url: URL, completion: @escaping (ReleasePageOpenOutcome) -> Void) {
        precondition(Thread.isMainThread, "Open release pages on the GTK thread")
        showURI(url, completion)
    }

    private static func launch(_ url: URL, completion: @escaping (ReleasePageOpenOutcome) -> Void) {
        let data = Unmanaged.passRetained(Completion(completion)).toOpaque()
        // No borrowed parent survives asynchronous export or window destruction.
        gtk_show_uri_full(nil, url.absoluteString, UInt32(GDK_CURRENT_TIME), nil, { _, result, data in
            guard let data else { return }
            let completion = Unmanaged<Completion>.fromOpaque(data).takeRetainedValue()
            guard let result else { completion.call(.failed); return }
            var error: UnsafeMutablePointer<GError>?
            let opened = gtk_show_uri_full_finish(nil, result, &error) != 0
            if let error { g_error_free(error) }
            completion.call(opened ? .opened : .failed)
        }, data)
    }
}
#endif
