import AppKit
import MonkeysPawCore
import SwiftUI

enum WishInkPhase { case wet, drying(Double), dry }

/// The picker owns this palette; the Library keeps its native appearance.
enum WishCardStyle {
    static let nightTop = color(0x1D1939), nightBottom = color(0x120F26)
    static let primary = color(0xECE7F6), secondary = color(0x9A92B5), amber = color(0xFFB547)
    static let paperTop = color(0xFCF7EB), paperBottom = color(0xF3EAD8), bodyInk = color(0x3B3346)
    static let titleInk = color(0x9C4F24), folderInk = color(0x8A7A5A), tagInk = color(0x9C92A9)
    static let brassTop = color(0xF3D27A), brassBottom = color(0xB8892A), brassRim = color(0x7A5A12)
    static let focusInk = color(0xE58A22), blankRule = color(0xB3A6C6), well = color(0xF2E9D6)
    static let errorInk = color(0xA13A0B), stamp = color(0xA23B57), slipPaper = color(0xFFFEFA)
    static let resultsWidth: CGFloat = 232, paperInset: CGFloat = 22
    static let minimumSlotWidth: CGFloat = 48, slotPadding: CGFloat = 10
    static let roll = 0.140, bump = 0.120, dry = 0.5, ink = 0.220, stagger = 0.045, sheen = 0.560, nudge = 0.300
    static let serif = NSFont(name: "Palatino", size: 15) ?? NSFont.systemFont(ofSize: 15)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func fieldFont(_ provenance: FieldProvenance, kind: FieldKind = .text) -> NSFont {
        let font = kind == .multiline ? mono : serif
        return provenance == .defaultValue ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
    }

    static func ink(_ provenance: FieldProvenance, phase: WishInkPhase) -> NSColor {
        if provenance == .defaultValue { return nsColor(0x6F667C) }
        guard provenance == .typed else { return nsColor(0x8F4708) }
        let progress: CGFloat
        switch phase {
        case .wet: progress = 0
        case .drying(let value): progress = CGFloat(value)
        case .dry: progress = 1
        }
        let dry = nsColor(0x8F4708)
        return nsColor(0xC8650A).blended(withFraction: progress, of: dry) ?? dry
    }

    static func slotWidth(value: String, label: String, font: NSFont, lineWidth: CGFloat) -> CGFloat {
        let text = value.isEmpty ? label : value
        let measured = (text as NSString).size(withAttributes: [.font: font]).width + slotPadding
        return min(max(1, lineWidth), max(minimumSlotWidth, ceil(measured)))
    }

    static func color(_ hex: UInt32) -> Color { Color(nsColor: nsColor(hex)) }

    static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

struct WishNight: View {
    var body: some View {
        if !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            GeometryReader { geometry in
                LinearGradient(colors: [WishCardStyle.nightTop, WishCardStyle.nightBottom],
                               startPoint: .top, endPoint: .bottom)
                ForEach(0..<7) { index in
                    let points: [CGPoint] = [.init(x: 0.08, y: 0.12), .init(x: 0.23, y: 0.06),
                        .init(x: 0.41, y: 0.14), .init(x: 0.62, y: 0.05), .init(x: 0.77, y: 0.11),
                        .init(x: 0.90, y: 0.07), .init(x: 0.96, y: 0.18)]
                    Circle().fill(WishCardStyle.brassTop.opacity(0.55)).frame(width: 2, height: 2)
                        .position(x: geometry.size.width * points[index].x, y: geometry.size.height * points[index].y)
                }
            }
            .accessibilityHidden(true)
        }
    }
}
