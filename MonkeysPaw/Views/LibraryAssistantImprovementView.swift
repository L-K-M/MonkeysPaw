import MonkeysPawCore
import SwiftUI

struct LibraryAssistantImprovementView: View {
    @ObservedObject var presentation: LibraryAssistantViewState
    let promptTitle: String

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            bar
        }
        .accessibilityIdentifier("library-assistant")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: promptTitle).font(.title3.weight(.semibold))
                .lineLimit(1).truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            if let request = presentation.improvementRequest {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    if !request.instruction.isEmpty {
                        GridRow(alignment: .firstTextBaseline) {
                            Text(LibraryAssistantStrings.requestInstruction).font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: "“\(request.instruction)”").font(.callout)
                                .lineLimit(3).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !request.findings.isEmpty {
                        GridRow(alignment: .firstTextBaseline) {
                            Text(LibraryAssistantStrings.requestFindings).font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: LibraryAssistantStrings.findingsSummary(request.findings)).font(.callout)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if presentation.state.mutationAccess == .privateCopy {
                Label(LibraryAssistantStrings.viewer, systemImage: "info.circle").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder private var stageContent: some View {
        switch presentation.improvementStage {
        case .working:
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text(LibraryAssistantStrings.generatingImprovements).font(.title3)
                Text(LibraryAssistantStrings.closingCancels).font(.caption).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center).padding(16)
        case .preparing:
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text(LibraryAssistantStrings.preparingDiff).font(.title3)
            }
            .multilineTextAlignment(.center).padding(16)
        case .saving, .ready:
            readyContent
        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(presentation.resultMessage).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("library-assistant-result")
            }
            .multilineTextAlignment(.center).padding(16)
        case .invalid:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(LibraryAssistantStrings.invalidImprovement)
                        .accessibilityIdentifier("library-assistant-result")
                    LibraryAssistantIssueList(issues: presentation.state.issues)
                    notes
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        case .outdated:
            VStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.largeTitle)
                    .accessibilityHidden(true)
                Text(presentation.resultMessage).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("library-assistant-result")
            }
            .multilineTextAlignment(.center).padding(16)
        case .ended:
            Color.clear
        }
    }

    private var readyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // While saving, the bar reports progress; one status line is enough.
                if presentation.improvementStage == .ready {
                    Text(presentation.resultMessage).font(.caption)
                        .accessibilityIdentifier("library-assistant-result")
                }
                let warnings = presentation.state.issues.filter { $0.severity == .warning }
                if !warnings.isEmpty { LibraryAssistantIssueList(issues: warnings) }
                if let diff = presentation.state.diff {
                    LibraryDiffView(diff: diff, title: LibraryAssistantStrings.diffTitle,
                        candidateTitle: LibraryAssistantStrings.improvedColumn)
                }
                notes
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }

    @ViewBuilder private var notes: some View {
        if let notes = presentation.state.artifact?.notes, !notes.isEmpty {
            Text(LibraryAssistantStrings.draftNotes).font(.headline)
            Text(verbatim: notes).textSelection(.enabled)
        }
    }

    private var bar: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if showsRetry {
                    HStack {
                        TextField(LibraryAssistantStrings.feedback, text: $presentation.feedback)
                            .accessibilityLabel(LibraryAssistantStrings.feedback)
                            .onSubmit(presentation.retry)
                        Button(LibraryAssistantStrings.retry, action: presentation.retry)
                            .accessibilityIdentifier("library-assistant-retry")
                            .fixedSize()
                    }
                }
                HStack(spacing: 8) {
                    Text(presentation.footer).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .accessibilityIdentifier("library-assistant-footer")
                    Spacer(minLength: 12)
                    stageButtons.fixedSize()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var showsRetry: Bool {
        guard presentation.canRetry else { return false }
        switch presentation.improvementStage {
        case .failed, .invalid, .outdated, .ready: return true
        default: return false
        }
    }

    private var stageButtons: some View {
        HStack(spacing: 8) {
            switch presentation.improvementStage {
            case .working, .preparing:
                cancelButton
            case .saving:
                ProgressView().controlSize(.small)
                Text(presentation.resultMessage).font(.caption)
                cancelButton
            case .failed:
                Button(MainMenuStrings.close, action: presentation.cancel)
                    .accessibilityIdentifier("library-assistant-close")
                if presentation.showsRefresh { showDiffButton }
            case .invalid, .ready:
                rejectButton
                acceptButton
            case .outdated:
                rejectButton
                if presentation.showsRefresh { showDiffButton.buttonStyle(.borderedProminent) }
                acceptButton
            case .ended:
                EmptyView()
            }
        }
    }

    private var cancelButton: some View {
        Button(LibraryAssistantStrings.cancel, action: presentation.cancel)
            .accessibilityIdentifier("library-assistant-cancel")
    }

    private var rejectButton: some View {
        Button(LibraryAssistantStrings.reject, action: presentation.reject)
            .accessibilityIdentifier("library-assistant-reject")
    }

    private var acceptButton: some View {
        Button(LibraryAssistantStrings.accept, action: presentation.accept)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!presentation.canAccept)
            .accessibilityIdentifier("library-assistant-accept")
    }

    private var showDiffButton: some View {
        Button(LibraryAssistantStrings.showDiff, action: presentation.showDiff)
            .accessibilityIdentifier("library-assistant-show-diff")
    }
}
