import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptSearchTests: XCTestCase {
    func testSubsequenceMatrixAndNonMatches() {
        let cases: [(String, String, Bool)] = [
            ("rvw", "Review", true), ("r v", "r x v", true),
            ("abc", "a--b--c", true), ("aa", "banana", true),
            ("aa", "a", false), ("ba", "abc", false), ("z", "abc", false),
            ("abc", "", false), ("", "abc", false)
        ]
        for (term, text, matches) in cases {
            XCTAssertEqual(score(term, text) != nil, matches, "\(term) in \(text)")
        }
    }

    func testWordStartBonusBeatsMidWordAtEqualLength() throws {
        XCTAssertGreaterThan(try XCTUnwrap(score("cd", "ab cd")), try XCTUnwrap(score("cd", "abcdx")))
        XCTAssertGreaterThan(try XCTUnwrap(score("cd", "ab/cd")), try XCTUnwrap(score("cd", "abcdx")))
    }

    func testConsecutiveRunBonusAndBestAlignmentRatherThanFirst() throws {
        XCTAssertGreaterThan(try XCTUnwrap(score("ab", "abxyz")), try XCTUnwrap(score("ab", "axbyz")))
        // The first a in ax ab is a worse start than the later consecutive ab.
        XCTAssertEqual(try XCTUnwrap(score("ab", "ax ab")), 5.0 / 7 * 0.7, accuracy: 1e-12)
    }

    func testOptimalScoresAgainstExhaustiveAlignmentOracle() throws {
        var frontier = [""]
        var texts = frontier
        for _ in 0..<4 {
            frontier = frontier.flatMap { prefix in ["a", "b", " "].map { prefix + $0 } }
            texts += frontier
        }
        for text in texts {
            for term in ["a", "b", "aa", "ab", "ba", "bb", "aaa", "aba", "bab", "bbb"] {
                let alignments = positions(Array(term), in: Array(text))
                guard let raw = alignments.map({ indices -> Int in
                    let starts = indices.filter { $0 == 0 || Array(text)[$0 - 1] == " " }.count
                    let adjacent = zip(indices, indices.dropFirst()).filter { $1 == $0 + 1 }.count
                    return term.count + 2 * starts + adjacent
                }).max() else {
                    XCTAssertNil(score(term, text))
                    continue
                }
                let expected = Double(raw) / Double(4 * term.count - 1)
                    * (1 + Double(term.count) / Double(text.count)) / 2
                XCTAssertEqual(try XCTUnwrap(score(term, text)), expected, accuracy: 1e-12,
                               "\(term) in \(text)")
            }
        }
    }

    // Enumerate every increasing alignment independently of the matcher's DP.
    private func positions(_ term: [Character], in text: [Character], prefix: [Int] = []) -> [[Int]] {
        if prefix.count == term.count { return [prefix] }
        let start = prefix.last.map { $0 + 1 } ?? 0
        guard start < text.count else { return [] }
        return (start..<text.count).filter { text[$0] == term[prefix.count] }.flatMap {
            positions(term, in: text, prefix: prefix + [$0])
        }
    }

    func testFormulaLengthRuleAndScoreBounds() throws {
        XCTAssertEqual(try XCTUnwrap(score("ab", "ab")), 5.0 / 7, accuracy: 1e-12)
        XCTAssertGreaterThan(try XCTUnwrap(score("ab", "ab")), try XCTUnwrap(score("ab", "abxyz")))
        XCTAssertEqual(score("==", "=="), 1, "Punctuation can attain every word-start bonus.")
        for text in ["a", "aaaa", " A a a", "a- a/ ab", "Áb a👋a"] {
            for term in ["a", "aa", "ab"] {
                guard let value = score(term, text) else { continue }
                XCTAssertGreaterThan(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
                XCTAssertEqual(value, score(term, text))
            }
        }
    }

    func testCaseFoldingAndCanonicalNormalizationWithoutAccentRemoval() throws {
        for (lower, upper) in [("review", "REVIEW"), ("Straße", "STRASSE"), ("σ", "Σ"), ("é", "E\u{301}")] {
            XCTAssertEqual(try XCTUnwrap(score(lower, lower)), try XCTUnwrap(score(upper, lower)), accuracy: 1e-12)
        }
        XCTAssertNil(score("e", "é"))
        XCTAssertEqual(FuzzyText("É").scalars.count, 1)
        XCTAssertEqual(FuzzyText("Straße").scalars.count, 7)
    }

    func testFieldWeightOrderingAndMatchedFieldInfo() throws {
        let entries = [entry(title: "n"), entry(tags: ["n"]), entry(path: "n/a.md"),
                       entry(description: "n"), entry(body: "n")]
        let matches = try entries.map { try XCTUnwrap(PromptSearchContent($0).match(PromptSearchQuery("n"))) }
        XCTAssertEqual(matches.map(\.score), [4, 2, 2, 1, 0.5])
        XCTAssertEqual(matches.map(\.fields), [[.title], [.tags], [.folder], [.description], [.body]])
        let equalFields = PromptSearchContent(entry(title: "zzz", tags: ["n"], path: "n/a.md"))
        XCTAssertEqual(equalFields.match(PromptSearchQuery("n"))?.fields, [.tags])
    }

    func testTermsMustAllMatchButMayMatchDifferentFields() throws {
        let content = PromptSearchContent(entry(title: "review", tags: ["code"], body: "python"))
        let review = try XCTUnwrap(content.match(PromptSearchQuery("review")))
        let python = try XCTUnwrap(content.match(PromptSearchQuery("python")))
        let combined = try XCTUnwrap(content.match(PromptSearchQuery("  REVIEW\tpython\n")))
        XCTAssertEqual(combined.score, (review.score + python.score) / 2, accuracy: 1e-12)
        XCTAssertEqual(combined.fields, [.title, .body])
        XCTAssertNil(content.match(PromptSearchQuery("review absent")))
        XCTAssertNil(PromptSearchContent(entry(tags: ["c", "d"])).match(PromptSearchQuery("cd")),
                     "A term may not run across different tags.")
    }

    func testTagFiltersAreExactCaseFoldedAndAllRequired() throws {
        let content = PromptSearchContent(entry(title: "review", tags: ["Code", "Straße", "e\u{301}"], body: "python"))
        XCTAssertEqual(content.match(PromptSearchQuery("#code"))?.score, 1)
        XCTAssertEqual(content.match(PromptSearchQuery("#CODE #strasse #É"))?.fields, [.tags])
        let match = try XCTUnwrap(content.match(PromptSearchQuery("#code REVIEW python")))
        XCTAssertEqual(match.fields, [.title, .tags, .body])
        XCTAssertEqual(match.score, content.match(PromptSearchQuery("REVIEW python"))?.score)
        for query in ["#cod", "#cde", "#", "#code #missing", "#python"] {
            XCTAssertNil(content.match(PromptSearchQuery(query)), query)
        }
        XCTAssertNil(PromptSearchContent(entry(title: "code", body: "code")).match(PromptSearchQuery("#code")))
        XCTAssertTrue(PromptSearchQuery("\t \n").isEmpty)
        XCTAssertFalse(PromptSearchQuery("#code").isEmpty)
    }

    private func score(_ term: String, _ text: String) -> Double? {
        FuzzyMatcher.score(Array(FuzzyText.normalize(term).unicodeScalars), in: FuzzyText(text))
    }

    private func entry(title: String = "zzz", tags: [String] = [], path: String = "a.md",
                       description: String? = nil, body: String = "") -> LibraryEntry {
        let document = PromptDocument(source: body, body: body,
                                      frontMatter: FrontMatter(title: title, description: description, tags: tags),
                                      template: Template.parse(body))
        return LibraryEntry(path: path, document: document, stamp: FileStamp("test"))
    }
}

final class PromptRankingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testExactHalfLifeFormulaAtKnownAndFractionalAges() {
        let ages: [Double] = [0, 7, 14, 28, 140]
        let events = ages.map { now.addingTimeInterval(-$0 * 86_400) }
        let expected = 1 + sqrt(0.5) + 0.5 + 0.25 + 1.0 / 1_024
        XCTAssertEqual(PromptRanking.frecency(events: events, at: now), expected, accuracy: 1e-12)
        XCTAssertEqual(PromptRanking.frecency(events: [], at: now), 0)
        XCTAssertEqual(Limits.frecencyHalfLifeDays, 14)
    }

    func testCapIsExactly32AndFutureUsesCannotContributeMoreThanOne() {
        XCTAssertEqual(PromptRanking.frecency(events: Array(repeating: now, count: 100), at: now), 32)
        XCTAssertEqual(PromptRanking.frecency(events: [now.addingTimeInterval(86_400)], at: now), 1)
        XCTAssertEqual(Limits.frecencyCap, 32)
        XCTAssertEqual(Limits.favoriteBoost, 1.5)
    }
}
