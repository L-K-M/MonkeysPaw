import MonkeysPawCore
import SwiftUI

struct LibraryView: View {
    private enum Pane: Hashable { case filter, sidebar, prompts, preview }
    @ObservedObject var presentation: LibraryViewState
    @FocusState private var focusedPane: Pane?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let imports = presentation.imports { LibraryImportControls(presentation: imports) }
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 140, idealWidth: 180, maxWidth: 260)
                importablePrompts.frame(minWidth: 180, idealWidth: 240)
                editor.frame(minWidth: 240, maxWidth: .infinity)
            }
            if let imports = presentation.imports { LibraryImportReportView(presentation: imports) }
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
                .accessibilityLabel(presentation.snapshot.selectedPrompt?.favorite == true
                    ? LibraryStrings.removeFavorite : LibraryStrings.addFavorite)
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
        .accessibilityLabel(section.title + ", " + String(section.count) + (section.count == 1 ? " prompt" : " prompts"))
    }

    @ViewBuilder
    private var importablePrompts: some View {
        if let imports = presentation.imports {
            prompts.modifier(LibraryImportDropTarget(presentation: imports))
        } else { prompts }
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

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let prompt = presentation.editorState.prompt {
                Text(presentation.snapshot.selectedPrompt?.title ?? LibraryStrings.prompts).font(.headline)
                Text(prompt.relativePath.string).font(.caption).foregroundStyle(.secondary)
                if let reason = presentation.editorState.readOnlyReason {
                    Text(EditorStrings.readOnly(reason)).font(.caption)
                        .accessibilityIdentifier("library-read-only")
                }
                HStack {
                    Button(EditorStrings.save, action: presentation.save)
                        .disabled(!presentation.canSave && !presentation.canShowConflict)
                        .keyboardShortcut("s", modifiers: .command).accessibilityIdentifier("library-save")
                    Button(EditorStrings.revert, action: presentation.revert).disabled(!presentation.canRevert)
                        .accessibilityIdentifier("library-revert")
                    Button(EditorStrings.saveAsCopy, action: presentation.saveAsCopy).disabled(!presentation.canSave)
                        .accessibilityIdentifier("library-save-copy")
                }
                HStack {
                    Button(LibraryCommandStrings.rename) { presentation.requestFileCommand(.rename) }
                        .accessibilityIdentifier("library-rename")
                    Button(LibraryCommandStrings.move) { presentation.requestFileCommand(.move) }
                        .accessibilityIdentifier("library-move")
                    Button(LibraryCommandStrings.delete) { presentation.requestFileCommand(.delete) }
                        .accessibilityIdentifier("library-delete")
                }
                .disabled(!presentation.canRunFileCommand || presentation.fileCommandRequest != nil)
                TabView(selection: $presentation.editorTab) {
                    source.tabItem { Text(EditorStrings.editTab) }.tag(LibraryViewState.EditorTab.edit)
                    preview.tabItem { Text(EditorStrings.previewTab) }.tag(LibraryViewState.EditorTab.preview)
                    fields.tabItem { Text(EditorStrings.fieldsTab) }.tag(LibraryViewState.EditorTab.fields)
                    LibraryHistoryView(presentation: presentation)
                        .tabItem { Text(LibraryCommandStrings.historyTab) }.tag(LibraryViewState.EditorTab.history)
                }
            } else {
                Text(LibraryStrings.noSelection).foregroundStyle(.secondary)
                Spacer()
            }
            Text(presentation.commandMessage ?? EditorStrings.status(presentation.editorState)).font(.caption)
                .accessibilityIdentifier("library-editor-status")
        }
        .padding(12)
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Core's canEdit excludes nil source, including an in-flight load.
            LibrarySourceEditor(source: presentation.editorState.source ?? "",
                path: presentation.editorState.prompt?.relativePath,
                revision: presentation.sourceRevision,
                isEditable: presentation.libraryAvailable && presentation.editorState.canEdit,
                onEdit: presentation.edit)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(presentation.editorState.issues.enumerated()), id: \.offset) { issue in
                        Text(EditorStrings.issue(issue.element))
                            .foregroundStyle(issue.element.severity == .error ? Color.red : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: presentation.editorState.issues.isEmpty ? 0 : 120)
            .accessibilityIdentifier("library-validation")
        }
        .padding(8)
    }

    private var fields: some View {
        ScrollView([.horizontal, .vertical]) {
            if presentation.editorState.fields.isEmpty {
                Text(EditorStrings.noFields).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        Text(EditorStrings.fieldName); Text(EditorStrings.fieldType)
                        Text(EditorStrings.fieldDefault); Text(EditorStrings.fieldOptions); Text(EditorStrings.fieldBehaviorHeader)
                    }.font(.headline)
                    ForEach(Array(presentation.editorState.fields.enumerated()), id: \.offset) { item in
                        GridRow {
                            VStack(alignment: .leading) {
                                Text(verbatim: item.element.name).font(.system(.body, design: .monospaced))
                                Text(verbatim: item.element.label)
                                if let description = item.element.description { Text(verbatim: description).font(.caption) }
                            }
                            Text(EditorStrings.fieldKind(item.element.kind))
                            Text(verbatim: item.element.defaultValue)
                            Text(verbatim: item.element.options.map { $0.label + " = " + $0.value }.joined(separator: "\n"))
                            Text(EditorStrings.fieldBehavior(item.element))
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .padding(12)
        .accessibilityLabel(EditorStrings.parsedFields)
        .accessibilityIdentifier("library-fields")
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let row = presentation.snapshot.selectedPrompt {
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
