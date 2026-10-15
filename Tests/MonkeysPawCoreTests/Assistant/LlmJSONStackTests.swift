import Foundation
import XCTest
@testable import MonkeysPawCore

final class LlmJSONStackTests: XCTestCase {
    func testSerializationAtEnvelopeCapOnSmallStack() throws {
        try onSmallStack {
            let depth = Limits.assistantEnvelopeNestingCap - 1
            let document = "\u{FEFF}{\"error\":\"json_schema is not supported\",\"unused\":"
                + String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth) + "}"
            var parser = LlmJSONParser(bytes: Array(document.utf8), mode: .serialization)
            let value = try parser.parse()
            XCTAssertEqual(try value.member("error").string, "json_schema is not supported")
            var leaf = try value.member("unused")
            for _ in 0..<depth { leaf = try XCTUnwrap(leaf.array.first) }
            guard case .number = leaf else { return XCTFail("Expected scalar at the cap") }
        }
    }

    func testEnvelopeValueDestructionOnSmallStack() throws {
        // Construct on the test thread to isolate destruction from parser frames.
        for shape in 0..<3 {
            let owner = ValueOwner()
            for depth in 0..<Limits.assistantEnvelopeNestingCap {
                if shape == 0 || (shape == 2 && depth.isMultiple(of: 2)) {
                    owner.value = .array([owner.value!])
                } else {
                    owner.value = .object(["x": owner.value!])
                }
            }
            try onSmallStack { owner.value = nil }
        }
    }

    func testBothModesKeepDepthBoundariesAndCleanUpPartialTreesOnSmallStack() throws {
        try onSmallStack {
            for mode in [LlmJSONParser.Mode.output, .serialization] {
                let cap = mode == .output ? Limits.llmJSONNestingCap : Limits.assistantEnvelopeNestingCap
                for object in [false, true] {
                    let opening = object ? "{\"x\":" : "["
                    let closing = object ? "}" : "]"
                    let prefix = String(repeating: opening, count: cap - 1)
                    let suffix = String(repeating: closing, count: cap - 1)
                    for leaf in ["[]", "{}", opening + "true" + closing, opening + "\"leaf\"" + closing] {
                        var parser = LlmJSONParser(bytes: Array((prefix + leaf + suffix).utf8), mode: mode)
                        XCTAssertNoThrow(try parser.parse())
                    }
                    for leaf in [opening + "[]" + closing, opening + "{}" + closing] {
                        var parser = LlmJSONParser(bytes: Array((prefix + leaf + suffix).utf8), mode: mode)
                        XCTAssertThrowsError(try parser.parse()) { XCTAssertEqual($0 as? AssistantError, .invalidOutput) }
                    }
                    let complete = prefix + "null" + suffix
                    for document in [String(complete.dropLast()), complete + "x", "[" + complete + ",]",
                                     "{\"x\":" + complete + ",\"bad\":[1,]}"] {
                        var parser = LlmJSONParser(bytes: Array(document.utf8), mode: mode)
                        XCTAssertThrowsError(try parser.parse()) { XCTAssertEqual($0 as? AssistantError, .invalidOutput) }
                    }
                    if mode == .serialization {
                        // Replacing the last owner of a deep duplicate also destroys it.
                        let document = "{\"x\":" + complete + ",\"x\":\"last\"}"
                        var parser = LlmJSONParser(bytes: Array(document.utf8), mode: mode)
                        XCTAssertEqual(try parser.parse().member("x").string, "last")
                    }
                }
            }
        }
    }

    func testPrefixPositionsBOMAndTrailingContentRemainModeSpecific() throws {
        for mode in [LlmJSONParser.Mode.output, .serialization] {
            let prefix = mode == .serialization ? "\u{FEFF} \t" : " \t"
            for value in ["{}", "[]", "{\"a\":[null,{},[]]}", "true", "\"😀\"", "-1.2e3"] {
                let bytes = Array((prefix + value + " \nfalse").utf8)
                var parser = LlmJSONParser(bytes: bytes, mode: mode)
                let (_, end) = try parser.parsePrefix()
                XCTAssertEqual(end, (prefix + value).utf8.count)
                let (next, nextEnd) = try parser.parsePrefix()
                XCTAssertFalse(try next.boolean)
                XCTAssertEqual(nextEnd, bytes.count)
                var whole = LlmJSONParser(bytes: bytes, mode: mode)
                XCTAssertThrowsError(try whole.parse()) { XCTAssertEqual($0 as? AssistantError, .invalidOutput) }
                var offset = LlmJSONParser(bytes: Array(("skip" + value + " ").utf8), position: 4, mode: mode)
                XCTAssertEqual(try offset.parsePrefix().1, 4 + value.utf8.count)
            }
            var offsetBOM = LlmJSONParser(bytes: Array("x\u{FEFF}{}".utf8), position: 1, mode: mode)
            XCTAssertThrowsError(try offsetBOM.parse()) { XCTAssertEqual($0 as? AssistantError, .invalidOutput) }
            var spacedBOM = LlmJSONParser(bytes: Array(" \u{FEFF}{}".utf8), mode: mode)
            XCTAssertThrowsError(try spacedBOM.parse()) { XCTAssertEqual($0 as? AssistantError, .invalidOutput) }
        }
        var outputBOM = LlmJSONParser(bytes: Array("\u{FEFF}{}".utf8))
        XCTAssertThrowsError(try outputBOM.parse())
    }

    func testDuplicatePoliciesAndEagerScalarValidationRemainModeSpecific() throws {
        let duplicate = #"{"x":"first","\u0078":"last"}"#
        var output = LlmJSONParser(bytes: Array(duplicate.utf8))
        XCTAssertThrowsError(try output.parse()) { XCTAssertEqual($0 as? AssistantError, .invalidOutput) }
        var serialization = LlmJSONParser(bytes: Array(duplicate.utf8), mode: .serialization)
        XCTAssertEqual(try serialization.parse().member("x").string, "last")
        for mode in [LlmJSONParser.Mode.output, .serialization] {
            for token in ["0", "-0", "1.25e-2", "true", "null", #""\uD83D\uDE00\n\"\\""#] {
                var parser = LlmJSONParser(bytes: Array(("{\"unused\":" + token + "}").utf8), mode: mode)
                XCTAssertNoThrow(try parser.parse())
            }
            for token in ["01", "1.", "+1", "NaN", "1e400", #""\uD800""#, #""\uDC00""#, "[1,]", "{\"x\":0,}"] {
                let document = "{\"unused\":" + token + (mode == .serialization ? ",\"unused\":0}" : "}")
                var parser = LlmJSONParser(bytes: Array(document.utf8), mode: mode)
                XCTAssertThrowsError(try parser.parse()) { XCTAssertEqual($0 as? AssistantError, .invalidOutput) }
            }
        }
        // Output's Foundation fragment compatibility accepts a numeric BOM.
        var fragment = LlmJSONParser(bytes: Array("[\u{FEFF}1]".utf8))
        XCTAssertNoThrow(try fragment.parse())
        var strict = LlmJSONParser(bytes: Array("[\u{FEFF}1]".utf8), mode: .serialization)
        XCTAssertThrowsError(try strict.parse()) { XCTAssertEqual($0 as? AssistantError, .invalidOutput) }
    }

    private func onSmallStack(_ operation: @escaping @Sendable () throws -> Void) throws {
        let finished = DispatchSemaphore(value: 0)
        let result = ThreadResult()
        let thread = Thread {
            result.value = Result { try operation() }
            finished.signal()
        }
        // Darwin cooperative-pool threads have 512 KiB; use 256 KiB to expose
        // per-container native recursion on Linux's otherwise larger stacks.
        thread.stackSize = 256 * 1024
        thread.start()
        guard finished.wait(timeout: .now() + 10) == .success else {
            return XCTFail("Small-stack worker did not finish")
        }
        try XCTUnwrap(result.value).get()
    }
}

// The semaphore orders worker writes before reads on the joining test thread.
private final class ThreadResult: @unchecked Sendable {
    var value: Result<Void, Error>?
}

private final class ValueOwner: @unchecked Sendable {
    var value: LlmJSONValue? = .number
}
