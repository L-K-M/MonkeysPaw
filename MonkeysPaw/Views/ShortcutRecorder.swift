import AppKit
import Carbon.HIToolbox
import MonkeysPawCore
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let onCapture: (String) -> Void
    let onError: (ShortcutRebindError) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton { ShortcutRecorderButton(frame: .zero) }

    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {
        view.onCapture = onCapture
        view.onError = onError
    }

    static func dismantleNSView(_ view: ShortcutRecorderButton, coordinator: ()) { view.stopCapture() }
}

/// A window-local monitor precedes menu equivalents, so Command chords and
/// Escape belong to capture. Teardown never leaves a monitor on the picker.
final class ShortcutRecorderButton: NSButton {
    enum Capture: Equatable {
        case ignored, cancelled, unsupportedKey
        case accelerator(String)
    }

    var onCapture: ((String) -> Void)?
    var onError: ((ShortcutRebindError) -> Void)?
    private(set) var isRecording = false
    private var keyMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        title = Strings.recordShortcut
        setAccessibilityLabel(Strings.recordShortcut)
        target = self
        action = #selector(beginCapture)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { removeObservers() }

    override var acceptsFirstResponder: Bool { true }

    @objc func beginCapture() {
        guard let window, window.makeFirstResponder(self) else { return }
        stopCapture()
        isRecording = true
        title = Strings.recordingShortcut
        setAccessibilityLabel(Strings.recordingShortcut)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording, let window = self.window,
                  event.window === window, window.isKeyWindow else { return event }
            self.record(event)
            return nil
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in self?.stopCapture()
            })
        }
    }

    func stopCapture() {
        isRecording = false
        title = Strings.recordShortcut
        setAccessibilityLabel(Strings.recordShortcut)
        removeObservers()
    }

    override func resignFirstResponder() -> Bool {
        stopCapture()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stopCapture() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        record(event)
    }

    override func cancelOperation(_ sender: Any?) {
        guard isRecording else { super.cancelOperation(sender); return }
        stopCapture()
    }

    private func removeObservers() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
    }

    private func record(_ event: NSEvent) {
        switch Self.capture(event) {
        case .ignored: break
        case .cancelled: stopCapture()
        case .unsupportedKey: onError?(.unsupportedCarbonKey)
        case .accelerator(let text):
            stopCapture()
            onCapture?(text)
        }
    }

    static func capture(_ event: NSEvent) -> Capture {
        guard event.type == .keyDown, !event.isARepeat else { return .ignored }
        if event.keyCode == UInt16(kVK_Escape) { return .cancelled }
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !modifiers.isEmpty else { return .ignored }
        let modifierKeys = [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift,
                            kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl,
                            kVK_CapsLock, kVK_Function]
        guard !modifierKeys.contains(Int(event.keyCode)) else { return .ignored }
        guard let key = CarbonHotkeyBackend.keyName(for: event.keyCode) else { return .unsupportedKey }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Cmd") }
        return .accelerator((parts + [key]).joined(separator: "+"))
    }
}
