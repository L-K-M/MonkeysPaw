import Foundation
import MonkeysPawCore

/// Pure geometry, independent of NSScreen and other AppKit state.
enum PanelPlacement {
    static func screenIndex(at cursor: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(cursor) }
    }

    static func frame(at cursor: CGPoint, in visibleFrame: CGRect) -> CGRect {
        // visibleFrame excludes the menu bar and Dock. Shrink for a small
        // display before clamping so even an oversized panel stays reachable.
        let width = min(CGFloat(Limits.panelSize.width), visibleFrame.width)
        let height = min(CGFloat(Limits.panelSize.height), visibleFrame.height)
        let x = min(max(cursor.x, visibleFrame.minX), visibleFrame.maxX - width)
        // Cocoa coordinates rise upward; put the panel's top-left at the cursor.
        let y = min(max(cursor.y - height, visibleFrame.minY), visibleFrame.maxY - height)

        return CGRect(x: x, y: y, width: width, height: height)
    }
}
