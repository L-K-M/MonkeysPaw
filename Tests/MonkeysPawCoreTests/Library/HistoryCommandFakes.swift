import Foundation
import XCTest
@testable import MonkeysPawCore

enum HistoryTestCommand: CaseIterable {
    case rename, move, delete, restore

    var action: EditorDiscardAction {
        switch self { case .rename: return .rename; case .move: return .move; case .delete: return .delete; case .restore: return .revert }
    }

    var destination: String {
        switch self { case .rename: return "renamed.md"; case .move: return "one/two/a.md"; case .delete, .restore: return "a.md" }
    }

    func run(_ service: PromptEditingService, session: PromptEditingSession, stamp: FileStamp,
             revision: HistoryRevision, completion: @escaping (PromptCommandOutcome) -> Void) {
        switch self {
        case .rename: service.rename(to: "renamed.md", session: session, expectedStamp: stamp, completion: completion)
        case .move: service.move(to: "one/two", session: session, expectedStamp: stamp, completion: completion)
        case .delete: service.delete(session: session, expectedStamp: stamp, completion: completion)
        case .restore: service.restore(revision, session: session, expectedStamp: stamp, completion: completion)
        }
    }

}

let historyCommandSource = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\ntitle: Title\n---\nOriginal\r\n"

@discardableResult
func historySnapshot(_ h: PromptEditingHarness, identity: PromptIdentity,
                     bytes: Data = Data("Previous\r\n".utf8)) throws -> HistoryRevision {
    try HistoryStore(files: h.data).snapshot(bytes, for: identity, at: h.clock.date)
}

func commandResult(_ h: PromptEditingHarness, _ run: (@escaping (PromptCommandOutcome) -> Void) -> Void,
                   file: StaticString = #filePath, line: UInt = #line) throws -> PromptCommandOutcome {
    var result: PromptCommandOutcome?
    h.marker.ui { run { result = $0; XCTAssertTrue(h.marker.isUI, file: file, line: line) } }
    h.held.releaseAll()
    h.main.releaseAll()
    return try XCTUnwrap(result, file: file, line: line)
}
