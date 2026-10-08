#if os(Linux)
import CGtk
import MonkeysPawCore

/// The Linux composition root: only this type assembles platform drivers.
final class LinuxEnvironment {
    let log: LogSink
    let mainThread: MainThread

    // GApplication can dispatch a cold action without "activate". A stored lazy
    // panel covers both paths and keeps the Swift wrapper alive while hidden.
    private(set) lazy var panel = LinuxPanel(application: application)

    private let application: UnsafeMutablePointer<GtkApplication>

    init(application: UnsafeMutablePointer<GtkApplication>) {
        self.application = application
        log = StandardErrorLog()
        mainThread = GLibMainThread()
    }
}
#endif
