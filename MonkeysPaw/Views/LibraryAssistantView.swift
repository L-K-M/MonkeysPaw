import Foundation
import MonkeysPawCore
import SwiftUI

struct LibraryAssistantView: View {
    @ObservedObject var presentation: LibraryAssistantViewState
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(LibraryAssistantStrings.title).font(.headline)
                Spacer()
                Button("Close Assistant", action: close)
                    .accessibilityIdentifier("library-assistant-close")
            }
            Picker("Assistant flow", selection: $presentation.flow) {
                Text("Write").tag(LibraryAssistantViewState.Flow.write)
                Text("Review").tag(LibraryAssistantViewState.Flow.review)
                Text("Improve").tag(LibraryAssistantViewState.Flow.improve)
            }
            .pickerStyle(.segmented)
            .disabled(presentation.isWorking || presentation.state.isAccepting)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    inputs
                    if presentation.state.mutationAccess == .privateCopy {
                        Text(LibraryAssistantStrings.viewer).font(.caption)
                    }
                    if presentation.isWorking {
                        HStack { ProgressView().controlSize(.small); Text("Working…") }
                    }
                    Text(presentation.resultMessage).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("library-assistant-result")
                    if let review = presentation.state.review { findings(review) }
                    if let artifact = presentation.state.artifact { draft(artifact) }
                    issues
                    if let diff = presentation.state.diff { LibraryDiffView(diff: diff) }
                    actions
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
    }

    @ViewBuilder private var inputs: some View {
        switch presentation.flow {
        case .write:
            Text("Describe the reusable prompt you want to write.").font(.caption)
            TextEditor(text: $presentation.brief).frame(minHeight: 72, maxHeight: 120)
                .accessibilityLabel("Prompt brief")
                .disabled(presentation.isWorking || presentation.state.isAccepting)
            Button("Write", action: presentation.write).disabled(!presentation.canWrite)
                .accessibilityIdentifier("library-assistant-write")
            if let message = presentation.writeDisabledMessage { Text(message).font(.caption) }
        case .review:
            Text("Review the current template against the prompt rubric.").font(.caption)
            Button("Review", action: presentation.review).disabled(!presentation.canReview)
                .accessibilityIdentifier("library-assistant-review")
            if let message = presentation.sourceDisabledMessage { Text(message).font(.caption) }
        case .improve:
            instruction
            if let message = presentation.sourceDisabledMessage { Text(message).font(.caption) }
        }
    }

    private var instruction: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Improvement instruction", text: Binding(get: { presentation.state.instruction },
                set: presentation.editInstruction))
                .accessibilityLabel("Improvement instruction")
                .disabled(presentation.isWorking || presentation.state.isAccepting)
            Text("Use selected findings, an instruction, or both.").font(.caption)
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
                        Button("Show quote in editor") { presentation.highlightFinding(item.offset) }
                            .disabled(!presentation.canSelectFindings)
                    case .unmatched:
                        Text(LibraryAssistantStrings.unmatched).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
            if presentation.flow != .improve { instruction }
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
            Text("Draft").font(.headline)
            Text(verbatim: artifact.title).font(.headline)
            Text(verbatim: artifact.description)
            Text(verbatim: artifact.tags.joined(separator: ", ")).font(.caption)
            ForEach(Array(artifact.fields.enumerated()), id: \.offset) { item in
                Text(verbatim: item.element.name + " · " + EditorStrings.fieldKind(item.element.type))
                    .font(.caption)
            }
            Text(verbatim: artifact.body).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            if !artifact.notes.isEmpty {
                Text("Draft notes (not saved)").font(.caption)
                Text(verbatim: artifact.notes).textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("library-assistant-draft")
    }

    private var issues: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(presentation.state.issues.enumerated()), id: \.offset) { item in
                Text(EditorStrings.issue(item.element))
                    .foregroundStyle(item.element.severity == .error ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("library-assistant-validation")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if presentation.isWorking || presentation.state.isAccepting {
                Button("Cancel", action: presentation.cancel)
            } else {
                HStack {
                    Button("Show diff", action: presentation.showDiff).disabled(!presentation.canShowDiff)
                    Button("Accept", action: presentation.accept).disabled(!presentation.canAccept)
                        .accessibilityIdentifier("library-assistant-accept")
                    Button("Reject", action: presentation.reject)
                        .accessibilityIdentifier("library-assistant-reject")
                }
                TextField("Feedback for retry", text: $presentation.feedback)
                    .accessibilityLabel("Feedback for retry")
                Button("Retry with feedback", action: presentation.retry).disabled(!presentation.canRetry)
                    .accessibilityIdentifier("library-assistant-retry")
            }
        }
    }
}
