import Foundation
import XCTest
@testable import MonkeysPawCore

final class LlmRecoverySchemaTests: XCTestCase {
    func testProseCannotStartJSONStringOrBracketStateBeforeTheObject() throws {
        let json = #"{"a":1}"#
        for output in [
            #"He said "hi {"a":1}"#,
            #"see [note {"a":1}"#,
            "[note \(json)",
            "He said \"hi <think>\" [ { ignored</think>\(json)",
            "see [note <think>\" [ { ignored</think>\(json)",
            "<think>\" [ { <think>\" [ {</think></think>\(json)",
            "```json\nHe said \"hi [note\n\(json)\n```",
            "~~~json\n\" [note\n\(json)\n~~~"
        ] {
            XCTAssertEqual(try LlmJSONRecovery.object(in: output), Array(json.utf8), output)
        }
    }

    func testBothDecodersRecoverObjectsAfterUnbalancedProse() throws {
        let artifactJSON = try AssistantOutputFixtures.json(AssistantOutputFixtures.artifact)
        let reviewJSON = try AssistantOutputFixtures.json(AssistantOutputFixtures.review)
        let artifact = try LlmOutputDecoder.artifact(from: artifactJSON)
        let review = try LlmOutputDecoder.review(from: reviewJSON, source: "Use sources.")
        for prefix in ["He said \"hi ", "see [note ", "```json\n\" [note\n",
                       "<think>\" [ { ignored</think>\" [note "] {
            XCTAssertEqual(try LlmOutputDecoder.artifact(from: prefix + artifactJSON), artifact)
            XCTAssertEqual(try LlmOutputDecoder.review(from: prefix + reviewJSON, source: "Use sources."), review)
        }
    }

    func testRecoveryDoesNotUnwrapTopLevelArrays() throws {
        let json = #"{"a":1}"#
        for output in ["[\(json)]", "```json\n[\(json)]\n```", "~~~json\n[\(json)]\n~~~"] {
            XCTAssertThrowsError(try LlmJSONRecovery.object(in: output)) {
                XCTAssertEqual($0 as? AssistantError, .invalidOutput)
            }
        }
    }

    func testParserAndRecoveryCountEmptyContainersAtTheSameNestingLimit() throws {
        for depth in [Limits.llmJSONNestingCap, Limits.llmJSONNestingCap + 1] {
            let documents = [
                "{\"x\":" + String(repeating: "[", count: depth - 1)
                    + String(repeating: "]", count: depth - 1) + "}",
                String(repeating: "{\"x\":", count: depth - 1) + "{}"
                    + String(repeating: "}", count: depth - 1)
            ]
            for document in documents {
                var parser = LlmJSONParser(bytes: Array(document.utf8))
                if depth == Limits.llmJSONNestingCap {
                    XCTAssertNoThrow(try LlmJSONRecovery.object(in: document))
                    XCTAssertNoThrow(try parser.parse())
                } else {
                    XCTAssertThrowsError(try LlmJSONRecovery.object(in: document)) {
                        XCTAssertEqual($0 as? AssistantError, .invalidOutput)
                    }
                    XCTAssertThrowsError(try parser.parse()) {
                        XCTAssertEqual($0 as? AssistantError, .invalidOutput)
                    }
                }
            }
        }
    }

    func testRecoversFencesProseAndThinkingWithoutReadingThoughtObjects() throws {
        let json = try AssistantOutputFixtures.json(AssistantOutputFixtures.artifact)
        let expected = try LlmOutputDecoder.artifact(from: json)
        for output in [
            "```json\n\(json)\n```", "```JSON\r\n\(json)\r\n```", "~~~json\n\(json)\n~~~",
            "Here is the result:\n\(json)\nThat is all.", "\u{feff} \t\n\(json)\r\n",
            "<think>{\"title\":\"wrong\"}</think>\n```json\n\(json)\n```",
            "<think>outer <think>{invalid}</think> more thought</think>\n\(json)",
            "[\"prose\", {\"nested\": true}]\n\(json)", "\(json)\n\(json)"
        ] {
            XCTAssertEqual(try LlmOutputDecoder.artifact(from: output), expected)
        }
        let review = try AssistantOutputFixtures.json(AssistantOutputFixtures.review)
        XCTAssertEqual(try LlmOutputDecoder.review(from: "<think>{}</think>```json\n\(review)\n```", source: "Use sources.")
            .findings.first?.quoteMatch, .matched(byteRange: 0..<12))
    }

    func testRecoveryPreservesBracesQuotesEscapesFencesAndThinkInsideStrings() throws {
        var root = AssistantOutputFixtures.artifact
        let body = "Literal { braces } and [arrays], \"quotes\", \\ paths and \\\"}\\\".\n```json\n< Field >\n<think>{literal}</think>\n```"
        root["body"] = body
        root["notes"] = "Ends with a backslash \\"
        let json = try AssistantOutputFixtures.json(root)
        let artifact = try LlmOutputDecoder.artifact(from: "<think>{ignore}</think>\n```json\n\(json)\n``` prose")
        XCTAssertEqual(Data(artifact.body.utf8), Data(body.utf8))
        XCTAssertEqual(artifact.notes, "Ends with a backslash \\")
    }

    func testMalformedOrNonObjectJSONIsRejectedAndRecoveryDoesNotSkipAnInvalidFirstObject() throws {
        let valid = try AssistantOutputFixtures.json(AssistantOutputFixtures.artifact)
        let invalid = ["", "prose only", "{}", "[]", "[\(valid)]", "\"{}\"", "null", "true", "42",
            "{", "{\"body\":\"unterminated}", "<think>unclosed\n\(valid)", "{invalid} \(valid)",
            "{} \(valid)", "{\"tags\":[} \(valid)", valid.replacingOccurrences(of: "\"title\":", with: "\"title\" "),
            "Here is a quoted \"{brace}\":\n\(valid)",
            valid.replacingOccurrences(of: "\"title\":\"Research\"", with: "\"title\":\"bad\\q\""),
            valid.replacingOccurrences(of: "\"title\":\"Research\"", with: "\"title\":\"bad\nline\""),
            String(valid.dropLast()) + ",}", valid.replacingOccurrences(of: "\"research\",\"work\"", with: "\"research\",\"work\",")]
        for output in invalid {
            XCTAssertThrowsError(try LlmOutputDecoder.artifact(from: output)) {
                XCTAssertEqual($0 as? AssistantError, .invalidOutput)
            }
        }
    }

    func testDuplicateObjectKeysAreRejectedIncludingEscapedNamesAndNestedObjects() throws {
        let json = try AssistantOutputFixtures.json(AssistantOutputFixtures.artifact)
        for (original, replacement) in [
            ("\"title\":\"Research\"", "\"title\":\"Research\",\"title\":\"Other\""),
            ("\"title\":\"Research\"", "\"title\":\"Research\",\"\\u0074itle\":\"Other\""),
            ("\"type\":\"choice\"", "\"type\":\"choice\",\"type\":\"text\""),
            ("\"value\":\"neutral\"", "\"value\":\"neutral\",\"value\":\"warm\"")
        ] {
            XCTAssertThrowsError(try LlmOutputDecoder.artifact(from: json.replacingOccurrences(of: original, with: replacement))) {
                XCTAssertEqual($0 as? AssistantError, .invalidOutput)
            }
        }
        let review = try AssistantOutputFixtures.json(AssistantOutputFixtures.review)
        XCTAssertThrowsError(try LlmOutputDecoder.review(from: review.replacingOccurrences(of: "\"severity\":\"medium\"",
            with: "\"severity\":\"medium\",\"severity\":\"high\""), source: "Use sources."))
    }

    func testBooleanNumbersAreNotCoercedAndJSONEscapesAreDecoded() throws {
        let json = try AssistantOutputFixtures.json(AssistantOutputFixtures.artifact)
        for number in ["0", "1", "0.0", "1e0", "-1", "null"] {
            XCTAssertThrowsError(try LlmOutputDecoder.artifact(from:
                json.replacingOccurrences(of: "\"remember\":true", with: "\"remember\":\(number)")))
        }
        let escaped = json.replacingOccurrences(of: "\"title\":\"Research\"",
            with: "\"title\":\"\\u0052esearch \\uD83D\\uDE00\"")
        XCTAssertEqual(try LlmOutputDecoder.artifact(from: escaped).title, "Research 😀")
        XCTAssertThrowsError(try LlmOutputDecoder.artifact(from: json.replacingOccurrences(of: "\"title\":\"Research\"",
            with: "\"title\":\"\\uD800\"")))
    }

    func testInputByteCapAndNestingBoundApplyBeforeRecovery() throws {
        let json = try AssistantOutputFixtures.json(AssistantOutputFixtures.artifact)
        let padding = String(repeating: " ", count: Limits.responseCap - json.utf8.count)
        XCTAssertNoThrow(try LlmOutputDecoder.artifact(from: padding + json))
        XCTAssertThrowsError(try LlmOutputDecoder.artifact(from: padding + " " + json))
        XCTAssertThrowsError(try LlmOutputDecoder.artifact(from:
            "<think>" + String(repeating: "é", count: Limits.responseCap / 2) + "</think>" + json))
        let allowed = "{\"x\":" + String(repeating: "[", count: Limits.llmJSONNestingCap - 1) + "0"
            + String(repeating: "]", count: Limits.llmJSONNestingCap - 1) + "}"
        var parser = LlmJSONParser(bytes: try LlmJSONRecovery.object(in: allowed))
        XCTAssertNoThrow(try parser.parse())
        let tooDeep = "{\"x\":" + String(repeating: "[", count: Limits.llmJSONNestingCap) + "0"
            + String(repeating: "]", count: Limits.llmJSONNestingCap) + "}"
        XCTAssertThrowsError(try LlmJSONRecovery.object(in: tooDeep))
        var deepParser = LlmJSONParser(bytes: Array(tooDeep.utf8))
        XCTAssertThrowsError(try deepParser.parse())
    }
}
