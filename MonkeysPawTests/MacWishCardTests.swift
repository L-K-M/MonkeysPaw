import AppKit
import Carbon.HIToolbox
import MonkeysPawCore
import SwiftUI
import XCTest
@testable import MonkeysPaw

/// One queued callback per `after`; `advance()` runs exactly one, so the take
/// exposes one paw frame per call. The UI tour's take captures use this seam.
final class WishCardStepper: MonkeysPawCore.Scheduler {
    private var pending: [() -> Void] = []
    private(set) var intervals: [Duration] = []
    var queued: Int { pending.count }
    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        intervals.append(delay)
        pending.append(work)
    }
    @discardableResult func advance() -> Bool {
        guard !pending.isEmpty else { return false }
        pending.removeFirst()()
        return true
    }
}

extension NSView {
    /// Window frame, visible part and scroll clip, for visibility failures
    /// that only CI's Mac can reproduce.
    func placementDescription() -> String {
        let clip = enclosingScrollView.map { NSStringFromRect($0.documentVisibleRect) } ?? "none"
        let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        return "frame=" + NSStringFromRect(convert(bounds, to: nil)) + " visible=" + NSStringFromRect(visibleRect)
            + " clip=" + clip + " responder=" + responder
    }
}

/// Hosted Wish Card coverage on the real panel, mirroring MacPickerViewTests'
/// isolated roots. MacPickerViewTests retains the broader mixed-control
/// traversal, marked-text and undo coverage.
final class MacWishCardTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var data: URL!
    private var files: RootedFileStore!
    private var delegate: AppDelegate!
    private var controller: PanelController!
    private var originalWindows: Set<ObjectIdentifier> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("library", isDirectory: true)
        data = directory.appendingPathComponent("data", isDirectory: true)
        files = try RootedFileStore(root: root)
    }

    override func tearDown() {
        defer { super.tearDown() }
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate?.pickerModel?.dismiss()
        controller?.hide()
        for window in NSApp.windows where !originalWindows.contains(ObjectIdentifier(window)) { window.close() }
        delegate = nil
        controller = nil
        files = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func start(scheduler: MonkeysPawCore.Scheduler = DispatchScheduler(),
                       clipboard: Clipboard = PasteboardClipboard(),
                       pasteInjectors: [PasteInjector]? = nil) throws -> PickerModel {
        delegate = AppDelegate(libraryRoot: root, dataRoot: data, launchURI: { _ in },
            clipboard: clipboard, pasteInjectors: pasteInjectors,
            makeFocusTracker: { main, scheduler in
                WorkspaceFocusTracker(source: .init(frontmost: { nil }, activate: { _ in
                    XCTFail("Hosted wish card tests must not activate an external app")
                    return false
                }), mainThread: main, scheduler: scheduler, isTrusted: { false }, deactivateIfUnused: {})
            }, scheduler: scheduler, makePanelController: { [weak self] main, scheduler, log in
                let panel = PanelController(mainThread: main, scheduler: scheduler, log: log)
                self?.controller = panel
                return panel
            })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.pickerPresentation?.reduceMotion = { false }
        return try XCTUnwrap(delegate.pickerModel)
    }

    private func open(scheduler: MonkeysPawCore.Scheduler = DispatchScheduler(),
                      clipboard: Clipboard = PasteboardClipboard(),
                      pasteInjectors: [PasteInjector]? = nil) throws -> PickerModel {
        let picker = try start(scheduler: scheduler, clipboard: clipboard, pasteInjectors: pasteInjectors)
        delegate.togglePicker()
        XCTAssertTrue(spin { self.controller.isActiveAndVisible })
        XCTAssertEqual(picker.state, .picker)
        XCTAssertTrue(spin { self.find("picker-query") != nil && self.find("wish-card") != nil })
        return picker
    }

    // MARK: - Thumbnail and fill

    func testThumbnailShowsLabelsWithoutRememberedValues() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, description: A wish word, default: Suggestion}
        ---
        Wish for {{word}} with {{clipboard}}.
        """.utf8), at: "wish.md")
        let clipboard = MacRepeatClipboard()
        let picker = try open(clipboard: clipboard)
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        let identity = try XCTUnwrap(picker.results.first?.identity)
        let values = try RootedFileStore(root: data)
        try values.createRoot()
        try ValuesStore(files: values).record(identity: identity, values: ["word": "remembered-unicorn-7"])

        picker.selectResult(at: 0)
        let panel = try currentPanel()
        XCTAssertEqual(clipboard.reads, 0)
        XCTAssertNil(find("fill-field-word"), "The thumbnail renders no editable controls")
        XCTAssertEqual(picker.selectedCard?.hasFields, true)
        // The thumbnail renders the template; remembered text is never read.
        XCTAssertEqual(presentation.preview, "Wish for {{word}} with {{clipboard}}.")
        XCTAssertNotNil(axElement(identifier: "wish-slip", in: panel))
        XCTAssertNotNil(axElement(text: "Word", in: panel), "The thumbnail must label the blank")
        XCTAssertFalse(axElements(under: panel).contains { axText($0).contains("remembered-unicorn-7") },
                       "The thumbnail must not surface remembered values")

        // The remembered value exists; only the fill view may show it.
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertEqual(fill.values["word"], "remembered-unicorn-7")
        XCTAssertEqual(fill.fields.first?.provenance, .remembered)
    }

    func testFillSlotsShowPrefillValuesWithProvenance() throws {
        try files.write(Data("""
        ---
        fields:
          recalled: {label: Recalled, default: Declared}
          fallback: {label: Fallback, default: Declared default}
          chosen: {type: choice, options: [Swift, Rust], default: Swift}
          free: {label: Free, optional: true}
        ---
        {{recalled}} / {{fallback}} / {{chosen}} / {{free}}
        """.utf8), at: "fill.md")
        let picker = try open()
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.reduceMotion = { false }
        let identity = try XCTUnwrap(picker.results.first?.identity)
        let values = try RootedFileStore(root: data)
        try values.createRoot()
        try ValuesStore(files: values).record(identity: identity, values: ["recalled": "Remembered text"])

        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { self.find("fill-field-free") != nil })
        XCTAssertEqual(fill.fields.map(\.name), ["recalled", "fallback", "chosen", "free"])
        XCTAssertEqual(fill.fields.map(\.value), ["Remembered text", "Declared default", "Swift", ""])
        XCTAssertEqual(fill.fields.map(\.provenance),
                       [.remembered, .defaultValue, .defaultValue, .defaultValue])
        XCTAssertEqual((find("fill-field-recalled") as? PickerTextField)?.stringValue, "Remembered text")
        XCTAssertEqual((find("fill-field-chosen") as? WishCardTumbler)?.choiceValue, "Swift")

        let recalled = try XCTUnwrap(find("fill-field-recalled") as? PickerTextField)
        recalled.stringValue = "Hand-typed value"
        recalled.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: recalled))
        XCTAssertEqual(fill.values["recalled"], "Hand-typed value")
        XCTAssertEqual(fill.fields[0].provenance, .typed)
        XCTAssertTrue(presentation.wetFields.contains("recalled"))
        pump(for: WishCardStyle.dry + 0.2)
        XCTAssertFalse(presentation.wetFields.contains("recalled"))

        // Drafts hold the whole card, so a reopened form is all draft provenance.
        picker.escape()
        XCTAssertEqual(picker.state, .picker)
        presentation.use(mode: .copyOnly)
        XCTAssertEqual(picker.fillModel?.fields.map(\.provenance), [.draft, .draft, .draft, .draft])
        XCTAssertEqual(picker.fillModel?.values["recalled"], "Hand-typed value")
    }

    func testTypingReflowsSlotAndUpdatesProof() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, default: A}
        ---
        Wish for {{word}}.
        """.utf8), at: "reflow.md")
        let picker = try open()
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { self.find("fill-field-word") != nil })
        let field = try XCTUnwrap(find("fill-field-word") as? PickerTextField)
        let panel = try currentPanel()
        XCTAssertTrue(spin { field.frame.width > 0 })

        // The slot hugs its contents: a longer value measures wider.
        XCTAssertLessThan(WishCardStyle.slotWidth(value: "A", label: "Word",
                                                  font: WishCardStyle.serif, lineWidth: 600),
                          WishCardStyle.slotWidth(value: "A much longer wish than before", label: "Word",
                                                  font: WishCardStyle.serif, lineWidth: 600))
        let before = field.frame.width
        field.stringValue = "A much longer wish than before"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(fill.values["word"], "A much longer wish than before")
        XCTAssertTrue(spin { field.frame.width > before }, "The slot must reflow around the longer value")
        XCTAssertEqual(presentation.preview, "Wish for A much longer wish than before.")

        presentation.toggleProof()
        XCTAssertTrue(presentation.proofShown)
        XCTAssertEqual(presentation.preview, "Wish for A much longer wish than before.")
        XCTAssertNotNil(axElement(identifier: "wish-proof", in: panel))
        presentation.toggleProof()
        XCTAssertFalse(presentation.proofShown)
    }

    func testTumblerArrowsRollValueWithoutOpeningMenu() throws {
        try files.write(Data("""
        ---
        fields:
          language: {type: choice, options: [Swift, Rust, Python], default: Swift}
        ---
        {{language}}
        """.utf8), at: "tumbler.md")
        let picker = try open()
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        let panel = try currentPanel()
        XCTAssertTrue(spin { self.find("fill-field-language") != nil })
        let tumbler = try XCTUnwrap(find("fill-field-language") as? WishCardTumbler)
        XCTAssertEqual(tumbler.options.map(\.value), ["Swift", "Rust", "Python"])
        XCTAssertEqual(tumbler.choiceValue, "Swift")
        XCTAssertFalse(tumbler.isMenuOpen)
        XCTAssertTrue(panel.makeFirstResponder(tumbler))

        try sendKey(code: UInt16(kVK_DownArrow), characters: "\u{f701}", to: panel)
        XCTAssertEqual(fill.values["language"], "Rust")
        XCTAssertEqual(tumbler.choiceValue, "Rust")
        try sendKey(code: UInt16(kVK_DownArrow), characters: "\u{f701}", to: panel)
        XCTAssertEqual(fill.values["language"], "Python")
        try sendKey(code: UInt16(kVK_DownArrow), characters: "\u{f701}", to: panel)
        XCTAssertEqual(fill.values["language"], "Python", "Down at the last option must not wrap")
        try sendKey(code: UInt16(kVK_UpArrow), characters: "\u{f700}", to: panel)
        XCTAssertEqual(fill.values["language"], "Rust")
        try sendKey(code: UInt16(kVK_UpArrow), characters: "\u{f700}", to: panel)
        XCTAssertEqual(fill.values["language"], "Swift")
        try sendKey(code: UInt16(kVK_UpArrow), characters: "\u{f700}", to: panel)
        XCTAssertEqual(fill.values["language"], "Swift", "Up at the first option must not wrap")
        XCTAssertEqual(fill.fields[0].provenance, .typed)

        // Letter keys jump to the matching option label; the menu never opens.
        try sendKey(code: UInt16(kVK_ANSI_P), characters: "p", to: panel)
        XCTAssertEqual(fill.values["language"], "Python")
        try sendKey(code: UInt16(kVK_ANSI_S), characters: "s", to: panel)
        XCTAssertEqual(fill.values["language"], "Swift")
        XCTAssertFalse(tumbler.isMenuOpen)
    }

    func testTabAndShiftTabRevealBlanksBelowFoldAndWrap() throws {
        let body = "{{first}}\n" + String(repeating: "Words on the paper.\n", count: 30) + "{{last}}"
        try files.write(Data(("---\nfields:\n  last: {type: choice, options: [One, Two]}\n---\n" + body).utf8), at: "scroll.md")
        let clipboard = MacRepeatClipboard()
        let picker = try open(clipboard: clipboard)
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { self.find("fill-field-last") != nil })
        let first = try XCTUnwrap(find("fill-field-first") as? PickerTextField)
        let last = try XCTUnwrap(find("fill-field-last") as? WishCardTumbler)
        let panel = try currentPanel()
        XCTAssertTrue(spin { self.isFocused(first, in: panel) && last.bounds.height > 0 })
        XCTAssertTrue(last.visibleRect.isEmpty, "The last blank begins below the fold: " + last.placementDescription())

        let steps: [(NSEvent.ModifierFlags, Int)] = [([], 1), (.shift, 0), (.shift, 1), ([], 0)]
        for (flags, position) in steps {
            try sendKey(code: UInt16(kVK_Tab), characters: "\t", modifiers: flags, to: panel)
            XCTAssertEqual(fill.focusIndex, position)
            let control: NSView = position == 0 ? first : last
            XCTAssertTrue(spin {
                let focused = position == 0 ? self.isFocused(first, in: panel) : panel.firstResponder === last
                return focused && control.visibleRect.contains(control.bounds.insetBy(dx: 1, dy: 1))
            }, "Tab traversal must reveal the focused blank: " + control.placementDescription())
        }
        XCTAssertTrue(clipboard.writes.isEmpty)
    }

    // MARK: - Nudge and pending builtins

    func testIncompleteReturnNudgesAndFocusesMissingBlank() throws {
        try files.write(Data("{{first}} and {{second}}".utf8), at: "blanks.md")
        let clipboard = MacRepeatClipboard()
        let picker = try open(clipboard: clipboard)
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        let panel = try currentPanel()
        XCTAssertTrue(spin { self.find("fill-field-second") != nil })
        XCTAssertFalse(fill.deliverEnabled)
        fill.focusField(at: 1)
        let second = try XCTUnwrap(find("fill-field-second") as? PickerTextField)
        XCTAssertTrue(spin { self.isFocused(second, in: panel) })
        let before = presentation.nudgeRevision

        try sendKey(code: UInt16(kVK_Return), characters: "\r", to: panel)

        XCTAssertEqual(presentation.nudgeIndex, 0)
        XCTAssertEqual(fill.focusIndex, 0, "The nudge must focus the missing blank")
        XCTAssertEqual(presentation.gloss, "Fill every required field before rendering.")
        XCTAssertTrue(spin {
            panel.contentView?.layoutSubtreeIfNeeded()
            return self.axElements(under: panel).contains {
                self.ax($0, Selector(("accessibilityIdentifier"))) == "wish-gloss"
                    && self.axText($0).contains("Fill every required field before rendering.")
            }
        }, "VoiceOver must read the nudge gloss")
        let first = try XCTUnwrap(find("fill-field-first") as? PickerTextField)
        XCTAssertTrue(spin { self.isFocused(first, in: panel) })
        XCTAssertFalse(presentation.take.holdsCard)
        XCTAssertFalse(presentation.take.isPlaying)
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertEqual(fill.state, .editing)
        XCTAssertEqual(picker.state, .fill)
        XCTAssertTrue(controller.isVisible)

        // The footer's Deliver button is the same blocked intent.
        presentation.perform(.deliver)
        XCTAssertEqual(presentation.nudgeRevision, before + 2)
        XCTAssertEqual(presentation.nudgeIndex, 0)
        XCTAssertTrue(clipboard.writes.isEmpty)
    }

    func testReturnWhileBuiltinsResolveDoesNothing() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, default: Granted}
        ---
        Wish granted: {{word}} — {{clipboard}}
        """.utf8), at: "pending.md")
        let clipboard = MacRepeatClipboard()
        clipboard.hold = true
        let picker = try open(clipboard: clipboard)
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        let panel = try currentPanel()
        XCTAssertTrue(spin { self.find("fill-field-word") is PickerTextField })
        let word = try XCTUnwrap(find("fill-field-word") as? PickerTextField)
        let stepper = WishCardStepper()
        _ = try attach(stepper)
        XCTAssertTrue(spin { self.isFocused(word, in: panel) })
        XCTAssertFalse(fill.builtinsResolved)

        let nudges = presentation.nudgeRevision
        try sendKey(code: UInt16(kVK_Return), characters: "\r", to: panel)

        XCTAssertFalse(presentation.take.holdsCard)
        XCTAssertFalse(presentation.take.isPlaying)
        XCTAssertEqual(presentation.nudgeRevision, nudges)
        XCTAssertNil(presentation.nudgeIndex)
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertEqual(fill.state, .editing)
        XCTAssertEqual(picker.state, .fill)

        clipboard.release("diff --git a/a b/a")
        XCTAssertTrue(spin { fill.builtinsResolved && fill.deliverEnabled })
        try sendKey(code: UInt16(kVK_Return), characters: "\r", to: panel)
        XCTAssertTrue(presentation.take.isPlaying)
        XCTAssertEqual(presentation.take.frameIndex, 0)
        presentation.cancelTake()
        XCTAssertFalse(presentation.take.holdsCard)
    }

    // MARK: - The take

    func testStageRedrawsFrozenCardAndPawForEachExposure() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, default: Granted}
        ---
        Wish granted: {{word}}.
        """.utf8), at: "granted.md")
        let clipboard = MacRepeatClipboard()
        let picker = try open(clipboard: clipboard)
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { fill.deliverEnabled && self.find("fill-field-word") != nil })
        let stepper = WishCardStepper()
        let take = try attach(stepper)
        let stage = try XCTUnwrap(take.stage as? WishCardTakeDrawing)
        presentation.use(mode: .copyOnly)
        XCTAssertTrue(take.isPlaying)

        // SwiftUI never updates the stage representable, so each exposure
        // must mark the stage dirty itself.
        for frame in 1...3 {
            stage.needsDisplay = false
            XCTAssertTrue(stepper.advance())
            XCTAssertEqual(take.frameIndex, frame)
            XCTAssertTrue(stage.needsDisplay, "Exposure \(frame) must redraw the stage")
        }

        let rep = try XCTUnwrap(stage.bitmapImageRepForCachingDisplay(in: stage.bounds))
        stage.cacheDisplay(in: stage.bounds, to: rep)
        let scale: CGFloat = CGFloat(rep.pixelsWide) / stage.bounds.width
        func rendered(_ point: NSPoint) -> NSColor? {
            rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
        }

        // The frozen card stays opaque left of the paw.
        let card = take.cardRect
        for point in [NSPoint(x: card.minX + 30, y: card.midY), NSPoint(x: card.minX + 30, y: card.minY + 40)] {
            let alpha: CGFloat = rendered(point)?.alphaComponent ?? 0
            XCTAssertGreaterThan(alpha, 0.9, "The frozen card must not be blank at \(point); card=\(card)")
        }

        // Opaque paw pixels land where PawTake places the anchor on the grip.
        let exposure = PawTake.frames[3]
        let paw = try XCTUnwrap(WishPawArt.image(exposure.image))
        let cgPaw = try XCTUnwrap(paw.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let art = NSBitmapImageRep(cgImage: cgPaw)
        let artScale: CGFloat = CGFloat(art.pixelsWide) / CGFloat(PawTake.imageSize.x)
        let gripX: CGFloat = card.minX + card.width * CGFloat(PawTake.gripFraction)
        let gripY: CGFloat = card.minY + CGFloat(PawTake.gripDepth)
        let originX: CGFloat = gripX + CGFloat(exposure.paw.x - PawTake.anchor.x)
        let originY: CGFloat = gripY + CGFloat(exposure.paw.y - PawTake.anchor.y)
        var samples = 0
        var matches = 0
        for y in stride(from: 0, to: art.pixelsHigh, by: 12) {
            for x in stride(from: 0, to: art.pixelsWide, by: 12) {
                guard let expected = art.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      expected.alphaComponent > 0.99 else { continue }
                let point = NSPoint(x: originX + CGFloat(x) / artScale, y: originY + CGFloat(y) / artScale)
                guard stage.bounds.insetBy(dx: 2, dy: 2).contains(point), let actual = rendered(point) else { continue }
                samples += 1
                let red: CGFloat = abs(actual.redComponent - expected.redComponent)
                let green: CGFloat = abs(actual.greenComponent - expected.greenComponent)
                let blue: CGFloat = abs(actual.blueComponent - expected.blueComponent)
                if max(red, green, blue) < 0.2 { matches += 1 }
            }
        }
        XCTAssertGreaterThan(samples, 20, "The paw must overlap the panel")
        XCTAssertGreaterThan(matches * 4, samples * 3, "The stage must draw the paw: \(matches)/\(samples) samples match")

        presentation.cancelTake()
        XCTAssertFalse(take.holdsCard)
        XCTAssertTrue(clipboard.writes.isEmpty)
    }

    func testReadyReturnPlaysNineExposuresThenDeliversCopyOnlyOnce() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, default: Granted}
        ---
        Wish granted: {{word}}.
        """.utf8), at: "granted.md")
        let clipboard = MacRepeatClipboard()
        let injector = MacRepeatInjector()
        let picker = try open(clipboard: clipboard, pasteInjectors: [injector])
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { fill.deliverEnabled && self.find("fill-field-word") != nil })
        let stepper = WishCardStepper()
        let take = try attach(stepper)
        var cues: [WishCardCue] = []
        take.playCue = { cues.append($0) }
        let panel = try currentPanel()
        let word = try XCTUnwrap(find("fill-field-word") as? PickerTextField)
        XCTAssertTrue(spin { self.isFocused(word, in: panel) })

        try sendKey(code: UInt16(kVK_Return), characters: "\r", to: panel)

        XCTAssertTrue(take.isPlaying)
        XCTAssertTrue(take.holdsCard)
        XCTAssertEqual(take.frameIndex, 0)
        XCTAssertEqual(stepper.queued, 1)
        XCTAssertEqual(fill.state, .editing)
        XCTAssertTrue(clipboard.writes.isEmpty)
        // The disabled footer cannot enqueue another take or deliver early.
        presentation.perform(.deliver)
        XCTAssertEqual(stepper.queued, 1)
        XCTAssertTrue(clipboard.writes.isEmpty)

        for frame in 1...8 {
            XCTAssertTrue(stepper.advance(), "Queued exposure \(frame) missing")
            XCTAssertEqual(take.frameIndex, frame)
            XCTAssertTrue(take.isPlaying)
            XCTAssertEqual(fill.state, .editing)
        }
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(stepper.advance(), "The last queued exposure must finish the take")
        XCTAssertFalse(take.isPlaying)
        XCTAssertEqual(stepper.queued, 0)
        XCTAssertEqual(cues, [.crack, .crack, .crack, .crack, .take])
        XCTAssertEqual(stepper.intervals, Array(repeating: PawTake.frameInterval, count: PawTake.frames.count))

        XCTAssertTrue(spin { clipboard.writes.count == 1 })
        XCTAssertEqual(clipboard.writes, ["Wish granted: Granted."])
        XCTAssertTrue(spin { picker.state == .done(.copiedOnly(.requested)) })
        XCTAssertTrue(spin { !self.controller.isVisible })
        XCTAssertFalse(take.holdsCard)
        XCTAssertNil(take.frameIndex)
        XCTAssertTrue(injector.chords.isEmpty)
    }

    func testCommandReturnOverridesCopyPreferredMode() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, default: Granted}
        ---
        Wish granted: {{word}}.
        """.utf8), at: "granted.md")
        let clipboard = MacRepeatClipboard()
        let injector = MacRepeatInjector()
        let picker = try open(clipboard: clipboard, pasteInjectors: [injector])
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertEqual(fill.preferredMode, .copyOnly)
        XCTAssertTrue(spin { fill.deliverEnabled && self.find("fill-field-word") != nil })
        let stepper = WishCardStepper()
        let take = try attach(stepper)
        let panel = try currentPanel()
        let word = try XCTUnwrap(find("fill-field-word") as? PickerTextField)
        XCTAssertTrue(spin { self.isFocused(word, in: panel) })

        try sendKey(code: UInt16(kVK_Return), characters: "\r", modifiers: .command, to: panel)
        XCTAssertTrue(take.isPlaying)

        for _ in PawTake.frames { XCTAssertTrue(stepper.advance()) }
        XCTAssertFalse(take.isPlaying)
        XCTAssertTrue(spin { picker.state == .done(.pasted(.cgEvent)) })
        XCTAssertEqual(injector.chords, [.standard])
        XCTAssertEqual(clipboard.writes, ["Wish granted: Granted."])
    }

    func testFieldlessReturnPlaysThumbnailTakeThenDeliversOnce() throws {
        try files.write(Data("May it be granted.".utf8), at: "plain.md")
        let clipboard = MacRepeatClipboard()
        let picker = try open(clipboard: clipboard, pasteInjectors: [])
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        XCTAssertEqual(picker.selectedCard?.hasFields, false)
        let stepper = WishCardStepper()
        let take = try attach(stepper)
        let panel = try currentPanel()

        try sendKey(code: UInt16(kVK_Return), characters: "\r", modifiers: .option, to: panel)
        XCTAssertTrue(take.isPlaying)
        XCTAssertEqual(take.frameIndex, 0)
        XCTAssertNil(picker.fillModel)

        for frame in 1...8 {
            XCTAssertTrue(stepper.advance())
            XCTAssertEqual(take.frameIndex, frame)
        }
        XCTAssertTrue(stepper.advance())
        XCTAssertFalse(take.isPlaying)
        XCTAssertTrue(spin { picker.state == .done(.copiedOnly(.requested)) })
        XCTAssertEqual(clipboard.writes, ["May it be granted."])
    }

    func testEscapeDuringTakeCancelsAndKeepsDraft() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, default: Granted}
        ---
        Wish granted: {{word}}.
        """.utf8), at: "granted.md")
        let clipboard = MacRepeatClipboard()
        let picker = try open(clipboard: clipboard)
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        fill.setValue("Draft wish", name: "word")
        let stepper = WishCardStepper()
        let take = try attach(stepper)
        let panel = try currentPanel()
        presentation.use(mode: .copyOnly)
        XCTAssertTrue(take.isPlaying)
        XCTAssertEqual(take.frameIndex, 0)

        try sendKey(code: UInt16(kVK_Escape), characters: "\u{1b}", to: panel)

        XCTAssertFalse(take.isPlaying)
        XCTAssertFalse(take.holdsCard)
        XCTAssertNil(take.frameIndex)
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertEqual(fill.state, .editing)
        XCTAssertEqual(picker.state, .fill)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(fill.values["word"], "Draft wish")

        // The revoked exposure stays queued but is inert.
        _ = stepper.advance()
        XCTAssertTrue(clipboard.writes.isEmpty)

        presentation.escape()
        XCTAssertEqual(picker.state, .picker)
        picker.use(mode: .copyOnly)
        XCTAssertEqual(picker.fillModel?.values["word"], "Draft wish")
    }

    func testSecondReturnDuringTakeSkipsToDelivery() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, default: Granted}
        ---
        Wish granted: {{word}}.
        """.utf8), at: "granted.md")
        let clipboard = MacRepeatClipboard()
        let picker = try open(clipboard: clipboard)
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { fill.deliverEnabled && self.find("fill-field-word") != nil })
        let stepper = WishCardStepper()
        let take = try attach(stepper)
        let panel = try currentPanel()
        presentation.use(mode: .copyOnly)
        XCTAssertTrue(take.isPlaying)

        try sendKey(code: UInt16(kVK_Return), characters: "\r", to: panel)

        XCTAssertFalse(take.isPlaying)
        XCTAssertTrue(spin { clipboard.writes.count == 1 })
        XCTAssertEqual(clipboard.writes, ["Wish granted: Granted."])
        // The exposure callbacks queued behind the early finish are inert.
        for _ in PawTake.frames { _ = stepper.advance() }
        XCTAssertEqual(stepper.queued, 0)
        XCTAssertEqual(clipboard.writes.count, 1)
        XCTAssertTrue(spin { picker.state == .done(.copiedOnly(.requested)) })
    }

    func testKeyRepeatAndPlainKeysAreSwallowedDuringTake() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, default: Granted}
        ---
        Wish granted: {{word}}.
        """.utf8), at: "granted.md")
        let clipboard = MacRepeatClipboard()
        let picker = try open(clipboard: clipboard)
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { fill.deliverEnabled && self.find("fill-field-word") != nil })
        let stepper = WishCardStepper()
        let take = try attach(stepper)
        let panel = try currentPanel()
        presentation.use(mode: .copyOnly)
        XCTAssertTrue(take.isPlaying)

        try sendKey(code: UInt16(kVK_Return), characters: "\r", isARepeat: true, to: panel)
        XCTAssertTrue(take.isPlaying, "A key repeat must not skip to delivery")
        XCTAssertEqual(take.frameIndex, 0)
        try sendKey(code: UInt16(kVK_ANSI_X), characters: "x", to: panel)
        XCTAssertTrue(take.isPlaying)
        XCTAssertEqual(fill.values["word"], "Granted")
        XCTAssertTrue(clipboard.writes.isEmpty)

        try sendKey(code: UInt16(kVK_Return), characters: "\r", to: panel)
        XCTAssertFalse(take.isPlaying)
        XCTAssertTrue(spin { clipboard.writes.count == 1 })
    }

    func testHidingPanelDuringTakeCancelsWithoutDelivering() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, default: Granted}
        ---
        Wish granted: {{word}}.
        """.utf8), at: "granted.md")
        let clipboard = MacRepeatClipboard()
        let picker = try open(clipboard: clipboard)
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { fill.deliverEnabled && self.find("fill-field-word") != nil })
        let stepper = WishCardStepper()
        let take = try attach(stepper)
        presentation.use(mode: .copyOnly)
        XCTAssertTrue(take.isPlaying)

        controller.hide()

        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(take.isPlaying)
        XCTAssertFalse(take.holdsCard)
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertEqual(fill.state, .editing)
        XCTAssertEqual(picker.state, .fill)
        for _ in PawTake.frames { _ = stepper.advance() }
        XCTAssertEqual(stepper.queued, 0)
        XCTAssertTrue(clipboard.writes.isEmpty)
    }

    func testBlurDuringTakeCancelsAndDismisses() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, default: Granted}
        ---
        Wish granted: {{word}}.
        """.utf8), at: "granted.md")
        let clipboard = MacRepeatClipboard()
        let picker = try open(clipboard: clipboard)
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { fill.deliverEnabled && self.find("fill-field-word") != nil })
        let stepper = WishCardStepper()
        let take = try attach(stepper)
        let panel = try currentPanel()
        presentation.use(mode: .copyOnly)
        XCTAssertTrue(take.isPlaying)

        panel.resignKey()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)

        XCTAssertFalse(take.isPlaying)
        XCTAssertFalse(take.holdsCard)
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(spin { picker.state == .closed })
        XCTAssertFalse(controller.isVisible)
    }

    func testReduceMotionDeliversImmediatelyWithoutTake() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, default: Granted}
        ---
        Wish granted: {{word}}.
        """.utf8), at: "granted.md")
        let clipboard = MacRepeatClipboard()
        let picker = try open(clipboard: clipboard)
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { fill.deliverEnabled && self.find("fill-field-word") != nil })
        let stepper = WishCardStepper()
        let take = try attach(stepper)
        presentation.reduceMotion = { true }

        presentation.use(mode: .copyOnly)

        XCTAssertFalse(take.isPlaying)
        XCTAssertFalse(take.holdsCard)
        XCTAssertNil(take.frameIndex)
        XCTAssertEqual(stepper.queued, 0)
        XCTAssertTrue(spin { clipboard.writes.count == 1 })
        XCTAssertEqual(clipboard.writes, ["Wish granted: Granted."])
        XCTAssertTrue(spin { picker.state == .done(.copiedOnly(.requested)) })
    }

    // MARK: - Slip and Proof

    func testClipboardSlipShowsSummaryTagAndEmptyState() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, default: Granted}
        ---
        {{word}} — {{clipboard}}
        """.utf8), at: "slip.md")
        let clipboard = MacRepeatClipboard()
        clipboard.hold = true
        let picker = try open(clipboard: clipboard)
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        let panel = try currentPanel()
        _ = try XCTUnwrap(axElement(identifier: "wish-slip", in: panel),
                                 "The card must render the clipboard slip")
        XCTAssertNil(fill.clipboardSummary, "The slip reads pending until the snapshot arrives")

        clipboard.release("diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1 +1 @@\n-old\n+new")
        XCTAssertTrue(spin { fill.clipboardSummary?.kind == .diff })
        let summary = try XCTUnwrap(fill.clipboardSummary)
        XCTAssertEqual(summary.lineCount, 6)
        XCTAssertEqual(WishCardSlip.caption(summary), "CLIPBOARD · 6 LINES · DIFF")
        XCTAssertTrue(spin {
            guard let slip = self.axElement(identifier: "wish-slip", in: panel) else { return false }
            return (self.axText(slip) + self.axElements(in: slip).map { self.axText($0) }.joined(separator: " ")).contains("CLIPBOARD")
        }, "The slip must show the summary tag")
        let projection = presentation.clipboardSlip
        presentation.setValue("Changed", field: fill.fields[0])
        XCTAssertTrue(presentation.clipboardSlip === projection, "Typing reuses the resolved clipboard projection")
        XCTAssertEqual(WishCardSlip.displayable("\tline\u{0000}\r"), "    line")

        picker.escape()
        clipboard.text = ""
        presentation.use(mode: .copyOnly)
        XCTAssertTrue(spin { picker.fillModel?.clipboardSummary?.kind == .empty })
        XCTAssertTrue(spin {
            guard let empty = self.axElement(identifier: "wish-slip", in: panel) else { return false }
            return (self.axText(empty) + self.axElements(in: empty).map { self.axText($0) }.joined(separator: " ")).contains("empty")
        }, "The slip must show its explicit empty state")
    }

    func testCommandPTogglesExactProofInPickerAndFill() throws {
        try files.write(Data("""
        ---
        fields:
          word: {label: Word, default: Granted}
        ---
        Wish for {{word}}.
        """.utf8), at: "proof.md")
        let picker = try open()
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        let panel = try currentPanel()

        try sendKey(code: UInt16(kVK_ANSI_P), characters: "p", modifiers: .command, to: panel)
        XCTAssertTrue(presentation.proofShown)
        // The thumbnail Proof renders defaults, as the picker preview always has.
        XCTAssertEqual(presentation.preview, "Wish for Granted.")
        XCTAssertNotNil(axElement(identifier: "wish-proof", in: panel))
        try sendKey(code: UInt16(kVK_ANSI_P), characters: "p", modifiers: .command, to: panel)
        XCTAssertFalse(presentation.proofShown)

        presentation.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { fill.builtinsResolved })
        try sendKey(code: UInt16(kVK_ANSI_P), characters: "p", modifiers: .command, to: panel)
        XCTAssertTrue(presentation.proofShown)
        XCTAssertEqual(presentation.preview, "Wish for Granted.")
        XCTAssertNotNil(axElement(identifier: "wish-proof", in: panel))
        presentation.escape()
        XCTAssertFalse(presentation.proofShown)
        XCTAssertEqual(picker.state, .fill, "Escape dismisses Proof before leaving the card")
    }

    func testWordBoundaryFeedbackUsesTheCurrentModelValue() throws {
        try files.write(Data("{{word}}".utf8), at: "feedback.md")
        let picker = try open()
        picker.use(mode: .copyOnly)
        let fill = try XCTUnwrap(picker.fillModel)
        XCTAssertTrue(spin { fill.builtinsResolved })
        var cues: [WishCardCue] = []
        let feedback = PickerViewState(model: picker, mainThread: DispatchMainThread(),
            reduceMotion: { true }, playCue: { cues.append($0) }, requestedIntent: { _ in }, createPrompt: { _ in })
        let priorRender = fill.fields[0]
        // Model updates synchronously; a native editor may still retain the
        // same field snapshot for several edits in one SwiftUI update cycle.
        feedback.setValue("One", field: priorRender)
        feedback.setValue("One more", field: priorRender)
        feedback.setValue("One more!", field: priorRender)
        XCTAssertEqual(cues.filter { $0 == .tick }.count, 2)
        XCTAssertEqual(fill.values["word"], "One more!")
    }

    func testSoundPreferenceGateDefaultsOnAndHonorsBothDomains() {
        XCTAssertTrue(WishCardSounds.preferenceEnabled(system: nil, global: nil))
        XCTAssertFalse(WishCardSounds.preferenceEnabled(system: NSNumber(value: false), global: nil))
        XCTAssertFalse(WishCardSounds.preferenceEnabled(system: nil, global: NSNumber(value: false)))
        XCTAssertTrue(WishCardSounds.preferenceEnabled(system: NSNumber(value: true), global: NSNumber(value: false)))
    }

    // MARK: - Art

    func testAllNinePawImagesExistInAppBundle() throws {
        XCTAssertEqual(PawTake.imageCount, 9)
        XCTAssertEqual(PawTake.frames.count, PawTake.imageCount)
        for (index, frame) in PawTake.frames.enumerated() {
            XCTAssertTrue((0..<PawTake.imageCount).contains(frame.image), "Frame \(index) has no image slot")
        }
        var missing: [String] = []
        for index in 0..<PawTake.imageCount {
            let name = PawTake.imageName(index)
            if WishPawArt.image(index) == nil { missing.append(name) }
        }
        XCTAssertTrue(missing.isEmpty, "Missing paw art in the app bundle: \(missing.joined(separator: ", "))")
    }

    // MARK: - Take helpers

    /// Attaches the stepper and waits for the real card surface and stage.
    @discardableResult
    private func attach(_ stepper: WishCardStepper) throws -> WishCardTake {
        let presentation = try XCTUnwrap(delegate.pickerPresentation)
        let take = presentation.take
        take.scheduler = stepper
        XCTAssertTrue(spin {
            let controlsReady = presentation.model.fillModel?.fields.allSatisfy {
                self.find("fill-field-" + $0.name) != nil
            } ?? true
            return controlsReady && take.surface != nil && take.stage != nil && take.surface?.window != nil
                && (take.surface?.bounds.width ?? 0) > 0 && (take.surface?.bounds.height ?? 0) > 0
        }, "The card surface and take stage must be laid out")
        return take
    }

    // MARK: - Panel helpers

    private func currentPanel() throws -> PromptPanel {
        try XCTUnwrap(NSApp.windows.compactMap { $0 as? PromptPanel }.first {
            !originalWindows.contains(ObjectIdentifier($0))
        })
    }

    private func isFocused(_ field: NSTextField, in panel: NSWindow) -> Bool {
        guard let editor = field.currentEditor() else { return false }
        return panel.firstResponder === editor
    }

    private func find(_ identifier: String) -> NSView? {
        func walk(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            for child in view.subviews { if let found = walk(child) { return found } }
            return nil
        }
        return (try? currentPanel()).flatMap { $0.contentView }.flatMap(walk)
    }

    /// In-process NSAccessibility reads reach SwiftUI-only elements like the
    /// gloss and slip that have no NSView identifier. Same reads as the tour.
    private func axElements(in root: NSObject, depth: Int = 16) -> [NSObject] {
        let children = #selector(NSAccessibilityProtocol.accessibilityChildren)
        guard depth > 0, root.responds(to: children),
              let descendants = root.perform(children)?.takeUnretainedValue() as? [Any] else { return [] }
        return descendants.flatMap { descendant -> [NSObject] in
            guard let node = descendant as? NSObject else { return [] }
            return [node] + axElements(in: node, depth: depth - 1)
        }
    }

    private func axElements(under window: NSWindow) -> [NSObject] {
        let elements = axElements(in: window)
        guard let content = window.contentView else { return elements }
        return elements + axElements(in: content)
    }

    private func ax(_ element: NSObject, _ selector: Selector) -> String? {
        guard element.responds(to: selector),
              let value = element.perform(selector)?.takeUnretainedValue() else { return nil }
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let string = value as? NSAttributedString { return string.string.isEmpty ? nil : string.string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func axText(_ element: NSObject) -> String {
        [#selector(NSAccessibilityProtocol.accessibilityLabel),
         #selector(NSAccessibilityProtocol.accessibilityTitle),
         Selector(("accessibilityValue")),
         Selector(("accessibilityHelp"))]
            .compactMap { ax(element, $0) }
            .joined(separator: " ")
    }

    private func axElement(identifier: String, in window: NSWindow) -> NSObject? {
        var result: NSObject?
        _ = spin {
            window.contentView?.layoutSubtreeIfNeeded()
            result = self.axElements(under: window).first { self.ax($0, Selector(("accessibilityIdentifier"))) == identifier }
            return result != nil
        }
        return result
    }

    /// SwiftUI static text reports its label as AXValue, not AXDescription,
    /// and may keep the drawn capitals; either spelling names the element.
    private func axElement(text: String, in window: NSWindow) -> NSObject? {
        let selectors = [#selector(NSAccessibilityProtocol.accessibilityLabel),
                         #selector(NSAccessibilityProtocol.accessibilityTitle),
                         Selector(("accessibilityValue"))]
        var result: NSObject?
        _ = spin {
            window.contentView?.layoutSubtreeIfNeeded()
            result = self.axElements(under: window).first { element in
                selectors.contains { self.ax(element, $0)?.caseInsensitiveCompare(text) == .orderedSame }
            }
            return result != nil
        }
        return result
    }

    private func spin(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        spin(until: ProcessInfo.processInfo.systemUptime + timeout, condition)
    }

    private func spin(until deadline: TimeInterval, _ condition: () -> Bool) -> Bool {
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return false
    }

    private func pump(for duration: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        _ = spin(until: deadline) { ProcessInfo.processInfo.systemUptime >= deadline }
    }

    private func sendKey(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [],
                         isARepeat: Bool = false, to panel: PromptPanel) throws {
        NSApp.sendEvent(try keyEvent(code: code, characters: characters, modifiers: modifiers,
                                     isARepeat: isARepeat, to: panel))
    }

    private func keyEvent(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags,
                          isARepeat: Bool = false, to panel: PromptPanel) throws -> NSEvent {
        if !panel.isKeyWindow { panel.makeKey() }
        let becameKey = spin { panel.isKeyWindow }
        _ = try XCTUnwrap(becameKey ? panel : nil, "Picker panel could not become key before a test key event")
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: isARepeat,
            keyCode: code))
    }
}
