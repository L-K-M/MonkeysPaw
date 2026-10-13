import Foundation
import MonkeysPawCore

struct PromptError: Error, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let response: SyncAPI.ErrorResponse
    init(_ response: SyncAPI.ErrorResponse) { self.response = response }
    var description: String { "PromptError(<redacted>)" }
    var debugDescription: String { description }
}

struct PromptService: Sendable {
    private let repository: PromptRepository
    private let clock: @Sendable () -> Date

    init(database: ServerDatabase, clock: @escaping @Sendable () -> Date = { Date() }) {
        repository = PromptRepository(database: database)
        self.clock = clock
    }

    func get(id: String, session: SessionIdentity) async throws -> SyncAPI.Prompt {
        try AccountValidation.dto(SyncAPI.IDPath(id: id))
        return try await repository.read { prompts, accounts, devices, groups in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            guard let head = try await prompts.head(id: id) else { throw AccountError.notFound }
            try await Self.requireAccess(head.identity, actor: actor, groups: groups, access: .read)
            guard head.deletedAt == nil else { throw AccountError.notFound }
            return head.prompt
        }
    }

    func put(id: String, request: SyncAPI.PutPromptRequest, session: SessionIdentity) async throws -> SyncAPI.WriteResponse {
        try AccountValidation.dto(SyncAPI.IDPath(id: id))
        try AccountValidation.dto(request)
        return try await repository.write { prompts, accounts, devices, groups in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            let current = try await prompts.head(id: id)
            if let current {
                // Proposed scope is untrusted: authorize the stored identity first.
                try await Self.requireAccess(current.identity, actor: actor, groups: groups, access: .write)
                if current.deletedAt != nil { throw PromptError(.deleted) }
                guard current.rev == request.baseRev, current.identity.scope == request.scope else {
                    throw PromptError(.conflict(head: current.conflictHead))
                }
                guard current.rev < Int64.max else { throw PromptPersistenceError.revisionExhausted }
            } else if let retired = try await prompts.retiredIdentity(id: id) {
                try await Self.requireAccess(retired, actor: actor, groups: groups, access: .write)
                throw PromptError(.deleted)
            } else {
                try await Self.requireAccess(.init(scope: request.scope, userID: actor.id), actor: actor, groups: groups, access: .write)
                guard request.baseRev == 0 else { throw AccountError.notFound }
            }

            let identity = current?.identity ?? PromptOwnership(scope: request.scope, userID: actor.id)
            let validated = try Self.validate(id: id, request: request)
            if let existing = try await prompts.livePrompt(identity: identity, pathKey: validated.path.pathKey, excludingID: id) {
                try await Self.requireAccess(existing.identity, actor: actor, groups: groups, access: .read)
                throw PromptError(.pathTaken(existing: existing.existing))
            }

            let at = ServerTimestamp.string(clock())
            let head = PromptRecord(id: id, identity: identity, path: validated.path.path, pathKey: validated.path.pathKey,
                                    content: validated.content, title: validated.title, rev: (current?.rev ?? 0) + 1,
                                    createdBy: current?.createdBy ?? actor.id, createdAt: current?.createdAt ?? at,
                                    updatedBy: actor.id, updatedAt: at, deletedAt: nil)
            if current == nil { try await prompts.insert(head) }
            else { try await prompts.update(head, baseRev: request.baseRev) }
            let origin: SyncAPI.RevisionOrigin
            switch request.origin ?? .edit {
            case .edit: origin = .edit
            case .llm: origin = .llm
            case .restore: origin = .restore
            }
            try await prompts.appendRevision(head, origin: origin)
            let seq = try await prompts.appendUpsert(head)
            return .init(rev: head.rev, seq: seq, warnings: validated.warnings.isEmpty ? nil : validated.warnings)
        }
    }

    func revisions(id: String, session: SessionIdentity) async throws -> SyncAPI.RevisionsResponse {
        try AccountValidation.dto(SyncAPI.IDPath(id: id))
        return try await repository.read { prompts, accounts, devices, groups in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            guard let head = try await prompts.head(id: id) else { throw AccountError.notFound }
            try await Self.requireAccess(head.identity, actor: actor, groups: groups, access: .read)
            let boundary = try await prompts.historyBoundary(head: head, readerID: actor.id)
            return try await .init(revisions: prompts.revisions(id: id, after: boundary))
        }
    }

    func revision(id: String, rev: Int64, session: SessionIdentity) async throws -> SyncAPI.Revision {
        try AccountValidation.dto(SyncAPI.RevisionPath(id: id, rev: rev))
        return try await repository.read { prompts, accounts, devices, groups in
            let actor = try await SessionService.requireSession(session, accounts: accounts, devices: devices)
            guard let head = try await prompts.head(id: id) else { throw AccountError.notFound }
            try await Self.requireAccess(head.identity, actor: actor, groups: groups, access: .read)
            let boundary = try await prompts.historyBoundary(head: head, readerID: actor.id)
            guard let revision = try await prompts.revision(id: id, rev: rev, after: boundary) else { throw AccountError.notFound }
            return revision
        }
    }

    private enum Access { case read, write }

    private static func requireAccess(
        _ identity: PromptOwnership, actor: AccountRecord, groups: GroupRepository.Transaction, access: Access
    ) async throws {
        switch identity {
        case .user(let ownerID):
            guard actor.id == ownerID else { throw AccountError.notFound }
        case .group(let groupID):
            guard try await groups.group(id: groupID) != nil,
                  let member = try await groups.member(groupID: groupID, userID: actor.id) else { throw AccountError.notFound }
            if access == .write && member.role == .viewer { throw AccountError.forbidden }
        }
    }

    private struct ValidatedPrompt {
        let path: SyncPath
        let content: String
        let title: String
        let warnings: [SyncAPI.Issue]
    }

    private static func validate(id: String, request: SyncAPI.PutPromptRequest) throws -> ValidatedPrompt {
        let path: SyncPath
        let isGroup: Bool
        switch request.scope {
        case .user: isGroup = false
        case .group: isGroup = true
        }
        do { path = try SyncPathValidator.validate(request.path, scope: isGroup ? .group : .user) }
        catch let issue as SyncPathIssue { throw PromptError(.validation(issues: [.init(issue)])) }

        let filename = (path.path as NSString).lastPathComponent
        let document = PromptCodec.parse(request.content, filename: filename)
        // CanonicalForm returns these validator warnings after this error gate.
        let errors = PromptValidator.validate(document).filter { $0.severity == .error }.map { SyncAPI.Issue($0) }
        if !errors.isEmpty { throw PromptError(.validation(issues: errors)) }
        guard document.frontMatter.id?.rawValue == id else {
            throw PromptError(.validation(issues: [.init(code: "prompt.id_mismatch", severity: .error)]))
        }

        // Invalid/future input was rejected above; serializer failures are internal.
        let canonical: CanonicalForm
        do {
            let bytes = Data(request.content.utf8)
            canonical = try isGroup ? CanonicalForm.group(bytes, filename: filename) : CanonicalForm.user(bytes, filename: filename)
        } catch PromptWriteError.sourceTooLarge {
            throw PromptError(.validation(issues: [.init(code: PromptIssueCode.sourceTooLarge.rawValue, severity: .error)]))
        }
        return .init(path: path, content: String(decoding: canonical.bytes, as: UTF8.self),
                     title: document.frontMatter.title, warnings: canonical.warnings.map { SyncAPI.Issue($0) })
    }
}
