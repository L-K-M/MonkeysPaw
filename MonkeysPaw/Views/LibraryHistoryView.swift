import MonkeysPawCore
import SwiftUI

/// Inspector history pane: a narrow revision list above a scrollable source
/// preview. Refresh sits at the top; Restore lives at the bottom.
struct LibraryHistoryView: View {
    @ObservedObject var presentation: LibraryViewState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: presentation.loadHistory) {
                    Label(LibraryCommandStrings.refreshHistory, systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .disabled(!presentation.canLoadHistory || presentation.editorState.history.isLoading)
                .accessibilityLabel(LibraryCommandStrings.refreshHistory)
                .accessibilityIdentifier("library-history-refresh")
                if presentation.editorState.history.isLoading {
                    ProgressView().controlSize(.small)
                    Text(LibraryCommandStrings.loadingHistory)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let failure = presentation.editorState.history.failure {
                    Label(EditorStrings.editingFailure(failure), systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("library-history-failure")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            if presentation.editorState.history.revisions.isEmpty, !presentation.editorState.history.isLoading {
                // One centered message instead of an empty list over an empty preview.
                ContentUnavailableView(LibraryCommandStrings.noRevisionsTitle, systemImage: "clock.arrow.circlepath",
                    description: Text(LibraryCommandStrings.noHistory))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("library-history-preview")
            } else {
                VSplitView {
                    revisionList
                    previewPane
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(LibraryCommandStrings.restore, action: presentation.restoreRevision)
                    .disabled(!presentation.canRestoreRevision)
                    .accessibilityIdentifier("library-restore")
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var revisionList: some View {
        List(selection: Binding<String?>(get: {
            presentation.editorState.history.selectedRevision?.filename
        }, set: presentation.selectRevision)) {
            ForEach(presentation.editorState.history.revisions, id: \.revision.filename) { snapshot in
                VStack(alignment: .leading, spacing: 4) {
                    Text(LibraryCommandStrings.timestamp(snapshot.revision.timestamp))
                    Text(LibraryCommandStrings.byteSize(snapshot.byteCount) + " · "
                        + (snapshot.isForensic ? LibraryCommandStrings.forensic : LibraryCommandStrings.valid))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(snapshot.revision.filename)
            }
        }
        .frame(minHeight: 80)
        .accessibilityLabel(LibraryCommandStrings.revisions)
        .accessibilityIdentifier("library-history-list")
    }

    private var previewPane: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 8) {
                if let snapshot = presentation.selectedRevision {
                    if let reason = snapshot.restoreFailure {
                        Text(LibraryCommandStrings.restoreRefusal(reason)).foregroundStyle(.secondary)
                    }
                    if let source = snapshot.source {
                        Text(verbatim: source).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text(snapshot.byteCount > Limits.maxPromptBytes
                            ? LibraryCommandStrings.oversizedPreview : LibraryCommandStrings.noUTF8Preview)
                    }
                } else {
                    if presentation.editorState.history.isLoading {
                        Text(LibraryCommandStrings.loadingHistory).foregroundStyle(.secondary)
                    } else if presentation.editorState.history.revisions.isEmpty {
                        Text(LibraryCommandStrings.noHistory).foregroundStyle(.secondary)
                    } else {
                        Text(LibraryCommandStrings.selectRevision).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading).padding(8)
        }
        .frame(minHeight: 100)
        .accessibilityLabel(LibraryCommandStrings.historyPreview)
        .accessibilityIdentifier("library-history-preview")
    }
}
