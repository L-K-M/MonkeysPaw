import XCTest
@testable import MonkeysPawCore

final class PathIdentityTests: XCTestCase {
    func testFileEventEqualityUsesPathBytes() {
        XCTAssertNotEqual(FileStoreEvent(relativePath: "é.md", kind: .created),
                          FileStoreEvent(relativePath: "e\u{301}.md", kind: .created))
    }

    func testStoredFileEqualityUsesPathBytesEvenWithTheSameStamp() {
        let stamp = FileStamp("same inode, including hard links")
        XCTAssertNotEqual(StoredFile(relativePath: "é.md", stamp: stamp),
                          StoredFile(relativePath: "e\u{301}.md", stamp: stamp))
    }

    func testPickerRowsAndEditIntentsUsePathBytesEvenWithTheSameIdentity() {
        let identity = PromptIdentity.local(String(repeating: "0", count: 64))
        func row(_ path: String) -> PickerResultRow {
            PickerResultRow(identity: identity, relativePath: path, title: "Same", folder: "",
                tags: [], favorite: false, previewLine: nil, issues: [], canRender: true)
        }
        XCTAssertNotEqual(row("é.md"), row("e\u{301}.md"))
        XCTAssertNotEqual(PickerModel.Intent.edit(identity: identity, relativePath: "é.md"),
                          PickerModel.Intent.edit(identity: identity, relativePath: "e\u{301}.md"))
    }
}
