import Foundation
import XCTest
@testable import MonkeysPawCore

final class FillServiceTests: XCTestCase {
    func testBuiltinSnapshotUsesLocalGregorianPOSIXDateTimeAndOneClockSample() throws {
        let h = PromptFlowHarness(zone: TimeZone(secondsFromGMT: -5 * 3_600)!)
        let entry = try h.put("{{date}} {{time}}")
        let snapshots = BuiltinSnapshots()
        h.fill.builtinSnapshot(for: entry.document) { snapshots.append($0) }
        XCTAssertEqual(h.clock.readCount, 1)
        XCTAssertEqual(snapshots.received, [PromptBuiltinValues(date: "1969-12-31", time: "19:00")])
        XCTAssertEqual(h.delivery.clipboard.readCount, 0)
        XCTAssertEqual(try h.fill.render(entry.document, values: [:],
                                         builtins: try XCTUnwrap(snapshots.received.first)),
                       "1969-12-31 19:00")
        let east = PromptFlowHarness(zone: TimeZone(secondsFromGMT: 5 * 3_600 + 30 * 60)!)
        let next = try east.put("{{time}}")
        east.fill.builtinSnapshot(for: next.document) { snapshots.append($0) }
        XCTAssertEqual(snapshots.received.last?.time, "05:30")
    }

    func testClipboardReadOnlyWhenUsedAndAsyncSnapshotRetainsOpenTime() throws {
        let h = PromptFlowHarness()
        let plain = try h.put("Nothing to read")
        let snapshots = BuiltinSnapshots()
        h.fill.builtinSnapshot(for: plain.document) { snapshots.append($0) }
        XCTAssertEqual(h.delivery.clipboard.readCount, 0)
        let entry = try h.put("{{clipboard}} {{date}} {{time}} {{clipboard}}")
        h.delivery.clipboard.readMode = .deferred
        h.fill.builtinSnapshot(for: entry.document) { snapshots.append($0) }
        XCTAssertEqual(h.delivery.clipboard.readCount, 1)
        XCTAssertEqual(snapshots.received.count, 1)
        h.clock.date = Date(timeIntervalSince1970: 86_400)
        h.delivery.clipboard.completeRead("{{raw}}\nprivate text")
        XCTAssertEqual(snapshots.received.count, 2)
        XCTAssertEqual(snapshots.received.last, PromptBuiltinValues(clipboard: "{{raw}}\nprivate text",
                                                                   date: "1970-01-01", time: "00:00"))
    }

    func testEmptyOrUnavailableClipboardStillCompletesWithRenderableEmptyValue() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("A{{clipboard}}B")
        let snapshots = BuiltinSnapshots()
        h.fill.builtinSnapshot(for: entry.document) { snapshots.append($0) }
        XCTAssertEqual(snapshots.received.count, 1)
        XCTAssertEqual(try h.fill.render(entry.document, values: [:],
                                         builtins: try XCTUnwrap(snapshots.received.first)), "AB")
        h.delivery.clipboard.writeText("")
        h.fill.builtinSnapshot(for: entry.document) { snapshots.append($0) }
        XCTAssertEqual(snapshots.received.count, 2)
        XCTAssertEqual(snapshots.received.last?.clipboard, "")
    }

    func testFormBodyOrderMetadataRememberedWinsOverDefaultsAndEmptyStaysEmpty() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("""
        ---
        fields:
          second:
            type: choice
            label: Language
            description: Pick a language.
            options: [Rust, Python]
            default: Rust
          first:
            type: multiline
            optional: true
            default: default text
          noMemory:
            default: fresh
            remember: false
        ---
        {{first}} {{second}} {{implicit}} {{noMemory}} {{first}}
        """)
        try h.values.record(identity: entry.identity, values: ["first": "", "second": "Python", "noMemory": "old"])
        let form = h.fill.form(for: entry)
        XCTAssertEqual(form.fields.map(\.name), ["first", "second", "implicit", "noMemory"])
        XCTAssertEqual(form.fields.map(\.prefill), ["", "Python", "", "fresh"])
        XCTAssertEqual(form.fields.map(\.kind), [.multiline, .choice, .text, .text])
        XCTAssertEqual(form.fields[1].label, "Language")
        XCTAssertEqual(form.fields[1].description, "Pick a language.")
        XCTAssertEqual(form.fields[1].options.map(\.value), ["Rust", "Python"])
        XCTAssertTrue(form.fields[0].optional)
        XCTAssertFalse(form.fields[3].remember)
        XCTAssertTrue(form.canRender)
        XCTAssertFalse(form.isReadOnly)
        XCTAssertNil(form.warning)
    }

    func testFormReadFailureSurfacesWarningWithoutResettingRememberedState() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("---\nfields:\n  f:\n    default: fallback\n---\n{{f}}")
        try h.data.put("private corrupt state", at: "values.json")
        let form = h.fill.form(for: entry)
        XCTAssertEqual(form.fields[0].prefill, "fallback")
        XCTAssertEqual(form.warning, .rememberedValuesUnavailable)
        XCTAssertEqual(try h.data.text(at: "values.json"), "private corrupt state")
    }

    func testPreviewDescribesMissingRequiredInvalidChoiceValidationReadOnlyAndBuiltin() throws {
        let h = PromptFlowHarness()
        let required = try h.put("{{f}}")
        XCTAssertEqual(h.fill.preview(required.document, values: [:], builtins: PromptBuiltinValues()),
                       .blocked(.missingRequiredValue("f"), issues: []))
        let choice = try h.put("---\nfields:\n  c:\n    type: choice\n    options: [one, two]\n---\n{{c}}")
        XCTAssertEqual(h.fill.preview(choice.document, values: ["c": "bad"], builtins: PromptBuiltinValues()),
                       .blocked(.invalidChoiceValue("c"), issues: []))
        let broken = try h.put("---\ntitle: [bad\n---\nBody")
        XCTAssertEqual(h.fill.preview(broken.document, values: [:], builtins: PromptBuiltinValues()),
                       .blocked(.invalidPrompt, issues: broken.issues))
        let future = try h.put("---\nformat: 2\n---\nBody")
        XCTAssertEqual(h.fill.preview(future.document, values: [:], builtins: PromptBuiltinValues()),
                       .blocked(.unsupportedFormat(future.document.frontMatter.format), issues: future.issues))
        XCTAssertTrue(h.fill.form(for: future).isReadOnly)
        XCTAssertFalse(h.fill.form(for: broken).canRender)
        let builtin = try h.put("{{clipboard}}")
        XCTAssertEqual(h.fill.preview(builtin.document, values: [:], builtins: PromptBuiltinValues()),
                       .blocked(.missingBuiltin(.clipboard), issues: []))
    }

    func testRenderPassthroughPreservesRawValuesAndErrors() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("{{f}} {{f}}")
        XCTAssertEqual(h.fill.preview(entry.document, values: ["f": "{{raw}}"], builtins: PromptBuiltinValues()),
                       .rendered("{{raw}} {{raw}}"))
        XCTAssertEqual(try h.fill.render(entry.document, values: ["f": " x\n"], builtins: PromptBuiltinValues()),
                       try PromptRenderer.render(entry.document, values: ["f": " x\n"]))
        XCTAssertThrowsError(try h.fill.render(entry.document, values: ["f": ""], builtins: PromptBuiltinValues())) {
            XCTAssertEqual($0 as? PromptRenderError, .missingRequiredValue("f"))
        }
    }

    func testRememberedOnDeliveryFiltersFlagsMergesAndStoresEmptyVerbatim() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("""
        ---
        fields:
          forget:
            remember: false
          empty:
            optional: true
        ---
        {{keep}} {{forget}} {{empty}}
        """)
        try h.values.record(identity: entry.identity, values: ["previous": "kept"])
        try h.fill.rememberedOnDelivery(identity: entry.identity, fields: entry.document.effectiveFields,
                                        values: ["keep": "value", "forget": "secret", "empty": "", "extra": "no"])
        XCTAssertEqual(try h.values.rememberedValues(for: entry.identity),
                       ["previous": "kept", "keep": "value", "empty": ""])
        XCTAssertTrue(h.data.isPrivate(at: "values.json"))
        let forgotten = try h.put("---\nfields:\n  f:\n    remember: false\n---\n{{f}}", at: "b.md")
        let before = try h.data.read(at: "values.json")
        try h.fill.rememberedOnDelivery(identity: forgotten.identity, fields: forgotten.document.effectiveFields,
                                        values: ["f": "no"])
        XCTAssertEqual(try h.data.read(at: "values.json"), before)
    }

    func testRememberedOnDeliverySkipsUndeliveredFieldsInsteadOfStoringDefaults() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("---\nfields:\n  f:\n    default: declared\n---\n{{f}} {{g}}")
        try h.fill.rememberedOnDelivery(identity: entry.identity, fields: entry.document.effectiveFields,
                                        values: ["g": "used"])
        XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), ["g": "used"])
    }

    func testForgetValuesRemovesStaleFieldsRestoresDefaultsAndPreservesOtherPrompt() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("---\nfields:\n  f:\n    default: fallback\n---\n{{f}}")
        let other = try h.put("---\nfields:\n  g:\n    default: fresh\n---\n{{g}}", at: "b.md")
        try h.values.record(identity: entry.identity, values: ["f": "", "removedField": "stale text"])
        try h.values.record(identity: other.identity, values: ["g": "kept", "anotherOldField": "also kept"])
        XCTAssertEqual(h.fill.form(for: entry).fields[0].prefill, "")

        try h.fill.forgetValues(for: entry.identity)

        let form = h.fill.form(for: entry)
        XCTAssertEqual(form.fields[0].prefill, "fallback")
        XCTAssertNil(form.warning)
        XCTAssertEqual(try h.values.rememberedValues(for: entry.identity), [:])
        XCTAssertEqual(h.fill.form(for: other).fields[0].prefill, "kept")
        XCTAssertEqual(try h.values.rememberedValues(for: other.identity),
                       ["g": "kept", "anotherOldField": "also kept"])
        XCTAssertEqual(h.clock.readCount, 0)
        XCTAssertEqual(h.delivery.clipboard.readCount, 0)
    }

    func testForgetAllValuesRestoresDefaultsForEveryPromptAndRecoversCorruption() throws {
        let h = PromptFlowHarness()
        let first = try h.put("---\nfields:\n  f:\n    default: first default\n---\n{{f}}")
        let second = try h.put("---\nfields:\n  g:\n    default: second default\n---\n{{g}}", at: "b.md")
        try h.values.record(identity: first.identity, values: ["f": "first remembered"])
        try h.values.record(identity: second.identity, values: ["g": "second remembered"])

        try h.fill.forgetAllValues()

        XCTAssertEqual(h.fill.form(for: first).fields[0].prefill, "first default")
        XCTAssertEqual(h.fill.form(for: second).fields[0].prefill, "second default")
        XCTAssertNil(h.fill.form(for: first).warning)
        XCTAssertNil(h.fill.form(for: second).warning)
        XCTAssertEqual(try h.data.text(at: "values.json"), "{\"values\":{},\"version\":1}")
        XCTAssertTrue(h.data.isPrivate(at: "values.json"))

        try h.data.put("private corrupt text", at: "values.json")
        XCTAssertEqual(h.fill.form(for: first).warning, .rememberedValuesUnavailable)
        XCTAssertThrowsError(try h.fill.forgetValues(for: first.identity)) {
            XCTAssertEqual($0 as? LibraryError, .operationFailed)
        }
        XCTAssertEqual(try h.data.text(at: "values.json"), "private corrupt text")
        try h.fill.forgetAllValues()
        XCTAssertNil(h.fill.form(for: first).warning)
        XCTAssertEqual(h.fill.form(for: first).fields[0].prefill, "first default")
        XCTAssertEqual(try h.data.text(at: "values.json"), "{\"values\":{},\"version\":1}")
        XCTAssertTrue(h.data.isPrivate(at: "values.json"))
    }

    func testForgetAPIsPassThroughTypedFailuresWithoutChangingState() throws {
        let h = PromptFlowHarness()
        let entry = try h.put("{{f}}")
        try h.values.record(identity: entry.identity, values: ["f": "kept"])
        let before = try h.data.read(at: "values.json")
        let operations: [() throws -> Void] = [
            { try h.fill.forgetValues(for: entry.identity) },
            { try h.fill.forgetAllValues() }
        ]
        for operation in operations {
            h.data.failNextWrite = true
            XCTAssertThrowsError(try operation()) {
                XCTAssertEqual($0 as? FileStoreError, .ioFailure)
            }
            XCTAssertEqual(try h.data.read(at: "values.json"), before)
        }

        let accesses = h.data.accessCount
        XCTAssertThrowsError(try h.fill.forgetValues(for: .local("private/path"))) {
            XCTAssertEqual($0 as? LibraryError, .invalidIdentity)
        }
        XCTAssertEqual(h.data.accessCount, accesses)
        h.data.onRead = { _ in throw FileStoreError.outsideRoot }
        XCTAssertThrowsError(try h.fill.forgetValues(for: entry.identity)) {
            XCTAssertEqual($0 as? FileStoreError, .outsideRoot)
        }
        h.data.onRead = nil
        XCTAssertEqual(try h.data.read(at: "values.json"), before)
    }
}
