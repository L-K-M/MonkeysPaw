import Foundation

/// A stable incarnation makes an empty folder's replay distinguishable from
/// an unrelated directory created at the same spelling after interruption.
struct SyncDirectoryEdit: Codable, CustomStringConvertible, CustomReflectable {
    enum Kind: String, Codable { case rename, removeEmpty }
    let id: UUID
    let kind: Kind
    let source: RelativePath
    let identity: FileStamp
    let destination: RelativePath?
    let intermediate: RelativePath?
    let localFiles: [SyncLibraryFile]
    var description: String { "<sync directory edit>" }
    var customMirror: Mirror { Mirror(self, children: ["edit": description]) }

    private enum CodingKeys: String, CodingKey { case id, kind, source, identity, destination, intermediate, localFiles }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        id = try value.decode(UUID.self, forKey: .id)
        kind = try value.decode(Kind.self, forKey: .kind)
        source = RelativePath(try value.decode(String.self, forKey: .source))
        identity = try value.decode(FileStamp.self, forKey: .identity)
        destination = try value.decodeIfPresent(String.self, forKey: .destination).map { RelativePath($0) }
        intermediate = try value.decodeIfPresent(String.self, forKey: .intermediate).map { RelativePath($0) }
        localFiles = try value.decodeIfPresent([SyncLibraryFile].self, forKey: .localFiles) ?? []
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(id, forKey: .id)
        try value.encode(kind, forKey: .kind)
        try value.encode(source.string, forKey: .source)
        try value.encode(identity, forKey: .identity)
        try value.encode(destination?.string, forKey: .destination)
        try value.encode(intermediate?.string, forKey: .intermediate)
        try value.encode(localFiles, forKey: .localFiles)
    }

    init(id: UUID = UUID(), removing source: RelativePath, identity: FileStamp) throws {
        self.id = id
        kind = .removeEmpty
        self.source = source
        self.identity = identity
        destination = nil
        intermediate = nil
        localFiles = []
        try validate()
    }

    init(id: UUID = UUID(), renaming source: RelativePath, identity: FileStamp,
         to destination: RelativePath, intermediate: RelativePath? = nil, localFiles: [SyncLibraryFile] = []) throws {
        self.id = id
        kind = .rename
        self.source = source
        self.identity = identity
        self.destination = destination
        self.intermediate = intermediate
        self.localFiles = localFiles
        try validate()
    }

    func validate() throws {
        try FileStorePath.validate(source.string)
        let parts = source.string.utf8.split(separator: 47)
        guard !parts.isEmpty, SyncPathCaseFold.fold(String(decoding: parts[0], as: UTF8.self)) == "groups" else {
            throw SyncError.invalidState
        }
        if kind == .removeEmpty {
            guard destination == nil, intermediate == nil, localFiles.isEmpty, source.string != "Groups" else { throw SyncError.invalidState }
            return
        }
        guard let destination, source != destination, parts.count == 2,
              source.string.hasPrefix("Groups/"), destination.string.hasPrefix("Groups/"),
              destination.string.utf8.split(separator: 47).count == 2 else { throw SyncError.invalidState }
        try SyncIdentifiers.folder(String(decoding: destination.string.utf8.dropFirst("Groups/".utf8.count), as: UTF8.self))
        if let intermediate {
            try FileStorePath.validate(intermediate.string)
            guard intermediate.string.hasPrefix("Groups/_sync-"),
                  intermediate.string.utf8.split(separator: 47).count == 2,
                  intermediate != source, intermediate != destination,
                  try SyncNaming.pathKey(intermediate) != SyncNaming.pathKey(source),
                  try SyncNaming.pathKey(intermediate) != SyncNaming.pathKey(destination) else {
                throw SyncError.invalidState
            }
        } else if try SyncNaming.pathKey(source) == SyncNaming.pathKey(destination) {
            throw SyncError.invalidState // Case-only renames always take two steps.
        }
        guard Set(localFiles.map { RelativePath($0.path) }).count == localFiles.count else { throw SyncError.invalidState }
        for file in localFiles {
            try file.validate()
            guard case .local = try file.identity, file.path.utf8.starts(with: (source.string + "/").utf8) else {
                throw SyncError.invalidState
            }
            try FileStorePath.validate(relocatedPath(for: file).string)
        }
    }

    func relocatedPath(for file: SyncLibraryFile) -> RelativePath {
        RelativePath((destination ?? source).string + String(decoding: file.path.utf8.dropFirst(source.string.utf8.count), as: UTF8.self))
    }

    func identityTransitions() throws -> [SyncIdentityTransition] {
        try localFiles.map { try SyncIdentityTransition(from: $0.identity,
            to: PromptIdentity(path: relocatedPath(for: $0).string, id: nil)) }
    }
}

struct SyncDirectoryStep: Codable {
    let edit: SyncDirectoryEdit
    let migrations: [SyncKeyedMigration]
    var started = false
    var completed = false

    init(edit: SyncDirectoryEdit, migrations: [SyncKeyedMigration] = []) {
        self.edit = edit
        self.migrations = migrations
    }

    private enum CodingKeys: String, CodingKey { case edit, migrations, started, completed }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        edit = try value.decode(SyncDirectoryEdit.self, forKey: .edit)
        migrations = try value.decodeIfPresent([SyncKeyedMigration].self, forKey: .migrations) ?? []
        started = try value.decode(Bool.self, forKey: .started)
        completed = try value.decode(Bool.self, forKey: .completed)
    }
}
