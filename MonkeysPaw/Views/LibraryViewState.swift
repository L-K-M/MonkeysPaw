import Foundation
import MonkeysPawCore
import SwiftUI

/// The reusable window follows one browser graph at a time. Tokens and a
/// binding revision also protect against already-queued retired publications.
final class LibraryViewState: ObservableObject {
    enum Preview: Equatable {
        case none
        case rendered(String)
        case issues([PromptIssue])
    }

    enum Direction { case up, down }

    @Published private(set) var snapshot: LibraryBrowserState
    @Published private(set) var preview: Preview = .none
    @Published private(set) var favoriteOutcome: PromptFavoriteOutcome?
    @Published private(set) var libraryAvailable: Bool
    @Published private(set) var activeLibraryPath: String
    @Published private(set) var focusRevision: UInt64 = 0
    private(set) var model: LibraryBrowserModel
    private let mainThread: MainThread
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private let revealLibrary: () -> Void
    private var observer: UUID?
    private var bindingRevision: UInt64 = 0
    private var isActive = true

    init(model: LibraryBrowserModel, libraryPath: String, available: Bool,
         mainThread: MainThread, now: @escaping () -> Date,
         timeZone: @escaping () -> TimeZone, revealLibrary: @escaping () -> Void) {
        self.model = model
        snapshot = model.state
        activeLibraryPath = libraryPath
        libraryAvailable = available
        self.mainThread = mainThread
        self.now = now
        self.timeZone = timeZone
        self.revealLibrary = revealLibrary
        observeModel()
        refresh()
    }

    deinit { if let observer { model.removeObserver(observer) } }

    var canToggleFavorite: Bool {
        guard isActive, libraryAvailable, let row = snapshot.selectedPrompt else { return false }
        return row.canRender && !row.isReadOnly
    }

    var favoriteMessage: String? { favoriteOutcome.flatMap(LibraryStrings.favoriteMessage) }

    func rebind(to model: LibraryBrowserModel, libraryPath: String, available: Bool) {
        guard isActive else { return }
        if let observer { self.model.removeObserver(observer) }
        observer = nil
        bindingRevision &+= 1
        self.model = model
        activeLibraryPath = libraryPath
        libraryAvailable = available
        favoriteOutcome = nil
        observeModel()
        refresh()
        focusRevision &+= 1
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        bindingRevision &+= 1
        if let observer { model.removeObserver(observer) }
        observer = nil
        libraryAvailable = false
        favoriteOutcome = nil
    }

    func setLibraryAvailable(_ available: Bool) {
        guard isActive else { return }
        libraryAvailable = available
    }

    func didShow() {
        guard isActive else { return }
        refresh()
        focusRevision &+= 1
    }

    func setFilter(_ filter: String) {
        guard isActive else { return }
        favoriteOutcome = nil
        model.setFilter(filter)
    }

    func selectSection(_ section: LibrarySectionID) {
        guard isActive else { return }
        favoriteOutcome = nil
        model.selectSection(section)
    }

    /// SwiftUI List can publish nil when a filter removes its selected row.
    /// Ignore that reconciliation; Core keeps the selected prompt's preview.
    func selectPath(_ path: RelativePath?) {
        guard isActive, let path,
              let row = snapshot.rows.first(where: { $0.relativePath == path }) else { return }
        favoriteOutcome = nil
        model.selectPrompt(row.selection)
    }

    func moveSelection(_ direction: Direction) {
        guard isActive, !snapshot.rows.isEmpty else { return }
        let position = snapshot.rows.firstIndex { $0.selection == snapshot.selection }
        let next: Int
        if let position {
            next = min(max(position + (direction == .up ? -1 : 1), 0), snapshot.rows.count - 1)
        } else {
            next = direction == .up ? snapshot.rows.count - 1 : 0
        }
        selectPath(snapshot.rows[next].relativePath)
    }

    func toggleFavorite() {
        // The keyboard shortcut must honour the same gate as the button.
        guard canToggleFavorite else { return }
        favoriteOutcome = model.toggleFavorite()
    }

    func revealFolder() {
        guard isActive, libraryAvailable else { return }
        revealLibrary()
    }

    /// Return true when Escape cleared search. The controller closes only on
    /// the next Escape, independently of which pane currently owns focus.
    func clearFilterForEscape() -> Bool {
        guard isActive, !snapshot.filter.isEmpty else { return false }
        setFilter("")
        focusRevision &+= 1
        return true
    }

    private func observeModel() {
        let revision = bindingRevision
        let model = self.model
        observer = model.addObserver { [weak self, weak model] state in
            self?.mainThread.run { [weak self, weak model] in
                guard let self, let model, self.isActive,
                      self.bindingRevision == revision, self.model === model else { return }
                if self.snapshot.selection != state.selection { self.favoriteOutcome = nil }
                self.snapshot = state
                self.refreshPreview()
            }
        }
    }

    private func refresh() {
        snapshot = model.state
        refreshPreview()
    }

    private func refreshPreview() {
        guard let row = snapshot.selectedPrompt, let entry = model.selectedEntry else {
            preview = .none
            return
        }
        guard row.canRender, !row.isReadOnly else {
            preview = .issues(row.issues)
            return
        }
        preview = .rendered(Self.renderPreview(entry.document, now: now(), timeZone: timeZone()))
    }

    /// Preview accepts name markers even for required/choice fields. Delivery's
    /// renderer rightly rejects them, so use its parsed tokens without reading
    /// remembered values or resolving the clipboard builtin through FillService.
    static func renderPreview(_ document: PromptDocument, now: Date, timeZone: TimeZone) -> String {
        var values: [String: String] = [:]
        for field in document.effectiveFields {
            values[field.name] = field.defaultValue.isEmpty ? "{\(field.name)}" : field.defaultValue
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        values[BuiltinName.date.rawValue] = formatter.string(from: now)
        formatter.dateFormat = "HH:mm"
        values[BuiltinName.time.rawValue] = formatter.string(from: now)
        values[BuiltinName.clipboard.rawValue] = "{clipboard}"

        return document.template.tokens.map { token in
            switch token {
            case .literal(let text): return text
            case .escapedOpener: return "{{"
            case .placeholder(let name): return values[name] ?? "{\(name)}"
            }
        }.joined()
    }
}
