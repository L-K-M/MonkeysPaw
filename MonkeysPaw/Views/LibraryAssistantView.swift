import Foundation
import MonkeysPawCore
import SwiftUI

struct LibraryAssistantView: View {
    enum Purpose { case currentPrompt, newPrompt }

    @ObservedObject var presentation: LibraryAssistantViewState
    var purpose = Purpose.currentPrompt
    @FocusState private var instructionFocused: Bool
    @State private var appliedFocusRevision: UInt64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if purpose == .currentPrompt {
                Picker(LibraryAssistantStrings.flow, selection: $presentation.flow) {
                    Text(LibraryAssistantStrings.reviewAndImprove).tag(LibraryAssistantViewState.Flow.review)
                    Text(LibraryAssistantStrings.improveDirectly).tag(LibraryAssistantViewState.Flow.improve)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(presentation.isWorking || presentation.state.isAccepting)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    inputs
                    if presentation.state.mutationAccess == .privateCopy {
                        Text(LibraryAssistantStrings.viewer).font(.caption)
                    }
                    if presentation.isWorking {
                        HStack { ProgressView().controlSize(.small); Text(LibraryAssistantStrings.working) }
                    }
                    if !presentation.resultMessage.isEmpty {
                        Text(presentation.resultMessage).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("library-assistant-result")
                    }
                    if purpose == .currentPrompt, presentation.flow == .review,
                       let review = presentation.state.review { findings(review) }
                    if purpose == .currentPrompt {
                        if presentation.canShowImprovement {
                            Button(LibraryAssistantStrings.openImprovement, action: presentation.showImprovement)
                                .accessibilityIdentifier("library-assistant-open-improvement")
                        } else {
                            actions
                        }
                    } else {
                        if let artifact = presentation.state.artifact { draft(artifact) }
                        LibraryAssistantIssueList(issues: presentation.state.issues)
                        if let diff = presentation.state.diff { LibraryDiffView(diff: diff) }
                        actions
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text(presentation.footer).font(.caption).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("library-assistant-footer")
        }
        .padding(12)
        .accessibilityIdentifier("library-assistant")
        .onChange(of: presentation.instructionFocusRevision) { _ in
            applyInstructionFocus()
        }
        .onAppear { applyInstructionFocus() }
    }

    /// A focus bump may arrive before the inspector mounts this view; the
    /// applied marker keeps each request once-only either way.
    private func applyInstructionFocus() {
        guard presentation.instructionFocusRevision != appliedFocusRevision else { return }
        appliedFocusRevision = presentation.instructionFocusRevision
        guard presentation.flow == .improve else { return }
        instructionFocused = true
    }

    @ViewBuilder private var inputs: some View {
        if purpose == .newPrompt {
            Text(LibraryAssistantStrings.writeHint).font(.caption)
            TextEditor(text: $presentation.brief).frame(minHeight: 72, maxHeight: 120)
                .accessibilityLabel(LibraryAssistantStrings.brief)
                .disabled(presentation.isWorking || presentation.state.isAccepting)
            Button(LibraryAssistantStrings.generate, action: presentation.write).disabled(!presentation.canWrite)
                .accessibilityIdentifier("library-assistant-write")
            if let message = presentation.writeDisabledMessage { Text(message).font(.caption) }
        } else {
            switch presentation.flow {
            case .review:
                Text(LibraryAssistantStrings.reviewHint).font(.caption)
                Button(LibraryAssistantStrings.review, action: presentation.review).disabled(!presentation.canReview)
                    .accessibilityIdentifier("library-assistant-review")
                if let message = presentation.sourceDisabledMessage { Text(message).font(.caption) }
            case .improve:
                instruction
                if let message = presentation.sourceDisabledMessage { Text(message).font(.caption) }
            }
        }
    }

    private var instruction: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(LibraryAssistantStrings.instruction, text: Binding(get: { presentation.state.instruction },
                set: presentation.editInstruction))
                .accessibilityLabel(LibraryAssistantStrings.instruction)
                .focused($instructionFocused)
                .disabled(presentation.isWorking || presentation.state.isAccepting)
            Text(LibraryAssistantStrings.instructionHint).font(.caption)
            if presentation.flow == .improve, !presentation.state.selectedFindings.isEmpty {
                Text(LibraryAssistantStrings.selectedFindingsHint).font(.caption)
            }
            Button(presentation.improveTitle, action: presentation.improve).disabled(!presentation.canImprove)
                .accessibilityIdentifier("library-assistant-improve")
        }
    }

    private func findings(_ review: LlmReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: review.summary).textSelection(.enabled)
            ForEach(Array(review.findings.enumerated()), id: \.offset) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(get: { presentation.state.selectedFindings.contains(item.offset) },
                        set: { _ in presentation.toggleFinding(item.offset) })) {
                        Text(LibraryAssistantStrings.severity(item.element.severity) + " · "
                            + LibraryAssistantStrings.criterion(item.element.criterion))
                            .foregroundStyle(severityColor(item.element.severity))
                    }
                    .disabled(!presentation.canSelectFindings)
                    Text(verbatim: item.element.problem)
                    Text(verbatim: item.element.suggestion).foregroundStyle(.secondary)
                    Text(verbatim: item.element.quote).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    switch item.element.quoteMatch {
                    case .matched:
                        Button(LibraryAssistantStrings.showQuote) { presentation.highlightFinding(item.offset) }
                            .disabled(!presentation.canSelectFindings)
                    case .unmatched:
                        Text(LibraryAssistantStrings.unmatched).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
            instruction
        }
        .accessibilityIdentifier("library-assistant-findings")
    }

    private func severityColor(_ severity: LlmReviewSeverity) -> Color {
        switch severity {
        case .high: return .red
        case .medium: return .orange
        case .low: return .secondary
        }
    }

    private func draft(_ artifact: LlmArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LibraryAssistantStrings.draft).font(.headline)
            Text(verbatim: artifact.title).font(.headline)
            Text(verbatim: artifact.description)
            Text(verbatim: artifact.tags.joined(separator: ", ")).font(.caption)
            ForEach(Array(artifact.fields.enumerated()), id: \.offset) { item in
                Text(verbatim: item.element.name + " · " + EditorStrings.fieldKind(item.element.type))
                    .font(.caption)
            }
            Text(verbatim: artifact.body).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            if !artifact.notes.isEmpty {
                Text(LibraryAssistantStrings.draftNotes).font(.caption)
                Text(verbatim: artifact.notes).textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("library-assistant-draft")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if presentation.isWorking || presentation.state.isAccepting {
                Button(LibraryAssistantStrings.cancel, action: presentation.cancel)
            } else {
                if presentation.state.artifact != nil {
                    HStack {
                        Button(LibraryAssistantStrings.showDiff, action: presentation.showDiff).disabled(!presentation.canShowDiff)
                        Button(LibraryAssistantStrings.accept, action: presentation.accept).disabled(!presentation.canAccept)
                            .accessibilityIdentifier("library-assistant-accept")
                        Button(LibraryAssistantStrings.reject, action: presentation.reject)
                            .accessibilityIdentifier("library-assistant-reject")
                    }
                }
                if presentation.canRetry {
                    TextField(LibraryAssistantStrings.feedback, text: $presentation.feedback)
                        .accessibilityLabel(LibraryAssistantStrings.feedback)
                    Button(LibraryAssistantStrings.retry, action: presentation.retry)
                        .accessibilityIdentifier("library-assistant-retry")
                }
            }
        }
    }
}

struct LibraryAssistantIssueList: View {
    let issues: [PromptIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(issues.enumerated()), id: \.offset) { item in
                Text(EditorStrings.issue(item.element))
                    .foregroundStyle(item.element.severity == .error ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("library-assistant-validation")
    }
}
