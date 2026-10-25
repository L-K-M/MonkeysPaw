import AppKit
import MonkeysPawCore
import QuartzCore
import SwiftUI

/// One discrete timer tick per exposure. Generation checks revoke queued work
/// on Escape, blur and root replacement, including a cancelled take's last tick.
final class WishCardTake {
    var scheduler: MonkeysPawCore.Scheduler = DispatchScheduler()
    var onChange: () -> Void = {}
    var playCue: (WishCardCue) -> Void = { _ in }
    private(set) var frameIndex: Int?
    private(set) var snapshot: NSImage?
    private(set) var cardRect = NSRect.zero
    private var generation: UInt64 = 0
    private var completion: (() -> Void)?
    weak var surface: NSView?
    weak var stage: NSView?

    var isPlaying: Bool { completion != nil }
    var holdsCard: Bool { snapshot != nil }

    @discardableResult func start(deliver: @escaping () -> Void) -> Bool {
        guard !holdsCard, let surface, let stage,
              surface.window != nil, surface.bounds.width > 0, surface.bounds.height > 0 else { return false }
        surface.window?.makeFirstResponder(nil)
        surface.layoutSubtreeIfNeeded()
        guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { return false }
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        bitmap.size = surface.bounds.size
        let image = NSImage(size: surface.bounds.size)
        image.addRepresentation(bitmap)
        snapshot = image
        cardRect = surface.convert(surface.bounds, to: stage)
        completion = deliver
        generation &+= 1
        show(0)
        queueNext(generation)
        return true
    }

    func cancel() {
        // Blur and hide cancel too; an idle take must not republish the picker.
        guard holdsCard || isPlaying else { return }
        generation &+= 1
        completion = nil
        snapshot = nil
        frameIndex = nil
        changed()
    }

    func finish() {
        guard let work = completion else { return }
        generation &+= 1
        completion = nil
        // Keep the frozen card until the delivery path hides the panel.
        work()
        changed()
    }

    private func queueNext(_ revision: UInt64) {
        scheduler.after(PawTake.frameInterval) { [weak self] in
            guard let self, self.generation == revision, self.isPlaying, let index = self.frameIndex else { return }
            if index + 1 == PawTake.frames.count { self.finish(); return }
            self.show(index + 1)
            self.queueNext(revision)
        }
    }

    private func show(_ index: Int) {
        frameIndex = index
        switch PawTake.frames[index].cue {
        case .crack: playCue(.crack)
        case .lift: playCue(.take)
        case nil: break
        }
        changed()
    }

    /// The stage view's inputs never change identity, so SwiftUI skips its
    /// update; each exposure marks it dirty here instead.
    private func changed() {
        stage?.needsDisplay = true
        onChange()
    }
}

/// Caching the native hosting view includes AppKit editors, unlike ImageRenderer.
struct WishCardSurface: NSViewRepresentable {
    let presentation: PickerViewState

    func makeNSView(context: Context) -> NSHostingView<WishCardView> {
        let view = NSHostingView(rootView: WishCardView(presentation: presentation))
        view.sizingOptions = []
        // Paper is always light; a dark appearance would draw black scroller
        // tracks and light default ink on it.
        view.appearance = NSAppearance(named: .aqua)
        view.identifier = NSUserInterfaceItemIdentifier("wish-card")
        presentation.take.surface = view
        return view
    }

    func updateNSView(_ view: NSHostingView<WishCardView>, context: Context) {
        view.rootView = WishCardView(presentation: presentation)
        presentation.take.surface = view
    }
}

struct WishCardTakeStage: NSViewRepresentable {
    let take: WishCardTake

    func makeNSView(context: Context) -> WishCardTakeDrawing {
        let view = WishCardTakeDrawing()
        view.take = take
        take.stage = view
        return view
    }

    func updateNSView(_ view: WishCardTakeDrawing, context: Context) {
        take.stage = view
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.take = take
        view.needsDisplay = true
        CATransaction.commit()
    }
}

final class WishCardTakeDrawing: NSView {
    weak var take: WishCardTake?
    /// The exposure last drawn by a display pass, so tests can see redraws.
    private(set) var drawnExposure: Int?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let take, let image = take.snapshot, let index = take.frameIndex else { drawnExposure = nil; return }
        drawnExposure = index
        let frame = PawTake.frames[index]
        let rect = take.cardRect
        let grip = NSPoint(x: rect.minX + rect.width * CGFloat(PawTake.gripFraction),
                           y: rect.minY + CGFloat(PawTake.gripDepth))
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: Double(rect.midX), yBy: Double(rect.midY) + frame.cardLift)
        transform.rotate(byDegrees: frame.cardTurn)
        transform.translateX(by: -Double(rect.midX), yBy: -Double(rect.midY))
        transform.concat()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: CGFloat(frame.cardOpacity),
                   respectFlipped: true, hints: nil)
        drawGouge(PawTake.gouge(upTo: frame.scratch), from: grip, opacity: CGFloat(frame.cardOpacity))
        NSGraphicsContext.restoreGraphicsState()

        // Art may arrive after the code. Missing frames leave the paper motion.
        if let paw = WishPawArt.image(frame.image) {
            let pawRect = NSRect(x: grip.x + CGFloat(frame.paw.x - PawTake.anchor.x),
                y: grip.y + CGFloat(frame.paw.y - PawTake.anchor.y),
                width: CGFloat(PawTake.imageSize.x), height: CGFloat(PawTake.imageSize.y))
            paw.draw(in: pawRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// A claw gouge in the paper: a pale torn lip under a dark furrow, with a
    /// faint bruise so it reads as cut into the card rather than drawn on it.
    private func drawGouge(_ points: [PawTake.Point], from grip: NSPoint, opacity: CGFloat) {
        guard points.count > 1 else { return }

        func path(offset: CGFloat) -> NSBezierPath {
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: grip.x + CGFloat(points[0].x) + offset, y: grip.y + CGFloat(points[0].y) + offset))
            for point in points.dropFirst() {
                path.line(to: NSPoint(x: grip.x + CGFloat(point.x) + offset, y: grip.y + CGFloat(point.y) + offset))
            }
            return path
        }

        let bruise = path(offset: 0)
        bruise.lineWidth = 4
        WishCardStyle.nsColor(0x51351F).withAlphaComponent(0.10 * opacity).setStroke()
        bruise.stroke()
        let lip = path(offset: 0.9)
        lip.lineWidth = 1.2
        WishCardStyle.nsColor(0xFFFEFA).withAlphaComponent(0.9 * opacity).setStroke()
        lip.stroke()
        let furrow = path(offset: 0)
        furrow.lineWidth = 1.4
        WishCardStyle.nsColor(0x4A2E1B).withAlphaComponent(0.8 * opacity).setStroke()
        furrow.stroke()
    }
}

/// The nine rendered paw exposures, loaded once. A synchronized group may
/// flatten `WishPaw/` into the bundle's resources or keep the folder, so both
/// are tried; a missing frame leaves the paper motion.
enum WishPawArt {
    private static let images: [NSImage?] = (0..<PawTake.imageCount).map(load)

    static func image(_ index: Int) -> NSImage? {
        images.indices.contains(index) ? images[index] : nil
    }

    private static func load(_ index: Int) -> NSImage? {
        let name = PawTake.imageName(index)
        if let image = Bundle.main.image(forResource: NSImage.Name(name)) { return image }

        let file = name + "@2x"
        guard let url = Bundle.main.url(forResource: file, withExtension: "png", subdirectory: "WishPaw")
                ?? Bundle.main.url(forResource: file, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: CGFloat(PawTake.imageSize.x), height: CGFloat(PawTake.imageSize.y))
        return image
    }
}
