import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptIndexChangeTests: XCTestCase {
    func testIndependentSubscribersReceiveEveryPublishAndRemovalKeepsTheOther() throws {
        let h = PromptFlowHarness()
        let first = IndexChanges()
        let second = IndexChanges()
        let one = h.index.addObserver { first.append([]) }
        let two = h.index.addObserver { second.append([]) }
        try h.index.rebuild()
        try h.index.apply(LibraryChangeSet())
        XCTAssertEqual(first.received.count, 2)
        XCTAssertEqual(second.received.count, 2)

        h.index.removeObserver(one)
        try h.index.rebuild()
        XCTAssertEqual(first.received.count, 2)
        XCTAssertEqual(second.received.count, 3)
        h.index.removeObserver(two)
        try h.index.rebuild()
        XCTAssertEqual(second.received.count, 3)
    }

    func testRemovalDuringPublishSkipsRemovedSubscriberAndAllowsReentry() throws {
        let h = PromptFlowHarness()
        let second = IndexChanges()
        let tokens = IndexTokens()
        let index = h.index
        tokens.first = index.addObserver { [weak index] in
            _ = index?.search("")
            index?.removeObserver(tokens.first!)
            index?.removeObserver(tokens.second!)
        }
        tokens.second = index.addObserver { second.append([]) }
        try index.rebuild()
        try index.rebuild()
        XCTAssertTrue(second.received.isEmpty)
    }

    func testSubscribersInstalledDuringReadReceiveCompletedLatestPublication() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Before")
        let changes = IndexChanges()
        let index = h.index
        h.library.onRead = { [weak index] _ in
            h.library.onRead = nil
            _ = index?.addObserver { [weak index] in
                changes.append(index?.search("").map(\.relativePath) ?? [])
            }
        }
        defer { h.library.onRead = nil }
        try index.rebuild()
        XCTAssertEqual(changes.received, [["a.md"]])
    }

    func testSubscriberAddedDuringCallbackWaitsUntilNextPublish() throws {
        let h = PromptFlowHarness()
        let changes = IndexChanges()
        let index = h.index
        let tokens = IndexTokens()
        tokens.first = index.addObserver { [weak index] in
            index?.removeObserver(tokens.first!)
            tokens.second = index?.addObserver { changes.append([]) }
        }
        try index.rebuild()
        XCTAssertTrue(changes.received.isEmpty)
        try index.rebuild()
        XCTAssertEqual(changes.received.count, 1)
    }

    func testCompatibilityShimClearsOnlyItsSubscriptionAndPreservesPicker() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Body")
        try h.open()
        let independent = IndexChanges()
        let compatibility = IndexChanges()
        h.index.addObserver { independent.append([]) }
        h.index.setOnChange { compatibility.append([]) }
        try h.index.rebuild()
        h.index.setOnChange(nil)
        _ = try h.put("Second", at: "b.md")
        try h.index.apply(LibraryChangeSet(created: ["b.md"]))
        XCTAssertEqual(independent.received.count, 2)
        XCTAssertEqual(compatibility.received.count, 1)
        XCTAssertEqual(h.picker.results.count, 2)
    }

    func testUsageNotificationCanReenterIndexAfterRankingCacheCommits() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Alpha", at: "a.md")
        let used = try h.put("Beta", at: "b.md")
        try h.index.rebuild()
        let changes = IndexChanges()
        let index = h.index
        let token = h.usage.addObserver { [weak index] in
            changes.append(index?.search("").map(\.relativePath) ?? [])
        }
        try index.recordUse(of: used.identity)
        XCTAssertEqual(changes.received, [["b.md", "a.md"]])
        h.usage.removeObserver(token)
    }

    func testEachSuccessfulPublishNotifiesOnceAfterUnlockAndRecordUseIsQuiet() throws {
        let h = PromptFlowHarness()
        _ = try h.put("Alpha", at: "a.md")
        let used = try h.put("Beta", at: "b.md")
        let changes = IndexChanges()
        let index = h.index
        index.setOnChange(nil) // clear only the compatibility subscription
        index.setOnChange { [weak index] in
            XCTAssertTrue(changes.isOwnerThread)
            // Search re-entry would deadlock if publication held the index lock.
            changes.append(index?.search("").map(\.relativePath) ?? [])
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
        h.index.setOnChange(nil)
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

    func testHookCanTransferOwnershipAfterClearAndUnsubscribe() throws {
        let h = PromptFlowHarness()
        let first = IndexChanges()
        let second = IndexChanges()
        let index = h.index
        index.setOnChange(nil)
        index.setOnChange { first.append([]) }
        index.setOnChange(nil)
        index.setOnChange { [weak index] in
            second.append([])
            index?.setOnChange(nil) // also safe to re-enter callback ownership
        }
        try index.rebuild()
        try index.rebuild()
        XCTAssertTrue(first.received.isEmpty)
        XCTAssertEqual(second.received.count, 1)
    }

    func testIndexDoesNotKeepItsPickerOwnerAlive() {
        let h = PromptFlowHarness()
        h.index.setOnChange(nil)
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

private final class IndexTokens: @unchecked Sendable {
    var first: UUID?
    var second: UUID?
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
