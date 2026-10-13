import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantServiceTests: XCTestCase {
    func testPrivatePromptRefusesEveryActionBeforeCredentialReadOrHTTP() async throws {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            for action in 0..<3 {
                let h = try AssistantActionHarness(source: "---\nprivate: true\n---\nSensitive template", kind: kind)
                let reads = h.provider.secrets.reads.count
                let writes = h.provider.files.attemptedWrites.count
                h.ui {
                    if action == 0 { h.model.write(brief: "Brief") }
                    else if action == 1 { h.model.review() }
                    else { h.model.improve() }
                }
                try await h.phase(.failed)
                XCTAssertEqual(h.model.state.failure, .assistant(.privatePrompt))
                XCTAssertEqual(h.provider.secrets.reads.count, reads)
                XCTAssertEqual(h.provider.files.attemptedWrites.count, writes)
                let requests = await h.transport.snapshot()
                XCTAssertTrue(requests.isEmpty)
                XCTAssertFalse(h.model.canAccept)
            }
        }
    }

    func testInvalidReadOnlyConflictedAndMissingBuffersRefuseBeforeHTTP() async throws {
        let cases: [(String?, AssistantFailure)] = [
            (nil, .noEditor), ("Broken {{field", .invalid([PromptIssue(.unbalancedOpener)])),
            ("---\nformat: 2\n---\nFuture", .readOnly(.unsupportedFormat(PromptFormatVersion(2)!)))]
        for (source, expected) in cases {
            let h = try AssistantActionHarness(source: source)
            h.ui { h.model.improve() }
            try await h.phase(.failed)
            if case .invalid = expected {
                guard case .invalid(let issues) = h.model.state.failure else { return XCTFail("Expected local validation failure") }
                XCTAssertTrue(issues.contains { $0.code == .unbalancedOpener })
            } else { XCTAssertEqual(h.model.state.failure, expected) }
            let sent = await h.transport.snapshot()
            XCTAssertTrue(sent.isEmpty)
        }
        let h = try AssistantActionHarness(source: "Original")
        h.editor.ui { h.editor.model.edit("Unsaved") }
        try h.editor.change("External")
        h.editor.settle()
        h.ui { h.model.review() }
        try await h.phase(.failed)
        XCTAssertEqual(h.model.state.failure, .editorConflict)
    }

    func testTemplateRequestsNeverReadOrSendRememberedClipboardOrFillValues() async throws {
        let remembered = "remembered-" + UUID().uuidString
        let clipboard = "clipboard-" + UUID().uuidString
        let filled = "filled-" + UUID().uuidString
        let source = "Use {{topic}} with {{clipboard}}."
        let flow = PromptFlowHarness()
        let entry = try flow.put(source)
        try flow.values.record(identity: entry.identity, values: ["topic": remembered])
        flow.delivery.clipboard.writeText(clipboard)
        try flow.open()
        let form = try flow.openForm()
        form.setValue(filled, name: "topic")
        XCTAssertEqual(form.values["topic"], filled)
        let clipboardReads = flow.delivery.clipboard.readCount
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            for action in 0..<3 {
                let h = try AssistantActionHarness(source: source, kind: kind)
                h.ui {
                    if action == 0 { h.model.write(brief: "Brief {{topic}}") }
                    else if action == 1 { h.model.review() }
                    else { h.model.editInstruction("Improve clarity"); h.model.improve() }
                }
                try await h.sent()
                let requests = await h.transport.snapshot()
                for request in requests {
                    let body = try XCTUnwrap(request.body)
                    for sentinel in [remembered, clipboard, filled] {
                        XCTAssertNil(body.range(of: Data(sentinel.utf8)))
                    }
                }
                if action == 1 { await h.transport.release(try h.response(AssistantOutputFixtures.review)) }
                else { try await h.artifact() }
                try await h.phase(action == 1 ? .draft : .ready)
                XCTAssertEqual(flow.delivery.clipboard.readCount, clipboardReads)
                XCTAssertEqual(try flow.values.rememberedValues(for: entry.identity)["topic"], remembered)
            }
        }
    }

    func testActionBudgetStartsBeforeQueuedWorkAndIsPassedToTransport() async throws {
        let h = try AssistantActionHarness()
        let start = h.time.now()
        h.ui { h.model.write(brief: "Brief") }
        h.time.advance(by: .seconds(8))
        try await h.sent()
        let sent = await h.transport.snapshot()
        XCTAssertEqual(sent[0].deadline, start.advanced(by: Limits.llmBudget))
        h.model.cancel()
        try await h.artifact()

        let expired = try AssistantActionHarness()
        let reads = expired.provider.secrets.reads.count
        expired.ui { expired.model.write(brief: "Brief") }
        expired.time.advance(by: Limits.llmBudget)
        try await expired.phase(.failed)
        XCTAssertEqual(expired.model.state.failure, .assistant(.transport(.deadlineExceeded)))
        XCTAssertEqual(expired.provider.secrets.reads.count, reads)
        let noRequests = await expired.transport.snapshot()
        XCTAssertTrue(noRequests.isEmpty)
    }

    func testTimeoutCompletesWaitingTransportWithoutUserCancellation() async throws {
        let h = try AssistantActionHarness([.waiting], budget: .milliseconds(100))
        h.ui { h.model.write(brief: "Brief") }
        try await h.sent()
        try await h.phase(.failed)
        XCTAssertEqual(h.model.state.failure, .assistant(.transport(.deadlineExceeded)))
        await h.transport.waitUntilCancelled()
        XCTAssertEqual(h.model.state.transcript.count, 1)
    }

    func testCredentialFailureAndMissingConfigurationRemainTyped() async throws {
        let h = try AssistantActionHarness()
        h.provider.secrets.readError = SecretStoreError.readFailed
        h.ui { h.model.write(brief: "Brief") }
        try await h.phase(.failed)
        XCTAssertEqual(h.model.state.failure, .settings(.secret(.readFailed)))
        try h.provider.service.selectProfile(nil)
        h.changed()
        h.ui { h.model.write(brief: "Brief") }
        try await h.phase(.failed)
        XCTAssertEqual(h.model.state.failure, .assistant(.notConfigured))
    }

    func testAccessStateOffersFreshPrivateCopyPreservingMetadataAndBlocksUnavailable() async throws {
        let h = try AssistantActionHarness(source: "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\nx-owner: custom\n---\nOriginal")
        h.access = .group(.viewer)
        h.changed()
        XCTAssertEqual(h.model.state.mutationAccess, .privateCopy)
        h.ui { h.model.improve() }
        try await h.sent()
        try await h.artifact()
        try await h.phase(.ready)
        let candidate = try XCTUnwrap(h.model.state.candidate)
        XCTAssertEqual(candidate.mutationAccess, .privateCopy)
        XCTAssertNotEqual(candidate.content.document.frontMatter.id, ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV"))
        XCTAssertTrue(String(decoding: candidate.content.canonicalBytes, as: UTF8.self).contains("x-owner: custom"))
        for access in [AssistantAccessState.privatePrompt, .group(.editor), .group(.owner)] {
            XCTAssertEqual(access.mutationAccess, .currentScope)
        }
        h.access = .unavailable
        h.changed()
        h.ui { h.model.write(brief: "Brief") }
        try await h.phase(.failed)
        XCTAssertEqual(h.model.state.failure, .assistant(.accessDenied))
    }

    func testServiceCancellationDuringBlockedCredentialReadCompletesOnceOnMainThread() async throws {
        let provider = ProviderHarness()
        try provider.service.save(ProviderDraft(kind: .openaiCompatible, modelID: "manual-model", key: .replace(SecretValue("test-key"))))
        let started = expectation(description: "credential read started")
        let returned = expectation(description: "blocked worker returned")
        let completed = expectation(description: "MainThread callback")
        let secrets = ConnectionBlockingSecrets { started.fulfill() }
        let settings = ProviderSettingsService(store: ProviderSettingsStore(files: provider.files), secrets: secrets)
        let main = AssistantActionMain(queued: false)
        let transport = ConnectionTransport([])
        let service = AssistantService(providerSettings: settings, anthropic: AnthropicClient(transport: transport),
            openAICompatible: OpenAIClient(transport: transport, providerState: ProviderStateStore(files: MemoryFileStore())),
            work: ConnectionBackground(afterWork: { returned.fulfill() }), main: main)
        let context = AssistantContext(libraryID: UUID(), profile: service.selectedProfile)
        var results: [Result<AssistantResponse, AssistantFailure>] = []
        let operation = service.perform(.write(brief: "Brief"), context: context) {
            XCTAssertTrue(main.isRunning)
            results.append($0)
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        operation.cancel()
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(try XCTUnwrap(results.first).failure, .assistant(.transport(.cancelled)))
        secrets.allowReturn.signal()
        await fulfillment(of: [returned], timeout: 3)
        XCTAssertEqual(results.count, 1)
        let requests = await transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testAllNewDiagnosticSurfacesRedactPromptAndProviderContent() async throws {
        let sentinel = "sensitive-" + UUID().uuidString
        let h = try AssistantActionHarness(source: sentinel)
        h.ui { h.model.improve() }
        try await h.sent()
        try await h.artifact(body: sentinel, notes: sentinel)
        try await h.phase(.ready)
        let values: [Any] = [h.model, h.model.state, h.context, try XCTUnwrap(h.context.editor),
            try XCTUnwrap(h.model.state.candidate), try XCTUnwrap(h.model.accept()),
            AssistantCommand.write(brief: sentinel), AssistantFailure.assistant(.unexpectedStop(sentinel))]
        for value in values {
            XCTAssertFalse(String(describing: value).contains(sentinel))
            XCTAssertFalse(String(reflecting: value).contains(sentinel))
            var output = ""
            dump(value, to: &output)
            XCTAssertFalse(output.contains(sentinel))
        }
        XCTAssertTrue(h.provider.log.lines.isEmpty)
    }
}

private extension Result where Failure == AssistantFailure {
    var failure: AssistantFailure? { if case .failure(let failure) = self { return failure }; return nil }
}
