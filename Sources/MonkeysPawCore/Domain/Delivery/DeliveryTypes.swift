import Foundation

/// Session detection is filled by drivers, including the host of a sandbox.
public indirect enum DesktopSession: Equatable, Codable, Sendable {
    case macOS
    case gnomeWayland
    case gnomeX11
    case kdeWayland
    case kdeX11
    case otherX11
    case wlroots
    case flatpak(host: DesktopSession)
}

/// An opaque target identity; Core never inspects native window handles.
public enum DeliveryTarget: Equatable, Sendable {
    case macOS(processID: Int32, bundleID: String?)
    case linux(session: DesktopSession, x11WindowClass: String?)
}

public enum DeliveryMode: Equatable, Sendable {
    case paste(PasteChord)
    case copyOnly
}

public enum DeliveryInvocationSource: Sendable {
    case picker
    case currentTarget
}

/// Immutable focus/session captured before asynchronous builtin or file work.
/// Cancellation is thread safe; side effects check it on the injected UI thread.
public final class DeliveryInvocation: @unchecked Sendable {
    public let target: DeliveryTarget?
    public let session: DesktopSession
    let owner: ObjectIdentifier
    let generation: UInt64
    private let lock = NSLock()
    private var cancelled = false

    init(target: DeliveryTarget?, session: DesktopSession, owner: ObjectIdentifier, generation: UInt64) {
        self.target = target
        self.session = session
        self.owner = owner
        self.generation = generation
    }

    public func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

public enum PasteChord: String, Equatable, Codable, Sendable {
    case standard
    case terminal
}

public enum PasteBackend: String, CaseIterable, Codable, Sendable {
    case cgEvent
    case appleScript
    case remoteDesktopPortal
    case ydotool
    case xdotool
}

/// Typed diagnostics deliberately exclude provider and tool error bodies (§12).
public enum PasteFailure: String, Error, Codable, Sendable {
    case permissionDenied
    case toolMissing
    case timeout
    case portalDenied
    case backendUnavailable
    case notReceived
    case unknown
}

public enum PasteAttemptResult: Equatable, Sendable {
    /// Events were sent; only the self-test can establish that text arrived.
    case sent
    case failed(PasteFailure)
}

public struct BackendFailure: Equatable, Codable, Sendable {
    public let backend: PasteBackend
    public let reason: PasteFailure

    public init(backend: PasteBackend, reason: PasteFailure) {
        self.backend = backend
        self.reason = reason
    }
}

public enum CopyReason: Equatable, Codable, Sendable {
    case requested
    case backendsFailed([BackendFailure])
}

public enum DeliveryOutcome: Equatable, Codable, Sendable {
    case pasted(PasteBackend)
    case copiedOnly(CopyReason)
}

public enum FocusConfirmation: String, Codable, Sendable {
    case confirmed
    case unconfirmed
    case notCaptured
}

/// Keeps §4.5's outcome cases intact while recording best-effort focus (§6.3).
public struct DeliveryReceipt: Equatable, Sendable {
    public let outcome: DeliveryOutcome
    public let focus: FocusConfirmation

    public init(outcome: DeliveryOutcome, focus: FocusConfirmation) {
        self.outcome = outcome
        self.focus = focus
    }
}

/// Shared delivery copy from §11.5; front ends choose their native chord label.
public enum DeliveryStrings {
    public static let testPrompt = "Monkey's Paw test: if you can read this, delivery works."
    public static let copied = "Copied."
    public static let pressCommandV = "Copied. Press Cmd+V"
    public static let pressControlV = "Copied. Press Ctrl+V"
    public static let pressControlShiftV = "Copied. Press Ctrl+Shift+V"

    public static func pressPaste(chord: PasteChord, session: DesktopSession) -> String {
        if session == .macOS { return pressCommandV }
        return chord == .terminal ? pressControlShiftV : pressControlV
    }
}
