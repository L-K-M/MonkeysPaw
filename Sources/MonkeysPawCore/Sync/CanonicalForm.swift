import Foundation
import Yams

/// Pure sync storage bytes and ingest diagnostics. Callers own file writes,
/// identity assignment and per-user favourite state (§9.5).
public struct CanonicalForm: Sendable {
    public enum Scope: String, Sendable {
        case user
        case group
    }

    public let bytes: Data
    /// Lowercase SHA-256 of every stored byte, including the front-matter id.
    public let canonicalHash: String
    /// Group ingest only: nil means absent, including on a canonical re-read.
    public let favorite: Bool?
    public let warnings: [PromptIssue]

    private init(bytes: Data, favorite: Bool? = nil, warnings: [PromptIssue]) {
        self.bytes = bytes
        self.canonicalHash = SHA256.hexDigest(bytes)
        self.favorite = favorite
        self.warnings = warnings
    }

    /// Strip only top-level personal keys, retaining typed unknown metadata
    /// and exact Markdown UTF-8 bytes through the existing canonical writer.
    /// Invalid/future content throws PromptWriteError before any keys are removed.
    public static func group(_ data: Data, filename: String) throws -> Self {
        let document = try validated(data, filename: filename)
        let mapping = document.preservedHeader?.mapping
        let hasFavorite = mapping?.contains { PortableYAML.string($0.key) == "favorite" } ?? false
        var warnings = document.issues.filter { $0.severity == .warning }
        if let entry = mapping?.first(where: { PortableYAML.string($0.key) == "private" }) {
            warnings.append(PromptIssue(.groupPrivateRemoved, at: PortableYAML.location(entry.value)))
        }

        let text = try PromptCodec.write(groupDocument(document))
        return Self(bytes: Data(text.utf8),
                    favorite: hasFavorite ? document.frontMatter.favorite : nil, warnings: warnings)
    }

    /// Private storage validates without rewriting: comments, key presentation,
    /// personal keys and line endings all remain byte-for-byte as supplied.
    public static func user(_ data: Data, filename: String) throws -> Self {
        let document = try validated(data, filename: filename)
        return Self(bytes: data, warnings: document.issues.filter { $0.severity == .warning })
    }

    /// §9.4 adoption compares canonical content independently of identity.
    /// User comparisons retain personal keys; group comparisons strip them.
    /// This is never the stored-byte hash and never assigns an identity.
    public static func equivalentForAdoption(_ local: Data, _ server: Data,
                                             scope: Scope, filename: String) throws -> Bool {
        let left = try adoptionBytes(local, scope: scope, filename: filename)
        let right = try adoptionBytes(server, scope: scope, filename: filename)
        return left == right
    }

    private static func validated(_ data: Data, filename: String) throws -> PromptDocument {
        let document: PromptDocument
        if data.count <= Limits.maxPromptBytes, String(data: data, encoding: .utf8) != nil {
            // Decode only validated UTF-8. Foundation's String(data:) can drop
            // a leading BOM; it is body data when no front matter precedes it.
            document = PromptCodec.parse(String(decoding: data, as: UTF8.self), filename: filename)
        } else {
            document = PromptCodec.parseFile(data, filename: filename)
        }
        guard !document.isReadOnly else {
            throw PromptWriteError.unsupportedFormat(document.frontMatter.format)
        }
        guard !document.issues.contains(where: { $0.severity == .error }) else {
            throw PromptWriteError.invalidPrompt
        }
        return document
    }

    private static func groupDocument(_ document: PromptDocument) -> PromptDocument {
        let front = document.frontMatter
        let metadata = FrontMatter(id: front.id, title: front.title, description: front.description,
                                   tags: front.tags, fields: front.fields, format: front.format)
        let header = document.preservedHeader.map { node in
            let pairs = node.mapping?.filter {
                let key = PortableYAML.string($0.key)
                return key != "favorite" && key != "private"
            }.map { ($0.key, $0.value) } ?? []
            return Node(pairs, Tag(.map), .block)
        }
        return PromptDocument(source: document.source, body: document.body, frontMatter: metadata,
                              template: document.template, preservedHeader: header,
                              decodingIssues: document.decodingIssues,
                              declarationLocations: document.declarationLocations)
    }

    private static func adoptionBytes(_ data: Data, scope: Scope, filename: String) throws -> Data {
        let original = try validated(data, filename: filename)
        let document = scope == .group ? groupDocument(original) : original
        let front = document.frontMatter
        let metadata = FrontMatter(title: front.title, description: front.description, tags: front.tags,
                                   favorite: front.favorite, isPrivate: front.isPrivate,
                                   fields: front.fields, format: front.format)
        let pairs = document.preservedHeader?.mapping?.filter { PortableYAML.string($0.key) != "id" }
            .map { ($0.key, $0.value) } ?? []
        // An id-only server header must match a plain, idless local file.
        // Storage keeps explicit empty headers; this comparison treats them as absent.
        let header = pairs.isEmpty ? nil : Node(pairs, Tag(.map), .block)
        let neutral = PromptDocument(source: document.source, body: document.body, frontMatter: metadata,
                                     template: document.template, preservedHeader: header,
                                     decodingIssues: document.decodingIssues,
                                     declarationLocations: document.declarationLocations)
        return Data(try PromptCodec.write(neutral).utf8)
    }
}
