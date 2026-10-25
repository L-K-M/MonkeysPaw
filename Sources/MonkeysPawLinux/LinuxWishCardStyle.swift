#if os(Linux)
import CGtk
import Foundation

enum WishCardMotion {
    static var enabled: Bool { mp_settings_boolean("gtk-enable-animations") != 0 }
    static let warmth = 0.420
    static let wick = 0.260
    static let roll = 0.140
    static let bump = 0.120
    static let dry = 0.450
    static let dryTransition = 0.520
    static let stagger = 0.045
    static let ink = 0.220
    static let slip = 0.200
    static let sheen = 0.560
    static let sparks = 0.420
    static let nudge = 0.260
    static let take = 0.220
    static func milliseconds(_ seconds: Double) -> UInt32 { UInt32(seconds * 1_000) }
}

/// Palette and geometry belong to this panel, never the Library's theme.
enum WishCardStyle {
    static let nightTop = "#1D1939", nightBottom = "#120F26"
    static let primary = "#ECE7F6", secondary = "#9A92B5", amber = "#FFB547"
    static let placeholder = "#7E7699", caption = "#8F87AA", keycap = "#C9C1E2"
    static let paperTop = "#FCF7EB", paperBottom = "#F3EAD8", bodyInk = "#3B3346"
    static let titleInk = "#9C4F24", folderInk = "#8A7A5A", tagInk = "#9C92A9"
    static let brassTop = "#F3D27A", brassBottom = "#B8892A", brassRim = "#7A5A12"
    static let pencil = "#6F667C", pencilRule = "#A79CB8", dryInk = "#8F4708"
    static let wetInk = "#C8650A", focusInk = "#E58A22", blankRule = "#B3A6C6"
    static let well = "#F2E9D6", emptyInk = "#857A97", tumblerTop = "#FFF9EC"
    static let tumblerBottom = "#F0E2C4", tumblerRim = "#D7BF95", tumblerArrow = "#B48A5A"
    static let invalid = "#C2410C", errorInk = "#A13A0B", stamp = "#A23B57"
    static let slipPaper = "#FFFEFA", slipInk = "#2E2A36"
    static let wickTrack = "#785A28", wickStart = "#E9902B", wickEnd = "#FFC765", ember = "#FFC86E"
    static let pawTop = "#3A2414", pawBottom = "#1A0F08", pawRim = "#FFBE6E"
    static let serif = "\"Literata\", \"Charis SIL\", \"P052\", \"Palatino\", \"Noto Serif\", \"DejaVu Serif\", serif"
    /// The desktop's own monospace face: a named face the system lacks is
    /// silently substituted by fontconfig, often with a poor match.
    static let mono = "monospace"
    static let pangoMono = "Monospace"
    static let bodySize = 15, proofSize = 12, wellSize = 12, tagSize = 11.0
    static let minimumSlotWidth = 48, slotPadding = 10, slotBaseline = 2
    static let wellMinimum = 26, wellMaximum = 170, wellFallbackWidth = 240
    static let bodyLineSpace = 3, panelGap = 12, cardGap = 10
    static let paperInset = 22, medallion = 12, resultsWidth = 232, fullWidthInset = 16, revealMargin = 18

    static func source(_ cr: OpaquePointer, _ hex: String, alpha: Double = 1) {
        let color = components(hex)
        cairo_set_source_rgba(cr, color.0, color.1, color.2, alpha)
    }

    static func stop(_ pattern: OpaquePointer, _ offset: Double, _ hex: String, _ alpha: Double = 1) {
        let color = components(hex)
        cairo_pattern_add_color_stop_rgba(pattern, offset, color.0, color.1, color.2, alpha)
    }

    private static func components(_ hex: String) -> (Double, Double, Double) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }

    private static var installedDisplays: [OpaquePointer] = []

    static func install(on widget: GTK.Widget) {
        guard let display = gtk_widget_get_display(widget), !installedDisplays.contains(display) else { return }
        installedDisplays.append(display)
        let provider = gtk_css_provider_new()!
        mp_css_load(provider, css)
        mp_add_style_provider(display, provider)
        g_object_unref(provider)
    }

    private static let css = """
    window.mp-picker.mp-night {
        background-image:
          radial-gradient(circle at 8% 12%, rgba(255,226,170,.55) 0, rgba(255,226,170,0) 1.2px),
          radial-gradient(circle at 23% 6%, rgba(255,226,170,.55) 0, rgba(255,226,170,0) 1.2px),
          radial-gradient(circle at 41% 14%, rgba(255,226,170,.55) 0, rgba(255,226,170,0) 1.2px),
          radial-gradient(circle at 62% 5%, rgba(255,226,170,.55) 0, rgba(255,226,170,0) 1.2px),
          radial-gradient(circle at 77% 11%, rgba(255,226,170,.55) 0, rgba(255,226,170,0) 1.2px),
          radial-gradient(circle at 90% 7%, rgba(255,226,170,.55) 0, rgba(255,226,170,0) 1.2px),
          radial-gradient(circle at 96% 18%, rgba(255,226,170,.55) 0, rgba(255,226,170,0) 1.2px),
          linear-gradient(180deg, \(nightTop), \(nightBottom));
        border: 1px solid rgba(255,196,120,.20); border-radius: 14px; color: \(primary);
    }
    .mp-night label, .mp-night image { color: \(primary); }
    .mp-night .dim-label, .mp-night .subtitle { color: \(secondary); opacity: 1; }
    .mp-night .caption { color: \(caption); font-size: 11px; }
    .mp-night list, .mp-night scrolledwindow, .mp-night viewport,
    .mp-night textview, .mp-night textview text { background: transparent; color: \(primary); }
    .mp-night entry, .mp-night searchentry {
        background: transparent; color: \(primary); caret-color: \(amber); box-shadow: none;
    }
    .mp-night .mp-picker-search {
        border: none; border-radius: 0; border-bottom: 1px solid rgba(255,255,255,.10);
        background: transparent; font-size: 18px; padding: 6px; outline: none;
    }
    .mp-night .mp-picker-search:focus-within { outline: none; box-shadow: none; }
    .mp-night .mp-picker-search placeholder { color: \(placeholder); }
    .mp-night list row { border-radius: 8px; padding: 6px 10px; font-size: 14px; }
    .mp-night list row .caption { font-size: 11px; color: \(secondary); }
    .mp-night list row:selected {
        background: linear-gradient(90deg, rgba(255,181,71,.18), rgba(255,181,71,.03));
        box-shadow: inset 3px 0 0 \(amber);
    }
    .mp-night .mp-favorite { color: \(amber); }
    .mp-night button { color: \(keycap); background: transparent; border-color: transparent; box-shadow: none; }
    .mp-night button:hover { background: rgba(255,255,255,.06); }
    .mp-night scrollbar { background: transparent; }
    .mp-night scrollbar slider { background: alpha(\(secondary), .45); border: none; }
    .mp-night button.mp-deliver {
        background: transparent; border: 1px solid rgba(255,181,71,.35);
        color: #B9A27A; border-radius: 999px; padding: 3px 12px;
    }
    .mp-night button.mp-deliver.mp-ready {
        background: \(amber); color: #2B1B06; box-shadow: 0 0 14px rgba(255,170,60,.45);
    }
    .mp-night button.mp-deliver label { color: inherit; }
    .mp-card, .mp-proof {
        background: linear-gradient(180deg, \(paperTop), \(paperBottom));
        color: \(bodyInk); border-radius: 10px; padding: 18px 22px 14px;
        border: 1px solid rgba(120,90,40,.25);
    }
    .mp-card { transition: box-shadow \(milliseconds(WishCardMotion.warmth)) ease-out; }
    .mp-card.mp-heat-0 { box-shadow: 0 10px 28px rgba(0,0,0,.50), 0 0 0 1px rgba(170,160,210,.22); }
    .mp-card.mp-heat-1 { box-shadow: 0 10px 28px rgba(0,0,0,.50), 0 0 0 1px rgba(170,160,210,.22), 0 0 16px rgba(255,170,60,.16); }
    .mp-card.mp-heat-2 { box-shadow: 0 10px 28px rgba(0,0,0,.50), 0 0 0 1px rgba(170,160,210,.22), 0 0 24px rgba(255,170,60,.28); }
    .mp-card.mp-ready { box-shadow: 0 10px 28px rgba(0,0,0,.50), 0 0 0 1px rgba(255,196,110,.85), 0 0 34px rgba(255,170,60,.48); }
    .mp-card label { color: \(bodyInk); }
    .mp-card .mp-card-title { color: \(titleInk); font-size: 10.5px; font-weight: 700; letter-spacing: 1.6px; }
    .mp-card .mp-card-folder { color: \(folderInk); font-size: 10.5px; font-weight: 700; letter-spacing: 1.6px; }
    .mp-medallion { background: radial-gradient(\(brassTop), \(brassBottom)); border: 1px solid \(brassRim); border-radius: 999px; min-width: 10px; min-height: 10px; }
    .mp-card .mp-card-body, .mp-card .mp-card-body text {
        font-family: \(serif); font-size: \(bodySize)px; background: transparent; color: \(bodyInk);
    }
    /* The proof is a paper sheet too; outrank the night's transparent views. */
    .mp-night scrolledwindow.mp-proof { background: linear-gradient(180deg, \(paperTop), \(paperBottom)); }
    .mp-proof textview, .mp-proof textview text { font-family: \(mono); font-size: \(proofSize)px; color: \(bodyInk); background: transparent; }
    .mp-card .mp-slot, .mp-card .mp-echo, .mp-card .mp-slot-static {
        font-family: \(serif); font-size: \(bodySize)px; font-weight: 400; color: \(dryInk);
        min-height: 22px; min-width: 0; padding: 0 2px; border: none; border-radius: 0; outline: none;
        background: transparent; box-shadow: none; border-bottom: 1.5px dashed \(blankRule);
        transition: color \(milliseconds(WishCardMotion.dryTransition)) ease-out, text-shadow \(milliseconds(WishCardMotion.dryTransition)) ease-out, opacity \(milliseconds(WishCardMotion.ink)) ease-out;
    }
    .mp-card .mp-slot placeholder { color: \(emptyInk); font-style: italic; }
    .mp-card .mp-slot:focus-within {
        background: radial-gradient(ellipse at center, rgba(255,190,90,.30), rgba(255,190,90,0) 75%);
        border-bottom: 2px solid \(focusInk); caret-color: \(focusInk); outline: none; box-shadow: none;
    }
    .mp-card button.mp-tumbler:focus, .mp-card button.mp-tumbler:focus-visible {
        outline: none; border-color: \(focusInk);
        box-shadow: inset 0 1px 0 rgba(255,255,255,.85), 0 0 0 2px rgba(229,138,34,.35), 0 0 12px rgba(255,170,60,.35);
    }
    .mp-card .mp-well:focus-within {
        box-shadow: inset 0 1px 3px rgba(60,40,10,.20), 0 0 0 2px rgba(229,138,34,.35);
    }
    .mp-card .mp-well textview, .mp-card .mp-well textview:focus { outline: none; }
    .mp-card .mp-gloss {
        font-family: \(serif); font-style: italic; font-size: 12px; color: \(folderInk);
        border-top: 1px dotted rgba(120,90,40,.30); padding-top: 6px;
    }
    .mp-card .mp-well, .mp-card .mp-well textview {
        background: \(well); font-family: \(mono); font-size: \(wellSize)px; border: none;
    }
    .mp-card .mp-well textview text { background: transparent; font-family: \(mono); font-size: \(wellSize)px; color: inherit; border: none; }
    .mp-card .mp-well { border-radius: 6px; padding: 7px 10px; box-shadow: inset 0 1px 3px rgba(60,40,10,.20); }
    .mp-card .mp-well-placeholder { color: \(emptyInk); font-style: italic; font-size: \(wellSize)px; }
    .mp-card button.mp-tumbler {
        background: linear-gradient(180deg, \(tumblerTop), \(tumblerBottom));
        border: 1px solid \(tumblerRim); border-radius: 6px;
        box-shadow: inset 0 1px 0 rgba(255,255,255,.85), 0 1px 2px rgba(80,50,10,.25);
        padding: 0 8px; min-height: 22px; color: \(dryInk); outline: none;
        transition: opacity \(milliseconds(WishCardMotion.ink)) ease-out;
    }
    .mp-card .mp-tumbler label { color: inherit; }
    .mp-card .mp-tumbler .mp-tumbler-arrow { color: \(tumblerArrow); font-size: 9px; }
    .mp-card .mp-echo { border-bottom: 1px dotted \(pencilRule); }
    .mp-card .mp-slot-static { font-size: 11px; font-weight: 600; color: \(emptyInk); }
    .mp-card .mp-ink-default, .mp-card .mp-ink-default text, .mp-card button.mp-ink-default {
        color: \(pencil); font-style: italic; font-weight: 400; border-bottom: 1px dotted \(pencilRule);
    }
    .mp-card .mp-ink-remembered, .mp-card .mp-ink-draft, .mp-card .mp-ink-typed,
    .mp-card .mp-ink-remembered text, .mp-card .mp-ink-draft text, .mp-card .mp-ink-typed text,
    .mp-card button.mp-ink-remembered, .mp-card button.mp-ink-draft, .mp-card button.mp-ink-typed { color: \(dryInk); }
    .mp-card .mp-ink-wet, .mp-card .mp-ink-wet text, .mp-card button.mp-ink-wet { color: \(wetInk); text-shadow: 0 0 6px rgba(255,170,60,.55); }
    .mp-card .mp-ink-pending { opacity: 0; }
    .mp-card .mp-well textview, .mp-card .mp-well textview text { border: none; }
    .mp-card selection, .mp-card text selection { background: rgba(255,181,71,.38); color: \(bodyInk); }
    .mp-card entry:not(:focus-within) selection { background: transparent; color: inherit; }
    .mp-card .mp-slot-invalid, .mp-card button.mp-slot-invalid { border: 1px dashed \(invalid); }
    .mp-card .mp-stamp {
        font-size: 11px; font-weight: bold; letter-spacing: 1px; color: \(stamp);
        border: 1.5px solid \(stamp); border-radius: 3px; padding: 0 5px; transform: rotate(-2deg); opacity: .88;
    }
    .mp-card .mp-card-error { color: \(errorInk); }
    @keyframes mp-bump-up { 50% { transform: translateY(-2px); } }
    @keyframes mp-bump-down { 50% { transform: translateY(2px); } }
    .mp-bump-up { animation: mp-bump-up \(milliseconds(WishCardMotion.bump)) ease-out; }
    .mp-bump-down { animation: mp-bump-down \(milliseconds(WishCardMotion.bump)) ease-out; }
    @keyframes mp-nudge {
        0% { transform: translateX(0); } 100% { transform: translateX(0); } 20% { transform: translateX(-4px); }
        40% { transform: translateX(4px); } 60% { transform: translateX(-3px); } 80% { transform: translateX(2px); }
    }
    .mp-card .mp-nudge { animation: mp-nudge \(milliseconds(WishCardMotion.nudge)) ease-out; border-bottom-color: \(invalid); }
    .mp-card .mp-slot.mp-nudge:focus-within, .mp-card button.mp-nudge,
    .mp-card .mp-well textview.mp-nudge { border-bottom: 2px solid \(invalid); }
    .mp-taken { opacity: 0; }
    .mp-picker popover button, .mp-picker popover label,
    .mp-picker .mp-card popover button, .mp-picker .mp-card popover button label {
        color: @theme_fg_color;
    }
    .mp-picker popover button:hover { background: alpha(@theme_fg_color, .08); }
    """

    private static func milliseconds(_ seconds: Double) -> String { "\(WishCardMotion.milliseconds(seconds))ms" }
}
#endif
