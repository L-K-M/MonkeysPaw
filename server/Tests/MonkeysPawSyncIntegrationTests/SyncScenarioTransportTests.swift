import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import NIOEmbedded
import XCTest
@testable import MonkeysPawCore
@testable import MonkeysPawServer

final class SyncScenarioTransportTests: XCTestCase {
    func testScenarioPeerChannelClosesAfterSuccessAndFailure() async throws {
        for status in [200, 500] {
            let capture = PeerChannelCapture()
            let router = Router(context: PeerChannelContext.self)
            router.get("/probe") { _, context -> Response in
                capture.channel = context.channel as? NIOAsyncTestingChannel
                XCTAssertNotNil(capture.channel)
                if status == 500 { throw HTTPError(.internalServerError) }
                return Response(status: .ok)
            }
            let app = ScenarioPeerApplication(base: Application(router: router))
            try await app.test(.router) { client in
                let response = try await client.executeRequest(uri: "/probe", method: .get, headers: [:], body: nil)
                XCTAssertEqual(response.status.code, status)
                XCTAssertNil(capture.channel, "Scenario peer channel must be released")
                if let channel = capture.channel { _ = try await channel.finish(acceptAlreadyClosed: true) }
            }
        }
    }

    func testResponseRewriteRemainsPendingUntilApplied() async throws {
        let app = makeApplication(configuration: try .init(environment: ["MONKEYSPAW_LOG_LEVEL": "critical"]))
        try await app.test(.router) { client in
            let server = try SyncServerURL("https://main.test")
            for failure in [HTTPTransportError.requestTooLarge, .responseTooLarge] {
                let transport = InProcessHTTPTransport(clients: ["main.test": client])
                transport.rewrite(.init(device: "a", phase: .response, method: .get,
                    path: "/api/health", patch: ["/status": .string("rewritten")]))
                if failure == .requestTooLarge {
                    transport.rewrite(.init(device: "a", phase: .request, method: .get,
                        path: "/api/health", patch: ["/status": .string(String(repeating: "x", count: 256))]))
                }
                let request = try MonkeysPawCore.HTTPRequest(url: server.baseURL.appendingPathComponent("api/health"), method: .get,
                    body: Data("{\"status\":\"original\"}".utf8), requestByteCap: 128,
                    responseByteCap: failure == .responseTooLarge ? 1 : 1024,
                    deadline: ContinuousClock.now.advanced(by: .seconds(30)), urlPolicy: .sync(server: server))
                do {
                    _ = try await transport.send(request)
                    XCTFail("Expected capped transport failure")
                } catch let error as HTTPTransportError {
                    XCTAssertEqual(error, failure)
                }
                XCTAssertEqual(transport.traces.count, failure == .requestTooLarge ? 0 : 1)
                XCTAssertEqual(transport.pendingRewrites, 1, "Unapplied response rewrite must remain pending")

                let retry = try MonkeysPawCore.HTTPRequest(url: request.url, method: .get,
                    deadline: ContinuousClock.now.advanced(by: .seconds(30)), urlPolicy: .sync(server: server))
                let response = try await transport.send(retry)
                let json = try JSONDecoder().decode(ScenarioValue.self, from: response.body)
                XCTAssertEqual(try json.at("/status"), .string("rewritten"))
                XCTAssertEqual(transport.pendingRewrites, 0)
            }
        }
    }
}

private final class PeerChannelCapture: @unchecked Sendable {
    weak var channel: NIOAsyncTestingChannel?
}

private struct PeerChannelContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    let channel: any Channel

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        channel = source.channel
    }
}
