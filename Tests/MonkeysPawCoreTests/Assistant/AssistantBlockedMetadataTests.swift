import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantBlockedMetadataTests: XCTestCase {
    func testModelCancelDoesNotWaitForBlockedCredentialRead() async throws {
        let started = expectation(description: "credential read blocked")
        let returned = expectation(description: "credential worker returned")
        let h = try BlockingAssistantHarness(onRead: { started.fulfill() }, onReturn: { returned.fulfill() })
        h.model.write(brief: "Brief")
        await fulfillment(of: [started], timeout: 3)
        let fallback = h.releaseAfterDelay()
        defer { fallback.cancel(); h.secrets.allowReturn.signal() }
        h.model.cancel()
        XCTAssertFalse(h.released.value, "Cancel waited for the native credential read")
        XCTAssertEqual(h.model.state.phase, .idle)
        h.secrets.allowReturn.signal()
        await fulfillment(of: [returned], timeout: 3)
    }

    func testModelTimeoutPublishesBeforeBlockedCredentialReadReturns() async throws {
        for queued in [false, true] {
            let started = expectation(description: "credential read blocked")
            let returned = expectation(description: "credential worker returned")
            let completed = expectation(description: "model timeout")
            let h = try BlockingAssistantHarness(queued: queued, budget: .milliseconds(200),
                onRead: { started.fulfill() }, onReturn: { returned.fulfill() })
            var readWasReleased = true
            h.model.onChange = {
                if h.model.state.phase == .failed {
                    readWasReleased = h.released.value
                    completed.fulfill()
                }
            }
            h.model.write(brief: "Brief")
            h.main.drain()
            await fulfillment(of: [started], timeout: 3)
            let fallback = h.releaseAfterDelay()
            defer { fallback.cancel(); h.secrets.allowReturn.signal() }
            if queued {
                for _ in 0..<600 {
                    h.main.drain()
                    if h.model.state.phase == .failed { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            await fulfillment(of: [completed], timeout: 3)
            XCTAssertFalse(readWasReleased, "The deadline callback waited for the native credential read")
            XCTAssertEqual(h.model.state.failure, .assistant(.transport(.deadlineExceeded)))
            h.secrets.allowReturn.signal()
            await fulfillment(of: [returned], timeout: 3)
        }
    }
}

private final class AssistantReleaseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return released }
    func mark() { lock.lock(); released = true; lock.unlock() }
}

private final class BlockingAssistantHarness {
    let secrets: ConnectionBlockingSecrets
    let released = AssistantReleaseFlag()
    let main: AssistantActionMain
    let service: AssistantService
    lazy var model = AssistantModel(service: service, main: main, context: { [unowned self] in
        AssistantContext(libraryID: self.libraryID, profile: self.service.selectedProfile)
    })
    private let libraryID = UUID()

    init(queued: Bool = false, budget: Duration = Limits.llmBudget,
         onRead: @escaping () -> Void, onReturn: @escaping () -> Void) throws {
        main = AssistantActionMain(queued: queued)
        let provider = ProviderHarness()
        try provider.service.save(ProviderDraft(kind: .openaiCompatible, modelID: "manual-model",
                                               key: .replace(SecretValue("test-key"))))
        secrets = ConnectionBlockingSecrets(onRead: onRead)
        let settings = ProviderSettingsService(store: ProviderSettingsStore(files: provider.files), secrets: secrets)
        let transport = ConnectionTransport([])
        service = AssistantService(providerSettings: settings, anthropic: AnthropicClient(transport: transport),
            openAICompatible: OpenAIClient(transport: transport, providerState: ProviderStateStore(files: MemoryFileStore())),
            work: ConnectionBackground(afterWork: onReturn), main: main, timeout: Limits.modelListTimeout,
            now: { ContinuousClock.now }, actionBudget: budget)
    }

    func releaseAfterDelay() -> Task<Void, Never> {
        Task.detached { [secrets, released] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            released.mark()
            secrets.allowReturn.signal()
        }
    }
}
