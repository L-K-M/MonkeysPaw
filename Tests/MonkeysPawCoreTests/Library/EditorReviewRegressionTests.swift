import Foundation
import XCTest
@testable import MonkeysPawCore

final class EditorReviewRegressionTests: XCTestCase {
    func testDeletedCopyBeforeReconciliationKeepsSavedTextAndRecoveryChoices() throws {
        for choice in [EditorConflictChoice.keepMine, .saveAsCopy, .discard] {
            let e = EditorHarness(heldWork: true, queuedMain: true)
            try e.open()
            e.ui { e.model.edit("Just saved copy"); e.model.saveAsCopy() }
            e.h.held.releaseNext()
            let written = try e.h.files.text(at: "a 2.md")
            // Delete before adoption, when no session observes the copy yet.
            try e.change(nil, at: "a 2.md")
            e.h.main.releaseAll()
            let adopted = try XCTUnwrap(e.model.state.prompt)
            XCTAssertFalse(e.model.state.isDirty)
            e.settle()

            XCTAssertEqual(e.model.state.prompt, adopted, "choice: \(choice)")
            XCTAssertEqual(e.model.state.source, written, "choice: \(choice)")
            XCTAssertEqual(e.model.state.status, .idle)
            XCTAssertEqual(e.model.state.conflict?.kind, .deleted)
            XCTAssertEqual(e.model.state.conflict?.choices, [.keepMine, .saveAsCopy, .discard])
            XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original")
            e.ui { e.model.resolveConflict(choice) }
            e.settle()
            if choice == .discard {
                XCTAssertNil(e.model.state.prompt)
                XCTAssertNil(e.model.state.source)
            } else {
                let recovered = try XCTUnwrap(e.model.state.prompt)
                XCTAssertTrue(try e.h.files.text(at: recovered.relativePath.string).hasSuffix("Just saved copy"))
                XCTAssertNil(e.model.state.conflict)
                XCTAssertFalse(e.model.state.isDirty)
            }
        }
    }

    func testPreviewDefaultsNeverUseTrappingDictionaryConstruction() throws {
        let source = try editorSource()
        XCTAssertFalse(source.contains("Dictionary(uniqueKeysWithValues:"),
            "Duplicate effective field names must never trap while typing.")
        let e = EditorHarness()
        try e.open("---\nfields:\n  a:\n    default: First\n---\n{{a}} {{a}} {{missing}}")
        XCTAssertEqual(e.model.state.preview, "First First {missing}")
    }

    func testPreviewDuplicateDefaultsKeepFirstDeclarationIncludingEmptyDefault() {
        let fields = [PromptField(name: "a", defaultValue: "First"),
                      PromptField(name: "a", defaultValue: "Later"),
                      PromptField(name: "empty"),
                      PromptField(name: "empty", defaultValue: "Later")]
        XCTAssertEqual(EditorModel.previewDefaults(for: fields), ["a": "First", "empty": "{empty}"])
    }

    func testFailedDecisionSaveDoesNotApproveLaterManualSave() throws {
        for invalid in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: true)
            let original = try e.open()
            var replies: [EditorGuardResult] = []
            e.ui {
                e.model.edit(invalid ? "{{unclosed" : "Mine")
                e.model.request(.close) { replies.append($0) }
            }
            e.settle()
            let decision = try XCTUnwrap(e.model.state.pendingDecision)
            if !invalid { e.h.files.failNextWrite = true }
            try e.decide(.save)
            e.settle()
            XCTAssertEqual(e.model.state.pendingDecision, decision)
            XCTAssertEqual(e.model.state.status, invalid
                ? .failed(.invalid(e.model.state.issues))
                : .failed(.editing(.fileStore(.ioFailure))))
            XCTAssertTrue(replies.isEmpty)

            e.ui { e.model.edit("Manual save"); e.model.save() }
            e.settle()
            XCTAssertEqual(e.model.state.prompt?.relativePath, original.relativePath)
            XCTAssertEqual(e.model.state.pendingDecision, decision,
                "A manual save cannot confirm an earlier failed decision save.")
            XCTAssertTrue(replies.isEmpty)
            XCTAssertFalse(e.model.state.isDirty)
            let committed = try e.h.files.text(at: "a.md")
            XCTAssertEqual(committed, e.model.state.source)
            XCTAssertEqual(PromptCodec.parse(committed, filename: "a.md").body, "Manual save")
            try e.decide(.cancel)
            e.settle()
            XCTAssertEqual(replies, [.cancelled])
        }
    }

    func testDeactivationCompletesPendingAndQueuedGuardsExactlyOnce() throws {
        for queuedMain in [false, true] {
            let e = EditorHarness(queuedMain: queuedMain)
            try e.open()
            var closeReplies: [EditorGuardResult] = []
            var quitReplies: [EditorGuardResult] = []
            var moveReplies: [EditorGuardResult] = []
            e.ui {
                e.model.edit("Mine")
                e.model.request(.close) { closeReplies.append($0); XCTAssertTrue(e.h.marker.isUI) }
                e.model.request(.quit) { quitReplies.append($0); XCTAssertTrue(e.h.marker.isUI) }
                e.model.request(.move) { moveReplies.append($0); XCTAssertTrue(e.h.marker.isUI) }
            }
            e.settle()
            XCTAssertEqual(e.model.state.pendingDecision?.action, .close)
            XCTAssertEqual(e.model.state.queuedActions, [.quit, .move])
            e.ui { e.model.deactivate(); e.model.deactivate() }
            e.settle()
            XCTAssertEqual(closeReplies, [.inactive], "queuedMain: \(queuedMain)")
            XCTAssertEqual(quitReplies, [.inactive], "queuedMain: \(queuedMain)")
            XCTAssertEqual(moveReplies, [.inactive], "queuedMain: \(queuedMain)")
        }
    }

    func testDeactivationCompletesGuardsQueuedDuringSave() throws {
        let e = EditorHarness(heldWork: true, queuedMain: true)
        try e.open()
        var replies: [EditorGuardResult] = []
        e.ui {
            e.model.edit("Mine")
            e.model.save()
            e.model.request(.quit) { replies.append($0); XCTAssertTrue(e.h.marker.isUI) }
            e.model.deactivate()
        }
        e.settle()
        XCTAssertEqual(replies, [.inactive])
        XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original")
    }

    func testDeactivationCompletesReservedDecisionBeforeQueuedApproval() throws {
        for decision in [EditorDecision.discard, .cancel] {
            let e = EditorHarness(queuedMain: true)
            try e.open()
            var replies: [EditorGuardResult] = []
            var reentrantReplies: [EditorGuardResult] = []
            e.ui {
                e.model.edit("Mine")
                e.model.request(.quit) {
                    replies.append($0)
                    XCTAssertTrue(e.h.marker.isUI)
                    e.model.request(.move) { reentrantReplies.append($0) }
                }
            }
            e.settle()
            try e.decide(decision)
            XCTAssertNil(e.model.state.pendingDecision)
            e.ui { e.model.deactivate() }
            e.settle()
            XCTAssertEqual(replies, [.inactive], "decision: \(decision)")
            XCTAssertEqual(reentrantReplies, [.inactive], "decision: \(decision)")
        }
    }

    func testDuplicateQueuedOpenKeepsInFlightLoadAndCompletesEveryGuard() throws {
        for queuedMain in [false, true] {
            let e = EditorHarness(heldWork: true, queuedMain: queuedMain)
            let selection = try e.put("Original")
            var firstReplies: [EditorGuardResult] = []
            var secondReplies: [EditorGuardResult] = []
            e.ui {
                e.model.request(.open(selection)) { firstReplies.append($0) }
                e.model.request(.open(selection)) { secondReplies.append($0) }
            }
            e.h.main.releaseAll()
            XCTAssertEqual(e.h.held.pending.count, 1, "queuedMain: \(queuedMain)")
            XCTAssertEqual(e.model.state.status, .loading)
            e.settle()
            XCTAssertEqual(e.model.state.source, "Original")
            XCTAssertEqual(firstReplies, [.allowed])
            XCTAssertEqual(secondReplies, [.allowed])
            let accesses = e.h.files.accessCount
            var samePromptReplies: [EditorGuardResult] = []
            e.ui {
                e.model.edit("Mine")
                e.model.request(.open(selection)) { samePromptReplies.append($0) }
            }
            e.settle()
            XCTAssertEqual(samePromptReplies, [.allowed])
            XCTAssertNil(e.model.state.pendingDecision)
            XCTAssertEqual(e.model.state.source, "Mine")
            XCTAssertEqual(e.h.files.accessCount, accesses)
        }
    }

    func testPreviewReusesFormattersUntilTimeZoneChanges() throws {
        var zone = try XCTUnwrap(TimeZone(secondsFromGMT: 19_800))
        let e = EditorHarness(timeZone: { zone })
        try e.open("{{date}} {{time}}")
        XCTAssertEqual(e.model.state.preview, "1970-01-01 05:30")
        let initial = cachedFormatters(e.model)
        XCTAssertEqual(initial.count, 2, "Preview caches separate date and time formatters.")
        guard initial.count == 2 else { return }

        e.h.clock.date = Date(timeIntervalSince1970: 86_400)
        e.ui { e.model.edit("{{date}} {{time}}!") }
        XCTAssertEqual(e.model.state.preview, "1970-01-02 05:30!")
        XCTAssertEqual(cachedFormatters(e.model).map(ObjectIdentifier.init), initial.map(ObjectIdentifier.init))
        zone = try XCTUnwrap(TimeZone(secondsFromGMT: -28_800))
        e.ui { e.model.edit("{{date}} {{time}}!!") }
        XCTAssertEqual(e.model.state.preview, "1970-01-01 16:00!!")
        let changedZone = cachedFormatters(e.model)
        XCTAssertEqual(changedZone.count, 2)
        XCTAssertTrue(Set(changedZone.map(ObjectIdentifier.init)).isDisjoint(with: initial.map(ObjectIdentifier.init)))
        e.ui { e.model.edit("{{date}} {{time}}!!!") }
        XCTAssertEqual(cachedFormatters(e.model).map(ObjectIdentifier.init), changedZone.map(ObjectIdentifier.init))
    }

    func testEditorConstructionHasNoClipboardDependency() throws {
        // Binding the exact initializer type fails compilation if a clipboard
        // parameter is added, even if that parameter has a default value.
        let construct: (PromptEditingService, WallClock, @escaping () -> TimeZone, MainThread) -> EditorModel = EditorModel.init
        let h = PromptEditingHarness()
        let model = construct(h.editor, h.clock, { .gmt }, h.main)
        XCTAssertFalse(Mirror(reflecting: model).children.contains { $0.value is Clipboard })
        XCTAssertFalse(try editorSource().contains("Clipboard"),
            "Editor construction and preview must have no clipboard port, including an optional stored dependency.")
    }

    private func editorSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Sources/MonkeysPawCore/Presentation/EditorModel.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func cachedFormatters(_ model: EditorModel) -> [DateFormatter] {
        func formatters(in value: Any) -> [DateFormatter] {
            if let formatter = value as? DateFormatter { return [formatter] }
            let mirror = Mirror(reflecting: value)
            guard mirror.displayStyle == .optional || mirror.displayStyle == .tuple else { return [] }
            return mirror.children.flatMap { formatters(in: $0.value) }
        }
        return Mirror(reflecting: model).children.flatMap { formatters(in: $0.value) }
    }
}
