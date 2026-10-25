#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Cairo-drawn card effects for the wish picker. `LinuxCardEffects` renders a
/// card's warmth wick and the one-shot ready sheen; `LinuxPawTake` renders the
/// paw that grips a taken card over the whole panel. Timed pieces run on the
/// widget frame clock or `GTK.after`; cancellation restores borrowed widgets
/// and revokes queued work.
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
    static func cssInOut(_ t: Double) -> Double { bezier(t, 0.42, 0, 0.58, 1) }

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
            // Motion may be switched off mid-effect: disarm what is running.
            cancel()
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
        if t >= 1 {
            // Land exactly: float residue would re-arm an empty ease later.
            displayedWarmth = easeTo
            wickTick = nil
            return false
        }
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

/// Freezes the card after its next paint, then plays Core's discrete
/// exposures. The live card stays hidden until delivery hides the panel.
final class LinuxPawTake {
    let widget: GTK.Widget
    var scheduler: Scheduler = GLibScheduler()
    var playCue: (WishCardCue) -> Void = { _ in }
    private(set) var frameIndex: Int?

    private let frames: LinuxPawFrames
    private var widgetAlive = true
    private var card: GTK.Widget?
    private var image: OpaquePointer?
    private var revision: UInt64 = 0
    private var completion: (() -> Void)?
    private var cardRect = (x: 0.0, y: 0.0, width: 0.0, height: 0.0)

    var isPlaying: Bool { completion != nil }

    init(frames: LinuxPawFrames) {
        self.frames = frames
        widget = gtk_drawing_area_new()!
        // The panel reuses this overlay across library graph replacements.
        // Keep our own reference while its old GtkOverlay unparents it.
        g_object_ref_sink(widget)
        gtk_widget_set_can_target(widget, 0)

        GTK.draw(widget) { [weak self] cr, _, _ in self?.draw(cr) }
        GTK.onSignal(UnsafeMutableRawPointer(widget), "unrealize") { [weak self] in self?.cancel() }
        GTK.onSignal(UnsafeMutableRawPointer(widget), "destroy") { [weak self] in
            self?.widgetAlive = false
            self?.cancel()
        }
    }

    deinit {
        cancel()
        g_object_unref(widget)
    }

    /// With animations off no capture or exposures are queued.
    func play(card: GTK.Widget, completion: @escaping () -> Void) {
        cancel()
        guard WishCardMotion.enabled, widgetAlive, gtk_widget_get_frame_clock(widget) != nil else {
            completion()
            return
        }

        self.completion = completion
        self.card = card
        let observed = card
        GTK.onSignal(UnsafeMutableRawPointer(card), "destroy") { [weak self] in
            guard let self, self.card == observed else { return }
            self.card = nil
            self.cancel()
        }
        // The key press may have queued layout; capture only after it paints.
        let generation = revision
        GTK.afterNextPaint(widget) { [weak self] in
            guard let self, self.revision == generation, let card = self.card else { return }
            self.capture(card)
            _ = self.frames.image(0)
            self.show(0)
            self.queueNext(generation)
        }
    }

    private func capture(_ card: GTK.Widget) {
        var bounds = graphene_rect_t()
        guard gtk_widget_compute_bounds(card, widget, &bounds) != 0,
              let image = mp_widget_capture(card) else { return }
        cardRect = (Double(bounds.origin.x), Double(bounds.origin.y),
                    Double(bounds.size.width), Double(bounds.size.height))
        self.image = image
        gtk_widget_add_css_class(card, "mp-taken")
    }

    /// Restore the live card and revoke even the last queued exposure.
    func cancel() {
        revision &+= 1
        completion = nil
        frameIndex = nil
        if let card { gtk_widget_remove_css_class(card, "mp-taken") }
        card = nil
        if let image { cairo_surface_destroy(image) }
        image = nil
        if widgetAlive { gtk_widget_queue_draw(widget) }
    }

    /// Also handles a fresh Return before capture. Keep any frozen card until
    /// the delivery path hides the panel, so the live paper never flashes back.
    func finish() {
        guard let work = completion else { return }
        revision &+= 1
        completion = nil
        if let card { gtk_widget_add_css_class(card, "mp-taken") }
        work()
    }

    private func queueNext(_ generation: UInt64) {
        scheduler.after(PawTake.frameInterval) { [weak self] in
            guard let self, self.revision == generation, self.completion != nil,
                  let index = self.frameIndex else { return }
            if index + 1 == PawTake.frames.count { self.finish(); return }
            self.show(index + 1)
            self.queueNext(generation)
        }
    }

    private func show(_ index: Int) {
        frameIndex = index
        switch PawTake.frames[index].cue {
        case .crack: playCue(.crack)
        case .lift: playCue(.take)
        case nil: break
        }
        if widgetAlive { gtk_widget_queue_draw(widget) }
    }

    private func draw(_ cr: OpaquePointer) {
        guard let image, let index = frameIndex else { return }
        let frame = PawTake.frames[index]
        let grip = (x: cardRect.x + cardRect.width * PawTake.gripFraction,
                    y: cardRect.y + PawTake.gripDepth)
        let center = (x: cardRect.x + cardRect.width / 2, y: cardRect.y + cardRect.height / 2)

        cairo_save(cr)
        cairo_translate(cr, center.x, center.y + frame.cardLift)
        cairo_rotate(cr, frame.cardTurn * .pi / 180)
        cairo_translate(cr, -center.x, -center.y)
        cairo_set_source_surface(cr, image, cardRect.x, cardRect.y)
        cairo_paint_with_alpha(cr, frame.cardOpacity)
        drawGouge(cr, points: PawTake.gouge(upTo: frame.scratch), grip: grip, opacity: frame.cardOpacity)
        cairo_restore(cr)

        if let paw = frames.image(frame.image) {
            cairo_save(cr)
            cairo_translate(cr, grip.x + frame.paw.x - PawTake.anchor.x,
                            grip.y + frame.paw.y - PawTake.anchor.y)
            // @2x pixels occupy half a user-space point, including on HiDPI.
            cairo_scale(cr, 0.5, 0.5)
            cairo_set_source_surface(cr, paw, 0, 0)
            cairo_paint(cr)
            cairo_restore(cr)
        }
    }

    /// Match the shared take's bruise, pale torn lip and dark furrow.
    private func drawGouge(_ cr: OpaquePointer, points: [PawTake.Point],
                           grip: (x: Double, y: Double), opacity: Double) {
        guard let first = points.first, points.count > 1 else { return }
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)

        func stroke(offset: Double, width: Double, color: String, alpha: Double) {
            cairo_new_path(cr)
            cairo_move_to(cr, grip.x + first.x + offset, grip.y + first.y + offset)
            for point in points.dropFirst() {
                cairo_line_to(cr, grip.x + point.x + offset, grip.y + point.y + offset)
            }
            cairo_set_line_width(cr, width)
            WishCardStyle.source(cr, color, alpha: alpha * opacity)
            cairo_stroke(cr)
        }
        stroke(offset: 0, width: 4, color: "#51351F", alpha: 0.10)
        stroke(offset: 0.9, width: 1.2, color: "#FFFEFA", alpha: 0.9)
        stroke(offset: 0, width: 1.4, color: "#4A2E1B", alpha: 0.8)
    }
}
#endif
