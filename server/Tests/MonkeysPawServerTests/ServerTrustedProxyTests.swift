import Foundation
import NIOCore
import Testing
@testable import MonkeysPawServer

struct ServerTrustedProxyTests {
    @Test func defaultAndUntrustedPeersIgnoreEveryForwardedHeader() throws {
        let peer = try SocketAddress(ipAddress: "198.51.100.1", port: 1234)
        for proxies in [try TrustedProxies(), try TrustedProxies(configuration: "10.0.0.0/8,2001:db8::/32")] {
            for headers in [["203.0.113.1"], ["bad", "10.0.0.2"], [String(repeating: "x", count: 10_000)]] {
                #expect(try proxies.clientIP(peer: peer, forwardedFor: headers).value == "198.51.100.1")
            }
        }
        #expect(throws: ClientIPError.missingPeer) { try TrustedProxies().clientIP(peer: nil, forwardedFor: ["203.0.113.1"]) }
    }

    @Test func trustedChainsStopAtTheNearestUntrustedHopAcrossRepeatedFields() throws {
        let proxies = try TrustedProxies(configuration: " 10.0.0.0/8, 2001:db8::/32 ")
        let peer = try SocketAddress(ipAddress: "10.0.0.2", port: 1234)
        #expect(try proxies.clientIP(peer: peer, forwardedFor: ["203.0.113.1, 10.2.3.4"]).value == "203.0.113.1")
        #expect(try proxies.clientIP(peer: peer, forwardedFor: ["192.0.2.10, 198.51.100.7", "10.2.3.4,2001:db8::1"]).value == "198.51.100.7")
        #expect(try proxies.clientIP(peer: peer, forwardedFor: ["bad spoofed prefix,198.51.100.7", "10.2.3.4"]).value == "198.51.100.7")
        #expect(try proxies.clientIP(peer: peer, forwardedFor: ["10.3.4.5,10.2.3.4"]).value == "10.3.4.5")
    }

    @Test func oversizedSpoofedPrefixesCannotSelectTheProxyBucket() throws {
        let proxies = try TrustedProxies(configuration: "10.0.0.0/8")
        let peer = try SocketAddress(ipAddress: "10.0.0.1", port: 1234)
        let oversizedBytes = String(repeating: "x", count: ServerLimits.forwardedForMaxBytes + 1)
        let oversizedHops = Array(repeating: "192.0.2.55", count: ServerLimits.forwardedForMaxHops + 1).joined(separator: ",")
        for prefix in [oversizedBytes, oversizedHops] {
            #expect(try proxies.clientIP(peer: peer, forwardedFor: [prefix + ",198.51.100.7,10.2.3.4"]).value == "198.51.100.7")
        }
        let repeatedFields = Array(repeating: "spoof", count: ServerLimits.forwardedForMaxHops + 1) + ["198.51.100.7,10.2.3.4"]
        #expect(try proxies.clientIP(peer: peer, forwardedFor: repeatedFields).value == "198.51.100.7")
    }

    @Test func CIDRBitsAndAddressFamiliesAreChecked() throws {
        let v4 = try TrustedProxies(configuration: "192.0.2.128/25")
        for (peer, expected) in [("192.0.2.127", "192.0.2.127"), ("192.0.2.128", "198.51.100.1"),
                                 ("192.0.2.255", "198.51.100.1"), ("192.0.3.1", "192.0.3.1")] {
            #expect(try v4.clientIP(peer: SocketAddress(ipAddress: peer, port: 0), forwardedFor: ["198.51.100.1"]).value == expected)
        }
        let v6 = try TrustedProxies(configuration: "2001:db8:0:8000::/49")
        for (peer, expected) in [("2001:db8:0:7fff::1", "2001:db8:0:7fff::1"),
                                 ("2001:db8:0:8000::1", "198.51.100.1"), ("2001:db8:0:ffff::1", "198.51.100.1"),
                                 ("2001:db8:1::1", "2001:db8:1::1"), ("192.0.2.128", "192.0.2.128")] {
            #expect(try v6.clientIP(peer: SocketAddress(ipAddress: peer, port: 0), forwardedFor: ["198.51.100.1"]).value == expected)
        }
        for configuration in ["192.0.2.1", "192.0.2.1/32", "::ffff:192.0.2.1/128"] {
            let exact = try TrustedProxies(configuration: configuration)
            #expect(try exact.clientIP(peer: SocketAddress(ipAddress: "::ffff:192.0.2.1", port: 0), forwardedFor: ["198.51.100.1"]).value == "198.51.100.1")
            #expect(try exact.clientIP(peer: SocketAddress(ipAddress: "192.0.2.2", port: 0), forwardedFor: ["198.51.100.1"]).value == "192.0.2.2")
        }
        #expect(try TrustedProxies(configuration: "::1/128").clientIP(peer: SocketAddress(ipAddress: "::2", port: 0), forwardedFor: ["198.51.100.1"]).value == "::2")
    }

    @Test func IPSpellingsAndMappedIPv6UseOneCanonicalBucketKey() throws {
        #expect(try ClientIPAddress("2001:0DB8:0000:0000:0000:0000:0000:0001") == ClientIPAddress("2001:db8::1"))
        #expect(try ClientIPAddress("::ffff:192.0.2.1") == ClientIPAddress("192.0.2.1"))
        #expect(try ClientIPAddress("::ffff:c000:201") == ClientIPAddress("192.0.2.1"))
        for invalid in ["", "localhost", "127.1", "0127.0.0.1", "192.0.2.1:80", "[::1]", "::1%lo", "192.0.2.1\u{0}spoof"] {
            #expect(throws: ClientIPError.invalidAddress) { try ClientIPAddress(invalid) }
        }
    }

    @Test func malformedOrOversizedTrustedSuffixFallsBackToSocketPeer() throws {
        let proxies = try TrustedProxies(configuration: "10.0.0.1")
        let peer = try SocketAddress(ipAddress: "10.0.0.1", port: 1234)
        for headers in [[], [""], ["203.0.113.1,"], ["203.0.113.1,unknown"], ["127.0.0.1\u{0}spoof"],
                        ["203.0.113.1, [::1]"], [String(repeating: " ", count: ServerLimits.forwardedForMaxBytes + 1)],
                        [Array(repeating: "10.0.0.1", count: ServerLimits.forwardedForMaxHops + 1).joined(separator: ",")],
                        Array(repeating: "10.0.0.1", count: ServerLimits.forwardedForMaxHops + 1)] {
            #expect(try proxies.clientIP(peer: peer, forwardedFor: headers).value == "10.0.0.1")
        }
        let boundary = Array(repeating: "10.0.0.1", count: ServerLimits.forwardedForMaxHops - 1)
        #expect(try proxies.clientIP(peer: peer, forwardedFor: [(["203.0.113.1"] + boundary).joined(separator: ",")]).value == "203.0.113.1")
        let exactBytes = String(repeating: " ", count: ServerLimits.forwardedForMaxBytes - "203.0.113.1".utf8.count) + "203.0.113.1"
        #expect(try proxies.clientIP(peer: peer, forwardedFor: [exactBytes]).value == "203.0.113.1")
        #expect(try proxies.clientIP(peer: peer, forwardedFor: [" " + exactBytes]).value == "10.0.0.1")
    }

    @Test func trustedProxyConfigurationFailsClosedAndRedactsInvalidValues() throws {
        for invalid in ["*", "localhost", "10.0.0.1,", "10.0.0.1,,::1", "10.0.0.1/33", "::1/129", "10.0.0.1/-1",
                        "10.0.0.1/+1", "10.0.0.1/", "10.0.0.1/8/9", "::ffff:192.0.2.1/95", "192.0.2.1\u{0}secret",
                        Array(repeating: "10.0.0.1", count: ServerLimits.trustedProxyMaxEntries + 1).joined(separator: ","),
                        String(repeating: "x", count: ServerLimits.trustedProxyConfigurationMaxBytes + 1)] {
            do {
                _ = try ServerConfiguration(environment: ["MONKEYSPAW_TRUSTED_PROXIES": invalid])
                Issue.record("Invalid proxy configuration was accepted")
            } catch {
                let message = String(describing: error)
                #expect(message.hasPrefix("MONKEYSPAW_TRUSTED_PROXIES must be"))
                #expect(!message.contains(invalid))
            }
        }
        for blank in ["", " \t\n"] {
            let configuration = try ServerConfiguration(environment: ["MONKEYSPAW_TRUSTED_PROXIES": blank])
            #expect(try configuration.trustedProxies.clientIP(peer: SocketAddress(ipAddress: "127.0.0.1", port: 0), forwardedFor: ["198.51.100.1"]).value == "127.0.0.1")
        }
    }
}
