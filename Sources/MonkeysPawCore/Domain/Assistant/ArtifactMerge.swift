import Foundation
import Yams

/// Only ready carries canonical bytes that may be offered for acceptance.
public enum ArtifactMergeResult {
    case ready(ArtifactMergeCandidate)
    case invalid([PromptIssue])
    case failed(PromptWriteError)
}

public struct ArtifactMergeCandidate {
    public let document: PromptDocument
    public let canonicalBytes: Data
}

/// Pure content conversion. Identity generation, stale checks and writes belong
/// to the saving service; this never stores the artifact's notes.
public enum ArtifactMerge {
    public static func write(_ artifact: LlmArtifact, id: ULID) -> ArtifactMergeResult {
        let original = PromptDocument(source: "", body: "", frontMatter: FrontMatter(id: id, title: ""),
            template: Template.parse(""),
            preservedHeader: Node([(string("id"), string(id.rawValue))], Tag(.map), .block))
        return merge(artifact, original: original)
    }

    public static func improve(_ artifact: LlmArtifact, original: PromptDocument) -> ArtifactMergeResult {
        return merge(artifact, original: original)
    }

    private static func merge(_ artifact: LlmArtifact, original: PromptDocument) -> ArtifactMergeResult {
        let originalIssues = PromptValidator.validate(original)
        guard !originalIssues.contains(where: { $0.severity == .error }) else { return .invalid(originalIssues) }

        let artifactIssues = artifact.issues
        guard !artifactIssues.contains(where: { $0.severity == .error }) else { return .invalid(artifactIssues) }

        let replaced = ["title", "description", "tags", "fields"]
        var pairs = original.preservedHeader?.mapping?.filter {
            !replaced.contains(PortableYAML.string($0.key) ?? "")
        }.map { ($0.key, $0.value) } ?? []
        pairs += [(string("title"), string(artifact.title)),
                  (string("description"), string(artifact.description)),
                  (string("tags"), Node(artifact.tags.map(string), Tag(.seq), .block)),
                  (string("fields"), Node(artifact.fields.map { (string($0.name), fieldNode($0)) }, Tag(.map), .block))]

        let old = original.frontMatter
        let fields = artifact.fields.map {
            PromptField(name: $0.name, kind: $0.type, label: $0.label, description: $0.description,
                        defaultValue: $0.defaultValue, options: $0.options, optional: $0.optional, remember: $0.remember)
        }
        let merged = PromptDocument(source: "", body: artifact.body,
            frontMatter: FrontMatter(id: old.id, title: artifact.title, description: artifact.description,
                                     tags: artifact.tags, favorite: old.favorite, isPrivate: old.isPrivate,
                                     fields: fields, format: old.format),
            template: Template.parse(artifact.body), preservedHeader: Node(pairs, Tag(.map), .block))
        let issues = PromptValidator.validate(merged)
        guard !issues.contains(where: { $0.severity == .error }) else { return .invalid(issues) }

        do {
            let canonical = try PromptCodec.write(merged)
            let document = PromptCodec.parse(canonical, filename: artifact.title + ".md")
            let finalIssues = PromptValidator.validate(document)
            guard !finalIssues.contains(where: { $0.severity == .error }) else { return .invalid(finalIssues) }
            return .ready(ArtifactMergeCandidate(document: document, canonicalBytes: Data(canonical.utf8)))
        } catch let error as PromptWriteError {
            return .failed(error)
        } catch {
            return .failed(.serializationFailed)
        }
    }

    private static func fieldNode(_ field: LlmArtifact.Field) -> Node {
        var pairs = [(string("type"), string(field.type.rawValue)),
                     (string("label"), string(field.label)),
                     (string("description"), string(field.description)),
                     (string("optional"), boolean(field.optional)),
                     (string("remember"), boolean(field.remember))]
        if !field.defaultValue.isEmpty { pairs.append((string("default"), string(field.defaultValue))) }
        if field.type == .choice {
            let options = field.options.map { option in
                option.label.utf8.elementsEqual(option.value.utf8) ? string(option.value)
                    : Node([(string("label"), string(option.label)), (string("value"), string(option.value))],
                           Tag(.map), .block)
            }
            pairs.append((string("options"), Node(options, Tag(.seq), .block)))
        }
        return Node(pairs, Tag(.map), .block)
    }

    private static func string(_ value: String) -> Node { Node(value, Tag(.str)) }
    private static func boolean(_ value: Bool) -> Node { Node(value ? "true" : "false", Tag(.bool)) }
}
