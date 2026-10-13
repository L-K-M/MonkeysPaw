import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncServerURLTests: XCTestCase {
    func testNormalizationProducesAccountDeploymentBasesAndOneAPISuffix() throws {
        let cases = [
            (" HTTPS://EXAMPLE.COM.:443/ ", "https://example.com"),
            ("http://LOCALHOST:80/paw/", "http://localhost/paw"),
            ("https://example.com:8443/paw/api/v1/", "https://example.com:8443/paw"),
            ("https://example.com/api/v1/api/v1", "https://example.com"),
            ("https://example.com/paw/api/v1/api/v1/", "https://example.com/paw"),
            ("https://example.com/a%20b/", "https://example.com/a%20b"),
            ("https://example.com/café/", "https://example.com/caf%C3%A9"),
            ("https://BÜCHER.example/", "https://xn--bcher-kva.example"),
            ("https://xn--bcher-kva.example/", "https://xn--bcher-kva.example"),
            ("http://[FC00:0000:0:0:0:0:0:1]:80/", "http://[fc00::1]"),
            ("http://[0:0:0:0:0:0:0:1]/", "http://[::1]")
        ]
        for (input, expected) in cases {
            let server = try SyncServerURL(input)
            XCTAssertEqual(server.baseURL.absoluteString, expected, input)
            XCTAssertEqual(server.apiURL.absoluteString, expected + "/api/v1", input)
            XCTAssertEqual(try SyncServerURL(server.baseURL.absoluteString), server)
            XCTAssertEqual(try SyncServerURL(server.apiURL.absoluteString), server)
            XCTAssertNoThrow(try SyncAccountIdentity(serverURL: expected, userID: ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!), input)
        }
    }

    func testHTTPAllowsOnlyLoopbackCanonicalRFC1918AndULA() throws {
        for host in ["localhost", "LOCALHOST.", "127.0.0.1", "127.255.255.255", "[::1]",
                     "10.0.0.0", "10.255.255.255", "172.16.0.0", "172.31.255.255",
                     "192.168.0.0", "192.168.255.255", "[fc00::]", "[fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]"] {
            XCTAssertNoThrow(try SyncServerURL("http://" + host + ":8080/paw"), host)
        }
    }

    func testPercentEncodedHostsCannotBecomeCanonicalAccountsOrServerURLs() {
        let userID = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")!
        for input in ["https://ex%C3%A9mple.com", "https://ex%61mple.com", "https://%78n--bcher-kva.example"] {
            XCTAssertThrowsError(try SyncAccountIdentity(serverURL: input, userID: userID)) {
                XCTAssertEqual($0 as? SyncError, .invalidAccount, input)
            }
            XCTAssertThrowsError(try SyncServerURL(input)) {
                XCTAssertEqual($0 as? SyncServerURLError, .invalidURL, input)
            }
        }
        for input in ["https://example.com", "http://192.168.1.10", "http://[::1]:8080", "https://xn--bcher-kva.example"] {
            XCTAssertNoThrow(try SyncAccountIdentity(serverURL: input, userID: userID), input)
            XCTAssertNoThrow(try SyncServerURL(input), input)
        }
    }

    func testPublicPrivateHostnameAndLiteralLookalikesRequireHTTPS() throws {
        for host in ["example.com", "server.local", "lan", "localhost.evil.test", "localhost.localdomain",
                     "9.255.255.255", "11.0.0.0", "172.15.255.255", "172.32.0.0",
                     "192.167.255.255", "192.169.0.0", "100.64.0.0", "100.127.255.255",
                     "169.254.0.1", "0.0.0.0", "[fbff:ffff::1]", "[fe00::1]", "[fe80::1]", "[::2]",
                     "[::ffff:127.0.0.1]", "[::ffff:192.168.1.1]", "[::ffff:a00:1]",
                     "127.1", "10.1", "2130706433", "167772161", "0177.0.0.1", "012.0.0.1",
                     "127.0.0.01", "10.00.0.1", "0x7f000001", "0x0a000001", "0x0a.0.0.1",
                     "bücher.example", "xn--bcher-kva.example", "１２７.０.０.１"] {
            XCTAssertThrowsError(try SyncServerURL("http://" + host)) {
                XCTAssertEqual($0 as? SyncServerURLError, .insecureURL, host)
            }
            XCTAssertNoThrow(try SyncServerURL("https://" + host), host)
        }
    }

    func testRejectsCredentialsQueriesFragmentsAndInvalidPrefixes() {
        let cases: [(String, SyncServerURLError)] = [
            ("", .invalidURL), ("example.com", .invalidURL), ("//example.com", .invalidURL),
            ("ftp://localhost", .invalidURL), ("https://example.com:0", .invalidURL),
            ("https://example.com:65536", .invalidURL), ("https://example.com:abc", .invalidURL),
            ("https://example.com..", .invalidURL), ("https://localhost..", .invalidURL),
            ("http://10.0.0.1..", .invalidURL),
            ("https://[not:ipv6]", .invalidURL), ("https://[fc00:::1]", .invalidURL),
            ("http://[fe80::1%25eth0]", .invalidURL), ("http://%31%32%37.0.0.1", .invalidURL),
            ("https://exam ple.com", .invalidURL), ("https://example.com\\evil", .invalidURL),
            ("https://example.com/a\nb", .invalidURL),
            ("https://user:secret@example.com", .credentialsInURL),
            ("https://@example.com", .credentialsInURL),
            ("https://example.com?", .queryOrFragmentInURL),
            ("https://example.com?token=secret", .queryOrFragmentInURL),
            ("https://example.com#", .queryOrFragmentInURL),
            ("https://example.com/a//b", .invalidDeploymentPrefix),
            ("https://example.com/../paw", .invalidDeploymentPrefix),
            ("https://example.com/%2E/paw", .invalidDeploymentPrefix),
            ("https://example.com/a%2fb", .invalidDeploymentPrefix),
            ("https://example.com/a%5cb", .invalidDeploymentPrefix),
            ("https://example.com/%00", .invalidDeploymentPrefix),
            ("https://example.com/%252e%252e", .invalidDeploymentPrefix),
            ("https://example.com/a%3fb", .invalidDeploymentPrefix),
            ("https://example.com/a%23b", .invalidDeploymentPrefix)
        ]
        for (input, expected) in cases {
            XCTAssertThrowsError(try SyncServerURL(input)) {
                XCTAssertEqual($0 as? SyncServerURLError, expected, input)
            }
        }
    }

    func testRequestPolicyBindsSchemeHostPortAndDeploymentPrefix() throws {
        let server = try SyncServerURL("https://example.com:8443/paw")
        let valid = URL(string: "https://EXAMPLE.COM:8443/paw/api/v1/prompts/ID?base_rev=1")!
        XCTAssertEqual(try server.validatedRequestURL(valid).absoluteString,
                       "https://example.com:8443/paw/api/v1/prompts/ID?base_rev=1")
        for input in ["https://other.example:8443/paw/api/v1/me", "https://example.com/paw/api/v1/me",
                      "https://example.com:8443/other/api/v1/me", "https://example.com:8443/paw/api/v10/me",
                      "https://example.com:8443/paw-evil/api/v1/me", "https://example.com:8443/api/v1/me"] {
            XCTAssertThrowsError(try server.validatedRequestURL(URL(string: input)!)) {
                XCTAssertEqual($0 as? HTTPTransportError, .serverMismatch, input)
            }
        }
        let dotSegments = try XCTUnwrap(URL(string: "https://example.com:8443/paw/api/v1/../me"))
        XCTAssertEqual(URLComponents(url: dotSegments, resolvingAgainstBaseURL: false)?.path, "/paw/api/v1/../me")
        XCTAssertThrowsError(try server.validatedRequestURL(dotSegments)) {
            XCTAssertEqual($0 as? HTTPTransportError, .invalidURL)
        }
        XCTAssertThrowsError(try server.validatedRequestURL(URL(string: "https://example.com:8443/paw/api/v1/me#secret")!))
        XCTAssertThrowsError(try server.validatedRequestURL(URL(string: "https://user:secret@example.com:8443/paw/api/v1/me")!))
        let encoded = try SyncServerURL("https://example.com/café")
        XCTAssertEqual(try encoded.validatedRequestURL(encoded.apiURL.appendingPathComponent("me")),
                       encoded.apiURL.appendingPathComponent("me"))
        let local = try SyncServerURL("https://10.0.0.1/paw")
        XCTAssertThrowsError(try local.validatedRequestURL(URL(string: "http://10.0.0.1/paw/api/v1/me")!)) {
            XCTAssertEqual($0 as? HTTPTransportError, .serverMismatch)
        }
    }

    func testErrorsDoNotRetainInput() {
        let secret = UUID().uuidString
        XCTAssertThrowsError(try SyncServerURL("https://" + secret + "@example.com")) { error in
            XCTAssertEqual(error as? SyncServerURLError, .credentialsInURL)
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(String(reflecting: error).contains(secret))
            XCTAssertFalse((error as NSError).description.contains(secret))
        }
    }
}
