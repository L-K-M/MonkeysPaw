import Foundation
import MonkeysPawCore

enum SchemaRenderer {
    private static let identifierBase = "https://lkmc.ch/monkeyspaw/sync-api/schema/"
    private static let ulidPattern = "[0-7][0-9A-HJKMNP-TV-Z]{25}"

    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for description in SyncAPI.schemas.sorted(by: { $0.name < $1.name }) {
            var schema = render(description.schema)
            schema["$schema"] = SyncAPI.schemaDialect
            schema["$id"] = identifierBase + description.name + ".json"
            schema["title"] = description.name

            var data = try JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(0x0A)
            try data.write(to: directory.appendingPathComponent(description.name + ".json"), options: .atomic)
        }
        try Data(readme.utf8).write(to: directory.appendingPathComponent("README.md"), options: .atomic)
    }

    private static func render(_ schema: SyncAPISchema) -> [String: Any] {
        switch schema {
        case .string(let constraints): return renderString(constraints)
        case .integer(let minimum, let maximum):
            return ["type": "integer", "minimum": minimum, "maximum": maximum]
        case .boolean: return ["type": "boolean"]
        case .null: return ["type": "null"]
        case .array(let items, let minimum, let maximum, let unique):
            var result: [String: Any] = ["type": "array", "items": render(items)]
            if minimum > 0 { result["minItems"] = minimum }
            if let maximum { result["maxItems"] = maximum }
            if unique { result["uniqueItems"] = true }
            return result
        case .object(let fields, let minimum, let rules):
            var result: [String: Any] = [
                "type": "object",
                "properties": Dictionary(uniqueKeysWithValues: fields.map { ($0.name, render($0.schema)) }),
                "required": fields.filter(\.required).map(\.name).sorted(),
                "additionalProperties": false
            ]
            if minimum > 0 { result["minProperties"] = minimum }
            if !rules.isEmpty { result["x-syncapi-rules"] = rules.map(ruleName) }
            return result
        case .map(let keys, let values):
            return ["type": "object", "propertyNames": renderString(keys), "additionalProperties": render(values)]
        case .oneOf(let alternatives): return ["oneOf": alternatives.map(render)]
        case .reference(let name): return ["$ref": name + ".json"]
        }
    }

    private static func renderString(_ constraints: SyncAPIString) -> [String: Any] {
        var result: [String: Any] = ["type": "string"]
        if constraints.minimumLength > 0 { result["minLength"] = constraints.minimumLength }
        if let maximum = constraints.maximumLength { result["maxLength"] = maximum }
        if let maximum = constraints.maximumUTF8Bytes {
            result["maxLength"] = min(constraints.maximumLength ?? maximum, maximum)
            result["x-max-utf8-bytes"] = maximum
        }
        if let values = constraints.allowedValues {
            if values.count == 1 { result["const"] = values[0] }
            else { result["enum"] = values.sorted() }
        }

        var patterns = constraints.pattern.map { [$0] } ?? []
        if let format = constraints.format {
            result["format"] = format == .utcMilliseconds ? "date-time" : format.rawValue
            switch format {
            case .ulid: patterns.append(ulidPattern)
            case .uuid: patterns.append("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
            case .scopeKey: patterns.append("(user|group):" + ulidPattern)
            case .utcMilliseconds:
                patterns.append("(?!0000)[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]\\.[0-9]{3}Z")
                result["x-syncapi-format"] = format.rawValue
            }
        }
        if patterns.count == 1 { result["pattern"] = fullMatch(patterns[0]) }
        else if !patterns.isEmpty { result["allOf"] = patterns.map { ["pattern": fullMatch($0)] } }
        return result
    }

    private static func fullMatch(_ pattern: String) -> String {
        // JSON Schema searches for a match; `$` alone also admits a final newline.
        var body = pattern
        if body.hasPrefix("^"), body.hasSuffix("$"),
           body.dropLast().reversed().prefix(while: { $0 == "\\" }).count.isMultiple(of: 2) {
            body = String(body.dropFirst().dropLast())
        }
        return "^(?:" + body + ")(?![\\s\\S])"
    }

    private static func ruleName(_ rule: SyncAPIRule) -> String {
        switch rule {
        case .groupScopeKey: return "group-scope-key"
        case .syncPage: return "sync-page"
        case .pullItemBudget: return "pull-item-budget"
        }
    }

    private static let readme = """
    # SyncAPI JSON Schemas

    Generated by `server/Sources/dump-schema/` from `SyncAPI.schemas` in Core.
    One `<schemaName>.json` per named contract, including enums, parameters and
    the JSON-integer representation of the Retry-After header. HTTP routing and
    status/header requirements remain in `SyncAPI.endpoints`, §8 and the DTO fixtures.

    From the repository root, regenerate and check all files (including this README):

    ```sh
    swift run --package-path server dump-schema spec/schema
    schema_dir=$(mktemp -d)
    trap 'rm -rf "$schema_dir"' EXIT
    swift run --package-path server dump-schema "$schema_dir"
    diff -ru spec/schema "$schema_dir"
    ```

    On the Paseo host, substitute `/home/paseo/.local/bin/swift64` for `swift`.
    Commit regenerated files together with contract changes. Remove obsolete
    schema files when a contract is removed or renamed; regeneration does not
    delete existing files. CI compares a fresh output tree recursively, detecting
    changed, missing and extra files, including untracked files.

    The dialect is [JSON Schema 2020-12](https://json-schema.org/draft/2020-12/schema).
    Keys and required-property names are sorted; files end with one newline.
    CI's Swift 6.4 Linux output is the baseline; byte equality on Darwin is not
    yet verified. Patterns require lookahead support; consumers with a restricted
    regex engine must supply equivalent spelling checks.
    `$id` URLs are stable logical identifiers, not network dependencies. Register
    the local files under their `$id`s to resolve sibling `$ref`s offline. Use
    exact integers: bounds include Int64.max, beyond binary64's exact range.
    Closed union branches use required const/enum discriminators (`scope`, `kind`,
    `severity`, `code`) or distinct required fields. Omission and null are separate:
    only an explicit null branch admits null, independently of `required`.

    Patterns assert full spelling, including uppercase Crockford ULIDs, lowercase
    hyphenated UUIDs and UTC timestamps with exactly three fractional digits.
    Every UTF-8 byte cap also supplies a standard `maxLength` at most that cap
    (72 for passwords, 262144 for content, 1024 for paths). UTF-8 bytes are at
    least the Unicode scalar count, so this backstop never rejects a byte-valid
    string. Generic validators reject excess scalars; exact byte enforcement
    still needs `x-max-utf8-bytes`, including multi-byte strings below `maxLength`.
    `format` is an annotation by default in this dialect. The following extensions
    require application validation in addition to a generic schema engine:

    | Annotation | Required check |
    |---|---|
    | `x-max-utf8-bytes` | Bound decoded string UTF-8 bytes, independently of JSON escaping or Unicode scalar length. |
    | `x-syncapi-format: utc-milliseconds` | Gregorian calendar validity, years 0001–9999; pattern already enforces UTC, precision and time ranges. |
    | `x-syncapi-rules: [group-scope-key]` | `key == "group:" + group_id`. |
    | `x-syncapi-rules: [sync-page]` | Item seq ≤ head; snapshots contain only upserts at exactly head; delta seqs are positive. |
    | `x-syncapi-rules: [pull-item-budget]` | At most 200 items across scopes, unique scope keys, exactly one user scope, no visible/removed overlap. |

    Server Schema tests invoke the executable, check byte determinism and catalog
    coverage, and compare every DTO fixture with strict Codable using a small
    validator for emitted keywords plus these extensions. It is a contract test
    helper, not a general JSON Schema implementation. Canonical JSON/duplicate-key
    boundaries are documented in `spec/README.md`; semantic prompt/path validation
    and HTTP envelope limits remain service/transport responsibilities.

    """
}
