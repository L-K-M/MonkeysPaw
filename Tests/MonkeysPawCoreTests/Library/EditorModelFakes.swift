import Foundation
import XCTest
@testable import MonkeysPawCore

final class EditorHarness {
    let h: PromptEditingHarness
    let model: EditorModel
    init(heldWork: Bool = false, queuedMain: Bool = false, timeZone: @escaping () -> TimeZone = { .gmt }) {
        h = PromptEditingHarness(heldWork: heldWork)
        h.clock.date = Date(timeIntervalSince1970: 0)
        model = EditorModel(editing: h.editor, clock: h.clock,
                            timeZone: timeZone, main: h.main)
        h.main.isHeld = queuedMain
    }

    @discardableResult
    func put(_ source: String, at path: String = "a.md") throws -> LibraryPromptSelection {
        try h.files.put(source, at: path)
        try h.index.rebuild()
        return selection(try h.library.load(at: path))
    }

    @discardableResult
    func open(_ source: String = "Original", at path: String = "a.md") throws -> LibraryPromptSelection {
        let selection = try put(source, at: path)
        ui { model.open(selection) }
        settle()
        return selection
    }

    func ui(_ work: () -> Void) { h.marker.ui(work) }

    func settle(file: StaticString = #filePath, line: UInt = #line) {
        let maximumSteps = 1_000
        for _ in 0..<maximumSteps {
            if h.held.pending.isEmpty && h.main.pending.isEmpty { return }
            if !h.held.pending.isEmpty { h.held.releaseNext() }
            if !h.main.pending.isEmpty { h.main.releaseNext() }
        }
        XCTFail("Editor queues did not settle within \(maximumSteps) steps.", file: file, line: line)
    }

    func change(_ source: String?, at path: String = "a.md") throws {
        if let source {
            try h.files.put(source, at: path)
            try h.index.apply(LibraryChangeSet(modified: [RelativePath(path)]))
        } else {
            try h.files.delete(at: path)
            try h.index.apply(LibraryChangeSet(deleted: [RelativePath(path)]))
        }
    }

    func selection(_ entry: LibraryEntry) -> LibraryPromptSelection {
        LibraryPromptSelection(identity: entry.identity, relativePath: RelativePath(entry.relativePath))
    }

    func decide(_ choice: EditorDecision, file: StaticString = #filePath, line: UInt = #line) throws {
        let decision = try XCTUnwrap(model.state.pendingDecision, file: file, line: line)
        ui { model.resolveDecision(choice, id: decision.id) }
    }
}
