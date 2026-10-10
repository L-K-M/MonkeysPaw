import Foundation
import XCTest
@testable import MonkeysPawCore

final class SHA256Tests: XCTestCase {
    func testStandardKnownAnswerVectors() {
        let vectors = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
             "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
            ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
             "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"),
        ]
        for (source, digest) in vectors { XCTAssertEqual(SHA256.hexDigest(Data(source.utf8)), digest) }
    }

    func testMillionByteMultiBlockVector() {
        XCTAssertEqual(SHA256.hexDigest(Data(repeating: 0x61, count: 1_000_000)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testLocalIdentityHashesExactRelativePathBytes() {
        let path = "folder/é.md"
        let identity = PromptIdentity(path: path, id: nil)
        XCTAssertEqual(identity, .local(SHA256.hexDigest(Data(path.utf8))))
        XCTAssertNotEqual(identity, PromptIdentity(path: "folder/e\u{301}.md", id: nil))
        XCTAssertNotEqual(identity, PromptIdentity(path: "other/é.md", id: nil))
        XCTAssertFalse(String(describing: identity).contains(path))
    }
}
