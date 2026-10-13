import Foundation
import XCTest

final class SchemaValidatorTests: XCTestCase {
    func testSchemaJSONPreservesLiteralKindsAndExactIntegers() throws {
        let cases: [(String, SchemaJSON)] = [
            ("0", .integer(0)), ("1", .integer(1)),
            ("true", .boolean(true)), ("false", .boolean(false)),
            ("9223372036854775807", .integer(.max)),
            ("-9223372036854775808", .integer(.min)),
            ("9223372036854775808", .number(9_223_372_036_854_775_808)),
            ("-9223372036854775809", .number(-9_223_372_036_854_775_808)),
            ("-9223372036854775810", .number(-9_223_372_036_854_775_808)),
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
}
