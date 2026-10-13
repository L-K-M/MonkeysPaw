import MonkeysPawCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryImportControls: View {
    @ObservedObject var presentation: LibraryImportViewState

    var body: some View {
        HStack(spacing: 12) {
            Button(ImportStrings.action, action: presentation.choose)
                .disabled(!presentation.canImport)
                .accessibilityIdentifier("library-import")
            Picker(ImportStrings.destination, selection: Binding(get: { presentation.destination },
                set: presentation.selectDestination)) {
                ForEach(presentation.destinations, id: \.self) { path in
                    Text(verbatim: path.string + "/").tag(path)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(!presentation.canImport)
            .accessibilityIdentifier("library-import-destination")
            Spacer()
            if presentation.isBusy {
                ProgressView().controlSize(.small)
                Text(ImportStrings.progress(presentation.progress,
                    selection: presentation.requestNumber, total: presentation.requestCount))
                    .font(.caption).accessibilityIdentifier("library-import-progress")
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }
}

struct LibraryImportReportView: View {
    @ObservedObject var presentation: LibraryImportViewState

    var body: some View {
        if presentation.hasReport || presentation.selectionMessage != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(ImportStrings.report).font(.headline)
                    if presentation.hasReport {
                        Text(ImportStrings.summary(created: presentation.createdCount, skipped: presentation.skippedCount))
                            .font(.caption)
                    }
                    Spacer()
                    Button(ImportStrings.dismiss, action: presentation.dismissReport).disabled(presentation.isBusy)
                        .accessibilityIdentifier("library-import-dismiss")
                }
                if let message = presentation.selectionMessage {
                    Text(message).font(.caption).accessibilityIdentifier("library-import-message")
                }
                if presentation.hasReport {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(presentation.reports.enumerated()), id: \.offset) { item in
                                if let failure = item.element.report.failure {
                                    Text(verbatim: item.element.source + ": " + ImportStrings.failed(failure))
                                }
                            }
                            ForEach(Array(presentation.files.enumerated()), id: \.offset) { item in
                                file(item.element)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                    .accessibilityLabel(ImportStrings.report)
                    .accessibilityIdentifier("library-import-report")
                }
            }
            .padding(12)
        }
    }

    private func file(_ file: ImportFileReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: file.sourcePath).font(.caption).foregroundStyle(.secondary)
            switch file.outcome {
            case .created(let path):
                Button(ImportStrings.created(path)) { presentation.open(path) }
                    .disabled(!presentation.libraryAvailable)
            case .skipped(let reason): Text(ImportStrings.skipped(reason))
            }
            ForEach(Array(file.mapping.mappings.enumerated()), id: \.offset) { item in
                Text(verbatim: ImportStrings.mapping(item.element)).font(.caption)
            }
            if !file.mapping.preservedKeys.isEmpty {
                Text(verbatim: ImportStrings.preserved(file.mapping.preservedKeys)).font(.caption)
            }
            ForEach(Array(file.mapping.dropped.enumerated()), id: \.offset) { item in
                Text(ImportStrings.loss(item.element)).font(.caption)
            }
            ForEach(Array(file.mapping.warnings.enumerated()), id: \.offset) { item in
                Text(verbatim: ImportStrings.warning(item.element)).font(.caption)
            }
        }
    }
}

/// Keeps SwiftUI's asynchronous item-provider bridge tied to the current graph.
struct LibraryImportDropTarget: ViewModifier {
    @ObservedObject var presentation: LibraryImportViewState

    func body(content: Content) -> some View {
        content.onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: presentation.acceptDrop)
    }
}
