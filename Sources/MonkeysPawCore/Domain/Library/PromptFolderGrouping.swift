import Foundation

/// The heading a prompt sits under in a grouped list (§11.8). Private prompts,
/// and prompts under `Groups/` without group access, use their exact folder
/// bytes, empty at the top level. Group prompts use the group ID and their
/// folder inside the group, so headings show the committed group name.
public enum PromptFolderKey: Hashable, Sendable {
    case folder(RelativePath)
    case group(ULID, subfolder: RelativePath)
}

/// One folder heading and the adjacent rows below it in a flat row array.
public struct PromptFolderGroup: Equatable, Sendable {
    public let key: PromptFolderKey
    /// "Top level", the folder path, or the group name and its subfolder.
    public let title: String
    /// Positions of this heading's rows in the list's flat row array.
    public let rows: Range<Int>

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.title.utf8.elementsEqual(rhs.title.utf8) && lhs.rows == rhs.rows
    }
}

/// Groups list rows under folder headings without changing their order inside
/// a heading. A list whose rows are all top-level gets no headings (§11.8).
enum PromptFolderGrouping {
    enum HeadingOrder {
        /// Ranked lists: each heading follows its best-ranked row, so the best
        /// match stays first.
        case firstAppearance
        /// Title-ordered Library lists, like the sidebar: Top level, groups by
        /// name and ID, then folders as a tree with parents first.
        case sidebar
    }

    static let topLevelTitle = "Top level"

    struct Placement {
        let key: PromptFolderKey
        let title: String
        fileprivate let rank: Rank
    }

    fileprivate enum Rank {
        case topLevel
        case group(name: String, id: ULID, subfolder: [RelativePath])
        case folder([RelativePath])
    }

    static func placement(folder: String, access: PromptAccessState) -> Placement {
        if case .group(let group) = access, let subfolder = subfolder(of: folder, in: group) {
            let title = subfolder.isEmpty ? group.name : group.name + "/" + subfolder
            return Placement(key: .group(group.id, subfolder: RelativePath(subfolder)), title: title,
                rank: .group(name: group.name, id: group.id, subfolder: components(subfolder)))
        }
        guard !folder.isEmpty else {
            return Placement(key: .folder(RelativePath("")), title: topLevelTitle, rank: .topLevel)
        }
        return Placement(key: .folder(RelativePath(folder)), title: folder, rank: .folder(components(folder)))
    }

    /// Returns the rows reordered so each heading's rows are adjacent, and the
    /// headings as ranges over that array.
    static func group<Row>(_ rows: [Row], order: HeadingOrder,
                           placement: (Row) -> Placement) -> (rows: [Row], groups: [PromptFolderGroup]) {
        var headings: [Placement] = []
        var buckets: [[Row]] = []
        var positions: [PromptFolderKey: Int] = [:]
        for row in rows {
            let place = placement(row)
            if let position = positions[place.key] {
                buckets[position].append(row)
                continue
            }
            positions[place.key] = headings.count
            headings.append(place)
            buckets.append([row])
        }

        // A flat library keeps its unheaded look.
        guard !headings.allSatisfy({ isTopLevel($0.key) }) else { return (rows, []) }

        var sequence = Array(headings.indices)
        if order == .sidebar { sequence.sort { precedes(headings[$0].rank, headings[$1].rank) } }
        var grouped: [Row] = []
        grouped.reserveCapacity(rows.count)
        var groups: [PromptFolderGroup] = []
        for position in sequence {
            let start = grouped.count
            grouped.append(contentsOf: buckets[position])
            groups.append(PromptFolderGroup(key: headings[position].key, title: headings[position].title,
                rows: start..<grouped.count))
        }
        return (grouped, groups)
    }

    private static func isTopLevel(_ key: PromptFolderKey) -> Bool {
        if case .folder(let path) = key { return path.string.isEmpty }
        return false
    }

    /// The folder inside `Groups/<group folder>`, compared by bytes. Nil when
    /// the path is outside the group's folder.
    private static func subfolder(of folder: String, in group: GroupAccessGroup) -> String? {
        let root = Array(("Groups/" + group.folder.string).utf8)
        let bytes = Array(folder.utf8)
        guard bytes.starts(with: root) else { return nil }
        if bytes.count == root.count { return "" }
        guard bytes[root.count] == UInt8(ascii: "/") else { return nil }
        return String(decoding: bytes[(root.count + 1)...], as: UTF8.self)
    }

    /// Slash boundaries by scalar, like folder sections, so a component that
    /// starts with a combining mark keeps its boundary.
    private static func components(_ path: String) -> [RelativePath] {
        path.unicodeScalars.split(separator: "/").map { RelativePath(String($0)) }
    }

    private static func precedes(_ lhs: Rank, _ rhs: Rank) -> Bool {
        switch (lhs, rhs) {
        case (.topLevel, .topLevel): return false
        case (.topLevel, _): return true
        case (_, .topLevel): return false
        case (.group(let leftName, let leftID, let leftSub), .group(let rightName, let rightID, let rightSub)):
            if !leftName.utf8.elementsEqual(rightName.utf8) { return leftName.utf8.lexicographicallyPrecedes(rightName.utf8) }
            if leftID != rightID { return leftID.rawValue < rightID.rawValue }
            return leftSub.lexicographicallyPrecedes(rightSub)
        case (.group, .folder): return true
        case (.folder, .group): return false
        case (.folder(let left), .folder(let right)): return left.lexicographicallyPrecedes(right)
        }
    }
}
