import ApplicationServices
import CoreServices
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
            let stderr = Pipe()
            process.standardError = stderr
            // Drain concurrently, including during launch, so pipe capacity cannot
            // prevent exit. Diagnostics are inspected for a code, never logged.
            let errorCapture = StandardErrorCapture(handle: stderr.fileHandleForReading)

            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do {
                try process.run()
            } catch {
                try? stderr.fileHandleForWriting.close()
                _ = errorCapture.permissionWasDenied()
                completion(.failed(.toolMissing))
                return
            }
            // Only the child may keep stderr open; its exit must give the reader EOF.
            try? stderr.fileHandleForWriting.close()

            guard exited.wait(timeout: .now() + Limits.appleScriptPasteTimeout.timeInterval) == .success else {
                // Kill before returning: a late consent answer must not send a
                // keystroke after Core has already fallen back to copy-only.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                // SIGKILL cannot be ignored. Reap on this worker before completing,
                // including an exit racing the deadline, without blocking AppKit.
                process.waitUntilExit()
                _ = errorCapture.permissionWasDenied()
                completion(.failed(.timeout))
                return
            }

            // Exit zero means sent, not received. SelfTest supplies stronger evidence.
            let permissionDenied = errorCapture.permissionWasDenied()
            guard process.terminationStatus != 0 else {
                completion(.sent)
                return
            }
            completion(.failed(permissionDenied ? .permissionDenied : .backendUnavailable))
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

/// The drain owns the diagnostic bytes; the worker reads only its typed result.
private final class StandardErrorCapture {
    private let drained = DispatchGroup()
    // Written only by the drain and read only after its group has completed.
    private var permissionDenied = false

    init(handle: FileHandle) {
        drained.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = handle.readDataToEndOfFile()
            permissionDenied = String(decoding: data, as: UTF8.self).contains(String(errAEEventNotPermitted))
            try? handle.close()
            drained.leave()
        }
    }

    func permissionWasDenied() -> Bool {
        drained.wait()
        return permissionDenied
    }
}
