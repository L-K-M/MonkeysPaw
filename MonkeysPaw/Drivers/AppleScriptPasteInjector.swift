import ApplicationServices
import CoreServices
import Darwin
import Foundation
import MonkeysPawCore

final class AppleScriptPasteInjector: PasteInjector {
    let backend = PasteBackend.appleScript

    private let worker = DispatchQueue(label: "ch.lkmc.MonkeysPaw.appleScript", qos: .userInitiated)
    private let isTrusted: () -> Bool
    private let makeInvocation: () -> AppleScriptInvocation

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         makeInvocation: @escaping () -> AppleScriptInvocation = AppleScriptPasteInjector.makeInvocation) {
        self.isTrusted = isTrusted
        self.makeInvocation = makeInvocation
    }

    func paste(chord: PasteChord, completion: @escaping (PasteAttemptResult) -> Void) {
        worker.async { [self] in
            guard isTrusted() else {
                completion(.failed(.permissionDenied))
                return
            }

            let invocation = makeInvocation()
            let stderr = Pipe()
            // Drain concurrently, including during launch, so pipe capacity cannot
            // prevent exit. Diagnostics are inspected for a code, never logged.
            let errorCapture = StandardErrorCapture(handle: stderr.fileHandleForReading)

            let exited = DispatchSemaphore(value: 0)
            do {
                try invocation.run(standardError: stderr, onExit: { exited.signal() })
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
                if invocation.isRunning { invocation.kill() }
                // SIGKILL cannot be ignored. Reap on this worker before completing,
                // including an exit racing the deadline, without blocking AppKit.
                invocation.waitUntilExit()
                _ = errorCapture.permissionWasDenied()
                completion(.failed(.timeout))
                return
            }

            // Exit zero means sent, not received. SelfTest supplies stronger evidence.
            let permissionDenied = errorCapture.permissionWasDenied()
            guard invocation.terminationStatus != 0 else {
                completion(.sent)
                return
            }
            completion(.failed(permissionDenied ? .permissionDenied : .backendUnavailable))
        }
    }

    private static func makeInvocation() -> AppleScriptInvocation {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Script and argv are fixed; prompt contents travel only on the clipboard.
        process.arguments = ["-e", "tell application \"System Events\" to keystroke \"v\" using command down"]
        return AppleScriptProcessInvocation(process: process)
    }
}

/// Driver-local invocation seam: Darwin's Process class cluster is not a fake base.
protocol AppleScriptInvocation: AnyObject {
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
    func run(standardError: Pipe, onExit: @escaping () -> Void) throws
    func kill()
    func waitUntilExit()
}

final class AppleScriptProcessInvocation: AppleScriptInvocation {
    private let process: Process

    init(process: Process) { self.process = process }

    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32 { process.terminationStatus }

    func run(standardError: Pipe, onExit: @escaping () -> Void) throws {
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        process.terminationHandler = { _ in onExit() }
        try process.run()
    }

    func kill() { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    func waitUntilExit() { process.waitUntilExit() }
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
