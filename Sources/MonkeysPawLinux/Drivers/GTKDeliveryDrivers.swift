#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Native tokens, calls and teardown are confined to the owning GTK thread.
final class GTKClipboard: ClipboardRestoring {
    private final class ReadBox {
        let completion: @Sendable (String?) -> Void
        init(_ completion: @escaping @Sendable (String?) -> Void) { self.completion = completion }
    }

    private final class RevisionCounter {
        var generation: UInt64 = 0
        weak var ownership: Ownership?

        func changed() {
            generation &+= 1
            ownership?.releaseProvider()
        }
    }

    private final class Revision: ClipboardRevision {
        let counter: RevisionCounter
        let generation: UInt64

        init(_ counter: RevisionCounter) {
            self.counter = counter
            generation = counter.generation
        }
    }

    private final class Ownership: ClipboardWriteOwnership {
        let revision: Revision
        let generation: UInt64
        private(set) var provider: UnsafeMutablePointer<GdkContentProvider>?

        init(revision: Revision, generation: UInt64, provider: UnsafeMutablePointer<GdkContentProvider>) {
            self.revision = revision
            self.generation = generation
            self.provider = provider
        }

        func releaseProvider() {
            guard let provider else { return }
            self.provider = nil
            g_object_unref(provider)
        }

        deinit { releaseProvider() }
    }

    private let clipboard: OpaquePointer
    private let context: OpaquePointer
    private let counter = RevisionCounter()
    private var changedHandler: gulong = 0
    private var reads: [ObjectIdentifier: SnapshotRead] = [:]
    private var isShutDown = false

    init(owner: GTK.Widget) {
        clipboard = gtk_widget_get_clipboard(owner)!
        _ = g_object_ref(UnsafeMutableRawPointer(clipboard))
        context = g_main_context_ref_thread_default()!
        let data = Unmanaged.passRetained(counter).toOpaque()
        let changed: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data else { return }
            Unmanaged<RevisionCounter>.fromOpaque(data).takeUnretainedValue().changed()
        }
        changedHandler = mp_connect(UnsafeMutableRawPointer(clipboard), "changed",
                                    unsafeBitCast(changed, to: GCallback.self), data, { data, _ in
            guard let data else { return }
            Unmanaged<RevisionCounter>.fromOpaque(data).release()
        })
    }

    deinit {
        shutdown()
        g_object_unref(UnsafeMutableRawPointer(clipboard))
        g_main_context_unref(context)
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        counter.changed()
        g_signal_handler_disconnect(UnsafeMutableRawPointer(clipboard), changedHandler)
        // Completion can reenter the driver, so iterate a stable collection.
        let pending = Array(reads.values)
        for read in pending { read.cancel() }
    }

    private func onContext(_ work: () -> Void) {
        g_main_context_push_thread_default(context)
        defer { g_main_context_pop_thread_default(context) }
        work()
    }

    private func isCurrent(_ revision: Revision) -> Bool {
        !isShutDown && revision.counter === counter && revision.generation == counter.generation
    }

    /// The shim returns on this GTK thread's owning context, without dispatch.
    func readText(_ completion: @escaping @Sendable (String?) -> Void) {
        let box = Unmanaged.passRetained(ReadBox(completion)).toOpaque()
        onContext {
            mp_clipboard_read_text_from_clipboard(clipboard, { text, data in
                guard let data else { return }
                let value = text.map { String(cString: $0) }
                Unmanaged<ReadBox>.fromOpaque(data).takeUnretainedValue().completion(value)
            }, box, { data in
                guard let data else { return }
                Unmanaged<ReadBox>.fromOpaque(data).release()
            })
        }
    }

    func writeText(_ text: String) {
        // The resident application retains ownership after its picker hides.
        counter.changed()
        gdk_clipboard_set_text(clipboard, text)
    }

    func snapshotText(
        budget: Duration, byteLimit: Int,
        completion: @escaping (ClipboardTextSnapshot?) -> Void
    ) -> ClipboardSnapshotRead {
        let read = SnapshotRead(driver: self, budget: budget, byteLimit: byteLimit, completion: completion)
        reads[ObjectIdentifier(read)] = read
        onContext { read.start() }
        return read
    }

    func writeTextOwning(_ text: String, after revision: ClipboardRevision) -> ClipboardWriteOwnership? {
        guard let provider = mp_clipboard_text_provider(text) else {
            writeText(text)
            return nil
        }
        let captured = revision as? Revision
        let eligible = captured.map(isCurrent) ?? false
        counter.changed()
        guard gdk_clipboard_set_content(clipboard, provider) != 0 else {
            g_object_unref(provider)
            writeText(text)
            return nil
        }
        guard eligible, let captured, gdk_clipboard_is_local(clipboard) != 0,
              gdk_clipboard_get_content(clipboard) == provider else {
            g_object_unref(provider)
            return nil
        }
        let ownership = Ownership(revision: captured, generation: counter.generation, provider: provider)
        counter.ownership = ownership
        return ownership
    }

    func restore(_ snapshot: ClipboardTextSnapshot, ifOwnedBy ownership: ClipboardWriteOwnership) {
        guard let ownership = ownership as? Ownership, ownership.revision.counter === counter else { return }
        defer { ownership.releaseProvider() }
        guard !isShutDown, ownership.revision === snapshot.revision,
              ownership.generation == counter.generation, let provider = ownership.provider,
              gdk_clipboard_is_local(clipboard) != 0, gdk_clipboard_get_content(clipboard) == provider else { return }

        snapshot.withText { text in
            guard let previous = mp_clipboard_text_provider(text) else { return }
            defer { g_object_unref(previous) }
            // No clear or async gap: a rejected publication keeps delivered text.
            _ = gdk_clipboard_set_content(clipboard, previous)
        }
    }

    private final class SnapshotRead: ClipboardSnapshotRead {
        private weak var driver: GTKClipboard?
        private let revision: Revision
        private let context: OpaquePointer
        private let cancellable: UnsafeMutablePointer<GCancellable>
        private let deadline: ContinuousClock.Instant
        private let byteLimit: Int
        private var timer: UnsafeMutablePointer<GSource>?
        private var completion: ((ClipboardTextSnapshot?) -> Void)?

        init(driver: GTKClipboard, budget: Duration, byteLimit: Int,
             completion: @escaping (ClipboardTextSnapshot?) -> Void) {
            self.driver = driver
            revision = Revision(driver.counter)
            context = g_main_context_ref(driver.context)!
            cancellable = g_cancellable_new()!
            deadline = ContinuousClock.now.advanced(by: budget)
            self.byteLimit = min(byteLimit, Limits.clipboardSnapshotMaxBytes)
            self.completion = completion
        }

        deinit {
            g_object_unref(cancellable)
            g_main_context_unref(context)
        }

        func start() {
            guard let driver, driver.isCurrent(revision), byteLimit >= 0,
                  ContinuousClock.now < deadline else {
                finish(nil)
                return
            }
            let milliseconds = ceil(ContinuousClock.now.duration(to: deadline).timeInterval * 1_000)
            // GTK.after targets the global context; this driver retains its own.
            let source = g_timeout_source_new(guint(min(Double(guint.max), max(0, milliseconds))))!
            timer = source
            g_source_set_callback(source, { data in
                guard let data else { return 0 }
                Unmanaged<SnapshotRead>.fromOpaque(data).takeUnretainedValue().cancel()
                return 0
            }, Unmanaged.passRetained(self).toOpaque(), { data in
                guard let data else { return }
                Unmanaged<SnapshotRead>.fromOpaque(data).release()
            })
            _ = g_source_attach(source, context)
            mp_clipboard_snapshot_text(driver.clipboard, gsize(byteLimit), cancellable, { text, data in
                guard let data else { return }
                Unmanaged<SnapshotRead>.fromOpaque(data).takeUnretainedValue().received(text)
            }, Unmanaged.passRetained(self).toOpaque(), { data in
                guard let data else { return }
                Unmanaged<SnapshotRead>.fromOpaque(data).release()
            })
        }

        func cancel() { finish(nil) }

        private func received(_ text: UnsafePointer<CChar>?) {
            guard completion != nil else { return }
            guard let text, ContinuousClock.now < deadline, let driver, driver.isCurrent(revision) else {
                finish(nil)
                return
            }
            finish(ClipboardTextSnapshot(text: String(cString: text), revision: revision))
        }

        private func finish(_ snapshot: ClipboardTextSnapshot?) {
            guard let completion else { return }
            self.completion = nil
            g_cancellable_cancel(cancellable)
            if let timer {
                self.timer = nil
                g_source_destroy(timer)
                g_source_unref(timer)
            }
            driver?.reads.removeValue(forKey: ObjectIdentifier(self))
            completion(snapshot)
        }
    }
}

struct GTKNotifier: Notifier, LibraryAvailabilityNotifier {
    private let application: UnsafeMutablePointer<GtkApplication>
    private let session: SessionProbe

    init(application: UnsafeMutablePointer<GtkApplication>, session: SessionProbe) {
        self.application = application
        self.session = session
    }

    func copied() { mp_notify(application, AppIdentity.displayName, DeliveryStrings.copied) }

    func libraryUnavailable() {
        mp_notify(application, OnboardingStrings.libraryUnavailableNotificationTitle,
                  OnboardingStrings.libraryUnavailableNotificationBody)
    }

    func pressPaste(chord: PasteChord, reason: CopyReason) {
        mp_notify(application, AppIdentity.displayName,
                  DeliveryStrings.pressPaste(chord: chord, session: session.currentSession()))
    }
}

struct GLibScheduler: Scheduler {
    func after(_ delay: Duration, _ work: @escaping () -> Void) {
        GTK.after(delay.timeInterval, work)
    }
}

final class GTKSelfTestTarget: SelfTestTarget {
    private let window: GTK.Widget
    private let entry: GTK.Widget

    init(application: UnsafeMutablePointer<GtkApplication>) {
        window = gtk_application_window_new(application)!
        entry = gtk_entry_new()!
        GTK.hideOnClose(window)
        gtk_window_set_title(mp_window(window), LinuxStrings.selfTestTitle)
        gtk_window_set_default_size(mp_window(window), Int32(Limits.panelSize.width), -1)
        gtk_window_set_child(mp_window(window), entry)
    }

    func present(fieldExpecting text: String) {
        // The field must start empty: only an injected paste may establish receipt.
        mp_entry_set_text(entry, "")
        gtk_window_present(mp_window(window))
        gtk_widget_grab_focus(entry)
    }

    func readBack() -> String? {
        guard let text = mp_entry_text(entry) else { return nil }
        return String(cString: text)
    }

    func close() { gtk_widget_set_visible(window, 0) }
}
#endif
