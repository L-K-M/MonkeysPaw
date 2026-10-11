#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawLinux

final class GTKClipboardTests: XCTestCase {
    func testReadReturnsTextOnceAsynchronouslyOnOwningThread() throws {
        try GTKTestSupport.requireDisplay()
        let owner = try XCTUnwrap(gtk_window_new())
        defer { gtk_window_destroy(mp_window(owner)) }
        let clipboard = GTKClipboard(owner: owner)
        clipboard.writeText("Unicode ☃\n{{raw}}")
        let reads = ClipboardReads()
        clipboard.readText { reads.append($0) }
        XCTAssertTrue(reads.values.isEmpty)
        XCTAssertTrue(GTKTestSupport.spin { reads.values.count == 1 })
        XCTAssertEqual(reads.values, ["Unicode ☃\n{{raw}}"])
        _ = GTKTestSupport.spin(until: { false }, timeout: .milliseconds(30))
        XCTAssertEqual(reads.values.count, 1)
    }

    func testEmptyAndUnavailableClipboardReturnNilExactlyOnce() throws {
        try GTKTestSupport.requireDisplay()
        let owner = try XCTUnwrap(gtk_window_new())
        defer { gtk_window_destroy(mp_window(owner)) }
        let clipboard = GTKClipboard(owner: owner)
        clipboard.writeText("")
        let empty = ClipboardReads()
        clipboard.readText { empty.append($0) }
        XCTAssertTrue(GTKTestSupport.spin { empty.values.count == 1 })
        XCTAssertEqual(empty.values, [nil])
        _ = gdk_clipboard_set_content(gtk_widget_get_clipboard(owner), nil)
        let unavailable = ClipboardReads()
        clipboard.readText { unavailable.append($0) }
        XCTAssertTrue(GTKTestSupport.spin { unavailable.values.count == 1 })
        XCTAssertEqual(unavailable.values, [nil])
    }

    func testShimCompletesAndDestroysBoxOnThreadDefaultContextAfterOwnerCloses() throws {
        try GTKTestSupport.requireDisplay()
        let context = try XCTUnwrap(g_main_context_new())
        g_main_context_push_thread_default(context)
        defer {
            g_main_context_pop_thread_default(context)
            g_main_context_unref(context)
        }
        let owner = try XCTUnwrap(gtk_window_new())
        GTKClipboard(owner: owner).writeText("snapshot")
        let reads = ClipboardReads()
        let box = Unmanaged.passRetained(reads).toOpaque()
        mp_clipboard_read_text(owner, { text, data in
            guard let data else { return }
            Unmanaged<ClipboardReads>.fromOpaque(data).takeUnretainedValue()
                .append(text.map { String(cString: $0) })
        }, box, { data in
            guard let data else { return }
            let box = Unmanaged<ClipboardReads>.fromOpaque(data)
            box.takeUnretainedValue().destroyed()
            box.release()
        })
        gtk_window_destroy(mp_window(owner))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        // Pump only the owning context, never the global GTK context.
        while reads.destroyCount == 0, ContinuousClock.now < deadline {
            _ = g_main_context_iteration(context, 0)
            Thread.sleep(forTimeInterval: 0.002)
        }
        XCTAssertEqual(reads.values, ["snapshot"])
        XCTAssertEqual(reads.destroyCount, 1)
    }
}

private final class ClipboardReads: @unchecked Sendable {
    private let owner = Thread.current
    private let lock = NSLock()
    private var text: [String?] = []
    private var destroys = 0

    var values: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
    var destroyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return destroys
    }
    func append(_ value: String?) {
        XCTAssertTrue(Thread.current === owner)
        lock.lock()
        defer { lock.unlock() }
        text.append(value)
    }
    func destroyed() {
        XCTAssertTrue(Thread.current === owner)
        lock.lock()
        defer { lock.unlock() }
        destroys += 1
    }
}
#endif
