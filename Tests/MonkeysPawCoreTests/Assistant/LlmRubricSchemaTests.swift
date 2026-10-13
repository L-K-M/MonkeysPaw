import Foundation
import XCTest
@testable import MonkeysPawCore

final class LlmRubricSchemaTests: XCTestCase {
    func testPinsEveryRubricWireNameAndReviewSeverity() throws {
        let criteria = ["clarity", "context", "role", "delimiting", "output_format", "examples", "reasoning",
                        "verifiability", "decomposition", "placeholders"]
        XCTAssertEqual(LlmRubricCriterion.allCases.map(\.rawValue), criteria)
        XCTAssertEqual(LlmReviewSeverity.allCases.map(\.rawValue), ["high", "medium", "low"])
        for criterion in criteria {
            for severity in ["high", "medium", "low"] {
                var finding = AssistantOutputFixtures.finding
                finding["criterion"] = criterion
                finding["severity"] = severity
                let review = try LlmOutputDecoder.review(from: AssistantOutputFixtures.json(
                    AssistantOutputFixtures.reviewReplacing(finding, layer: 1)), source: "Use sources.")
                XCTAssertEqual(review.findings.first?.criterion.rawValue, criterion)
                XCTAssertEqual(review.findings.first?.severity.rawValue, severity)
            }
        }
    }

    func testPinsCompleteArtifactRequestSchemaSnapshot() throws {
        let snapshot = #"""
        {"type":"object","additionalProperties":false,
         "required":["title","description","tags","fields","body","notes"],
         "properties":{
          "title":{"type":"string"},"description":{"type":"string"},
          "tags":{"type":"array","items":{"type":"string"}},
          "fields":{"type":"array","items":{"type":"object","additionalProperties":false,
           "required":["name","type","label","description","default","options","optional","remember"],
           "properties":{
            "name":{"type":"string"},"type":{"type":"string","enum":["text","multiline","choice"]},
            "label":{"type":"string"},"description":{"type":"string"},"default":{"type":"string"},
            "options":{"type":"array","items":{"type":"object","additionalProperties":false,
             "required":["value","label"],"properties":{"value":{"type":"string"},"label":{"type":"string"}}}},
            "optional":{"type":"boolean"},"remember":{"type":"boolean"}}}},
          "body":{"type":"string"},"notes":{"type":"string"}}}
        """#
        try assertSnapshot(LlmArtifact.jsonSchema, snapshot: snapshot)
    }

    func testPinsCompleteReviewRequestSchemaSnapshot() throws {
        let snapshot = #"""
        {"type":"object","additionalProperties":false,"required":["summary","findings"],
         "properties":{"summary":{"type":"string"},
          "findings":{"type":"array","items":{"type":"object","additionalProperties":false,
           "required":["severity","criterion","quote","problem","suggestion"],
           "properties":{
            "severity":{"type":"string","enum":["high","medium","low"]},
            "criterion":{"type":"string","enum":["clarity","context","role","delimiting","output_format",
              "examples","reasoning","verifiability","decomposition","placeholders"]},
            "quote":{"type":"string"},"problem":{"type":"string"},"suggestion":{"type":"string"}}}}}}
        """#
        try assertSnapshot(LlmReview.jsonSchema, snapshot: snapshot)
    }

    private func assertSnapshot(_ schema: Data, snapshot: String) throws {
        let expected = try JSONSerialization.jsonObject(with: Data(snapshot.utf8))
        XCTAssertEqual(schema, try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]))
        try assertStrictObjects(try XCTUnwrap(JSONSerialization.jsonObject(with: schema) as? [String: Any]))
    }

    private func assertStrictObjects(_ schema: [String: Any]) throws {
        if schema["type"] as? String == "object" {
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
            let required = try XCTUnwrap(schema["required"] as? [String])
            XCTAssertEqual(Set(required), Set(properties.keys))
            XCTAssertEqual(required.count, properties.count)
            for property in properties.values { try assertStrictObjects(property) }
        } else if schema["type"] as? String == "array" {
            try assertStrictObjects(try XCTUnwrap(schema["items"] as? [String: Any]))
        }
    }
}
