import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptFolderGroupingTests: XCTestCase {
    private struct Row: Equatable {
        let name: String
        let folder: String
        var access = PromptAccessState.local
    }

    private let team = GroupAccessGroup(id: ULID("01JABCDEFGHJKMNPQRSTVWXYZ0")!, name: "team", folder: "Team", role: .editor)
    private let otherTeam = GroupAccessGroup(id: ULID("01JABCDEFGHJKMNPQRSTVWXYZ1")!, name: "team", folder: "Other", role: .viewer)

    func testFlatAndEmptyListsHaveNoHeadingsAndKeepOrder() {
        let flat = [Row(name: "b", folder: ""), Row(name: "a", folder: "")]
        for order in [PromptFolderGrouping.HeadingOrder.firstAppearance, .sidebar] {
            let grouped = group(flat, order)
            XCTAssertEqual(grouped.rows, flat)
            XCTAssertEqual(grouped.groups, [])
            XCTAssertEqual(group([], order).groups, [])
        }
    }

    func testSingleFolderShowsItsHeading() {
        let grouped = group([Row(name: "a", folder: "work"), Row(name: "b", folder: "work")], .sidebar)
        XCTAssertEqual(grouped.groups, [PromptFolderGroup(key: .folder("work"), title: "work", rows: 0..<2)])
    }

    func testFirstAppearanceKeepsBestMatchFirstAndRankInsideHeadings() {
        let ranked = [Row(name: "1", folder: "work"), Row(name: "2", folder: ""),
                      Row(name: "3", folder: "Groups/Team", access: .group(team)), Row(name: "4", folder: "work"),
                      Row(name: "5", folder: ""), Row(name: "6", folder: "Groups/Team/reviews", access: .group(team))]
        let grouped = group(ranked, .firstAppearance)
        XCTAssertEqual(grouped.rows.map(\.name), ["1", "4", "2", "5", "3", "6"])
        XCTAssertEqual(grouped.groups.map(\.title), ["work", "Top level", "team", "team/reviews"])
        XCTAssertEqual(grouped.groups.map(\.rows), [0..<2, 2..<4, 4..<5, 5..<6])
        XCTAssertEqual(grouped.groups[2].key, .group(team.id, subfolder: ""))
        XCTAssertEqual(grouped.groups[3].key, .group(team.id, subfolder: "reviews"))
    }

    func testSidebarOrderPutsTopLevelThenGroupsThenFolderTree() {
        let rows = [Row(name: "spaced", folder: "a b"), Row(name: "child", folder: "a/b"),
                    Row(name: "parent", folder: "a"), Row(name: "other", folder: "Groups/Other", access: .group(otherTeam)),
                    Row(name: "nested", folder: "Groups/Team/x", access: .group(team)),
                    Row(name: "team", folder: "Groups/Team", access: .group(team)),
                    Row(name: "lost", folder: "Groups/Gone", access: .unavailable), Row(name: "root", folder: "")]
        let grouped = group(rows, .sidebar)
        XCTAssertEqual(grouped.rows.map(\.name), ["root", "team", "nested", "other", "lost", "parent", "child", "spaced"])
        XCTAssertEqual(grouped.groups.map(\.title),
                       ["Top level", "team", "team/x", "team", "Groups/Gone", "a", "a/b", "a b"],
                       "Same-named groups stay separate and sort by ID; folders sort as a tree, parents first")
    }

    func testByteDistinctFoldersStaySeparateAndGroupPathsOutsideTheGroupUseTheirFolder() {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        let rows = [Row(name: "a", folder: composed), Row(name: "b", folder: decomposed),
                    Row(name: "c", folder: "Groups/Teammates", access: .group(team))]
        let grouped = group(rows, .firstAppearance)
        XCTAssertEqual(grouped.groups.map(\.key), [.folder(RelativePath(composed)), .folder(RelativePath(decomposed)),
                                                   .folder("Groups/Teammates")])
        XCTAssertFalse(grouped.groups[0] == grouped.groups[1])
    }

    private func group(_ rows: [Row], _ order: PromptFolderGrouping.HeadingOrder) -> (rows: [Row], groups: [PromptFolderGroup]) {
        PromptFolderGrouping.group(rows, order: order) { PromptFolderGrouping.placement(folder: $0.folder, access: $0.access) }
    }
}
