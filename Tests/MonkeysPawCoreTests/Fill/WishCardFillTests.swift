import Foundation
import XCTest
@testable import MonkeysPawCore

final class WishCardFillTests: XCTestCase {
    func testPrefillSourceIsRememberedEvenEmptyAndDefaultOtherwise() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("""
        ---
        fields:
          keep:
            default: fallback
          skip:
            remember: false
            default: fresh
        ---
        {{keep}} {{skip}} {{implicit}}
        """)
        try h.values.record(identity: entry.identity, values: ["keep": "", "skip": "old"])
        let form = h.fill.form(for: entry)
        XCTAssertEqual(form.fields.map(\.prefillSource), [.remembered, .defaultValue, .defaultValue])
        XCTAssertEqual(form.fields.map(\.prefill), ["", "fresh", ""])
    }

    func testProvenanceTracksDefaultsRememberedDraftTypingAndReset() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("""
        ---
        fields:
          f:
            default: initial
        ---
        {{f}} {{g}}
        """)
        try h.values.record(identity: entry.identity, values: ["f": "kept"])
        try h.open()
        let form = try h.openForm()
        XCTAssertEqual(form.fields.map(\.provenance), [.remembered, .defaultValue])

        form.setValue("typed", name: "f")
        form.setValue("", name: "g")
        XCTAssertEqual(form.fields.map(\.provenance), [.typed, .typed])

        form.escape()
        let reopened = try h.openForm()
        // A held draft key wins provenance even when its value is empty.
        XCTAssertEqual(reopened.fields.map(\.provenance), [.draft, .draft])
        XCTAssertEqual(reopened.fields.map(\.value), ["typed", ""])

        h.picker.forgetSelectedValues()
        XCTAssertEqual(reopened.fields.map(\.provenance), [.defaultValue, .defaultValue])
        XCTAssertEqual(reopened.fields.map(\.value), ["initial", ""])
    }

    func testBuiltinTextIsNilUntilSnapshotThenReadsSnapshotFields() throws {
        let h = PromptFlowHarness(mainMode: .deferred)
        _ = try h.put("{{f}}/{{clipboard}}")
        try h.open()
        h.delivery.clipboard.readMode = .deferred
        let form = try h.openForm()
        XCTAssertNil(form.builtinText(.clipboard))
        XCTAssertNil(form.builtinText(.date))
        XCTAssertNil(form.builtinText(.time))
        XCTAssertNil(form.clipboardSummary)

        h.delivery.clipboard.completeRead("clip\ntext")
        h.delivery.main.drain()
        XCTAssertEqual(form.builtinText(.clipboard), "clip\ntext")
        XCTAssertEqual(form.builtinText(.date), "1970-01-01")
        XCTAssertEqual(form.builtinText(.time), "00:00")
        XCTAssertEqual(form.clipboardSummary, ClipboardSummary("clip\ntext"))
    }

    func testBuiltinTextAndSummaryStayNilWithoutClipboardUse() throws {
        let h = PromptFlowHarness()
        _ = try h.put("{{f}}/{{date}}")
        try h.open()
        let form = try h.openForm()
        h.delivery.main.drain()
        XCTAssertTrue(form.builtinsResolved)
        XCTAssertEqual(form.builtinText(.date), "1970-01-01")
        XCTAssertNil(form.builtinText(.clipboard))
        XCTAssertNil(form.clipboardSummary)
        XCTAssertEqual(h.delivery.clipboard.readCount, 0)
    }

    func testMissingRequiredIndexAndWarmthIgnoreOptionalFields() throws {
        let h = PromptFlowHarness()
        _ = try h.put("""
        ---
        fields:
          req:
            default: set
          opt:
            optional: true
        ---
        {{req}} {{opt}} {{other}}
        """)
        try h.open()
        let form = try h.openForm()
        XCTAssertEqual(form.missingRequiredFieldIndex, 2)
        XCTAssertEqual(form.warmth, 0.5)

        form.setValue("filled", name: "other")
        XCTAssertNil(form.missingRequiredFieldIndex)
        XCTAssertEqual(form.warmth, 1.0)
        form.setValue("", name: "req")
        XCTAssertEqual(form.missingRequiredFieldIndex, 0)
        XCTAssertEqual(form.warmth, 0.5)
    }

    func testWarmthIsOneWhenNothingIsRequired() throws {
        let h = PromptFlowHarness()
        _ = try h.put("---\nfields:\n  opt:\n    optional: true\n---\n{{opt}}")
        try h.open()
        let form = try h.openForm()
        XCTAssertEqual(form.warmth, 1.0)
        XCTAssertNil(form.missingRequiredFieldIndex)
    }

    func testCardTitleAndFolderComeFromTheHeldEntry() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("---\ntitle: Greeting\n---\nHello {{name}}", at: "sub/dir/greet.md")
        try h.open()
        let form = try h.openForm()
        XCTAssertEqual(form.title, "Greeting")
        XCTAssertEqual(form.folder, "sub/dir")
        XCTAssertEqual(form.card, PromptCard(document: entry.document))
        XCTAssertTrue(form.card.hasFields)
    }
}
