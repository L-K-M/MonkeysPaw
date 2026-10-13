import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class PasteboardClipboardRestoreTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var clipboard: PasteboardClipboard!

    override func setUp() {
        super.setUp()
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertTrue(AppDelegate.isRunningTests)
        pasteboard = NSPasteboard(name: .init("ch.lkmc.monkeyspaw.restore-tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        clipboard = PasteboardClipboard(pasteboard: pasteboard)
    }

    override func tearDown() {
        clipboard = nil
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    func testRestoresUnicodeMultilineTextAndOwnWriteRevision() throws {
        let previous = "Café 🐒\n日本語\nآخر سطر"
        replace(with: previous)
        let priorCount = pasteboard.changeCount
        let snapshot = try XCTUnwrap(capture())
        XCTAssertEqual(snapshot.withText { $0 }, previous)
        XCTAssertEqual(pasteboard.changeCount, priorCount, "Snapshotting must not write")

        let ownership = try XCTUnwrap(clipboard.writeTextOwning("delivered", after: snapshot.revision))
        let writtenCount = pasteboard.changeCount
        XCTAssertNotEqual(writtenCount, priorCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "delivered")

        clipboard.restore(snapshot, ifOwnedBy: ownership)
        XCTAssertEqual(pasteboard.string(forType: .string), previous)
        XCTAssertNotEqual(pasteboard.changeCount, writtenCount)

        let restoredCount = pasteboard.changeCount
        clipboard.restore(snapshot, ifOwnedBy: ownership)
        XCTAssertEqual(pasteboard.changeCount, restoredCount, "Ownership cannot be reused after restore")
    }

    func testNewerDifferentCopySkipsRestore() throws {
        try assertNewerCopySkipsRestore("new copy")
    }

    func testNewerIdenticalCopySkipsRestore() throws {
        try assertNewerCopySkipsRestore("delivered")
    }

    func testNewerEmptyCopySkipsRestore() throws {
        try assertNewerCopySkipsRestore("")
    }

    func testClearedPasteboardSkipsRestore() throws {
        replace(with: "previous")
        let snapshot = try XCTUnwrap(capture())
        let ownership = try XCTUnwrap(clipboard.writeTextOwning("delivered", after: snapshot.revision))
        pasteboard.clearContents()
        let changedCount = pasteboard.changeCount

        clipboard.restore(snapshot, ifOwnedBy: ownership)
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(pasteboard.changeCount, changedCount)
    }

    func testStaleSnapshotStillWritesButHasNoOwnership() throws {
        replace(with: "previous")
        let snapshot = try XCTUnwrap(capture())
        replace(with: "previous")

        XCTAssertNil(clipboard.writeTextOwning("delivered", after: snapshot.revision))
        XCTAssertEqual(pasteboard.string(forType: .string), "delivered")
    }

    func testRevisionAndOwnershipBelongToOneDriver() throws {
        replace(with: "previous")
        let snapshot = try XCTUnwrap(capture())
        let otherDriver = PasteboardClipboard(pasteboard: pasteboard)
        XCTAssertNil(otherDriver.writeTextOwning("delivered", after: snapshot.revision))
        XCTAssertEqual(pasteboard.string(forType: .string), "delivered")

        let current = try XCTUnwrap(capture())
        let ownership = try XCTUnwrap(clipboard.writeTextOwning("next delivery", after: current.revision))
        let writtenCount = pasteboard.changeCount
        otherDriver.restore(current, ifOwnedBy: ownership)
        clipboard.restore(snapshot, ifOwnedBy: ownership)
        XCTAssertEqual(pasteboard.string(forType: .string), "next delivery")
        XCTAssertEqual(pasteboard.changeCount, writtenCount)
    }

    func testUnknownRevisionStillWritesWithoutOwnership() {
        replace(with: "previous")
        XCTAssertNil(clipboard.writeTextOwning("delivered", after: UnknownRevision()))
        XCTAssertEqual(pasteboard.string(forType: .string), "delivered")
    }

    func testUnknownOwnershipSkipsRestore() throws {
        replace(with: "previous")
        let snapshot = try XCTUnwrap(capture())
        clipboard.writeText("delivered")
        let writtenCount = pasteboard.changeCount

        clipboard.restore(snapshot, ifOwnedBy: UnknownOwnership())
        XCTAssertEqual(pasteboard.string(forType: .string), "delivered")
        XCTAssertEqual(pasteboard.changeCount, writtenCount)
    }

    func testAbsentEmptyAndNonTextContentHaveNoSnapshot() {
        XCTAssertNil(capture())
        replace(with: "")
        XCTAssertNil(capture())
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([1, 2, 3]), forType: .png))
        let count = pasteboard.changeCount
        XCTAssertNil(capture())
        XCTAssertEqual(pasteboard.changeCount, count)
    }

    func testUnreadableUTF8HasNoSnapshot() {
        XCTAssertTrue(pasteboard.setData(Data([0xFF, 0xFE, 0xFF]), forType: .string))
        let count = pasteboard.changeCount
        XCTAssertNil(capture())
        XCTAssertEqual(pasteboard.changeCount, count)
    }

    func testSnapshotUsesUTF8ByteLimit() throws {
        let previous = "🐒\nété"
        replace(with: previous)
        let byteCount = previous.utf8.count
        XCTAssertGreaterThan(byteCount, previous.count)
        XCTAssertNil(capture(byteLimit: byteCount - 1))
        XCTAssertEqual(try XCTUnwrap(capture(byteLimit: byteCount)).withText { $0 }, previous)
    }

    func testExpiredBudgetAndInvalidLimitHaveNoSnapshot() {
        replace(with: "previous")
        let count = pasteboard.changeCount
        XCTAssertNil(capture(budget: .zero))
        XCTAssertNil(capture(budget: .milliseconds(-1)))
        XCTAssertNil(capture(byteLimit: 0))
        XCTAssertNil(capture(byteLimit: -1))
        XCTAssertEqual(pasteboard.changeCount, count)
    }

    func testLatePromisedTextHasNoSnapshot() {
        let provider = SlowTextProvider()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.string]))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let count = pasteboard.changeCount

        XCTAssertNil(capture(budget: .milliseconds(1)))
        XCTAssertEqual(provider.reads, 1)
        XCTAssertEqual(pasteboard.changeCount, count)
    }

    func testInlineCompletionAndCancellationDoNotRetainSnapshot() {
        replace(with: "previous")
        weak var captured: ClipboardTextSnapshot?
        var completions = 0
        let read = clipboard.snapshotText(budget: Limits.clipboardSnapshotBudget,
                                          byteLimit: Limits.clipboardSnapshotMaxBytes) { snapshot in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNotNil(snapshot)
            captured = snapshot
            completions += 1
        }

        XCTAssertEqual(completions, 1)
        XCTAssertNil(captured, "The driver and completed read must not keep prior text alive")
        read.cancel()
        read.cancel()
        XCTAssertEqual(completions, 1)
    }

    func testRestoreAndSkipDoNotRetainSnapshot() throws {
        for newerCopy in [false, true] {
            replace(with: "previous")
            var snapshot: ClipboardTextSnapshot? = try XCTUnwrap(capture())
            weak var released = snapshot
            let ownership = try XCTUnwrap(clipboard.writeTextOwning("delivered", after: try XCTUnwrap(snapshot).revision))
            if newerCopy { replace(with: "new copy") }

            clipboard.restore(try XCTUnwrap(snapshot), ifOwnedBy: ownership)
            snapshot = nil
            XCTAssertNil(released)
            XCTAssertEqual(pasteboard.string(forType: .string), newerCopy ? "new copy" : "previous")
        }
    }

    func testOrdinaryClipboardReadAndWriteUseInjectedPasteboard() {
        clipboard.writeText("ordinary\n🐒")
        clipboard.readText { text in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(text, "ordinary\n🐒")
        }

        clipboard.writeText("")
        clipboard.readText { XCTAssertNil($0) }
    }

    private func replace(with text: String) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
    }

    private func capture(budget: Duration = Limits.clipboardSnapshotBudget,
                         byteLimit: Int = Limits.clipboardSnapshotMaxBytes) -> ClipboardTextSnapshot? {
        var result: ClipboardTextSnapshot?
        var completions = 0
        _ = clipboard.snapshotText(budget: budget, byteLimit: byteLimit) {
            XCTAssertTrue(Thread.isMainThread)
            result = $0
            completions += 1
        }
        XCTAssertEqual(completions, 1)
        return result
    }

    private func assertNewerCopySkipsRestore(_ newerText: String) throws {
        replace(with: "previous")
        let snapshot = try XCTUnwrap(capture())
        let ownership = try XCTUnwrap(clipboard.writeTextOwning("delivered", after: snapshot.revision))
        let writtenCount = pasteboard.changeCount
        replace(with: newerText)
        let changedCount = pasteboard.changeCount
        XCTAssertNotEqual(changedCount, writtenCount)

        clipboard.restore(snapshot, ifOwnedBy: ownership)
        XCTAssertEqual(pasteboard.string(forType: .string), newerText)
        XCTAssertEqual(pasteboard.changeCount, changedCount)
    }
}

private final class UnknownRevision: ClipboardRevision {}
private final class UnknownOwnership: ClipboardWriteOwnership {}

private final class SlowTextProvider: NSObject, NSPasteboardItemDataProvider {
    private(set) var reads = 0

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        XCTAssertTrue(Thread.isMainThread)
        reads += 1
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertTrue(item.setString("late text", forType: type))
    }
}
