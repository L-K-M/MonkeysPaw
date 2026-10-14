import Foundation
import XCTest
@testable import MonkeysPawCore

final class GitHubReleaseClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let current = ReleaseVersion("v1.0.0-beta.12")!

    func testExactUnauthenticatedRequestAndBudget() async throws {
        let transport = ConnectionTransport([.response(updateResponse())])
        let before = ContinuousClock.now
        let release = try await GitHubReleaseClient(transport: transport).latestRelease(currentVersion: current, now: { self.now })
        let after = ContinuousClock.now
        let requests = await transport.snapshot()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url.absoluteString, "https://api.github.com/repos/L-K-M/MonkeysPaw/releases/latest")
        XCTAssertEqual(request.method, .get)
        XCTAssertNil(request.body)
        XCTAssertEqual(request.headers, ["Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "MonkeysPaw/1.0.0-beta.12"])
        XCTAssertEqual(request.urlPolicy, .assistant)
        XCTAssertEqual(request.responseByteCap, 1_048_576)
        XCTAssertGreaterThanOrEqual(request.deadline, before.advanced(by: .seconds(15)))
        XCTAssertLessThanOrEqual(request.deadline, after.advanced(by: .seconds(15)))
        XCTAssertEqual(release?.version, ReleaseVersion("2.0.0"))
    }

    func testAllUntrustedResponseURLsAreIgnored() async throws {
        for url in ["https://evil.example/install", "https://github.com.evil.example/L-K-M/MonkeysPaw/releases/tag/v2.0.0",
                    "https://github.com@evil.example/path", "http://github.com/L-K-M/MonkeysPaw/releases/tag/v2.0.0",
                    "https://github.com/other/repo/releases/tag/v2.0.0", "file:///etc/passwd", "javascript:alert(1)",
                    "https://github.com/L-K-M/MonkeysPaw/releases/tag/v2.0.0?token=secret", "invalid"] {
            let transport = ConnectionTransport([.response(updateResponse(htmlURL: url))])
            let release = try await GitHubReleaseClient(transport: transport).latestRelease(currentVersion: current, now: { self.now })
            XCTAssertEqual(release?.page.absoluteString, "https://github.com/L-K-M/MonkeysPaw/releases/tag/v2.0.0")
        }
    }

    func testNoReleaseDraftAndPrereleaseAreDistinctFromMalformed() async throws {
        for response in [HTTPResponse(statusCode: 404, body: Data("ignored error".utf8)),
                         updateResponse(draft: true), updateResponse(tag: "v3.0.0-beta.1", prerelease: true)] {
            let transport = ConnectionTransport([.response(response)])
            let release = try await GitHubReleaseClient(transport: transport).latestRelease(currentVersion: current, now: { self.now })
            XCTAssertNil(release)
        }
        for response in [updateResponse(tag: "2.0.0"), updateResponse(tag: "v3.0.0-beta.1"),
                         updateResponse(tag: "v2.0.0/../../other/repo"), updateResponse(tag: "v2.0.0?x=1"),
                         HTTPResponse(statusCode: 200, body: Data("{}".utf8)),
                         HTTPResponse(statusCode: 200, body: Data("null".utf8)),
                         HTTPResponse(statusCode: 200, body: Data(#"{"tag_name":"v2.0.0","draft":0,"prerelease":false}"#.utf8))] {
            await assertFailure(.response(response), .malformedResponse)
        }
    }

    func test403And429RespectResetAndRetryHeadersWithoutExposingBodies() async {
        for code in [403, 429] {
            let response = HTTPResponse(statusCode: code,
                headers: ["Retry-After": "120", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700000180"],
                body: Data("private diagnostic".utf8))
            await assertFailure(.response(response), .rateLimited(UpdateRateLimit(statusCode: code,
                until: now.addingTimeInterval(180))))
            await assertFailure(.response(HTTPResponse(statusCode: code, body: Data())),
                .rateLimited(UpdateRateLimit(statusCode: code, until: now.addingTimeInterval(60))))
            await assertFailure(.response(HTTPResponse(statusCode: code, headers: ["Retry-After": "NaN"], body: Data())),
                .rateLimited(UpdateRateLimit(statusCode: code, until: now.addingTimeInterval(60))))
        }
    }

    func testTransportAndHTTPFailuresAreSanitizedAndNeverUpToDate() async {
        await assertFailure(.failure(.networkFailure), .offline)
        await assertFailure(.unsafeFailure("secret provider body"), .offline)
        for error in [HTTPTransportError.redirectRefused, .deadlineExceeded, .responseTooLarge, .cancelled, .invalidResponse] {
            await assertFailure(.failure(error), .transport(error))
        }
        await assertFailure(.response(HTTPResponse(statusCode: 302, headers: ["Location": "https://evil.example"], body: Data())),
                            .transport(.redirectRefused))
        await assertFailure(.response(HTTPResponse(statusCode: 503, body: Data("private error".utf8))), .httpStatus(503))
    }

    func testClientAlsoRejectsOversizedBodiesFromANonconformingFake() async {
        await assertFailure(.response(HTTPResponse(statusCode: 200,
            body: Data(repeating: 32, count: Limits.updateResponseCap + 1))), .transport(.responseTooLarge))
    }

    private func assertFailure(_ reply: ConnectionTransport.Reply, _ expected: UpdateCheckFailure,
                               file: StaticString = #filePath, line: UInt = #line) async {
        let transport = ConnectionTransport([reply])
        do {
            _ = try await GitHubReleaseClient(transport: transport).latestRelease(currentVersion: current, now: { self.now })
            XCTFail("Expected a typed failure", file: file, line: line)
        } catch { XCTAssertEqual(error as? UpdateCheckFailure, expected, file: file, line: line) }
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1, "No retries", file: file, line: line)
    }
}
