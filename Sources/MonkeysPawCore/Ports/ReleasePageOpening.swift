import Foundation

public enum ReleasePageOpenOutcome: Sendable {
    case opened
    case failed
}

/// Called on the injected UI thread only after an explicit View release intent.
/// The service supplies a constructed URL in the verified repository; drivers
/// use NSWorkspace or GTK/OpenURI, never download or install the release.
public protocol ReleasePageOpening {
    func openReleasePage(_ url: URL, completion: @escaping (ReleasePageOpenOutcome) -> Void)
}
