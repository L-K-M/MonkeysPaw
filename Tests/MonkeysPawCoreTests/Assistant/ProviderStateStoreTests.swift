import Foundation
import XCTest
@testable import MonkeysPawCore

final class ProviderStateStoreTests: XCTestCase {
    func testAbsentStateStartsAtSchemaWithoutWritingOrTouchingProviderSettings() throws {
        let files = ProviderRecordingFiles()
        let settings = #"{"version":1,"profiles":[],"future":"keep"}"#
        try files.memory.put(settings, at: "provider-settings.json")
        let store = ProviderStateStore(files: files)
        XCTAssertEqual(try store.format(for: connection()), .jsonSchema)
        XCTAssertNil(try files.stamp(at: "provider-state.json"))
        XCTAssertEqual(try files.memory.text(at: "provider-settings.json"), settings)
        XCTAssertTrue(files.attemptedWrites.isEmpty)
    }

    func testSuccessfulLowerFormatsRoundTripWithProfileIsolationAndNoSecrets() throws {
        let files = ProviderRecordingFiles()
        let store = ProviderStateStore(files: files)
        let sentinel = UUID().uuidString
        let first = try connection(key: sentinel)
        let second = try connection(key: sentinel)
        XCTAssertEqual(try store.format(for: first), .jsonSchema)
        try store.recordSuccess(.jsonObject, for: first)
        XCTAssertEqual(try store.format(for: second), .jsonSchema)
        try store.recordSuccess(.none, for: second)
        let reopened = ProviderStateStore(files: files)
        XCTAssertEqual(try reopened.format(for: first), .jsonObject)
        XCTAssertEqual(try reopened.format(for: second), .none)
        let object = try json(files)
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(Set(object.keys), ["version", "profiles"])
        let entries = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        for entry in entries { XCTAssertEqual(Set(entry.keys), ["id", "kind", "baseURL", "modelID", "format"]) }
        for bytes in files.attemptedWrites { XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(sentinel)) }
        assertRedacted(store, sentinel: sentinel)
    }

    func testUnknownRootAndProfileKeysSurviveNormalizedIDRewritesAndInvalidation() throws {
        let files = ProviderRecordingFiles()
        let connection = try connection()
        let future: [String: Any] = ["items": [1, NSNull(), "kept"]]
        var entry = entry(for: connection, format: .jsonObject)
        entry["id"] = connection.profileID.rawValue.uppercased()
        entry["baseURL"] = "HTTPS://API.OPENAI.COM.:443/v1/chat/completions/"
        entry["futureProfile"] = future
        let original: [String: Any] = ["version": 1, "profiles": [entry], "futureRoot": future]
        try files.memory.write(JSONSerialization.data(withJSONObject: original), at: "provider-state.json")
        let store = ProviderStateStore(files: files)
        XCTAssertEqual(try store.format(for: connection), .jsonObject)
        XCTAssertTrue(files.attemptedWrites.isEmpty)
        try store.recordSuccess(.none, for: connection)
        let changed = try self.connection(id: connection.profileID, model: "other-model")
        XCTAssertEqual(try store.format(for: changed), .jsonSchema)
        let rewritten = try json(files)
        XCTAssertEqual(rewritten["futureRoot"] as? NSDictionary, future as NSDictionary)
        let retained = try XCTUnwrap((rewritten["profiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(retained["futureProfile"] as? NSDictionary, future as NSDictionary)
        XCTAssertEqual(retained["id"] as? String, connection.profileID.rawValue)
        XCTAssertEqual(retained["baseURL"] as? String, connection.baseURL.absoluteString)
        XCTAssertEqual(retained["modelID"] as? String, "other-model")
        XCTAssertEqual(retained["format"] as? String, "json_schema")
        XCTAssertEqual(try store.format(for: connection), .jsonSchema)
    }

    func testKindOriginPathAndModelChangesInvalidateEvenAfterReturningToOldIdentity() throws {
        let id = ProviderProfileID()
        let original = try connection(id: id)
        let changes = try [connection(id: id, model: "different-model"),
            connection(id: id, base: "https://other.example/v1"),
            connection(id: id, base: "https://api.openai.com:444/v1"),
            connection(id: id, base: "https://api.openai.com/custom/v1"),
            connection(id: id, base: "https://localhost/v1"),
            connection(id: id, base: "http://localhost/v1"),
            connection(id: id, base: "https://api.openai.com/v1", kind: .anthropic)]
        for changed in changes {
            let files = ProviderRecordingFiles()
            let store = ProviderStateStore(files: files)
            _ = try store.format(for: original)
            try store.recordSuccess(.none, for: original)
            XCTAssertEqual(try store.format(for: changed), .jsonSchema)
            XCTAssertEqual(try ProviderStateStore(files: files).format(for: changed), .jsonSchema)
            XCTAssertEqual(try store.format(for: original), .jsonSchema)
        }
    }

    func testEquivalentNormalizedBaseAndNewKeyRetainCapability() throws {
        let files = ProviderRecordingFiles()
        let store = ProviderStateStore(files: files)
        let first = try connection()
        _ = try store.format(for: first)
        try store.recordSuccess(.jsonObject, for: first)
        let equivalent = try connection(id: first.profileID, base: "HTTPS://API.OPENAI.COM.:443/v1/models/", key: "new-key")
        XCTAssertEqual(try store.format(for: equivalent), .jsonObject)
        XCTAssertEqual(files.attemptedWrites.count, 1)
    }

    func testOlderInFlightSuccessCannotOverwriteNewlyObservedModel() throws {
        let files = ProviderRecordingFiles()
        let store = ProviderStateStore(files: files)
        let old = try connection()
        let new = try connection(id: old.profileID, model: "new-model")
        _ = try store.format(for: old)
        _ = try store.format(for: new)
        try store.recordSuccess(.none, for: old)
        XCTAssertTrue(files.attemptedWrites.isEmpty)
        try store.recordSuccess(.jsonObject, for: new)
        XCTAssertEqual(try store.format(for: new), .jsonObject)
    }

    func testOlderInFlightSuccessCannotOverwriteExternallyChangedIdentity() throws {
        let files = ProviderRecordingFiles()
        let store = ProviderStateStore(files: files)
        let old = try connection()
        _ = try store.format(for: old)
        try store.recordSuccess(.jsonObject, for: old)
        let new = try connection(id: old.profileID, model: "externally-changed-model")
        let replacement = try JSONSerialization.data(withJSONObject: ["version": 1, "profiles": [entry(for: new, format: .none)]])
        try files.memory.write(replacement, at: "provider-state.json")
        let writes = files.attemptedWrites.count
        try store.recordSuccess(.none, for: old)
        XCTAssertTrue(try files.read(at: "provider-state.json") == replacement)
        XCTAssertEqual(files.attemptedWrites.count, writes)
    }

    func testConcurrentSuccessCannotForgetARejectedLowerFormat() throws {
        let files = ProviderRecordingFiles()
        let store = ProviderStateStore(files: files)
        let connection = try connection()
        _ = try store.format(for: connection)
        try store.recordSuccess(.none, for: connection)
        // Another action started at schema mode and completed out of order.
        try store.recordSuccess(.jsonObject, for: connection)
        XCTAssertEqual(try store.format(for: connection), .none)
        XCTAssertEqual(files.attemptedWrites.count, 1)
    }

    func testMalformedFutureUnsupportedAndInvalidEntriesFailClosedWithoutRewriting() throws {
        let connection = try connection()
        let valid = entry(for: connection, format: .jsonObject)
        let invalidEntries: [[String: Any]] = [["id": "invalid"], ["kind": "unknown"], ["baseURL": "http://remote.example"],
            ["baseURL": "https://remote.example?key=value"], ["modelID": ""], ["modelID": "model\n"],
            ["format": "future-format"], ["format": true]]
        var cases: [(String, SettingsError)] = [
            (#"{"version":2,"profiles":"new shape"}"#, .futureVersion(2)),
            (#"{"version":0}"#, .unsupportedVersion(0)), (#"{"version":-1}"#, .unsupportedVersion(-1)),
            (#"{"version":true,"profiles":[]}"#, .corruptFile), (#"{"version":1}"#, .corruptFile),
            (#"{"version":1,"profiles":null}"#, .corruptFile), ("{", .corruptFile)]
        for changes in invalidEntries {
            let bad = valid.merging(changes, uniquingKeysWith: { _, new in new })
            cases.append((try AssistantOutputFixtures.json(["version": 1, "profiles": [bad]]), .corruptFile))
        }
        cases.append((try AssistantOutputFixtures.json(["version": 1, "profiles": [valid, valid]]), .corruptFile))
        for (original, expected) in cases {
            let files = ProviderRecordingFiles()
            try files.memory.put(original, at: "provider-state.json")
            let store = ProviderStateStore(files: files)
            XCTAssertThrowsError(try store.format(for: connection)) { XCTAssertEqual($0 as? SettingsError, expected) }
            XCTAssertThrowsError(try store.recordSuccess(.none, for: connection)) { XCTAssertEqual($0 as? SettingsError, expected) }
            XCTAssertEqual(try files.memory.text(at: "provider-state.json"), original)
            XCTAssertTrue(files.attemptedWrites.isEmpty)
            try files.memory.delete(at: "provider-state.json")
            XCTAssertThrowsError(try store.format(for: connection)) { XCTAssertEqual($0 as? SettingsError, expected) }
            XCTAssertEqual(try ProviderStateStore(files: files).format(for: connection), .jsonSchema)
        }
    }

    func testReadErrorsAreSanitizedAndExternalReplacementBlocksPublication() throws {
        let files = ProviderRecordingFiles()
        let sentinel = UUID().uuidString
        files.memory.onRead = { _ in throw NSError(domain: sentinel, code: 1) }
        let store = ProviderStateStore(files: files)
        let connection = try connection()
        XCTAssertThrowsError(try store.format(for: connection)) {
            XCTAssertEqual($0 as? SettingsError, .readFailed(.ioFailure))
            self.assertRedacted($0, sentinel: sentinel)
        }
        files.memory.onRead = nil
        XCTAssertThrowsError(try store.format(for: connection))
        let reopened = ProviderStateStore(files: files)
        _ = try reopened.format(for: connection)
        try files.memory.put(#"{"version":9}"#, at: "provider-state.json")
        XCTAssertThrowsError(try reopened.recordSuccess(.none, for: connection)) {
            XCTAssertEqual($0 as? SettingsError, .futureVersion(9))
        }
        XCTAssertEqual(try files.memory.text(at: "provider-state.json"), #"{"version":9}"#)
        XCTAssertTrue(files.attemptedWrites.isEmpty)
    }

    func testFailedAtomicWritePreservesCapabilityAndCanBeRetried() throws {
        let files = ProviderRecordingFiles()
        let store = ProviderStateStore(files: files)
        let connection = try connection()
        _ = try store.format(for: connection)
        files.memory.failNextWrite = true
        XCTAssertThrowsError(try store.recordSuccess(.jsonObject, for: connection)) {
            XCTAssertEqual($0 as? SettingsError, .writeFailed(.ioFailure))
        }
        XCTAssertNil(try files.stamp(at: "provider-state.json"))
        XCTAssertEqual(try store.format(for: connection), .jsonSchema)
        try store.recordSuccess(.jsonObject, for: connection)
        let original = try files.read(at: "provider-state.json")
        files.memory.failNextWrite = true
        XCTAssertThrowsError(try store.recordSuccess(.none, for: connection))
        XCTAssertEqual(try files.read(at: "provider-state.json"), original)
        XCTAssertEqual(try store.format(for: connection), .jsonObject)
        try store.recordSuccess(.none, for: connection)
        XCTAssertEqual(try ProviderStateStore(files: files).format(for: connection), .none)
    }

    private func connection(id: ProviderProfileID = ProviderProfileID(), base: String = "https://api.openai.com/v1",
                            kind: ProviderKind = .openaiCompatible, model: String = "chosen-model",
                            key: String? = nil) throws -> ProviderConnection {
        ProviderConnection(profileID: id, kind: kind, baseURL: try ProviderSettings.normalizeBaseURL(base, kind: kind),
            modelID: model, key: key.map(SecretValue.init))
    }

    private func entry(for connection: ProviderConnection, format: OpenAIResponseFormat) -> [String: Any] {
        ["id": connection.profileID.rawValue, "kind": connection.kind.rawValue,
         "baseURL": connection.baseURL.absoluteString, "modelID": connection.modelID, "format": format.rawValue]
    }

    private func json(_ files: ProviderRecordingFiles) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: files.read(at: "provider-state.json")) as? [String: Any])
    }

    private func assertRedacted(_ value: Any, sentinel: String) {
        XCTAssertFalse(String(describing: value).contains(sentinel))
        XCTAssertFalse(String(reflecting: value).contains(sentinel))
        var diagnostic = ""
        dump(value, to: &diagnostic)
        XCTAssertFalse(diagnostic.contains(sentinel))
    }
}
