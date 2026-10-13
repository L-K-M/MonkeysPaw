import Foundation
import Yams

enum SyncConflictMetadataError: Error, Equatable {
    case invalidPrompt
    case invalidOrigin
}

/// These unknown front-matter keys travel in private content, not WriteOrigin.
enum SyncConflictMetadata {
    static let conflictKey = "x-monkeyspaw-conflict-of"
    static let rescuedKey = "x-monkeyspaw-rescued"

    static func origin(in document: PromptDocument) throws -> SyncPromptOrigin? {
        guard document.canRender else { throw SyncConflictMetadataError.invalidPrompt }
        let mapping = document.preservedHeader?.mapping
        let conflict = mapping?.first { PortableYAML.string($0.key) == conflictKey }?.value
        let rescued = mapping?.first { PortableYAML.string($0.key) == rescuedKey }?.value
        var original: ULID?
        if let conflict {
            guard let raw = PortableYAML.string(conflict), let id = try? SyncIdentifiers.ulid(raw),
                  id != document.frontMatter.id else { throw SyncConflictMetadataError.invalidOrigin }
            original = id
        }
        var isRescued = false
        if let rescued {
            guard let value = PortableYAML.boolean(rescued) else { throw SyncConflictMetadataError.invalidOrigin }
            isRescued = value
        }
        guard original == nil || !isRescued else { throw SyncConflictMetadataError.invalidOrigin }
        if let original { return .conflictOf(original) }
        return isRescued ? .rescued : nil
    }

    /// Group metadata is still validated, but only private prompts have origin.
    static func origin(in bytes: Data, filename: String, scope: SyncPathValidator.Scope = .user) throws -> SyncPromptOrigin? {
        let value = try origin(in: PromptCodec.parseFile(bytes, filename: filename))
        return scope == .user ? value : nil
    }

    static func hasInvalidOrigin(in document: PromptDocument) -> Bool {
        do { _ = try origin(in: document); return false }
        catch SyncConflictMetadataError.invalidOrigin { return true }
        catch { return false }
    }

    static func settingOrigin(_ origin: SyncPromptOrigin?, in bytes: Data, filename: String) throws -> Data {
        let document = PromptCodec.parseFile(bytes, filename: filename)
        let existing = try self.origin(in: document)
        if let origin, existing == origin { return bytes }
        if origin == nil, document.preservedHeader?.mapping?.contains(where: {
            let key = PortableYAML.string($0.key)
            return key == conflictKey || key == rescuedKey
        }) != true { return bytes }
        if case .conflictOf(let id) = origin, id == document.frontMatter.id {
            throw SyncConflictMetadataError.invalidOrigin
        }
        var pairs = document.preservedHeader?.mapping?.filter {
            let key = PortableYAML.string($0.key)
            return key != conflictKey && key != rescuedKey
        }.map { ($0.key, $0.value) } ?? []
        switch origin {
        case .conflictOf(let id): pairs.append((Node(conflictKey, Tag(.str)), Node(id.rawValue, Tag(.str))))
        case .rescued: pairs.append((Node(rescuedKey, Tag(.str)), Node("true", Tag(.bool))))
        case nil: break
        }
        // Preserve the body and all other typed metadata through the house writer.
        let updated = PromptDocument(source: document.source, body: document.body, frontMatter: document.frontMatter,
            template: document.template, preservedHeader: Node(pairs, Tag(.map), .block),
            decodingIssues: document.decodingIssues, declarationLocations: document.declarationLocations)
        let result = Data(try PromptCodec.write(updated).utf8)
        guard try self.origin(in: result, filename: filename) == origin else {
            throw SyncConflictMetadataError.invalidOrigin
        }
        return result
    }

    /// Compare generated full bytes when reusing a copy, including its own ID.
    /// Keeping an existing root origin avoids a conflict-of-conflict chain.
    static func copyBytes(_ file: SyncLibraryFile, freshID: ULID, origin: SyncPromptOrigin,
                          filename: String) throws -> Data {
        let document = PromptCodec.parseFile(file.bytes, filename: LibraryPath.filename(file.path))
        _ = try self.origin(in: document)
        guard freshID != document.frontMatter.id else { throw SyncError.invalidState }
        let copy = try ImportMapper.replacingIdentity(freshID, in: document, filename: filename).document
        return try settingOrigin(origin, in: Data(copy.source.utf8), filename: filename)
    }
}
