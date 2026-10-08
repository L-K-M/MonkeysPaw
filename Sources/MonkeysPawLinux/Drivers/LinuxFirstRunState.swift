#if os(Linux)
import Foundation

/// The initial Setup presentation is app state, separate from GNOME's successful
/// keybinding record. A service launch remains windowless until an action fires.
struct LinuxFirstRunState {
    private let marker: URL

    init(paths: LinuxPaths) {
        marker = paths.configDirectory.appendingPathComponent("setup-shown")
    }

    var needsSetup: Bool { !FileManager.default.fileExists(atPath: marker.path) }

    func recordPresentation() throws {
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try Data().write(to: marker, options: .atomic)
    }
}
#endif
