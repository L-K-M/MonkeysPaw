import Foundation

extension SyncAPI {
    public enum IssueLocation: APIObjectDTO, Equatable {
        case frontMatter(line: Int64, column: Int64)
        case body(byteOffset: Int64)
        case path(segment: Int64?)

        public static let schema: SyncAPISchema = .oneOf([
            .object(fields: [.init("kind", .constant("front_matter")), .init("line", .integer(minimum: 1)), .init("column", .integer(minimum: 1))]),
            .object(fields: [.init("kind", .constant("body")), .init("byte_offset", .integer(minimum: 0))]),
            .object(fields: [.init("kind", .constant("path")), .init("segment", .nullable(.integer(minimum: 0)))])
        ])

        init(object: [String: APIValue]) throws {
            switch try object.string("kind") {
            case "front_matter": self = .frontMatter(line: try object.integer("line"), column: try object.integer("column"))
            case "body": self = .body(byteOffset: try object.integer("byte_offset"))
            case "path": self = .path(segment: object["segment"] == .null ? nil : try object.integer("segment"))
            default: throw APIContractError.invalidValue
            }
        }

        var object: [String: APIValue] {
            switch self {
            case .frontMatter(let line, let column): return ["kind": .string("front_matter"), "line": .integer(line), "column": .integer(column)]
            case .body(let offset): return ["kind": .string("body"), "byte_offset": .integer(offset)]
            case .path(let segment): return ["kind": .string("path"), "segment": segment.map(APIValue.integer) ?? .null]
            }
        }
    }

    public struct Issue: APIObjectDTO, Equatable {
        public let code: String
        public let severity: Severity
        public let location: IssueLocation?

        public init(code: String, severity: Severity, location: IssueLocation? = nil) {
            self.code = code
            self.severity = severity
            self.location = location
        }

        public init(_ issue: PromptIssue) {
            code = issue.code.rawValue
            severity = issue.severity == .warning ? .warning : .error
            switch issue.location {
            case .frontMatter(let line, let column): location = .frontMatter(line: Int64(line), column: Int64(column))
            case .body(let offset): location = .body(byteOffset: Int64(offset))
            case nil: location = nil
            }
        }

        public init(_ issue: SyncPathIssue) {
            code = issue.code.rawValue
            severity = .error
            location = .path(segment: issue.segmentIndex.map(Int64.init))
        }

        public static let schema: SyncAPISchema = .oneOf([schema(severity: .error), schema(severity: .warning)])

        static func schema(severity: Severity) -> SyncAPISchema {
            let codes = severity == .warning ? warningCodes : errorCodes
            return .object(fields: [
                .init("code", .string(.init(allowedValues: codes))),
                .init("severity", .constant(severity.rawValue)),
                .init("location", .reference("IssueLocation"), required: false)
            ])
        }

        private static let warningCodes = [PromptIssueCode.invalidPlaceholder, .unusedField, .groupPrivateRemoved].map(\.rawValue)
        private static let errorCodes = [
            PromptIssueCode.sourceTooLarge, .invalidUTF8, .unclosedFrontMatter, .invalidYAML,
            .frontMatterNotMapping, .duplicateKey, .anchorOrAlias, .mergeKey, .nonPortableScalar,
            .nonPortableTag, .invalidID, .invalidMetadataType, .invalidFormat, .unsupportedFormat,
            .invalidFieldName, .reservedFieldName, .invalidFieldDeclaration, .unknownFieldType,
            .invalidFieldProperty, .invalidFieldBoolean, .invalidFieldOptions, .invalidFieldDefault,
            .unbalancedOpener
        ].map(\.rawValue) + [
            SyncPathIssueCode.emptyPath, .normalizationFailed, .absolutePath, .pathTooLong,
            .emptySegment, .dotSegment, .hiddenDirectory, .backslash, .controlCharacter, .trailingDotOrSpace,
            .segmentTooLong, .invalidExtension, .reservedGroupsPrefix
        ].map(\.rawValue) + ["prompt.id_mismatch"]

        init(object: [String: APIValue]) throws {
            code = try object.string("code")
            severity = try object.rawEnum("severity")
            location = try object["location"].map { _ in try object.dto("location") }
        }

        var object: [String: APIValue] {
            var result: [String: APIValue] = ["code": .string(code), "severity": .string(severity.rawValue)]
            if let location { result["location"] = .dto(location) }
            return result
        }
    }
}
