import AppKit
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

/// Native-shaped facts and callbacks, with no production Carbon registration.
final class MacRepeatHotkeys: MacHotkeyBackend {
    let mechanism = HotkeyMechanism.carbon
    private var unbound: [HotkeyAction: HotkeyRegistration] = [:]
    private(set) var current: [HotkeyAction: HotkeyRegistration] = [:]
    private(set) var callbacks: [HotkeyAction: () -> Void] = [:]
    private(set) var requested: [(HotkeyAction, Accelerator?)] = []
    var nextStatus: RegistrationStatus?
    var onRegister: ((HotkeyAction, Accelerator?) -> Void)?

    func registration(for action: HotkeyAction) -> HotkeyRegistration {
        if let value = current[action] { return value }
        if let value = unbound[action] { return value }
        let value = HotkeyRegistration(mechanism: .carbon, status: .unbound, detail: SetupStrings.unboundShortcut)
        unbound[action] = value
        return value
    }

    func register(_ action: HotkeyAction, accelerator: Accelerator?, onFire: @escaping () -> Void) -> HotkeyRegistration {
        requested.append((action, accelerator))
        let status = nextStatus ?? (accelerator == nil ? .unbound : .registered)
        nextStatus = nil
        let value = HotkeyRegistration(mechanism: .carbon, status: status, detail: "Isolated Carbon test")
        current[action] = value
        callbacks[action] = status == .registered ? onFire : nil
        onRegister?(action, accelerator)
        return value
    }

    func unregister(_ registration: HotkeyRegistration) {
        guard let action = current.first(where: { $0.value.id == registration.id })?.key else { return }
        current.removeValue(forKey: action)
        callbacks.removeValue(forKey: action)
    }
}

final class MacRepeatWork: BackgroundWork {
    private(set) var pending: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { pending.append(work) }
    func drain() {
        var count = 0
        while !pending.isEmpty {
            guard count < 1_000 else { XCTFail("Repeat background work did not settle"); return }
            count += 1
            pending.removeFirst()()
        }
    }
}

final class MacRepeatScheduler: MonkeysPawCore.Scheduler {
    private(set) var pending: [(Duration, () -> Void)] = []
    func after(_ delay: Duration, _ work: @escaping () -> Void) { pending.append((delay, work)) }
    func drain() {
        var count = 0
        while !pending.isEmpty {
            guard count < 1_000 else { XCTFail("Repeat timers did not settle"); return }
            count += 1
            pending.removeFirst().1()
        }
    }
}

final class MacRepeatClipboard: ClipboardRestoring {
    private final class Read: ClipboardSnapshotRead { func cancel() {} }
    var text: String? = "clipboard"
    var hold = false
    private(set) var pending: (@Sendable (String?) -> Void)?
    private(set) var writes: [String] = []
    private(set) var reads = 0
    private(set) var snapshots = 0

    func writeText(_ text: String) { writes.append(text); self.text = text }
    func readText(_ completion: @escaping @Sendable (String?) -> Void) {
        reads += 1
        if hold { pending = completion } else { completion(text) }
    }
    func release(_ text: String) {
        let callback = pending
        pending = nil
        hold = false
        callback?(text)
    }
    func snapshotText(budget: Duration, byteLimit: Int,
                      completion: @escaping (ClipboardTextSnapshot?) -> Void) -> ClipboardSnapshotRead {
        snapshots += 1
        completion(nil)
        return Read()
    }
    func writeTextOwning(_ text: String, after revision: ClipboardRevision) -> ClipboardWriteOwnership? {
        writeText(text)
        return nil
    }
    func restore(_ snapshot: ClipboardTextSnapshot, ifOwnedBy ownership: ClipboardWriteOwnership) {
        XCTFail("No ownership was issued")
    }
}

final class MacRepeatInjector: PasteInjector {
    let backend = PasteBackend.cgEvent
    private(set) var chords: [PasteChord] = []
    func paste(chord: PasteChord, completion: @escaping (PasteAttemptResult) -> Void) {
        chords.append(chord)
        completion(.sent)
    }
}

struct MacRepeatWatcher: FileStoreWatcher {
    func start(_ onEvent: @escaping @Sendable (FileStoreWatchEvent) -> Void) throws {}
    func stop() {}
}

struct MacRepeatNoHTTP: HTTPTransporting {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        XCTFail("Hosted repeat and shortcut flows must send no HTTP")
        throw HTTPTransportError.networkFailure
    }
}
