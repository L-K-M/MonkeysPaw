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
