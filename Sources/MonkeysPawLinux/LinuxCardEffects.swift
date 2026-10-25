#if os(Linux)
import CGtk
import Foundation

/// Cairo-drawn card effects for the wish picker. `LinuxCardEffects` renders a
/// card's warmth wick and the one-shot ready sheen; `LinuxPawTake` renders the
/// paw that grips a taken card over the whole panel. Timed pieces run on the
/// widget frame clock or `GTK.after`; every `cancel` leaves borrowed widgets
/// exactly as found, with no sources still armed.
private enum CardEffectMetric {
    static let wickHeight: Int32 = 3
    static let wickTrackAlpha = 0.15
    static let emberRadius = 2.5          // 5px ember head
    static let emberGlowRadius = 6.0
    static let emberGlowAlpha = 0.85
    static let sheenBandWidth = 90.0
    static let sheenBandAngle = 20.0 * .pi / 180
    static let sheenBandPeakAlpha = 0.30
    static let sheenWhite = "#FFFFFF"
    static let sparkRadius = 2.0
    static let sparkGlowRadius = 5.0
    static let sparkGlowAlpha = 0.40
    static let sparkGravity = 140.0
    /// Eight fixed launch velocities: up 50...110 px/s, sideways within ±40 px/s.
    static let sparkVelocities: [(x: Double, y: Double)] = [
        (-38, -62), (-30, -96), (-17, -55), (-7, -108),
        (8, -76), (18, -102), (27, -68), (38, -88),
    ]
}

private enum CardEase {
    static func cubicOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func cssOut(_ t: Double) -> Double { bezier(t, 0, 0, 0.58, 1) }
    static func cssInOut(_ t: Double) -> Double { bezier(t, 0.42, 0, 0.58, 1) }
    /// The timing function on the 35% keyframe of .mp-taking.
    static func takeRise(_ t: Double) -> Double { bezier(t, 0.5, 0, 0.75, 0) }

    /// CSS cubic-bezier(x1,y1,x2,y2): solve x(u)=t for u by Newton's method
    /// bracketed by bisection, then evaluate y(u).
    private static func bezier(_ t: Double, _ x1: Double, _ y1: Double,
                               _ x2: Double, _ y2: Double) -> Double {
        func curve(_ a: Double, _ b: Double, _ u: Double) -> Double {
            let v = 1 - u
            return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u
        }
        var u = t, lo = 0.0, hi = 1.0
        for _ in 0..<8 {
            let x = curve(x1, x2, u) - t
            if abs(x) < 0.000_1 { break }
            if x < 0 { lo = u } else { hi = u }
            let d = 3 * (1 - u) * (1 - u) * x1 + 6 * (1 - u) * u * (x2 - x1) + 3 * u * u * (1 - x2)
            let next = abs(d) > 0.000_001 ? u - x / d : (lo + hi) / 2
            u = min(1, max(0, next))
        }
        return curve(y1, y2, u)
    }
}

/// The warmth bar and the ready flash of a single wish card. The panel places
/// `wick` at the card's edge and layers `sheen` over the whole card; both stay
/// transparent until `update` says otherwise.
final class LinuxCardEffects {
    let wick: GTK.Widget
    let sheen: GTK.Widget

    private var displayedWarmth = 0.0
    private var wasReady = false
    private var easeFrom = 0.0, easeTo = 0.0
    private var wickBegan: Int64?
    private var wickTick: guint?
    private var wickAlive = true
    private var sheenBegan: Int64?
    private var sheenTick: guint?
    private var sweepT: Double?
    private var sparkOrigin: (x: Double, y: Double)?
    private var sheenAlive = true

    init() {
        wick = gtk_drawing_area_new()!
        gtk_drawing_area_set_content_height(mp_drawing_area(wick), CardEffectMetric.wickHeight)
        gtk_widget_set_hexpand(wick, 1)
        // The ember glows a few pixels past the 3px strip it sits on.
        gtk_widget_set_overflow(wick, GTK_OVERFLOW_VISIBLE)

        sheen = gtk_drawing_area_new()!
        // An effects layer, never a pointer target.
        gtk_widget_set_can_target(sheen, 0)

        GTK.draw(wick) { [weak self] cr, w, h in self?.drawWick(cr, w: Double(w), h: Double(h)) }
        GTK.draw(sheen) { [weak self] cr, w, h in self?.drawSheen(cr, w: Double(w), h: Double(h)) }

        // Unrealize drops a widget's tick callbacks and destroy takes the
        // widget; forget the ids both ways so cancel never touches them again.
        GTK.onSignal(UnsafeMutableRawPointer(wick), "unrealize") { [weak self] in
            self?.wickTick = nil
            self?.wickBegan = nil
        }
        GTK.onSignal(UnsafeMutableRawPointer(wick), "destroy") { [weak self] in
            self?.wickTick = nil
            self?.wickAlive = false
        }
        GTK.onSignal(UnsafeMutableRawPointer(sheen), "unrealize") { [weak self] in
            self?.sheenTick = nil
            self?.sheenBegan = nil
        }
        GTK.onSignal(UnsafeMutableRawPointer(sheen), "destroy") { [weak self] in
            self?.sheenTick = nil
            self?.sheenAlive = false
        }
    }

    func update(warmth: Double, ready: Bool) {
        let target = min(1, max(0, warmth))
        let transition = ready && !wasReady
        wasReady = ready

        guard WishCardMotion.enabled else {
            displayedWarmth = target
            if wickAlive { gtk_widget_queue_draw(wick) }
            return
        }

        // Retarget the ease without restarting its clock unless the goal moved.
        if target != easeTo || (wickTick == nil && displayedWarmth != target) {
            easeFrom = displayedWarmth
            easeTo = target
            wickBegan = nil
            if wickTick == nil, wickAlive {
                wickTick = GTK.tick(wick) { [weak self] now in self?.stepWick(now) ?? false }
            }
        }
        if wickAlive { gtk_widget_queue_draw(wick) }

        // One sweep and one spark burst per false-to-true transition, including
        // the very first update when it already arrives ready.
        if transition, sheenAlive {
            sheenBegan = nil
            sweepT = 0
            sparkOrigin = nil
            if sheenTick == nil {
                sheenTick = GTK.tick(sheen) { [weak self] now in self?.stepSheen(now) ?? false }
            }
        }
    }

    /// Removes every armed tick and clears pending effect state. Displayed
    /// warmth and the ready latch are state, not pending work, and stay.
    func cancel() {
        if let wickTick, wickAlive { GTK.removeTick(wick, wickTick) }
        wickTick = nil
        wickBegan = nil
        if let sheenTick, sheenAlive { GTK.removeTick(sheen, sheenTick) }
        sheenTick = nil
        sheenBegan = nil
        sweepT = nil
        sparkOrigin = nil
        if wickAlive { gtk_widget_queue_draw(wick) }
        if sheenAlive { gtk_widget_queue_draw(sheen) }
    }

    private func stepWick(_ now: Int64) -> Bool {
        if now == 0 { return true }
        if wickBegan == nil { wickBegan = now }
        let t = min(1, Double(now - (wickBegan ?? now)) / 1_000_000 / WishCardMotion.wick)
        displayedWarmth = easeFrom + (easeTo - easeFrom) * CardEase.cubicOut(t)
        if wickAlive { gtk_widget_queue_draw(wick) }
        if t >= 1 { wickTick = nil; return false }
        return true
    }

    private func stepSheen(_ now: Int64) -> Bool {
        if now == 0 { return true }
        if sheenBegan == nil { sheenBegan = now }
        let elapsed = Double(now - (sheenBegan ?? now)) / 1_000_000
        if elapsed >= WishCardMotion.sheen {
            sweepT = nil
            sparkOrigin = nil
            sheenTick = nil
            if sheenAlive { gtk_widget_queue_draw(sheen) }
            return false
        }
        sweepT = elapsed
        if sheenAlive { gtk_widget_queue_draw(sheen) }
        return true
    }

    private func drawWick(_ cr: OpaquePointer, w: Double, h: Double) {
        guard w > 0, h > 0 else { return }
        WishCardStyle.source(cr, WishCardStyle.wickTrack, alpha: CardEffectMetric.wickTrackAlpha)
        cairo_rectangle(cr, 0, 0, w, h)
        cairo_fill(cr)

        let fill = w * displayedWarmth
        guard fill > 0 else { return }
        let gradient = cairo_pattern_create_linear(0, 0, fill, 0)!
        WishCardStyle.stop(gradient, 0, WishCardStyle.wickStart, 1)
        WishCardStyle.stop(gradient, 1, WishCardStyle.wickEnd, 1)
        cairo_set_source(cr, gradient)
        cairo_pattern_destroy(gradient)
        cairo_rectangle(cr, 0, 0, fill, h)
        cairo_fill(cr)

        let x = fill, y = h / 2
        let glow = cairo_pattern_create_radial(x, y, 0, x, y, CardEffectMetric.emberGlowRadius)!
        WishCardStyle.stop(glow, 0, WishCardStyle.ember, CardEffectMetric.emberGlowAlpha)
        WishCardStyle.stop(glow, 1, WishCardStyle.ember, 0)
        cairo_set_source(cr, glow)
        cairo_pattern_destroy(glow)
        cairo_arc(cr, x, y, CardEffectMetric.emberGlowRadius, 0, 2 * .pi)
        cairo_fill(cr)
        WishCardStyle.source(cr, WishCardStyle.ember)
        cairo_arc(cr, x, y, CardEffectMetric.emberRadius, 0, 2 * .pi)
        cairo_fill(cr)
    }

    private func drawSheen(_ cr: OpaquePointer, w: Double, h: Double) {
        guard let elapsed = sweepT, w > 0, h > 0 else { return }
        let t = min(1, elapsed / WishCardMotion.sheen)

        // A 90px soft white band tilted 20° travels edge to edge, brightening
        // and fading on a sine so the sweep peaks mid-card.
        let extent = hypot(w, h) + CardEffectMetric.sheenBandWidth
        let margin = CardEffectMetric.sheenBandWidth / 2
            + sin(CardEffectMetric.sheenBandAngle) * extent / 2
        let x = -margin + (w + 2 * margin) * CardEase.cssInOut(t)
        let alpha = CardEffectMetric.sheenBandPeakAlpha * sin(.pi * t)
        cairo_save(cr)
        cairo_translate(cr, x, h / 2)
        cairo_rotate(cr, CardEffectMetric.sheenBandAngle)
        let band = cairo_pattern_create_linear(-CardEffectMetric.sheenBandWidth / 2, 0,
                                               CardEffectMetric.sheenBandWidth / 2, 0)!
        WishCardStyle.stop(band, 0, CardEffectMetric.sheenWhite, 0)
        WishCardStyle.stop(band, 0.5, CardEffectMetric.sheenWhite, alpha)
        WishCardStyle.stop(band, 1, CardEffectMetric.sheenWhite, 0)
        cairo_set_source(cr, band)
        cairo_pattern_destroy(band)
        cairo_rectangle(cr, -CardEffectMetric.sheenBandWidth / 2, -extent / 2,
                        CardEffectMetric.sheenBandWidth, extent)
        cairo_fill(cr)
        cairo_restore(cr)

        guard elapsed <= WishCardMotion.sparks else { return }
        let origin = sparkOrigin ?? resolveSparkOrigin(w: w, h: h)
        let fade = 1 - elapsed / WishCardMotion.sparks
        for velocity in CardEffectMetric.sparkVelocities {
            let sx = origin.x + velocity.x * elapsed
            let sy = origin.y + velocity.y * elapsed
                + CardEffectMetric.sparkGravity * elapsed * elapsed / 2
            let glow = cairo_pattern_create_radial(sx, sy, 0, sx, sy,
                                                   CardEffectMetric.sparkGlowRadius)!
            WishCardStyle.stop(glow, 0, WishCardStyle.amber, CardEffectMetric.sparkGlowAlpha * fade)
            WishCardStyle.stop(glow, 1, WishCardStyle.amber, 0)
            cairo_set_source(cr, glow)
            cairo_pattern_destroy(glow)
            cairo_arc(cr, sx, sy, CardEffectMetric.sparkGlowRadius, 0, 2 * .pi)
            cairo_fill(cr)
            WishCardStyle.source(cr, WishCardStyle.ember, alpha: fade)
            cairo_arc(cr, sx, sy, CardEffectMetric.sparkRadius, 0, 2 * .pi)
            cairo_fill(cr)
        }
    }

    /// Sparks leave from the wick's ember head, resolved in sheen coordinates.
    /// A real bounds answer is cached for the burst; the fallback (full-width
    /// wick along the sheen's bottom edge) is recomputed until one lands.
    private func resolveSparkOrigin(w: Double, h: Double) -> (x: Double, y: Double) {
        if wickAlive {
            var bounds = graphene_rect_t()
            if gtk_widget_compute_bounds(wick, sheen, &bounds) != 0 {
                let origin = (x: Double(bounds.origin.x) + displayedWarmth * Double(bounds.size.width),
                              y: Double(bounds.origin.y) + Double(bounds.size.height) / 2)
                sparkOrigin = origin
                return origin
            }
        }
        return (x: displayedWarmth * w, y: h - Double(CardEffectMetric.wickHeight) / 2)
    }
}

private enum PawSegment {
    case m(Double, Double), l(Double, Double)
    case c(Double, Double, Double, Double, Double, Double)
    case z
}

private enum PawTakeMetric {
    /// The paw is drawn this tall; its fingers hang `overlap` onto the card's
    /// face, the way the icon's paw grips its card.
    static let height = 168.0
    static let viewBox = 24.0
    static let drawingHeight = 19.34
    static let overlap = 40.0
    /// Where along the card's width the paw grips, and its slant.
    static let gripX = 0.36
    static let tilt = -10.0 * .pi / 180
    /// Phases of WishCardMotion.take: reach and press, hold, carry away.
    static let reachEnd = 0.34
    static let holdEnd = 0.46
    /// The press: the card yields slightly to the grip.
    static let pressScale = 0.965
    static let pressDip = 6.0
    /// The carry: up past the panel's top edge, turning and shrinking.
    static let carryTurn = -5.0 * .pi / 180
    static let carryScale = 0.9
    static let fadeFrom = 0.55
    static let rimWidth = 1.2
    static let rimAlpha = 0.55
    static let shadowOffset = (x: 2.5, y: 5.0)
    static let shadowAlpha = 0.28
    /// Amber glow under the fingertips, in path units (viewBox space).
    static let glowX = 10.5, glowY = 18.4, glowRadius = 9.0, glowAlpha = 0.55
    /// The card keeps its ready glow while it travels: a soft halo and a
    /// dark drop shadow, approximated by expanding translucent outlines.
    static let haloSteps = 8
    static let haloSpread = 2.5
    static let haloAlpha = 0.07
    static let dropOffset = 10.0
    static let cornerRadius = 10.0
    /// media-sources/paw-symbol.svg, transcribed; M, L, C and Z only.
    static let path: [PawSegment] = [
        .m(6.90, 0.00),
        .c(6.45, 0.45, 6.40, 0.60, 6.30, 0.90),
        .l(5.72, 1.45), .l(5.92, 1.32), .l(5.95, 2.25), .l(5.30, 2.80),
        .l(5.57, 2.67), .l(5.62, 3.65), .l(4.95, 4.15), .l(5.24, 4.07),
        .c(4.35, 4.80, 4.55, 4.80, 4.80, 4.80),
        .c(4.55, 6.60, 5.00, 7.90, 5.45, 9.35),
        .c(5.23, 11.80, 3.97, 13.10, 4.25, 14.80),
        .c(4.39, 15.45, 4.90, 15.84, 5.20, 15.70),
        .c(5.58, 15.84, 6.05, 15.40, 6.15, 14.80),
        .c(6.00, 12.30, 7.20, 12.52, 7.55, 9.35),
        .c(7.74, 8.83, 8.31, 8.83, 8.50, 9.35),
        .c(8.28, 11.80, 7.34, 15.30, 7.62, 17.00),
        .c(7.76, 17.65, 8.30, 18.04, 8.60, 17.90),
        .c(8.98, 18.04, 9.48, 17.60, 9.58, 17.00),
        .c(9.43, 14.50, 10.35, 13.62, 10.70, 9.35),
        .c(10.89, 8.83, 11.41, 8.83, 11.60, 9.35),
        .c(11.38, 11.80, 10.64, 16.60, 10.92, 18.30),
        .c(11.06, 18.95, 11.60, 19.34, 11.90, 19.20),
        .c(12.28, 19.34, 12.78, 18.90, 12.88, 18.30),
        .c(12.73, 15.80, 13.45, 14.27, 13.80, 9.35),
        .c(13.99, 8.83, 14.56, 8.83, 14.75, 9.35),
        .c(14.53, 11.80, 14.07, 14.30, 14.35, 16.00),
        .c(14.49, 16.65, 15.00, 17.04, 15.30, 16.90),
        .c(15.68, 17.04, 16.15, 16.60, 16.25, 16.00),
        .c(16.10, 13.50, 16.30, 10.40, 17.35, 10.55),
        .c(17.60, 10.90, 17.40, 11.30, 17.50, 11.70),
        .c(18.30, 12.70, 20.55, 12.55, 22.20, 11.90),
        .c(23.10, 12.30, 23.50, 10.85, 22.25, 10.20),
        .c(21.40, 9.45, 19.75, 9.50, 19.00, 7.60),
        .c(19.25, 6.30, 16.10, 3.00, 14.40, 0.00),
        .z,
    ]
}

/// The monkey paw that takes a card. The panel layers `widget` over the
/// whole window. `play` freezes the card into an image, hides the live card,
/// and draws the take with Cairo:
///
///   0 ──── reach ──── .34 ─ hold ─ .46 ──────── carry ──────── 1
///   paw drops in,         claws        card and paw rise past the
///   card yields 3.5%      set          top edge, turning and fading
final class LinuxPawTake {
    let widget: GTK.Widget

    private var tickID: guint?
    private var timerID: guint?
    private var widgetAlive = true
    private var card: GTK.Widget?
    private var image: OpaquePointer?
    private var captureRevision = 0
    private var completion: (() -> Void)?
    private var began: Int64?
    private var progress = 0.0
    private var showing = false
    private var frame = (x: 0.0, y: 0.0, width: 0.0, height: 0.0)

    init() {
        widget = gtk_drawing_area_new()!
        // The panel reuses this overlay across library graph replacements.
        // Keep our own reference while its old GtkOverlay unparents it.
        g_object_ref_sink(widget)
        gtk_widget_set_can_target(widget, 0)

        GTK.draw(widget) { [weak self] cr, w, h in self?.draw(cr, w: Double(w), h: Double(h)) }
        GTK.onSignal(UnsafeMutableRawPointer(widget), "unrealize") { [weak self] in
            self?.tickID = nil
            self?.began = nil
        }
        GTK.onSignal(UnsafeMutableRawPointer(widget), "destroy") { [weak self] in
            self?.tickID = nil
            self?.widgetAlive = false
        }
    }

    deinit {
        cancel()
        g_object_unref(widget)
    }

    /// Grips the card and carries it off. With animations off the completion
    /// fires immediately and no classes, ticks or timers are ever armed.
    func play(card: GTK.Widget, completion: @escaping () -> Void) {
        cancel()
        guard WishCardMotion.enabled else {
            completion()
            return
        }

        self.completion = completion
        self.card = card
        let observed = card
        GTK.onSignal(UnsafeMutableRawPointer(card), "destroy") { [weak self] in
            if self?.card == observed { self?.card = nil }
        }
        // Freeze the card once its layout is current (the key press that got
        // here may have queued one); until then the live card stays put.
        captureRevision += 1
        let revision = captureRevision
        GTK.afterNextPaint(widget) { [weak self] in
            guard let self, self.captureRevision == revision, self.showing, let card = self.card else { return }
            self.capture(card)
        }
        progress = 0
        began = nil
        showing = true
        tickID = GTK.tick(widget) { [weak self] now in self?.step(now) ?? false }
        timerID = GTK.after(WishCardMotion.take) { [weak self] in
            self?.timerID = nil
            self?.finish()
        }
        if widgetAlive { gtk_widget_queue_draw(widget) }
    }

    private func capture(_ card: GTK.Widget) {
        var bounds = graphene_rect_t()
        guard gtk_widget_compute_bounds(card, widget, &bounds) != 0,
              let image = mp_widget_capture(card) else { return }
        frame = (Double(bounds.origin.x), Double(bounds.origin.y),
                 Double(bounds.size.width), Double(bounds.size.height))
        self.image = image
        // Opacity alone hides the live card; the image does all the moving.
        gtk_widget_add_css_class(card, "mp-taken")
        if widgetAlive { gtk_widget_queue_draw(widget) }
    }

    /// Drops the class back off a still-living card and disarms every source
    /// without completing. Safe to call twice or after the widgets are gone.
    func cancel() {
        if let timerID {
            g_source_remove(timerID)
            self.timerID = nil
        }
        if let tickID, widgetAlive { GTK.removeTick(widget, tickID) }
        tickID = nil
        began = nil
        captureRevision += 1
        if let card { gtk_widget_remove_css_class(card, "mp-taken") }
        card = nil
        if let image { cairo_surface_destroy(image) }
        image = nil
        completion = nil
        showing = false
        progress = 0
        if widgetAlive { gtk_widget_queue_draw(widget) }
    }

    private func step(_ now: Int64) -> Bool {
        if now == 0 { return true }
        if began == nil { began = now }
        progress = min(1, Double(now - (began ?? now)) / 1_000_000 / WishCardMotion.take)
        if widgetAlive { gtk_widget_queue_draw(widget) }
        if progress >= 1 {
            tickID = nil
            return false
        }
        return true
    }

    /// Runs exactly once, from the timer. The live card stays hidden until
    /// the panel's dismissal resets it.
    private func finish() {
        if let tickID, widgetAlive { GTK.removeTick(widget, tickID) }
        tickID = nil
        // The timeout can edge out the last frame; land the final pose.
        progress = 1
        if widgetAlive { gtk_widget_queue_draw(widget) }
        let completion = self.completion
        self.completion = nil
        completion?()
    }

    /// The card's pose at `t`: offset, scale, turn and opacity.
    private func pose(_ t: Double) -> (dy: Double, scale: Double, turn: Double, alpha: Double) {
        typealias M = PawTakeMetric
        if t <= M.reachEnd {
            let s = CardEase.cubicOut(t / M.reachEnd)
            return (M.pressDip * s, 1 - (1 - M.pressScale) * s, 0, 1)
        }
        if t <= M.holdEnd { return (M.pressDip, M.pressScale, 0, 1) }
        let s = CardEase.takeRise((t - M.holdEnd) / (1 - M.holdEnd))
        let travel = -(frame.y + frame.height * 0.9) - M.pressDip
        let fade = max(0, (s - M.fadeFrom) / (1 - M.fadeFrom))
        return (M.pressDip + travel * s, M.pressScale + (M.carryScale - M.pressScale) * s, M.carryTurn * s, 1 - fade)
    }

    private func draw(_ cr: OpaquePointer, w: Double, h: Double) {
        guard showing, image != nil, w > 0, h > 0 else { return }
        typealias M = PawTakeMetric
        let pose = pose(progress)
        let center = (x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)

        // Card space: every later drawing rides with the card.
        cairo_save(cr)
        defer { cairo_restore(cr) }
        cairo_translate(cr, center.x, center.y + pose.dy)
        cairo_rotate(cr, pose.turn)
        cairo_scale(cr, pose.scale, pose.scale)
        cairo_translate(cr, -frame.width / 2, -frame.height / 2)

        cairo_push_group(cr)
        drawHalo(cr)
        if let image {
            cairo_set_source_surface(cr, image, 0, 0)
            cairo_paint(cr)
        }
        drawPaw(cr)
        cairo_pop_group_to_source(cr)
        cairo_paint_with_alpha(cr, pose.alpha)
    }

    /// The ready glow and drop shadow the live card wore, drawn by hand.
    private func drawHalo(_ cr: OpaquePointer) {
        typealias M = PawTakeMetric
        for step in 0..<M.haloSteps {
            let spread = Double(step + 1) * M.haloSpread
            let alpha = M.haloAlpha * Double(M.haloSteps - step) / Double(M.haloSteps)
            roundedRect(cr, -spread, M.dropOffset - spread, frame.width + spread * 2, frame.height + spread * 2)
            cairo_set_source_rgba(cr, 0, 0, 0, alpha * 1.6)
            cairo_fill(cr)
            roundedRect(cr, -spread, -spread, frame.width + spread * 2, frame.height + spread * 2)
            WishCardStyle.source(cr, WishCardStyle.amber, alpha: alpha)
            cairo_fill(cr)
        }
    }

    /// The paw drops in from above the panel and hangs its fingers over the
    /// card's face; once it grips, it rides in card space.
    private func drawPaw(_ cr: OpaquePointer) {
        typealias M = PawTakeMetric
        let scale = M.height / M.drawingHeight
        let reach = progress < M.reachEnd ? CardEase.cubicOut(progress / M.reachEnd) : 1
        // From fully above the panel's top edge to the grip.
        let gripTop = M.overlap - M.height
        let startTop = -(frame.y + M.height + M.pressDip)
        let top = startTop + (gripTop - startTop) * reach

        cairo_save(cr)
        defer { cairo_restore(cr) }
        cairo_translate(cr, frame.width * M.gripX, top)
        cairo_rotate(cr, M.tilt)
        cairo_scale(cr, scale, scale)
        cairo_translate(cr, -M.viewBox / 2, 0)

        // Contact shadow on the paper, then the warm light under the claws.
        cairo_save(cr)
        cairo_translate(cr, M.shadowOffset.x / scale, M.shadowOffset.y / scale)
        tracePaw(cr)
        cairo_set_source_rgba(cr, 0.12, 0.06, 0.02, M.shadowAlpha)
        cairo_fill(cr)
        cairo_restore(cr)

        let glow = cairo_pattern_create_radial(M.glowX, M.glowY, 0, M.glowX, M.glowY, M.glowRadius)!
        WishCardStyle.stop(glow, 0, WishCardStyle.amber, M.glowAlpha * reach)
        WishCardStyle.stop(glow, 1, WishCardStyle.amber, 0)
        cairo_set_source(cr, glow)
        cairo_pattern_destroy(glow)
        cairo_arc(cr, M.glowX, M.glowY, M.glowRadius, 0, 2 * .pi)
        cairo_fill(cr)

        tracePaw(cr)
        let fill = cairo_pattern_create_linear(0, 0, 0, M.drawingHeight)!
        WishCardStyle.stop(fill, 0, WishCardStyle.pawTop, 1)
        WishCardStyle.stop(fill, 1, WishCardStyle.pawBottom, 1)
        cairo_set_source(cr, fill)
        cairo_pattern_destroy(fill)
        cairo_fill_preserve(cr)
        WishCardStyle.source(cr, WishCardStyle.pawRim, alpha: M.rimAlpha)
        cairo_set_line_width(cr, M.rimWidth / scale)
        cairo_stroke(cr)
    }

    private func tracePaw(_ cr: OpaquePointer) {
        for segment in PawTakeMetric.path {
            switch segment {
            case let .m(x, y): cairo_move_to(cr, x, y)
            case let .l(x, y): cairo_line_to(cr, x, y)
            case let .c(x1, y1, x2, y2, x, y): cairo_curve_to(cr, x1, y1, x2, y2, x, y)
            case .z: cairo_close_path(cr)
            }
        }
    }

    private func roundedRect(_ cr: OpaquePointer, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        let r = min(PawTakeMetric.cornerRadius, w / 2, h / 2)
        cairo_new_sub_path(cr)
        cairo_arc(cr, x + w - r, y + r, r, -.pi / 2, 0)
        cairo_arc(cr, x + w - r, y + h - r, r, 0, .pi / 2)
        cairo_arc(cr, x + r, y + h - r, r, .pi / 2, .pi)
        cairo_arc(cr, x + r, y + r, r, .pi, 3 * .pi / 2)
        cairo_close_path(cr)
    }
}
#endif
