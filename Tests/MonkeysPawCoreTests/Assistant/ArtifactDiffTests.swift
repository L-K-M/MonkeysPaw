import Foundation
import XCTest
@testable import MonkeysPawCore

final class ArtifactDiffTests: XCTestCase {
    private let id = ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PD")!

    func testByteComparisonReconstructsExactHeadersBodiesAndUnicode() throws {
        let old = Data("---\r\n# keep comment\r\ntitle: 'Exact'\r\nx-extra: true\r\n---\r\nCaf\u{e9}\r\n{{old}}".utf8)
        let new = Data("---\ntitle: Exact\nx-extra: true\n---\nCafe\u{301}\n{{new}}\n".utf8)
        let diff = try ArtifactDiff.compare(originalBytes: old, candidateBytes: new)
        XCTAssertEqual(project(diff.frontMatter + diff.body, excluding: .added), old)
        XCTAssertEqual(project(diff.frontMatter + diff.body, excluding: .removed), new)
        XCTAssertTrue(diff.frontMatter.contains { $0.kind == .removed && $0.text.contains("# keep comment") })
        XCTAssertEqual(diff.placeholderWarnings, [.renamed(from: "old", to: "new")])
        XCTAssertThrowsError(try ArtifactDiff.compare(originalBytes: Data([0xff]), candidateBytes: new))
    }

    func testSeparateComparisonsReconstructFinalCanonicalCandidate() throws {
        let initial = try ready(ArtifactMerge.write(artifact("Old {{topic}}\r\n"), id: id))
        let source = initial.document.source.replacingOccurrences(of: "title: Research", with: "# discarded comment\ntitle: Research")
        let original = PromptCodec.parse(source, filename: "Original.md")
        let candidate = try ready(ArtifactMerge.improve(artifact("New {{topic}}\n"), original: original))
        let diff = try ArtifactDiff.compare(original: original, candidate: candidate)
        XCTAssertTrue(diff.frontMatter.allSatisfy { $0.kind == .unchanged })
        XCTAssertEqual(diff.body.map(\.kind), [.removed, .added])
        XCTAssertEqual(project(diff.frontMatter + diff.body, excluding: .added), Data(try PromptCodec.write(original).utf8))
        XCTAssertEqual(project(diff.frontMatter + diff.body, excluding: .removed), candidate.canonicalBytes)
        XCTAssertTrue(diff.placeholderWarnings.isEmpty)
        XCTAssertFalse(candidate.document.source.contains("Exact LLM notes"))
    }

    func testWriteDiffUsesEmptyBaselineAndContainsPreflightedID() throws {
        let candidate = try ready(ArtifactMerge.write(artifact("Use {{input}}\n"), id: id))
        let diff = try ArtifactDiff.compare(original: nil, candidate: candidate)
        XCTAssertTrue(diff.frontMatter.allSatisfy { $0.kind == .added })
        XCTAssertTrue(diff.body.allSatisfy { $0.kind == .added })
        XCTAssertEqual(project(diff.frontMatter + diff.body, excluding: .removed), candidate.canonicalBytes)
        XCTAssertTrue(diff.frontMatter.contains { $0.text == "id: \(id.rawValue)\n" })
        XCTAssertEqual(diff.placeholderWarnings, [.added("input")])
        XCTAssertEqual(diff.body[0].placeholderWarnings, [.added("input")])
        XCTAssertTrue(diff.frontMatter.allSatisfy { $0.placeholderWarnings.isEmpty })
    }

    func testAddedRemovedAndPossibleRenameMarkers() throws {
        let changed = try diff("Keep {{stable}}\nRemove {{gone}}\nAnchor\n", "Keep {{stable}}\nAnchor\nAdd {{new}}\n")
        XCTAssertEqual(changed.placeholderWarnings, [.removed("gone"), .added("new")])
        XCTAssertEqual(changed.body.filter { !$0.placeholderWarnings.isEmpty }.map(\.placeholderWarnings),
                       [[.removed("gone")], [.added("new")]])
        let renamed = try diff("Use {{topic}} and {{ topic }}\r\n", "Use {{subject}} and {{ subject }}\r\n")
        XCTAssertEqual(renamed.placeholderWarnings, [.renamed(from: "topic", to: "subject")])
        XCTAssertEqual(renamed.body.map(\.placeholderWarnings),
                       [[.renamed(from: "topic", to: "subject")], [.renamed(from: "topic", to: "subject")]])
        XCTAssertEqual(try diff("{{topic}}", "{{Topic}}").placeholderWarnings, [.renamed(from: "topic", to: "Topic")])
    }

    func testRetainedAndReusedNamesDoNotWarnAndFirstUseOrderIsStable() throws {
        XCTAssertTrue(try diff("{{same}}\n{{same}}\n", "{{same}}\n").placeholderWarnings.isEmpty)
        XCTAssertTrue(try diff("{{same}}\n", "{{same}}\n{{same}}\n").placeholderWarnings.isEmpty)
        let changed = try diff("{{z}} {{a}} {{z}}\n", "{{y}} {{b}} {{y}}\n")
        XCTAssertEqual(changed.placeholderWarnings, [.removed("z"), .removed("a"), .added("y"), .added("b")])
        XCTAssertEqual(changed.body[0].placeholderWarnings, [.removed("z"), .removed("a")])
        XCTAssertEqual(changed.body[1].placeholderWarnings, [.added("y"), .added("b")])
    }

    func testAmbiguousRenamePairsAcrossHunksRemainAddAndRemoveWarnings() throws {
        let oneToMany = try diff("{{old}}\nanchor\n{{old}}\n", "{{new1}}\nanchor\n{{new2}}\n")
        XCTAssertEqual(oneToMany.placeholderWarnings, [.removed("old"), .added("new1"), .added("new2")])
        let manyToOne = try diff("{{old1}}\nanchor\n{{old2}}\n", "{{new}}\nanchor\n{{new}}\n")
        XCTAssertEqual(manyToOne.placeholderWarnings, [.removed("old1"), .removed("old2"), .added("new")])
        let unpairedUse = try diff("{{old}}\nanchor\n{{old}}\n", "{{new}}\nanchor\n")
        XCTAssertEqual(unpairedUse.placeholderWarnings, [.removed("old"), .added("new")])
    }

    func testGrammarExcludesEscapesAndInvalidMultilineLiteralConstructs() throws {
        let literal = try diff("\\{{fake}} {{ a b }}\n", "\\{{other}} {{#if x}}\n{{_value2}} {{date}}\n")
        XCTAssertEqual(literal.placeholderWarnings, [.added("_value2"), .added("date")])
        let multiline = try diff("{{ invalid\n {{real}}}}\nActual {{gone}}\n", "{{ invalid\n {{phantom}}}}\nActual {{next}}\n")
        XCTAssertEqual(multiline.placeholderWarnings, [.renamed(from: "gone", to: "next")])
        for row in multiline.body where row.text.contains("real") || row.text.contains("phantom") {
            XCTAssertTrue(row.placeholderWarnings.isEmpty)
        }
    }

    func testMergeAndDiffDeterminism() throws {
        let original = PromptCodec.parse("---\nfavorite: true\nmodel: {nested: [1, false]}\n---\n{{old}}\n", filename: "Original.md")
        let output = try artifact("{{new}}\n")
        let candidate = try ready(ArtifactMerge.improve(output, original: original))
        let expected = try ArtifactDiff.compare(original: original, candidate: candidate)
        for _ in 0..<10 {
            let repeated = try ready(ArtifactMerge.improve(output, original: original))
            XCTAssertEqual(repeated.canonicalBytes, candidate.canonicalBytes)
            XCTAssertEqual(try ArtifactDiff.compare(original: original, candidate: repeated), expected)
        }
    }

    private func diff(_ old: String, _ new: String) throws -> ArtifactDiff {
        let original = PromptCodec.parse(old, filename: "Original.md")
        return try ArtifactDiff.compare(original: original,
            candidate: ready(ArtifactMerge.improve(artifact(new), original: original)))
    }

    private func artifact(_ body: String) throws -> LlmArtifact {
        var root = AssistantOutputFixtures.artifact
        root["fields"] = []
        root["body"] = body
        root["notes"] = "Exact LLM notes"
        return try LlmOutputDecoder.artifact(from: AssistantOutputFixtures.json(root))
    }

    private func ready(_ result: ArtifactMergeResult) throws -> ArtifactMergeCandidate {
        guard case .ready(let candidate) = result else { XCTFail("Expected validated candidate"); throw PromptWriteError.invalidPrompt }
        return candidate
    }

    private func project(_ rows: [LineDiffLine], excluding kind: LineDiffLine.Kind) -> Data {
        rows.filter { $0.kind != kind }.reduce(into: Data()) { $0.append($1.bytes) }
    }
}
