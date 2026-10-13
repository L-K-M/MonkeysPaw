import Foundation
import XCTest
@testable import MonkeysPawCore

final class SyncStateReviewTests: XCTestCase {
    func testManagedFolderKeysRejectULIDAliasesBeforeDictionaryConstruction() throws {
        let raw = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let id = try SyncIdentifiers.ulid(raw)
        let account = try SyncTestValues.account()
        let folder = try SyncManagedFolder(owner: account, folder: "Team")
        let other = try SyncManagedFolder(owner: account, folder: "Other")
        let binding = try SyncLibraryBinding(root: SyncLibraryRoot("/library"), owner: account, managedFolders: [id: folder])
        let aliases = [raw.lowercased(), raw.replacingOccurrences(of: "A", with: "a"),
                       raw.replacingOccurrences(of: "0", with: "O"), raw.replacingOccurrences(of: "1", with: "I"),
                       raw.replacingOccurrences(of: "1", with: "L"), raw.replacingOccurrences(of: "Q", with: "U")]
        for alias in aliases {
            XCTAssertThrowsError(try SyncIdentifiers.ulid(alias)) { XCTAssertEqual($0 as? SyncError, .invalidState) }
            var object = try SyncTestValues.object(binding)
            object["managed_folders"] = [raw: try SyncTestValues.object(folder), alias: try SyncTestValues.object(other)]
            XCTAssertThrowsError(try JSONDecoder().decode(SyncLibraryBinding.self,
                from: JSONSerialization.data(withJSONObject: object))) {
                XCTAssertEqual($0 as? SyncError, .invalidState)
            }
        }
        XCTAssertEqual(try JSONDecoder().decode(SyncLibraryBinding.self, from: JSONEncoder().encode(binding)), binding)
    }

    func testScopeKeyValidationRejectsMalformedSplitsAndUnknownPrefixes() throws {
        let raw = SyncTestValues.user.rawValue
        for value in ["", "user", "user:", ":" + raw, "user:" + raw + ":extra", "team:" + raw, "USER:" + raw] {
            XCTAssertThrowsError(try SyncScopeKey(value)) { XCTAssertEqual($0 as? SyncError, .invalidState) }
            XCTAssertThrowsError(try JSONDecoder().decode(SyncScopeKey.self, from: JSONEncoder().encode(value))) {
                XCTAssertEqual($0 as? SyncError, .invalidState)
            }
        }
        XCTAssertEqual(try SyncScopeKey("user:" + raw), .user(SyncTestValues.user))
        XCTAssertEqual(try SyncScopeKey("group:" + raw), .group(SyncTestValues.user))
    }

    func testAllIssueCodesAreDisjointAndRoundTripWithoutRemapping() throws {
        let content: [PromptIssueCode] = [
            .sourceTooLarge, .invalidUTF8, .unclosedFrontMatter, .invalidYAML, .frontMatterNotMapping,
            .duplicateKey, .anchorOrAlias, .mergeKey, .nonPortableScalar, .nonPortableTag, .invalidID,
            .invalidMetadataType, .groupPrivateRemoved, .invalidFormat, .unsupportedFormat, .invalidFieldName,
            .reservedFieldName, .invalidFieldDeclaration, .unknownFieldType, .invalidFieldProperty,
            .invalidFieldBoolean, .invalidFieldOptions, .invalidFieldDefault, .unusedField,
            .invalidPlaceholder, .unbalancedOpener
        ]
        let paths: [SyncPathIssueCode] = [
            .emptyPath, .normalizationFailed, .absolutePath, .pathTooLong, .emptySegment, .dotSegment,
            .hiddenDirectory, .backslash, .controlCharacter, .trailingDotOrSpace, .segmentTooLong,
            .invalidExtension, .reservedGroupsPrefix
        ]
        let codes = content.map(SyncIssueCode.content) + paths.map(SyncIssueCode.path)
            + [.idMismatch, .notFound, .forbidden, .pathClash, .localVisibility]
        XCTAssertEqual(Set(codes.map(\.rawValue)).count, codes.count)
        for code in codes {
            XCTAssertEqual(try JSONDecoder().decode(SyncIssueCode.self, from: JSONEncoder().encode(code)), code)
        }
    }

    func testClearedKnownOptionalsStayNilAfterNestedMergeAndRestart() throws {
        let files = MemoryFileStore()
        let operations = MemorySyncFileOperations(files: files)
        let store = SyncStateStore(files: files, operations: operations)
        let state = try SyncTestValues.state()
        try store.update(for: state.binding) { $0 = state }
        try store.update(for: state.binding) {
            $0.databaseID = nil
            $0.prompts[.assigned(SyncTestValues.personalPrompt)] = try SyncPromptState(
                scope: .user(SyncTestValues.user), path: "Pending.md", rev: 0)
        }
        let current = try XCTUnwrap(store.snapshot.value)
        let reloaded = try XCTUnwrap(SyncStateStore(files: files, operations: operations).load(for: state.binding))
        XCTAssertEqual(reloaded, current)
        let prompt = try XCTUnwrap(reloaded.prompts[.assigned(SyncTestValues.personalPrompt)])
        XCTAssertNil(reloaded.databaseID)
        XCTAssertNil(prompt.canonicalHash)
        XCTAssertNil(prompt.origin)
        XCTAssertNil(prompt.lastError)
    }

    func testGroupPathsAreRelativeToScopeRatherThanManagedFolder() throws {
        var state = try SyncTestValues.state()
        state.groups[SyncTestValues.device] = try SyncGroupState(name: "Other", folder: "Other", role: .editor)
        // This is Groups/Team/Other/File.md, not a file in the Other group.
        let prompt = try SyncPromptState(scope: .group(SyncTestValues.group), path: "Other/File.md", rev: 1,
                                         canonicalHash: SyncHash(bytes: Data("canonical".utf8)))
        state.prompts[.assigned(SyncTestValues.groupPrompt)] = prompt
        XCTAssertNoThrow(try state.validate())
        XCTAssertEqual(try JSONDecoder().decode(SyncState.self, from: JSONEncoder().encode(state)), state)
    }

    func testBindingPreservesPriorFolderOwnershipAndDuplicateHeldVersions() throws {
        let prior = try SyncTestValues.account()
        let current = try SyncTestValues.account(userID: SyncTestValues.otherUser)
        let hash = SyncHash(bytes: Data("duplicate forensic bytes".utf8))
        let holds = try [RelativePath("Original.md"), "Copy.md"].map {
            try SyncHeldPrompt(identity: .assigned(SyncTestValues.personalPrompt), path: $0,
                               sourceAccount: prior, contentHash: hash)
        }
        let binding = try SyncLibraryBinding(root: SyncLibraryRoot("/library"), owner: current,
            managedFolders: [SyncTestValues.group: SyncManagedFolder(owner: prior, folder: "Team")], holds: holds)
        let reloaded = try JSONDecoder().decode(SyncLibraryBinding.self, from: JSONEncoder().encode(binding))
        XCTAssertEqual(reloaded, binding)
        for hold in holds { XCTAssertTrue(reloaded.isHeld(identity: hold.identity, path: hold.path, contentHash: hold.contentHash)) }
    }
}
