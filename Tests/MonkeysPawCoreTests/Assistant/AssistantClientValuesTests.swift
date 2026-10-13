import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantClientValuesTests: XCTestCase {
    func testActionRequestOutputResponseAndErrorsRedactContentInDiagnostics() throws {
        let sentinel = UUID().uuidString
        var artifact = AssistantOutputFixtures.artifact
        artifact["body"] = sentinel
        let output = AssistantOutput.artifact(try LlmOutputDecoder.artifact(from: AssistantOutputFixtures.json(artifact)))
        let actions: [AssistantAction] = [.write(brief: sentinel), .review(source: sentinel),
            .improve(source: sentinel, instruction: sentinel, selectedFindings: [])]
        let values: [Any] = actions + actions.map { AssistantRequest(action: $0) }
            + [output, AssistantResponse(output: output), AssistantError.unexpectedStop(sentinel)]
        for value in values {
            XCTAssertFalse(String(describing: value).contains(sentinel))
            XCTAssertFalse(String(reflecting: value).contains(sentinel))
            var diagnostic = ""
            dump(value, to: &diagnostic)
            XCTAssertFalse(diagnostic.contains(sentinel))
        }
    }

    func testRequestDefaultsAndModelPageRetainTypedMetadata() {
        XCTAssertNil(AssistantRequest(action: .write(brief: "Brief")).effort)
        XCTAssertEqual(AssistantRequest(action: .review(source: "Source"), effort: .high).effort, .high)
        let page = AssistantModelPage(models: [ModelDescriptor(id: "model", displayName: "Model")],
                                      hasMore: true, firstID: "model", lastID: "model")
        XCTAssertEqual(page.models.first?.displayName, "Model")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.firstID, "model")
        XCTAssertEqual(page.lastID, "model")
        XCTAssertEqual(AssistantError.rateLimited(retryAfter: 15).description, "rateLimited")
    }
}
