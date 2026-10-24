import Foundation
import XCTest
@testable import MonkeysPawCore

final class ProviderSettingsStoreTests: XCTestCase {
    func testAbsentProviderFileUpgradesAnExistingInstallWithoutTouchingGeneralSettings() throws {
        let files = ProviderRecordingFiles()
        let original = #"{"version":1,"libraryFolderPath":"/library","firstRun":{"setupPresented":true,"libraryFolderCompleted":true,"seedsOffered":true},"unknown":{"keep":7}}"#
        try files.memory.put(original, at: "settings.json")
        let general = SettingsService(store: SettingsStore(files: files))
        let harness = ProviderHarness(files: files)
        XCTAssertEqual(harness.service.snapshot.settings, try ProviderSettings())
        XCTAssertFalse(harness.service.snapshot.isReadOnly)
        XCTAssertNil(try files.stamp(at: "provider-settings.json"))
        XCTAssertTrue(files.attemptedWrites.isEmpty)

        let draft = ProviderDraft()
        try harness.service.save(draft)
        let reopened = harness.reopen()
        XCTAssertEqual(reopened.service.snapshot, harness.service.snapshot)
        XCTAssertEqual(try files.memory.text(at: "settings.json"), original)
        XCTAssertEqual(SettingsService(store: SettingsStore(files: files)).snapshot, general.snapshot)
        XCTAssertEqual(try harness.json()["version"] as? Int, 1)
        XCTAssertEqual(reopened.service.snapshot.settings.selectedProfileID, draft.id)
    }

    func testRoundTripNormalizedEndpointsOptionalReferencesAndSelection() throws {
        let harness = ProviderHarness()
        let first = ProviderDraft(baseURL: "https://api.anthropic.com/v1/messages/", key: .typed("first"))
        let second = ProviderDraft(displayName: "Local", kind: .openaiCompatible,
            baseURL: "http://localhost:11434/v1/chat/completions", modelID: "manual-model")
        try harness.service.save(first)
        try harness.service.save(second)
        try harness.service.selectProfile(second.id)
        let before = harness.files.attemptedWrites.count
        let reopened = harness.reopen()
        XCTAssertEqual(reopened.service.snapshot, harness.service.snapshot)
        XCTAssertEqual(harness.files.attemptedWrites.count, before)
        let profiles = reopened.service.snapshot.settings.profiles
        XCTAssertEqual(profiles.map(\.id), [first.id, second.id])
        XCTAssertEqual(profiles[0].baseURL.absoluteString, "https://api.anthropic.com")
        XCTAssertEqual(profiles[0].secretReference, .provider(first.id))
        XCTAssertNil(profiles[1].secretReference)
        XCTAssertEqual(profiles[1].modelID, "manual-model")
        XCTAssertEqual(try reopened.service.secretTier(for: first.id), .secretService)
    }

    func testEscapedSavedProfilesLoadWithoutRewritingAndRemainEditable() throws {
        // Mirrors the reported file's shape without retaining the owner's metadata.
        let original = #"""
        {"profiles":[{"baseURL":"https:\/\/api.example.test\/api\/v1","displayName":"Keyless","id":"01234567-89ab-cdef-0123-456789abcdef","kind":"openaiCompatible","modelID":"manual-one","secretReference":null},{"baseURL":"https:\/\/api.example.test\/api\/v1","displayName":"With key","id":"fedcba98-7654-4321-fedc-ba9876543210","kind":"openaiCompatible","modelID":"manual-two","secretReference":"provider:fedcba98-7654-4321-fedc-ba9876543210"}],"selectedProfileID":"01234567-89ab-cdef-0123-456789abcdef","version":1}
        """#
        let files = ProviderRecordingFiles()
        try files.memory.put(original, at: "provider-settings.json")
        let h = ProviderHarness(files: files)
        XCTAssertNil(h.service.snapshot.readOnlyError)
        let settings = h.service.snapshot.settings
        XCTAssertEqual(settings.profiles.map(\.displayName), ["Keyless", "With key"])
        let first = try XCTUnwrap(settings.profiles.first)
        let second = try XCTUnwrap(settings.profiles.last)
        XCTAssertEqual(settings.selectedProfileID, first.id)
        XCTAssertNil(first.secretReference)
        XCTAssertEqual(second.secretReference, .provider(second.id))
        XCTAssertEqual(second.baseURL.absoluteString, "https://api.example.test/api/v1")
        XCTAssertEqual(try files.memory.text(at: "provider-settings.json"), original)
        XCTAssertTrue(files.attemptedWrites.isEmpty)
        XCTAssertTrue(h.secrets.reads.isEmpty)

        let added = ProviderDraft(displayName: "New profile")
        try h.service.save(added)
        let reopened = h.reopen()
        XCTAssertNil(reopened.service.snapshot.readOnlyError)
        XCTAssertEqual(reopened.service.snapshot.settings.profiles, settings.profiles + [try ProviderProfile(
            id: added.id, displayName: added.displayName, kind: added.kind,
            baseURL: added.baseURL, modelID: added.modelID)])
        XCTAssertEqual(reopened.service.snapshot.settings.selectedProfileID, first.id)
    }

    func testUnknownRootAndNestedProfileKeysFollowIDsThroughEditsAndDeletion() throws {
        let harness = ProviderHarness()
        let first = ProviderDraft(displayName: "One")
        let second = ProviderDraft(displayName: "Two")
        try harness.service.save(first)
        try harness.service.save(second)
        var object = try harness.json()
        object["future"] = ["nested": ["items": [1, NSNull(), "kept"]]]
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]], "provider-settings fixture missing a profiles array")
        profiles[0]["id"] = first.id.rawValue.uppercased()
        profiles[0]["futureProfile"] = ["array": [false, "one"]]
        profiles[1]["futureProfile"] = ["array": [true, "two"]]
        object["profiles"] = profiles.reversed().map { $0 }
        try harness.files.memory.write(JSONSerialization.data(withJSONObject: object), at: "provider-settings.json")

        var edit = second
        edit.displayName = "Two edited"
        try harness.service.save(edit)
        try harness.service.selectProfile(first.id)
        var rewritten = try harness.json()
        XCTAssertEqual(rewritten["future"] as? NSDictionary, object["future"] as? NSDictionary)
        let output = try XCTUnwrap(rewritten["profiles"] as? [[String: Any]], "rewritten settings missing a profiles array")
        for profile in output {
            let profileID = try XCTUnwrap(profile["id"] as? String, "rewritten profile missing its ID")
            let original = try XCTUnwrap(profiles.first { ($0["id"] as? String)?.lowercased() == profileID },
                                         "no source profile matched rewritten ID \(profileID)")
            XCTAssertEqual(profile["futureProfile"] as? NSDictionary, original["futureProfile"] as? NSDictionary)
        }
        try harness.service.deleteProfile(first.id)
        rewritten = try harness.json()
        let retained = try XCTUnwrap(rewritten["profiles"] as? [[String: Any]], "rewritten settings missing a profiles array")
        XCTAssertEqual(retained.count, 1)
        let retainedProfile = try XCTUnwrap(retained.first, "rewritten settings missing the retained profile")
        XCTAssertEqual(retainedProfile["futureProfile"] as? NSDictionary, profiles[1]["futureProfile"] as? NSDictionary)
        XCTAssertEqual(rewritten["future"] as? NSDictionary, object["future"] as? NSDictionary)
    }

    func testCorruptFutureUnsupportedAndCrossProfileFilesFailClosed() throws {
        let id = ProviderProfileID()
        let other = ProviderProfileID()
        let profile = """
        {"id":"\(id.rawValue)","displayName":"Name","kind":"anthropic","baseURL":"https://api.anthropic.com","modelID":"manual","secretReference":"provider:\(other.rawValue)"}
        """
        let cases: [(String, ProviderSettingsError)] = [
            (#"{"version":2,"profiles":"new shape"}"#, .futureVersion(2)),
            (#"{"version":0}"#, .unsupportedVersion(0)),
            (#"{"version":-1}"#, .unsupportedVersion(-1)),
            (#"{"version":true,"profiles":[]}"#, .corruptFile),
            (#"{"version":1}"#, .corruptFile),
            (#"{"version":1,"profiles":null}"#, .corruptFile),
            (#"{"version":1,"profiles":[],"selectedProfileID":"invalid"}"#, .corruptFile),
            ("{", .corruptFile),
            ("{\"version\":1,\"profiles\":[\(profile)]}", .corruptFile)
        ]
        for (original, expected) in cases {
            let files = ProviderRecordingFiles()
            try files.memory.put(original, at: "provider-settings.json")
            let harness = ProviderHarness(files: files)
            XCTAssertEqual(harness.service.snapshot.readOnlyError, expected)
            XCTAssertEqual(harness.service.snapshot.settings, try ProviderSettings())
            XCTAssertThrowsError(try harness.service.save(ProviderDraft()), "\(expected)") {
                XCTAssertEqual($0 as? ProviderSettingsError, expected)
            }
            XCTAssertThrowsError(try harness.service.resolveForTesting(ProviderDraft()), "\(expected)") {
                XCTAssertEqual($0 as? ProviderSettingsError, expected)
            }
            XCTAssertEqual(try files.memory.text(at: "provider-settings.json"), original)
            XCTAssertTrue(files.attemptedWrites.isEmpty)
            XCTAssertTrue(harness.secrets.reads.isEmpty)
        }
    }

    func testReadErrorsAreSanitizedAndReadOnlyStateRequiresRecreation() throws {
        let files = ProviderRecordingFiles()
        let sentinel = UUID().uuidString
        files.memory.onRead = { _ in throw NSError(domain: sentinel, code: 1) }
        let harness = ProviderHarness(files: files)
        XCTAssertEqual(harness.service.snapshot.readOnlyError, .readFailed(.ioFailure))
        files.memory.onRead = nil
        XCTAssertThrowsError(try harness.service.save(ProviderDraft())) {
            XCTAssertEqual($0 as? ProviderSettingsError, .readFailed(.ioFailure))
        }
        XCTAssertThrowsError(try harness.service.resolveForTesting(ProviderDraft())) {
            XCTAssertEqual($0 as? ProviderSettingsError, .readFailed(.ioFailure))
        }
        XCTAssertFalse(harness.log.lines.joined().contains(sentinel))
        XCTAssertTrue(harness.files.attemptedWrites.isEmpty)
        let reopened = harness.reopen()
        XCTAssertFalse(reopened.service.snapshot.isReadOnly)
        try reopened.service.save(ProviderDraft())
    }

    func testInvalidProfileDiagnosticsIdentifyTheStageWithoutMetadata() throws {
        let source = ProviderHarness()
        try source.service.save(ProviderDraft())
        let original = try source.json()
        let profiles = try XCTUnwrap(original["profiles"] as? [[String: Any]])
        let profile = try XCTUnwrap(profiles.first)
        let sentinel = UUID().uuidString
        let cases: [(String, Any, String)] = [
            ("secretReference", "provider:\(sentinel) invalid", "Provider settings contain an invalid secret reference."),
            ("baseURL", "http://\(sentinel).example", "Provider settings fail profile validation."),
            ("modelID", false, "Provider settings do not match the expected JSON structure.")
        ]
        for (field, value, diagnostic) in cases {
            var invalid = profile
            invalid["displayName"] = sentinel
            invalid[field] = value
            var object = original
            object["profiles"] = [invalid]
            let bytes = try JSONSerialization.data(withJSONObject: object)
            let files = ProviderRecordingFiles()
            try files.memory.write(bytes, at: "provider-settings.json")
            let h = ProviderHarness(files: files)

            XCTAssertEqual(h.service.snapshot.readOnlyError, .corruptFile)
            XCTAssertEqual(h.log.lines, ["warning: " + diagnostic,
                "warning: Provider settings read failed; settings are read-only."])
            XCTAssertFalse(h.log.lines.joined().contains(sentinel))
            XCTAssertEqual(try files.read(at: "provider-settings.json"), bytes)
            XCTAssertTrue(files.attemptedWrites.isEmpty)
            XCTAssertTrue(h.secrets.reads.isEmpty)
        }
    }

    func testExternalFutureOrCorruptReplacementBlocksReadsAndSecretEdits() throws {
        let cases: [(String, ProviderSettingsError)] = [(#"{"version":8}"#, .futureVersion(8)), ("invalid", .corruptFile)]
        for (replacement, expected) in cases {
            let harness = ProviderHarness()
            var draft = ProviderDraft(key: .typed("stored"))
            try harness.service.save(draft)
            try harness.files.memory.put(replacement, at: "provider-settings.json")
            let secretReads = harness.secrets.reads.count
            let secretWrites = harness.secrets.writes.count
            draft.key = .typed("replacement")
            XCTAssertThrowsError(try harness.service.connection(for: draft.id), replacement) {
                XCTAssertEqual($0 as? ProviderSettingsError, expected)
            }
            XCTAssertThrowsError(try harness.service.resolveForTesting(draft), replacement) {
                XCTAssertEqual($0 as? ProviderSettingsError, expected)
            }
            XCTAssertThrowsError(try harness.service.save(draft), replacement) {
                XCTAssertEqual($0 as? ProviderSettingsError, expected)
            }
            XCTAssertTrue(harness.service.snapshot.isReadOnly)
            XCTAssertEqual(harness.secrets.reads.count, secretReads)
            XCTAssertEqual(harness.secrets.writes.count, secretWrites)
            XCTAssertEqual(try harness.files.memory.text(at: "provider-settings.json"), replacement)
        }
    }

    func testFailedMetadataWriteLeavesFileAndSnapshotRetryable() throws {
        let harness = ProviderHarness()
        var draft = ProviderDraft()
        harness.files.memory.failNextWrite = true
        XCTAssertThrowsError(try harness.service.save(draft)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .writeFailed(.ioFailure))
        }
        XCTAssertNil(try harness.files.stamp(at: "provider-settings.json"))
        XCTAssertEqual(harness.service.snapshot.settings.profiles, [])
        try harness.service.save(draft)
        let before = harness.service.snapshot
        let bytes = try harness.files.read(at: "provider-settings.json")
        draft.displayName = "Changed"
        harness.files.memory.failNextWrite = true
        XCTAssertThrowsError(try harness.service.save(draft)) {
            XCTAssertEqual($0 as? ProviderSettingsError, .writeFailed(.ioFailure))
        }
        XCTAssertEqual(harness.service.snapshot, before)
        XCTAssertEqual(try harness.files.read(at: "provider-settings.json"), bytes)
        try harness.service.save(draft)
        XCTAssertEqual(harness.service.snapshot.settings.profiles.first?.displayName, "Changed")
        XCTAssertEqual(harness.reopen().service.snapshot, harness.service.snapshot)
    }

    func testDuplicateIDsUnknownKindsAndUnsafeURLsNeverReachSecrets() throws {
        let harness = ProviderHarness()
        try harness.service.save(ProviderDraft())
        let valid = try harness.json()
        let profiles = try XCTUnwrap(valid["profiles"] as? [[String: Any]], "provider-settings fixture missing a profiles array")
        let profile = try XCTUnwrap(profiles.first, "provider-settings fixture missing its profile")
        let modifications: [[String: Any]] = [
            ["profiles": [profile, profile]],
            ["profiles": [profile.merging(["kind": "unknown"], uniquingKeysWith: { _, new in new })]],
            ["profiles": [profile.merging(["baseURL": "http://remote.example"], uniquingKeysWith: { _, new in new })]],
            ["profiles": [profile.merging(["baseURL": "https://remote.example?key=secret"], uniquingKeysWith: { _, new in new })]]
        ]
        for change in modifications {
            let object = valid.merging(change, uniquingKeysWith: { _, new in new })
            try harness.files.memory.write(JSONSerialization.data(withJSONObject: object), at: "provider-settings.json")
            let reads = harness.secrets.reads.count
            let reopened = harness.reopen()
            XCTAssertEqual(reopened.service.snapshot.readOnlyError, .corruptFile)
            XCTAssertThrowsError(try reopened.service.resolveForTesting(ProviderDraft())) {
                XCTAssertEqual($0 as? ProviderSettingsError, .corruptFile)
            }
            XCTAssertEqual(harness.secrets.reads.count, reads)
        }
    }
}
