import Foundation
import XCTest
import MonkeysPawCore

/// Run hostile inputs in a child XCTest process. A parser regression must fail
/// within the deadline without leaving the parent suite stuck inside Yams.
final class PromptParserWorkTests: XCTestCase {
    private let largeRadixDigits = 64_000
    private let nearLimitRadixDigits = Limits.maxPromptBytes - 256
    private let processDeadline: TimeInterval = 10

    func testLiteralAnchorCharactersRemainValid() throws {
        try isolated(#function) {
            let source = """
            ---
            quoted: "&anchor *alias #literal"
            single: '*alias &anchor #literal'
            plain: middle&anchor middle*alias &anchor *alias
            literal: |
              &anchor
              *alias
              #literal
            folded: >
              &anchor
              *alias
            tagged: !!str "*alias &anchor"
            nonspecific: ! '&anchor *alias'
            # &anchor *alias
            ---
            Body
            """
            let document = PromptCodec.parse(source, filename: "Probe.md")
            XCTAssertEqual(document.source, source)
            XCTAssertTrue(document.issues.isEmpty)
            XCTAssertEqual(try PromptRenderer.render(document), "Body")
            let written = try PromptCodec.write(document)
            let reparsed = PromptCodec.parse(written, filename: "Probe.md")
            XCTAssertTrue(reparsed.issues.isEmpty)
            XCTAssertEqual(reparsed.body, "Body")
            XCTAssertEqual(try PromptCodec.write(reparsed), written)
        }
    }

    func testAliasKeyIsRejectedBeforeExpansion() throws {
        try isolated(#function) {
            var entries: [String] = ["seed: &n0 [value]"]
            for index in 1...25 {
                entries.append("level\(index): &n\(index) [*n\(index - 1), *n\(index - 1)]")
            }
            entries.append("? *n25\n: key-value")
            let source = "---\n" + entries.joined(separator: "\n") + "\n---\nBody"
            XCTAssertEqual(source.utf8.count, 686)
            let document = PromptCodec.parse(source, filename: "Probe.md")
            XCTAssertEqual(document.source, source)
            XCTAssertEqual(document.body, "Body")
            XCTAssertTrue(document.issues.contains { $0.code == .anchorOrAlias })
            XCTAssertFalse(document.canRender)
            XCTAssertThrowsError(try PromptCodec.write(document))
        }
    }

    func testLargeExplicitIntegerKeyAndRoundTripAreBounded() throws {
        try isolated(#function) {
            let key = "0x" + String(repeating: "f", count: largeRadixDigits)
            let source = "---\n? " + key + "\n: value\n---\nBody"
            XCTAssertEqual(source.utf8.count, 64_025)
            let document = PromptCodec.parse(source, filename: "Probe.md")
            XCTAssertTrue(document.issues.isEmpty)
            XCTAssertTrue(document.canRender)
            XCTAssertEqual(try PromptRenderer.render(document), "Body")
            let written = try PromptCodec.write(document)
            XCTAssertTrue(written.contains(key))
            let reparsed = PromptCodec.parse(written, filename: "Probe.md")
            XCTAssertTrue(reparsed.issues.isEmpty)
            XCTAssertEqual(reparsed.body, "Body")
            XCTAssertEqual(try PromptCodec.write(reparsed), written)
        }
    }

    func testLargeRadixFormatReturnsExactReadOnlyVersion() throws {
        try isolated(#function) {
            let source = "---\nformat: 0x" + String(repeating: "f", count: largeRadixDigits) + "\n---\nBody"
            XCTAssertEqual(source.utf8.count, 64_023)
            let document = PromptCodec.parse(source, filename: "Probe.md")
            XCTAssertEqual(document.source, source)
            XCTAssertEqual(document.body, "Body")
            XCTAssertEqual(document.issues.map(\.code), [.unsupportedFormat])
            XCTAssertTrue(document.isReadOnly)
            XCTAssertFalse(document.canRender)
            let version = document.frontMatter.format
            // Independent Python integer oracle: str((1 << 256000) - 1).
            XCTAssertEqual(version.decimalValue.utf8.count, 77_064)
            XCTAssertEqual(String(version.decimalValue.prefix(80)),
                           "47740831539698625844989483573034188227645677020582450586218881609034630342475902")
            XCTAssertEqual(String(version.decimalValue.suffix(80)),
                           "56953728177214082422123812696530714923077542922312620781642885544348819312869375")
            XCTAssertEqual(decimalChecksum(version.decimalValue), 0x0e24058fd697f955)
            XCTAssertThrowsError(try PromptCodec.write(document)) {
                XCTAssertEqual($0 as? PromptWriteError, .unsupportedFormat(version))
            }
            XCTAssertThrowsError(try PromptRenderer.render(document)) {
                XCTAssertEqual($0 as? PromptRenderError, .unsupportedFormat(version))
            }
        }
    }

    func testNearLimitIntegerKeyRoundTripIsBounded() throws {
        try isolated(#function) {
            let key = "0x" + String(repeating: "f", count: nearLimitRadixDigits)
            let source = "---\n? " + key + "\n: value\n---\nBody"
            XCTAssertLessThan(source.utf8.count, Limits.maxPromptBytes)
            XCTAssertLessThan(Limits.maxPromptBytes - source.utf8.count, 256)
            let document = PromptCodec.parse(source, filename: "Probe.md")
            XCTAssertTrue(document.issues.isEmpty)
            XCTAssertTrue(document.canRender)
            XCTAssertEqual(try PromptRenderer.render(document), "Body")
            let written = try PromptCodec.write(document)
            XCTAssertTrue(written.contains(key))
            let reparsed = PromptCodec.parse(written, filename: "Probe.md")
            XCTAssertTrue(reparsed.issues.isEmpty)
            XCTAssertEqual(reparsed.frontMatter, document.frontMatter)
            XCTAssertEqual(reparsed.body, "Body")
            XCTAssertEqual(try PromptCodec.write(reparsed), written)
        }
    }

    func testNearLimitFormatReturnsExactReadOnlyVersion() throws {
        try isolated(#function) {
            let source = "---\nformat: 0x" + String(repeating: "f", count: nearLimitRadixDigits) + "\n---\nBody"
            XCTAssertLessThan(source.utf8.count, Limits.maxPromptBytes)
            XCTAssertLessThan(Limits.maxPromptBytes - source.utf8.count, 256)
            let document = PromptCodec.parse(source, filename: "Probe.md")
            XCTAssertEqual(document.source, source)
            XCTAssertEqual(document.body, "Body")
            XCTAssertEqual(document.issues.map(\.code), [.unsupportedFormat])
            XCTAssertTrue(document.isReadOnly)
            XCTAssertFalse(document.canRender)
            let version = document.frontMatter.format
            // Independent Python oracle: str((1 << (261888 * 4)) - 1).
            XCTAssertEqual(version.decimalValue.utf8.count, 315_345)
            XCTAssertEqual(String(version.decimalValue.prefix(80)),
                           "37498836674454857564675524082172798133359444894381400828284855921855133754214044")
            XCTAssertEqual(String(version.decimalValue.suffix(80)),
                           "37483288163601806583498230806113465299721526706804488436487835176877495204970495")
            XCTAssertEqual(decimalChecksum(version.decimalValue), 0x5bcc0ec3640cdc3a)
            XCTAssertThrowsError(try PromptCodec.write(document)) {
                XCTAssertEqual($0 as? PromptWriteError, .unsupportedFormat(version))
            }
            XCTAssertThrowsError(try PromptRenderer.render(document)) {
                XCTAssertEqual($0 as? PromptRenderError, .unsupportedFormat(version))
            }
        }
    }

    func testNearLimitOctalFormatReturnsExactReadOnlyVersion() throws {
        try isolated(#function) {
            let source = "---\nformat: 0o" + String(repeating: "7", count: nearLimitRadixDigits) + "\n---\nBody"
            XCTAssertLessThan(source.utf8.count, Limits.maxPromptBytes)
            XCTAssertLessThan(Limits.maxPromptBytes - source.utf8.count, 256)
            let document = PromptCodec.parse(source, filename: "Probe.md")
            XCTAssertEqual(document.source, source)
            XCTAssertEqual(document.body, "Body")
            XCTAssertEqual(document.issues.map(\.code), [.unsupportedFormat])
            XCTAssertTrue(document.isReadOnly)
            XCTAssertFalse(document.canRender)
            let version = document.frontMatter.format
            // Independent Python oracle: str((1 << (261888 * 3)) - 1).
            XCTAssertEqual(version.decimalValue.utf8.count, 236_509)
            XCTAssertEqual(String(version.decimalValue.prefix(80)),
                           "26947181413322124650220192690173964235920497364795482829409479022335043428386726")
            XCTAssertEqual(String(version.decimalValue.suffix(80)),
                           "25896603642243098224382111170408517714545930170872561833462137199256677033967615")
            XCTAssertEqual(decimalChecksum(version.decimalValue), 0x1282a1efc482b30c)
            XCTAssertThrowsError(try PromptCodec.write(document)) {
                XCTAssertEqual($0 as? PromptWriteError, .unsupportedFormat(version))
            }
            XCTAssertThrowsError(try PromptRenderer.render(document)) {
                XCTAssertEqual($0 as? PromptRenderError, .unsupportedFormat(version))
            }
        }
    }

    func testRadixChunkCarriesAndCrossBaseDuplicatesAreExact() throws {
        try isolated(#function) {
            // Python int/format oracles around binary-word and decimal-chunk
            // boundaries, plus multiple carries and a partial leading group.
            let cases: [(String, String, String)] = [
                ("0x3b9ac9ff", "0o7346544777", "999999999"),
                ("0x3b9aca00", "0o7346545000", "1000000000"),
                ("0x3b9aca01", "0o7346545001", "1000000001"),
                ("0xffffffff", "0o37777777777", "4294967295"),
                ("0x100000000", "0o40000000000", "4294967296"),
                ("0xfffffffffffffff", "0o77777777777777777777", "1152921504606846975"),
                ("0x7fffffffffffffff", "0o777777777777777777777", "9223372036854775807"),
                ("0xffffffffffffffff", "0o1777777777777777777777", "18446744073709551615"),
                ("0x10000000000000000", "0o2000000000000000000000", "18446744073709551616"),
                ("0x8ac7230489e7ffff", "0o1053071060221171777777", "9999999999999999999"),
                ("0x8ac7230489e80000", "0o1053071060221172000000", "10000000000000000000"),
                ("0x8ac7230489e80001", "0o1053071060221172000001", "10000000000000000001"),
                ("0xffffffffffffffffffffffffffffffff", "0o3777777777777777777777777777777777777777777",
                 "340282366920938463463374607431768211455"),
                ("0x100000000000000000000000000000000", "0o4000000000000000000000000000000000000000000",
                 "340282366920938463463374607431768211456"),
                ("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                 "0o17777777777777777777777777777777777777777777777777777777777777777777777777777777777777",
                 "115792089237316195423570985008687907853269984665640564039457584007913129639935"),
                ("0xf0010000000000000000000000000000f", "0o74000400000000000000000000000000000000000017",
                 "5104318580563813509192675599417790693391")
            ]
            for (hex, octal, decimal) in cases {
                let spellings: [String] = [hex, octal, decimal, "+" + decimal, hex.uppercased().replacingOccurrences(of: "0X", with: "0x")]
                for spelling in spellings {
                    let document = PromptCodec.parse("---\nformat: " + spelling + "\n---\nBody", filename: "Probe.md")
                    XCTAssertEqual(document.frontMatter.format.decimalValue, decimal, spelling)
                    XCTAssertEqual(document.issues.map(\.code), [.unsupportedFormat], spelling)
                    XCTAssertTrue(document.isReadOnly)
                    XCTAssertFalse(document.canRender)
                }
                let duplicate = PromptCodec.parse("---\n? " + hex + "\n: first\n? " + octal
                                                 + "\n: second\n? +" + decimal + "\n: third\n---\nBody",
                                                 filename: "Probe.md")
                XCTAssertEqual(duplicate.issues.map(\.code), [.duplicateKey, .duplicateKey])
                XCTAssertFalse(duplicate.canRender)
                XCTAssertThrowsError(try PromptCodec.write(duplicate))
                let distinct = PromptCodec.parse("---\n? " + hex + "\n: first\n? " + decimal
                                                + "0\n: second\n---\nBody", filename: "Probe.md")
                XCTAssertTrue(distinct.issues.isEmpty)
                let written = try PromptCodec.write(distinct)
                XCTAssertTrue(PromptCodec.parse(written, filename: "Probe.md").issues.isEmpty)
            }
        }
    }

    func testBalancedRadixGroupsPreserveMixedAndSparseIntegers() throws {
        try isolated(#function) {
            // Independent Python int(digits, 16)/decimal/FNV-1a oracles.
            // Odd group counts, zero groups and carries cross recursive splits.
            let cases: [(String, Int, UInt64)] = [
                (String(repeating: "f00ab001", count: 256), 2_467, 0xe44cd42cb3d0be14),
                ("1" + String(repeating: "0", count: 8_191) + "1", 9_865, 0xa6992f6104a2ea4b),
                (String(repeating: "abc0123456789def", count: 137), 2_640, 0xef09ac09790edb8d)
            ]
            for (digits, count, checksum) in cases {
                let key = "0x" + digits
                let source = "---\nformat: " + key + "\n---\nBody"
                let document = PromptCodec.parse(source, filename: "Probe.md")
                let version = document.frontMatter.format
                XCTAssertEqual(version.decimalValue.utf8.count, count)
                XCTAssertEqual(decimalChecksum(version.decimalValue), checksum)
                XCTAssertEqual(document.issues.map(\.code), [.unsupportedFormat])
                XCTAssertTrue(document.isReadOnly)
                XCTAssertFalse(document.canRender)
                XCTAssertThrowsError(try PromptCodec.write(document)) {
                    XCTAssertEqual($0 as? PromptWriteError, .unsupportedFormat(version))
                }
                XCTAssertThrowsError(try PromptRenderer.render(document)) {
                    XCTAssertEqual($0 as? PromptRenderError, .unsupportedFormat(version))
                }
                let duplicate = PromptCodec.parse("---\n? " + key + "\n: first\n? "
                                                 + version.decimalValue + "\n: second\n---\nBody",
                                                 filename: "Probe.md")
                XCTAssertEqual(duplicate.issues.map(\.code), [.duplicateKey])
                XCTAssertFalse(duplicate.canRender)
                XCTAssertThrowsError(try PromptCodec.write(duplicate))
                let distinct = PromptCodec.parse("---\n? " + key + "\n: first\n? "
                                                + version.decimalValue + "0\n: second\n---\nBody",
                                                filename: "Probe.md")
                XCTAssertTrue(distinct.issues.isEmpty)
                XCTAssertEqual(try PromptRenderer.render(distinct), "Body")
                let written = try PromptCodec.write(distinct)
                let reparsed = PromptCodec.parse(written, filename: "Probe.md")
                XCTAssertTrue(reparsed.issues.isEmpty)
                XCTAssertEqual(try PromptCodec.write(reparsed), written)
            }
        }
    }

    func testRadixPaddingZeroAndDecimalSignsKeepTheirMeaning() throws {
        try isolated(#function) {
            let validSpellings: [String] = ["1", "+1", "0x0001", "0o0001", "!!int '0x0001'"]
            for spelling in validSpellings {
                let document = PromptCodec.parse("---\nformat: " + spelling + "\n---\nBody", filename: "Probe.md")
                XCTAssertTrue(document.issues.isEmpty, spelling)
                XCTAssertEqual(document.frontMatter.format.decimalValue, "1")
                XCTAssertEqual(try PromptRenderer.render(document), "Body")
                XCTAssertTrue(try PromptCodec.write(document).contains("format: 1\n"))
            }
            let invalidSpellings: [String] = ["0", "+0", "-0", "0x000000000000000000000", "0o000000000000000000000", "-1"]
            for spelling in invalidSpellings {
                let document = PromptCodec.parse("---\nformat: " + spelling + "\n---\nBody", filename: "Probe.md")
                XCTAssertEqual(document.issues.map(\.code), [.invalidFormat], spelling)
                XCTAssertFalse(document.isReadOnly)
                XCTAssertFalse(document.canRender)
            }
            let pairs: [(String, String)] = [("+0", "0x000"), ("-0", "0o000"), ("0x000a", "+10"), ("0o0012", "10"), ("-10", "!!int '-10'")]
            for pair in pairs {
                let document = PromptCodec.parse("---\n? " + pair.0 + "\n: first\n? " + pair.1
                                                 + "\n: second\n---\nBody", filename: "Probe.md")
                XCTAssertEqual(document.issues.map(\.code), [.duplicateKey])
                XCTAssertFalse(document.canRender)
            }
            let prefixes: [String] = ["0x", "0o"]
            for prefix in prefixes {
                let padded = "---\nformat: " + prefix + String(repeating: "0", count: nearLimitRadixDigits - 1) + "1\n---\nBody"
                let document = PromptCodec.parse(padded, filename: "Probe.md")
                XCTAssertTrue(document.issues.isEmpty)
                XCTAssertEqual(document.frontMatter.format.decimalValue, "1")
                XCTAssertEqual(try PromptRenderer.render(document), "Body")
                XCTAssertEqual(try PromptCodec.write(document), "---\nformat: 1\n---\nBody")
            }
        }
    }

    func testNestedAliasKeysRetainMetadataBeforeRejection() throws {
        try isolated(#function) {
            let metadata = """
            id: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD
            title: Retained title
            description: Retained description
            tags: [one, two]
            favorite: true
            private: false
            fields: {topic: {type: choice, options: [Swift, Rust], default: Swift}}
            """
            let body = "  👋 {{topic}}\r\n"
            let reference = PromptCodec.parse("---\n" + metadata + "\n---\n" + body, filename: "Probe.md")
            XCTAssertTrue(reference.issues.isEmpty)
            let depth = 128
            var entries: [String] = [metadata, "seed: &n0 [value]"]
            for index in 1...depth {
                entries.append("level\(index): &n\(index) [*n\(index - 1), *n\(index - 1)]")
            }
            // Aliases can hide in a sequence, either side of a mapping pair,
            // or a mapping nested inside a sequence used as a key.
            let keys: [String] = ["[*n128]", "{? *n128 : value}", "{nested: *n128}", "[{nested: [*n128]}]"]
            for key in keys {
                let source = "---\n" + entries.joined(separator: "\n") + "\n? " + key + "\n: rejected\n---\n" + body
                let document = PromptCodec.parse(source, filename: "Probe.md")
                XCTAssertEqual(document.source, source)
                XCTAssertEqual(Array(document.body.utf8), Array(body.utf8))
                XCTAssertEqual(document.frontMatter, reference.frontMatter)
                XCTAssertEqual(document.effectiveFields, reference.effectiveFields)
                XCTAssertEqual(document.issues.map(\.code), Array(repeating: .anchorOrAlias, count: depth + 2))
                XCTAssertEqual(document.issues, PromptValidator.validate(document))
                XCTAssertFalse(document.canRender)
                XCTAssertThrowsError(try PromptCodec.write(document)) {
                    XCTAssertEqual($0 as? PromptWriteError, .invalidPrompt)
                }
                XCTAssertThrowsError(try PromptRenderer.render(document)) {
                    XCTAssertEqual($0 as? PromptRenderError, .invalidPrompt)
                }
            }
        }
    }

    func testDeferredEqualKeysReportAnchorsAndRecoverOrdinaryMetadata() throws {
        try isolated(#function) {
            let source = """
            ---
            title: Retained title
            private: false
            ? &bad title
            : Rejected title
            ---
            {{implicit}}
            """
            let document = PromptCodec.parse(source, filename: "Fallback.md")
            XCTAssertEqual(document.source, source)
            XCTAssertEqual(document.body, "{{implicit}}")
            XCTAssertEqual(document.frontMatter.title, "Retained title")
            XCTAssertFalse(document.frontMatter.isPrivate)
            XCTAssertEqual(document.effectiveFields.map(\.name), ["implicit"])
            XCTAssertEqual(document.issues.map(\.code), [.anchorOrAlias])
            XCTAssertEqual(document.issues.first?.location, .frontMatter(line: 4, column: 3))
            XCTAssertEqual(document.issues, PromptValidator.validate(document))
            XCTAssertFalse(document.canRender)
            XCTAssertThrowsError(try PromptCodec.write(document)) {
                XCTAssertEqual($0 as? PromptWriteError, .invalidPrompt)
            }
            XCTAssertThrowsError(try PromptRenderer.render(document, values: ["implicit": "supplied"])) {
                XCTAssertEqual($0 as? PromptRenderError, .invalidPrompt)
            }

            // Anchored values and duplicates inside anchored collections must
            // still take the ordinary parser-error/fail-closed recovery path.
            let headers: [String] = ["seed: &a value\nx: first\nx: second",
                                     "seed: &a {x: first, x: second}",
                                     "title: Retained title\nprivate: false\nx: first\nx: second"]
            for header in headers {
                let invalid = PromptCodec.parse("---\n" + header + "\n---\nBody", filename: "Fallback.md")
                XCTAssertEqual(invalid.issues.map(\.code), [.duplicateKey])
                XCTAssertEqual(invalid.frontMatter.title, "Fallback")
                XCTAssertTrue(invalid.frontMatter.isPrivate)
                XCTAssertEqual(invalid.body, "Body")
                XCTAssertFalse(invalid.canRender)
            }
        }
    }

    private func isolated(_ function: String, body: () throws -> Void) throws {
        let test = "MonkeysPawCoreTests.PromptParserWorkTests/" + function.replacingOccurrences(of: "()", with: "")
        let childKey = "MONKEYSPAW_PARSER_WORK_TEST"
        if ProcessInfo.processInfo.environment[childKey] == test {
            let started = ProcessInfo.processInfo.systemUptime
            try body()
            print("Parser work: \(function) body took \(ProcessInfo.processInfo.systemUptime - started) seconds.")
            return
        }

        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let output = try FileHandle(forWritingTo: log)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: log)
        }
        let child = Process()
        #if os(Linux)
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [test]
        #else
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", test, Bundle(for: Self.self).bundleURL.path]
        #endif
        var environment = ProcessInfo.processInfo.environment
        environment[childKey] = test
        environment["SWIFT_BACKTRACE"] = "enable=no"
        child.environment = environment
        child.standardOutput = output
        child.standardError = output
        let finished = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in finished.signal() }
        try child.run()
        guard finished.wait(timeout: .now() + processDeadline) == .success else {
            child.terminate()
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success, "Parser child did not terminate.")
            XCTFail("\(test) exceeded the 10-second process deadline.")
            return
        }
        let result = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(child.terminationStatus, 0, result)
        XCTAssertTrue(result.contains("Executed 1 test"), "Child did not execute the selected test: \(result)")
        for line in result.split(separator: "\n") where line.hasPrefix("Parser work:") { print(line) }
    }

    // FNV-1a of every decimal byte, checked against an independent Python
    // integer oracle, also catches errors between the retained end samples.
    private func decimalChecksum(_ value: String) -> UInt64 {
        value.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }
}
