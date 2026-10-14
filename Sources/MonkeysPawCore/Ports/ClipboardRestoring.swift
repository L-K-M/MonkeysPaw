/// Driver-owned, immutable identities. Core never compares text to establish
/// ownership. Tokens belong to one clipboard driver and are UI-thread confined.
public protocol ClipboardRevision: AnyObject {}
public protocol ClipboardWriteOwnership: AnyObject {}

/// Previous text stays in memory and is redacted from diagnostics/reflection.
/// Neither snapshots nor ownership tokens may be logged or persisted (§12).
public final class ClipboardTextSnapshot: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let revision: ClipboardRevision
    private let text: String

    public init(text: String, revision: ClipboardRevision) {
        self.text = text
        self.revision = revision
    }

    public func withText<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(text)
    }

    public var description: String { "<clipboard text redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["snapshot": description]) }
}

/// Cancel on the owning UI thread. Cancellation is idempotent, releases captured
/// text/resources promptly and prevents further successful completion.
public protocol ClipboardSnapshotRead: AnyObject {
    func cancel()
}

/// Optional capability of the same Clipboard instance used for delivery.
/// All calls and completions run on its owning UI thread/context. Snapshotting
/// returns immediately; write/restore have no asynchronous read/check/write gap.
public protocol ClipboardRestoring: Clipboard {
    /// Capture only text, within one monotonic budget and UTF-8 byte limit.
    /// Complete at most once, inline or asynchronously. Nil covers absent text,
    /// read failure, timeout, oversize data or a revision change during capture.
    /// The driver bounds receipt before allocating/decoding untrusted data.
    func snapshotText(
        budget: Duration, byteLimit: Int,
        completion: @escaping (ClipboardTextSnapshot?) -> Void
    ) -> ClipboardSnapshotRead

    /// Always write text. Recheck the snapshot revision immediately before the
    /// write; return ownership of the resulting revision/provider only if that
    /// revision was still current and ownership can be established. Otherwise
    /// return nil, leaving the delivered text available for manual paste.
    func writeTextOwning(_ text: String, after revision: ClipboardRevision) -> ClipboardWriteOwnership?

    /// Recheck revision/provider immediately before replacing with prior text.
    /// A newer copy, even identical bytes, or unknown ownership means no write.
    /// Release native resources after restore/skip. OS APIs cannot atomically
    /// exclude a simultaneous external copy; this guards observed changes (§6.3).
    func restore(_ snapshot: ClipboardTextSnapshot, ifOwnedBy ownership: ClipboardWriteOwnership)
}
