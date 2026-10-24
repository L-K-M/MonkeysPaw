import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptRenderLimitTests: XCTestCase {
    func testRepeatedValueCannotExpandBeyondTwoMiB() {
        let document = PromptCodec.parse(String(repeating: "{{x}}", count: 2_049), filename: "expanded.md")
        XCTAssertTrue(document.canRender)
        let value = String(repeating: "a", count: 1_024)
        XCTAssertThrowsError(try PromptRenderer.render(document, values: ["x": value])) {
            XCTAssertEqual($0 as? PromptRenderError, .outputTooLarge)
        }
    }

    func testExactByteBudgetSucceedsAndOneExtraByteFails() throws {
        let document = PromptCodec.parse("{{x}}", filename: "expanded.md")
        let exact = String(repeating: "a", count: Limits.maxRenderedPromptBytes)
        XCTAssertEqual(try PromptRenderer.render(document, values: ["x": exact]).utf8.count,
                       Limits.maxRenderedPromptBytes)
        XCTAssertThrowsError(try PromptRenderer.render(document, values: ["x": exact + "a"])) {
            XCTAssertEqual($0 as? PromptRenderError, .outputTooLarge)
        }
    }

    func testLiteralsEscapesAndMultibyteValuesConsumeTheSameUTF8Budget() throws {
        let document = PromptCodec.parse("é\\{{{{x}}", filename: "expanded.md")
        let exact = String(repeating: "🐒", count: (Limits.maxRenderedPromptBytes - 4) / 4)
        let result = try PromptRenderer.render(document, values: ["x": exact])
        XCTAssertTrue(result.hasPrefix("é{{"))
        XCTAssertEqual(result.utf8.count, Limits.maxRenderedPromptBytes)
        XCTAssertThrowsError(try PromptRenderer.render(document, values: ["x": exact + "!"])) {
            XCTAssertEqual($0 as? PromptRenderError, .outputTooLarge)
        }
    }

    func testRepeatedDefaultsAndClipboardAreBounded() {
        let value = String(repeating: "a", count: 1_024)
        let source = "---\nfields: {x: {default: " + value + "}}\n---\n" + String(repeating: "{{x}}", count: 2_049)
        let document = PromptCodec.parse(source, filename: "default.md")
        XCTAssertTrue(document.canRender)
        XCTAssertThrowsError(try PromptRenderer.render(document)) {
            XCTAssertEqual($0 as? PromptRenderError, .outputTooLarge)
        }
        let clipboard = PromptCodec.parse(String(repeating: "{{clipboard}}", count: 2_049), filename: "clipboard.md")
        XCTAssertThrowsError(try PromptRenderer.render(clipboard, builtins: PromptBuiltinValues(clipboard: value))) {
            XCTAssertEqual($0 as? PromptRenderError, .outputTooLarge)
        }
    }

    func testRequiredValidationStillPrecedesExpansion() {
        let document = PromptCodec.parse("{{x}}{{required}}", filename: "required.md")
        XCTAssertThrowsError(try PromptRenderer.render(document,
            values: ["x": String(repeating: "a", count: Limits.maxRenderedPromptBytes + 1)])) {
            XCTAssertEqual($0 as? PromptRenderError, .missingRequiredValue("required"))
        }
    }

    func testEditorBoundsDefaultPreviewWithoutBlockingSourceEditsOrSave() throws {
        let e = EditorHarness()
        let value = String(repeating: "a", count: 1_024)
        let source = "---\nfields: {x: {default: " + value + "}}\n---\n" + String(repeating: "{{x}}", count: 2_049)
        try e.open(source)
        XCTAssertEqual(e.model.state.previewOutputFailure, .outputTooLarge)
        XCTAssertNil(e.model.state.previewFailure, "Output size is separate from source validity")
        XCTAssertEqual(e.model.state.preview, "")
        XCTAssertTrue(e.model.state.issues.isEmpty)
        XCTAssertTrue(e.model.state.canSave)
        e.ui { e.model.save() }
        e.settle()
        let saved = PromptCodec.parse(try e.h.files.text(at: "a.md"), filename: "a.md")
        XCTAssertEqual(saved.body, String(repeating: "{{x}}", count: 2_049))
        XCTAssertEqual(saved.frontMatter.fields.first?.defaultValue, value)
        XCTAssertFalse(e.model.state.isDirty)

        e.ui { e.model.edit("Try {{empty}} and {{clipboard}}") }
        e.settle()
        XCTAssertNil(e.model.state.previewOutputFailure)
        XCTAssertEqual(e.model.state.preview, "Try {empty} and {clipboard}")
    }

    func testOversizedFillHasNoDeliveryOrLearningEffectsAndCanRecover() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("{{x}}")
        try h.open()
        let form = try h.openForm(mode: .copyOnly)
        form.setValue(String(repeating: "a", count: Limits.maxRenderedPromptBytes + 1), name: "x")
        guard case .blocked(.outputTooLarge, _) = form.preview else { return XCTFail("Expected the output-size error") }
        XCTAssertFalse(form.deliverEnabled)
        let events = h.delivery.recorder.events.count
        form.deliver(mode: .copyOnly)
        h.settle()
        XCTAssertEqual(h.delivery.recorder.events.count, events)
        XCTAssertEqual(try h.usage.useEvents(for: entry.identity), [])
        XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), [:])

        form.setValue("Small", name: "x")
        XCTAssertTrue(form.deliverEnabled)
        XCTAssertEqual(form.preview, .rendered("Small"))
    }

    func testPickerAndRepeatExplainOversizedBuiltinWithoutWritingClipboard() throws {
        let h = try RepeatHarness()
        let entry = try h.put(String(repeating: "{{clipboard}}", count: 3))
        h.flow.delivery.clipboard.writeText("small")
        try h.deliver(mode: .copyOnly)
        let uses = try h.flow.usage.useEvents(for: entry.identity)
        h.flow.delivery.clipboard.writeText(String(repeating: "a", count: Limits.maxRenderedPromptBytes / 2))
        let events = h.flow.delivery.recorder.events.filter { if case .write = $0 { return true }; return false }.count
        let results = h.repeatNow()
        guard case .reviewRequired(_, .outputTooLarge) = results.first else { return XCTFail("Repeat must explain its output-size refusal") }
        XCTAssertEqual(try h.flow.usage.useEvents(for: entry.identity), uses)
        XCTAssertEqual(h.flow.delivery.recorder.events.filter { if case .write = $0 { return true }; return false }.count, events)

        try h.open()
        h.picker.use(mode: .copyOnly)
        h.flow.settle()
        XCTAssertEqual(h.picker.selectedPreview, .renderFailure(.outputTooLarge))
        XCTAssertEqual(h.picker.state, .picker)
        XCTAssertEqual(h.flow.delivery.recorder.events.filter { if case .write = $0 { return true }; return false }.count, events)
    }
}
