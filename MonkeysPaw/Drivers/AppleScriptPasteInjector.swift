import ApplicationServices
import Darwin
import Foundation
import MonkeysPawCore

final class AppleScriptPasteInjector: PasteInjector {
    let backend = PasteBackend.appleScript

    private let worker = DispatchQueue(label: "ch.lkmc.MonkeysPaw.appleScript", qos: .userInitiated)
    private let isTrusted: () -> Bool
    private let makeProcess: () -> Process

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         makeProcess: @escaping () -> Process = AppleScriptPasteInjector.makeProcess) {
        self.isTrusted = isTrusted
        self.makeProcess = makeProcess
    }

    func paste(chord: PasteChord, completion: @escaping (PasteAttemptResult) -> Void) {
        worker.async { [self] in
            guard isTrusted() else {
                completion(.failed(.permissionDenied))
                return
            }

            let process = makeProcess()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do {
                try process.run()
            } catch {
                completion(.failed(.toolMissing))
                return
            }

            guard exited.wait(timeout: .now() + Limits.appleScriptPasteTimeout.timeInterval) == .success else {
                // Kill before returning: a late consent answer must not send a
                // keystroke after Core has already fallen back to copy-only.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                completion(.failed(.timeout))
                return
            }

            // Exit zero means sent, not received. SelfTest supplies stronger evidence.
            completion(process.terminationStatus == 0 ? .sent : .failed(.backendUnavailable))
        }
    }

    private static func makeProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Script and argv are fixed; prompt contents travel only on the clipboard.
        process.arguments = ["-e", "tell application \"System Events\" to keystroke \"v\" using command down"]
        return process
    }
}
