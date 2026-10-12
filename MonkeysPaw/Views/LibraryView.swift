import MonkeysPawCore
import SwiftUI

struct LibraryView: View {
    private enum Pane: Hashable { case filter, sidebar, prompts, preview }
    @ObservedObject var presentation: LibraryViewState
    @FocusState private var focusedPane: Pane?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 140, idealWidth: 180, maxWidth: 260)
                prompts.frame(minWidth: 180, idealWidth: 240)
                preview.frame(minWidth: 200, maxWidth: .infinity)
            }
            if !presentation.libraryAvailable {
                Text(Strings.libraryUnavailable).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .accessibilityIdentifier("library-unavailable")
            }
            if let message = presentation.favoriteMessage {
                Text(message).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .accessibilityIdentifier("library-favorite-message")
            }
            Divider()
            Text(LibraryStrings.keyboardHint).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .onAppear { focusedPane = .filter }
        .onChange(of: presentation.focusRevision) { _ in focusedPane = .filter }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField(LibraryStrings.filter, text: Binding(get: { presentation.snapshot.filter },
                set: presentation.setFilter))
                .textFieldStyle(.roundedBorder)
                .focused($focusedPane, equals: .filter)
                .accessibilityLabel(LibraryStrings.filter)
                .accessibilityIdentifier("library-filter")
            Button(presentation.snapshot.selectedPrompt?.favorite == true
                ? LibraryStrings.removeFavorite : LibraryStrings.addFavorite,
                systemImage: presentation.snapshot.selectedPrompt?.favorite == true ? "star.fill" : "star",
                action: presentation.toggleFavorite)
                .labelStyle(.iconOnly)
                .disabled(!presentation.canToggleFavorite)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .accessibilityIdentifier("library-favorite")
            Button(Strings.showInFinder, action: presentation.revealFolder)
                .disabled(!presentation.libraryAvailable)
                .help(presentation.activeLibraryPath)
                .accessibilityIdentifier("library-reveal")
        }
        .padding(12)
    }

    private var sidebar: some View {
        List(selection: Binding<LibrarySectionID?>(get: { presentation.snapshot.selectedSection },
            set: { if let section = $0 { presentation.selectSection(section) } })) {
            ForEach(standardSections, id: \.id, content: sectionRow)
            if !folderSections.isEmpty {
                Section(LibraryStrings.folders) {
                    ForEach(folderSections, id: \.id, content: sectionRow)
                }
            }
            if !tagSections.isEmpty {
                Section(LibraryStrings.tags) {
                    ForEach(tagSections, id: \.id, content: sectionRow)
                }
            }
        }
        .listStyle(.sidebar)
        .focused($focusedPane, equals: .sidebar)
        .accessibilityLabel(LibraryStrings.sidebar)
        .accessibilityIdentifier("library-sidebar")
    }

    private var standardSections: [LibraryBrowserSection] {
        presentation.snapshot.sections.filter { section in
            switch section.id { case .all, .favourites, .recent: return true; default: return false }
        }
    }

    private var folderSections: [LibraryBrowserSection] {
        presentation.snapshot.sections.filter { if case .folder = $0.id { return true }; return false }
    }

    private var tagSections: [LibraryBrowserSection] {
        presentation.snapshot.sections.filter { if case .tag = $0.id { return true }; return false }
    }

    private func sectionRow(_ section: LibraryBrowserSection) -> some View {
        HStack {
            Text(section.title).padding(.leading, CGFloat(section.depth) * 12)
            Spacer()
            Text(String(section.count)).foregroundStyle(.secondary)
        }
        .tag(section.id)
        .accessibilityLabel(section.title + ", " + String(section.count) + " prompts")
    }

    private var prompts: some View {
        VStack(spacing: 0) {
            List(selection: Binding<RelativePath?>(get: { presentation.snapshot.selection?.relativePath },
                set: presentation.selectPath)) {
                ForEach(presentation.snapshot.rows, id: \.relativePath) { row in
                    LibraryRowView(row: row, showsLastUse: presentation.snapshot.selectedSection == .recent)
                        .tag(row.relativePath)
                }
            }
            .focused($focusedPane, equals: .prompts)
            .onKeyPress(.upArrow) { presentation.moveSelection(.up); return .handled }
            .onKeyPress(.downArrow) { presentation.moveSelection(.down); return .handled }
            .onKeyPress(.return) { .handled }
            .accessibilityLabel(LibraryStrings.prompts)
            .accessibilityIdentifier("library-prompts")
            if presentation.snapshot.rows.isEmpty {
                Text(LibraryStrings.noRows).foregroundStyle(.secondary).padding(12)
            }
        }
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let row = presentation.snapshot.selectedPrompt {
                    Text(row.title).font(.headline)
                    Text(row.relativePath.string).font(.caption).foregroundStyle(.secondary)
                    if let description = row.previewLine { Text(description).foregroundStyle(.secondary) }
                }
                switch presentation.preview {
                case .none: Text(LibraryStrings.noSelection).foregroundStyle(.secondary)
                case .rendered(let text): Text(verbatim: text).textSelection(.enabled)
                case .issues(let issues):
                    ForEach(Array(issues.enumerated()), id: \.offset) { issue in
                        Text(issue.element.message).foregroundStyle(.red)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .focusable()
        .focused($focusedPane, equals: .preview)
        .accessibilityLabel(LibraryStrings.preview)
        .accessibilityIdentifier("library-preview")
    }
}

private struct LibraryRowView: View {
    let row: LibraryBrowserRow
    let showsLastUse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((row.favorite ? "★ " : "") + row.title)
            Text(row.relativePath.string).font(.caption).foregroundStyle(.secondary)
            if row.isReadOnly || !row.canRender {
                HStack(spacing: 8) {
                    if row.isReadOnly { Text(LibraryStrings.readOnly) }
                    if !row.canRender { Text(LibraryStrings.invalid) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if showsLastUse, let date = row.lastUsedAt {
                Text(lastUseLabel(date))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [row.title, row.relativePath.string]
        if row.favorite { parts.append(Strings.favorite) }
        if row.isReadOnly { parts.append(LibraryStrings.readOnly) }
        if !row.canRender { parts.append(LibraryStrings.invalid) }
        if showsLastUse, let date = row.lastUsedAt { parts.append(lastUseLabel(date)) }
        return parts.joined(separator: ", ")
    }

    private func lastUseLabel(_ date: Date) -> String {
        "Last used " + date.formatted(date: .abbreviated, time: .shortened)
    }
}
