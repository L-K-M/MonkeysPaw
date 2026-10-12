import Foundation

public struct LineDiffLine: Equatable, Sendable {
    public enum Kind: String, Sendable { case unchanged, removed, added }

    public let kind: Kind
    /// Exact UTF-8, including LF/CRLF and whether the final line is terminated.
    public let bytes: Data
    public var text: String { String(decoding: bytes, as: UTF8.self) }
    /// One-based line numbers within the compared section, nil on an absent side.
    public let originalLine: Int?
    public let mergedLine: Int?
    public let placeholderWarnings: [PlaceholderChange]

    init(kind: Kind, bytes: Data, originalLine: Int?, mergedLine: Int?,
         placeholderWarnings: [PlaceholderChange] = []) {
        self.kind = kind
        self.bytes = bytes
        self.originalLine = originalLine
        self.mergedLine = mergedLine
        self.placeholderWarnings = placeholderWarnings
    }
}

public enum LineDiffError: Error, Equatable, Sendable {
    case sourceTooLarge
    case comparisonTooComplex
}

/// Myers' shortest edit script, preferring deletion when frontiers tie.
/// Data equality avoids Swift String's canonical Unicode equivalence.
public enum MyersLineDiff {
    public static func compare(_ original: String, _ merged: String) throws -> [LineDiffLine] {
        guard original.utf8.count <= Limits.maxPromptBytes, merged.utf8.count <= Limits.maxPromptBytes else {
            throw LineDiffError.sourceTooLarge
        }
        let old = lines(original), new = lines(merged)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }

        var result = (0..<prefix).map {
            LineDiffLine(kind: .unchanged, bytes: old[$0], originalLine: $0 + 1, mergedLine: $0 + 1)
        }
        let oldEnd = old.count - suffix, newEnd = new.count - suffix
        if prefix == oldEnd {
            result += (prefix..<newEnd).map {
                LineDiffLine(kind: .added, bytes: new[$0], originalLine: nil, mergedLine: $0 + 1)
            }
        } else if prefix == newEnd {
            result += (prefix..<oldEnd).map {
                LineDiffLine(kind: .removed, bytes: old[$0], originalLine: $0 + 1, mergedLine: nil)
            }
        } else {
            result += try edits(Array(old[prefix..<oldEnd]), Array(new[prefix..<newEnd]), offset: prefix)
        }
        result += (0..<suffix).map {
            LineDiffLine(kind: .unchanged, bytes: old[oldEnd + $0],
                         originalLine: oldEnd + $0 + 1, mergedLine: newEnd + $0 + 1)
        }
        return result
    }

    private static func lines(_ source: String) -> [Data] {
        let bytes = Array(source.utf8)
        var result = [Data]()
        var start = 0
        for index in bytes.indices where bytes[index] == 10 {
            result.append(Data(bytes[start...index]))
            start = index + 1
        }
        if start < bytes.count { result.append(Data(bytes[start...])) }
        return result
    }

    private static func edits(_ old: [Data], _ new: [Data], offset: Int) throws -> [LineDiffLine] {
        var trace = [[Int]]()
        var work = 0
        for distance in 0...(old.count + new.count) {
            // The existing byte cap also bounds frontier storage and search work.
            guard distance + 1 <= Limits.maxPromptBytes - work else { throw LineDiffError.comparisonTooComplex }
            work += distance + 1
            var frontier = [Int](repeating: 0, count: distance + 1)
            for index in 0...distance {
                let diagonal = 2 * index - distance
                var x = 0
                if distance > 0 {
                    let previous = trace[distance - 1]
                    if index == 0 || (index != distance && previous[index - 1] < previous[index]) {
                        x = previous[index]
                    } else {
                        x = previous[index - 1] + 1
                    }
                }
                var y = x - diagonal
                while x < old.count, y < new.count, old[x] == new[y] {
                    guard work < Limits.maxPromptBytes else { throw LineDiffError.comparisonTooComplex }
                    work += 1
                    x += 1
                    y += 1
                }
                frontier[index] = x
                if x >= old.count, y >= new.count {
                    trace.append(frontier)
                    return backtrack(trace, old: old, new: new, offset: offset)
                }
            }
            trace.append(frontier)
        }
        throw LineDiffError.comparisonTooComplex
    }

    private static func backtrack(_ trace: [[Int]], old: [Data], new: [Data], offset: Int) -> [LineDiffLine] {
        var x = old.count, y = new.count
        var result = [LineDiffLine]()
        for distance in stride(from: trace.count - 1, through: 1, by: -1) {
            let index = (x - y + distance) / 2
            let previous = trace[distance - 1]
            let insertion = index == 0 || (index != distance && previous[index - 1] < previous[index])
            let previousX = previous[insertion ? index : index - 1]
            let previousY = previousX - (x - y + (insertion ? 1 : -1))
            while x > previousX, y > previousY {
                result.append(LineDiffLine(kind: .unchanged, bytes: old[x - 1],
                                           originalLine: offset + x, mergedLine: offset + y))
                x -= 1
                y -= 1
            }
            if insertion {
                result.append(LineDiffLine(kind: .added, bytes: new[y - 1], originalLine: nil, mergedLine: offset + y))
                y -= 1
            } else {
                result.append(LineDiffLine(kind: .removed, bytes: old[x - 1], originalLine: offset + x, mergedLine: nil))
                x -= 1
            }
        }
        while x > 0, y > 0 {
            result.append(LineDiffLine(kind: .unchanged, bytes: old[x - 1], originalLine: offset + x, mergedLine: offset + y))
            x -= 1
            y -= 1
        }
        return result.reversed()
    }
}
