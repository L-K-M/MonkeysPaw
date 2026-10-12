import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantModelPickerTests: XCTestCase {
    func testByteDistinctUnicodeDraftEditsInvalidatePendingReply() {
        let composed = "é"
        let decomposed = "e\u{301}"
        let draft = ProviderDraft(displayName: composed, baseURL: "https://example.com/\(composed)",
                                  modelID: composed, key: .replace(SecretValue(composed)))
        let edits: [(inout ProviderDraft) -> Void] = [
            { $0.displayName = decomposed }, { $0.baseURL = "https://example.com/\(decomposed)" },
            { $0.modelID = decomposed }, { $0.key = .replace(SecretValue(decomposed)) }
        ]
        for edit in edits {
            var picker = AssistantModelPickerState(draft: draft)
            let request = picker.beginTest()
            var changed = draft
            edit(&changed)
            picker.update(draft: changed)
            XCTAssertFalse(picker.receive(.ok(models: [ModelDescriptor(id: "old")]), for: request))
        }
    }

    func testManualIDSurvivesEmptyFailedAndUnsupportedListsWithoutSelection() {
        let draft = ProviderDraft(kind: .openaiCompatible, modelID: "unlisted-model")
        var picker = AssistantModelPickerState(draft: draft)
        let models = [ModelDescriptor(id: "suggestion")]
        let initialRequest1 = picker.beginTest()
        picker.receive(.ok(models: models), for: initialRequest1)
        XCTAssertEqual(picker.manualModelID, "unlisted-model")
        for result in [ConnectionTestResult.network, .unsupportedListing, .authentication, .timeout, .invalidResponse] {
            let initialRequest2 = picker.beginTest()
            picker.receive(result, for: initialRequest2)
            XCTAssertEqual(picker.availableModels, models)
            XCTAssertEqual(picker.manualModelID, "unlisted-model")
            XCTAssertEqual(picker.lastResult, result)
        }
        let initialRequest3 = picker.beginTest()
        picker.receive(.ok(models: []), for: initialRequest3)
        XCTAssertTrue(picker.availableModels.isEmpty)
        XCTAssertEqual(picker.manualModelID, "unlisted-model")
        var edited = draft
        edited.modelID = "another-unlisted-model"
        picker.update(draft: edited)
        XCTAssertEqual(picker.manualModelID, edited.modelID)
    }

    func testEveryDraftEditInvalidatesAvailableModelsAndInFlightReply() {
        let draft = ProviderDraft(key: .replace(SecretValue("key")))
        let edits: [(inout ProviderDraft) -> Void] = [
            { $0.displayName = "Renamed" }, { $0.kind = .openaiCompatible },
            { $0.baseURL = "https://another.example/custom" }, { $0.modelID = "typed-id" },
            { $0.key = .replace(SecretValue("new-key")) }, { $0.key = .clear }, { $0.key = .keep }
        ]
        for edit in edits {
            var picker = AssistantModelPickerState(draft: draft)
            let initialRequest4 = picker.beginTest()
            picker.receive(.ok(models: [ModelDescriptor(id: "old")]), for: initialRequest4)
            let pending = picker.beginTest()
            var changed = draft
            edit(&changed)
            picker.update(draft: changed)
            XCTAssertFalse(picker.receive(.ok(models: [ModelDescriptor(id: "late")]), for: pending))
            XCTAssertTrue(picker.availableModels.isEmpty)
            XCTAssertNil(picker.lastResult)
            XCTAssertFalse(picker.isTesting)
            XCTAssertEqual(picker.manualModelID, changed.modelID)
        }
    }

    func testProfileSwitchAwayAndBackDoesNotReviveOldGeneration() {
        let first = ProviderDraft()
        var picker = AssistantModelPickerState(draft: first)
        let request = picker.beginTest()
        picker.update(draft: ProviderDraft())
        picker.update(draft: first)
        let current = picker.beginTest()
        XCTAssertFalse(picker.receive(.ok(models: [ModelDescriptor(id: "old")]), for: request))
        XCTAssertTrue(picker.isTesting)
        XCTAssertTrue(picker.receive(.ok(models: [ModelDescriptor(id: "current")]), for: current))
        XCTAssertEqual(picker.availableModels.map(\.id), ["current"])
    }

    func testNewerTestRejectsOlderReplyAndRepeatedDelivery() {
        var picker = AssistantModelPickerState(draft: ProviderDraft())
        let first = picker.beginTest()
        let second = picker.beginTest()
        XCTAssertFalse(picker.receive(.ok(models: [ModelDescriptor(id: "old")]), for: first))
        XCTAssertTrue(picker.receive(.ok(models: [ModelDescriptor(id: "new")]), for: second))
        XCTAssertFalse(picker.receive(.ok(models: []), for: second))
        XCTAssertEqual(picker.availableModels.map(\.id), ["new"])
    }

    func testUnchangedDraftKeepsSuggestionsAndPendingRequest() {
        let draft = ProviderDraft()
        var picker = AssistantModelPickerState(draft: draft)
        let initialRequest5 = picker.beginTest()
        picker.receive(.ok(models: [ModelDescriptor(id: "model")]), for: initialRequest5)
        let pending = picker.beginTest()
        picker.update(draft: draft)
        XCTAssertTrue(picker.isTesting)
        XCTAssertEqual(picker.availableModels.map(\.id), ["model"])
        XCTAssertTrue(picker.receive(.network, for: pending))
    }

    func testCancellationInvalidatesGenerationAndKeepsManualIDAndSuggestions() {
        var picker = AssistantModelPickerState(draft: ProviderDraft(modelID: "manual"))
        let initialRequest6 = picker.beginTest()
        picker.receive(.ok(models: [ModelDescriptor(id: "suggestion")]), for: initialRequest6)
        let pending = picker.beginTest()
        picker.cancelTest()
        XCTAssertFalse(picker.receive(.ok(models: []), for: pending))
        XCTAssertEqual(picker.lastResult, .cancelled)
        XCTAssertEqual(picker.manualModelID, "manual")
        XCTAssertEqual(picker.availableModels.map(\.id), ["suggestion"])
    }
}
