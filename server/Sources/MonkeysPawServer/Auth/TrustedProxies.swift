import Foundation
import NIOCore

enum ClientIPError: Error, Equatable { case invalidAddress, invalidConfiguration, missingPeer }

/// Numeric parsing and a single spelling keep IPv6 aliases out of IP buckets.
struct ClientIPAddress: Sendable, Equatable {
    let bytes: [UInt8]
    let value: String

    init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= ServerLimits.ipAddressMaxBytes,
              !value.utf8.contains(0), !value.contains("%") else { throw ClientIPError.invalidAddress }
        let socket: SocketAddress
        do { socket = try SocketAddress(ipAddress: value, port: 0) }
        catch { throw ClientIPError.invalidAddress }
        switch socket {
        case .v4(let address):
            var address = address.address.sin_addr
            bytes = withUnsafeBytes(of: &address) { Array($0) }
            self.value = socket.ipAddress!
        case .v6(let address):
            var address = address.address.sin6_addr
            let bytes = withUnsafeBytes(of: &address) { Array($0) }
            if bytes.prefix(12) == Array(repeating: UInt8(0), count: 10) + [255, 255] {
                self.bytes = Array(bytes.suffix(4))
                self.value = self.bytes.map(String.init).joined(separator: ".")
            } else {
                self.bytes = bytes
                self.value = socket.ipAddress!
            }
        case .unixDomainSocket: throw ClientIPError.invalidAddress
        }
    }
}

struct TrustedProxies: Sendable {
    private let ranges: [IPRange]

    init(configuration: String = "") throws {
        guard configuration.utf8.count <= ServerLimits.trustedProxyConfigurationMaxBytes else {
            throw ClientIPError.invalidConfiguration
        }
        if configuration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ranges = []
            return
        }
        let entries = configuration.split(separator: ",", omittingEmptySubsequences: false)
        guard entries.count <= ServerLimits.trustedProxyMaxEntries else { throw ClientIPError.invalidConfiguration }
        ranges = try entries.map { try IPRange(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func clientIP(peer: SocketAddress?, forwardedFor: [String]) throws -> ClientIPAddress {
        guard let value = peer?.ipAddress else { throw ClientIPError.missingPeer }
        let peer = try ClientIPAddress(value)
        guard contains(peer), !forwardedFor.isEmpty else { return peer }
        var current = peer
        var hop: [UInt8] = []
        var inspectedBytes = 0
        var inspectedHops = 0

        func consumeHop() -> Bool {
            guard inspectedHops < ServerLimits.forwardedForMaxHops,
                  let parsed = try? ClientIPAddress(String(decoding: hop.reversed(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)) else { return false }
            current = parsed
            inspectedHops += 1
            hop.removeAll(keepingCapacity: true)
            return true
        }

        // Inspect only the trusted suffix. Counting spoofable prefixes could
        // let a client select the proxy bucket by padding an otherwise valid XFF.
        for index in forwardedFor.indices.reversed() {
            for byte in forwardedFor[index].utf8.reversed() {
                if byte == 44 {
                    guard consumeHop() else { return peer }
                    guard contains(current) else { return current }
                }
                guard inspectedBytes < ServerLimits.forwardedForMaxBytes else { return peer }
                inspectedBytes += 1
                if byte != 44 { hop.append(byte) }
            }
            guard consumeHop() else { return peer }
            guard contains(current) else { return current }
            if index > 0 {
                guard inspectedBytes < ServerLimits.forwardedForMaxBytes else { return peer }
                inspectedBytes += 1 // Repeated fields are separated by a comma.
            }
        }
        return current
    }

    private func contains(_ address: ClientIPAddress) -> Bool { ranges.contains { $0.contains(address) } }
}

private struct IPRange: Sendable {
    let address: ClientIPAddress
    let prefix: Int

    init(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { throw ClientIPError.invalidConfiguration }
        address = try ClientIPAddress(String(parts[0]))
        guard parts.count == 2 else {
            prefix = address.bytes.count * 8
            return
        }
        guard !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let bits = Int(parts[1]) else { throw ClientIPError.invalidConfiguration }
        let mapped = parts[0].contains(":") && address.bytes.count == 4
        let width = mapped ? 128 : address.bytes.count * 8
        guard (0...width).contains(bits), !mapped || bits >= 96 else { throw ClientIPError.invalidConfiguration }
        prefix = mapped ? bits - 96 : bits
    }

    func contains(_ candidate: ClientIPAddress) -> Bool {
        guard candidate.bytes.count == address.bytes.count else { return false }
        let wholeBytes = prefix / 8
        guard candidate.bytes.prefix(wholeBytes) == address.bytes.prefix(wholeBytes) else { return false }
        let remainingBits = prefix % 8
        guard remainingBits != 0 else { return true }
        let mask = UInt8.max << (8 - remainingBits)
        return candidate.bytes[wholeBytes] & mask == address.bytes[wholeBytes] & mask
    }
}
