import Foundation

enum SyncNamingError: Error, Equatable {
    case invalidPath
    case invalidDate
    case exhausted
}

/// Sync naming never changes the editor/import copy-name convention.
enum SyncNaming {
    static func groupFolder(_ name: String, occupied: [String]) throws -> String {
        let stem = try component(name, fallback: "Group", maxBytes: Limits.syncPathSegmentMaxBytes)
        let keys = try Set(occupied.map { try pathKey(RelativePath($0)) })
        // Shortening can make the bare stem equal a numbered candidate. N+1
        // numbered candidates still guarantee a vacancy among N occupied keys.
        for number in 1...(keys.count + 2) {
            let suffix = number == 1 ? "" : " (\(number))"
            let budget = Limits.syncPathSegmentMaxBytes - suffix.utf8.count
            let shortened = prefix(stem, maxBytes: budget)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            let folder = (shortened.isEmpty ? "Group" : shortened) + suffix
            try SyncIdentifiers.folder(folder)
            if !keys.contains(try pathKey(RelativePath(folder))) { return folder }
        }
        throw SyncNamingError.exhausted
    }

    static func pathKey(_ path: RelativePath) throws -> String {
        guard FileStorePath.isValid(path.string, mode: .relative),
              let nfc = path.string.applyingTransform(StringTransform("Any-NFC"), reverse: false),
              let key = SyncPathCaseFold.fold(nfc).applyingTransform(StringTransform("Any-NFC"), reverse: false) else {
            throw SyncNamingError.invalidPath
        }
        return key
    }

    static func clash(_ path: RelativePath, scope: SyncPathValidator.Scope,
                      occupiedPaths: [RelativePath]) throws -> RelativePath {
        let checked = try SyncPathValidator.validate(path.string, scope: scope)
        let parts = split(RelativePath(checked.path))
        var stem = String(parts.name.dropLast(3))
        var first = 2
        // A retry continues the bounded sequence rather than nesting suffixes.
        for number in 2...Limits.syncPathClashMax {
            let suffix = " (\(number))"
            if stem.hasSuffix(suffix) {
                stem = String(stem.dropLast(suffix.count))
                first = number + 1
                break
            }
        }
        guard first <= Limits.syncPathClashMax else { throw SyncNamingError.exhausted }
        let occupied = try Set(occupiedPaths.map(pathKey))
        for number in first...Limits.syncPathClashMax {
            let candidate = try filename(stem, suffix: " (\(number)).md", parent: parts.parent)
            let checked = try SyncPathValidator.validate(candidate.string, scope: scope)
            if !occupied.contains(checked.pathKey) { return RelativePath(checked.path) }
        }
        throw SyncNamingError.exhausted
    }

    static func conflict(source: RelativePath, groupFolder: String?, device: String, at date: Date,
                         occupiedPaths: [RelativePath]) throws -> RelativePath {
        let group = try component(groupFolder ?? "Personal", fallback: "Personal", maxBytes: Limits.syncPathSegmentMaxBytes)
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: " -_"))
        let deviceText = String(device.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" })
        let device = try component(deviceText, fallback: "Device", maxBytes: Limits.syncConflictDeviceMaxBytes)
        let stamp = try utc(date, format: "yyyy-MM-dd HHmm")
        let parent = "Conflicts/" + group + "/"
        let name = split(source).name
        let stem = try component(name.hasSuffix(".md") ? String(name.dropLast(3)) : name,
                                 fallback: "Prompt", maxBytes: Limits.syncPathSegmentMaxBytes)
        return try available(stem: stem, suffix: " (conflict \(device) \(stamp)).md", parent: parent, occupiedPaths: occupiedPaths)
    }

    static func rescue(source: RelativePath, at date: Date, occupiedPaths: [RelativePath]) throws -> RelativePath {
        try FileStorePath.validate(source.string)
        let parent = "Conflicts/rescued-" + (try utc(date, format: "yyyy-MM-dd")) + "/"
        let hierarchical = parent + source.string
        if let checked = try? SyncPathValidator.validate(hierarchical, scope: .user),
           checked.path.utf8.elementsEqual(hierarchical.utf8), LibraryPath.isPrompt(hierarchical),
           Limits.maxPathBytes - split(RelativePath(hierarchical)).parent.utf8.count > " (20).md".utf8.count {
            return try available(RelativePath(hierarchical), occupiedPaths: occupiedPaths)
        }
        let name = split(source).name
        let stem = try component(name.hasSuffix(".md") ? String(name.dropLast(3)) : name,
                                 fallback: "Prompt", maxBytes: Limits.syncPathSegmentMaxBytes)
        // Distinct long hierarchies remain distinguishable when flattened.
        let suffix = " (" + String(SyncHash(bytes: Data(source.string.utf8)).rawValue.prefix(Limits.syncRescuePathHashLength)) + ").md"
        return try available(stem: stem, suffix: suffix, parent: parent, occupiedPaths: occupiedPaths)
    }

    private static func available(_ path: RelativePath, occupiedPaths: [RelativePath]) throws -> RelativePath {
        let checked = try SyncPathValidator.validate(path.string, scope: .user)
        let occupied = try Set(occupiedPaths.map(pathKey))
        if !occupied.contains(checked.pathKey) { return path }
        return try clash(path, scope: .user, occupiedPaths: occupiedPaths)
    }

    private static func available(stem: String, suffix: String, parent: String,
                                  occupiedPaths: [RelativePath]) throws -> RelativePath {
        let occupied = try Set(occupiedPaths.map(pathKey))
        for number in 1...Limits.syncPathClashMax {
            // Reserve the full timestamp/source suffix even at NAME_MAX.
            let ending = number == 1 ? suffix : String(suffix.dropLast(3)) + " (\(number)).md"
            let candidate = try filename(stem, suffix: ending, parent: parent)
            let checked = try SyncPathValidator.validate(candidate.string, scope: .user)
            if !occupied.contains(checked.pathKey) { return RelativePath(checked.path) }
        }
        throw SyncNamingError.exhausted
    }

    private static func filename(_ stem: String, suffix: String, parent: String) throws -> RelativePath {
        let budget = min(Limits.syncPathSegmentMaxBytes, Limits.maxPathBytes - parent.utf8.count) - suffix.utf8.count
        guard budget > 0 else { throw SyncNamingError.exhausted }
        let truncated = prefix(stem, maxBytes: budget)
        let name = truncated.isEmpty ? prefix("Prompt", maxBytes: budget) : truncated
        return RelativePath(parent + name + suffix)
    }

    private static func component(_ text: String, fallback: String, maxBytes: Int) throws -> String {
        guard let nfc = text.applyingTransform(StringTransform("Any-NFC"), reverse: false) else {
            throw SyncNamingError.invalidPath
        }
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\"))
        let sanitized = String(nfc.unicodeScalars.map { forbidden.contains($0) ? Character("-") : Character(String($0)) })
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        let limited = prefix(sanitized, maxBytes: maxBytes).trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        return limited.isEmpty ? fallback : limited
    }

    /// Character boundaries keep combining sequences and emoji intact.
    private static func prefix(_ text: String, maxBytes: Int) -> String {
        var result = ""
        var count = 0
        for character in text {
            let size = String(character).utf8.count
            if count + size > maxBytes { break }
            result.append(character)
            count += size
        }
        return result
    }

    private static func split(_ path: RelativePath) -> (parent: String, name: String) {
        let bytes = path.string.utf8
        guard let slash = bytes.lastIndex(of: 47) else { return ("", path.string) }
        return (String(decoding: bytes[...slash], as: UTF8.self), String(decoding: bytes[bytes.index(after: slash)...], as: UTF8.self))
    }

    private static func utc(_ date: Date, format: String) throws -> String {
        guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0,
              date.timeIntervalSince1970 < Limits.historyMaxUnixSeconds else { throw SyncNamingError.invalidDate }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
