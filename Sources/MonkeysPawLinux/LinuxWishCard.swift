#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// The prompt is the form. Anchors keep native input widgets inside the
/// template's text flow; all values and actions still belong to FillModel.
final class LinuxWishCard {
    private final class Slot {
        let index: Int
        let widget: GTK.Widget
        let root: GTK.Widget
        let tumbler: LinuxTumbler?
        let placeholder: GTK.Widget?
        var hasPreedit = false
        var inkRevision = 0
        init(index: Int, widget: GTK.Widget, root: GTK.Widget,
             tumbler: LinuxTumbler? = nil, placeholder: GTK.Widget? = nil) {
            self.index = index; self.widget = widget; self.root = root
            self.tumbler = tumbler; self.placeholder = placeholder
        }
    }
    private struct Echo {
        let name: String
        let widget: GTK.Widget
    }

    let widget: GTK.Widget
    private let paper: GTK.Widget
    private let body: GTK.Widget
    private let titleLabel: GTK.Widget
    private let folderLabel: GTK.Widget
    private let effects = LinuxCardEffects()
    private let sounds: LinuxFeedbackSounds
    private weak var fill: FillModel?
    private var slots: [Slot] = []
    private var echoes: [Echo] = []
    private var stamps: [(BuiltinName, GTK.Widget)] = []
    private var slips: [LinuxClipboardSlip] = []
    private var fullWidth: [GTK.Widget] = []
    private var bodyWidth: Int32 = 0
    private var isUpdating = false
    private var retired = false
    private var wasReady = false
    private var nudgeRevision = 0

    var firstFieldWidget: GTK.Widget? { slots.first?.widget }
    var choicePopoverOpen: Bool { slots.contains { $0.tumbler?.isOpen == true } }

    init(card: PromptCard?, title: String, folder: String, fill: FillModel? = nil,
         fallback: String = "", sounds: LinuxFeedbackSounds) {
        self.fill = fill
        self.sounds = sounds
        widget = gtk_overlay_new()!
        gtk_widget_set_name(widget, "wish-card")
        gtk_widget_set_valign(widget, GTK_ALIGN_START)
        gtk_widget_set_hexpand(widget, 1)
        paper = gtk_box_new(GTK_ORIENTATION_VERTICAL, Int32(WishCardStyle.cardGap))!
        gtk_widget_add_css_class(paper, "mp-card")
        gtk_overlay_set_child(mp_overlay(widget), paper)
        let header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, Int32(WishCardStyle.cardGap))!
        titleLabel = GTK.label(title.uppercased())
        gtk_widget_add_css_class(titleLabel, "mp-card-title")
        gtk_widget_set_hexpand(titleLabel, 1)
        gtk_label_set_wrap(mp_label(titleLabel), 0)
        gtk_label_set_ellipsize(mp_label(titleLabel), PANGO_ELLIPSIZE_END)
        gtk_box_append(mp_box(header), titleLabel)
        let medallion = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_widget_add_css_class(medallion, "mp-medallion")
        gtk_widget_set_size_request(medallion, Int32(WishCardStyle.medallion), Int32(WishCardStyle.medallion))
        gtk_widget_set_valign(medallion, GTK_ALIGN_CENTER)
        gtk_box_append(mp_box(header), medallion)
        folderLabel = GTK.label(folder.uppercased())
        gtk_widget_add_css_class(folderLabel, "mp-card-folder")
        gtk_label_set_wrap(mp_label(folderLabel), 0)
        gtk_label_set_ellipsize(mp_label(folderLabel), PANGO_ELLIPSIZE_END)
        gtk_box_append(mp_box(header), folderLabel)
        gtk_box_append(mp_box(paper), header)

        body = gtk_text_view_new()!
        gtk_widget_set_name(body, "card-body")
        gtk_widget_add_css_class(body, "mp-card-body")
        gtk_widget_set_focusable(body, 0)
        gtk_text_view_set_editable(mp_text_view(body), 0)
        gtk_text_view_set_cursor_visible(mp_text_view(body), 0)
        gtk_text_view_set_wrap_mode(mp_text_view(body), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_pixels_below_lines(mp_text_view(body), Int32(WishCardStyle.bodyLineSpace))
        gtk_text_view_set_pixels_inside_wrap(mp_text_view(body), Int32(WishCardStyle.bodyLineSpace))
        gtk_widget_set_hexpand(body, 1)
        gtk_box_append(mp_box(paper), body)
        gtk_box_append(mp_box(paper), effects.wick)
        gtk_overlay_add_overlay(mp_overlay(widget), effects.sheen)
        gtk_widget_set_can_target(effects.sheen, 0)

        if let card {
            for segment in card.segments { append(segment) }
        } else {
            appendText(fallback)
            gtk_widget_add_css_class(body, "mp-card-error")
        }
        tagXMLLines()
        if !fullWidth.isEmpty {
            // The wick and body share the paper's content width. Observe its
            // allocation rather than keep a frame clock running on a still card.
            GTK.onResize(effects.wick) { [weak self] width, _ in
                guard let self, !self.retired else { return }
                if width > 0, self.bodyWidth != width {
                    self.bodyWidth = width
                    GTK.onMainLoop { [weak self] in
                        guard let self, !self.retired else { return }
                        for child in self.fullWidth { gtk_widget_set_size_request(child, max(1, width - 2), -1) }
                    }
                }
            }
        }
        GTK.onSignal(body, "destroy") { [weak self] in self?.retire() }
        update()
        if fill != nil, WishCardMotion.enabled {
            for (order, slot) in slots.enumerated() {
                gtk_widget_add_css_class(slot.widget, "mp-ink-pending")
                GTK.after(Double(order) * WishCardMotion.stagger) { [weak self, weak slot] in
                    guard let self, !self.retired, let slot else { return }
                    gtk_widget_remove_css_class(slot.widget, "mp-ink-pending")
                }
            }
        }
    }

    /// Retire before removing the view: delayed closures never touch freed GTK
    /// pointers, and custom popovers are unparented while their buttons live.
    func retire() {
        guard !retired else { return }
        retired = true
        nudgeRevision += 1
        effects.cancel()
        for slot in slots { slot.tumbler?.retire() }
        for slip in slips { slip.retire() }
    }

    func updateHeader(title: String, folder: String) {
        guard !retired else { return }
        gtk_label_set_text(mp_label(titleLabel), title.uppercased())
        gtk_label_set_text(mp_label(folderLabel), folder.uppercased())
    }

    func update() {
        guard !retired else { return }
        isUpdating = true
        defer { isUpdating = false }
        guard let fill else {
            setHeat(0, ready: false)
            return
        }
        for slot in slots {
            let field = fill.fields[slot.index]
            switch field.kind {
            case .text:
                if String(cString: mp_entry_text(slot.widget)) != field.value { mp_entry_set_text(slot.widget, field.value) }
                let width = min(WishCardStyle.maximumSlot, max(WishCardStyle.minimumSlot,
                    max(field.label.count, field.value.count) + 1))
                gtk_editable_set_width_chars(mp_editable(slot.widget), Int32(width))
                gtk_editable_set_max_width_chars(mp_editable(slot.widget), Int32(width))
            case .multiline:
                if text(in: slot.widget) != field.value {
                    gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(slot.widget)), field.value, -1)
                }
                if let placeholder = slot.placeholder { gtk_widget_set_visible(placeholder, field.value.isEmpty ? 1 : 0) }
            case .choice: slot.tumbler?.update(field.value)
            }
            provenance(field.provenance, on: slot.widget)
            if field.provenance != .typed { gtk_widget_remove_css_class(slot.widget, "mp-ink-wet") }
        }
        for echo in echoes {
            guard let field = fill.fields.first(where: { $0.name == echo.name }) else { continue }
            gtk_label_set_text(mp_label(echo.widget), field.value.isEmpty ? field.label : field.value)
            provenance(field.provenance, on: echo.widget)
            if let slot = slots.first(where: { fill.fields[$0.index].name == echo.name }),
               gtk_widget_has_css_class(slot.widget, "mp-ink-wet") != 0 {
                gtk_widget_add_css_class(echo.widget, "mp-ink-wet")
            } else { gtk_widget_remove_css_class(echo.widget, "mp-ink-wet") }
        }
        for (name, stamp) in stamps {
            gtk_label_set_text(mp_label(stamp), (fill.builtinText(name) ?? name.rawValue).uppercased())
        }
        for slip in slips { slip.update(text: fill.builtinText(.clipboard), summary: fill.clipboardSummary) }
        setHeat(fill.warmth, ready: fill.deliverEnabled)
        if fill.deliverEnabled && !wasReady { sounds.play(.ready) }
        wasReady = fill.deliverEnabled
    }

    func fieldWidget(at index: Int) -> GTK.Widget? { slots.first { $0.index == index }?.widget }

    func focusedIndex(_ focus: GTK.Widget?) -> Int? {
        guard let focus, !retired else { return nil }
        return slots.first { focus == $0.widget || gtk_widget_is_ancestor(focus, $0.widget) != 0 }?.index
    }

    func hasPreedit(_ focus: GTK.Widget?) -> Bool {
        guard let index = focusedIndex(focus) else { return false }
        return slots.first { $0.index == index }?.hasPreedit == true
    }

    func handleKey(_ key: UInt32, modifiers: UInt32, focus: GTK.Widget?) -> Bool {
        guard let index = focusedIndex(focus), let slot = slots.first(where: { $0.index == index }) else { return false }
        return slot.tumbler?.handleKey(key, modifiers: modifiers) ?? false
    }

    func nudge() {
        guard let fill, !retired else { return }
        let invalid = fill.fields.firstIndex { field in
            field.kind == .choice && !field.value.isEmpty && !field.options.contains { $0.value == field.value }
        }
        guard let index = fill.missingRequiredFieldIndex ?? invalid ?? fill.focusIndex,
              let widget = fieldWidget(at: index) else { sounds.play(.nudge); return }
        fill.focusField(at: index)
        gtk_widget_grab_focus(widget)
        sounds.play(.nudge)
        guard WishCardMotion.enabled else { return }
        nudgeRevision += 1
        let revision = nudgeRevision
        for slot in slots { gtk_widget_remove_css_class(slot.widget, "mp-nudge") }
        gtk_widget_add_css_class(widget, "mp-nudge")
        GTK.after(WishCardMotion.nudge) { [weak self] in
            guard let self, !self.retired, revision == self.nudgeRevision else { return }
            gtk_widget_remove_css_class(widget, "mp-nudge")
        }
    }

    private func setHeat(_ warmth: Double, ready: Bool) {
        for name in ["mp-heat-0", "mp-heat-1", "mp-heat-2", "mp-ready"] { gtk_widget_remove_css_class(paper, name) }
        gtk_widget_add_css_class(paper, warmth >= 0.5 ? "mp-heat-2" : (warmth > 0 ? "mp-heat-1" : "mp-heat-0"))
        if ready { gtk_widget_add_css_class(paper, "mp-ready") }
        effects.update(warmth: warmth, ready: ready)
    }

    private func append(_ segment: PromptCard.Segment) {
        switch segment {
        case .text(let text): appendText(text)
        case .builtin(.clipboard):
            let slip = LinuxClipboardSlip(thumbnail: fill == nil)
            slips.append(slip)
            fullWidth.append(slip.widget)
            gtk_widget_set_size_request(slip.widget, Int32(WishCardStyle.wellFallbackWidth), -1)
            anchor(slip.widget)
        case .builtin(let name):
            let label = GTK.label(name.rawValue.uppercased())
            gtk_widget_add_css_class(label, "mp-stamp")
            stamps.append((name, label))
            anchor(label, alignBaseline: true)
        case .field(let name, let label, let kind, let occurrence):
            guard let fill, let index = fill.fields.firstIndex(where: { $0.name == name }) else {
                let placeholder = GTK.label(label.uppercased())
                gtk_widget_add_css_class(placeholder, kind == .multiline ? "mp-well" : "mp-slot-static")
                if kind == .multiline { fullWidth.append(placeholder) }
                anchor(placeholder, alignBaseline: kind != .multiline)
                return
            }
            if occurrence > 0 {
                let echo = GTK.label(label)
                gtk_widget_set_focusable(echo, 0)
                gtk_widget_add_css_class(echo, "mp-echo")
                echoes.append(Echo(name: name, widget: echo))
                GTK.onClick(echo) { [weak self, weak fill] in
                    guard let self, !self.retired else { return }
                    fill?.focusField(at: index)
                    if let widget = self.fieldWidget(at: index) { gtk_widget_grab_focus(widget) }
                }
                anchor(echo, alignBaseline: true)
            } else { anchor(makeSlot(fill.fields[index], index: index), alignBaseline: kind != .multiline) }
        }
    }

    private func makeSlot(_ field: FillFieldState, index: Int) -> GTK.Widget {
        // Grid exposes the editor row's baseline even with a description
        // underneath it; a vertical box aligns the entire slot above the line.
        let row = gtk_grid_new()!
        gtk_grid_set_baseline_row(mp_grid(row), 0)
        gtk_grid_set_row_spacing(mp_grid(row), 2)
        let slot: Slot
        switch field.kind {
        case .text:
            let entry = gtk_entry_new()!
            gtk_entry_set_has_frame(mp_entry(entry), 0)
            gtk_entry_set_placeholder_text(mp_entry(entry), field.label)
            gtk_widget_add_css_class(entry, "mp-slot")
            gtk_widget_set_valign(entry, GTK_ALIGN_BASELINE)
            gtk_grid_attach(mp_grid(row), entry, 0, 0, 1, 1)
            slot = Slot(index: index, widget: entry, root: row)
            GTK.onSignal(entry, "changed") { [weak self, weak slot] in
                guard let self, let slot else { return }
                self.change(String(cString: mp_entry_text(entry)), slot: slot)
            }
            observePreedit(mp_entry_text_delegate(entry), slot: slot)
        case .multiline:
            let view = gtk_text_view_new()!
            gtk_text_view_set_wrap_mode(mp_text_view(view), GTK_WRAP_WORD_CHAR)
            let scroll = gtk_scrolled_window_new()!
            gtk_widget_add_css_class(scroll, "mp-well")
            gtk_widget_add_css_class(view, "mp-well-ink")
            gtk_scrolled_window_set_policy(mp_scrolled_window(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_propagate_natural_height(mp_scrolled_window(scroll), 1)
            gtk_scrolled_window_set_min_content_height(mp_scrolled_window(scroll), Int32(WishCardStyle.wellMinimum))
            gtk_scrolled_window_set_max_content_height(mp_scrolled_window(scroll), Int32(WishCardStyle.wellMaximum))
            gtk_scrolled_window_set_child(mp_scrolled_window(scroll), view)
            gtk_widget_set_hexpand(scroll, 1)
            gtk_grid_attach(mp_grid(row), scroll, 0, 0, 1, 1)
            let overlay = gtk_overlay_new()!
            gtk_overlay_set_child(mp_overlay(overlay), row)
            let placeholder = GTK.label(field.label + (field.optional ? " — optional" : ""))
            gtk_widget_add_css_class(placeholder, "mp-well-placeholder")
            gtk_widget_set_can_target(placeholder, 0)
            gtk_widget_set_valign(placeholder, GTK_ALIGN_START)
            gtk_widget_set_margin_top(placeholder, 7)
            gtk_widget_set_margin_start(placeholder, 10)
            gtk_overlay_add_overlay(mp_overlay(overlay), placeholder)
            slot = Slot(index: index, widget: view, root: overlay, placeholder: placeholder)
            fullWidth.append(overlay)
            gtk_widget_set_size_request(overlay, Int32(WishCardStyle.wellFallbackWidth), -1)
            GTK.onSignal(UnsafeMutableRawPointer(gtk_text_view_get_buffer(mp_text_view(view))!), "changed") { [weak self, weak slot] in
                guard let self, let slot else { return }
                self.change(self.text(in: view), slot: slot)
            }
            observePreedit(view, slot: slot)
        case .choice:
            let tumbler = LinuxTumbler(field: field, changed: { [weak self] value in
                guard let self, let slot = self.slots.first(where: { $0.index == index }) else { return }
                self.change(value, slot: slot)
            }, tick: { [weak self] in self?.sounds.play(.tick) })
            gtk_widget_set_valign(tumbler.widget, GTK_ALIGN_BASELINE)
            gtk_grid_attach(mp_grid(row), tumbler.widget, 0, 0, 1, 1)
            slot = Slot(index: index, widget: tumbler.widget, root: row, tumbler: tumbler)
        }
        gtk_widget_set_name(slot.widget, "fill-field-" + field.name)
        if field.kind != .choice { mp_accessible_label(slot.widget, field.label) }
        gtk_widget_set_tooltip_text(slot.widget, field.description)
        gtk_widget_set_margin_bottom(slot.root, Int32(WishCardStyle.slotBaseline))
        if let description = field.description, !description.isEmpty {
            let label = GTK.label(description)
            gtk_widget_set_name(label, "fill-description-" + field.name)
            gtk_widget_add_css_class(label, "mp-field-description")
            gtk_grid_attach(mp_grid(row), label, 0, 1, 1, 1)
            mp_accessible_description(slot.widget, description)
        }
        slots.append(slot)
        return slot.root
    }

    private func observePreedit(_ widget: GTK.Widget?, slot: Slot) {
        guard let widget else { return }
        GTK.onPreeditChanged(widget) { [weak self, weak slot] active in
            guard let self, !self.retired else { return }
            slot?.hasPreedit = active
        }
    }

    private func change(_ value: String, slot: Slot) {
        guard !retired, !isUpdating, let fill, fill.state == .editing else { return }
        gtk_widget_remove_css_class(slot.widget, "mp-ink-pending")
        slot.inkRevision += 1
        let revision = slot.inkRevision
        if WishCardMotion.enabled { gtk_widget_add_css_class(slot.widget, "mp-ink-wet") }
        fill.setValue(value, name: fill.fields[slot.index].name)
        GTK.after(WishCardMotion.dry) { [weak self, weak slot] in
            guard let self, !self.retired, let slot, slot.inkRevision == revision else { return }
            gtk_widget_remove_css_class(slot.widget, "mp-ink-wet")
            for echo in self.echoes where echo.name == fill.fields[slot.index].name {
                gtk_widget_remove_css_class(echo.widget, "mp-ink-wet")
            }
        }
    }

    private func provenance(_ provenance: FieldProvenance, on widget: GTK.Widget) {
        let name: String
        switch provenance {
        case .defaultValue: name = "mp-ink-default"
        case .remembered: name = "mp-ink-remembered"
        case .draft: name = "mp-ink-draft"
        case .typed: name = "mp-ink-typed"
        }
        for css in ["mp-ink-default", "mp-ink-remembered", "mp-ink-draft", "mp-ink-typed"] where css != name {
            gtk_widget_remove_css_class(widget, css)
        }
        gtk_widget_add_css_class(widget, name)
    }

    private func appendText(_ text: String) {
        let buffer = gtk_text_view_get_buffer(mp_text_view(body))!
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        gtk_text_buffer_insert(buffer, &end, text, -1)
    }

    private func anchor(_ child: GTK.Widget, alignBaseline: Bool = false) {
        let buffer = gtk_text_view_get_buffer(mp_text_view(body))!
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        let anchor = gtk_text_buffer_create_child_anchor(buffer, &end)!
        gtk_text_view_add_child_at_anchor(mp_text_view(body), child, anchor)
        if alignBaseline {
            // GtkTextView aligns an anchored widget's bottom to the line.
            // Lower it by its descent so the native editor's text shares the
            // sentence baseline, even with a description below its first row.
            var height: Int32 = 0, baseline: Int32 = -1
            gtk_widget_measure(child, GTK_ORIENTATION_VERTICAL, -1, nil, &height, nil, &baseline)
            if baseline >= 0, height > baseline {
                var start = end
                gtk_text_iter_backward_char(&start)
                let tag = mp_card_anchor_baseline(buffer, -(height - baseline) * 1_024)
                gtk_text_buffer_apply_tag(buffer, tag, &start, &end)
            }
        }
    }

    private func tagXMLLines() {
        let buffer = gtk_text_view_get_buffer(mp_text_view(body))!
        let tag = mp_card_tag(buffer, WishCardStyle.pangoMono, WishCardStyle.tagSize, WishCardStyle.tagInk)
        for line in 0..<gtk_text_buffer_get_line_count(buffer) {
            var start = GtkTextIter(), end = GtkTextIter()
            gtk_text_buffer_get_iter_at_line(buffer, &start, line)
            end = start
            gtk_text_iter_forward_to_line_end(&end)
            guard let raw = gtk_text_buffer_get_slice(buffer, &start, &end, 0) else { continue }
            let value = String(cString: raw).trimmingCharacters(in: .whitespaces)
            g_free(raw)
            guard value.hasPrefix("<"), value.hasSuffix(">") else { continue }
            var name = value.dropFirst().dropLast()
            if name.hasPrefix("/") { name = name.dropFirst() }
            guard !name.isEmpty, name.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 45
            }) else { continue }
            gtk_text_buffer_apply_tag(buffer, tag, &start, &end)
        }
    }

    private func text(in view: GTK.Widget) -> String {
        let buffer = gtk_text_view_get_buffer(mp_text_view(view))!
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }
}
#endif
