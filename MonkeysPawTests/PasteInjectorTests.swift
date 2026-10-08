import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class PasteInjectorTests: XCTestCase {
    func testCGEventConstructionWithoutPosting() throws {
        let pair = try XCTUnwrap(CGEventPasteInjector.makeEventPair())
        XCTAssertEqual(pair.down.type, .keyDown)
        XCTAssertEqual(pair.up.type, .keyUp)
        for event in [pair.down, pair.up] {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(kVK_ANSI_V))
            XCTAssertEqual(event.flags, .maskCommand)
        }
    }

    func testBothChordsPostOnWorkerWithPairGapThroughFakeSink() {
        for chord in [PasteChord.standard, .terminal] {
            let completed = expectation(description: "CGEvent callback")
            var types: [CGEventType] = []
            var times: [TimeInterval] = []
            // This replaces posting. AX trust is also injected; no permission is needed.
            let injector = CGEventPasteInjector(isTrusted: { true }, post: { event in
                XCTAssertFalse(Thread.isMainThread)
                types.append(event.type)
                times.append(ProcessInfo.processInfo.systemUptime)
                XCTAssertEqual(event.flags, .maskCommand)
            })
            injector.paste(chord: chord) { result in
                XCTAssertEqual(result, .sent)
                XCTAssertEqual(types, [.keyDown, .keyUp])
                XCTAssertGreaterThanOrEqual(times[1] - times[0], Limits.cgEventPairGap.timeInterval)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 2)
        }
    }

    func testUntrustedInjectorsCompleteWithoutSendingOrLaunching() {
        let cgDone = expectation(description: "CGEvent denied")
        let cg = CGEventPasteInjector(isTrusted: { false }, post: { _ in XCTFail("Must not post") })
        cg.paste(chord: .standard) { result in
            XCTAssertEqual(result, .failed(.permissionDenied))
            cgDone.fulfill()
        }

        let scriptDone = expectation(description: "AppleScript denied")
        let script = AppleScriptPasteInjector(isTrusted: { false }, makeProcess: {
            XCTFail("Must not launch System Events")
            return Process()
        })
        script.paste(chord: .standard) { result in
            XCTAssertEqual(result, .failed(.permissionDenied))
            scriptDone.fulfill()
        }
        wait(for: [cgDone, scriptDone], timeout: 2)
    }

    func testAppleScriptWorkerKillsTimedOutProcessAndCompletesOnce() {
        let completed = expectation(description: "Bounded subprocess callback")
        completed.assertForOverFulfill = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let injector = AppleScriptPasteInjector(isTrusted: { true }, makeProcess: { process })
        injector.paste(chord: .standard) { result in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(result, .failed(.timeout))
            completed.fulfill()
        }
        wait(for: [completed], timeout: Limits.appleScriptPasteTimeout.timeInterval + 2)
        // Waiting for the killed fake child is bounded here by an XCTest expectation.
        // No AppleScript, real events, AX query or consent prompt is involved.
        let reaped = expectation(description: "Fake child reaped")
        DispatchQueue.global().async {
            process.waitUntilExit()
            XCTAssertFalse(process.isRunning)
            reaped.fulfill()
        }
        wait(for: [reaped], timeout: 2)
    }

    func testAppleScriptTimeoutReapsOnWorkerBeforeCompleting() {
        let completed = expectation(description: "Timed-out fake child reaped before callback")
        completed.assertForOverFulfill = true
        // This fake has already stopped at the deadline, so no PID is killed.
        // Its exit handler is withheld until waitUntilExit, exposing the race.
        let process = StubScriptProcess(exit: .timeout)
        let injector = AppleScriptPasteInjector(isTrusted: { true }, makeProcess: { process })
        injector.paste(chord: .standard) { result in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(result, .failed(.timeout))
            XCTAssertTrue(process.didWaitForExit)
            completed.fulfill()
        }
        wait(for: [completed], timeout: Limits.appleScriptPasteTimeout.timeInterval + 2)
    }

    func testAppleScriptDistinguishesAutomationDenialFromOtherExits() {
        let cases: [(Int32, String, PasteAttemptResult)] = [
            (1, "Not authorized to send Apple events to System Events. (-1743)", .failed(.permissionDenied)),
            (1, "System Events got an error. (-1728)", .failed(.backendUnavailable)),
            (0, "", .sent),
            (0, "Ignored diagnostic (-1743)", .sent),
            // More than pipe capacity: the worker must drain while run/exit proceeds.
            (1, String(repeating: "x", count: 128 * 1_024) + " (-1743)", .failed(.permissionDenied)),
        ]
        for (status, stderr, expected) in cases {
            let completed = expectation(description: "Fake osascript exit classified")
            completed.assertForOverFulfill = true
            let process = StubScriptProcess(exit: .finished(status, stderr))
            let injector = AppleScriptPasteInjector(isTrusted: { true }, makeProcess: { process })
            injector.paste(chord: .standard) { result in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(result, expected)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 2)
        }
    }
}

/// A process-factory fake; no executable, AX query, event or TCC prompt is used.
private final class StubScriptProcess: Process {
    enum Exit { case finished(Int32, String), timeout }

    private let exit: Exit
    private(set) var didWaitForExit = false

    init(exit: Exit) {
        self.exit = exit
        super.init()
    }

    override var isRunning: Bool { false }

    override var terminationStatus: Int32 {
        if case .finished(let status, _) = exit { return status }
        return 0
    }

    override func run() throws {
        guard case .finished(_, let stderr) = exit else { return }
        let handle = (standardError as? Pipe)?.fileHandleForWriting ?? (standardError as? FileHandle)
        handle?.write(Data(stderr.utf8))
        terminationHandler?(self)
    }

    override func waitUntilExit() {
        XCTAssertFalse(Thread.isMainThread)
        didWaitForExit = true
        if case .timeout = exit { terminationHandler?(self) }
    }
}
