import Foundation

/// Stable §7.5 wire names; do not derive them from localized labels.
public enum LlmRubricCriterion: String, CaseIterable, Sendable {
    case clarity
    case context
    case role
    case delimiting
    case outputFormat = "output_format"
    case examples
    case reasoning
    case verifiability
    case decomposition
    case placeholders
}

public enum LlmReviewSeverity: String, CaseIterable, Sendable {
    case high
    case medium
    case low
}

public struct LlmReview: Equatable, Sendable {
    public let summary: String
    public let findings: [Finding]

    public struct Finding: Equatable, Sendable {
        public let criterion: LlmRubricCriterion
        public let severity: LlmReviewSeverity
        public let quote: String
        public let problem: String
        public let suggestion: String
        /// Matched against the exact input snapshot, never approximate text.
        public let quoteMatch: QuoteMatch
    }

    public enum QuoteMatch: Equatable, Sendable {
        /// Zero-based UTF-8 byte range in the input source; first exact occurrence.
        case matched(byteRange: Range<Int>)
        case unmatched
    }

    public static var jsonSchema: Data { LlmSchemas.review.jsonSchema }
}
