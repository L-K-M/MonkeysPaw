import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MonkeysPawCore

final class URLSessionHTTPTransportTests: XCTestCase {
    private let transport = URLSessionHTTPTransport()

    func testSuccessPreservesRequestAndResponseData() async throws {
        let payload = Data("{\"input\":\"hello\"}".utf8)
        let reply = Data("{\"output\":\"world\"}".utf8)
        let server = try LoopbackHTTPServer { connection, _, _ in
            connection.respond(headers: "X-Reply: received\r\n", body: reply)
        }
        defer { server.stop() }
        let response = try await transport.send(HTTPRequest(url: server.url("/v1/messages?version=1"), method: .post,
            headers: ["Content-Type": "application/json", "X-Test": "supplied"], body: payload,
            deadline: .now.advanced(by: .seconds(3))))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["x-reply"], "received")
        XCTAssertEqual(response.body, reply)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.target, "/v1/messages?version=1")
        XCTAssertEqual(request.headers["x-test"], "supplied")
        XCTAssertEqual(request.body, payload)
    }

    func testHTTPErrorStatusesReturnBoundedDataForProtocolParsing() async throws {
        for status in [400, 401, 429, 500] {
            let data = Data("{\"error\":\"provider detail\"}".utf8)
            let server = try LoopbackHTTPServer { connection, _, _ in
                connection.respond(status: status, headers: "Retry-After: 2\r\n", body: data)
            }
            defer { server.stop() }
            let response = try await transport.send(request(server.url()))
            XCTAssertEqual(response.statusCode, status)
            XCTAssertEqual(response.headers["retry-after"], "2")
            XCTAssertEqual(response.body, data)
        }
    }

    func testChunkedBodyIsAssembledWithoutFraming() async throws {
        let server = try LoopbackHTTPServer { connection, _, _ in
            connection.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
            connection.write("3\r\nabc\r\n5\r\ndefgh\r\n0\r\n\r\n")
        }
        defer { server.stop() }
        let response = try await transport.send(request(server.url(), cap: 8))
        XCTAssertEqual(response.body, Data("abcdefgh".utf8))
    }

    func testCloseDelimitedBodyAndExactCapAreAccepted() async throws {
        let server = try LoopbackHTTPServer { connection, _, _ in
            connection.write("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nabcdefgh")
        }
        defer { server.stop() }
        let response = try await transport.send(request(server.url(), cap: 8))
        XCTAssertEqual(response.body, Data("abcdefgh".utf8))
    }

    func testNormalizedSchemeAndLoopbackHostSpellingConnect() async throws {
        let server = try LoopbackHTTPServer { connection, _, _ in connection.respond(body: Data([1])) }
        defer { server.stop() }
        for url in [server.url(host: "localhost."),
                    URL(string: "HTTP://LOCALHOST:\(server.port)/")!] {
            let response = try await transport.send(request(url))
            XCTAssertEqual(response.body, Data([1]))
        }
        XCTAssertEqual(server.requests.count, 2)
    }

    func testCallerCanSelectSyncCapForBodyLargerThanLLMCap() async throws {
        let data = Data(repeating: 65, count: Limits.responseCap + 1)
        let server = try LoopbackHTTPServer { connection, _, _ in connection.respond(body: data) }
        defer { server.stop() }
        let response = try await transport.send(request(server.url(), cap: Limits.syncResponseCap))
        XCTAssertEqual(response.body, data)
    }

    func testAdvertisedOversizeCancelsBeforeCompleteBodyArrives() async throws {
        let closed = expectation(description: "Oversized length closed the peer")
        let server = try LoopbackHTTPServer { connection, _, _ in
            connection.write("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\nConnection: close\r\n\r\na")
            XCTAssertTrue(connection.waitForPeerClose())
            closed.fulfill()
        }
        defer { server.stop() }
        await assertError(.responseTooLarge, request: try request(server.url(), cap: 64))
        await fulfillment(of: [closed], timeout: 4)
    }

    func testChunkedOversizeCancelsBeforeFinalChunk() async throws {
        let closed = expectation(description: "Chunked overflow closed the peer")
        let server = try LoopbackHTTPServer { connection, _, _ in
            connection.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
            connection.write("40\r\n" + String(repeating: "a", count: 64) + "\r\n1\r\nb\r\n")
            XCTAssertTrue(connection.waitForPeerClose())
            closed.fulfill()
        }
        defer { server.stop() }
        await assertError(.responseTooLarge, request: try request(server.url(), cap: 64))
        await fulfillment(of: [closed], timeout: 4)
    }

    func testCompressedBodyUsesReceivedByteCapRatherThanContentLength() async throws {
        // gzip of 1,024 'a' bytes: the 29-byte wire length fits the cap, while
        // the decoded data delivered by Foundation exceeds it.
        let compressed = Data(base64Encoded: "H4sIAAAAAAACA0tMHAWjYBSMVAAAuZdVfAAEAAA=")!
        let server = try LoopbackHTTPServer { connection, _, _ in
            connection.respond(headers: "Content-Encoding: gzip\r\n", body: compressed)
        }
        defer { server.stop() }
        await assertError(.responseTooLarge, request: try request(server.url(), cap: 64))
    }

    func testUnknownLengthErrorBodyIsCappedDuringReceipt() async throws {
        let closed = expectation(description: "Unknown length overflow closed the peer")
        let server = try LoopbackHTTPServer { connection, _, _ in
            connection.write("HTTP/1.1 500 Test\r\nConnection: close\r\n\r\n" + String(repeating: "a", count: 65))
            XCTAssertTrue(connection.waitForPeerClose())
            closed.fulfill()
        }
        defer { server.stop() }
        await assertError(.responseTooLarge, request: try request(server.url(), cap: 64))
        await fulfillment(of: [closed], timeout: 4)
    }

    func testDeadlineCancelsWhileWaitingForResponseHeaders() async throws {
        let closed = expectation(description: "Slow response closed the peer")
        let server = try LoopbackHTTPServer { connection, _, _ in
            XCTAssertTrue(connection.waitForPeerClose())
            closed.fulfill()
        }
        defer { server.stop() }
        let started = ContinuousClock.now
        await assertError(.deadlineExceeded, request: try request(server.url(), budget: .milliseconds(250)))
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        await fulfillment(of: [closed], timeout: 4)
    }

    func testDripResponseCannotExtendMonotonicDeadline() async throws {
        let closed = expectation(description: "Drip response closed the peer")
        let server = try LoopbackHTTPServer { connection, _, _ in
            connection.write("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n")
            for _ in 0..<100 {
                if !connection.write("a") { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTAssertTrue(connection.waitForPeerClose())
            closed.fulfill()
        }
        defer { server.stop() }
        let started = ContinuousClock.now
        await assertError(.deadlineExceeded, request: try request(server.url(), budget: .milliseconds(250)))
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        await fulfillment(of: [closed], timeout: 4)
    }

    func testCancellationClosesTheInFlightTask() async throws {
        let receiving = expectation(description: "Response began")
        let closed = expectation(description: "Cancellation closed the peer")
        let server = try LoopbackHTTPServer { connection, _, _ in
            connection.write("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nConnection: close\r\n\r\na")
            receiving.fulfill()
            XCTAssertTrue(connection.waitForPeerClose())
            closed.fulfill()
        }
        defer { server.stop() }
        let request = try request(server.url())
        let task = Task { try await transport.send(request) }
        await fulfillment(of: [receiving], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? HTTPTransportError, .cancelled) }
        await fulfillment(of: [closed], timeout: 4)
    }

    func testPreCancelledTaskAndExpiredDeadlineNeverConnect() async throws {
        let server = try LoopbackHTTPServer { connection, _, _ in connection.respond() }
        defer { server.stop() }
        let live = try request(server.url())
        let task = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch {}
            return try await transport.send(live)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected pre-cancellation") }
        catch { XCTAssertEqual(error as? HTTPTransportError, .cancelled) }
        await assertError(.deadlineExceeded, request: try request(server.url(), budget: .seconds(-1)))
        XCTAssertEqual(server.connectionCount, 0)
    }

    func testConcurrentOperationsHaveIndependentCancellationAndBodies() async throws {
        let receiving = expectation(description: "Slow operation began")
        let closed = expectation(description: "Slow operation closed")
        let slow = try LoopbackHTTPServer { connection, _, _ in
            connection.write("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\na")
            receiving.fulfill()
            XCTAssertTrue(connection.waitForPeerClose())
            closed.fulfill()
        }
        defer { slow.stop() }
        let fast = try LoopbackHTTPServer { connection, _, _ in connection.respond(body: Data([2, 3])) }
        defer { fast.stop() }
        let slowRequest = try request(slow.url())
        let pending = Task { try await transport.send(slowRequest) }
        await fulfillment(of: [receiving], timeout: 2)
        let response = try await transport.send(request(fast.url()))
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? HTTPTransportError, .cancelled) }
        XCTAssertEqual(response.body, Data([2, 3]))
        await fulfillment(of: [closed], timeout: 4)
    }

    func testInsecureAndAmbiguousLoopbackURLsAreRejectedBeforeConnection() async throws {
        let server = try LoopbackHTTPServer { connection, _, _ in connection.respond() }
        defer { server.stop() }
        for host in ["example.com", "192.168.1.2", "localhost.evil.test", "127.1", "2130706433",
                     "0x7f000001", "127.0.0.01", "127.00.0.1", "127.0.0.08", "[::2]"] {
            await assertError(.insecureURL, request: try request(server.url(host: host)))
        }
        XCTAssertEqual(server.connectionCount, 0)
    }

    func testUserinfoAndInvalidSchemesAreRejectedBeforeConnection() async throws {
        let server = try LoopbackHTTPServer { connection, _, _ in connection.respond() }
        defer { server.stop() }
        for userinfo in ["user:secret", "user", ""] {
            let url = URL(string: "http://\(userinfo)@127.0.0.1:\(server.port)/")!
            await assertError(.credentialsInURL, request: try request(url))
        }
        for url in [URL(string: "file:///tmp/local")!, URL(string: "ftp://127.0.0.1:\(server.port)/")!] {
            await assertError(.invalidURL, request: try request(url))
        }
        XCTAssertEqual(server.connectionCount, 0)
    }

    func testInvalidHeadersAndGETBodiesAreRejectedBeforeConnection() async throws {
        let server = try LoopbackHTTPServer { connection, _, _ in connection.respond() }
        defer { server.stop() }
        for headers in [["Authorization": "key\r\nInjected: value"], ["Bad Name": "value"],
                        ["Authorization": "one", "authorization": "two"]] {
            XCTAssertThrowsError(try HTTPRequest(url: server.url(), method: .get,
                headers: headers, deadline: .now.advanced(by: .seconds(3)))) {
                XCTAssertEqual($0 as? HTTPTransportError, .invalidRequest)
            }
        }

        await assertError(.invalidRequest, request: try HTTPRequest(url: server.url(), method: .get,
            body: Data([1]), deadline: .now.advanced(by: .seconds(3))))
        XCTAssertEqual(server.connectionCount, 0)
    }

    func testRefusesEveryRedirectWithoutConnectingToTarget() async throws {
        let target = try LoopbackHTTPServer { connection, _, _ in connection.respond() }
        defer { target.stop() }
        for status in [301, 302, 303, 307, 308] {
            let server = try LoopbackHTTPServer { connection, _, _ in
                connection.respond(status: status, headers: "Location: \(target.url("/target"))\r\n",
                    body: Data("redirect body".utf8))
            }
            defer { server.stop() }
            await assertError(.redirectRefused, request: try HTTPRequest(url: server.url(), method: .post,
                headers: ["Authorization": "Bearer private-header"], body: Data("private-body".utf8),
                deadline: .now.advanced(by: .seconds(3))))
        }
        XCTAssertEqual(target.connectionCount, 0)
    }

    func testRedirectsWithoutLocationStillProduceTypedRefusal() async throws {
        for status in [300, 301, 302, 304, 307, 308] {
            let server = try LoopbackHTTPServer { connection, _, _ in connection.respond(status: status) }
            defer { server.stop() }
            await assertError(.redirectRefused, request: try request(server.url()))
        }
    }

    func testCookiesAndCacheDoNotPersistBetweenRequests() async throws {
        let server = try LoopbackHTTPServer { connection, _, index in
            connection.respond(headers: "Set-Cookie: test=private; Path=/\r\nCache-Control: max-age=3600\r\n",
                body: Data("reply-\(index)".utf8))
        }
        defer { server.stop() }
        for index in 0..<2 {
            let response = try await transport.send(request(server.url()))
            XCTAssertEqual(response.body, Data("reply-\(index)".utf8))
        }
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertTrue(server.requests.allSatisfy { $0.headers["cookie"] == nil })
    }

    func testSharedCredentialStorageIsNotUsed() async throws {
        let server = try LoopbackHTTPServer { connection, _, _ in
            connection.respond(status: 401, headers: "WWW-Authenticate: Basic realm=\"test\"\r\n",
                body: Data("auth error".utf8))
        }
        defer { server.stop() }
        let space = URLProtectionSpace(host: "127.0.0.1", port: Int(server.port), protocol: "http", realm: "test",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let credential = URLCredential(user: "private-user", password: "private-password", persistence: .forSession)
        URLCredentialStorage.shared.setDefaultCredential(credential, for: space)
        defer { URLCredentialStorage.shared.remove(credential, for: space) }
        let response = try await transport.send(request(server.url()))
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(response.body, Data("auth error".utf8))
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertNil(server.requests.first?.headers["authorization"])
    }

    func testErrorsAndActualStderrNeverContainSecretHeadersBodiesOrURLs() async throws {
        let secret = UUID().uuidString
        let captured = try HTTPTransportStderrCapture()
        let server = try LoopbackHTTPServer { connection, _, _ in
            connection.respond(status: 302, headers: "Location: http://localhost/?token=\(secret)\r\nX-Secret: \(secret)\r\n",
                body: Data(secret.utf8))
        }
        defer { server.stop() }
        let broken = try LoopbackHTTPServer { connection, _, _ in
            connection.write("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\nX-Secret: \(secret)\r\n\r\n" + secret)
        }
        defer { broken.stop() }
        var errors = [Error]()
        let requests = [
            try HTTPRequest(url: server.url("/?token=" + secret), method: .post,
                headers: ["Authorization": "Bearer " + secret, "x-api-key": secret], body: Data(secret.utf8),
                deadline: .now.advanced(by: .seconds(3))),
            try request(URL(string: "http://\(secret)@127.0.0.1:\(server.port)/")!),
            try request(server.url("/?token=" + secret), budget: .seconds(-1)),
            try HTTPRequest(url: broken.url("/?token=" + secret), method: .post,
                headers: ["x-api-key": secret], body: Data(secret.utf8), deadline: .now.advanced(by: .seconds(3)))
        ]
        for request in requests {
            do { _ = try await transport.send(request); XCTFail("Expected typed error") }
            catch {
                errors.append(error)
                StandardErrorLog().write(.warning, String(describing: error))
            }
        }
        let output = try captured.finish()
        XCTAssertEqual(errors.compactMap { $0 as? HTTPTransportError },
                       [.redirectRefused, .credentialsInURL, .deadlineExceeded, .networkFailure])
        XCTAssertFalse(output.contains(secret))
        for error in errors {
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(String(reflecting: error).contains(secret))
            XCTAssertFalse((error as NSError).description.contains(secret))
        }
    }

    private func request(_ url: URL, cap: Int = Limits.responseCap, budget: Duration = .seconds(3)) throws -> HTTPRequest {
        try HTTPRequest(url: url, method: .get, responseByteCap: cap, deadline: .now.advanced(by: budget))
    }

    private func assertError(_ expected: HTTPTransportError, request: HTTPRequest,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await transport.send(request); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? HTTPTransportError, expected, file: file, line: line) }
    }
}
