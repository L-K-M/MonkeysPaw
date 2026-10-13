import Foundation
import XCTest

final class SchemaValidatorTests: XCTestCase {
    func testSchemaJSONPreservesLiteralKindsAndExactIntegers() throws {
        let cases: [(String, SchemaJSON)] = [
            ("0", .integer(0)), ("1", .integer(1)),
            ("true", .boolean(true)), ("false", .boolean(false)),
            ("9223372036854775807", .integer(.max)),
            ("-9223372036854775808", .integer(.min)),
            ("9223372036854775808", .number(try XCTUnwrap(Decimal(string: "9223372036854775808")))),
            ("-9223372036854775809", .number(try XCTUnwrap(Decimal(string: "-9223372036854775809")))),
            ("-9223372036854775810", .number(try XCTUnwrap(Decimal(string: "-9223372036854775810")))),
            ("1.0", .integer(1)), ("1e0", .integer(1)), ("1.5", .number(1.5)),
            ("\"1\"", .string("1")), ("null", .null),
            (#"{"values":[0,1,true,false]}"#,
             .object(["values": .array([.integer(0), .integer(1), .boolean(true), .boolean(false)])]))
        ]
        for (source, expected) in cases {
            XCTAssertEqual(try SchemaJSON(data: Data(source.utf8)), expected, source)
        }

        let validator = SchemaValidator(schemas: [:])
        for source in ["0", "1", "true", "false"] {
            let value = try SchemaJSON(data: Data(source.utf8))
            let isBoolean = source == "true" || source == "false"
            XCTAssertEqual(try validator.validate(value, against: .object(["type": .string("boolean")])), isBoolean, source)
            XCTAssertEqual(try validator.validate(value, against: .object(["type": .string("integer")])), !isBoolean, source)
        }
    }

    func testSchemaValidatorRejectsMalformedTypeAndRequired() throws {
        let validator = SchemaValidator(schemas: [:])
        let sources = [
            #"{"type":["string","null"]}"#, #"{"type":null}"#,
            #"{"type":1}"#, #"{"type":true}"#,
            #"{"required":"name"}"#, #"{"required":null}"#,
            #"{"required":[1]}"#, #"{"required":[true]}"#,
            #"{"required":["missing",null]}"#
        ]
        for source in sources {
            let schema = try SchemaJSON(data: Data(source.utf8))
            for value in [SchemaJSON.object(["": .string("present")]), .string("text")] {
                XCTAssertThrowsError(try validator.validate(value, against: schema), source) { error in
                    guard case SchemaValidator.Failure.unsupportedSchema = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                }
            }
        }
    }

    func testSchemaValidatorAcceptsNumbersAndOnlyIntegralIntegers() throws {
        let validator = SchemaValidator(schemas: [:])
        let number = SchemaJSON.object(["type": .string("number")])
        let integer = SchemaJSON.object(["type": .string("integer")])
        for (source, isInteger) in [("-2", true), ("0", true), ("1", true), ("2.0", true), ("2e0", true),
                                    ("-1.5", false), ("0.5", false), ("2.5", false)] {
            let value = try SchemaJSON(data: Data(source.utf8))
            XCTAssertTrue(try validator.validate(value, against: number), source)
            XCTAssertEqual(try validator.validate(value, against: integer), isInteger, source)
        }
        for source in ["true", "false", "null", #""2""#, "[]", "{}"] {
            let value = try SchemaJSON(data: Data(source.utf8))
            XCTAssertFalse(try validator.validate(value, against: number), source)
            XCTAssertFalse(try validator.validate(value, against: integer), source)
        }

        let bounded = try SchemaJSON(data: Data(#"{"type":"number","minimum":0.5,"maximum":2.5}"#.utf8))
        for (source, valid) in [("0.5", true), ("1", true), ("2.0", true), ("2.5", true),
                                ("0.4", false), ("0", false), ("2.6", false), ("3", false)] {
            XCTAssertEqual(try validator.validate(SchemaJSON(data: Data(source.utf8)), against: bounded), valid, source)
        }
        let exact = SchemaJSON.object(["type": .string("number"), "minimum": .integer(.min), "maximum": .integer(.max)])
        for source in ["9223372036854775807", "-9223372036854775808"] {
            XCTAssertTrue(try validator.validate(SchemaJSON(data: Data(source.utf8)), against: exact), source)
        }
        for source in ["9223372036854775808", "-9223372036854775809"] {
            XCTAssertFalse(try validator.validate(SchemaJSON(data: Data(source.utf8)), against: exact), source)
        }
    }

    func testSchemaValidatorChecksFullUTCMillisecondSpellingAndCalendar() throws {
        let validator = SchemaValidator(schemas: [:])
        let schema = SchemaJSON.object(["type": .string("string"), "x-syncapi-format": .string("utc-milliseconds")])
        for source in ["0001-01-01T00:00:00.000Z", "2000-02-29T12:34:56.789Z", "9999-12-31T23:59:59.999Z"] {
            XCTAssertTrue(try validator.validate(.string(source), against: schema), source)
        }
        for source in [
            "2024-01-01", "2024-01-01T99:99:99.000Z", "2024-01-01T24:00:00.000Z",
            "2024-01-01T00:60:00.000Z", "2024-01-01T00:00:60.000Z", "2024-01-01T00:00:00Z",
            "2024-01-01T00:00:00.00Z", "2024-01-01T00:00:00.0000Z", "2024-01-01T00:00:00.000+00:00",
            "2024-01-01T00:00:00.000z", "2024-01-01 00:00:00.000Z", "2024-01-01T00:00:00.000Z\n",
            "0000-01-01T00:00:00.000Z", "10000-01-01T00:00:00.000Z", "1900-02-29T00:00:00.000Z",
            "2025-02-29T00:00:00.000Z", "2024-04-31T00:00:00.000Z"
        ] {
            XCTAssertTrue(try validator.validate(.string(source), against: schema, mode: .schema), source)
            XCTAssertFalse(try validator.validate(.string(source), against: schema), source)
        }
    }

    func testSchemaJSONRejectsMalformedJSON() {
        for source in ["", "tru", "nul", "{", "[1", "1 2", "{}{}"] {
            XCTAssertThrowsError(try SchemaJSON(data: Data(source.utf8)), source)
        }
    }
}
