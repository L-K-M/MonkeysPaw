import Foundation
import MonkeysPawCore
import SwiftUI

/// Byte-preserving rows shared by Assistant and sync conflict comparisons.
struct LibraryDiffView: View {
    private enum Side { case original, candidate }

    let diff: ArtifactDiff
    var title = "Merged diff"
    var originalTitle = "Current"
    var candidateTitle = "Candidate"
    var accessibilityID = "library-assistant-diff"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(diff.placeholderWarnings.enumerated()), id: \.offset) { item in
                Text(LibraryAssistantStrings.placeholder(item.element)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(originalTitle).frame(maxWidth: .infinity)
                    Text(candidateTitle).frame(maxWidth: .infinity)
                }
                section("Front matter", lines: diff.frontMatter)
                section("Body", lines: diff.body)
            }
        }
        .accessibilityIdentifier(accessibilityID)
    }

    private func section(_ title: String, lines: [LineDiffLine]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text(title).font(.subheadline).padding(.vertical, 4)
            ForEach(Array(lines.enumerated()), id: \.offset) { item in
                HStack(alignment: .top, spacing: 0) {
                    line(item.element, side: .original)
                    Divider()
                    line(item.element, side: .candidate)
                }
            }
        }
    }

    private func line(_ line: LineDiffLine, side: Side) -> some View {
        let candidate = side == .candidate
        let visible = candidate ? line.kind != .removed : line.kind != .added
        let color: Color
        switch line.kind {
        case .unchanged: color = .clear
        case .removed: color = candidate ? .clear : .red.opacity(0.12)
        case .added: color = candidate ? .green.opacity(0.12) : .clear
        }
        return HStack(alignment: .top, spacing: 6) {
            Text(visible ? String((candidate ? line.mergedLine : line.originalLine) ?? 0) : "")
                .foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
            Text(verbatim: visible ? displayLine(line.bytes) : " ").textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if visible, !line.placeholderWarnings.isEmpty { Text("Warning").foregroundStyle(.orange) }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(4).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).background(color)
    }

    private func displayLine(_ bytes: Data) -> String {
        if bytes.suffix(2) == Data([13, 10]) { return String(decoding: bytes.dropLast(2), as: UTF8.self) + " ␍↵" }
        if bytes.last == 10 { return String(decoding: bytes.dropLast(), as: UTF8.self) + " ↵" }
        return String(decoding: bytes, as: UTF8.self) + " (no newline)"
    }
}
