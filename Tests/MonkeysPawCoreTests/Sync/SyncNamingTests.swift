import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncNamingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_792_008_245)

    func testClashesUseFullFoldAndContinueThroughTwenty() throws {
        let occupied: [RelativePath] = ["STRASSE (2).md", "Straße (3).md"]
        XCTAssertEqual(try SyncNaming.clash("Straße.md", scope: .user, occupiedPaths: occupied), "Straße (4).md")
        XCTAssertEqual(try SyncNaming.clash("Straße (3).md", scope: .user, occupiedPaths: occupied), "Straße (4).md")
        XCTAssertEqual(try SyncNaming.pathKey("CAFÉ.md"), try SyncNaming.pathKey("Cafe\u{301}.md"))
        let all = (2...20).map { RelativePath("Name (\($0)).md") }
        XCTAssertThrowsError(try SyncNaming.clash("Name.md", scope: .user, occupiedPaths: all)) {
            XCTAssertEqual($0 as? SyncNamingError, .exhausted)
        }
        XCTAssertThrowsError(try SyncNaming.clash("Name (20).md", scope: .user, occupiedPaths: []))
    }

    func testConflictNamesUseSanitizedDeviceAndUTCWithUniqueMinuteCollisions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 21, minute: 7))!
        let first = try SyncNaming.conflict(source: "Groups/Team/Hello!.md", groupFolder: "Team (2)",
            device: "../Mac/Phone\n", at: date, occupiedPaths: [])
        XCTAssertEqual(first.string, "Conflicts/Team (2)/Hello! (conflict Mac-Phone 2026-10-13 2107).md")
        let second = try SyncNaming.conflict(source: "Hello!.md", groupFolder: "Team (2)", device: "../Mac/Phone\n",
            at: date.addingTimeInterval(10), occupiedPaths: [RelativePath(first.string.uppercased())])
        XCTAssertEqual(second.string, String(first.string.dropLast(3)) + " (2).md")
        let personal = try SyncNaming.conflict(source: "a.md", groupFolder: nil, device: "///", at: date, occupiedPaths: [])
        XCTAssertTrue(personal.string.hasPrefix("Conflicts/Personal/a (conflict Device "))
    }

    func testFilenameTruncationPreservesWholeGraphemesAndWireCaps() throws {
        let stem = String(repeating: "👩🏽é", count: 20)
        let path = try SyncNaming.conflict(source: RelativePath(stem + ".md"), groupFolder: String(repeating: "界", count: 85),
            device: String(repeating: "界", count: 50), at: date, occupiedPaths: [])
        let checked = try SyncPathValidator.validate(path.string, scope: .user)
        XCTAssertLessThanOrEqual(checked.path.utf8.count, Limits.maxPathBytes)
        let name = LibraryPath.filename(path.string)
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        XCTAssertTrue(stem.hasPrefix(String(name.components(separatedBy: " (conflict ")[0])))
        let parent = String(repeating: "a", count: 255) + "/" + String(repeating: "b", count: 255) + "/" + String(repeating: "c", count: 255) + "/"
        let nearCap = RelativePath(parent + String(repeating: "é", count: 126) + ".md")
        let clash = try SyncNaming.clash(nearCap, scope: .group, occupiedPaths: [])
        XCTAssertLessThanOrEqual(clash.string.utf8.count, 1024)
        XCTAssertLessThanOrEqual(LibraryPath.filename(clash.string).utf8.count, 255)
        XCTAssertTrue(LibraryPath.filename(clash.string).hasSuffix(" (2).md"))
    }

    func testLongCollisionNamesKeepCompleteTimestampAndFlattenedSourceSuffix() throws {
        let source = RelativePath(String(repeating: "é", count: 126) + ".md")
        let first = try SyncNaming.conflict(source: source, groupFolder: nil, device: "Device", at: date, occupiedPaths: [])
        let second = try SyncNaming.conflict(source: source, groupFolder: nil, device: "Device", at: date, occupiedPaths: [first])
        let suffix = first.string.components(separatedBy: " (conflict ")[1]
        XCTAssertTrue(second.string.hasSuffix(" (conflict " + String(suffix.dropLast(3)) + " (2).md"))
        XCTAssertLessThanOrEqual(LibraryPath.filename(second.string).utf8.count, 255)
        let long = RelativePath(".hidden/" + source.string)
        let rescue = try SyncNaming.rescue(source: long, at: date, occupiedPaths: [])
        let collision = try SyncNaming.rescue(source: long, at: date, occupiedPaths: [rescue])
        let hashSuffix = String(SyncHash(bytes: Data(long.string.utf8)).rawValue.prefix(12))
        XCTAssertTrue(collision.string.hasSuffix(" (" + hashSuffix + ") (2).md"))
        XCTAssertLessThanOrEqual(LibraryPath.filename(collision.string).utf8.count, 255)
    }

    func testAWholeCharacterTooLargeForTheRemainingStemGetsASafeFallback() throws {
        let stem = "q" + String(repeating: "\u{301}", count: 100)
        XCTAssertEqual(stem.count, 1)
        let source = RelativePath(stem + ".md")
        XCTAssertNoThrow(try SyncPathValidator.validate(source.string, scope: .user))
        let conflict = try SyncNaming.conflict(source: source, groupFolder: nil,
            device: String(repeating: "D", count: 64), at: date, occupiedPaths: [])
        XCTAssertTrue(LibraryPath.filename(conflict.string).hasPrefix("Prompt (conflict "))
        XCTAssertNoThrow(try SyncPathValidator.validate(conflict.string, scope: .user))
    }

    func testMaximumRootedGroupPathRescueFlattensWithStableSourceSuffix() throws {
        let segment = String(repeating: "a", count: 255)
        let wire = segment + "/" + segment + "/" + String(repeating: "c", count: 254) + "/d/" + String(repeating: "b", count: 252) + ".md"
        XCTAssertEqual(wire.utf8.count, 1024)
        let rooted = RelativePath("Groups/" + segment + "/" + wire)
        XCTAssertEqual(rooted.string.utf8.count, 1287)
        let rescue = try SyncNaming.rescue(source: rooted, at: date, occupiedPaths: [])
        XCTAssertLessThanOrEqual(rescue.string.utf8.count, 1024)
        XCTAssertEqual(rescue.string.split(separator: "/").count, 3)
        XCTAssertEqual(try SyncNaming.rescue(source: rooted, at: date, occupiedPaths: []), rescue)
        XCTAssertNoThrow(try SyncPathValidator.validate(rescue.string, scope: .user))
        let other = RelativePath(rooted.string.replacingOccurrences(of: "Groups/", with: "groups/"))
        XCTAssertNotEqual(try SyncNaming.rescue(source: other, at: date, occupiedPaths: []), rescue)
    }

    func testOrdinaryRescueKeepsSafeHierarchyAndForensicsGetMarkdownDestination() throws {
        let regular = try SyncNaming.rescue(source: "Groups/Team/Nested/a.md", at: date, occupiedPaths: [])
        XCTAssertTrue(regular.string.hasSuffix("/Groups/Team/Nested/a.md"))
        let forensic = try SyncNaming.rescue(source: ".hidden/Unknown.bin", at: date, occupiedPaths: [])
        XCTAssertTrue(forensic.string.hasSuffix(").md"))
        XCTAssertNoThrow(try SyncPathValidator.validate(forensic.string, scope: .user))
        XCTAssertTrue(LibraryPath.isPrompt(forensic.string))
    }
}
