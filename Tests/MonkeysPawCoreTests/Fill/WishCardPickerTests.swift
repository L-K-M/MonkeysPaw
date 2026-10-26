import Foundation
import XCTest
@testable import MonkeysPawCore

final class WishCardPickerTests: XCTestCase {
    func testSelectedCardFollowsSelectionAndIsNilForUnrenderableOrNoSelection() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Hello {{f}}", at: "a.md")
        let broken = try h.put("---\ntitle: [bad\n---\nBody", at: "b.md")
        _ = try h.put("plain", at: "c.md")
        try h.open()

        let cardIndex = try XCTUnwrap(h.picker.results.firstIndex { $0.relativePath == "a.md" })
        h.picker.selectResult(at: cardIndex)
        XCTAssertEqual(h.picker.selectedCard?.segments, [
            .text("Hello "), .field(name: "f", label: "f", kind: .text, occurrence: 0),
        ])

        let brokenIndex = try XCTUnwrap(h.picker.results.firstIndex { $0.relativePath == "b.md" })
        h.picker.selectResult(at: brokenIndex)
        XCTAssertNil(h.picker.selectedCard)
        XCTAssertEqual(h.picker.selectedPreview, .issues(broken.issues))
        h.picker.use(mode: .copyOnly)
        XCTAssertNil(h.picker.selectedCard)
        XCTAssertNil(h.picker.fillModel)

        h.picker.setQuery("zzz")
        XCTAssertNil(h.picker.selectedCard)
        XCTAssertEqual(h.picker.selectedPreview, .none)
    }

    func testSelectionBuildsCardWithoutClipboardOrRememberedReads() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("{{f}}/{{clipboard}}")
        try h.values.record(identity: entry.identity, values: ["f": "secret"])
        try h.open()
        let accesses = h.data.accessCount
        let reads = h.delivery.clipboard.readCount

        h.picker.selectResult(at: 0)
        XCTAssertEqual(h.data.accessCount, accesses)
        XCTAssertEqual(h.delivery.clipboard.readCount, reads)
        XCTAssertEqual(h.picker.selectedCard?.segments, [
            .field(name: "f", label: "f", kind: .text, occurrence: 0),
            .text("/"),
            .builtin(.clipboard),
        ])

        h.picker.moveSelection(.down)
        XCTAssertEqual(h.data.accessCount, accesses)
        XCTAssertEqual(h.delivery.clipboard.readCount, reads)
    }

    func testFieldlessSelectedCardCoversOnlyBuiltinAndText() throws {
        let h = PromptFlowHarness()
        _ = try h.put("now {{date}}")
        try h.open()
        XCTAssertEqual(h.picker.selectedCard?.segments, [
            .text("now "), .builtin(.date),
        ])
        XCTAssertFalse(try XCTUnwrap(h.picker.selectedCard).hasFields)
    }
}
