/// §5.4: search owns its transform; only the frozen Unicode 17 C/F data is
/// shared with sync. Never consult Foundation's platform-specific tables.
enum SearchNormalizer {
    static func normalize(_ text: String) -> String {
        // ASCII has only the A–Z fold and is already NFC.
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            let folded = text.utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
            return String(decoding: folded, as: UTF8.self)
        }

        var folded = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if let replacement = SyncPathCaseFold.exceptions[scalar.value] {
                folded.append(contentsOf: replacement.unicodeScalars)
            } else if let range = SyncPathCaseFold.ranges.first(where: {
                $0.first <= scalar.value && scalar.value <= $0.last
                    && (scalar.value - $0.first) % $0.step == 0
            }) {
                folded.append(Unicode.Scalar(UInt32(Int64(scalar.value) + range.delta))!)
            } else {
                folded.append(scalar)
            }
        }
        return SearchNFC.normalize(String(folded))
    }

    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if !scalar.isASCII {
            // Apple assigns extra categories to some private-use scalars.
            if (0xE000...0xF8FF).contains(scalar.value)
                || (0xF0000...0xFFFFD).contains(scalar.value)
                || (0x100000...0x10FFFD).contains(scalar.value) { return false }
            if SearchUnicodeData.wordAdditions.contains(where: { $0.contains(scalar.value) }) { return true }
            guard let age = scalar.properties.age,
                  age.major < 17 || (age.major == 17 && age.minor == 0) else { return false }
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    static func tokens(_ query: String) -> [String] {
        let scalars = query.unicodeScalars
        var tokens = [String]()
        var tokenStart = scalars.startIndex
        var start = tokenStart
        for grapheme in boundaryText(query) {
            let end = scalars.index(start, offsetBy: grapheme.unicodeScalars.count)
            if scalars[start].properties.isWhitespace {
                if start > tokenStart { tokens.append(String(scalars[tokenStart..<start])) }
                tokenStart = end
            }
            start = end
        }
        if tokenStart < scalars.endIndex { tokens.append(String(scalars[tokenStart...])) }
        return tokens
    }

    static func isTag(_ token: String) -> Bool {
        token.unicodeScalars.first == "#" && boundaryText(token).first?.unicodeScalars.count == 1
    }

    private static func boundaryText(_ text: String) -> String {
        // Supported macOS Swift runtimes have Unicode 15/16 graphemes. Project
        // the changed space/# boundary classes only in the segmentation probe,
        // retaining one scalar per input scalar and all original token bytes.
        var probe = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if let addition = SearchUnicodeData.graphemeAdditions.first(where: { $0.range.contains(scalar.value) }) {
                probe.append(Unicode.Scalar(addition.representative)!)
            } else if let age = scalar.properties.age, age.major > 17 || (age.major == 17 && age.minor > 0) {
                probe.append("\u{FFFD}")
            } else {
                probe.append(scalar)
            }
        }
        return String(probe)
    }
}

/// Unicode 17 UAX #15 NFC: canonical decomposition, stable ordering and
/// unblocked composition. Frozen data also covers scalars unknown to host ICU.
enum SearchNFC {
    static func normalize(_ text: String) -> String {
        var decomposed = [UInt32]()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0xAC00...0xD7A3).contains(value) {
                let index = value - 0xAC00
                decomposed += [0x1100 + index / 588, 0x1161 + index % 588 / 28]
                if index % 28 != 0 { decomposed.append(0x11A7 + index % 28) }
            } else {
                decomposed.append(contentsOf: SearchUnicodeData.decompositions[value] ?? [value])
            }
        }

        var ordered = decomposed.map { (scalar: $0, ccc: combiningClass($0)) }
        var start = 0
        while start < ordered.count {
            if ordered[start].ccc == 0 { start += 1 }
            var end = start
            while end < ordered.count && ordered[end].ccc != 0 { end += 1 }
            if end - start > 1 {
                // The offset makes ordering stable even when sort isn't.
                let sorted = ordered[start..<end].enumerated().sorted {
                    $0.element.ccc == $1.element.ccc ? $0.offset < $1.offset : $0.element.ccc < $1.element.ccc
                }.map(\.element)
                ordered.replaceSubrange(start..<end, with: sorted)
            }
            start = end
        }

        var result = [UInt32]()
        var starter: Int?
        var lastClass: UInt8 = 0
        for (scalar, ccc) in ordered {
            if let index = starter, (lastClass == 0 || lastClass < ccc),
               let composed = compose(result[index], scalar) {
                result[index] = composed
            } else {
                if ccc == 0 { starter = result.count }
                result.append(scalar)
                lastClass = ccc
            }
        }
        return String(String.UnicodeScalarView(result.map { Unicode.Scalar($0)! }))
    }

    private static func combiningClass(_ scalar: UInt32) -> UInt8 {
        let ranges = SearchUnicodeData.combiningClasses
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if scalar < ranges[middle].first { high = middle }
            else if scalar > ranges[middle].last { low = middle + 1 }
            else { return ranges[middle].value }
        }
        return 0
    }

    private static func compose(_ base: UInt32, _ next: UInt32) -> UInt32? {
        if (0x1100...0x1112).contains(base), (0x1161...0x1175).contains(next) {
            return 0xAC00 + ((base - 0x1100) * 21 + next - 0x1161) * 28
        }
        if (0xAC00...0xD7A3).contains(base), (base - 0xAC00) % 28 == 0,
           (0x11A8...0x11C2).contains(next) { return base + next - 0x11A7 }
        return SearchUnicodeData.compositions[UInt64(base) << 21 | UInt64(next)]
    }
}
