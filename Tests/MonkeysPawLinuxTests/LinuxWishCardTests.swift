#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxWishCardTests: XCTestCase {
    private var application: UnsafeMutablePointer<GtkApplication>!
    private var tools: FakeLinuxTools!
    private var notifications: FakePortal!
    private var environment: LinuxEnvironment!
    private var files: RootedFileStore!
    private var animations: gboolean = 0

    override func setUpWithError() throws {
        let address = try FakePortal.requirePrivateBus()
        application = try GTKTestSupport.application()
        animations = mp_settings_boolean("gtk-enable-animations")
        mp_test_set_animations(1)
        tools = try FakeLinuxTools()
        tools.environment["HOME"] = tools.directory.path
        tools.environment["XDG_DATA_HOME"] = tools.directory.appendingPathComponent("data").path
        tools.environment["XDG_CONFIG_HOME"] = tools.directory.appendingPathComponent("config").path
        tools.environment["XDG_SESSION_TYPE"] = "wayland"
        files = try RootedFileStore(root: LinuxPaths(environment: tools.environment).documentsDirectory.appendingPathComponent("MonkeysPaw"))
        notifications = try FakePortal(address: address)
        try notifications.ownNotifications()
        environment = LinuxEnvironment(application: application, environment: tools.environment)
    }

    override func tearDown() {
        environment?.shutdown()
        environment = nil
        if let application { GTKTestSupport.destroy(application) }
        application = nil
        notifications?.shutdown()
        notifications = nil
        if gtk_settings_get_default() != nil { mp_test_set_animations(animations) }
        files = nil
        tools = nil
    }

    func testTumblerArrowsDoNotWrapAndInitialLetterJumps() throws {
        let fill = try openFill("""
        ---
        fields:
          language:
            type: choice
            options: [Swift, Rust, Python]
            default: Swift
        ---
        Write {{language}}.
        """)
        let control = try widget("fill-field-language")
        gtk_widget_grab_focus(control)
        XCTAssertTrue(key(GDK_KEY_Up))
        XCTAssertEqual(fill.values["language"], "Swift")
        XCTAssertTrue(key(GDK_KEY_Down))
        XCTAssertEqual(fill.values["language"], "Rust")
        XCTAssertEqual(try choiceValue(), "Rust")
        XCTAssertTrue(key(GDK_KEY_Down))
        XCTAssertTrue(key(GDK_KEY_Down))
        XCTAssertEqual(fill.values["language"], "Python")
        XCTAssertTrue(key(GDK_KEY_s))
        XCTAssertEqual(fill.values["language"], "Swift")
        assertAccessible(control, "language: Swift")
    }

    func testTumblerPopoverSelectsOptionWithoutDelivering() throws {
        let fill = try openFill("---\nfields:\n  language: {type: choice, options: [Swift, Rust], default: Swift}\n---\n{{language}}")
        gtk_widget_grab_focus(try widget("fill-field-language"))
        XCTAssertTrue(key(GDK_KEY_space))
        let option = try widget("fill-option-language-Rust")
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_mapped(option) != 0 })
        XCTAssertNotEqual(GTKTestSupport.activate(option), 0)
        XCTAssertTrue(GTKTestSupport.spin { fill.values["language"] == "Rust" })
        XCTAssertEqual(fill.state, .editing)
        XCTAssertEqual(gtk_widget_get_visible(try widget("fill-choices-language")), 0)
        XCTAssertEqual(try choiceValue(), "Rust")
    }

    func testTextWidthHugsContentAndStopsAtTheCardEdge() throws {
        _ = try openFill("---\nfields:\n  word: {label: Word}\n---\n{{word}}")
        let entry = try widget("fill-field-word")
        let scroll = try widget("card-scroll")
        func requested() -> Int32 {
            var width: Int32 = 0
            gtk_widget_get_size_request(entry, &width, nil)
            return width
        }
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_width(scroll) > 0 })
        let empty = requested()
        XCTAssertGreaterThan(empty, 0)
        mp_entry_set_text(entry, "Quantities multiply into the total")
        XCTAssertGreaterThan(requested(), empty)
        let sentence = requested()
        mp_entry_set_text(entry, "Quantities")
        XCTAssertLessThan(requested(), sentence)
        mp_entry_set_text(entry, String(repeating: "界", count: 80))
        XCTAssertLessThanOrEqual(requested(), gtk_widget_get_width(scroll))
        mp_entry_set_text(entry, "")
        XCTAssertEqual(requested(), empty)
    }

    func testInkMatchesDefaultTypedDraftAndRememberedProvenance() throws {
        let source = "---\nfields:\n  word: {default: Suggestion}\n---\n{{word}} / {{word}}"
        let fill = try openFill(source)
        let entry = try widget("fill-field-word")
        XCTAssertEqual(gtk_widget_has_css_class(entry, "mp-ink-default"), 1)
        mp_entry_set_text(entry, "Written")
        XCTAssertEqual(fill.fields[0].provenance, .typed)
        XCTAssertEqual(gtk_widget_has_css_class(entry, "mp-ink-typed"), 1)
        XCTAssertEqual(gtk_widget_has_css_class(entry, "mp-ink-wet"), 1)
        XCTAssertEqual(gtk_widget_has_css_class(entry, "mp-ink-pending"), 0)
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_has_css_class(entry, "mp-ink-wet") == 0 })
        XCTAssertTrue(key(GDK_KEY_Escape))
        XCTAssertTrue(key(GDK_KEY_Return))
        let draft = try widget("fill-field-word")
        XCTAssertEqual(gtk_widget_has_css_class(draft, "mp-ink-draft"), 1)
        environment.pickerModel.forgetSelectedValues()
        XCTAssertEqual(gtk_widget_has_css_class(draft, "mp-ink-default"), 1)
        environment.pickerModel.dismiss()
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })
        let identity = try XCTUnwrap(environment.pickerModel.results.first?.identity)
        let data = try RootedFileStore(root: LinuxPaths(environment: tools.environment).dataDirectory)
        try ValuesStore(files: data).record(identity: identity, values: ["word": "Remembered"])
        try open()
        environment.pickerModel.use(mode: .copyOnly)
        XCTAssertEqual(gtk_widget_has_css_class(try widget("fill-field-word"), "mp-ink-remembered"), 1)
    }

    func testMissingReturnFocusesFirstRequiredBlankAndDoesNotDeliver() throws {
        let fill = try openFill("{{first}} and {{second}}")
        let second = try widget("fill-field-second")
        gtk_widget_grab_focus(second)
        XCTAssertEqual(fill.focusIndex, 1)
        XCTAssertTrue(key(GDK_KEY_Return))
        XCTAssertEqual(fill.focusIndex, 0)
        let first = try widget("fill-field-first")
        XCTAssertTrue(focused(first))
        XCTAssertEqual(gtk_widget_has_css_class(first, "mp-nudge"), 1)
        XCTAssertEqual(fill.state, .editing)
        XCTAssertTrue(environment.panel.isVisible)
        XCTAssertEqual(notifications.notificationCount, 0)
        XCTAssertNotEqual(GTKTestSupport.activate(try widget("picker-use")), 0)
        XCTAssertTrue(GTKTestSupport.spin { focused(first) })
        XCTAssertEqual(fill.state, .editing)
    }

    func testTakeDelaysAndDeliversExactlyOnce() throws {
        let fill = try openFill("---\nfields:\n  word: {default: Wish}\n---\n{{word}}")
        XCTAssertTrue(GTKTestSupport.spin { fill.deliverEnabled })
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(key(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        XCTAssertEqual(fill.state, .editing)
        XCTAssertTrue(environment.panel.isVisible)
        XCTAssertTrue(key(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.copiedOnly(.requested)) })
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, WishCardMotion.take * 0.9)
        XCTAssertTrue(GTKTestSupport.spin { self.notifications.notificationCount == 1 })
        XCTAssertEqual(try usageCount(), 1)
    }

    func testDismissDuringTakeCancelsWithoutDeliveringOrLearning() throws {
        let fill = try openFill("---\nfields:\n  word: {default: Wish}\n---\n{{word}}")
        XCTAssertTrue(GTKTestSupport.spin { fill.deliverEnabled })
        XCTAssertTrue(key(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        environment.pickerModel.dismiss()
        try waitPastTake()
        XCTAssertEqual(environment.pickerModel.state, .closed)
        XCTAssertEqual(notifications.notificationCount, 0)
        XCTAssertEqual(try usageCount(), 0)
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })
    }

    func testFieldlessThumbnailTakesAndCanBeCancelled() throws {
        try files.write(Data("A wish without blanks".utf8), at: "wish.md")
        try open()
        XCTAssertTrue(key(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        XCTAssertEqual(environment.pickerModel.state, .picker)
        environment.pickerModel.dismiss()
        try waitPastTake()
        XCTAssertEqual(notifications.notificationCount, 0)
        XCTAssertEqual(try usageCount(), 0)
        XCTAssertTrue(GTKTestSupport.spin { !self.environment.panel.isVisible })
        try open()
        XCTAssertTrue(key(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.copiedOnly(.requested)) })
        XCTAssertEqual(try usageCount(), 1)
    }

    func testDestroyedPanelCancelsPendingTake() throws {
        let fill = try openFill("---\nfields:\n  word: {default: Wish}\n---\n{{word}}")
        XCTAssertTrue(GTKTestSupport.spin { fill.deliverEnabled })
        XCTAssertTrue(key(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        gtk_window_destroy(mp_window(environment.panel.clipboardOwner))
        try waitPastTake()
        XCTAssertEqual(fill.state, .editing)
        XCTAssertEqual(notifications.notificationCount, 0)
        XCTAssertEqual(try usageCount(), 0)
    }

    func testReopeningDuringTakeCancelsAndRestoresInput() throws {
        let fill = try openFill("---\nfields:\n  word: {default: Wish}\n---\n{{word}}")
        XCTAssertTrue(GTKTestSupport.spin { fill.deliverEnabled })
        XCTAssertTrue(key(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        environment.pickerModel.open()
        try waitPastTake()
        XCTAssertEqual(environment.pickerModel.state, .picker)
        XCTAssertEqual(notifications.notificationCount, 0)
        XCTAssertEqual(try usageCount(), 0)
        XCTAssertNotEqual(gtk_widget_get_sensitive(try widget("picker-query")), 0)
        XCTAssertTrue(key(GDK_KEY_Return))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.fillModel?.deliverEnabled == true })
        XCTAssertTrue(focused(try widget("fill-field-word")))
    }

    func testBlockedPreviewDuringTakeRestoresCardWithoutDelivery() throws {
        let fill = try openFill("---\nfields:\n  word: {default: Wish}\n---\n{{word}}")
        XCTAssertTrue(key(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        fill.setValue("", name: "word")
        try waitPastTake()
        XCTAssertEqual(fill.state, .editing)
        XCTAssertEqual(notifications.notificationCount, 0)
        XCTAssertEqual(gtk_widget_has_css_class(try widget("wish-card"), "mp-taken"), 0)
        XCTAssertNotEqual(gtk_widget_get_sensitive(try widget("picker-use")), 0)
        XCTAssertTrue(focused(try widget("fill-field-word")))
        XCTAssertTrue(key(GDK_KEY_Return))
    }

    func testChangedSelectionDuringTakeRestoresQueryFocus() throws {
        try files.write(Data("Alpha wish".utf8), at: "a.md")
        try files.write(Data("Beta wish".utf8), at: "b.md")
        try open()
        XCTAssertTrue(key(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        environment.pickerModel.selectResult(at: 1)
        XCTAssertTrue(focused(try widget("picker-query")))
        try waitPastTake()
        XCTAssertEqual(environment.pickerModel.state, .picker)
        XCTAssertEqual(notifications.notificationCount, 0)
        XCTAssertEqual(try usageCount(), 0)
    }

    func testReturnWhileFieldlessClipboardResolvesDoesNotTakeAgain() throws {
        let clipboard = WishDeferredClipboard()
        environment.shutdown()
        environment = LinuxEnvironment(application: application, environment: tools.environment, clipboard: clipboard)
        try files.write(Data("{{clipboard}}".utf8), at: "wish.md")
        try open()
        XCTAssertTrue(key(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.isResolvingBuiltins })
        XCTAssertTrue(GTKTestSupport.spin { clipboard.reads == 1 })
        // The taken card stays away while delivery waits for the clipboard.
        XCTAssertEqual(gtk_widget_has_css_class(try widget("wish-card"), "mp-taken"), 1)
        XCTAssertTrue(key(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        try waitPastTake()
        XCTAssertEqual(clipboard.reads, 1)
        XCTAssertEqual(gtk_widget_has_css_class(try widget("wish-card"), "mp-taken"), 1)
        clipboard.resolve("Resolved wish")
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.copiedOnly(.requested)) })
        XCTAssertEqual(clipboard.writes, ["Resolved wish"])
        XCTAssertEqual(try usageCount(), 1)
    }

    func testAccessibleLabelComparisonTreatsPercentAsLiteral() throws {
        _ = try openFill("---\nfields:\n  word: {label: 100% ready}\n---\n{{word}}")
        assertAccessible(try widget("fill-field-word"), "100% ready")
    }

    func testProofTogglesInBothStatesAndKeepsExactText() throws {
        try files.write(Data("---\nfields:\n  word: {default: Wish}\n---\n\\{{literal}} {{word}} {{date}}".utf8), at: "wish.md")
        try open()
        let preview = try widget("picker-preview")
        XCTAssertEqual(text(preview), "\\{{literal}} {{word}} {{date}}")
        XCTAssertTrue(key(GDK_KEY_p, modifiers: GDK_CONTROL_MASK))
        XCTAssertEqual(try proofPage(), "proof")
        XCTAssertTrue(key(GDK_KEY_P, modifiers: GDK_CONTROL_MASK))
        XCTAssertEqual(try proofPage(), "card")
        XCTAssertTrue(key(GDK_KEY_Return))
        let fill = try XCTUnwrap(environment.pickerModel.fillModel)
        XCTAssertTrue(GTKTestSupport.spin { fill.deliverEnabled })
        XCTAssertTrue(key(GDK_KEY_p, modifiers: GDK_CONTROL_MASK))
        if case .rendered(let rendered) = fill.preview { XCTAssertEqual(text(preview), rendered) }
        else { XCTFail("Expected rendered proof") }
        fill.setValue("", name: "word")
        if case .blocked(let error, let issues) = fill.preview {
            XCTAssertEqual(text(preview), ([error.description] + issues.map(\.message)).joined(separator: "\n"))
        } else { XCTFail("Expected blocked proof") }
    }

    func testClipboardSlipAccessibleLabelUsesResolvedSummary() throws {
        try files.write(Data("{{word}}\n{{clipboard}}".utf8), at: "wish.md")
        try open()
        assertAccessible(try widget("card-clipboard-slip"), LinuxClipboardSlip.thumbnailMessage)
        GTKClipboard(owner: environment.panel.clipboardOwner).writeText("diff --git a/a b/a\n--- a/a\n+++ b/a\n-old\n+new")
        XCTAssertTrue(key(GDK_KEY_Return))
        let fill = try XCTUnwrap(environment.pickerModel.fillModel)
        XCTAssertTrue(GTKTestSupport.spin { fill.builtinsResolved })
        XCTAssertEqual(fill.clipboardSummary?.lineCount, 5)
        XCTAssertEqual(fill.clipboardSummary?.kind, .diff)
        assertAccessible(try widget("card-clipboard-slip"), "Clipboard, 5 lines, diff")
    }

    func testAnimationsDisabledStartsDeliveryImmediately() throws {
        mp_test_set_animations(0)
        let fill = try openFill("---\nfields:\n  word: {default: Wish}\n---\n{{word}}")
        XCTAssertTrue(GTKTestSupport.spin { fill.deliverEnabled })
        XCTAssertTrue(key(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        XCTAssertEqual(fill.state, .delivering)
        XCTAssertTrue(GTKTestSupport.spin { self.environment.pickerModel.state == .done(.copiedOnly(.requested)) })
        XCTAssertEqual(try usageCount(), 1)
    }

    func testCardAnchorsHaveVisibleAllocations() throws {
        GTKClipboard(owner: environment.panel.clipboardOwner).writeText("diff --git a/wish.swift b/wish.swift\n--- a/wish.swift\n+++ b/wish.swift\n@@ -1 +1 @@\n-oldWish()\n+newWish()\n context")
        let fill = try openFill("""
        ---
        title: Review a diff
        fields:
          language: {type: choice, options: [Swift, Rust, Python], default: Swift}
          focus: {label: Review focus, default: correctness}
          notes: {type: multiline, label: Extra context, optional: true}
        ---
        You are a senior {{language}} engineer. Review this change for {{focus}}.

        <diff>
        {{clipboard}}
        </diff>
        {{notes}}
        Today is {{date}}. Report {{focus}} issues first.
        """)
        XCTAssertTrue(GTKTestSupport.spin { fill.builtinsResolved })
        let entry = try widget("fill-field-focus")
        let choice = try widget("fill-field-language")
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_width(entry) > 0 && gtk_widget_get_width(choice) > 0 })
        XCTAssertGreaterThan(gtk_widget_get_height(try widget("card-body")), 26)
        XCTAssertGreaterThan(gtk_widget_get_width(try widget("card-clipboard-slip")), 100)
        if let path = ProcessInfo.processInfo.environment["MONKEYSPAW_WISH_CARD_SCREENSHOT"] {
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            XCTAssertTrue(GTKTestSupport.spin { ProcessInfo.processInfo.systemUptime >= deadline })
            let window = environment.panel.clipboardOwner
            let paintable = gtk_widget_paintable_new(window)!
            let snapshot = gtk_snapshot_new()!
            gdk_paintable_snapshot(paintable, snapshot, Double(gtk_widget_get_width(window)), Double(gtk_widget_get_height(window)))
            let node = try XCTUnwrap(gtk_snapshot_free_to_node(snapshot))
            let renderer = try XCTUnwrap(gtk_native_get_renderer(gtk_widget_get_native(window)))
            let texture = try XCTUnwrap(gsk_renderer_render_texture(renderer, node, nil))
            XCTAssertNotEqual(gdk_texture_save_to_png(texture, path), 0)
            g_object_unref(UnsafeMutableRawPointer(texture))
            gsk_render_node_unref(node)
            g_object_unref(UnsafeMutableRawPointer(paintable))
        }
    }

    func testFullWidthSlotsKeepThePanelAtItsSize() throws {
        let source = """
        ---
        fields:
          context: {type: multiline, optional: true}
        ---
        Review this change.

        <diff>
        {{clipboard}}
        </diff>

        <context>
        {{context}}
        </context>

        """ + (1...30).map { "Instruction \($0): trace each changed path through its callers." }.joined(separator: "\n")
        try files.write(Data(source.utf8), at: "wish.md")
        try open()
        let window = environment.panel.clipboardOwner
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_width(window) > 0 })
        let pickerWidth = gtk_widget_get_width(window)
        let wide = (1...12).map { "+    let line\($0) = items.reduce(0) { partial, item in partial + item.price * Decimal(item.quantity) }" }
        mp_clipboard_set_text(window, (["diff --git a/Sources/Shop/Cart.swift b/Sources/Shop/Cart.swift"] + wide).joined(separator: "\n"))
        XCTAssertTrue(key(GDK_KEY_Return))
        let fill = try XCTUnwrap(environment.pickerModel.fillModel)
        XCTAssertTrue(GTKTestSupport.spin { fill.clipboardSummary?.kind == .diff })
        // Slips size themselves from the card's measured width over several
        // frames. Their requests must never raise the card's own minimum,
        // or a window manager grows the panel frame by frame.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        XCTAssertTrue(GTKTestSupport.spin { ProcessInfo.processInfo.systemUptime >= deadline })
        let card = try widget("wish-card")
        var minimum: Int32 = 0
        gtk_widget_measure(card, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, nil, nil, nil)
        XCTAssertLessThanOrEqual(minimum, gtk_widget_get_width(card))
        XCTAssertEqual(gtk_widget_get_width(window), pickerWidth)
    }

    func testTabRevealsABlankBelowTheFold() throws {
        let lines = (1...40).map { "Line \($0) of the instructions." }.joined(separator: "\n")
        let fill = try openFill("---\nfields:\n  first: {default: A}\n  last: {default: B}\n---\n{{first}}\n\(lines)\n{{last}}")
        let last = try widget("fill-field-last")
        let scroll = try widget("card-scroll")
        func visible(_ widget: GTK.Widget) -> Bool {
            var bounds = graphene_rect_t()
            guard gtk_widget_compute_bounds(widget, scroll, &bounds) != 0 else { return false }
            return bounds.origin.y >= 0 && bounds.origin.y + bounds.size.height <= Float(gtk_widget_get_height(scroll))
        }
        XCTAssertTrue(key(GDK_KEY_Tab))
        XCTAssertTrue(GTKTestSupport.spin { fill.focusIndex == 1 && self.focused(last) })
        XCTAssertTrue(GTKTestSupport.spin { visible(last) })
        // Back up from a scrolled position: the card scrolls to its top again.
        let adjustment = try XCTUnwrap(gtk_scrolled_window_get_vadjustment(mp_scrolled_window(scroll)))
        XCTAssertGreaterThan(gtk_adjustment_get_value(adjustment), 0)
        let first = try widget("fill-field-first")
        XCTAssertTrue(key(GDK_KEY_ISO_Left_Tab, modifiers: GDK_SHIFT_MASK))
        XCTAssertTrue(GTKTestSupport.spin { fill.focusIndex == 0 && self.focused(first) })
        XCTAssertTrue(GTKTestSupport.spin { gtk_adjustment_get_value(adjustment) == 0 })
    }

    func testTakeHidesTheLiveCardWhileThePawCarriesItsImage() throws {
        let fill = try openFill("---\nfields:\n  word: {default: Wish}\n---\n{{word}}")
        XCTAssertTrue(key(GDK_KEY_Return, modifiers: GDK_ALT_MASK))
        let card = try widget("wish-card")
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_has_css_class(card, "mp-taken") != 0 })
        XCTAssertEqual(fill.state, .editing)
        XCTAssertTrue(GTKTestSupport.spin { fill.state != .editing })
    }

    func testReturnWhileTheClipboardResolvesDoesNotNudge() throws {
        let clipboard = WishDeferredClipboard()
        environment.shutdown()
        environment = LinuxEnvironment(application: application, environment: tools.environment, clipboard: clipboard)
        try files.write(Data("---\nfields:\n  word: {default: Wish}\n---\n{{word}} {{clipboard}}".utf8), at: "wish.md")
        try open()
        XCTAssertTrue(key(GDK_KEY_Return))
        let fill = try XCTUnwrap(environment.pickerModel.fillModel)
        let word = try widget("fill-field-word")
        XCTAssertFalse(fill.builtinsResolved)
        XCTAssertTrue(key(GDK_KEY_Return))
        XCTAssertEqual(gtk_widget_has_css_class(word, "mp-nudge"), 0)
        clipboard.resolve("Copied text")
        XCTAssertTrue(GTKTestSupport.spin { fill.deliverEnabled })
    }

    func testLongFolderNamesEllipsizeInsteadOfWideningTheCard() throws {
        let folder = String(repeating: "deeply-nested-collection-", count: 4)
        try files.write(Data("---\nfields:\n  word: {default: Wish}\n---\n{{word}}".utf8), at: folder + "/wish.md")
        try open()
        let window = environment.panel.clipboardOwner
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_width(window) > 0 })
        let pickerWidth = gtk_widget_get_width(window)
        XCTAssertTrue(key(GDK_KEY_Return))
        let card = try widget("wish-card")
        XCTAssertTrue(GTKTestSupport.spin { gtk_widget_get_width(card) > 0 })
        var minimum: Int32 = 0
        gtk_widget_measure(card, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, nil, nil, nil)
        XCTAssertLessThanOrEqual(minimum, gtk_widget_get_width(card))
        XCTAssertEqual(gtk_widget_get_width(window), pickerWidth)
    }

    private func openFill(_ source: String) throws -> FillModel {
        try files.write(Data(source.utf8), at: "wish.md")
        try open()
        XCTAssertTrue(key(GDK_KEY_Return))
        let fill = try XCTUnwrap(environment.pickerModel.fillModel)
        XCTAssertTrue(GTKTestSupport.spin { fill.builtinsResolved })
        return fill
    }

    private func open() throws {
        environment.activateToggle()
        XCTAssertTrue(GTKTestSupport.spin { self.environment.panel.isActiveAndVisible })
        XCTAssertEqual(environment.pickerModel.state, .picker)
    }

    private func key(_ key: Int32, modifiers: GdkModifierType = GdkModifierType(rawValue: 0)) -> Bool {
        mp_test_emit_key_pressed(environment.panel.clipboardOwner, UInt32(key), modifiers) != 0
    }

    private func widget(_ name: String) throws -> GTK.Widget {
        func find(_ widget: GTK.Widget) -> GTK.Widget? {
            if String(cString: gtk_widget_get_name(widget)) == name { return widget }
            var child = gtk_widget_get_first_child(widget)
            while let current = child {
                if let found = find(current) { return found }
                child = gtk_widget_get_next_sibling(current)
            }
            return nil
        }
        return try XCTUnwrap(find(environment.panel.clipboardOwner), "Missing \(name)")
    }

    private func focused(_ widget: GTK.Widget) -> Bool {
        guard let focus = gtk_window_get_focus(mp_window(environment.panel.clipboardOwner)) else { return false }
        return focus == widget || gtk_widget_is_ancestor(focus, widget) != 0
    }

    private func choiceValue() throws -> String {
        String(cString: gtk_stack_get_visible_child_name(mp_stack(try widget("fill-options-language"))))
    }

    private func proofPage() throws -> String {
        String(cString: gtk_stack_get_visible_child_name(mp_stack(try widget("picker-proof-stack"))))
    }

    private func text(_ view: GTK.Widget) -> String {
        let buffer = gtk_text_view_get_buffer(mp_text_view(view))!
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        let value = gtk_text_buffer_get_text(buffer, &start, &end, 0)!
        defer { g_free(value) }
        return String(cString: value)
    }

    private func assertAccessible(_ widget: GTK.Widget, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        if let mismatch = mp_test_accessible_label(widget, expected) {
            defer { g_free(mismatch) }
            XCTFail("Accessible label: \(String(cString: mismatch))", file: file, line: line)
        }
    }

    private func usageCount() throws -> Int {
        let data = try RootedFileStore(root: LinuxPaths(environment: tools.environment).dataDirectory)
        let identity = try XCTUnwrap(environment.pickerModel.results.first?.identity)
        return try UsageStore(files: data, clock: SystemClock()).useEvents(for: identity).count
    }

    private func waitPastTake() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + WishCardMotion.take + 0.15
        XCTAssertTrue(GTKTestSupport.spin { ProcessInfo.processInfo.systemUptime >= deadline })
    }
}

private final class WishDeferredClipboard: Clipboard {
    private(set) var reads = 0
    private(set) var writes: [String] = []
    private var completion: (@Sendable (String?) -> Void)?
    func readText(_ completion: @escaping @Sendable (String?) -> Void) {
        reads += 1
        self.completion = completion
    }
    func writeText(_ text: String) { writes.append(text) }
    func resolve(_ text: String) {
        let pending = completion
        completion = nil
        pending?(text)
    }
}
#endif
