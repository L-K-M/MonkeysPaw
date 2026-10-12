import Foundation

/// A rename is a possible one-for-one substitution in one replacement hunk.
public enum PlaceholderChange: Equatable, Sendable {
    case added(String)
    case removed(String)
    case renamed(from: String, to: String)
}

public struct ArtifactDiff: Equatable, Sendable {
    public let frontMatter: [LineDiffLine]
    public let body: [LineDiffLine]
    /// Unique name changes, ordered by original first use, then added first use.
    public let placeholderWarnings: [PlaceholderChange]

    /// Compare canonical front matter (including delimiters) and exact body bytes
    /// separately. nil is the empty baseline for a newly written document.
    public static func compare(original: PromptDocument?, candidate: ArtifactMergeCandidate) throws -> ArtifactDiff {
        let oldSource = try original.map { try PromptCodec.write($0) } ?? ""
        let oldBody = original?.body ?? ""
        let newBody = candidate.document.body
        let oldHeader = Data(oldSource.utf8).dropLast(oldBody.utf8.count)
        let newHeader = candidate.canonicalBytes.dropLast(newBody.utf8.count)
        let headerDiff = try MyersLineDiff.compare(String(decoding: oldHeader, as: UTF8.self),
                                                  String(decoding: newHeader, as: UTF8.self))
        let bodyDiff = try MyersLineDiff.compare(oldBody, newBody)
        let oldTemplate = original?.template ?? Template.parse("")
        let newTemplate = candidate.document.template
        let oldNames = Set(oldTemplate.names), newNames = Set(newTemplate.names)
        let removed = oldTemplate.names.filter { !newNames.contains($0) }
        let added = newTemplate.names.filter { !oldNames.contains($0) }
        let removedSet = Set(removed), addedSet = Set(added)
        let oldLines = placeholderLines(oldBody, template: oldTemplate)
        let newLines = placeholderLines(newBody, template: newTemplate)

        var targets = [String: Set<String>](), sources = [String: Set<String>]()
        var ambiguousRemoved = Set<String>(), ambiguousAdded = Set<String>()
        var start = 0
        while start < bodyDiff.count {
            guard bodyDiff[start].kind != .unchanged else { start += 1; continue }
            var end = start
            var hunkRemoved = Set<String>(), hunkAdded = Set<String>()
            while end < bodyDiff.count, bodyDiff[end].kind != .unchanged {
                let row = bodyDiff[end]
                if let line = row.originalLine { hunkRemoved.formUnion((oldLines[line] ?? []).filter { removedSet.contains($0) }) }
                if let line = row.mergedLine { hunkAdded.formUnion((newLines[line] ?? []).filter { addedSet.contains($0) }) }
                end += 1
            }
            if hunkRemoved.count == 1, hunkAdded.count == 1,
               let from = hunkRemoved.first, let to = hunkAdded.first {
                targets[from, default: []].insert(to)
                sources[to, default: []].insert(from)
            } else {
                ambiguousRemoved.formUnion(hunkRemoved)
                ambiguousAdded.formUnion(hunkAdded)
            }
            start = end
        }
        var removedChanges = [String: PlaceholderChange](), addedChanges = [String: PlaceholderChange]()
        for name in added { addedChanges[name] = .added(name) }
        var renameTargets = Set<String>()
        for name in removed {
            if let candidates = targets[name], candidates.count == 1, let to = candidates.first,
               sources[to]?.count == 1, !ambiguousRemoved.contains(name), !ambiguousAdded.contains(to) {
                let change = PlaceholderChange.renamed(from: name, to: to)
                removedChanges[name] = change
                addedChanges[to] = change
                renameTargets.insert(to)
            } else {
                removedChanges[name] = .removed(name)
            }
        }
        let changes = removed.compactMap { removedChanges[$0] }
            + added.filter { !renameTargets.contains($0) }.compactMap { addedChanges[$0] }

        let marked = bodyDiff.map { row in
            let warnings: [PlaceholderChange]
            switch row.kind {
            case .removed: warnings = (oldLines[row.originalLine!] ?? []).compactMap { removedChanges[$0] }
            case .added: warnings = (newLines[row.mergedLine!] ?? []).compactMap { addedChanges[$0] }
            case .unchanged: warnings = []
            }
            return LineDiffLine(kind: row.kind, bytes: row.bytes, originalLine: row.originalLine,
                                mergedLine: row.mergedLine, placeholderWarnings: warnings)
        }
        return ArtifactDiff(frontMatter: headerDiff, body: marked, placeholderWarnings: changes)
    }

    /// Walk the full parser's tokens so escaped, invalid and multiline literal
    /// constructs never produce false placeholders when individual lines differ.
    private static func placeholderLines(_ body: String, template: Template) -> [Int: [String]] {
        let bytes = Array(body.utf8)
        var result = [Int: [String]]()
        var lineNames = Set<String>()
        var offset = 0, line = 1
        for token in template.tokens {
            switch token {
            case .literal(let text):
                offset += text.utf8.count
                let newlines = text.utf8.filter { $0 == 10 }.count
                line += newlines
                if newlines > 0 { lineNames.removeAll(keepingCapacity: true) }
            case .escapedOpener:
                offset += 3
            case .placeholder(let name):
                if lineNames.insert(name).inserted { result[line, default: []].append(name) }
                offset += 2
                while offset + 1 < bytes.count, !(bytes[offset] == 125 && bytes[offset + 1] == 125) { offset += 1 }
                offset += 2
            }
        }
        return result
    }
}
