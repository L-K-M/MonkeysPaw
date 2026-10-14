import Foundation
import XCTest
@testable import MonkeysPawCore

final class LastDeliveryStoreTests: XCTestCase {
    func testPrivateProjectionContainsOnlyPermittedFieldsAndNoContent() throws {
        let h = try RepeatHarness()
        let entry = try h.put("""
        ---
        fields:
          kept: {optional: true, default: default}
          secret: {remember: false}
        ---
        Private template {{kept}} {{secret}} {{clipboard}}
        """)
        let record = try LastDeliveryRecord(binding: h.binding, entry: entry,
            values: ["kept": "", "secret": "session-secret", "clipboard": "builtin-secret", "unused": "extra-secret"],
            mode: .copyOnly)
        try h.store.save(record)
        let text = try h.flow.data.text(at: "last-delivery.json")
        XCTAssertTrue(h.flow.data.isPrivate(at: "last-delivery.json"), "Private writes require 0600 before publishing.")
        XCTAssertFalse(text.contains("Private template"))
        for excluded in ["session-secret", "builtin-secret", "extra-secret"] { XCTAssertFalse(text.contains(excluded)) }
        let reopened = try XCTUnwrap(LastDeliveryStore(files: h.flow.data).load())
        XCTAssertEqual(reopened.rememberedValues, ["kept": ""])
        XCTAssertTrue(reopened.requiresSessionValues)
        XCTAssertTrue(reopened.copyOnly)
        XCTAssertEqual(try reopened.identity, entry.identity)
        XCTAssertEqual(try h.flow.data.listFiles().map(\.relativePath), ["last-delivery.json"])
    }

    func testMissingAndTombstoneRoundtrip() throws {
        let h = try RepeatHarness()
        XCTAssertNil(try h.store.load())
        try h.store.save(nil)
        XCTAssertEqual(try h.flow.data.text(at: "last-delivery.json"), "{\"record\":null,\"version\":1}")
        XCTAssertNil(try h.store.load())
        XCTAssertTrue(h.flow.data.isPrivate(at: "last-delivery.json"))
    }

    func testClearBypassesUnreadableCorruptFutureAndOversizedState() throws {
        let h = try RepeatHarness()
        for bytes in [Data("secret corrupt record".utf8), Data("{\"version\":2,\"record\":null}".utf8),
                      Data(repeating: 32, count: Limits.lastDeliveryFileCapBytes + 1)] {
            try h.flow.data.write(bytes, at: "last-delivery.json")
            h.flow.data.onRead = { _ in XCTFail("Clear must not read old state."); throw FileStoreError.ioFailure }
            try h.store.save(nil)
            h.flow.data.onRead = nil
            XCTAssertNil(try h.store.load())
        }
    }

    func testCorruptFutureCapAndWrongTypesFailClosedWithoutChangingBytes() throws {
        let h = try RepeatHarness()
        let examples: [(Data, RepeatFailure)] = [
            (Data("private invalid json".utf8), .corruptRecord),
            (Data("{\"version\":2,\"record\":null}".utf8), .futureRecord),
            (Data("{\"version\":0,\"record\":null}".utf8), .corruptRecord),
            (Data("{\"version\":true,\"record\":null}".utf8), .corruptRecord),
            (Data("{\"version\":1}".utf8), .corruptRecord),
            (Data("{\"version\":1,\"record\":[]}".utf8), .corruptRecord),
            (Data(repeating: 32, count: Limits.lastDeliveryFileCapBytes + 1), .recordTooLarge)
        ]
        for (bytes, error) in examples {
            try h.flow.data.write(bytes, at: "last-delivery.json")
            XCTAssertThrowsError(try h.store.load()) { XCTAssertEqual($0 as? RepeatFailure, error) }
            XCTAssertEqual(try h.flow.data.read(at: "last-delivery.json"), bytes)
        }
    }

    func testRejectsInvalidIdentityFingerprintBindingAndReservedFieldKeys() throws {
        let h = try RepeatHarness()
        let entry = try h.put("{{field}}")
        try h.store.save(LastDeliveryRecord(binding: h.binding, entry: entry, values: ["field": "value"], mode: .copyOnly))
        let bytes = try h.flow.data.read(at: "last-delivery.json")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let record = try XCTUnwrap(payload["record"] as? [String: Any])
        for (key, value) in [("identityKey", "bad" as Any), ("relativePath", "../private.md"),
                             ("sourceFingerprint", "bad"), ("rememberedValues", ["clipboard": "secret"]),
                             ("binding", ["root": "relative"]) ] {
            var changed = record
            changed[key] = value
            try h.flow.data.write(JSONSerialization.data(withJSONObject: ["version": 1, "record": changed]), at: "last-delivery.json")
            XCTAssertThrowsError(try h.store.load()) { XCTAssertEqual($0 as? RepeatFailure, .corruptRecord) }
        }
    }

    func testOversizedWriteIsRejectedAndPreservesPriorRecord() throws {
        let h = try RepeatHarness()
        let entry = try h.put("{{field}}")
        try h.store.save(nil)
        let previous = try h.flow.data.read(at: "last-delivery.json")
        let record = try LastDeliveryRecord(binding: h.binding, entry: entry,
            values: ["field": String(repeating: "x", count: Limits.lastDeliveryFileCapBytes)], mode: .copyOnly)
        XCTAssertThrowsError(try h.store.save(record)) { XCTAssertEqual($0 as? RepeatFailure, .recordTooLarge) }
        XCTAssertEqual(try h.flow.data.read(at: "last-delivery.json"), previous)
    }

    func testSanitizedFailuresAndRedactedRecordReflection() throws {
        let h = try RepeatHarness()
        let entry = try h.put("private body {{field}}", at: "private-name.md")
        let record = try LastDeliveryRecord(binding: h.binding, entry: entry, values: ["field": "private-value"], mode: .copyOnly)
        for object: Any in [record, h.binding, try record.reference] {
            var output = ""
            dump(object, to: &output)
            for secret in ["private body", "private-name", "private-value", "/library"] { XCTAssertFalse(output.contains(secret)) }
        }
        h.flow.data.onRead = { _ in throw NSError(domain: "private-value/private-name", code: 1) }
        XCTAssertThrowsError(try h.store.load()) { XCTAssertEqual($0 as? RepeatFailure, .readFailed) }
        h.flow.data.onRead = nil
        h.flow.data.failNextWrite = true
        XCTAssertThrowsError(try h.store.save(record)) { XCTAssertEqual($0 as? RepeatFailure, .writeFailed) }
        XCTAssertNil(try h.store.load())
    }

    func testBindingUsesExactRootAndCanonicalAccountIdentity() throws {
        let user = try XCTUnwrap(ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV"))
        let signedIn = try RepeatBinding(root: "/library", serverURL: "https://sync.example", userID: user)
        XCTAssertNotEqual(signedIn, try RepeatBinding(root: "/library"))
        XCTAssertNotEqual(signedIn, try RepeatBinding(root: "/other", serverURL: "https://sync.example", userID: user))
        XCTAssertThrowsError(try RepeatBinding(root: "relative"))
        XCTAssertThrowsError(try RepeatBinding(root: "/library", serverURL: "https://sync.example"))
        XCTAssertThrowsError(try RepeatBinding(root: "/library", serverURL: "https://user:secret@sync.example", userID: user))
        XCTAssertEqual(try JSONDecoder().decode(RepeatBinding.self, from: JSONEncoder().encode(signedIn)), signedIn)
    }
}
