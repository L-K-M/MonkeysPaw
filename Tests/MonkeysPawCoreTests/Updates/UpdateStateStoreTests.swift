import Foundation
import XCTest
@testable import MonkeysPawCore

final class UpdateStateStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testMissingStateIsQuietAndClaimIsPrivateAtomicAndDurable() throws {
        let files = MemoryFileStore()
        let store = UpdateStateStore(files: files)
        XCTAssertEqual(try store.read(at: now), UpdateStateRecord())
        XCTAssertThrowsError(try files.read(at: "update-state.json"))
        let first = try XCTUnwrap(store.claimAutomaticAttempt(at: now))
        XCTAssertEqual(first.lastAutomaticAttempt, now)
        XCTAssertNil(first.lastSuccessfulCheck)
        XCTAssertTrue(files.isPrivate(at: "update-state.json"))
        let reopened = UpdateStateStore(files: files)
        XCTAssertNil(try reopened.claimAutomaticAttempt(at: now.addingTimeInterval(86_399)))
        XCTAssertEqual(try reopened.claimAutomaticAttempt(at: now.addingTimeInterval(86_400))?.lastAutomaticAttempt,
                       now.addingTimeInterval(86_400))
    }

    func testSuccessfulTimeDoesNotReplaceAutomaticAttemptAndDefersRedundantChecks() throws {
        let files = MemoryFileStore()
        let store = UpdateStateStore(files: files)
        _ = try store.claimAutomaticAttempt(at: now)
        let completed = try store.recordSuccess(at: now.addingTimeInterval(10))
        XCTAssertEqual(completed.lastAutomaticAttempt, now)
        XCTAssertEqual(completed.lastSuccessfulCheck, now.addingTimeInterval(10))
        XCTAssertNil(try store.claimAutomaticAttempt(at: now.addingTimeInterval(86_400)))
        XCTAssertNotNil(try store.claimAutomaticAttempt(at: now.addingTimeInterval(86_410)))
    }

    func testCorruptFutureOversizedAndFutureTimestampsFailClosedWithoutRewrite() throws {
        let sources = ["corrupt", #"{"version":2}"#, #"{"version":0}"#, #"{"version":true}"#,
            #"{"version":1,"lastAutomaticAttempt":1700000001}"#,
            #"{"version":1,"lastSuccessfulCheck":1700000001}"#,
            #"{"version":1,"lastAutomaticAttempt":-1}"#,
            #"{"version":1,"lastAutomaticAttempt":"bad"}"#,
            #"{"version":1,"lastAutomaticAttempt":null}"#,
            #"{"version":1,"lastSuccessfulCheck":null}"#,
            #"{"version":1,"rateLimitUntil":1700000100}"#,
            #"{"version":1,"rateLimitUntil":1700000100,"rateLimitStatus":500}"#,
            String(repeating: " ", count: Limits.updateStateFileCap + 1)]
        for source in sources {
            let files = MemoryFileStore()
            try files.put(source, at: "update-state.json")
            let store = UpdateStateStore(files: files)
            XCTAssertThrowsError(try store.read(at: now), source)
            XCTAssertThrowsError(try store.claimAutomaticAttempt(at: now), source)
            XCTAssertThrowsError(try store.recordSuccess(at: now), source)
            XCTAssertEqual(try files.text(at: "update-state.json"), source)
            try files.delete(at: "update-state.json")
            XCTAssertThrowsError(try store.read(at: now), "Read-only is one-way for this store")
        }
    }

    func testClockRollbackBlocksAutomaticRequests() throws {
        let store = UpdateStateStore(files: MemoryFileStore())
        _ = try store.claimAutomaticAttempt(at: now)
        XCTAssertThrowsError(try store.claimAutomaticAttempt(at: now.addingTimeInterval(-1))) {
            XCTAssertEqual($0 as? UpdateStateError, .corruptFile)
        }
    }

    func testClaimWriteFailureDoesNotBecomeAPersistedAttempt() throws {
        let files = MemoryFileStore()
        let store = UpdateStateStore(files: files)
        files.failNextWrite = true
        XCTAssertThrowsError(try store.claimAutomaticAttempt(at: now)) {
            XCTAssertEqual($0 as? UpdateStateError, .writeFailed(.ioFailure))
        }
        XCTAssertEqual(try store.read(at: now), UpdateStateRecord())
        XCTAssertNotNil(try store.claimAutomaticAttempt(at: now))
    }

    func testPersistedRateLimitSurvivesRestartAndBlocksTheAutomaticClaim() throws {
        let files = MemoryFileStore()
        let store = UpdateStateStore(files: files)
        let limit = UpdateRateLimit(statusCode: 429, until: now.addingTimeInterval(120))
        _ = try store.recordRateLimit(limit, at: now)
        let reopened = UpdateStateStore(files: files)
        XCTAssertEqual(try reopened.read(at: now).rateLimit, limit)
        XCTAssertNil(try reopened.claimAutomaticAttempt(at: now.addingTimeInterval(119)))
        XCTAssertNotNil(try reopened.claimAutomaticAttempt(at: now.addingTimeInterval(120)))
    }

    func testReadFailureIsTypedAndDoesNotCreateState() throws {
        let files = MemoryFileStore()
        files.onRead = { _ in throw FileStoreError.ioFailure }
        let store = UpdateStateStore(files: files)
        XCTAssertThrowsError(try store.read(at: now)) {
            XCTAssertEqual($0 as? UpdateStateError, .readFailed(.ioFailure))
        }
        files.onRead = nil
        XCTAssertThrowsError(try files.read(at: "update-state.json"))
    }
}
