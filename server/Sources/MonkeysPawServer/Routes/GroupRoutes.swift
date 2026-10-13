import Hummingbird
import MonkeysPawCore

struct GroupRoutes {
    let groups: GroupService
    let sessions: SessionService

    func add(to router: Router<ServerRequestContext>) {
        let protected = router.group("/api/v1/groups").add(middleware: BearerMiddleware(sessions: sessions))
        protected.post { request, context in
            let body = try await context.requestDecoder.decode(SyncAPI.CreateGroupRequest.self, from: request, context: context)
            let group = try await groups.create(body, session: context.authenticatedSession())
            return try context.responseEncoder.encode(group, from: request, context: context)
        }
        protected.patch("/{id}") { request, context in
            guard let id = context.parameters.get("id") else { throw AccountError.malformedRequest }
            let body = try await context.requestDecoder.decode(SyncAPI.RenameGroupRequest.self, from: request, context: context)
            let group = try await groups.rename(id: id, request: body, session: context.authenticatedSession())
            return try context.responseEncoder.encode(group, from: request, context: context)
        }
        protected.delete("/{id}") { request, context in
            guard let id = context.parameters.get("id") else { throw AccountError.malformedRequest }
            try await groups.delete(id: id, session: context.authenticatedSession())
            return try context.responseEncoder.encode(SyncAPI.EmptyResponse(), from: request, context: context)
        }
        protected.get("/{id}/members") { request, context in
            guard let id = context.parameters.get("id") else { throw AccountError.malformedRequest }
            let members = try await groups.members(id: id, session: context.authenticatedSession())
            return try context.responseEncoder.encode(members, from: request, context: context)
        }
        protected.put("/{id}/members/{user_id}") { request, context in
            guard let id = context.parameters.get("id"), let userID = context.parameters.get("user_id") else { throw AccountError.malformedRequest }
            let body = try await context.requestDecoder.decode(SyncAPI.MembershipRequest.self, from: request, context: context)
            let member = try await groups.upsertMember(id: id, userID: userID, request: body, session: context.authenticatedSession())
            return try context.responseEncoder.encode(member, from: request, context: context)
        }
        protected.delete("/{id}/members/{user_id}") { request, context in
            guard let id = context.parameters.get("id"), let userID = context.parameters.get("user_id") else { throw AccountError.malformedRequest }
            try await groups.removeMember(id: id, userID: userID, session: context.authenticatedSession())
            return try context.responseEncoder.encode(SyncAPI.EmptyResponse(), from: request, context: context)
        }
    }
}
