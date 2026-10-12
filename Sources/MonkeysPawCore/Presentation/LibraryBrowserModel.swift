import Foundation

/// UI-thread intents and state reads. Service callbacks marshal through the
/// injected MainThread, including composition's retired-graph guard. Filtering
/// and usage refreshes use only cached, immutable content, never files.
public final class LibraryBrowserModel: @unchecked Sendable {
    public var onChange: (() -> Void)?
    public private(set) var state = LibraryBrowserState(sections: [], selectedSection: .all,
        filter: "", rows: [], selection: nil, selectedPrompt: nil)
    public var sections: [LibraryBrowserSection] { state.sections }
    public var selectedSection: LibrarySectionID { state.selectedSection }
    public var filter: String { state.filter }
    public var rows: [LibraryBrowserRow] { state.rows }
    public var selection: LibraryPromptSelection? { state.selection }
    public var selectedEntry: LibraryEntry? {
        guard let selection else { return nil }
        return contents.first { $0.entry.identity == selection.identity
            && RelativePath($0.entry.relativePath) == selection.relativePath }?.entry
    }

    private let index: PromptIndex
    private let usage: UsageStore
    private let favorites: PromptFavoriteEditing
    private let main: MainThread
    private weak var editor: EditorModel?
    private var indexObserver: UUID?
    private var usageObserver: UUID?
    private var editorObserver: UUID?
    private var isActive = true
    private var observers: [UUID: (LibraryBrowserState) -> Void] = [:]
    private var observerOrder: [UUID] = []
    private var contents: [PromptRanking.Input] = []
    private var lastUses: [PromptIdentity: Date] = [:]
    private var preferredSelection: LibraryPromptSelection?
    private var lastPublishedState: LibraryBrowserState?
    private var isPublishing = false

    /// Share the index's UsageStore, including LibraryService identity migration.
    /// Native composition supplies the same guarded MainThread as its picker.
    public init(index: PromptIndex, usage: UsageStore, favorites: PromptFavoriteEditing,
                main: MainThread, editor: EditorModel? = nil) {
        self.index = index
        self.usage = usage
        self.favorites = favorites
        self.main = main
        self.editor = editor
        indexObserver = index.addObserver { [weak self] in
            guard let self else { return }
            self.main.run { [weak self] in
                guard let self, self.isActive else { return }
                self.refreshContents()
            }
        }
        usageObserver = usage.addObserver { [weak self] in
            guard let self else { return }
            self.main.run { [weak self] in
                guard let self, self.isActive else { return }
                self.refreshUsage()
            }
        }
        editorObserver = editor?.addObserver { [weak self] state in
            guard let self else { return }
            self.main.run { [weak self] in
                guard let self, self.isActive, let prompt = state.prompt,
                      self.editor?.state.prompt == prompt,
                      self.preferredSelection?.relativePath == prompt.relativePath,
                      self.preferredSelection != prompt else { return }
                self.preferredSelection = prompt
                self.refreshContents()
            }
        }
        refreshContents()
        lastPublishedState = state
    }

    deinit {
        if let indexObserver { index.removeObserver(indexObserver) }
        if let usageObserver { usage.removeObserver(usageObserver) }
        if let editorObserver { editor?.removeObserver(editorObserver) }
    }

    /// Independent view/editor subscribers, on the UI thread. Registration is
    /// quiet; removal also cancels later observers in an ongoing publication.
    @discardableResult
    public func addObserver(_ observer: @escaping (LibraryBrowserState) -> Void) -> UUID {
        let token = UUID()
        guard isActive else { return token }
        observers[token] = observer
        observerOrder.append(token)
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
        observerOrder.removeAll { $0 == token }
    }

    /// Retire a graph, rather than merely hiding its reusable window. Queued
    /// callbacks and later intents cannot change its state or perform writes.
    public func deactivate() {
        guard isActive else { return }
        isActive = false
        if let indexObserver { index.removeObserver(indexObserver) }
        if let usageObserver { usage.removeObserver(usageObserver) }
        if let editorObserver { editor?.removeObserver(editorObserver) }
        indexObserver = nil
        usageObserver = nil
        editorObserver = nil
        observers = [:]
        observerOrder = []
        onChange = nil
    }

    public func selectSection(_ section: LibrarySectionID) {
        guard isActive else { return }
        let normalized: LibrarySectionID
        if case .tag(let tag) = section { normalized = .tag(FuzzyText.normalize(tag)) }
        else { normalized = section }
        guard sections.contains(where: { $0.id == normalized }), selectedSection != normalized else { return }
        update(section: normalized, filter: filter)
    }

    public func selectPrompt(_ selection: LibraryPromptSelection?) {
        guard isActive, selection != preferredSelection else { return }
        if let selection, !rows.contains(where: { $0.selection == selection }) { return }
        preferredSelection = selection
        update(section: selectedSection, filter: filter)
    }

    public func setFilter(_ filter: String) {
        guard isActive, !self.filter.utf8.elementsEqual(filter.utf8) else { return }
        update(section: selectedSection, filter: filter)
    }

    /// The open editor owns its buffer and stamped save. Unrelated prompts
    /// continue through the favourite port; only committed entries enter the index.
    @discardableResult
    public func toggleFavorite() -> PromptFavoriteOutcome {
        guard isActive else { return .inactive }
        guard let entry = selectedEntry else { return .noSelection }
        let outcome = editor?.toggleFavorite(of: entry) ?? favorites.toggleFavorite(of: entry)
        if case .saved(let saved) = outcome {
            preferredSelection = LibraryPromptSelection(identity: saved.identity,
                relativePath: RelativePath(saved.relativePath))
            index.acceptSaved(saved, replacing: entry)
            refreshContents()
        }
        return outcome
    }

    private func refreshContents() {
        contents = index.browseContents().sorted { Self.titleOrder($0.entry, $1.entry) }
        reconcileSelection()
        refreshUsage()
    }

    private func refreshUsage() {
        lastUses = usage.cachedUseEvents().compactMapValues { $0.max() }
        update(section: selectedSection, filter: filter)
    }

    private func reconcileSelection() {
        guard let selection = preferredSelection else { return }
        if contents.contains(where: { $0.entry.identity == selection.identity
            && RelativePath($0.entry.relativePath) == selection.relativePath }) { return }
        // The editor's first save replaces a path hash with a ULID before its
        // UI reply arrives. Retain the user's choice for that reply, without
        // following an unrelated selection or an external identity change.
        if editor?.state.status == .saving, editor?.state.prompt == selection { return }
        let sameIdentity = contents.filter { $0.entry.identity == selection.identity }
        // An assigned rename has one surviving identity. Refuse an ambiguous
        // duplicate id instead of jumping to an arbitrary byte-distinct path.
        guard sameIdentity.count == 1, let entry = sameIdentity.first?.entry else {
            preferredSelection = nil
            return
        }
        preferredSelection = LibraryPromptSelection(identity: entry.identity,
            relativePath: RelativePath(entry.relativePath))
    }

    private func update(section requested: LibrarySectionID, filter: String) {
        let all = contents.map { LibraryBrowserRow($0.entry, lastUsedAt: lastUses[$0.entry.identity]) }
        let recent = all.filter { $0.lastUsedAt != nil }.sorted {
            if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt! > $1.lastUsedAt! }
            return Self.rowTitleOrder($0, $1)
        }.prefix(Limits.libraryRecentCap)
        let sections = makeSections(all, recentCount: recent.count)
        let section = sections.contains { $0.id == requested } ? requested : .all
        let recentPaths = Set(recent.map(\.relativePath))
        let query = PromptSearchQuery(filter)
        let matchingPaths = Set(contents.compactMap { $0.content.match(query) == nil
            ? nil : RelativePath($0.entry.relativePath) })
        var rows = all.filter { matchingPaths.contains($0.relativePath)
            && belongs($0, to: section, recentPaths: recentPaths) }
        if section == .recent {
            rows.sort {
                if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt! > $1.lastUsedAt! }
                return Self.rowTitleOrder($0, $1)
            }
        }
        let selected = preferredSelection.flatMap { key in all.first { $0.selection == key } }
        let next = LibraryBrowserState(sections: sections, selectedSection: section, filter: filter,
            rows: rows, selection: selected?.selection, selectedPrompt: selected)
        guard next != state else { return }
        state = next
        // Intents originate on the UI thread, but even their notifications use
        // the port. A queued notification reads the latest state and coalesces
        // changes that have already been published by an earlier queued hop.
        main.run { [weak self] in self?.publishLatest() }
    }

    private func publishLatest() {
        guard isActive, !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }
        while isActive, lastPublishedState != state {
            let snapshot = state
            lastPublishedState = snapshot
            let subscribers = observerOrder
            onChange?()
            for token in subscribers {
                // Reentrant intents supersede this snapshot. Publish their
                // latest state next, without duplicate or stale notifications.
                guard state == snapshot else { break }
                observers[token]?(snapshot)
            }
        }
    }

    private func makeSections(_ all: [LibraryBrowserRow], recentCount: Int) -> [LibraryBrowserSection] {
        var result = [LibraryBrowserSection(id: .all, title: "All", count: all.count, parent: nil, depth: 0),
            LibraryBrowserSection(id: .favourites, title: "Favourites", count: all.filter(\.favorite).count, parent: nil, depth: 0),
            LibraryBrowserSection(id: .recent, title: "Recent", count: recentCount, parent: nil, depth: 0)]
        var folders: [RelativePath: Int] = [:]
        var tags: [String: (title: String, count: Int)] = [:]
        for row in all {
            for folder in Self.folderAncestors(row.relativePath) { folders[folder, default: 0] += 1 }
            var counted = Set<String>()
            for tag in row.tags {
                let key = FuzzyText.normalize(tag)
                guard !key.isEmpty, counted.insert(key).inserted else { continue }
                let previous = tags[key]
                let title = previous.map { tag.utf8.lexicographicallyPrecedes($0.title.utf8) ? tag : $0.title } ?? tag
                tags[key] = (title, (previous?.count ?? 0) + 1)
            }
        }
        for folder in folders.keys.sorted(by: Self.folderOrder) {
            let parts = Self.pathParts(folder)
            let parent = parts.count > 1 ? LibrarySectionID.folder(RelativePath(parts.dropLast().joined(separator: "/"))) : nil
            result.append(LibraryBrowserSection(id: .folder(folder), title: parts.last!,
                count: folders[folder]!, parent: parent, depth: parts.count - 1))
        }
        for key in tags.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let tag = tags[key]!
            result.append(LibraryBrowserSection(id: .tag(key), title: "#" + tag.title,
                count: tag.count, parent: nil, depth: 0))
        }
        return result
    }

    private func belongs(_ row: LibraryBrowserRow, to section: LibrarySectionID,
                         recentPaths: Set<RelativePath>) -> Bool {
        switch section {
        case .all: return true
        case .favourites: return row.favorite
        case .recent: return recentPaths.contains(row.relativePath)
        case .folder(let folder): return Self.folderAncestors(row.relativePath).contains(folder)
        case .tag(let tag): return row.tags.contains { FuzzyText.normalize($0) == tag }
        }
    }

    private static func folderAncestors(_ path: RelativePath) -> [RelativePath] {
        // Slash scalar boundaries also handle a combining mark starting a
        // component, where a Character-based split would lose that boundary.
        path.string.unicodeScalars.indices.compactMap { position in
            path.string.unicodeScalars[position] == "/" ? RelativePath(String(path.string[..<position])) : nil
        }
    }

    private static func pathParts(_ path: RelativePath) -> [String] {
        path.string.unicodeScalars.split(separator: "/").map(String.init)
    }

    private static func folderOrder(_ lhs: RelativePath, _ rhs: RelativePath) -> Bool {
        let left = pathParts(lhs).map { RelativePath($0) }
        let right = pathParts(rhs).map { RelativePath($0) }
        return left.lexicographicallyPrecedes(right)
    }

    private static func titleOrder(_ lhs: LibraryEntry, _ rhs: LibraryEntry) -> Bool {
        let left = lhs.document.frontMatter.title
        let right = rhs.document.frontMatter.title
        if !left.utf8.elementsEqual(right.utf8) { return left.utf8.lexicographicallyPrecedes(right.utf8) }
        return RelativePath(lhs.relativePath) < RelativePath(rhs.relativePath)
    }

    private static func rowTitleOrder(_ lhs: LibraryBrowserRow, _ rhs: LibraryBrowserRow) -> Bool {
        if !lhs.title.utf8.elementsEqual(rhs.title.utf8) { return lhs.title.utf8.lexicographicallyPrecedes(rhs.title.utf8) }
        return lhs.relativePath < rhs.relativePath
    }
}
