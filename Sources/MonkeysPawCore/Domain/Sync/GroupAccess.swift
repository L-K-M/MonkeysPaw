import Foundation

public struct GroupAccessGroup: Equatable, Sendable {
    public let id: ULID
    public let name: String
    public let folder: RelativePath
    public let role: AssistantGroupRole
}

public enum PromptAccessState: Equatable, Sendable {
    case local
    case group(GroupAccessGroup)
    case unavailable

    public var assistantAccess: AssistantAccessState {
        switch self {
        case .local: return .privatePrompt
        case .group(let group): return .group(group.role)
        case .unavailable: return .unavailable
        }
    }

    public var readOnlyReason: PromptReadOnlyReason? {
        switch self {
        case .local: return nil
        case .group(let group): return group.role == .viewer ? .groupViewer : nil
        case .unavailable: return .groupUnavailable
        }
    }
}

/// Committed account/root projection. Documents and canonical bytes stay intact.
public struct GroupAccessSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let groups: [ULID: GroupAccessGroup]
    public let isBlocked: Bool
    let binding: SyncLibraryIdentity?
    let prompts: [PromptIdentity: SyncPromptState]
    let favorites: [PromptIdentity: Bool]
    let unavailableIDs: Set<PromptIdentity>
    let managesGroups: Bool

    static let local = GroupAccessSnapshot(generation: 0, groups: [:], isBlocked: false,
        binding: nil, prompts: [:], favorites: [:], unavailableIDs: [], managesGroups: false)

    public func access(at path: String, identity: PromptIdentity? = nil) -> PromptAccessState {
        guard !isBlocked else { return .unavailable }
        let destination = accessForPath(path)
        guard destination != .unavailable else { return .unavailable }
        if let identity {
            if case .group(let id)? = prompts[identity]?.scope {
                guard let source = groups[id] else { return .unavailable }
                // External moves do not grant either source or destination rights.
                if source.role == .viewer { return .group(source) }
                if case .group(let group) = destination, group.role == .viewer { return destination }
                return .group(source)
            }
            if unavailableIDs.contains(identity) { return .unavailable }
        }
        return destination
    }

    private func accessForPath(_ path: String) -> PromptAccessState {
        guard managesGroups else { return .local }
        let parts = path.unicodeScalars.split(separator: "/").map(String.init)
        guard parts.first.map(SyncPathCaseFold.fold) == SyncPathCaseFold.fold("Groups") else { return .local }
        guard parts.count >= 3,
              let group = groups.values.first(where: {
                  SyncPathCaseFold.fold($0.folder.string) == SyncPathCaseFold.fold(parts[1])
              }) else { return .unavailable }
        return .group(group)
    }

    func favorite(for entry: LibraryEntry) -> Bool {
        switch access(at: entry.relativePath, identity: entry.identity) {
        case .local: return entry.document.frontMatter.favorite
        case .group: return favorites[entry.identity] == true
        case .unavailable: return false
        }
    }

    func samePolicy(as other: Self) -> Bool {
        binding == other.binding && groups == other.groups && isBlocked == other.isBlocked
            && unavailableIDs == other.unavailableIDs && managesGroups == other.managesGroups
            && prompts.mapValues(\.scope) == other.prompts.mapValues(\.scope)
    }
}

public enum PromptChangeOrigin: Equatable, Sendable {
    case external, local, sync, access, favorite
}
