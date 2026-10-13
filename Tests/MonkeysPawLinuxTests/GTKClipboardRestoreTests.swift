#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class GTKClipboardRestoreTests: XCTestCase {
    func testOwnWriteRestoresPreviousTextAfterDelayAndMainLoopDispatch() throws {
        try GTKTestSupport.requireDisplay()
        let owner = try XCTUnwrap(gtk_window_new())
        defer { gtk_window_destroy(mp_window(owner)) }
        let clipboard = GTKClipboard(owner: owner)
        let restoring: ClipboardRestoring = clipboard
        clipboard.writeText("Previous ☃\n{{raw}}")
        settleClipboard()
        var snapshots: [ClipboardTextSnapshot?] = []
        let read = restoring.snapshotText(
            budget: Limits.clipboardSnapshotBudget, byteLimit: Limits.clipboardSnapshotMaxBytes
        ) { snapshots.append($0) }
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertTrue(GTKTestSupport.spin { snapshots.count == 1 })
        let snapshot = try XCTUnwrap(snapshots.first ?? nil)
        let ownership = try XCTUnwrap(restoring.writeTextOwning("Delivered", after: snapshot.revision))
        var didRestore = false
        GTK.after(Limits.clipboardRestoreDelay.timeInterval) {
            restoring.restore(snapshot, ifOwnedBy: ownership)
            didRestore = true
        }
        XCTAssertTrue(GTKTestSupport.spin { didRestore })

        let result = RestoreTextReads()
        clipboard.readText { result.append($0) }
        XCTAssertTrue(GTKTestSupport.spin { result.values.count == 1 })
        XCTAssertEqual(result.values, ["Previous ☃\n{{raw}}"])
        withExtendedLifetime(read) {}
    }

    func testReadableEmptyTextCanBeRestored() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("")
        let snapshot = try snapshot(fixture.driver)
        XCTAssertEqual(snapshot.withText { $0 }, "")
        let token = try XCTUnwrap(fixture.driver.writeTextOwning("Delivered", after: snapshot.revision))
        fixture.driver.restore(snapshot, ifOwnedBy: token)
        XCTAssertEqual(try self.snapshot(fixture.driver).withText { $0 }, "")
        // Preserve the base Clipboard contract: its empty read still returns nil.
        XCTAssertNil(try text(fixture.driver))
    }

    func testMissingAndNonTextClipboardCompleteOnceWithNil() throws {
        let fixture = try ClipboardFixture()
        XCTAssertNil(try capture(fixture.driver))
        try publish([1, 2, 3], mime: "application/octet-stream", on: fixture.native)
        XCTAssertNil(try capture(fixture.driver))
    }

    func testUTF8ByteCapAcceptsExactLimitAndRejectsOversize() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("☃")
        XCTAssertEqual(try capture(fixture.driver, byteLimit: 3)?.withText { $0 }, "☃")
        XCTAssertNil(try capture(fixture.driver, byteLimit: 2))
        fixture.driver.writeText("")
        XCTAssertEqual(try capture(fixture.driver, byteLimit: 0)?.withText { $0 }, "")
        fixture.driver.writeText("x")
        XCTAssertNil(try capture(fixture.driver, byteLimit: 0))
    }

    func testNativeReceiptIsBoundedBeforeDecode() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText(String(repeating: "x", count: Limits.clipboardSnapshotMaxBytes))
        XCTAssertEqual(try capture(fixture.driver, budget: .seconds(3))?.withText { $0.utf8.count },
                       Limits.clipboardSnapshotMaxBytes)
        fixture.driver.writeText(String(repeating: "x", count: Limits.clipboardSnapshotMaxBytes + 1))
        XCTAssertNil(try capture(fixture.driver, budget: .seconds(3), byteLimit: Int.max))
    }

    func testInvalidUTF8AndEmbeddedNULNeverBecomePartialSnapshots() throws {
        let fixture = try ClipboardFixture()
        for bytes: [UInt8] in [[0xff], [0xe2, 0x98], [65, 0, 66], [0], [0, 65], [65, 0],
                              Array("abc\0def".utf8)] {
            try publish(bytes, on: fixture.native)
            XCTAssertNil(try capture(fixture.driver))
        }
    }

    func testCancelledReadCompletesOnceAndReleasesCompletionImmediately() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("Previous")
        var results: [ClipboardTextSnapshot?] = []
        weak var captured: Lifetime?
        var read: ClipboardSnapshotRead?
        do {
            let lifetime = Lifetime()
            captured = lifetime
            read = fixture.driver.snapshotText(budget: .seconds(3), byteLimit: 100) { snapshot in
                withExtendedLifetime(lifetime) { results.append(snapshot) }
            }
        }
        weak var pending = read
        XCTAssertTrue(results.isEmpty)
        read?.cancel()
        read?.cancel()
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first ?? nil)
        XCTAssertNil(captured)
        read = nil
        XCTAssertTrue(GTKTestSupport.spin { pending == nil })
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try text(fixture.driver), "Previous")
    }

    func testCancelAfterSuccessDoesNotCallBackAgain() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("Previous")
        settleClipboard()
        var results: [ClipboardTextSnapshot?] = []
        var read: ClipboardSnapshotRead? = fixture.driver.snapshotText(budget: .seconds(3), byteLimit: 100) {
            results.append($0)
        }
        weak var pending = read
        XCTAssertTrue(GTKTestSupport.spin { results.count == 1 })
        XCTAssertNotNil(results.first ?? nil)
        read?.cancel()
        read = nil
        XCTAssertTrue(GTKTestSupport.spin { pending == nil })
        XCTAssertEqual(results.count, 1)
    }

    func testChangedCaptureRevisionIncludingIdenticalTextReturnsNil() throws {
        let fixture = try ClipboardFixture()
        let other = try ClipboardFixture()
        fixture.driver.writeText("Previous")
        var results: [ClipboardTextSnapshot?] = []
        let read = fixture.driver.snapshotText(budget: .seconds(3), byteLimit: 100) { results.append($0) }
        other.driver.writeText("Previous")
        XCTAssertTrue(GTKTestSupport.spin { results.count == 1 })
        XCTAssertNil(results.first ?? nil)
        read.cancel()
        XCTAssertEqual(results.count, 1)
    }

    func testStaleRevisionStillWritesDeliveredTextWithoutOwnership() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("Previous")
        let snapshot = try snapshot(fixture.driver)
        fixture.driver.writeText("Previous")
        XCTAssertNil(fixture.driver.writeTextOwning("Delivered", after: snapshot.revision))
        XCTAssertEqual(try text(fixture.driver), "Delivered")
    }

    func testTwoDriversRejectEachOthersRevisionsAndOwnership() throws {
        let first = try ClipboardFixture()
        let second = try ClipboardFixture()
        first.driver.writeText("Previous")
        let snapshot = try snapshot(first.driver)
        XCTAssertNil(second.driver.writeTextOwning("Delivered", after: snapshot.revision))
        XCTAssertEqual(try text(first.driver), "Delivered")

        first.driver.writeText("Previous")
        let current = try self.snapshot(first.driver)
        let token = try XCTUnwrap(first.driver.writeTextOwning("Delivered", after: current.revision))
        second.driver.restore(current, ifOwnedBy: token)
        XCTAssertEqual(try text(first.driver), "Delivered")
        first.driver.restore(current, ifOwnedBy: token)
        XCTAssertEqual(try text(first.driver), "Previous")
    }

    func testNewerIdenticalWriteSkipsRestoreForSameAndOtherDriver() throws {
        let first = try ClipboardFixture()
        let second = try ClipboardFixture()
        for writer in [first.driver, second.driver] {
            first.driver.writeText("Previous")
            let snapshot = try snapshot(first.driver)
            let token = try XCTUnwrap(first.driver.writeTextOwning("Delivered", after: snapshot.revision))
            let release = try ProviderRelease.observe(on: first.native)
            writer.writeText("Delivered")
            first.driver.restore(snapshot, ifOwnedBy: token)
            XCTAssertEqual(try text(first.driver), "Delivered")
            XCTAssertTrue(GTKTestSupport.spin { release.count == 1 })
            withExtendedLifetime(token) {}
        }
    }

    func testExternalDisplayOwnerWithIdenticalTextSkipsRestore() throws {
        let fixture = try ClipboardFixture()
        let display = try XCTUnwrap(gdk_display_get_default())
        let external = try XCTUnwrap(gdk_display_open(gdk_display_get_name(display)))
        defer { gdk_display_close(external) }
        let externalClipboard = try XCTUnwrap(gdk_display_get_clipboard(external))
        gdk_display_sync(external)
        settleClipboard()
        fixture.driver.writeText("Previous")
        let snapshot = try snapshot(fixture.driver)
        let token = try XCTUnwrap(fixture.driver.writeTextOwning("Delivered", after: snapshot.revision))
        let release = try ProviderRelease.observe(on: fixture.native)
        // Let the peer observe our write before it claims the same X11 selection.
        settleClipboard()
        gdk_clipboard_set_text(externalClipboard, "Delivered")
        gdk_display_sync(external)
        XCTAssertTrue(GTKTestSupport.spin { gdk_clipboard_is_local(fixture.native) == 0 })
        settleClipboard()
        let externalProvider = try XCTUnwrap(gdk_clipboard_get_content(externalClipboard))
        fixture.driver.restore(snapshot, ifOwnedBy: token)
        XCTAssertNil(gdk_clipboard_get_content(fixture.native))
        XCTAssertEqual(gdk_clipboard_is_local(fixture.native), 0)
        XCTAssertEqual(gdk_clipboard_get_content(externalClipboard), externalProvider)
        let probe = NativeReadProbe()
        mp_clipboard_read_text_from_clipboard(externalClipboard, NativeReadProbe.callback,
                                             Unmanaged.passRetained(probe).toOpaque(), NativeReadProbe.destroy)
        XCTAssertTrue(GTKTestSupport.spin { probe.destroys == 1 })
        XCTAssertEqual(probe.values, ["Delivered"])
        XCTAssertTrue(GTKTestSupport.spin { release.count == 1 })
    }

    func testProviderLossSkipsRestoreAndReleasesRetain() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("Previous")
        let snapshot = try snapshot(fixture.driver)
        let token = try XCTUnwrap(fixture.driver.writeTextOwning("Delivered", after: snapshot.revision))
        let release = try ProviderRelease.observe(on: fixture.native)
        _ = gdk_clipboard_set_content(fixture.native, nil)
        fixture.driver.restore(snapshot, ifOwnedBy: token)
        XCTAssertNil(gdk_clipboard_get_content(fixture.native))
        XCTAssertNil(try capture(fixture.driver))
        XCTAssertTrue(GTKTestSupport.spin { release.count == 1 })
        withExtendedLifetime(token) {}
    }

    func testChangedSignalInvalidatesEvenWhenProviderPointerIsUnchanged() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("Previous")
        let snapshot = try snapshot(fixture.driver)
        let token = try XCTUnwrap(fixture.driver.writeTextOwning("Delivered", after: snapshot.revision))
        let provider = try XCTUnwrap(gdk_clipboard_get_content(fixture.native))
        let release = try ProviderRelease.observe(on: fixture.native)
        gdk_content_provider_content_changed(provider)
        XCTAssertEqual(gdk_clipboard_get_content(fixture.native), provider)
        fixture.driver.restore(snapshot, ifOwnedBy: token)
        XCTAssertEqual(try text(fixture.driver), "Delivered")
        _ = gdk_clipboard_set_content(fixture.native, nil)
        XCTAssertTrue(GTKTestSupport.spin { release.count == 1 })
    }

    func testRestoreConsumesProviderOnRestoreAndMismatchedSnapshotSkip() throws {
        let fixture = try ClipboardFixture()
        for matching in [true, false] {
            fixture.driver.writeText("Previous")
            let snapshot = try snapshot(fixture.driver)
            let token = try XCTUnwrap(fixture.driver.writeTextOwning("Delivered", after: snapshot.revision))
            let release = try ProviderRelease.observe(on: fixture.native)
            let supplied = matching ? snapshot : ClipboardTextSnapshot(text: "Other", revision: UnknownRevision())
            fixture.driver.restore(supplied, ifOwnedBy: token)
            XCTAssertEqual(try text(fixture.driver), matching ? "Previous" : "Delivered")
            _ = gdk_clipboard_set_content(fixture.native, nil)
            XCTAssertTrue(GTKTestSupport.spin { release.count == 1 })
            settleClipboard()
            // A consumed token cannot restore again even when still retained.
            fixture.driver.restore(snapshot, ifOwnedBy: token)
            XCTAssertNil(gdk_clipboard_get_content(fixture.native))
        }
    }

    func testUnknownOwnershipDoesNotReplaceDeliveredText() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("Previous")
        let snapshot = try snapshot(fixture.driver)
        fixture.driver.writeText("Delivered")
        fixture.driver.restore(snapshot, ifOwnedBy: UnknownOwnership())
        XCTAssertEqual(try text(fixture.driver), "Delivered")
    }

    func testDroppedOwnershipReleasesProviderForCoreCancellation() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("Previous")
        let snapshot = try snapshot(fixture.driver)
        var token = fixture.driver.writeTextOwning("Delivered", after: snapshot.revision)
        let release = try ProviderRelease.observe(on: fixture.native)
        weak var weakToken = token
        token = nil
        XCTAssertNil(weakToken)
        XCTAssertEqual(try text(fixture.driver), "Delivered")
        _ = gdk_clipboard_set_content(fixture.native, nil)
        XCTAssertTrue(GTKTestSupport.spin { release.count == 1 })
    }

    func testShutdownCancelsReadsOnceAndReleasesRetainedProvider() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("Previous")
        let snapshot = try snapshot(fixture.driver)
        let token = try XCTUnwrap(fixture.driver.writeTextOwning("Delivered", after: snapshot.revision))
        let release = try ProviderRelease.observe(on: fixture.native)
        var results: [ClipboardTextSnapshot?] = []
        var read: ClipboardSnapshotRead? = fixture.driver.snapshotText(budget: .seconds(3), byteLimit: 100) {
            results.append($0)
        }
        weak var pending = read
        fixture.driver.shutdown()
        fixture.driver.shutdown()
        read?.cancel()
        read = nil
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first ?? nil)
        XCTAssertTrue(GTKTestSupport.spin { pending == nil })
        fixture.driver.restore(snapshot, ifOwnedBy: token)
        XCTAssertEqual(try text(fixture.driver), "Delivered")
        XCTAssertNil(try capture(fixture.driver))
        XCTAssertEqual(release.count, 0)
        _ = gdk_clipboard_set_content(fixture.native, nil)
        XCTAssertTrue(GTKTestSupport.spin { release.count == 1 })
    }

    func testBackgroundShutdownAndCancellationCompleteOnceOnGTKThread() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("Previous")
        let thread = Thread.current
        var results: [ClipboardTextSnapshot?] = []
        let read = fixture.driver.snapshotText(budget: .seconds(3), byteLimit: 100) {
            XCTAssertTrue(Thread.current === thread)
            results.append($0)
        }
        let driver = fixture.driver
        runOnWorker {
            driver.shutdown()
            driver.shutdown()
            read.cancel()
        }
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(GTKTestSupport.spin { results.count == 1 })
        XCTAssertNil(results.first ?? nil)
        read.cancel()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try text(driver), "Previous")
        XCTAssertNil(try capture(driver))
    }

    func testBackgroundCancellationCompletesOnceOnGTKThread() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("Previous")
        let thread = Thread.current
        var results: [ClipboardTextSnapshot?] = []
        var read: ClipboardSnapshotRead? = fixture.driver.snapshotText(budget: .seconds(3), byteLimit: 100) {
            XCTAssertTrue(Thread.current === thread)
            results.append($0)
        }
        weak var pending = read
        let transfer = WorkerTransfer(try XCTUnwrap(read))
        read = nil
        runOnWorker {
            (transfer.object as? ClipboardSnapshotRead)?.cancel()
            (transfer.object as? ClipboardSnapshotRead)?.cancel()
            transfer.object = nil
        }
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(GTKTestSupport.spin { pending == nil })
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first ?? nil)
        XCTAssertEqual(try text(fixture.driver), "Previous")
    }

    func testBackgroundOwnershipReleaseWaitsForCapturedGTKContext() throws {
        try GTKTestSupport.requireDisplay()
        let context = try XCTUnwrap(g_main_context_new())
        defer { g_main_context_unref(context) }
        g_main_context_push_thread_default(context)
        let fixture = try ClipboardFixture()
        g_main_context_pop_thread_default(context)
        fixture.driver.writeText("Previous")
        var snapshots: [ClipboardTextSnapshot?] = []
        let read = fixture.driver.snapshotText(budget: .seconds(3), byteLimit: 100) { snapshots.append($0) }
        XCTAssertTrue(spin(context) { snapshots.count == 1 })
        let snapshot = try XCTUnwrap(snapshots.first ?? nil)
        var token = fixture.driver.writeTextOwning("Delivered", after: snapshot.revision)
        let release = try ProviderRelease.observe(on: fixture.native)
        weak var weakToken = token
        let transfer = WorkerTransfer(try XCTUnwrap(token))
        token = nil
        runOnWorker { transfer.object = nil }
        XCTAssertNil(weakToken)
        _ = gdk_clipboard_set_content(fixture.native, nil)
        XCTAssertEqual(release.count, 0)
        _ = g_main_context_iteration(nil, 0)
        XCTAssertEqual(release.count, 0)
        XCTAssertTrue(spin(context) { release.count == 1 })
        read.cancel()
    }

    func testBackgroundDriverDeinitTransfersTeardownWithoutRetainingDriver() throws {
        try GTKTestSupport.requireDisplay()
        let owner = try XCTUnwrap(gtk_window_new())
        let native = try XCTUnwrap(gtk_widget_get_clipboard(owner))
        defer { gtk_window_destroy(mp_window(owner)) }
        let context = try XCTUnwrap(g_main_context_new())
        defer { g_main_context_unref(context) }
        g_main_context_push_thread_default(context)
        var driver: GTKClipboard? = GTKClipboard(owner: owner)
        g_main_context_pop_thread_default(context)
        driver?.writeText("Previous")
        var snapshots: [ClipboardTextSnapshot?] = []
        let capture = driver?.snapshotText(budget: .seconds(3), byteLimit: 100) { snapshots.append($0) }
        XCTAssertTrue(spin(context) { snapshots.count == 1 })
        let snapshot = try XCTUnwrap(snapshots.first ?? nil)
        let token = try XCTUnwrap(driver?.writeTextOwning("Delivered", after: snapshot.revision))
        let release = try ProviderRelease.observe(on: native)
        let thread = Thread.current
        var results: [ClipboardTextSnapshot?] = []
        var read = driver?.snapshotText(budget: .seconds(3), byteLimit: 100) {
            XCTAssertTrue(Thread.current === thread)
            XCTAssertNotEqual(g_main_context_is_owner(context), 0)
            results.append($0)
        }
        weak var pending = read
        weak var weakDriver = driver
        let transfer = WorkerTransfer(try XCTUnwrap(driver))
        driver = nil
        runOnWorker { transfer.object = nil }
        XCTAssertNil(weakDriver)
        XCTAssertTrue(results.isEmpty)
        _ = g_main_context_iteration(nil, 0)
        XCTAssertTrue(results.isEmpty)
        read = nil
        XCTAssertTrue(spin(context) { pending == nil })
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first ?? nil)
        _ = gdk_clipboard_set_content(native, nil)
        XCTAssertTrue(GTKTestSupport.spin { release.count == 1 })
        withExtendedLifetime((capture, token)) {}
    }

    func testCoreDeliveryWorkerCallbacksReturnToGTKMainLoop() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("Previous")
        let ports = WorkerDeliveryPorts()
        let service = DeliveryService(panel: ports, focus: ports, clipboard: fixture.driver,
            injectors: [ports], notifier: ports, session: ports, scheduler: ports,
            mainThread: GLibMainThread(), failureCache: SessionPasteFailureCache(),
            clipboardRestore: .previousText)
        service.arm()
        XCTAssertTrue(GTKTestSupport.spin { ports.captures == 1 })
        var outcomes: [DeliveryOutcome] = []
        runOnWorker {
            service.deliver("Delivered", mode: .paste(.standard)) {
                XCTAssertTrue(Thread.isMainThread)
                outcomes.append($0)
            }
        }
        XCTAssertTrue(GTKTestSupport.spin { ports.hides == 1 })
        XCTAssertEqual(try text(fixture.driver), "Delivered")
        let release = try ProviderRelease.observe(on: fixture.native)
        ports.fireFromWorker(Limits.settleDelayLinux)
        XCTAssertTrue(GTKTestSupport.spin { outcomes.count == 1 })
        XCTAssertEqual(outcomes, [.pasted(.xdotool)])
        XCTAssertEqual(ports.focusRestores, 1)
        XCTAssertEqual(ports.pastes, 1)
        ports.fireFromWorker(Limits.clipboardRestoreDelay)
        XCTAssertEqual(release.count, 0)
        XCTAssertTrue(GTKTestSupport.spin { release.count == 1 })
        XCTAssertEqual(try text(fixture.driver), "Previous")

        runOnWorker { service.shutdown() }
        var drained = false
        GLibMainThread().run { drained = true }
        XCTAssertTrue(GTKTestSupport.spin { drained })
    }

    func testDriverDeinitCancelsPendingReadAndReleasesProvider() throws {
        try GTKTestSupport.requireDisplay()
        let owner = try XCTUnwrap(gtk_window_new())
        let native = try XCTUnwrap(gtk_widget_get_clipboard(owner))
        defer { gtk_window_destroy(mp_window(owner)) }
        var driver: GTKClipboard? = GTKClipboard(owner: owner)
        driver?.writeText("Previous")
        let snapshot = try snapshot(XCTUnwrap(driver))
        let token = try XCTUnwrap(driver?.writeTextOwning("Delivered", after: snapshot.revision))
        let release = try ProviderRelease.observe(on: native)
        var results: [ClipboardTextSnapshot?] = []
        var read = driver?.snapshotText(budget: .seconds(3), byteLimit: 100) { results.append($0) }
        weak var pending = read
        weak var weakDriver = driver
        driver = nil
        XCTAssertNil(weakDriver)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first ?? nil)
        read = nil
        XCTAssertTrue(GTKTestSupport.spin { pending == nil })
        _ = gdk_clipboard_set_content(native, nil)
        XCTAssertTrue(GTKTestSupport.spin { release.count == 1 })
        withExtendedLifetime(token) {}
    }

    func testLateNativeCallbackAndTimeoutStayOnCapturedContext() throws {
        try GTKTestSupport.requireDisplay()
        let context = try XCTUnwrap(g_main_context_new())
        defer { g_main_context_unref(context) }
        g_main_context_push_thread_default(context)
        let fixture = try ClipboardFixture()
        g_main_context_pop_thread_default(context)
        fixture.driver.writeText("Previous")
        var results: [ClipboardTextSnapshot?] = []
        weak var captured: Lifetime?
        var read: ClipboardSnapshotRead?
        do {
            let lifetime = Lifetime()
            captured = lifetime
            // The caller has popped its thread default; the driver retains it.
            read = fixture.driver.snapshotText(budget: .milliseconds(20), byteLimit: 100) { snapshot in
                XCTAssertNotEqual(g_main_context_is_owner(context), 0)
                withExtendedLifetime(lifetime) { results.append(snapshot) }
            }
        }
        weak var pending = read
        Thread.sleep(forTimeInterval: 0.04)
        _ = g_main_context_iteration(nil, 0)
        XCTAssertTrue(results.isEmpty)
        XCTAssertNotNil(captured)
        XCTAssertTrue(spin(context) { results.count == 1 })
        XCTAssertNil(results.first ?? nil)
        XCTAssertNil(captured)
        read?.cancel()
        read = nil
        XCTAssertTrue(spin(context) { pending == nil })
        XCTAssertEqual(results.count, 1)
    }

    func testZeroNegativeBudgetsAndInvalidByteLimitCompleteOnce() throws {
        let fixture = try ClipboardFixture()
        fixture.driver.writeText("Previous")
        for (budget, limit): (Duration, Int) in [(.zero, 100), (.milliseconds(-1), 100), (.seconds(3), -1)] {
            var results: [ClipboardTextSnapshot?] = []
            let read = fixture.driver.snapshotText(budget: budget, byteLimit: limit) { results.append($0) }
            XCTAssertEqual(results.count, 1)
            XCTAssertNil(results.first ?? nil)
            read.cancel()
            XCTAssertEqual(results.count, 1)
        }
    }

    func testCapturedContextAndDeadlineDoNotDependOnTimeoutDispatch() throws {
        try GTKTestSupport.requireDisplay()
        let owner = try XCTUnwrap(gtk_window_new())
        defer { gtk_window_destroy(mp_window(owner)) }
        gdk_clipboard_set_text(gtk_widget_get_clipboard(owner), "Previous")
        settleClipboard()
        let context = try XCTUnwrap(g_main_context_new())
        defer { g_main_context_unref(context) }
        g_main_context_push_thread_default(context)
        let driver = GTKClipboard(owner: owner)
        g_main_context_pop_thread_default(context)

        for late in [false, true] {
            var results: [ClipboardTextSnapshot?] = []
            var read: ClipboardSnapshotRead? = driver.snapshotText(
                budget: late ? .milliseconds(20) : .seconds(3), byteLimit: 100
            ) {
                XCTAssertNotEqual(g_main_context_is_owner(context), 0)
                results.append($0)
            }
            weak var pending = read
            // Prevent timeout dispatch, proving that a late native success is
            // still rejected by the monotonic deadline in the result callback.
            let data = Unmanaged.passUnretained(try XCTUnwrap(read) as AnyObject).toOpaque()
            let timer = try XCTUnwrap(g_main_context_find_source_by_user_data(context, data))
            g_source_destroy(timer)
            if late { Thread.sleep(forTimeInterval: 0.04) }
            XCTAssertTrue(spin(context) { results.count == 1 })
            XCTAssertEqual(results.first.flatMap { $0 }?.withText { $0 }, late ? nil : "Previous")
            read?.cancel()
            read = nil
            XCTAssertTrue(spin(context) { pending == nil })
            XCTAssertEqual(results.count, 1)
        }
    }

    func testNativeShimCallbackAndDestroyRunExactlyOnceOnAllResults() throws {
        let fixture = try ClipboardFixture()
        for outcome in ["success", "empty", "missing", "oversize", "cancel"] {
            fixture.driver.writeText(outcome == "empty" ? "" : "Previous")
            if outcome == "missing" { _ = gdk_clipboard_set_content(fixture.native, nil) }
            let cancellable = try XCTUnwrap(g_cancellable_new())
            defer { g_object_unref(cancellable) }
            let probe = NativeReadProbe()
            mp_clipboard_snapshot_text(fixture.native, outcome == "oversize" ? 1 : 100, cancellable,
                                      NativeReadProbe.callback, Unmanaged.passRetained(probe).toOpaque(),
                                      NativeReadProbe.destroy)
            if outcome == "cancel" { g_cancellable_cancel(cancellable) }
            XCTAssertTrue(probe.values.isEmpty)
            XCTAssertTrue(GTKTestSupport.spin { probe.destroys == 1 })
            XCTAssertEqual(probe.values.count, 1)
            XCTAssertEqual(probe.values.first ?? nil, outcome == "success" ? "Previous" : outcome == "empty" ? "" : nil)
            XCTAssertEqual(probe.destroys, 1)
        }
    }

    func testNativeShimSurvivesOwnerCloseOnThreadDefaultContext() throws {
        try GTKTestSupport.requireDisplay()
        let context = try XCTUnwrap(g_main_context_new())
        g_main_context_push_thread_default(context)
        defer {
            g_main_context_pop_thread_default(context)
            g_main_context_unref(context)
        }
        let owner = try XCTUnwrap(gtk_window_new())
        let native = try XCTUnwrap(gtk_widget_get_clipboard(owner))
        gdk_clipboard_set_text(native, "Previous")
        let cancellable = try XCTUnwrap(g_cancellable_new())
        defer { g_object_unref(cancellable) }
        let probe = NativeReadProbe(context: context)
        mp_clipboard_snapshot_text(native, 100, cancellable, NativeReadProbe.callback,
                                  Unmanaged.passRetained(probe).toOpaque(), NativeReadProbe.destroy)
        gtk_window_destroy(mp_window(owner))
        XCTAssertTrue(spin(context) { probe.destroys == 1 })
        XCTAssertEqual(probe.values, ["Previous"])
        XCTAssertEqual(probe.destroys, 1)
        _ = gdk_clipboard_set_content(native, nil)
        settleClipboard()
    }

    private func capture(_ clipboard: GTKClipboard, budget: Duration = Limits.clipboardSnapshotBudget,
                         byteLimit: Int = Limits.clipboardSnapshotMaxBytes) throws -> ClipboardTextSnapshot? {
        settleClipboard()
        let thread = Thread.current
        var results: [ClipboardTextSnapshot?] = []
        let read = clipboard.snapshotText(budget: budget, byteLimit: byteLimit) {
            XCTAssertTrue(Thread.current === thread)
            results.append($0)
        }
        XCTAssertTrue(GTKTestSupport.spin { results.count == 1 })
        read.cancel()
        XCTAssertEqual(results.count, 1)
        return results.first ?? nil
    }

    private func snapshot(_ clipboard: GTKClipboard) throws -> ClipboardTextSnapshot {
        try XCTUnwrap(capture(clipboard))
    }

    private func text(_ clipboard: GTKClipboard) throws -> String? {
        let result = RestoreTextReads()
        clipboard.readText { result.append($0) }
        XCTAssertTrue(GTKTestSupport.spin { result.values.count == 1 })
        return result.values.first ?? nil
    }

    private func publish(_ bytes: [UInt8], mime: String = "text/plain;charset=utf-8", on native: OpaquePointer) throws {
        let data = try XCTUnwrap(bytes.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) })
        defer { g_bytes_unref(data) }
        let provider = try XCTUnwrap(gdk_content_provider_new_for_bytes(mime, data))
        defer { g_object_unref(provider) }
        XCTAssertNotEqual(gdk_clipboard_set_content(native, provider), 0)
    }

    private func spin(_ context: OpaquePointer, until predicate: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline {
            _ = g_main_context_iteration(context, 0)
            Thread.sleep(forTimeInterval: 0.002)
        }
        return predicate()
    }
}

private final class RestoreTextReads: @unchecked Sendable {
    private let thread = Thread.current
    var values: [String?] = []
    func append(_ value: String?) {
        XCTAssertTrue(Thread.current === thread)
        values.append(value)
    }
}

private final class ClipboardFixture {
    private let thread = Thread.current
    let owner: GTK.Widget
    let native: OpaquePointer
    let driver: GTKClipboard

    init() throws {
        precondition(Thread.isMainThread)
        try GTKTestSupport.requireDisplay()
        owner = try XCTUnwrap(gtk_window_new())
        native = try XCTUnwrap(gtk_widget_get_clipboard(owner))
        driver = GTKClipboard(owner: owner)
        // This clears the display's real clipboard; use Xvfb or a throwaway session.
        _ = gdk_clipboard_set_content(native, nil)
        settleClipboard()
    }

    deinit {
        precondition(Thread.current === thread)
        driver.shutdown()
        _ = gdk_clipboard_set_content(native, nil)
        settleClipboard()
        gtk_window_destroy(mp_window(owner))
    }
}

private final class Lifetime {}
private final class UnknownRevision: ClipboardRevision {}
private final class UnknownOwnership: ClipboardWriteOwnership {}

private func settleClipboard() {
    // X11 clears/claims in one server millisecond can leave stale owner/TARGETS
    // events. Settle setup first; race tests change ownership after capture.
    gdk_display_sync(gdk_display_get_default())
    _ = GTKTestSupport.spin(until: { false }, timeout: .milliseconds(30))
}

private final class ProviderRelease {
    private let thread = Thread.current
    private(set) var count = 0

    static func observe(on clipboard: OpaquePointer) throws -> ProviderRelease {
        precondition(Thread.isMainThread)
        let provider = try XCTUnwrap(gdk_clipboard_get_content(clipboard))
        // Keep the borrowed provider alive through weak-notify registration.
        _ = g_object_ref(provider)
        defer { g_object_unref(provider) }
        let probe = ProviderRelease()
        g_object_weak_ref(UnsafeMutableRawPointer(provider).assumingMemoryBound(to: GObject.self), { data, _ in
            guard let data else { return }
            let probe = Unmanaged<ProviderRelease>.fromOpaque(data).takeRetainedValue()
            XCTAssertTrue(Thread.current === probe.thread)
            probe.count += 1
        }, Unmanaged.passRetained(probe).toOpaque())
        return probe
    }
}

private final class NativeReadProbe {
    private let thread = Thread.current
    private let context: OpaquePointer?
    private(set) var values: [String?] = []
    private(set) var destroys = 0

    init(context: OpaquePointer? = nil) { self.context = context }

    private func checkContext() {
        XCTAssertTrue(Thread.current === thread)
        if let context { XCTAssertNotEqual(g_main_context_is_owner(context), 0) }
    }

    static let callback: MPClipboardRead = { text, data in
        guard let data else { return }
        let probe = Unmanaged<NativeReadProbe>.fromOpaque(data).takeUnretainedValue()
        probe.checkContext()
        probe.values.append(text.map { String(cString: $0) })
    }

    static let destroy: GDestroyNotify = { data in
        guard let data else { return }
        let probe = Unmanaged<NativeReadProbe>.fromOpaque(data).takeRetainedValue()
        probe.checkContext()
        probe.destroys += 1
    }
}

// The semaphore transfers exclusive access; no test mutates the object concurrently.
private final class WorkerTransfer: @unchecked Sendable {
    var object: AnyObject?
    init(_ object: AnyObject) { self.object = object }
}

private final class WorkerAction: @unchecked Sendable {
    let work: () -> Void
    init(_ work: @escaping () -> Void) { self.work = work }
}

private final class WorkerDeliveryPorts: PanelWindow, FocusTracker, PasteInjector, Notifier, SessionProbe, Scheduler {
    let backend = PasteBackend.xdotool
    private(set) var captures = 0
    private(set) var hides = 0
    private(set) var focusRestores = 0
    private(set) var pastes = 0
    private var scheduled: [(Duration, () -> Void)] = []

    func show() { XCTAssertTrue(Thread.isMainThread) }
    func hide() { XCTAssertTrue(Thread.isMainThread) }
    func hideForDelivery() { XCTAssertTrue(Thread.isMainThread); hides += 1 }
    func currentSession() -> DesktopSession { XCTAssertTrue(Thread.isMainThread); return .otherX11 }
    func copied() { XCTFail("Unexpected copy-only delivery") }
    func pressPaste(chord: PasteChord, reason: CopyReason) { XCTFail("Unexpected paste fallback") }

    func captureTarget() -> DeliveryTarget? {
        XCTAssertTrue(Thread.isMainThread)
        captures += 1
        return .linux(session: .otherX11, x11WindowClass: nil)
    }

    func restore(_ target: DeliveryTarget, completion: @escaping (FocusConfirmation) -> Void) {
        XCTAssertTrue(Thread.isMainThread)
        focusRestores += 1
        runOnWorker { completion(.confirmed) }
    }

    func paste(chord: PasteChord, completion: @escaping (PasteAttemptResult) -> Void) {
        XCTAssertTrue(Thread.isMainThread)
        pastes += 1
        runOnWorker { completion(.sent) }
    }

    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        XCTAssertTrue(Thread.isMainThread)
        scheduled.append((delay, work))
    }

    func fireFromWorker(_ delay: Duration) {
        XCTAssertTrue(Thread.isMainThread)
        guard let index = scheduled.firstIndex(where: { $0.0 == delay }) else {
            XCTFail("Expected delivery timer")
            return
        }
        runOnWorker(scheduled.remove(at: index).1)
    }
}

private func runOnWorker(_ work: @escaping () -> Void) {
    let action = WorkerAction(work)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        XCTAssertFalse(Thread.isMainThread)
        action.work()
        done.signal()
    }
    XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
}
#endif
