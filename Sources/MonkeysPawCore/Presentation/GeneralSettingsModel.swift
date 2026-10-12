import Foundation

/// Settings → General (§11.1). Construct, release and call intents on the UI thread;
/// state updates and onChange are delivered through the injected MainThread.
public final class GeneralSettingsModel {
    public struct State: Equatable, Sendable {
        public let activeLibraryPath: String
        public let isDefaultLibrary: Bool
        public let isReadOnly: Bool
        public let settingsError: SettingsError?
        /// Nil after success, including choosing the already-active folder.
        public let lastSwitchMessage: LibrarySwitchOutcome?

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.activeLibraryPath.utf8.elementsEqual(rhs.activeLibraryPath.utf8)
                && lhs.isDefaultLibrary == rhs.isDefaultLibrary
                && lhs.isReadOnly == rhs.isReadOnly
                && lhs.settingsError == rhs.settingsError
                && lhs.lastSwitchMessage == rhs.lastSwitchMessage
        }
    }

    /// One owner: the platform view. Settings subscriptions remain independent.
    public var onChange: (() -> Void)?
    public private(set) var state: State

    private let settings: SettingsModel
    private let library: LibraryLocationControl
    private let mainThread: MainThread
    private var observer: UUID?
    private var isReadingSettings = false

    public init(settings: SettingsModel, library: LibraryLocationControl, mainThread: MainThread) {
        self.settings = settings
        self.library = library
        self.mainThread = mainThread
        state = State(activeLibraryPath: library.activeLibraryPath,
            isDefaultLibrary: Self.sameFolder(library.activeLibraryPath, library.defaultLibraryPath),
            isReadOnly: settings.isReadOnly, settingsError: settings.error, lastSwitchMessage: nil)
        observer = settings.addObserver { [weak self] _, _ in
            guard let self, !self.isReadingSettings else { return }
            self.mainThread.run { [weak self] in
                guard let self else { return }
                self.publish(path: self.library.activeLibraryPath, message: self.state.lastSwitchMessage)
            }
        }
    }

    deinit {
        if let observer { settings.removeObserver(observer) }
    }

    /// The view runs its native chooser and passes the selected absolute path.
    public func chooseFolder(_ path: String) {
        // Retain accepted mutations/reveals until the queued operation runs,
        // even if the settings view closes before the main loop drains it.
        mainThread.run {
            if Self.sameFolder(path, self.library.activeLibraryPath) {
                self.saveActiveFolder()
                return
            }
            self.switchLibrary(to: path)
        }
    }

    public func useDefaultFolder() {
        // Even when the active path is the default, nil must clear a saved
        // explicit choice or retry persistence after an earlier failed write.
        mainThread.run { self.switchLibrary(to: nil) }
    }

    public func revealFolder() {
        mainThread.run { self.library.revealLibrary() }
    }

    /// Republish after another composition operation replaces the graph.
    /// Failed startup can change its path without a shared-settings event.
    public func refresh() {
        mainThread.run { [weak self] in
            guard let self else { return }
            self.isReadingSettings = true
            self.settings.refresh()
            self.isReadingSettings = false
            self.publish(path: self.library.activeLibraryPath, message: self.state.lastSwitchMessage)
        }
    }

    private func switchLibrary(to path: String?) {
        // Composition updates the shared settings inline. Publish the final
        // path, settings error and outcome together, without an intermediate UI.
        isReadingSettings = true
        let outcome = library.switchLibrary(to: path)
        isReadingSettings = false

        let activePath: String
        switch outcome {
        case .deliveryInFlight, .invalidTarget: activePath = state.activeLibraryPath
        case .switched, .settingsNotSaved, .libraryUnavailable: activePath = library.activeLibraryPath
        }
        publish(path: activePath, message: outcome == .switched ? nil : outcome)
    }

    /// Re-choosing the running folder retries a failed save, like the default
    /// intent, without replacing the graph. An already-saved folder is a no-op.
    private func saveActiveFolder() {
        let active = library.activeLibraryPath
        let saved = settings.libraryFolderPath ?? library.defaultLibraryPath
        guard !Self.sameFolder(saved, active) else {
            publish(path: active, message: nil)
            return
        }

        isReadingSettings = true
        if Self.sameFolder(active, library.defaultLibraryPath) { settings.clearLibraryFolder() }
        else { settings.setLibraryFolder(active) }
        isReadingSettings = false
        publish(path: active, message: settings.error.map { .settingsNotSaved($0) })
    }

    private func publish(path: String, message: LibrarySwitchOutcome?) {
        let next = State(activeLibraryPath: path,
            isDefaultLibrary: Self.sameFolder(path, library.defaultLibraryPath),
            isReadOnly: settings.isReadOnly, settingsError: settings.error, lastSwitchMessage: message)
        guard next != state else { return }
        state = next
        onChange?()
    }

    private static func sameFolder(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = normalizedAbsolutePath(lhs), let right = normalizedAbsolutePath(rhs) else { return false }
        return left == right
    }

    /// Comparison alone removes repeated/trailing slashes and ASCII . / ..
    /// components (clamped at root). Preserve UTF-8 identity like RelativePath;
    /// do not fold Unicode/case, expand ~, resolve symlinks or touch files.
    /// Composition receives the original spelling and owns target validation.
    private static func normalizedAbsolutePath(_ path: String) -> RelativePath? {
        guard (try? SettingsDocument(libraryFolderPath: path)) != nil else { return nil }
        var components: [String] = []
        // Split separator bytes, since a slash followed by a combining scalar
        // need not form a standalone Swift Character (§5.1).
        for part in path.utf8.split(separator: UInt8(ascii: "/")) {
            if part.elementsEqual([UInt8(ascii: ".")]) { continue }
            if part.elementsEqual([UInt8(ascii: "."), UInt8(ascii: ".")]) {
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(String(decoding: part, as: UTF8.self))
            }
        }
        return RelativePath("/" + components.joined(separator: "/"))
    }
}
