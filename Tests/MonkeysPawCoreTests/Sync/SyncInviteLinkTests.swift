import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncInviteLinkTests: XCTestCase {
    private let token = String(repeating: "A", count: 43)

    func testNestedPercentEncodingAndPlusRoundTripExactlyOnce() throws {
        for input in ["https://example.test/paw%20space/a+b", "https://example.test/Caf%C3%A9", "http://[fd00::1]:8080/paw"] {
            let expected = try SyncInviteLink(server: SyncServerURL(input), token: SecretValue(token))
            let parsed = try SyncInviteLink(expected.text)
            XCTAssertTrue(parsed == expected, "Invite did not round-trip")
            XCTAssertTrue(expected.text.contains("%25") || input.contains("fd00"))
        }
        let link = try SyncInviteLink(server: SyncServerURL("https://example.test/a+b"), token: SecretValue(token))
        XCTAssertTrue(link.text.contains("%2B"))
        XCTAssertTrue(try SyncInviteLink(link.text).server.baseURL.path == "/a+b")
    }

    func testBareTokenRequiresExplicitValidServer() throws {
        XCTAssertThrowsError(try SyncInviteLink(token)) { XCTAssertTrue($0 as? SyncInviteLinkError == .serverRequired) }
        let link = try SyncInviteLink(token, server: "HTTPS://EXAMPLE.test:443/paw/api/v1/")
        XCTAssertEqual(link.server.baseURL.absoluteString, "https://example.test/paw")
        XCTAssertThrowsError(try SyncInviteLink(token, server: "http://public.test"))
    }

    func testRejectsDuplicateUnknownMissingAndEmptyQueryValues() throws {
        let original = try SyncInviteLink(server: SyncServerURL("https://example.test"), token: SecretValue(token)).text
        for suffix in ["&server=https%3A%2F%2Fother.test", "&token=" + token, "&unknown=x", "&", "&%74oken=" + token] {
            assertInvalid(original + suffix)
        }
        for query in ["server=", "token=" + token, "server=https%3A%2F%2Fexample.test&token=", "server&token=" + token] {
            assertInvalid("monkeyspaw://join?" + query)
        }
    }

    func testRejectsSchemeHostUserinfoPortPathFragmentAndControls() throws {
        let original = try SyncInviteLink(server: SyncServerURL("https://example.test"), token: SecretValue(token)).text
        let query = String(original.split(separator: "?", maxSplits: 1)[1])
        for prefix in ["https://join", "monkeyspaw:join", "monkeyspaw://other", "monkeyspaw://join.evil.test",
            "monkeyspaw://user@join", "monkeyspaw://join:80", "monkeyspaw://%6Aoin", "monkeyspaw://join/",
            "monkeyspaw://join/path", "monkeyspaw://join\\", "monkeyspaw://join."] {
            assertInvalid(prefix + "?" + query)
        }
        for suffix in ["#", "#fragment", "\n", "\u{0}"] { assertInvalid(original + suffix) }
    }

    func testRejectsNestedServerCredentialsQueriesPathsAndHTTPPolicyViolations() {
        for server in ["https://user:pass@example.test", "https://example.test?x=1&y=2", "https://example.test#x",
            "https://example.test/../paw", "https://example.test/a%2Fb", "https://example.test/%252e%252e",
            "http://public.test", "http://10.evil.test", "http://169.254.1.2", "https://%65xample.test"] {
            let encoded = server.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            assertInvalid("monkeyspaw://join?server=" + encoded + "&token=" + token)
        }
    }

    func testDecodedValuesKeepServerNormalizationWithoutForwardingControls() throws {
        let server = "https%3A%2F%2Fexample.test%2Fpaw"
        for control in ["%0A", "%0D", "%09", "%00", "%23", "%5C"] {
            assertInvalid("monkeyspaw://join?server=" + server + "/a" + control + "b&token=" + token)
            assertInvalid("monkeyspaw://join?server=" + server + "&token=" + token.dropLast() + control)
        }
        assertInvalid("monkeyspaw://join?server=https%3A%2F%2Fevil%0D%0A.test&token=" + token)
        assertInvalid("monkeyspaw://join?server=" + server + "%00&token=" + token)

        // Keep SyncServerURL's surrounding-whitespace normalization, as on Kotlin.
        for suffix in ["%0A", "%0D", "%09", "%20"] {
            let parsed = try SyncInviteLink("monkeyspaw://join?server=" + server + suffix + "&token=" + token)
            XCTAssertEqual(parsed.server.baseURL.absoluteString, "https://example.test/paw")
            XCTAssertEqual(parsed.server.apiURL.absoluteString, "https://example.test/paw/api/v1")
        }
        let literal = try SyncInviteLink("monkeyspaw://join?server=https://example.test/paw&token=" + token)
        XCTAssertEqual(literal.server.baseURL.absoluteString, "https://example.test/paw")
    }

    func testRejectsMalformedPercentInvalidUTF8AndDoubleEncodedValues() throws {
        let server = "https%3A%2F%2Fexample.test"
        for value in ["%", "%Q0", "%0", "%FF", "%2541" + String(token.dropFirst()), String(repeating: "A", count: 42) + "B",
            token + "=", String(repeating: "A", count: 42), String(repeating: "A", count: 44), token + "+"] {
            assertInvalid("monkeyspaw://join?server=" + server + "&token=" + value)
        }
        assertInvalid("monkeyspaw://join?server=https%253A%252F%252Fexample.test&token=" + token)
        let escaped = String(repeating: "%41", count: 43)
        XCTAssertTrue(try SyncInviteLink("monkeyspaw://join?token=" + escaped + "&server=" + server).token == SecretValue(token))
    }

    func testLinkAndErrorsHaveNoSecretDiagnostics() throws {
        let link = try SyncInviteLink(server: SyncServerURL("https://example.test"), token: SecretValue(token))
        assertSyncPresentationRedacted(link, secrets: [token, link.text])
        assertSyncPresentationRedacted(SyncInviteLinkError.invalidLink, secrets: [token, link.text])
    }

    private func assertInvalid(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SyncInviteLink(input), "Invalid invite accepted", file: file, line: line) {
            XCTAssertTrue($0 as? SyncInviteLinkError == .invalidLink, file: file, line: line)
        }
    }
}
