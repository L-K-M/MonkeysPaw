import Foundation

/// A checked sync spelling and its per-scope uniqueness key (§8.4, §19 B4).
/// Local filesystem identity continues to use unnormalized RelativePath bytes.
public struct SyncPath: Equatable, Sendable {
    public let path: String
    public let pathKey: String

    fileprivate init(path: String, pathKey: String) {
        self.path = path
        self.pathKey = pathKey
    }
}

public enum SyncPathValidator {
    public enum Scope: String, Sendable {
        /// The user's private scope, called `user` on the wire.
        case user
        case group
    }

    /// Returns NFC text and NFC → full default case fold → NFC path_key.
    /// Throws the first issue: empty input, NFC, absolute path, total size,
    /// segments in order, suffix, folded-key NFC, then reserved prefix.
    /// Limits apply to NFC path bytes, not the potentially longer folded key.
    /// No filesystem or state is read.
    public static func validate(_ input: String, scope: Scope) throws -> SyncPath {
        guard !input.isEmpty else { throw SyncPathIssue(.emptyPath) }
        let path = try nfc(input)
        let bytes = path.utf8
        guard bytes.first != 47 else { throw SyncPathIssue(.absolutePath) }
        guard bytes.count <= Limits.maxPathBytes else { throw SyncPathIssue(.pathTooLong) }

        // A slash followed by a combining scalar can be one Swift Character.
        // ASCII slash bytes always separate segments, even in that spelling.
        let segments = bytes.split(separator: 47, omittingEmptySubsequences: false)
        for (index, segment) in segments.enumerated() {
            guard !segment.isEmpty else { throw SyncPathIssue(.emptySegment, segment: index) }
            guard !segment.elementsEqual([46]), !segment.elementsEqual([46, 46]) else {
                throw SyncPathIssue(.dotSegment, segment: index)
            }
            // §5.1 ignores dot-directories but permits dot-prefixed files.
            guard index == segments.count - 1 || segment.first != 46 else {
                throw SyncPathIssue(.hiddenDirectory, segment: index)
            }
            guard !segment.contains(92) else { throw SyncPathIssue(.backslash, segment: index) }
            let text = String(decoding: segment, as: UTF8.self)
            guard !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw SyncPathIssue(.controlCharacter, segment: index)
            }
            guard segment.last != 46, segment.last != 32 else {
                throw SyncPathIssue(.trailingDotOrSpace, segment: index)
            }
            guard segment.count <= Limits.syncPathSegmentMaxBytes else {
                throw SyncPathIssue(.segmentTooLong, segment: index)
            }
        }

        guard bytes.suffix(3).elementsEqual([46, 109, 100]) else {
            throw SyncPathIssue(.invalidExtension)
        }
        // Default non-Turkic C/F mappings preserve accents/width and expand
        // full folds. Host case-comparison tables are not the full Unicode map.
        let key = try nfc(SyncPathCaseFold.fold(path))
        if scope == .user, key.utf8.starts(with: "groups/".utf8) {
            throw SyncPathIssue(.reservedGroupsPrefix)
        }
        return SyncPath(path: path, pathKey: key)
    }

    private static func nfc(_ text: String) throws -> String {
        // CF's precomposedString convenience can truncate long combining runs.
        // The ICU transform preserves all scalars and their canonical order.
        guard let normalized = text.applyingTransform(StringTransform("Any-NFC"), reverse: false) else {
            throw SyncPathIssue(.normalizationFailed)
        }
        return normalized
    }
}

/// Diagnostics retain no input path. Segment indices are zero-based; global
/// issues have no segment. Every issue blocks a sync write.
public struct SyncPathIssue: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: SyncPathIssueCode
    public let segmentIndex: Int?
    public var message: String { code.message }
    public var description: String { message }

    fileprivate init(_ code: SyncPathIssueCode, segment: Int? = nil) {
        self.code = code
        self.segmentIndex = segment
    }
}

public enum SyncPathIssueCode: String, Sendable {
    case emptyPath = "path.empty"
    case normalizationFailed = "path.normalization_failed"
    case absolutePath = "path.absolute"
    case pathTooLong = "path.too_long"
    case emptySegment = "path.segment_empty"
    case dotSegment = "path.segment_dot"
    case hiddenDirectory = "path.segment_hidden"
    case backslash = "path.backslash"
    case controlCharacter = "path.control_character"
    case trailingDotOrSpace = "path.trailing_dot_or_space"
    case segmentTooLong = "path.segment_too_long"
    case invalidExtension = "path.invalid_extension"
    case reservedGroupsPrefix = "path.reserved_groups_prefix"

    fileprivate var message: String {
        switch self {
        case .emptyPath: return "Supply a relative prompt path."
        case .normalizationFailed: return "The sync path could not be normalized."
        case .absolutePath: return "Use a relative path without a leading slash."
        case .pathTooLong: return "Keep the NFC path within \(Limits.maxPathBytes) UTF-8 bytes."
        case .emptySegment: return "Use nonempty path segments separated by a single slash."
        case .dotSegment: return "Replace dot and dot-dot path segments with names."
        case .hiddenDirectory: return "Use folder names without a leading dot."
        case .backslash: return "Use forward slashes to separate path segments."
        case .controlCharacter: return "Remove control characters from the path."
        case .trailingDotOrSpace: return "Remove trailing dots and spaces from path segments."
        case .segmentTooLong: return "Keep each NFC segment within \(Limits.syncPathSegmentMaxBytes) UTF-8 bytes."
        case .invalidExtension: return "End the prompt path with the exact lowercase .md suffix."
        case .reservedGroupsPrefix: return "Use a private path outside the reserved Groups folder."
        }
    }
}
