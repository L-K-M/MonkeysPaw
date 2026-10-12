import Foundation
import XCTest
@testable import MonkeysPawCore

final class EditorModelTests: XCTestCase {
    func testOpenTracksExactSourceBytesAndUndoClearsDirty() throws {
        let e = EditorHarness()
        let selection = try e.open("e\u{301}\r\n")
        XCTAssertEqual(e.model.state.prompt, selection)
        XCTAssertEqual(e.model.state.status, .idle)
        XCTAssertFalse(e.model.state.isDirty)
        var published: [EditorState] = []
        e.model.addObserver { published.append($0); XCTAssertTrue(e.h.marker.isUI) }
        e.ui { e.model.edit("é\r\n") }
        XCTAssertTrue(e.model.state.isDirty, "Canonically equivalent strings have different file bytes.")
        e.ui { e.model.edit("e\u{301}\r\n") }
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(Data(try XCTUnwrap(published.first?.source).utf8), Data("é\r\n".utf8))
    }

    func testLiveValidationAndFieldInspectorFollowCurrentSource() throws {
        let e = EditorHarness()
        try e.open()
        let text = """
        ---
        fields:
          unused:
            description: Kept in inspector
          language:
            type: choice
            options: [Swift, Rust]
            default: Swift
            remember: false
            description: Choose a language
          details:
            type: multiline
        ---
        {{details}} {{language}} {{implicit}} {{language}}
        """
        e.ui { e.model.edit(text) }
        XCTAssertEqual(e.model.state.fields.map(\.name), ["details", "language", "implicit", "unused"])
        let choice = try XCTUnwrap(e.model.state.fields.first { $0.name == "language" })
        XCTAssertEqual(choice.kind, .choice)
        XCTAssertEqual(choice.options.map(\.value), ["Swift", "Rust"])
        XCTAssertEqual(choice.defaultValue, "Swift")
        XCTAssertFalse(choice.remember)
        XCTAssertEqual(choice.description, "Choose a language")
        XCTAssertTrue(e.model.state.fields[2].isImplicit)
        XCTAssertEqual(e.model.state.issues.map(\.code), [.unusedField])
        XCTAssertEqual(e.model.state.preview, "{details} Swift {implicit} Swift")

        e.ui { e.model.edit("---\ntitle: [broken\n---\n{{new}}") }
        XCTAssertTrue(e.model.state.issues.contains { $0.code == .invalidYAML })
        XCTAssertEqual(e.model.state.fields.map(\.name), ["new"])
        XCTAssertEqual(e.model.state.previewFailure, .invalidPrompt)
        e.ui { e.model.edit("{{unclosed") }
        XCTAssertEqual(e.model.state.issues.map(\.code), [.unbalancedOpener])
        e.ui { e.model.edit("---\nformat: 2\n---\nFuture draft") }
        XCTAssertNil(e.model.state.readOnlyReason, "A newly typed version must remain correctable.")
        XCTAssertTrue(e.model.state.canEdit)
        e.ui { e.model.edit("Corrected") }
        XCTAssertTrue(e.model.state.issues.isEmpty)
    }

    func testPreviewUsesDefaultsMarkersClockAndTokensWithoutClipboardReads() throws {
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 19_800))
        let e = EditorHarness(timeZone: { zone })
        let source = "---\nfields:\n  a:\n    default: '{{clipboard}}'\n  choice:\n    type: choice\n    options: [one, two]\n---\n{{a}} {{choice}} {{missing}} {{date}} {{time}} {{clipboard}} \\{{literal}} {{#if x}}"
        try e.open(source)
        XCTAssertEqual(e.model.state.preview,
            "{{clipboard}} {choice} {missing} 1970-01-01 05:30 {clipboard} {{literal}} {{#if x}}")
        XCTAssertNil(e.model.state.previewFailure)
        e.h.clock.date = Date(timeIntervalSince1970: 86_400)
        e.ui { e.model.edit(source + "!") }
        XCTAssertTrue(e.model.state.preview.contains("1970-01-02 05:30 {clipboard}"))
        e.ui { e.model.save() }
        XCTAssertEqual(e.model.state.status, .saved)
    }

    func testSaveRefreshesCanonicalSourceIdentityStampAndOwnWritesStayQuiet() throws {
        let e = EditorHarness()
        try e.open("---\nmodel: custom\n---\nOriginal\r\n")
        let oldIdentity = try XCTUnwrap(e.model.state.prompt?.identity)
        let oldStamp = e.model.state.stamp
        e.ui { e.model.edit("---\nmodel: custom\n---\n  Mine\r\n"); e.model.save() }
        XCTAssertEqual(e.model.state.status, .saved)
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertNotEqual(e.model.state.prompt?.identity, oldIdentity)
        XCTAssertNotEqual(e.model.state.stamp, oldStamp)
        XCTAssertEqual(e.model.state.source, try e.h.files.text(at: "a.md"))
        XCTAssertTrue(try XCTUnwrap(e.model.state.source).contains("model: custom\n"))
        XCTAssertTrue(try XCTUnwrap(e.model.state.source).hasSuffix("  Mine\r\n"))
        let identity = try XCTUnwrap(e.model.state.prompt?.identity)
        XCTAssertEqual(try e.h.library.history(for: identity).count, 1)
        let savedSource = try XCTUnwrap(e.model.state.source)
        e.ui { e.model.edit(savedSource + "Next") }
        try e.h.index.apply(LibraryChangeSet(modified: ["a.md"]))
        XCTAssertNil(e.model.state.conflict, "The editor's committed stamp is its new baseline.")
        e.ui { e.model.save() }
        XCTAssertEqual(e.model.state.status, .saved)
        XCTAssertEqual(e.model.state.prompt?.identity, identity)
    }

    func testFailedSaveRetainsSourceDirtyAndLoadStamp() throws {
        let e = EditorHarness()
        try e.open()
        let stamp = e.model.state.stamp
        e.ui { e.model.edit("Mine") }
        e.h.files.failNextWrite = true
        e.ui { e.model.save() }
        XCTAssertEqual(e.model.state.status, .failed(.editing(.fileStore(.ioFailure))))
        XCTAssertEqual(e.model.state.source, "Mine")
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertEqual(e.model.state.stamp, stamp)
        XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original")
        e.ui { e.model.save() }
        XCTAssertEqual(e.model.state.status, .saved)
        XCTAssertFalse(e.model.state.isDirty)
    }

    func testInvalidSaveIsTypedAndDoesNotWrite() throws {
        let e = EditorHarness()
        try e.open()
        e.ui { e.model.edit("{{unclosed"); e.model.save() }
        XCTAssertEqual(e.model.state.status, .failed(.invalid(e.model.state.issues)))
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original")
        let identity = try XCTUnwrap(e.model.state.prompt?.identity)
        XCTAssertTrue(try e.h.library.history(for: identity).isEmpty)
    }

    func testDiskReadOnlyReasonsRefuseEditsAndSaveWithoutIO() throws {
        let futureFormat = try XCTUnwrap(PromptFormatVersion(2))
        let cases: [(Data, PromptReadOnlyReason)] = [
            (Data([0xff]), .invalidUTF8),
            (Data(repeating: 65, count: Limits.maxPromptBytes + 1), .sourceTooLarge),
            (Data("---\nformat: 2\n---\nFuture".utf8), .unsupportedFormat(futureFormat))
        ]
        for (bytes, reason) in cases {
            let e = EditorHarness()
            try e.h.files.write(bytes, at: "a.md")
            try e.h.index.rebuild()
            let selection = e.selection(try e.h.library.load(at: "a.md"))
            e.ui { e.model.open(selection) }
            XCTAssertEqual(e.model.state.readOnlyReason, reason, "reason: \(reason)")
            XCTAssertFalse(e.model.state.canEdit, "reason: \(reason)")
            XCTAssertFalse(e.model.state.canSave, "reason: \(reason)")
            if reason != .unsupportedFormat(futureFormat) { XCTAssertNil(e.model.state.source, "reason: \(reason)") }
            let accessCount = e.h.files.accessCount
            let source = e.model.state.source
            e.ui { e.model.edit("Replacement"); e.model.save() }
            XCTAssertEqual(e.model.state.status, .failed(.readOnly(reason)), "reason: \(reason)")
            XCTAssertEqual(e.model.state.source, source, "reason: \(reason)")
            XCTAssertFalse(e.model.state.isDirty, "reason: \(reason)")
            XCTAssertEqual(e.h.files.accessCount, accessCount, "reason: \(reason)")
            XCTAssertEqual(try e.h.files.read(at: "a.md"), bytes, "reason: \(reason)")
        }
    }

    func testHistoryMaintenanceFailureIsCommittedAndDoesNotRetryWrite() throws {
        let e = EditorHarness()
        try e.open()
        e.h.dataFiles.onList = {
            if try e.h.files.text(at: "a.md").hasSuffix("Mine") { throw FileStoreError.ioFailure }
        }
        e.ui { e.model.edit("Mine"); e.model.save() }
        XCTAssertEqual(e.model.state.status, .saved)
        XCTAssertTrue(e.model.state.historyMaintenanceFailed)
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertEqual(e.model.state.stamp, try e.h.files.stamp(at: "a.md"))
        XCTAssertEqual(e.model.state.source, try e.h.files.text(at: "a.md"))
        e.h.dataFiles.onList = nil
        let committed = try XCTUnwrap(e.model.state.source)
        e.ui { e.model.edit(committed + " Next"); e.model.save() }
        XCTAssertFalse(e.model.state.historyMaintenanceFailed)
        XCTAssertNil(e.model.state.conflict)
    }

    func testEditsDuringSaveRemainDirtyAgainstNewCommittedBaseline() throws {
        let e = EditorHarness(heldWork: true)
        try e.open()
        e.ui { e.model.edit("Saved draft"); e.model.save(); e.model.edit("Newer draft") }
        XCTAssertEqual(e.model.state.status, .saving)
        e.settle()
        XCTAssertEqual(e.model.state.status, .saved)
        XCTAssertEqual(e.model.state.source, "Newer draft")
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertEqual(e.model.state.stamp, try e.h.files.stamp(at: "a.md"))
        XCTAssertTrue(try e.h.files.text(at: "a.md").hasSuffix("Saved draft"))
        e.ui { e.model.save() }
        e.settle()
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertNil(e.model.state.conflict)
        XCTAssertTrue(try e.h.files.text(at: "a.md").hasSuffix("Newer draft"))
    }

    func testSaveAsCopyAdoptsNewSessionWithoutChangingOriginal() throws {
        let e = EditorHarness()
        let original = try e.open("---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\nOriginal")
        let originalBytes = try e.h.files.read(at: "a.md")
        let originalSource = try XCTUnwrap(e.model.state.source)
        e.ui { e.model.edit(originalSource + " Mine"); e.model.saveAsCopy() }
        XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath("a 2.md"))
        XCTAssertEqual(e.model.state.lastCopy, e.model.state.prompt)
        XCTAssertNotEqual(e.model.state.prompt?.identity, original.identity)
        XCTAssertEqual(e.model.state.status, .saved)
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertEqual(try e.h.files.read(at: "a.md"), originalBytes)
        let committed = try XCTUnwrap(e.model.state.source)
        e.ui { e.model.edit(committed + " Next"); e.model.save() }
        XCTAssertNil(e.model.state.conflict)
        XCTAssertTrue(try e.h.files.text(at: "a 2.md").hasSuffix("Mine Next"))
        try e.change("External original")
        XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath("a 2.md"))
    }

    func testEditsDuringCopyStayOnOriginalWithCopyResultExposed() throws {
        let e = EditorHarness(heldWork: true)
        let original = try e.open()
        e.ui { e.model.edit("Copy draft"); e.model.saveAsCopy(); e.model.edit("New draft") }
        e.settle()
        XCTAssertEqual(e.model.state.prompt, original)
        XCTAssertEqual(e.model.state.lastCopy?.relativePath, RelativePath("a 2.md"))
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertEqual(e.model.state.source, "New draft")
        XCTAssertTrue(try e.h.files.text(at: "a 2.md").hasSuffix("Copy draft"))
        XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original")
    }

    func testFailedCopyRetainsOriginalDraftAndCommittedCopyHistoryWarningAdoptsCopy() throws {
        let e = EditorHarness()
        let original = try e.open()
        e.ui { e.model.edit("Copy") }
        e.h.files.failNextWrite = true
        e.ui { e.model.saveAsCopy() }
        XCTAssertEqual(e.model.state.status, .failed(.editing(.fileStore(.ioFailure))))
        XCTAssertEqual(e.model.state.prompt, original)
        XCTAssertTrue(e.model.state.isDirty)
        XCTAssertNil(e.model.state.lastCopy)
        e.h.dataFiles.onList = {
            if try e.h.files.stamp(at: "a 2.md") != nil { throw FileStoreError.ioFailure }
        }
        e.ui { e.model.saveAsCopy() }
        XCTAssertEqual(e.model.state.status, .saved)
        XCTAssertTrue(e.model.state.historyMaintenanceFailed)
        XCTAssertEqual(e.model.state.prompt?.relativePath, RelativePath("a 2.md"))
        XCTAssertFalse(e.model.state.isDirty)
        XCTAssertEqual(try e.h.files.text(at: "a.md"), "Original")
    }

    func testFailedLoadAndMissingPromptRemainTypedOrCloseSilently() throws {
        let e = EditorHarness()
        let selection = try e.put("Original")
        e.h.files.onRead = { _ in throw FileStoreError.ioFailure }
        e.ui { e.model.open(selection) }
        XCTAssertEqual(e.model.state.status, .failed(.editing(.fileStore(.ioFailure))))
        XCTAssertNil(e.model.state.source)
        e.h.files.onRead = nil
        e.ui { e.model.revert() }
        XCTAssertEqual(e.model.state.source, "Original")
        e.ui { e.model.close() }
        try e.h.files.delete(at: "a.md")
        e.ui { e.model.open(selection) }
        XCTAssertNil(e.model.state.prompt)
        XCTAssertEqual(e.model.state.status, .idle)
    }
}
