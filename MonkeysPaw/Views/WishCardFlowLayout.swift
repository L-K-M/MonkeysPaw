import SwiftUI

struct WishBreak: LayoutValueKey { static let defaultValue = false }
struct WishWide: LayoutValueKey { static let defaultValue = false }

/// Word runs and native blanks share a baseline. Explicit newlines survive
/// wrapping, and wells/slips get the whole line without widening the panel.
struct WishCardFlowLayout: Layout {
    private struct Item {
        let index: Int
        let size: CGSize
        let baseline: CGFloat
        let x: CGFloat
    }
    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var ascent: CGFloat = 17
        var descent: CGFloat = 5
        var height: CGFloat { ascent + descent }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let offered = proposal.width ?? 400
        let width = offered.isFinite ? max(1, offered) : 400
        let rows = arrange(subviews, width: width)
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height + 3 })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: max(1, bounds.width)) {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: y + row.ascent - item.baseline),
                    anchor: .topLeading, proposal: ProposedViewSize(item.size))
            }
            y += row.height + 3
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let view = subviews[index]
            if view[WishBreak.self] {
                rows.append(row)
                row = Row()
                continue
            }
            let wide = view[WishWide.self]
            let ideal = view.sizeThatFits(.unspecified)
            let proposed = ProposedViewSize(width: wide ? width : min(width, ideal.width), height: nil)
            let dimensions = view.dimensions(in: proposed)
            let size = CGSize(width: min(width, dimensions.width), height: dimensions.height)
            if !row.items.isEmpty && (wide || row.width + size.width > width) {
                rows.append(row)
                row = Row()
            }
            let baseline = dimensions[.firstTextBaseline]
            row.items.append(Item(index: index, size: size, baseline: baseline, x: row.width))
            row.width += size.width
            row.ascent = max(row.ascent, baseline)
            row.descent = max(row.descent, size.height - baseline)
            if wide { rows.append(row); row = Row() }
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
