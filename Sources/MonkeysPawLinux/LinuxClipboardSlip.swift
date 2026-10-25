#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Only receives the presentation model's resolved snapshot. It never reads
/// the clipboard, including when used as a picker thumbnail.
final class LinuxClipboardSlip {
    private enum Layout {
        static let maximumLines = 6, header = 18, line = 16, foot = 14
        static let tooth = 7.0, tear = 3.0, inset = 10.0, settle = 10.0
        static let font = 11.5, caption = 9.5, medallion = 14.0
        static let statusLines = 3
        static let pangoScale = 1_024.0
    }
    static let pendingMessage = "Reading your clipboard…"
    static let thumbnailMessage = "Your clipboard goes here"
    static let emptyMessage = "Your clipboard is empty — copy the text first, then summon again."

    let widget: GTK.Widget
    private let thumbnail: Bool
    private var text: String?
    private var summary: ClipboardSummary?
    private var shownLines: [String] = []
    private var textLength = 0
    private var hasOverflow = false
    private var didConfigure = false
    private var progress = 1.0
    private var tickID: guint?
    private var retired = false

    init(thumbnail: Bool) {
        self.thumbnail = thumbnail
        widget = gtk_drawing_area_new()!
        gtk_widget_set_name(widget, "card-clipboard-slip")
        gtk_widget_add_css_class(widget, "mp-slip")
        gtk_widget_set_hexpand(widget, 1)
        GTK.draw(widget) { [weak self] cr, width, height in self?.draw(cr, width: Double(width), height: Double(height)) }
        GTK.onSignal(widget, "destroy") { [weak self] in
            self?.tickID = nil
            self?.retired = true
        }
        update(text: nil, summary: nil)
    }

    func retire() {
        guard !retired else { return }
        retired = true
        if let tickID { GTK.removeTick(widget, tickID); self.tickID = nil }
    }

    func update(text: String?, summary: ClipboardSummary?) {
        guard !retired else { return }
        // A FillModel owns one immutable snapshot. Do not split or compare a
        // potentially large clipboard again on each field edit or frame.
        guard !didConfigure || (self.text == nil && text != nil) else { return }
        didConfigure = true
        let firstResolution = self.text == nil && text != nil
        self.text = text
        self.summary = summary
        if let text {
            textLength = summary?.characterCount ?? text.count
            shownLines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(Layout.maximumLines).map(String.init)
            hasOverflow = (summary?.lineCount ?? 0) > Layout.maximumLines
        }
        let shown = summary?.kind == .empty ? Layout.statusLines : max(1, shownLines.count)
        let height = Layout.header + Layout.line * shown + Layout.foot
        gtk_drawing_area_set_content_height(mp_drawing_area(widget), Int32(height))
        let accessible: String
        if let summary {
            accessible = summary.kind == .empty ? Self.emptyMessage
                : "Clipboard, \(summary.lineCount) lines, \(summary.kind.rawValue)"
        } else { accessible = thumbnail ? Self.thumbnailMessage : Self.pendingMessage }
        mp_accessible_label(widget, accessible)
        if firstResolution, WishCardMotion.enabled {
            progress = 0
            var began: Int64?
            tickID = GTK.tick(widget) { [weak self] now in
                guard let self, !self.retired else { return false }
                if began == nil { began = now }
                let elapsed = Double(now - (began ?? now)) / 1_000_000
                let t = min(1, elapsed / WishCardMotion.slip)
                self.progress = 1 - pow(1 - t, 3)
                gtk_widget_queue_draw(self.widget)
                if t >= 1 { self.tickID = nil; return false }
                return true
            }
        }
        gtk_widget_queue_draw(widget)
    }

    private func outline(_ cr: OpaquePointer, width: Double, height: Double) {
        let seed = textLength
        let count = max(1, Int(width / Layout.tooth))
        cairo_move_to(cr, 0, Layout.tear)
        for tooth in 0...count {
            let x = min(width, Double(tooth) * Layout.tooth)
            let jitter = Double((seed &+ tooth &* 17) % 5) / 5
            cairo_line_to(cr, x, Layout.tear * (0.3 + jitter * 0.7))
            cairo_line_to(cr, min(width, x + Layout.tooth / 2), 0)
        }
        cairo_line_to(cr, width, height - Layout.tear)
        for tooth in (0...count).reversed() {
            let x = min(width, Double(tooth) * Layout.tooth)
            let jitter = Double((seed &+ tooth &* 13) % 5) / 5
            cairo_line_to(cr, x, height - Layout.tear * (0.3 + jitter * 0.7))
            cairo_line_to(cr, max(0, x - Layout.tooth / 2), height)
        }
        cairo_close_path(cr)
    }

    private func draw(_ cr: OpaquePointer, width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        cairo_save(cr)
        defer { cairo_restore(cr) }
        cairo_translate(cr, 0, -Layout.settle * (1 - progress))
        cairo_push_group(cr)
        let pending = text == nil
        let empty = summary?.kind == .empty
        if !pending && !empty {
            for stroke in [6.0, 4.0, 2.0] {
                cairo_save(cr)
                cairo_translate(cr, 0, 2)
                outline(cr, width: width, height: height - Layout.tear)
                cairo_set_source_rgba(cr, 0, 0, 0, 0.035)
                cairo_set_line_width(cr, stroke)
                cairo_stroke(cr)
                cairo_restore(cr)
            }
        }
        outline(cr, width: width, height: height - Layout.tear)
        WishCardStyle.source(cr, WishCardStyle.slipPaper)
        cairo_fill_preserve(cr)
        WishCardStyle.source(cr, empty ? WishCardStyle.invalid : WishCardStyle.blankRule)
        if pending || empty {
            let dashes: [Double] = [4, 3]
            dashes.withUnsafeBufferPointer { cairo_set_dash(cr, $0.baseAddress, Int32($0.count), 0) }
            cairo_set_line_width(cr, 1)
            cairo_stroke(cr)
            let message = empty ? Self.emptyMessage : (thumbnail ? Self.thumbnailMessage : Self.pendingMessage)
            drawText(message, cr: cr, x: Layout.inset, y: Double(Layout.header), width: width - 2 * Layout.inset,
                     size: Layout.font, color: empty ? WishCardStyle.errorInk : WishCardStyle.emptyInk,
                     italic: true, maximumLines: empty ? Layout.statusLines : 1)
        } else {
            cairo_new_path(cr)
            for (position, line) in shownLines.enumerated() {
                let fade = position == Layout.maximumLines - 1 && hasOverflow
                cairo_push_group(cr)
                drawText(line.replacingOccurrences(of: "\t", with: "    "), cr: cr, x: Layout.inset,
                         y: Double(Layout.header + position * Layout.line), width: width - 2 * Layout.inset,
                         size: Layout.font, color: WishCardStyle.slipInk)
                cairo_pop_group_to_source(cr)
                if fade {
                    let mask = cairo_pattern_create_linear(0, Double(Layout.header + position * Layout.line), 0, height)!
                    cairo_pattern_add_color_stop_rgba(mask, 0, 1, 1, 1, 1)
                    cairo_pattern_add_color_stop_rgba(mask, 1, 1, 1, 1, 0)
                    cairo_mask(cr, mask)
                    cairo_pattern_destroy(mask)
                } else { cairo_paint(cr) }
            }
            if let summary {
                let caption = "CLIPBOARD · \(summary.lineCount) LINES · \(summary.kind.rawValue.uppercased())"
                let layout = makeLayout(caption, cr: cr, size: Layout.caption, italic: false)
                var captionWidth: Int32 = 0
                pango_layout_get_pixel_size(layout, &captionWidth, nil)
                let x = max(Layout.inset, width - Double(captionWidth) - Layout.inset)
                medallion(cr, x: x - Layout.medallion - 4, y: Layout.tear)
                WishCardStyle.source(cr, WishCardStyle.brassRim)
                cairo_move_to(cr, x, Layout.tear)
                pango_cairo_show_layout(cr, layout)
                g_object_unref(UnsafeMutableRawPointer(layout))
            }
        }
        cairo_pop_group_to_source(cr)
        cairo_paint_with_alpha(cr, progress)
    }

    private func makeLayout(_ text: String, cr: OpaquePointer, size: Double, italic: Bool) -> OpaquePointer {
        let layout = pango_cairo_create_layout(cr)!
        let font = pango_font_description_from_string(WishCardStyle.pangoMono)!
        pango_font_description_set_absolute_size(font, size * Layout.pangoScale)
        if italic { pango_font_description_set_style(font, PANGO_STYLE_ITALIC) }
        pango_layout_set_font_description(layout, font)
        pango_font_description_free(font)
        pango_layout_set_text(layout, text, -1)
        return layout
    }

    private func drawText(_ text: String, cr: OpaquePointer, x: Double, y: Double, width: Double,
                          size: Double, color: String, italic: Bool = false, maximumLines: Int = 1) {
        let layout = makeLayout(text, cr: cr, size: size, italic: italic)
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        pango_layout_set_width(layout, Int32(max(0, width) * Layout.pangoScale))
        pango_layout_set_height(layout, -Int32(maximumLines))
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
        pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
        WishCardStyle.source(cr, color)
        cairo_move_to(cr, x, y)
        pango_cairo_show_layout(cr, layout)
    }

    private func medallion(_ cr: OpaquePointer, x: Double, y: Double) {
        cairo_new_path(cr)
        let radius = Layout.medallion / 2
        let gradient = cairo_pattern_create_radial(x + radius, y + radius / 2, 0, x + radius, y + radius, radius)!
        WishCardStyle.stop(gradient, 0, WishCardStyle.brassTop)
        WishCardStyle.stop(gradient, 1, WishCardStyle.brassBottom)
        cairo_arc(cr, x + radius, y + radius, radius, 0, 2 * .pi)
        cairo_set_source(cr, gradient)
        cairo_fill_preserve(cr)
        cairo_pattern_destroy(gradient)
        WishCardStyle.source(cr, WishCardStyle.brassRim)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
    }
}
#endif
