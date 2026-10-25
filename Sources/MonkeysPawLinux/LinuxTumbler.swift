#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// A choice remains one focus stop. Return belongs to the panel unless its
/// option popover is open; Space and pointer activation open the option list.
final class LinuxTumbler {
    let widget: GTK.Widget
    private let stack: GTK.Widget
    private let popover: GTK.Widget
    private let field: FillFieldState
    private let changed: (String) -> Void
    private let tick: () -> Void
    private var value: String
    private var invalidLabel: GTK.Widget?
    private var optionButtons: [GTK.Widget] = []
    private var popoverIndex = 0
    private var bumpRevision = 0
    private var retired = false
    var isOpen: Bool { !retired && gtk_widget_get_visible(popover) != 0 }

    init(field: FillFieldState, changed: @escaping (String) -> Void, tick: @escaping () -> Void) {
        self.field = field
        self.changed = changed
        self.tick = tick
        value = field.value
        widget = gtk_button_new()!
        gtk_widget_add_css_class(widget, "mp-tumbler")
        gtk_widget_set_focusable(widget, 1)
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        stack = gtk_stack_new()!
        gtk_widget_set_name(stack, "fill-options-" + field.name)
        gtk_stack_set_hhomogeneous(mp_stack(stack), 0)
        gtk_stack_set_vhomogeneous(mp_stack(stack), 0)
        gtk_stack_set_transition_duration(mp_stack(stack), WishCardMotion.milliseconds(WishCardMotion.roll))
        for option in field.options {
            let label = GTK.label(option.label)
            gtk_label_set_wrap(mp_label(label), 0)
            gtk_stack_add_named(mp_stack(stack), label, option.value)
        }
        gtk_box_append(mp_box(row), stack)
        let arrows = GTK.label("▴▾")
        gtk_widget_add_css_class(arrows, "mp-tumbler-arrow")
        gtk_box_append(mp_box(row), arrows)
        gtk_button_set_child(mp_button(widget), row)

        popover = gtk_popover_new()!
        gtk_widget_set_name(popover, "fill-choices-" + field.name)
        gtk_widget_set_parent(popover, widget)
        let list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        for (position, option) in field.options.enumerated() {
            let button = GTK.button(option.label) { [weak self] in self?.choose(position) }
            gtk_widget_set_name(button, "fill-option-" + field.name + "-" + option.value)
            gtk_widget_add_css_class(button, "flat")
            gtk_box_append(mp_box(list), button)
            optionButtons.append(button)
        }
        gtk_popover_set_child(mp_popover(popover), list)
        GTK.onSignal(widget, "clicked") { [weak self] in self?.open() }
        // GtkButton disposes its content, but does not own the custom popup's
        // parenting. Release that child before GtkWidget finalization.
        GTK.onSignal(widget, "destroy") { [weak self] in self?.retire() }
        GTK.observeKeys(widget) { [weak self] key, modifiers in self?.handleKey(key, modifiers: modifiers) ?? false }
        GTK.observeKeys(popover) { [weak self] key, modifiers in self?.popoverKey(key, modifiers: modifiers) ?? false }
        update(field.value)
    }

    /// Call while the owning view still owns its borrowed widgets.
    func retire() {
        guard !retired else { return }
        retired = true
        bumpRevision += 1
        gtk_popover_popdown(mp_popover(popover))
        gtk_widget_unparent(popover)
    }

    func update(_ newValue: String) {
        guard !retired else { return }
        let before = field.options.firstIndex { $0.value == value }
        let after = field.options.firstIndex { $0.value == newValue }
        value = newValue
        let transition = (after ?? 0) >= (before ?? 0) ? GTK_STACK_TRANSITION_TYPE_SLIDE_UP : GTK_STACK_TRANSITION_TYPE_SLIDE_DOWN
        gtk_stack_set_transition_type(mp_stack(stack), WishCardMotion.enabled ? transition : GTK_STACK_TRANSITION_TYPE_NONE)
        if let invalidLabel { gtk_stack_remove(mp_stack(stack), invalidLabel); self.invalidLabel = nil }
        if after == nil {
            let label = GTK.label(newValue.isEmpty ? field.label : newValue)
            gtk_label_set_wrap(mp_label(label), 0)
            gtk_stack_add_named(mp_stack(stack), label, newValue)
            invalidLabel = label
        }
        gtk_stack_set_visible_child_name(mp_stack(stack), newValue)
        let invalid = after == nil && !newValue.isEmpty
        if invalid { gtk_widget_add_css_class(widget, "mp-slot-invalid") }
        else { gtk_widget_remove_css_class(widget, "mp-slot-invalid") }
        let label = after.map { field.options[$0].label } ?? (newValue.isEmpty ? field.label : newValue)
        mp_accessible_label(widget, field.label + ": " + label)
        for (position, button) in optionButtons.enumerated() {
            gtk_button_set_label(mp_button(button), (position == after ? "✓ " : "") + field.options[position].label)
        }
    }

    func handleKey(_ key: UInt32, modifiers: UInt32) -> Bool {
        guard !retired, !isOpen else { return false }
        let relevant = GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue
            | GDK_META_MASK.rawValue | GDK_HYPER_MASK.rawValue
        guard modifiers & relevant == 0 else { return false }
        if key == UInt32(GDK_KEY_Up) || key == UInt32(GDK_KEY_Down) {
            let offset = key == UInt32(GDK_KEY_Up) ? -1 : 1
            let current = field.options.firstIndex { $0.value == value }
            let next = current.map { $0 + offset } ?? (offset > 0 ? 0 : field.options.count - 1)
            if field.options.indices.contains(next) { select(next) }
            else { bump(up: offset < 0) }
            return true
        }
        if key == UInt32(GDK_KEY_space) { open(); return true }
        guard let scalar = UnicodeScalar(gdk_keyval_to_unicode(key)), CharacterSet.letters.contains(scalar) else { return false }
        let prefix = String(scalar).lowercased()
        let current = field.options.firstIndex { $0.value == value } ?? -1
        for step in 1...field.options.count {
            let position = (current + step) % field.options.count
            if field.options[position].label.lowercased().hasPrefix(prefix) { select(position); return true }
        }
        return false
    }

    private func select(_ position: Int) {
        guard field.options.indices.contains(position) else { return }
        tick()
        changed(field.options[position].value)
    }

    private func open() {
        guard !retired else { return }
        popoverIndex = field.options.firstIndex { $0.value == value } ?? 0
        gtk_popover_popup(mp_popover(popover))
        if optionButtons.indices.contains(popoverIndex) { gtk_widget_grab_focus(optionButtons[popoverIndex]) }
    }

    private func choose(_ position: Int) {
        guard !retired else { return }
        select(position)
        gtk_popover_popdown(mp_popover(popover))
        gtk_widget_grab_focus(widget)
    }

    private func popoverKey(_ key: UInt32, modifiers: UInt32) -> Bool {
        guard isOpen, modifiers & ~GDK_LOCK_MASK.rawValue == 0 else { return false }
        switch key {
        case UInt32(GDK_KEY_Up), UInt32(GDK_KEY_Down):
            let delta = key == UInt32(GDK_KEY_Up) ? -1 : 1
            popoverIndex = min(max(0, popoverIndex + delta), optionButtons.count - 1)
            gtk_widget_grab_focus(optionButtons[popoverIndex])
        case UInt32(GDK_KEY_Return), UInt32(GDK_KEY_KP_Enter): choose(popoverIndex)
        case UInt32(GDK_KEY_Escape):
            gtk_popover_popdown(mp_popover(popover)); gtk_widget_grab_focus(widget)
        default: return false
        }
        return true
    }

    private func bump(up: Bool) {
        guard WishCardMotion.enabled else { return }
        bumpRevision += 1
        let revision = bumpRevision
        for name in ["mp-bump-up", "mp-bump-down"] { gtk_widget_remove_css_class(stack, name) }
        gtk_widget_add_css_class(stack, up ? "mp-bump-up" : "mp-bump-down")
        GTK.after(WishCardMotion.bump) { [weak self] in
            guard let self, !self.retired, revision == self.bumpRevision else { return }
            gtk_widget_remove_css_class(self.stack, "mp-bump-up")
            gtk_widget_remove_css_class(self.stack, "mp-bump-down")
        }
    }
}
#endif
