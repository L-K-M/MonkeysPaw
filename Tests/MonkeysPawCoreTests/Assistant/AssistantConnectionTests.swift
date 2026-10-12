import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantConnectionTests: XCTestCase {
    func testBothProtocolsListAllPagesDeduplicateAndSortDeterministically() async throws {
        let pages = try [ConnectionHarness.page([["id": "z", "display_name": "Z", "unknown": 1],
                                                ["id": "a", "display_name": "Second"]], more: true, last: "a"),
                         ConnectionHarness.page([["id": "a", "display_name": "First"], ["id": "m"]], more: true, last: "m"),
                         ConnectionHarness.page([["id": "m", "display_name": "Middle"]])]
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            let harness = ConnectionHarness(pages.map { .response($0) })
            try await assertResult(harness, draft: harness.draft(kind), expected: .ok(models: [
                ModelDescriptor(id: "a", displayName: "First"), ModelDescriptor(id: "m", displayName: "Middle"),
                ModelDescriptor(id: "z", displayName: "Z")]))
            let requests = await harness.transport.snapshot()
            XCTAssertEqual(requests.count, 3)
            XCTAssertTrue(requests.allSatisfy { $0.deadline == requests[0].deadline })
            XCTAssertNil(URLComponents(url: requests[0].url, resolvingAgainstBaseURL: false)?.query)
            for (request, cursor) in zip(requests.dropFirst(), ["a", "m"]) {
                XCTAssertEqual(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems,
                               [URLQueryItem(name: "after_id", value: cursor)])
            }
            XCTAssertTrue(harness.provider.files.attemptedWrites.isEmpty)
            XCTAssertTrue(harness.provider.secrets.writes.isEmpty)
        }
    }

    func testBothProtocolsAcceptEmptyListsAndNoModelSelection() async throws {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            let harness = ConnectionHarness([.response(try ConnectionHarness.page())])
            var draft = harness.draft(kind)
            draft.modelID = ""
            try await assertResult(harness, draft: draft, expected: .ok(models: []))
        }
    }

    func testEveryHTTPResultIsTypedBodyFreeAndDoesNotRetry() async throws {
        let sentinel = UUID().uuidString
        let cases: [(Int, ConnectionTestResult)] = [(401, .authentication), (403, .authentication), (404, .notFound),
            (429, .rateLimited(retryAfter: 17)), (405, .unsupportedListing), (501, .unsupportedListing),
            (500, .providerFailure(statusCode: 500)), (529, .providerFailure(statusCode: 529)),
            (400, .providerFailure(statusCode: 400)), (204, .providerFailure(statusCode: 204))]
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            for (status, expected) in cases {
                let harness = ConnectionHarness([.response(HTTPResponse(statusCode: status,
                    headers: ["Retry-After": "17"], body: Data(sentinel.utf8)))])
                var draft = harness.draft(kind)
                draft.key = .replace(SecretValue(sentinel))
                let result = try await run(harness, draft: draft)
                XCTAssertEqual(result, expected)
                assertRedacted(result, sentinel: sentinel)
                let requests = await harness.transport.snapshot()
                XCTAssertEqual(requests.count, 1)
                XCTAssertTrue(harness.provider.log.lines.isEmpty)
            }
        }
    }

    func testRetryAfterMissingInvalidAndPastDatePreserveOnlyParsedDelay() async throws {
        for (header, delay) in [(nil, nil), ("not-a-delay", nil), ("-1", nil), ("Wed, 21 Oct 2015 07:28:00 GMT", 0.0)] {
            let headers = header.map { ["Retry-After": $0] } ?? [:]
            let harness = ConnectionHarness([.response(HTTPResponse(statusCode: 429, headers: headers, body: Data()))])
            try await assertResult(harness, expected: .rateLimited(retryAfter: delay))
        }
    }

    func testTransportFailuresAndUntypedErrorsAreSanitized() async throws {
        let cases: [(HTTPTransportError, ConnectionTestResult)] = [(.networkFailure, .network), (.redirectRefused, .network),
            (.deadlineExceeded, .timeout), (.cancelled, .cancelled), (.invalidResponse, .invalidResponse),
            (.responseTooLarge, .invalidResponse), (.invalidRequest, .invalidResponse)]
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            for (failure, expected) in cases {
                let harness = ConnectionHarness([.failure(failure)])
                try await assertResult(harness, draft: harness.draft(kind), expected: expected)
            }
            let sentinel = UUID().uuidString
            let harness = ConnectionHarness([.unsafeFailure(sentinel)])
            let result = try await run(harness, draft: harness.draft(kind))
            XCTAssertEqual(result, .network)
            assertRedacted(result, sentinel: sentinel)
        }
    }

    func testMalformedSuccessfulListsNeverReturnPartialModels() async throws {
        let bodies = [Data(), Data("not-json".utf8), Data("{\"data\":[{\"id\":\"ok\"},{}]}".utf8),
            Data("{\"data\":[],\"has_more\":\"yes\"}".utf8)]
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            for body in bodies {
                let harness = ConnectionHarness([.response(HTTPResponse(statusCode: 200, body: body))])
                try await assertResult(harness, draft: harness.draft(kind), expected: .invalidResponse)
            }
            let harness = ConnectionHarness([.response(try ConnectionHarness.page([["id": "partial"]], more: true, last: "partial")),
                .response(HTTPResponse(statusCode: 401, body: Data()))])
            try await assertResult(harness, draft: harness.draft(kind), expected: .authentication)
        }
    }

    func testBrokenPaginationAndCursorCyclesFailWithoutLooping() async throws {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            for page in try [ConnectionHarness.page([], more: true, last: "a"),
                             ConnectionHarness.page([["id": "a"]], more: true)] {
                let harness = ConnectionHarness([.response(page)])
                try await assertResult(harness, draft: harness.draft(kind), expected: .invalidResponse)
                let requests = await harness.transport.snapshot()
                XCTAssertEqual(requests.count, 1)
            }
            let pages = try ["a", "b", "a"].map { (id: String) in
                try ConnectionHarness.page([["id": id]], more: true, last: id)
            }
            let harness = ConnectionHarness(pages.map { .response($0) })
            try await assertResult(harness, draft: harness.draft(kind), expected: .invalidResponse)
            let requests = await harness.transport.snapshot()
            XCTAssertEqual(requests.count, 3)
        }
    }

    func testAccumulatedEntryAndPageLimitsFailExplicitly() async throws {
        let entries = (0...Limits.modelListEntryCap).map { ["id": "model-\($0)"] }
        let oversized = ConnectionHarness([.response(try ConnectionHarness.page(entries))])
        try await assertResult(oversized, expected: .invalidResponse)
        let pages = try (0...Limits.modelListPageCap).map {
            try ConnectionTransport.Reply.response(ConnectionHarness.page([["id": "model-\($0)"]], more: true, last: "model-\($0)"))
        }
        let harness = ConnectionHarness(pages)
        try await assertResult(harness, expected: .invalidResponse)
        let requests = await harness.transport.snapshot()
        XCTAssertEqual(requests.count, Limits.modelListPageCap)
    }

    func testAccumulatedStringBytesAreBoundedAcrossPages() async throws {
        let name = String(repeating: "x", count: Limits.modelListByteCap / 2)
        let harness = ConnectionHarness([
            .response(try ConnectionHarness.page([["id": "a", "display_name": name]], more: true, last: "a")),
            .response(try ConnectionHarness.page([["id": "b", "display_name": name]]))])
        try await assertResult(harness, expected: .invalidResponse)
    }

    func testModelIDsDeduplicateByExactUTF8Bytes() async throws {
        let composed = "é"
        let decomposed = "e\u{301}"
        let harness = ConnectionHarness([.response(try ConnectionHarness.page([
            ["id": composed], ["id": decomposed], ["id": composed]]))])
        let result = try await run(harness)
        guard case .ok(let models) = result else { return XCTFail("Expected success") }
        XCTAssertEqual(models.map { Data($0.id.utf8) }, [Data(decomposed.utf8), Data(composed.utf8)])
    }

    func testUnreadableSettingsAndSecretsStayTypedAndNeverSend() async throws {
        let settings = ConnectionHarness([])
        try settings.provider.files.memory.write(Data("corrupt".utf8), at: "provider-settings.json")
        try await assertResult(settings, expected: .settings(.corruptFile))
        XCTAssertTrue(settings.provider.files.attemptedWrites.isEmpty)
        let secrets = ConnectionHarness([])
        secrets.provider.secrets.readError = SecretStoreError.locked
        try await assertResult(secrets, draft: ProviderDraft(kind: .openaiCompatible), expected: .settings(.secret(.locked)))
        let requests = await secrets.transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testTestUsesDraftAccountInsteadOfSelectedProfileAndNeverWrites() async throws {
        let harness = ConnectionHarness([.response(try ConnectionHarness.page())])
        var selected = harness.draft()
        selected.key = .replace(SecretValue(UUID().uuidString))
        var other = harness.draft()
        let otherKey = UUID().uuidString
        other.key = .replace(SecretValue(otherKey))
        try harness.provider.service.save(selected)
        try harness.provider.service.save(other)
        let snapshot = harness.provider.service.snapshot
        let settings = try harness.provider.files.read(at: "provider-settings.json")
        let writes = harness.provider.files.attemptedWrites.count
        let secretWrites = harness.provider.secrets.writes.count
        let persisted = harness.provider.secrets.persisted
        other.key = .keep
        try await assertResult(harness, draft: other, expected: .ok(models: []))
        let requests = await harness.transport.snapshot()
        XCTAssertTrue(requests[0].headers["Authorization"] == "Bearer " + otherKey)
        XCTAssertEqual(harness.provider.service.snapshot, snapshot)
        XCTAssertEqual(try harness.provider.files.read(at: "provider-settings.json"), settings)
        XCTAssertEqual(harness.provider.files.attemptedWrites.count, writes)
        XCTAssertEqual(harness.provider.secrets.writes.count, secretWrites)
        XCTAssertEqual(harness.provider.secrets.persisted, persisted)
        XCTAssertTrue(harness.provider.secrets.deletions.isEmpty)
        XCTAssertEqual(Set(harness.provider.secrets.reads.suffix(1).map { $0.0 }), [.provider(other.id)])
    }

    func testUnsavedReplacementAndClearOnlyAffectTheTestRequest() async throws {
        for edit in [ProviderKeyEdit.replace(SecretValue(UUID().uuidString)), .clear] {
            let harness = ConnectionHarness([.response(try ConnectionHarness.page())])
            var draft = harness.draft()
            try harness.provider.service.save(draft)
            let persisted = harness.provider.secrets.persisted
            let fileWrites = harness.provider.files.attemptedWrites.count
            let writes = harness.provider.secrets.writes.count
            draft.baseURL = "http://localhost:8080/custom"
            draft.modelID = "unsaved-model"
            draft.key = edit
            try await assertResult(harness, draft: draft, expected: .ok(models: []))
            let requests = await harness.transport.snapshot()
            let request = try XCTUnwrap(requests.first)
            if case .replace(let key) = edit {
                XCTAssertTrue(request.headers["Authorization"] == key.withValue { "Bearer " + $0 })
            } else { XCTAssertNil(request.headers["Authorization"]) }
            XCTAssertEqual(request.url.absoluteString, "http://localhost:8080/custom/models")
            XCTAssertEqual(harness.provider.secrets.persisted, persisted)
            XCTAssertEqual(harness.provider.files.attemptedWrites.count, fileWrites)
            XCTAssertEqual(harness.provider.secrets.writes.count, writes)
            XCTAssertTrue(harness.provider.secrets.deletions.isEmpty)
        }
    }

    func testNewKeylessDraftDoesNotBorrowSavedProfileKey() async throws {
        let harness = ConnectionHarness([.response(try ConnectionHarness.page())])
        try harness.provider.service.save(harness.draft())
        let draft = ProviderDraft(kind: .openaiCompatible, baseURL: "http://localhost:8080", modelID: "")
        try await assertResult(harness, draft: draft, expected: .ok(models: []))
        let requests = await harness.transport.snapshot()
        XCTAssertNil(requests[0].headers["Authorization"])
        XCTAssertEqual(harness.provider.secrets.reads.last?.0, .provider(draft.id))
    }

    func testResolutionFailuresPreventOutboundWork() async throws {
        let harness = ConnectionHarness([])
        var draft = harness.draft()
        try harness.provider.service.save(draft)
        draft.key = .keep
        draft.baseURL = "https://another.example"
        try await assertResult(harness, draft: draft, expected: .settings(.keyRequiredForChangedDestination))
        draft.baseURL = "https://example.com?key=secret"
        try await assertResult(harness, draft: draft, expected: .settings(.queryOrFragmentInURL))
        draft = harness.draft(.anthropic)
        draft.key = .clear
        try await assertResult(harness, draft: draft, expected: .authentication)
        draft.key = .replace(SecretValue("invalid\nkey"))
        try await assertResult(harness, draft: draft, expected: .settings(.invalidKey))
        let requests = await harness.transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCredentialReadsRunOnBackgroundWorkAndResultsUseMainThread() async throws {
        let work = ConnectionQueuedWork()
        let harness = ConnectionHarness([.response(try ConnectionHarness.page())], work: work)
        let queued = expectation(description: "Main callback queued")
        harness.main.onEnqueue = { queued.fulfill() }
        var called = false
        let draft = ProviderDraft(kind: .openaiCompatible)
        harness.service.testConnection(draft: draft) { _ in
            XCTAssertTrue(harness.main.isRunning)
            called = true
        }
        XCTAssertTrue(harness.provider.secrets.reads.isEmpty)
        XCTAssertFalse(called)
        work.drain()
        await fulfillment(of: [queued], timeout: 3)
        XCTAssertFalse(called)
        XCTAssertFalse(harness.provider.secrets.reads.isEmpty)
        harness.main.drain()
        XCTAssertTrue(called)
    }

    func testFifteenSecondDeadlineStartsAtIntentAndIsSharedAcrossPages() async throws {
        let clock = ConnectionManualClock()
        let start = clock.now()
        let harness = ConnectionHarness([.response(try ConnectionHarness.page([["id": "a"]], more: true, last: "a")),
            .response(try ConnectionHarness.page([["id": "b"]], more: true, last: "b"))],
            now: { clock.now() }, afterSend: { clock.advance(by: .seconds(8)) })
        try await assertResult(harness, expected: .timeout)
        let requests = await harness.transport.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.deadline == start.advanced(by: .seconds(15)) })
    }

    func testExhaustedBudgetBeforeBackgroundWorkPreventsCredentialReadAndHTTP() async throws {
        let work = ConnectionQueuedWork()
        let clock = ConnectionManualClock()
        let harness = ConnectionHarness([], work: work, now: { clock.now() })
        var result: ConnectionTestResult?
        harness.service.testConnection(draft: harness.draft()) { result = $0 }
        clock.advance(by: .seconds(15))
        work.drain()
        harness.main.drain()
        XCTAssertEqual(result, .timeout)
        XCTAssertTrue(harness.provider.secrets.reads.isEmpty)
        let requests = await harness.transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDeadlineCancelsWaitingTransportAndCompletesOnce() async throws {
        let harness = ConnectionHarness([.waiting], timeout: .milliseconds(100))
        try await assertResult(harness, expected: .timeout)
        await harness.transport.waitUntilCancelled()
        XCTAssertEqual(harness.main.count, 0)
    }

    func testDeadlineCompletesEvenWhenBackgroundWorkHasNotStarted() async throws {
        let work = ConnectionQueuedWork()
        let harness = ConnectionHarness([], work: work, timeout: .milliseconds(20))
        try await assertResult(harness, expected: .timeout)
        work.drain()
        XCTAssertTrue(harness.provider.secrets.reads.isEmpty)
        XCTAssertEqual(harness.main.count, 0)
    }

    func testCancelBeforeBackgroundWorkPreventsCredentialReadAndCompletesOnce() async throws {
        let work = ConnectionQueuedWork()
        let harness = ConnectionHarness([], work: work)
        var results: [ConnectionTestResult] = []
        let test = harness.service.testConnection(draft: harness.draft()) { result in
            XCTAssertTrue(harness.main.isRunning)
            results.append(result)
        }
        test.cancel()
        test.cancel()
        work.drain()
        XCTAssertEqual(harness.main.count, 1)
        harness.main.drain()
        XCTAssertEqual(results, [.cancelled])
        XCTAssertTrue(harness.provider.secrets.reads.isEmpty)
        let requests = await harness.transport.snapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancelDuringEitherPageCancelsTransportAndDoesNotPublishPartialModels() async throws {
        for page in [1, 2] {
            let replies: [ConnectionTransport.Reply] = page == 1 ? [.waiting] :
                [.response(try ConnectionHarness.page([["id": "a"]], more: true, last: "a")), .waiting]
            let harness = ConnectionHarness(replies)
            var results: [ConnectionTestResult] = []
            let test = harness.service.testConnection(draft: harness.draft()) { results.append($0) }
            await harness.transport.waitUntilSent(page)
            test.cancel()
            harness.main.drain()
            await harness.transport.waitUntilCancelled()
            XCTAssertEqual(results, [.cancelled])
            XCTAssertEqual(harness.main.count, 0)
            XCTAssertTrue(harness.provider.files.attemptedWrites.isEmpty)
        }
    }

    func testProfileSwitchRejectsAlreadyQueuedSuccess() async throws {
        let harness = ConnectionHarness([.response(try ConnectionHarness.page([["id": "old-model"]]))])
        let draft = harness.draft()
        var picker = AssistantModelPickerState(draft: draft)
        let request = picker.beginTest()
        let queued = expectation(description: "Old callback queued")
        harness.main.onEnqueue = { queued.fulfill() }
        harness.service.testConnection(draft: draft) { result in
            XCTAssertFalse(picker.receive(result, for: request))
        }
        await fulfillment(of: [queued], timeout: 3)
        picker.update(draft: harness.draft())
        harness.main.drain()
        XCTAssertTrue(picker.availableModels.isEmpty)
    }

    func testDraftEditRejectsTransportReplyThatIgnoresCancellation() async throws {
        let harness = ConnectionHarness([.held])
        var draft = harness.draft()
        var picker = AssistantModelPickerState(draft: draft)
        let request = picker.beginTest()
        let queued = expectation(description: "Callback queued")
        harness.main.onEnqueue = { queued.fulfill() }
        harness.service.testConnection(draft: draft) { result in
            XCTAssertFalse(picker.receive(result, for: request))
        }
        await harness.transport.waitUntilSent()
        draft.key = .replace(SecretValue(UUID().uuidString))
        picker.update(draft: draft)
        await harness.transport.release(try ConnectionHarness.page([["id": "old-model"]]))
        await fulfillment(of: [queued], timeout: 3)
        harness.main.drain()
        XCTAssertTrue(picker.availableModels.isEmpty)
    }

    func testDiagnosticsRedactProviderEchoedKeyAndManualDraftValues() async throws {
        let sentinel = UUID().uuidString
        let harness = ConnectionHarness([.response(try ConnectionHarness.page([["id": sentinel, "name": sentinel]]))])
        var draft = harness.draft()
        draft.key = .replace(SecretValue(sentinel))
        draft.modelID = sentinel
        let result = try await run(harness, draft: draft)
        var picker = AssistantModelPickerState(draft: draft)
        let initialRequest1 = picker.beginTest()
        picker.receive(result, for: initialRequest1)
        assertRedacted(result, sentinel: sentinel)
        assertRedacted(picker, sentinel: sentinel)
        assertRedacted(harness.service, sentinel: sentinel)
        harness.main.onEnqueue = nil
        let test = harness.service.testConnection(draft: draft) { _ in }
        test.cancel()
        assertRedacted(test, sentinel: sentinel)
        XCTAssertTrue(harness.provider.files.attemptedWrites.isEmpty)
        XCTAssertTrue(harness.provider.secrets.writes.isEmpty)
        XCTAssertTrue(harness.provider.log.lines.isEmpty)
    }

    private func assertResult(_ harness: ConnectionHarness, draft: ProviderDraft? = nil,
                              expected: ConnectionTestResult, file: StaticString = #filePath,
                              line: UInt = #line) async throws {
        let result = try await run(harness, draft: draft)
        XCTAssertEqual(result, expected, file: file, line: line)
    }

    private func run(_ harness: ConnectionHarness, draft: ProviderDraft? = nil) async throws -> ConnectionTestResult {
        let queued = expectation(description: "Result queued through MainThread")
        harness.main.onEnqueue = { queued.fulfill() }
        var result: ConnectionTestResult?
        harness.service.testConnection(draft: draft ?? harness.draft()) {
            XCTAssertTrue(harness.main.isRunning)
            result = $0
        }
        await fulfillment(of: [queued], timeout: 3)
        XCTAssertNil(result)
        harness.main.drain()
        return try XCTUnwrap(result)
    }

    private func assertRedacted(_ value: Any, sentinel: String) {
        XCTAssertFalse(String(describing: value).contains(sentinel))
        XCTAssertFalse(String(reflecting: value).contains(sentinel))
        var diagnostic = ""
        dump(value, to: &diagnostic)
        XCTAssertFalse(diagnostic.contains(sentinel))
    }
}
