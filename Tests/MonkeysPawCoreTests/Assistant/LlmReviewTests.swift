import Foundation
import XCTest
@testable import MonkeysPawCore

final class LlmReviewTests: XCTestCase {
    func testReviewPreservesFindingAndMatchesFirstExactUTF8Range() throws {
        let source = "😀\nUse sources.\nUse sources."
        let review = try decode(AssistantOutputFixtures.review, source: source)
        XCTAssertEqual(review.summary, "Clarify sources.")
        let finding = try XCTUnwrap(review.findings.first)
        XCTAssertEqual(finding.criterion, .verifiability)
        XCTAssertEqual(finding.severity, .medium)
        XCTAssertEqual(finding.quote, "Use sources.")
        XCTAssertEqual(finding.problem, "The source requirements are vague.")
        XCTAssertEqual(finding.suggestion, "Request primary sources.")
        XCTAssertEqual(finding.quoteMatch, .matched(byteRange: 5..<17))
    }

    func testUnmatchedQuotesStayUnmatchedWithoutNormalizationOrFuzzyAttachment() throws {
        for quote in ["", "use sources.", "Use  sources.", "Use sources!", "Use\nsources.", "café"] {
            var finding = AssistantOutputFixtures.finding
            finding["quote"] = quote
            let review = try decode(AssistantOutputFixtures.reviewReplacing(finding, layer: 1),
                                    source: "Use sources.\ncafe\u{301}")
            XCTAssertEqual(review.findings.first?.quoteMatch, .unmatched)
        }
        var finding = AssistantOutputFixtures.finding
        finding["quote"] = "line\nnext"
        let root = AssistantOutputFixtures.reviewReplacing(finding, layer: 1)
        XCTAssertEqual(try decode(root, source: "line\r\nnext").findings.first?.quoteMatch, .unmatched)
        XCTAssertEqual(try decode(root, source: "line\nnext").findings.first?.quoteMatch, .matched(byteRange: 0..<9))
        finding["quote"] = "cafe\u{301}"
        XCTAssertEqual(try decode(AssistantOutputFixtures.reviewReplacing(finding, layer: 1),
            source: "cafe\u{301}").findings.first?.quoteMatch, .matched(byteRange: 0..<6))
    }

    func testRejectsMissingExtraAndWrongTypesAtEveryReviewObject() throws {
        for (layer, original) in [AssistantOutputFixtures.review, AssistantOutputFixtures.finding].enumerated() {
            for key in original.keys.sorted() {
                var missing = original
                missing.removeValue(forKey: key)
                try assertInvalid(AssistantOutputFixtures.reviewReplacing(missing, layer: layer))
                for wrong in AssistantOutputFixtures.wrongTypes(for: key) {
                    var invalid = original
                    invalid[key] = wrong
                    try assertInvalid(AssistantOutputFixtures.reviewReplacing(invalid, layer: layer))
                }
            }
            var extra = original
            extra["unexpected"] = "value"
            try assertInvalid(AssistantOutputFixtures.reviewReplacing(extra, layer: layer))
        }
    }

    func testRejectsInvalidCriterionAndSeverityAndAcceptsEmptyFindings() throws {
        for criterion in ["outputFormat", "output-format", "Clarity", "unknown", ""] {
            var finding = AssistantOutputFixtures.finding
            finding["criterion"] = criterion
            try assertInvalid(AssistantOutputFixtures.reviewReplacing(finding, layer: 1))
        }
        for severity in ["HIGH", "critical", "", "low\n"] {
            var finding = AssistantOutputFixtures.finding
            finding["severity"] = severity
            try assertInvalid(AssistantOutputFixtures.reviewReplacing(finding, layer: 1))
        }
        var review = AssistantOutputFixtures.review
        review["findings"] = []
        XCTAssertTrue(try decode(review, source: "").findings.isEmpty)
    }

    func testInputSourceSizeIsBoundedInUTF8Bytes() throws {
        let json = try AssistantOutputFixtures.json(AssistantOutputFixtures.review)
        XCTAssertThrowsError(try LlmOutputDecoder.review(from: json,
            source: String(repeating: "é", count: Limits.maxPromptBytes / 2 + 1))) {
            XCTAssertEqual($0 as? AssistantError, .invalidOutput)
        }
        XCTAssertEqual(try LlmOutputDecoder.review(from: json,
            source: String(repeating: "é", count: Limits.maxPromptBytes / 2))
            .findings.first?.quoteMatch, .unmatched)
    }

    private func decode(_ object: [String: Any], source: String) throws -> LlmReview {
        try LlmOutputDecoder.review(from: AssistantOutputFixtures.json(object), source: source)
    }

    private func assertInvalid(_ object: [String: Any]) throws {
        let json = try AssistantOutputFixtures.json(object)
        XCTAssertThrowsError(try LlmOutputDecoder.review(from: json, source: "Use sources.")) {
            XCTAssertEqual($0 as? AssistantError, .invalidOutput)
        }
    }
}
