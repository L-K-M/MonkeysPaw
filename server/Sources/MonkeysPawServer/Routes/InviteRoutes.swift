import Hummingbird
import MonkeysPawCore

struct InviteRoutes {
    let invites: InviteService
    let sessions: SessionService

    func add(to router: Router<ServerRequestContext>) {
        router.post("/api/v1/auth/register") { request, context in
            let body = try await context.requestDecoder.decode(SyncAPI.RegisterRequest.self, from: request, context: context)
            let issued = try await invites.register(body)
            return try context.responseEncoder.encode(issued.response, from: request, context: context)
        }
        let protected = router.group("/api/v1").add(middleware: BearerMiddleware(sessions: sessions))
        protected.post("/groups/{id}/invites") { request, context in
            guard let id = context.parameters.get("id") else { throw AccountError.malformedRequest }
            let body = try await context.requestDecoder.decode(SyncAPI.GroupInviteRequest.self, from: request, context: context)
            let issued = try await invites.createGroup(id: id, request: body, session: context.authenticatedSession())
            return try context.responseEncoder.encode(issued.response, from: request, context: context)
        }
        protected.post("/admin/invites") { request, context in
            let body = try await context.requestDecoder.decode(SyncAPI.AdminInviteRequest.self, from: request, context: context)
            let issued = try await invites.createAdmin(body, session: context.authenticatedSession())
            return try context.responseEncoder.encode(issued.response, from: request, context: context)
        }
        protected.post("/groups/join") { request, context in
            let body = try await context.requestDecoder.decode(SyncAPI.JoinGroupRequest.self, from: request, context: context)
            let group = try await invites.join(body, session: context.authenticatedSession())
            return try context.responseEncoder.encode(group, from: request, context: context)
        }
    }
}
