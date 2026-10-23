import Foundation

extension SyncAPI {
    /// §26 S1/S5: `document` is opaque base64url ciphertext the server never
    /// decodes; `rev` is an ordering cursor, not a write precondition.
    public struct ProviderSettingsDocument: APIObjectDTO, Equatable {
        public let rev: Int64
        public let document: String?
        public let updatedAt: String?

        public init(rev: Int64, document: String?, updatedAt: String?) {
            self.rev = rev
            self.document = document
            self.updatedAt = updatedAt
        }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("rev", .baseRev),
            .init("document", .nullable(.providerSyncDocument)),
            .init("updated_at", .nullable(.timestamp))
        ])

        init(object: [String: APIValue]) throws {
            rev = try object.integer("rev")
            document = try object.optionalString("document")
            updatedAt = try object.optionalString("updated_at")
        }

        var object: [String: APIValue] {
            ["rev": .integer(rev), "document": .nullableString(document),
             "updated_at": .nullableString(updatedAt)]
        }
    }

    /// Last writer wins: the request carries no precondition.
    public struct PutProviderSettingsRequest: APIObjectDTO, Equatable {
        public let document: String

        public init(document: String) { self.document = document }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("document", .providerSyncDocument)
        ])

        init(object: [String: APIValue]) throws {
            document = try object.string("document")
        }

        var object: [String: APIValue] { ["document": .string(document)] }
    }

    public struct ProviderSettingsResponse: APIObjectDTO, Equatable {
        public let rev: Int64

        public init(rev: Int64) { self.rev = rev }

        public static let schema: SyncAPISchema = .object(fields: [
            .init("rev", .rev)
        ])

        init(object: [String: APIValue]) throws {
            rev = try object.integer("rev")
        }

        var object: [String: APIValue] { ["rev": .integer(rev)] }
    }
}

extension SyncAPISchema {
    static let providerSyncDocument: Self = .string(.init(minimumLength: 1,
        maximumLength: Limits.providerSyncDocumentMaxBase64,
        pattern: "^[A-Za-z0-9_-]+$"))
}
