import MonkeysPawCore
import SwiftUI

struct LibraryConflictView: View {
    @ObservedObject var presentation: LibraryConflictViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LibraryConflictStrings.title).font(.headline)
            ScrollView {
                if let diff = presentation.diff {
                    LibraryDiffView(diff: diff, title: LibraryConflictStrings.title,
                        originalTitle: LibraryConflictStrings.serverVersion,
                        candidateTitle: LibraryConflictStrings.myVersion,
                        accessibilityID: "library-conflict-diff")
                }
            }
            if presentation.opening || presentation.refreshPending || presentation.state?.isBusy == true {
                ProgressView().controlSize(.small)
            }
            Text(presentation.message).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("library-conflict-status")
            HStack {
                Button(LibraryConflictStrings.keepServer) { presentation.requestResolution(.keepServer) }
                    .disabled(!presentation.canResolve(.keepServer))
                    .accessibilityIdentifier("library-conflict-keep-server")
                Button(LibraryConflictStrings.keepMine) { presentation.requestResolution(.keepMine) }
                    .disabled(!presentation.canResolve(.keepMine))
                    .accessibilityIdentifier("library-conflict-keep-mine")
                Button(LibraryConflictStrings.keepBoth) { presentation.requestResolution(.keepBoth) }
                    .disabled(!presentation.canResolve(.keepBoth))
                    .accessibilityIdentifier("library-conflict-keep-both")
            }
            Button(LibraryConflictStrings.refresh) { presentation.refreshComparison() }
                .disabled(!presentation.canRefresh)
                .accessibilityIdentifier("library-conflict-refresh")
        }
        .padding(12)
        .accessibilityIdentifier("library-conflict")
    }
}
