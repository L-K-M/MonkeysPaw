import XCTest
@testable import MonkeysPawCore

final class LogLevelPolicyTests: XCTestCase {
    func testEachEnvironmentValueSelectsItsThresholdCaseInsensitively() {
        let cases: [(String?, [LogLevel])] = [
            (nil, [.warning, .error]), ("", [.warning, .error]),
            ("unknown", [.warning, .error]), ("trace", [.warning, .error]),
            ("debug", [.debug, .info, .warning, .error]),
            ("DEBUG", [.debug, .info, .warning, .error]),
            ("info", [.info, .warning, .error]), ("InFo", [.info, .warning, .error]),
            ("warning", [.warning, .error]), ("WARNING", [.warning, .error]),
            ("warn", [.warning, .error]), ("WaRn", [.warning, .error]),
            ("error", [.error]), ("ErRoR", [.error])
        ]
        let levels: [LogLevel] = [.debug, .info, .warning, .error]
        for (value, expected) in cases {
            let policy = LogLevelPolicy(environmentValue: value)
            XCTAssertEqual(levels.filter { policy.allows($0) }, expected, value ?? "unset")
        }
    }

    func testCompositeFiltersBeforeForwardingToEverySink() {
        let first = PolicyLogRecorder()
        let second = PolicyLogRecorder()
        let log = CompositeLogSink(sinks: [first, second])
        for level in [LogLevel.debug, .info, .warning, .error] { log.write(level, "safe metadata") }

        XCTAssertEqual(first.levels, [.warning, .error])
        XCTAssertEqual(second.levels, first.levels)
        XCTAssertEqual(first.messages, ["safe metadata", "safe metadata"])
        XCTAssertEqual(second.messages, first.messages)
    }

    func testCompositeUsesTheSuppliedPolicy() {
        let recorder = PolicyLogRecorder()
        let log = CompositeLogSink(sinks: [recorder], policy: LogLevelPolicy(environmentValue: "debug"))
        log.write(.debug, "stage started")
        XCTAssertEqual(recorder.levels, [.debug])
        XCTAssertEqual(recorder.messages, ["stage started"])
    }
}

private final class PolicyLogRecorder: LogSink {
    var levels: [LogLevel] = []
    var messages: [String] = []
    func write(_ level: LogLevel, _ message: String) {
        levels.append(level)
        messages.append(message)
    }
}
