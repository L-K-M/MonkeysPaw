import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptIndexChangeTests: XCTestCase {
    func testEachSuccessfulPublishNotifiesOnceAfterUnlockAndRecordUseIsQuiet() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Alpha", at: "a.md")
        let used = try h.put("Beta", at: "b.md")
        let changes = IndexChanges()
        let index = h.index
        index.setOnChange {
            XCTAssertTrue(changes.isOwnerThread)
            // Search re-entry would deadlock if publication held the index lock.
            changes.append(index.search("").map(\.relativePath))
        }
        try index.rebuild()
        XCTAssertEqual(changes.received, [["a.md", "b.md"]])
        try index.recordUse(of: used.identity)
        XCTAssertEqual(changes.received.count, 1)
        XCTAssertEqual(index.search("").map(\.relativePath), ["b.md", "a.md"])
        try index.apply(LibraryChangeSet())
        XCTAssertEqual(changes.received, [["a.md", "b.md"], ["b.md", "a.md"]])
        try h.library.delete(at: "a.md")
        try index.apply(LibraryChangeSet(deleted: ["a.md"]))
        XCTAssertEqual(changes.received.last, ["b.md"])
        XCTAssertEqual(changes.received.count, 3)
    }

    func testFailedRebuildAndApplyNeverNotifyOrPublish() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Before")
        let changes = IndexChanges()
        h.index.setOnChange { changes.append(["published"]) }
        try h.index.rebuild()
        try h.library.put("After", at: "a.md")
        h.library.onRead = { _ in throw FileStoreError.ioFailure }
        XCTAssertThrowsError(try h.index.rebuild())
        XCTAssertThrowsError(try h.index.apply(LibraryChangeSet(modified: ["a.md"])))
        XCTAssertEqual(changes.received.count, 1)
        XCTAssertEqual(h.index.search("before").count, 1)
        XCTAssertEqual(h.index.search("after").count, 0)
    }

    func testHookHasOneOwnerAndCanReplaceItselfOrUnsubscribe() throws {
        let h = PromptFlowHarness()
        let first = IndexChanges()
        let second = IndexChanges()
        let index = h.index
        index.setOnChange { first.append([]) }
        index.setOnChange {
            second.append([])
            index.setOnChange(nil) // also safe to re-enter callback ownership
        }
        try index.rebuild()
        try index.rebuild()
        XCTAssertTrue(first.received.isEmpty)
        XCTAssertEqual(second.received.count, 1)
    }

    func testIndexDoesNotKeepItsPickerOwnerAlive() {
        let h = PromptFlowHarness()
        weak var owner: PickerModel?
        do {
            let picker = PickerModel(index: h.index, fill: h.fill, delivery: h.delivery.service,
                                     main: h.delivery.main)
            owner = picker
            XCTAssertNotNil(owner)
        }
        XCTAssertNil(owner)
    }
}

private final class IndexChanges: @unchecked Sendable {
    private let owner = Thread.current
    private let lock = NSLock()
    private var snapshots: [[String]] = []
    var isOwnerThread: Bool { Thread.current === owner }
    var received: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }
    func append(_ snapshot: [String]) {
        lock.lock()
        defer { lock.unlock() }
        snapshots.append(snapshot)
    }
}
