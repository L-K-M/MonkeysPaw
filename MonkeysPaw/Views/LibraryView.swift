import Foundation
import MonkeysPawCore
import SwiftUI

/// Source list for the split-view window: Library sections, groups, a
/// collapsible folder tree and tags, with sync state pinned at its foot.
struct LibrarySidebarView: View {
    @ObservedObject var presentation: LibraryViewState
    @State private var dropTarget: LibrarySectionID?

    var body: some View {
        // A plain stack keeps the footer below the list; an inset let rows
        // scroll underneath the sync line.
        VStack(spacing: 0) {
            sectionList
            footer
        }
    }

    private var sectionList: some View {
        List(selection: Binding<LibrarySectionID?>(get: { presentation.snapshot.selectedSection },
            set: { if let section = $0 { presentation.selectSection(section) } })) {
            Section {
                ForEach(librarySections, id: \.id, content: sectionRow)
            } header: {
                Text(LibraryStrings.library)
            }
            if !groupSections.isEmpty {
                Section {
                    ForEach(groupSections, id: \.id, content: sectionRow)
                } header: {
                    Text(LibraryStrings.groups)
                }
            }
            if !folderTree.isEmpty {
                Section {
                    OutlineGroup(folderTree, children: \.children) { node in
                        sectionRow(node.section)
                    }
                } header: {
                    Text(LibraryStrings.folders)
                }
            }
            if !tagSections.isEmpty {
                Section {
                    ForEach(tagSections, id: \.id, content: sectionRow)
                } header: {
                    Text(LibraryStrings.tags)
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel(LibraryStrings.sidebar)
        .accessibilityIdentifier("library-sidebar")
        .onChange(of: presentation.scopeDragEpoch) { _ in dropTarget = nil }
    }

    private var librarySections: [LibraryBrowserSection] {
        presentation.snapshot.sections.filter { section in
            switch section.id { case .all, .favourites, .recent, .conflicts: return true; default: return false }
        }
    }

    private var folderSections: [LibraryBrowserSection] {
        presentation.snapshot.sections.filter { if case .folder = $0.id { return true }; return false }
    }

    private var groupSections: [LibraryBrowserSection] {
        presentation.snapshot.sections.filter { if case .group = $0.id { return true }; return false }
    }

    private var tagSections: [LibraryBrowserSection] {
        presentation.snapshot.sections.filter { if case .tag = $0.id { return true }; return false }
    }

    /// Parents precede children in the flat section order; a missing parent
    /// roots its folder rather than dropping it from the tree.
    private var folderTree: [LibraryFolderNode] {
        var children: [LibrarySectionID: [LibraryFolderNode]] = [:]
        var roots: [LibraryFolderNode] = []
        var known: Set<LibrarySectionID> = []
        for section in folderSections {
            let node = LibraryFolderNode(section: section)
            if let parent = section.parent, known.contains(parent) {
                children[parent, default: []].append(node)
            } else {
                roots.append(node)
            }
            known.insert(section.id)
        }
        return roots.map { node in attach(node, children: children) }
    }

    private func attach(_ node: LibraryFolderNode,
                        children: [LibrarySectionID: [LibraryFolderNode]]) -> LibraryFolderNode {
        var node = node
        node.children = children[node.id]?.map { attach($0, children: children) }
        return node
    }

    private func symbol(for id: LibrarySectionID) -> String {
        switch id {
        case .all: return "tray.full"
        case .favourites: return "star"
        case .recent: return "clock"
        case .conflicts: return "exclamationmark.triangle"
        case .folder: return "folder"
        case .tag: return "tag"
        case .group: return "person.2"
        }
    }

    @ViewBuilder
    private func sectionRow(_ section: LibraryBrowserSection) -> some View {
        if presentation.canDropScopeRow(onto: section.id) {
            sectionLabel(section)
                .onDrop(of: [LibraryViewState.scopeDragTypeIdentifier],
                    delegate: LibraryScopeDropTarget(presentation: presentation, section: section.id,
                        epoch: presentation.scopeDragEpoch, targeted: $dropTarget))
        } else {
            sectionLabel(section)
        }
    }

    private func sectionLabel(_ section: LibraryBrowserSection) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(displayTitle(section))
                if let role = section.role {
                    Text(LibraryStrings.role(role)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: symbol(for: section.id))
        }
        .badge(section.count)
        .listRowBackground(Rectangle().fill(dropTarget == section.id ? Color.accentColor.opacity(0.25) : Color.clear))
        .tag(section.id)
        .accessibilityLabel(LibraryStrings.sectionLabel(title: section.id == .all ? LibraryStrings.allPrompts : section.title, role: section.role, count: section.count))
    }

    /// The tag symbol already marks tags, so their "#" prefix is dropped.
    private func displayTitle(_ section: LibraryBrowserSection) -> String {
        switch section.id {
        case .all: return LibraryStrings.allPrompts
        case .tag:
            return section.title.hasPrefix("#") ? String(section.title.dropFirst()) : section.title
        default: return section.title
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let syncStatus = presentation.syncStatus { LibrarySidebarSyncFooter(status: syncStatus) }
        if !presentation.libraryAvailable {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                if !presentation.libraryAvailable {
                    Text(Strings.libraryUnavailable)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("library-unavailable")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Sync state at the sidebar's foot. With sync off there is nothing to
/// report, so the line disappears; Settings ▸ Account sets sync up.
private struct LibrarySidebarSyncFooter: View {
    @ObservedObject var status: SyncStatusViewState

    var body: some View {
        if status.state?.footer != .disabled {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                SyncStatusView(presentation: status)
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The open prompt's editor: read-only and sync-conflict bars above the
/// borderless source or preview, validation and save state in the status bar.
struct LibraryEditorView: View {
    @ObservedObject var presentation: LibraryViewState
    @State private var showsIssues = false

    var body: some View {
        VStack(spacing: 0) {
            importArea
            if presentation.editorState.prompt == nil {
                ContentUnavailableView(LibraryNativeStrings.noPromptSelected,
                    systemImage: "doc.text",
                    description: Text(LibraryStrings.noSelection))
                    .accessibilityIdentifier("library-editor-empty")
            } else {
                if let reason = presentation.editorState.readOnlyReason {
                    Label(EditorStrings.readOnly(reason), systemImage: "lock.fill")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .accessibilityIdentifier("library-read-only")
                }
                if let conflict = presentation.conflict {
                    LibraryConflictView(presentation: conflict)
                    Divider()
                }
                content
                if showsIssues, !presentation.editorState.issues.isEmpty {
                    Divider()
                    issueList
                }
                Divider()
                statusBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("library-editor")
        .onChange(of: presentation.editorState.prompt) { _ in showsIssues = false }
    }

    @ViewBuilder
    private var importArea: some View {
        if let imports = presentation.imports,
           imports.isBusy || imports.isChoosing || imports.hasReport || imports.selectionMessage != nil {
            VStack(spacing: 0) {
                if imports.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(ImportStrings.progress(imports.progress,
                            selection: imports.requestNumber, total: imports.requestCount))
                            .font(.caption)
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .accessibilityIdentifier("library-import-progress")
                }
                if imports.hasReport || imports.selectionMessage != nil {
                    LibraryImportReportView(presentation: imports)
                }
                Divider()
            }
        }
    }

    private var content: some View {
        // Keep the native text view mounted across modes so its undo stack,
        // marked-text ownership and selection belong to the editing session.
        ZStack(alignment: .topLeading) {
            source
                .accessibilityHidden(presentation.editorMode != .edit)
            if presentation.editorMode == .preview { preview }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var source: some View {
        LibrarySourceEditor(source: presentation.editorState.source ?? "",
            path: presentation.editorState.prompt?.relativePath,
            revision: presentation.sourceRevision,
            isEditable: presentation.canEditSource,
            onEdit: presentation.edit,
            highlight: presentation.quoteHighlight,
            focusRevision: presentation.editorMode == .edit ? presentation.editorFocusRevision : 0,
            isVisible: presentation.editorMode == .edit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var preview: some View {
        ScrollView {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                previewColumn
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .accessibilityLabel(LibraryStrings.preview)
        .accessibilityIdentifier("library-preview")
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let description = presentation.openPromptRow?.previewLine, !description.isEmpty {
                Text(description).foregroundStyle(.secondary)
            }
            previewBody
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(.vertical, 24)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var previewBody: some View {
        switch presentation.preview {
        case .none:
            Text(LibraryStrings.noSelection).foregroundStyle(.secondary)
        case .rendered(let text):
            Text(verbatim: text)
        case .issues(let issues):
            ForEach(Array(issues.enumerated()), id: \.offset) { issue in
                Label(EditorStrings.issue(issue.element), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var issueList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(presentation.editorState.issues.enumerated()), id: \.offset) { issue in
                    issueRow(issue.element)
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 140)
        .accessibilityIdentifier("library-validation")
    }

    private func issueRow(_ issue: PromptIssue) -> some View {
        Label(EditorStrings.issue(issue),
            systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(issue.severity == .error ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            validationButton
            statusText
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var validationButton: some View {
        let issues = presentation.editorState.issues
        let errors = issues.filter { $0.severity == .error }.count
        let summary: String
        let symbol: String
        let tint: Color
        if errors > 0 {
            summary = LibraryNativeStrings.errorCount(errors)
            symbol = "xmark.octagon.fill"
            tint = .red
        } else if !issues.isEmpty {
            summary = LibraryNativeStrings.issueCount(issues.count)
            symbol = "exclamationmark.triangle.fill"
            tint = .secondary
        } else {
            summary = LibraryCommandStrings.valid
            symbol = "checkmark.circle"
            tint = .secondary
        }
        return Button { showsIssues.toggle() } label: {
            Label(summary, systemImage: symbol)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .buttonStyle(.borderless)
        .disabled(issues.isEmpty)
        .accessibilityIdentifier("library-validation-summary")
    }

    /// Command results outrank Assistant and favourite outcomes, which in
    /// turn outrank the editor's own status line.
    private var statusText: some View {
        let message = presentation.commandMessage ?? presentation.assistantSaveMessage
            ?? presentation.favoriteMessage ?? EditorStrings.status(presentation.editorState)
        return Group {
            if statusIsError {
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    .accessibilityIdentifier(statusMessageIdentifier)
            } else {
                Text(message).accessibilityIdentifier(statusMessageIdentifier)
            }
        }
        .font(.caption)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-editor-status")
    }

    private var statusMessageIdentifier: String {
        if presentation.commandMessage != nil { return "library-command-message" }
        if presentation.assistantSaveMessage != nil { return "library-assistant-save-outcome" }
        if presentation.favoriteMessage != nil { return "library-favorite-message" }
        return "library-editor-message"
    }

    private var statusIsError: Bool {
        if presentation.commandMessage != nil {
            if case .failed = presentation.editorState.status { return true }
            return presentation.editorState.conflict != nil
        }
        if presentation.assistantSaveMessage != nil, let outcome = presentation.assistant?.state.acceptanceOutcome {
            switch outcome {
            case .conflict: return true
            case .failed(.cancelled): return false
            case .failed: return true
            case .saved, .committedWithProvenanceWarning: return false
            }
        }
        if presentation.favoriteMessage != nil { return true }
        if case .failed = presentation.editorState.status { return true }
        return false
    }
}

/// Inspector column: Fields, History and Assistant under one segmented picker.
struct LibraryInspectorView: View {
    @ObservedObject var presentation: LibraryViewState

    var body: some View {
        VStack(spacing: 0) {
            panePicker
            Divider()
            paneContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("library-inspector")
    }

    private var panePicker: some View {
        Picker(selection: Binding<LibraryViewState.InspectorPane>(
            get: { presentation.inspectorPane },
            set: { presentation.showInspector($0) })) {
            Image(systemName: "list.bullet.rectangle")
                .tag(LibraryViewState.InspectorPane.fields)
                .accessibilityLabel(EditorStrings.fieldsTab)
            Image(systemName: "clock.arrow.circlepath")
                .tag(LibraryViewState.InspectorPane.history)
                .accessibilityLabel(LibraryCommandStrings.historyTab)
            Image(systemName: "sparkles")
                .tag(LibraryViewState.InspectorPane.assistant)
                .accessibilityLabel(LibraryAssistantStrings.title)
        } label: {
            Text(verbatim: LibraryStrings.showInspector)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("library-inspector-picker")
    }

    @ViewBuilder
    private var paneContent: some View {
        switch presentation.inspectorPane {
        case .fields: fields
        case .history: LibraryHistoryView(presentation: presentation)
        case .assistant: assistantPane
        }
    }

    private var fields: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                promptInfo
                fieldCards
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(EditorStrings.parsedFields)
        .accessibilityIdentifier("library-fields")
    }

    private var promptInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LibraryNativeStrings.promptInfo).font(.headline)
                .accessibilityAddTraits(.isHeader)
            infoRow(LibraryNativeStrings.titleLabel, presentation.displayTitle)
            infoRow(LibraryNativeStrings.fileLabel, promptFile)
            infoRow(LibraryNativeStrings.tagsLabel, promptTags)
            infoRow(LibraryNativeStrings.statusLabel, promptStatus)
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
        } label: {
            Text(label).foregroundStyle(.secondary)
        }
    }

    private var promptFile: String {
        presentation.editorState.prompt?.relativePath.string ?? LibraryNativeStrings.none
    }

    private var promptTags: String {
        let tags = presentation.openPromptRow?.tags ?? []
        return tags.isEmpty ? LibraryNativeStrings.none : tags.joined(separator: ", ")
    }

    private var promptStatus: String {
        let status = EditorStrings.status(presentation.editorState)
        return status.isEmpty ? LibraryNativeStrings.ready : status
    }

    @ViewBuilder
    private var fieldCards: some View {
        if presentation.editorState.fields.isEmpty {
            Text(LibraryNativeStrings.noFields).foregroundStyle(.secondary)
        } else {
            ForEach(Array(presentation.editorState.fields.enumerated()), id: \.offset) { item in
                fieldCard(item.element)
            }
        }
    }

    private func fieldCard(_ field: PromptField) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                infoRow(LibraryNativeStrings.labelLabel, field.label)
                infoRow(LibraryNativeStrings.kindLabel, EditorStrings.fieldKind(field.kind))
                infoRow(EditorStrings.fieldDefault, field.defaultValue)
                if !field.options.isEmpty {
                    infoRow(EditorStrings.fieldOptions, optionsText(field))
                }
                infoRow(EditorStrings.fieldBehaviorHeader, EditorStrings.fieldBehavior(field))
                if let description = field.description, !description.isEmpty {
                    infoRow(LibraryNativeStrings.descriptionLabel, description)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(verbatim: field.name).font(.system(.callout, design: .monospaced))
        }
        .textSelection(.enabled)
    }

    private func optionsText(_ field: PromptField) -> String {
        field.options.map { $0.label + " = " + $0.value }.joined(separator: ", ")
    }

    @ViewBuilder
    private var assistantPane: some View {
        if let assistant = presentation.assistant {
            LibraryAssistantView(presentation: assistant)
        } else {
            Text(LibraryNativeStrings.assistantUnavailable)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        }
    }
}

private struct LibraryFolderNode: Identifiable {
    let section: LibraryBrowserSection
    var children: [LibraryFolderNode]?
    var id: LibrarySectionID { section.id }
}

/// One sidebar section's drop gate plus its accent highlight while targeted.
private struct LibraryScopeDropTarget: DropDelegate {
    let presentation: LibraryViewState
    let section: LibrarySectionID
    let epoch: UUID
    let targeted: Binding<LibrarySectionID?>

    func validateDrop(info: DropInfo) -> Bool {
        presentation.scopeDragEpoch == epoch && presentation.canDropScopeRow(onto: section)
            && info.hasItemsConforming(to: [LibraryViewState.scopeDragTypeIdentifier])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) { targeted.wrappedValue = section }

    func dropExited(info: DropInfo) { clearTarget() }

    func performDrop(info: DropInfo) -> Bool {
        clearTarget()
        return presentation.acceptScopeDrop(info.itemProviders(for: [LibraryViewState.scopeDragTypeIdentifier]),
            onto: section, epoch: epoch)
    }

    private func clearTarget() {
        if targeted.wrappedValue == section { targeted.wrappedValue = nil }
    }
}
