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
        generation &+= 1
        completion = nil
        snapshot = nil
        frameIndex = nil
        onChange()
    }

    func finish() {
        guard let work = completion else { return }
        generation &+= 1
        completion = nil
        // Keep the frozen card until the delivery path hides the panel.
        work()
        onChange()
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
        onChange()
    }
}

/// Caching the native hosting view includes AppKit editors, unlike ImageRenderer.
struct WishCardSurface: NSViewRepresentable {
    let presentation: PickerViewState

    func makeNSView(context: Context) -> NSHostingView<WishCardView> {
        let view = NSHostingView(rootView: WishCardView(presentation: presentation))
        view.sizingOptions = []
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
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let take, let image = take.snapshot, let index = take.frameIndex else { return }
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
        for scratch in PawTake.scratches {
            let start = NSPoint(x: grip.x + CGFloat(scratch.from.x), y: grip.y + CGFloat(scratch.from.y))
            let end = NSPoint(x: start.x + CGFloat((scratch.to.x - scratch.from.x) * frame.scratch),
                              y: start.y + CGFloat((scratch.to.y - scratch.from.y) * frame.scratch))
            let tear = NSBezierPath()
            tear.move(to: NSPoint(x: start.x + 1, y: start.y))
            tear.line(to: NSPoint(x: end.x + 1, y: end.y))
            tear.lineWidth = 2
            WishCardStyle.nsColor(0xFFFEFA).withAlphaComponent(CGFloat(frame.cardOpacity)).setStroke()
            tear.stroke()
            let claw = NSBezierPath()
            claw.move(to: start)
            claw.line(to: end)
            claw.lineWidth = 1
            WishCardStyle.nsColor(0x51351F).withAlphaComponent(CGFloat(frame.cardOpacity)).setStroke()
            claw.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Art may arrive after the code. Missing frames leave the paper motion.
        if let paw = Bundle.main.image(forResource: NSImage.Name(PawTake.imageName(frame.image))) {
            let pawRect = NSRect(x: grip.x + CGFloat(frame.paw.x - PawTake.anchor.x),
                y: grip.y + CGFloat(frame.paw.y - PawTake.anchor.y),
                width: CGFloat(PawTake.imageSize.x), height: CGFloat(PawTake.imageSize.y))
            paw.draw(in: pawRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}
