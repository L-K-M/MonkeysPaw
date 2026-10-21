import MonkeysPawCore
import SwiftUI

/// Compact sync-conflict bar shown above the editor: the message and
/// resolution choices with the comparison behind a Compare disclosure.
struct LibraryConflictView: View {
    @ObservedObject var presentation: LibraryConflictViewState
    @State private var showsComparison = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    Text(presentation.message)
                        .font(.callout)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("library-conflict-status")
                    if presentation.opening || presentation.refreshPending || presentation.state?.isBusy == true {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 4)
                    Button { showsComparison.toggle() } label: {
                        Label(LibraryNativeStrings.compare,
                            systemImage: showsComparison ? "chevron.down" : "chevron.right")
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("library-conflict-compare")
                }
                HStack(spacing: 8) {
                    Button(LibraryConflictStrings.keepServer) { presentation.requestResolution(.keepServer) }
                        .controlSize(.small)
                        .disabled(!presentation.canResolve(.keepServer))
                        .accessibilityIdentifier("library-conflict-keep-server")
                    Button(LibraryConflictStrings.keepMine) { presentation.requestResolution(.keepMine) }
                        .controlSize(.small)
                        .disabled(!presentation.canResolve(.keepMine))
                        .accessibilityIdentifier("library-conflict-keep-mine")
                    Button(LibraryConflictStrings.keepBoth) { presentation.requestResolution(.keepBoth) }
                        .controlSize(.small)
                        .disabled(!presentation.canResolve(.keepBoth))
                        .accessibilityIdentifier("library-conflict-keep-both")
                    Spacer(minLength: 4)
                    Button(LibraryConflictStrings.refresh) { presentation.refreshComparison() }
                        .controlSize(.small)
                        .disabled(!presentation.canRefresh)
                        .accessibilityIdentifier("library-conflict-refresh")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if showsComparison {
                Divider()
                Group {
                    if let diff = presentation.diff {
                        ScrollView {
                            LibraryDiffView(diff: diff, title: LibraryConflictStrings.comparison,
                                originalTitle: LibraryConflictStrings.serverVersion,
                                candidateTitle: LibraryConflictStrings.myVersion,
                                accessibilityID: "library-conflict-diff")
                            .padding(8)
                        }
                    } else {
                        Text(presentation.message)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .accessibilityIdentifier("library-conflict")
    }
}
