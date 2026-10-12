import Foundation
import XCTest
@testable import MonkeysPawCore

final class ForgetValuesOutcomeTests: XCTestCase {
    func testGlobalForgetReturnsSuccessAndDistinctDeliveryRefusal() throws {
        for source in ["Body", "{{topic}}"] {
            let h = PromptFlowHarness()
            _ = try h.put(source)
            try h.open()
            h.picker.use(mode: .copyOnly)
            h.picker.fillModel?.setValue("delivered", name: "topic")
            h.picker.fillModel?.deliver(mode: .copyOnly)
            XCTAssertEqual(h.picker.state, .delivering)
            let accesses = h.data.accessCount

            XCTAssertEqual(h.picker.forgetAllValues(), .deliveryInFlight)
            XCTAssertEqual(h.data.accessCount, accesses)
            XCTAssertEqual(h.picker.forgetValuesError as? LibraryError, .operationFailed)
            h.settle()
            XCTAssertEqual(h.picker.forgetAllValues(), .forgotten)
            XCTAssertNil(h.picker.forgetValuesError)
        }
    }

    func testGlobalForgetReturnsClassifiedFailuresAndSanitizesUnknownErrors() {
        let files = FailingForgetFileStore()
        let delivery = DeliveryHarness()
        let clock = LibraryClock()
        let values = ValuesStore(files: files)
        let usage = UsageStore(files: files, clock: clock)
        let service = LibraryService(library: MemoryFileStore(), data: files, clock: clock,
                                     entropy: LibraryEntropy(), keyedStores: [usage, values])
        let index = PromptIndex(service: service, usage: usage, clock: clock)
        let fill = FillService(values: values, clipboard: delivery.clipboard, clock: clock,
                               timeZone: { TimeZone(secondsFromGMT: 0)! })
        let picker = PickerModel(index: index, fill: fill, delivery: delivery.service, main: delivery.main)
        let failures: [(Error, RememberedValuesOutcome)] = [
            (FileStoreError.ioFailure, .fileStoreFailure(.ioFailure)),
            (FileStoreError.invalidRoot, .fileStoreFailure(.invalidRoot)),
            (LibraryError.keyedStateConflict, .libraryFailure(.keyedStateConflict)),
            (LibraryError.operationFailed, .libraryFailure(.operationFailed)),
            (NSError(domain: "/private/FIELD_SECRET_VALUE", code: 1,
                     userInfo: [NSLocalizedDescriptionKey: "PRIVATE_ERROR_BODY"]), .libraryFailure(.operationFailed))
        ]
        for (error, expected) in failures {
            files.failure = error
            let outcome = picker.forgetAllValues()
            XCTAssertEqual(outcome, expected)
            switch outcome {
            case .fileStoreFailure(let error): XCTAssertEqual(picker.forgetValuesError as? FileStoreError, error)
            case .libraryFailure(let error): XCTAssertEqual(picker.forgetValuesError as? LibraryError, error)
            case .forgotten, .deliveryInFlight: XCTFail("Expected a typed failure")
            }
            XCTAssertEqual(picker.state, .closed)
            XCTAssertEqual(files.storage.accessCount, 0)
            for sensitive in ["/private/", "FIELD_SECRET_VALUE", "PRIVATE_ERROR_BODY"] {
                XCTAssertFalse(String(describing: outcome).contains(sensitive))
                XCTAssertFalse(RememberedValuesStrings.message(for: outcome).contains(sensitive))
                XCTAssertFalse(String(describing: picker.forgetValuesError).contains(sensitive))
            }
        }
        files.failure = nil
        XCTAssertEqual(picker.forgetAllValues(), .forgotten)
        XCTAssertNil(picker.forgetValuesError)
    }

    func testReturnedFailureDoesNotDependOnMutableErrorAfterInlineCallback() {
        let h = PromptFlowHarness()
        h.data.failNextWrite = true
        var retried = false
        h.picker.onChange = {
            guard !retried else { return }
            retried = true
            XCTAssertEqual(h.picker.forgetAllValues(), .forgotten)
        }

        XCTAssertEqual(h.picker.forgetAllValues(), .fileStoreFailure(.ioFailure))
        XCTAssertTrue(retried)
        XCTAssertNil(h.picker.forgetValuesError, "The inline retry cleared the UI error, not the first call's result")
        h.picker.onChange = nil
    }
}

private final class FailingForgetFileStore: FileStore {
    let storage = MemoryFileStore()
    var failure: Error?

    func listFiles() throws -> [StoredFile] { try storage.listFiles() }
    func stamp(at path: String) throws -> FileStamp? { try storage.stamp(at: path) }
    func read(at path: String) throws -> Data { try storage.read(at: path) }
    func write(_ data: Data, at path: String) throws { try storage.write(data, at: path) }
    func create(_ data: Data, at path: String) throws { try storage.create(data, at: path) }
    func delete(at path: String) throws { try storage.delete(at: path) }
    func move(from source: String, to destination: String) throws { try storage.move(from: source, to: destination) }

    func writePrivate(_ data: Data, at path: String) throws {
        if let failure { throw failure }
        try storage.writePrivate(data, at: path)
    }
}
