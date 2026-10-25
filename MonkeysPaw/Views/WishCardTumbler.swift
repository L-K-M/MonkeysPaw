import AppKit
import MonkeysPawCore
import QuartzCore
import SwiftUI

/// Keep NSPopUpButton's menu, focus and accessibility, but arrows roll its
/// value directly instead of opening that menu.
final class WishCardTumbler: PickerChoiceButton, NSMenuDelegate {
    var options: [FieldOption] = []
    var choiceValue = ""
    var fieldLabel = ""
    var provenance = FieldProvenance.defaultValue
    var phase = WishInkPhase.dry
    var reduceMotion: () -> Bool = { true }
    var changed: (String) -> Void = { _ in }
    private(set) var isMenuOpen = false

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty, !isMenuOpen else { super.keyDown(with: event); return }
        if event.keyCode == 126 || event.keyCode == 125 {
            let delta = event.keyCode == 126 ? -1 : 1
            let current = options.firstIndex { $0.value == choiceValue }
            let next = current.map { $0 + delta } ?? (delta > 0 ? 0 : options.count - 1)
            if options.indices.contains(next) { roll(to: next, direction: delta) }
            else { bump(direction: delta) }
            return
        }
        if let text = event.characters, text.count == 1,
           text.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }), !options.isEmpty {
            let current = options.firstIndex { $0.value == choiceValue } ?? -1
            for step in 1...options.count {
                let next = (current + step) % options.count
                if options[next].label.lowercased().hasPrefix(text.lowercased()) {
                    roll(to: next, direction: 1)
                    return
                }
            }
        }
        // Space opens the real native menu; Return belongs to the panel.
        super.keyDown(with: event)
    }

    private func bump(direction: Int) {
        guard !reduceMotion() else { return }
        wantsLayer = true
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        animation.values = [0, direction > 0 ? 2 : -2, 0]
        animation.duration = WishCardStyle.bump
        layer?.add(animation, forKey: "wish-edge")
    }

    private func roll(to index: Int, direction: Int) {
        guard options[index].value != choiceValue else { return }
        if !reduceMotion() {
            wantsLayer = true
            let transition = CATransition()
            transition.type = .push
            transition.subtype = direction > 0 ? .fromTop : .fromBottom
            transition.duration = WishCardStyle.roll
            layer?.add(transition, forKey: "wish-roll")
        }
        choiceValue = options[index].value
        selectItem(at: index + 1)
        needsDisplay = true
        changed(choiceValue)
    }

    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }
    func menuDidClose(_ menu: NSMenu) { isMenuOpen = false }

    override func draw(_ dirtyRect: NSRect) {
        let selected = window?.firstResponder === self
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        WishCardStyle.nsColor(0xF0E2C4).setFill()
        outline.fill()
        let invalid = !choiceValue.isEmpty && !options.contains { $0.value == choiceValue }
        WishCardStyle.nsColor(invalid ? 0xC2410C : (selected ? 0xE58A22 : 0xD7BF95)).setStroke()
        outline.lineWidth = selected ? 2 : 1
        outline.stroke()
        let label = options.first { $0.value == choiceValue }?.label ?? (choiceValue.isEmpty ? fieldLabel : choiceValue)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (label as NSString).draw(in: NSRect(x: 8, y: 3, width: max(0, bounds.width - 26), height: bounds.height - 4),
            withAttributes: [.font: WishCardStyle.fieldFont(provenance),
                .foregroundColor: WishCardStyle.ink(provenance, phase: phase), .paragraphStyle: paragraph])
        ("▴▾" as NSString).draw(in: NSRect(x: bounds.width - 19, y: 6, width: 18, height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: WishCardStyle.nsColor(0xB48A5A)])
    }
}

struct WishCardChoiceInput: NSViewRepresentable {
    let field: FillFieldState
    let wantsFocus: Bool
    let focusRevision: UInt64
    let phase: WishInkPhase
    let reduceMotion: () -> Bool
    let onChange: (String) -> Void
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WishCardTumbler {
        let button = WishCardTumbler(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.focusRingType = .none
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: WishCardTumbler, context: Context) {
        if button.options != field.options || button.numberOfItems == 0 {
            button.options = field.options
            button.removeAllItems()
            let empty = NSMenuItem(title: field.label, action: nil, keyEquivalent: "")
            empty.representedObject = ""
            button.menu?.addItem(empty)
            for option in field.options {
                let item = NSMenuItem(title: option.label, action: nil, keyEquivalent: "")
                item.representedObject = option.value
                button.menu?.addItem(item)
            }
        }
        button.menu?.delegate = button
        button.choiceValue = field.value
        button.fieldLabel = field.label
        button.provenance = field.provenance
        button.phase = phase
        button.changed = onChange
        button.reduceMotion = reduceMotion
        if field.value.isEmpty { button.selectItem(at: 0) }
        else if let index = field.options.firstIndex(where: { $0.value == field.value }) { button.selectItem(at: index + 1) }
        else { button.select(nil) }
        button.isEnabled = context.environment.isEnabled
        button.onFocus = onFocus
        button.identifier = NSUserInterfaceItemIdentifier("fill-field-" + field.name)
        button.setAccessibilityLabel(field.label)
        button.setAccessibilityValue(field.value)
        button.setAccessibilityHelp(field.description)
        button.toolTip = field.description
        button.pickerFocus.update(view: button, wantsFocus: wantsFocus, revision: focusRevision)
        button.needsDisplay = true
    }

    final class Coordinator: NSObject {
        @objc func changed(_ sender: WishCardTumbler) {
            guard let value = sender.selectedItem?.representedObject as? String else { return }
            sender.choiceValue = value
            sender.changed(value)
        }
    }
}
