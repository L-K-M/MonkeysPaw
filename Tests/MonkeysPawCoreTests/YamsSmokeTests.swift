import XCTest
import Yams

final class YamsSmokeTests: XCTestCase {
    private struct PromptMetadata: Codable, Equatable {
        let title: String
        let tags: [String]
    }

    func testCodableYAMLRoundTrip() throws {
        let original = PromptMetadata(title: "Summarize", tags: ["writing", "review"])

        let yaml = try YAMLEncoder().encode(original)
        let decoded = try YAMLDecoder().decode(PromptMetadata.self, from: yaml)

        XCTAssertEqual(decoded, original)
    }
}
