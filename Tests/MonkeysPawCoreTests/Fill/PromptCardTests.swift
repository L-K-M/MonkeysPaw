import XCTest
@testable import MonkeysPawCore

final class PromptCardTests: XCTestCase {
    private func card(_ source: String) -> PromptCard {
        PromptCard(document: PromptCodec.parse(source, filename: "a.md"))
    }

    func testLiteralAndEmptyBodiesProduceOnlyTextSegments() throws {
        XCTAssertEqual(card("").segments, [])
        XCTAssertEqual(card("Just body").segments, [.text("Just body")])
        let document = PromptCodec.parse("alpha\nbeta\n", filename: "a.md")
        XCTAssertEqual(PromptCard(document: document).segments, [.text(document.body)])
        XCTAssertFalse(card("Just body").hasFields)
    }

    func testEscapedOpenerFlattensToLiteralBracesAndMerges() throws {
        // The card shows the text the user typed, matching render output.
        XCTAssertEqual(card("a\\{{b").segments, [.text("a{{b")])
        XCTAssertEqual(card("{{f}}\\{{x").segments, [
            .field(name: "f", label: "f", kind: .text, occurrence: 0),
            .text("{{x"),
        ])
        XCTAssertEqual(card("\\{{").segments, [.text("{{")])
    }

    func testDeferredAndUnknownPlaceholdersBecomeLiteralText() throws {
        for name in ["selection", "cursor", "datetime", "uuid"] {
            XCTAssertEqual(card("pre {{\(name)}} post").segments,
                           [.text("pre {{\(name)}} post")], name)
        }
        // A deferred name beside a field does not merge across the field.
        XCTAssertEqual(card("{{f}} {{selection}}").segments, [
            .field(name: "f", label: "f", kind: .text, occurrence: 0),
            .text(" {{selection}}"),
        ])
        XCTAssertFalse(card("{{selection}}").hasFields)
    }

    func testBuiltinPlaceholdersStayBuiltinAndBreakLiteralRuns() throws {
        XCTAssertEqual(card("{{date}}/{{time}}/{{clipboard}}").segments, [
            .builtin(.date), .text("/"), .builtin(.time), .text("/"), .builtin(.clipboard),
        ])
        XCTAssertEqual(card("x{{date}}y").segments, [.text("x"), .builtin(.date), .text("y")])
        XCTAssertFalse(card("{{clipboard}}").hasFields)
    }

    func testFieldOccurrencesCountPerNameFromZero() throws {
        XCTAssertEqual(card("{{f}} {{f}} {{g}} {{f}}").segments, [
            .field(name: "f", label: "f", kind: .text, occurrence: 0),
            .text(" "),
            .field(name: "f", label: "f", kind: .text, occurrence: 1),
            .text(" "),
            .field(name: "g", label: "g", kind: .text, occurrence: 0),
            .text(" "),
            .field(name: "f", label: "f", kind: .text, occurrence: 2),
        ])
        XCTAssertTrue(card("{{f}}").hasFields)
    }

    func testFieldSegmentsCarryDeclaredLabelAndKind() throws {
        XCTAssertEqual(card("""
        ---
        fields:
          pick:
            type: choice
            label: Language
            options: [Rust, Python]
          write:
            type: multiline
        ---
        {{pick}} {{implicit}} {{pick}} {{write}}
        """).segments, [
            .field(name: "pick", label: "Language", kind: .choice, occurrence: 0),
            .text(" "),
            .field(name: "implicit", label: "implicit", kind: .text, occurrence: 0),
            .text(" "),
            .field(name: "pick", label: "Language", kind: .choice, occurrence: 1),
            .text(" "),
            .field(name: "write", label: "write", kind: .multiline, occurrence: 0),
        ])
    }

    func testUnicodeLiteralsAndLabelsArePreserved() throws {
        XCTAssertEqual(card("héllo {{f}} wörld — ö").segments, [
            .text("héllo "),
            .field(name: "f", label: "f", kind: .text, occurrence: 0),
            .text(" wörld — ö"),
        ])
        XCTAssertEqual(card("---\nfields:\n  greet:\n    label: Crème brûlée\n---\n{{greet}}").segments, [
            .field(name: "greet", label: "Crème brûlée", kind: .text, occurrence: 0),
        ])
    }
}
