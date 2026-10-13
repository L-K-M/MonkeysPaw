import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MonkeysPawCore

final class URLSessionHTTPTransferTests: XCTestCase {
    func testAdvertisedCapErrorSurvivesReentrantCancellationAndDeadline() async throws {
        let url = URL(string: "http://127.0.0.1:1/")!
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        let transfer = HTTPTransfer(cap: 64, deadline: deadline)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "65"]))

        transfer.urlSession(session, dataTask: task, didReceive: response) { disposition in
            XCTAssertEqual(disposition, .cancel)
            // Model a cancellation callback, then expiry, while URLSession
            // handles the disposition. The cap error was already observed.
            transfer.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
            transfer.finish(.failure(.deadlineExceeded))
        }

        await assertCapError(transfer, url: url, deadline: deadline)
    }

    func testReceiptCapAccumulatesAcrossCallbacksAndSurvivesLaterCompletion() async throws {
        let url = URL(string: "http://127.0.0.1:1/")!
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        let transfer = HTTPTransfer(cap: 64, deadline: deadline)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 500, httpVersion: "HTTP/1.1",
            headerFields: [:]))

        transfer.urlSession(session, dataTask: task, didReceive: response) { disposition in
            XCTAssertEqual(disposition, .allow)
        }
        transfer.urlSession(session, dataTask: task, didReceive: Data(repeating: 65, count: 32))
        transfer.urlSession(session, dataTask: task, didReceive: Data(repeating: 65, count: 32))
        transfer.urlSession(session, dataTask: task, didReceive: Data([66]))
        transfer.finish(.failure(.deadlineExceeded))
        transfer.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))

        await assertCapError(transfer, url: url, deadline: deadline)
    }

    #if !canImport(FoundationNetworking)
    func testHTTPAuthenticationPreservesFailureResponseThroughReentrantCancellation() async throws {
        let url = URL(string: "http://127.0.0.1:1/")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let methods = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                       NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate]

        for method in methods {
            for status in [401, 407] {
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                let transfer = HTTPTransfer(cap: 64, deadline: deadline)
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: ["X-Auth": "denied"]))
                let space = URLProtectionSpace(host: "127.0.0.1", port: 1, protocol: "http", realm: "test",
                    authenticationMethod: method)
                let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                    previousFailureCount: 0, failureResponse: response, error: nil, sender: HTTPChallengeSender())

                transfer.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
                    XCTAssertEqual(disposition, .cancelAuthenticationChallenge, method)
                    XCTAssertNil(credential, method)
                    // CFNetwork can report cancellation while handling the disposition.
                    transfer.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
                    transfer.finish(.failure(.deadlineExceeded))
                }

                let request = try HTTPRequest(url: url, method: .post, responseByteCap: 64, deadline: deadline)
                let result = try await withCheckedThrowingContinuation { continuation in
                    transfer.start(request, url: url, continuation: continuation)
                }
                XCTAssertEqual(result.statusCode, status, method)
                XCTAssertEqual(result.headers["x-auth"], "denied", method)
                XCTAssertTrue(result.body.isEmpty, method)
            }
        }
    }

    func testServerTrustChallengeKeepsDefaultHandling() {
        let url = URL(string: "https://example.com/")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let transfer = HTTPTransfer(cap: 64, deadline: .now.advanced(by: .seconds(3)))
        let space = URLProtectionSpace(host: "example.com", port: 443, protocol: "https", realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: HTTPChallengeSender())

        transfer.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .performDefaultHandling)
            XCTAssertNil(credential)
        }
    }
    #endif

    private func assertCapError(_ transfer: HTTPTransfer, url: URL, deadline: ContinuousClock.Instant,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let request = try HTTPRequest(url: url, method: .get, responseByteCap: 64, deadline: deadline)
            _ = try await withCheckedThrowingContinuation { continuation in
                transfer.start(request, url: url, continuation: continuation)
            }
            XCTFail("Expected response cap error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? HTTPTransportError, .responseTooLarge, file: file, line: line)
        }
    }
}

#if !canImport(FoundationNetworking)
private final class HTTPChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
#endif
