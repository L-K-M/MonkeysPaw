import Foundation

/// Strict X.Y.Z[-prerelease], optionally prefixed by lowercase v. Build
/// metadata and leading zeros are forbidden by the repository's tag contract.
/// Prerelease comparison adapted from Vervellum's SemanticVersion.swift,
/// released under the Unlicense: https://github.com/L-K-M/Vervellum.
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    public let description: String
    public var isPrerelease: Bool { !prerelease.isEmpty }

    private let core: [String]
    private let prerelease: [String]

    public init?(_ raw: String) {
        guard !raw.isEmpty, raw.utf8.count <= Limits.releaseVersionMaxBytes else { return nil }
        let version = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        guard !version.isEmpty else { return nil }
        let parts = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard core.count == 3, core.allSatisfy(Self.isValidNumber) else { return nil }

        let prerelease = parts.count == 2
            ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard prerelease.allSatisfy({ identifier in
            !identifier.isEmpty && identifier.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            } && (!Self.isNumeric(identifier) || Self.isValidNumber(identifier))
        }) else { return nil }

        self.core = core
        self.prerelease = prerelease
        description = version
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.core, rhs.core) where left != right {
            return numericPrecedes(left, right)
        }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (isNumeric(left), isNumeric(right)) {
            case (true, true): return numericPrecedes(left, right)
            case (true, false): return true
            case (false, true): return false
            case (false, false): return left.utf8.lexicographicallyPrecedes(right.utf8)
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.core == rhs.core && lhs.prerelease == rhs.prerelease
    }

    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func isValidNumber(_ value: String) -> Bool {
        isNumeric(value) && (value.count == 1 || value.first != "0")
    }

    // Compare digit lengths first, so hostile large numeric identifiers cannot overflow.
    private static func numericPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs.utf8.lexicographicallyPrecedes(rhs.utf8) : lhs.count < rhs.count
    }
}
