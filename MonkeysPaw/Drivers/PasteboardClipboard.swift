import AppKit
import MonkeysPawCore

struct PasteboardClipboard: ClipboardRestoring {
    private let pasteboard: NSPasteboard
    private let identity = NSObject()

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Invoked inline on the caller's AppKit UI thread.
    func readText(_ completion: @escaping @Sendable (String?) -> Void) {
        assert(Thread.isMainThread)
        let text = pasteboard.string(forType: .string)
        completion(text.flatMap { $0.isEmpty ? nil : $0 })
    }

    func writeText(_ text: String) {
        assert(Thread.isMainThread)
        _ = write(text)
    }

    func snapshotText(budget: Duration, byteLimit: Int,
                      completion: @escaping (ClipboardTextSnapshot?) -> Void) -> ClipboardSnapshotRead {
        assert(Thread.isMainThread)
        let read = CompletedRead()
        guard budget > .zero, byteLimit > 0 else {
            completion(nil)
            return read
        }

        let deadline = ContinuousClock.now.advanced(by: budget)
        let changeCount = pasteboard.changeCount
        // AppKit materializes Data synchronously; bound decoding and reject late receipt.
        guard let data = pasteboard.data(forType: .string),
              !data.isEmpty, data.count <= byteLimit, ContinuousClock.now < deadline,
              let text = String(data: data, encoding: .utf8), !text.isEmpty,
              pasteboard.changeCount == changeCount, ContinuousClock.now < deadline else {
            completion(nil)
            return read
        }

        let revision = Revision(driver: identity, changeCount: changeCount)
        completion(ClipboardTextSnapshot(text: text, revision: revision))
        return read
    }

    func writeTextOwning(_ text: String, after revision: ClipboardRevision) -> ClipboardWriteOwnership? {
        assert(Thread.isMainThread)
        let revision = revision as? Revision
        let isCurrent = revision?.driver === identity && revision?.changeCount == pasteboard.changeCount
        let writtenCount = write(text)
        guard isCurrent, let revision, let writtenCount else { return nil }
        return Ownership(revision: revision, changeCount: writtenCount)
    }

    func restore(_ snapshot: ClipboardTextSnapshot, ifOwnedBy ownership: ClipboardWriteOwnership) {
        assert(Thread.isMainThread)
        guard let revision = snapshot.revision as? Revision, revision.driver === identity,
              let ownership = ownership as? Ownership, ownership.revision === revision,
              pasteboard.changeCount == ownership.changeCount else { return }

        snapshot.withText { text in
            guard !text.isEmpty else { return }
            writeText(text)
        }
    }

    private func write(_ text: String) -> Int? {
        // Keep the count from taking ownership, never adopt a competing writer's count.
        let changeCount = pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string),
              pasteboard.changeCount == changeCount else { return nil }
        return changeCount
    }

    private final class Revision: ClipboardRevision {
        let driver: NSObject
        let changeCount: Int

        init(driver: NSObject, changeCount: Int) {
            self.driver = driver
            self.changeCount = changeCount
        }
    }

    private final class Ownership: ClipboardWriteOwnership {
        let revision: Revision
        let changeCount: Int

        init(revision: Revision, changeCount: Int) {
            self.revision = revision
            self.changeCount = changeCount
        }
    }

    // Snapshot completion is inline; the returned handle retains no text or work.
    private final class CompletedRead: ClipboardSnapshotRead {
        func cancel() { assert(Thread.isMainThread) }
    }
}
