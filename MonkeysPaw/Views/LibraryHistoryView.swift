import MonkeysPawCore
import SwiftUI

struct LibraryHistoryView: View {
    @ObservedObject var presentation: LibraryViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(LibraryCommandStrings.refreshHistory, action: presentation.loadHistory)
                    .disabled(!presentation.canLoadHistory || presentation.editorState.history.isLoading)
                Spacer()
                Button(LibraryCommandStrings.restore, action: presentation.restoreRevision)
                    .disabled(!presentation.canRestoreRevision)
                    .accessibilityIdentifier("library-restore")
            }
            if presentation.editorState.history.isLoading {
                Text(LibraryCommandStrings.loadingHistory).font(.caption)
            }
            if let failure = presentation.editorState.history.failure {
                Text(EditorStrings.editingFailure(failure)).foregroundStyle(.red)
                    .accessibilityIdentifier("library-history-failure")
            }
            VSplitView {
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
                .frame(minHeight: 100)
                .accessibilityLabel(LibraryCommandStrings.revisions)
                .accessibilityIdentifier("library-history-list")
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
        .padding(8)
    }
}
