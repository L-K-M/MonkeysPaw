import Hummingbird
import MonkeysPawCore

struct AdminUserRoutes {
    let admin: AdminUserService
    let sessions: SessionService

    func add(to router: Router<ServerRequestContext>) {
        let protected = router.group("/api/v1/admin/users").add(middleware: BearerMiddleware(sessions: sessions))
        protected.post { request, context in
            let body = try await context.requestDecoder.decode(SyncAPI.CreateUserRequest.self, from: request, context: context)
            let user = try await admin.create(body, session: context.authenticatedSession())
            return try context.responseEncoder.encode(user, from: request, context: context)
        }
        protected.patch("/{id}") { request, context in
            guard let id = context.parameters.get("id") else { throw AccountError.malformedRequest }
            let body = try await context.requestDecoder.decode(SyncAPI.UpdateUserRequest.self, from: request, context: context)
            let user = try await admin.update(id: id, request: body, session: context.authenticatedSession())
            return try context.responseEncoder.encode(user, from: request, context: context)
        }
    }
}
