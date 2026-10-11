import Foundation

public enum PromptSearchField: CaseIterable, Hashable, Sendable {
    case title, tags, folder, description, body

    /// §5.4: title > tags/folder > description > body.
    fileprivate var weight: Double {
        switch self {
        case .title: return 4
        case .tags, .folder: return 2
        case .description: return 1
        case .body: return 0.5
        }
    }
}

public struct PromptSearchResult {
    /// Retains issues and read-only state, including invalid library entries.
    public let entry: LibraryEntry
    public var relativePath: String { entry.relativePath }
    public var identity: PromptIdentity { entry.identity }
    public let score: Double
    /// Best field per ordinary term, plus tags for # filters, in enum order.
    public let matchedFields: [PromptSearchField]
}

/// Normalization for both fields and terms: locale-fixed Unicode case folding,
/// then NFC. Match lengths and positions count normalized Unicode scalars;
/// accents remain significant. Cache field normalization during indexing.
struct FuzzyText {
    let scalars: [Unicode.Scalar]
    let wordStarts: [Bool]

    init(_ text: String) {
        let normalized = Array(Self.normalize(text).unicodeScalars)
        scalars = normalized
        wordStarts = normalized.indices.map {
            $0 == 0 || !CharacterSet.alphanumerics.contains(normalized[$0 - 1])
        }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}

/// §5.4: subsequence matching, maximizing m + 2W + C over alignments:
/// m = term length, W = matches at position zero or after a non-alphanumeric,
/// C = adjacent matched pairs. Divide by the upper bound 4m - 1, then multiply
/// by (1 + m/n)/2, where n is field length. Scores are in (0, 1], favor shorter
/// fields, and use no locale-sensitive comparison or undocumented heuristics.
/// Dynamic programming takes O(mn) time and O(n) space; a greedy alignment
/// would miss better word starts or consecutive runs later in a field.
enum FuzzyMatcher {
    static func score(_ term: [Unicode.Scalar], in text: FuzzyText) -> Double? {
        let m = term.count
        let n = text.scalars.count
        guard m > 0, m <= n else { return nil }

        var previous = [Int](repeating: -1, count: n)
        var current = previous
        for (termIndex, scalar) in term.enumerated() {
            var bestEarlier = -1
            var found = false
            for position in 0..<n {
                if position > 0 { bestEarlier = max(bestEarlier, previous[position - 1]) }
                current[position] = -1
                guard text.scalars[position] == scalar else { continue }
                let bonus = 1 + (text.wordStarts[position] ? 2 : 0)
                if termIndex == 0 {
                    current[position] = bonus
                } else if bestEarlier >= 0 {
                    let consecutive = position > 0 && previous[position - 1] >= 0
                        ? previous[position - 1] + 1 : -1
                    current[position] = max(bestEarlier, consecutive) + bonus
                }
                found = found || current[position] >= 0
            }
            guard found else { return nil }
            swap(&previous, &current)
        }
        let raw = previous.max()!
        return Double(raw) / (4 * Double(m) - 1) * (1 + Double(m) / Double(n)) / 2
    }
}

struct PromptSearchQuery {
    let terms: [[Unicode.Scalar]]
    let tags: [String]
    let isEmpty: Bool

    init(_ query: String) {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        terms = tokens.filter { !$0.hasPrefix("#") }.map { Array(FuzzyText.normalize($0).unicodeScalars) }
        tags = tokens.filter { $0.hasPrefix("#") }.map { FuzzyText.normalize(String($0.dropFirst())) }
        isEmpty = tokens.isEmpty
    }
}

struct PromptMatch {
    let score: Double
    let fields: [PromptSearchField]
}

struct PromptSearchContent {
    private let fields: [(PromptSearchField, FuzzyText)]
    private let tags: Set<String>

    init(_ entry: LibraryEntry) {
        let front = entry.document.frontMatter
        fields = [(.title, FuzzyText(front.title))]
            + front.tags.map { (.tags, FuzzyText($0)) }
            + [(.folder, FuzzyText(entry.folder)),
               (.description, FuzzyText(front.description ?? "")),
               (.body, FuzzyText(entry.document.body))]
        tags = Set(front.tags.map(FuzzyText.normalize))
    }

    /// All whitespace-separated terms must match, possibly in different fields.
    /// Each term takes its best weighted field; average those scores so term
    /// count does not inflate match. #tag is exact after normalization, never
    /// fuzzy; a bare # matches nothing. Filters add no numeric bonus. A query
    /// containing only matching filters has base match 1, like an empty query.
    func match(_ query: PromptSearchQuery) -> PromptMatch? {
        guard query.tags.allSatisfy({ !$0.isEmpty && tags.contains($0) }) else { return nil }
        var matched = Set<PromptSearchField>()
        if !query.tags.isEmpty { matched.insert(.tags) }
        var total: Double = 0
        for term in query.terms {
            var best: (field: PromptSearchField, score: Double)?
            for (field, text) in fields {
                guard let score = FuzzyMatcher.score(term, in: text) else { continue }
                let weighted = score * field.weight
                if best == nil || weighted > best!.score { best = (field, weighted) }
            }
            guard let best else { return nil }
            total += best.score
            matched.insert(best.field)
        }
        return PromptMatch(score: query.terms.isEmpty ? 1 : total / Double(query.terms.count),
                           fields: PromptSearchField.allCases.filter(matched.contains))
    }
}

enum PromptRanking {
    private static let secondsPerDay: Double = 86_400

    /// §5.4: sum 2^(-age_days/14), capped at 32. Days are elapsed 24-hour
    /// periods, independent of calendars/DST. Future uses have age zero so a
    /// backwards wall-clock adjustment cannot give one event more than 1.
    static func frecency(events: [Date], at now: Date) -> Double {
        min(Limits.frecencyCap, events.reduce(0) { sum, date in
            let ageDays = max(0, now.timeIntervalSince(date) / secondsPerDay)
            return sum + exp2(-ageDays / Limits.frecencyHalfLifeDays)
        })
    }
}
