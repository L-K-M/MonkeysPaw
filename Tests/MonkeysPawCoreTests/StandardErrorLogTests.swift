import Foundation
import XCTest
@testable import MonkeysPawCore

final class StandardErrorLogTests: XCTestCase {
    func testFormatsLevelsAndMessages() throws {
        let pipe = Pipe()
        let log = StandardErrorLog(output: pipe.fileHandleForWriting)

        log.write(.debug, "stage started")
        log.write(.info, "loaded 3 prompts")
        log.write(.warning, "backend unavailable")
        log.write(.error, "save failed")
        try pipe.fileHandleForWriting.close()

        let bytes = try XCTUnwrap(pipe.fileHandleForReading.readToEnd())
        let output = try XCTUnwrap(String(data: bytes, encoding: .utf8))

        XCTAssertEqual(output, """
        monkeyspaw debug: stage started
        monkeyspaw info: loaded 3 prompts
        monkeyspaw warning: backend unavailable
        monkeyspaw error: save failed

        """)
    }
}
