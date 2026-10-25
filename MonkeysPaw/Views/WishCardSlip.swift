import MonkeysPawCore
import SwiftUI

/// This view receives the form's one resolved snapshot. The thumbnail has no
/// snapshot, so selecting a result never reads clipboard or remembered values.
struct WishCardSlip: View, Equatable {
    enum Mode: Equatable { case thumbnail, fill }
    /// One immutable projection per snapshot. Identity comparison keeps large
    /// clipboard strings out of the card's per-keystroke diff and layout.
    final class Content {
        fileprivate enum Phase { case thumbnail, pending, empty, filled }
        fileprivate let phase: Phase
        fileprivate let lines: [String]
        fileprivate let caption: String
        fileprivate let hasOverflow: Bool

        init(mode: Mode, text: String? = nil, summary: ClipboardSummary? = nil) {
            if mode == .thumbnail {
                phase = .thumbnail
            } else if let summary {
                phase = summary.kind == .empty ? .empty : .filled
            } else { phase = .pending }
            caption = summary.map(WishCardSlip.caption) ?? ""
            hasOverflow = (summary?.lineCount ?? 0) > WishCardSlip.maximumLines
            lines = (text ?? "").split(maxSplits: WishCardSlip.maximumLines, omittingEmptySubsequences: false) {
                $0 == "\n" || $0 == "\r\n"
            }.prefix(WishCardSlip.maximumLines).map { WishCardSlip.displayable(String($0)) }
        }
    }

    let content: Content

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.content === rhs.content }
    static let thumbnailMessage = "Your clipboard goes here"
    static let pendingMessage = "Reading your clipboard…"
    static let emptyMessage = "Your clipboard is empty. Copy text first, then summon again."
    private static let maximumLines = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if content.phase == .filled {
                Text(content.caption).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(WishCardStyle.brassRim)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                ForEach(Array(content.lines.enumerated()), id: \.offset) { index, line in
                    Text(line).font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(WishCardStyle.bodyInk)
                        .opacity(index == Self.maximumLines - 1 && content.hasOverflow ? 0.35 : 1)
                }
            } else {
                Text(message).font(.system(size: 11.5, design: .monospaced)).italic()
                    .foregroundStyle(content.phase == .empty ? WishCardStyle.errorInk : WishCardStyle.folderInk)
                    .frame(maxWidth: .infinity, minHeight: content.phase == .empty ? 48 : 24, alignment: .leading)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WishTear().fill(WishCardStyle.slipPaper))
        .overlay(WishTear().stroke(WishCardStyle.blankRule.opacity(0.5), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wish-slip")
    }

    private var message: String {
        if content.phase == .thumbnail { return Self.thumbnailMessage }
        return content.phase == .empty ? Self.emptyMessage : Self.pendingMessage
    }

    static func caption(_ summary: ClipboardSummary) -> String {
        "CLIPBOARD · \(summary.lineCount) LINES · \(summary.kind.rawValue.uppercased())"
    }

    static func displayable(_ line: String) -> String {
        var result = ""
        for scalar in line.unicodeScalars {
            if scalar == "\t" { result += "    " }
            else if scalar.properties.generalCategory != .control { result.unicodeScalars.append(scalar) }
        }
        return result
    }
}

private struct WishTear: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = max(1, Int(rect.width / 7))
        path.move(to: CGPoint(x: 0, y: 3))
        for index in 0...count {
            let x = min(rect.width, CGFloat(index) * 7)
            path.addLine(to: CGPoint(x: x, y: CGFloat(index % 3) + 1))
            path.addLine(to: CGPoint(x: min(rect.width, x + 3.5), y: 0))
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - 3))
        for index in (0...count).reversed() {
            let x = min(rect.width, CGFloat(index) * 7)
            path.addLine(to: CGPoint(x: x, y: rect.height - CGFloat(index % 3) - 1))
            path.addLine(to: CGPoint(x: max(0, x - 3.5), y: rect.height))
        }
        path.closeSubpath()
        return path
    }
}
