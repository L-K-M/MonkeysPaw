import Foundation
import XCTest
@testable import MonkeysPawCore

final class ProviderNormalizationTests: XCTestCase {
    func testAnthropicBaseAndFullEndpointsNormalizeWithoutRepeatedV1() throws {
        let cases = [
            ("https://api.anthropic.com", "https://api.anthropic.com"),
            (" HTTPS://API.ANTHROPIC.COM:443/ \n", "https://api.anthropic.com"),
            ("https://api.anthropic.com/v1/", "https://api.anthropic.com"),
            ("https://api.anthropic.com/v1/messages/", "https://api.anthropic.com"),
            ("https://api.anthropic.com/v1/models", "https://api.anthropic.com"),
            ("https://proxy.example/anthropic/v1/messages", "https://proxy.example/anthropic"),
            ("https://proxy.example/anthropic/", "https://proxy.example/anthropic"),
            ("https://proxy.example/anthropic/v1/v1/messages", "https://proxy.example/anthropic"),
            ("http://[0:0:0:0:0:0:0:1]:8080/v1", "http://[0:0:0:0:0:0:0:1]:8080"),
            ("http://localhost:8080/v1", "http://localhost:8080")
        ]
        for (input, expected) in cases {
            let normalized = try ProviderSettings.normalizeBaseURL(input, kind: .anthropic)
            XCTAssertEqual(normalized.absoluteString, expected, input)
            let profile = try ProviderProfile(id: ProviderProfileID(), displayName: "Custom", kind: .anthropic,
                baseURL: input, modelID: "manual")
            XCTAssertEqual(profile.completionURL.absoluteString, expected + "/v1/messages")
            XCTAssertEqual(profile.modelsURL.absoluteString, expected + "/v1/models")
            XCTAssertEqual(try ProviderSettings.normalizeBaseURL(expected, kind: .anthropic), normalized)
        }
    }

    func testOpenAIHostV1CustomPathAndFullEndpoints() throws {
        let cases = [
            ("https://api.openai.com", "https://api.openai.com/v1"),
            ("https://api.openai.com/", "https://api.openai.com/v1"),
            ("https://api.openai.com/v1/", "https://api.openai.com/v1"),
            ("https://api.openai.com/v1/chat/completions/", "https://api.openai.com/v1"),
            ("https://api.openai.com/chat/completions", "https://api.openai.com/v1"),
            ("https://openrouter.ai/api/v1/chat/completions", "https://openrouter.ai/api/v1"),
            ("https://proxy.example/custom", "https://proxy.example/custom"),
            ("https://proxy.example/custom/models", "https://proxy.example/custom"),
            ("https://proxy.example/custom/models/models", "https://proxy.example/custom"),
            ("http://127.0.0.1:11434/v1", "http://127.0.0.1:11434/v1"),
            ("http://[::1]:1234/", "http://[::1]:1234/v1"),
            ("http://localhost.:80", "http://localhost/v1")
        ]
        for (input, expected) in cases {
            let normalized = try ProviderSettings.normalizeBaseURL(input, kind: .openaiCompatible)
            XCTAssertEqual(normalized.absoluteString, expected, input)
            let profile = try ProviderProfile(id: ProviderProfileID(), displayName: "Custom", kind: .openaiCompatible,
                baseURL: input, modelID: "typed-model")
            XCTAssertEqual(profile.completionURL.absoluteString, expected + "/chat/completions")
            XCTAssertEqual(profile.modelsURL.absoluteString, expected + "/models")
            XCTAssertEqual(try ProviderSettings.normalizeBaseURL(expected, kind: .openaiCompatible), normalized)
        }
    }

    func testHTTPRequiresAnExactLoopbackAddress() throws {
        for host in ["localhost", "127.0.0.1", "127.12.34.56", "[::1]"] {
            XCTAssertNoThrow(try ProviderSettings.normalizeBaseURL("http://\(host):8080", kind: .openaiCompatible))
        }
        for host in ["example.com", "localhost.evil.test", "127.0.0.1.evil.test", "192.168.1.2", "[::2]", "127.0.0.999"] {
            XCTAssertThrowsError(try ProviderSettings.normalizeBaseURL("http://\(host)", kind: .anthropic)) {
                XCTAssertEqual($0 as? ProviderSettingsError, .insecureBaseURL)
            }
        }
    }

    func testCredentialsQueryAndFragmentsAreRejectedForBothKinds() {
        for kind in [ProviderKind.anthropic, .openaiCompatible] {
            for input in ["https://user:password@example.com", "https://user@example.com", "https://@example.com"] {
                XCTAssertThrowsError(try ProviderSettings.normalizeBaseURL(input, kind: kind)) {
                    XCTAssertEqual($0 as? ProviderSettingsError, .credentialsInURL)
                }
            }
            for input in ["https://example.com?api_key=secret", "https://example.com?token=secret",
                          "https://example.com?harmless=value", "https://example.com#secret", "https://example.com?"] {
                XCTAssertThrowsError(try ProviderSettings.normalizeBaseURL(input, kind: kind)) {
                    XCTAssertEqual($0 as? ProviderSettingsError, .queryOrFragmentInURL)
                }
            }
        }
    }

    func testMalformedSchemesPathsPortsAndEncodedSeparatorsAreRejected() {
        for input in ["", "example.com", "/v1", "file:///v1", "ftp://example.com", "https://",
                      "https://example.com:0", "https://example.com:65536", "https://example.com/a/../v1",
                      "https://example.com/%2e%2e/v1", "https://example.com/v1%2Fmessages",
                      "https://example.com/a\\b", "https://example.com/a//b", "https://example.com/a%0Ab"] {
            XCTAssertThrowsError(try ProviderSettings.normalizeBaseURL(input, kind: .anthropic), input)
        }
    }

    func testProfileIDsAccountsAndEnvironmentNamesAreStableAndIsolated() throws {
        let id = ProviderProfileID(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!)
        XCTAssertEqual(id.rawValue, "00112233-4455-6677-8899-aabbccddeeff")
        XCTAssertEqual(id.environmentVariable, "MONKEYSPAW_PROVIDER_00112233445566778899AABBCCDDEEFF_API_KEY")
        XCTAssertEqual(SecretAccount.provider(id).rawValue, "provider:" + id.rawValue)
        XCTAssertNotEqual(SecretAccount.provider(id), .provider(ProviderProfileID()))
        XCTAssertNotEqual(try SecretAccount(namespace: "device-token", name: id.rawValue), .provider(id))
        XCTAssertEqual(try JSONDecoder().decode(ProviderProfileID.self, from: JSONEncoder().encode(id)), id)
        let account = SecretAccount.provider(id)
        XCTAssertEqual(try JSONDecoder().decode(SecretAccount.self, from: JSONEncoder().encode(account)), account)
        for input in ["", "provider", "provider:", "provider:a:b", "provider:a b"] {
            let bytes = try JSONEncoder().encode(input)
            XCTAssertThrowsError(try JSONDecoder().decode(SecretAccount.self, from: bytes))
        }
    }

    func testProfileRejectsCrossAccountReferencesAndSettingsRejectsDuplicateIDs() throws {
        let id = ProviderProfileID()
        let profile = try ProviderProfile(id: id, displayName: "Name", kind: .anthropic,
            baseURL: "https://api.anthropic.com", modelID: "manual", secretReference: .provider(id))
        XCTAssertThrowsError(try ProviderProfile(id: id, displayName: "Name", kind: .anthropic,
            baseURL: "https://api.anthropic.com", modelID: "manual", secretReference: .provider(ProviderProfileID())))
        XCTAssertThrowsError(try ProviderSettings(profiles: [profile, profile]))
        XCTAssertThrowsError(try ProviderSettings(profiles: [profile], selectedProfileID: ProviderProfileID()))
    }

    func testCacheKeyUsesIDKindNormalizedEndpointAndModel() throws {
        let id = ProviderProfileID()
        func profile(id: ProviderProfileID, kind: ProviderKind, base: String, model: String) throws -> ProviderProfile {
            try ProviderProfile(id: id, displayName: "Name", kind: kind, baseURL: base, modelID: model)
        }
        let original = try profile(id: id, kind: .anthropic, base: "https://api.anthropic.com", model: "manual").cacheKey
        XCTAssertEqual(original, try profile(id: id, kind: .anthropic,
            base: "HTTPS://API.ANTHROPIC.COM:443/v1/messages", model: "manual").cacheKey)
        let changes = [
            try profile(id: ProviderProfileID(), kind: .anthropic, base: "https://api.anthropic.com", model: "manual"),
            try profile(id: id, kind: .openaiCompatible, base: "https://api.anthropic.com", model: "manual"),
            try profile(id: id, kind: .anthropic, base: "https://api.anthropic.com/proxy", model: "manual"),
            try profile(id: id, kind: .anthropic, base: "https://api.anthropic.com", model: "other")
        ]
        for changed in changes { XCTAssertNotEqual(changed.cacheKey, original) }
    }
}
