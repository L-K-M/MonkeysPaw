import Hummingbird
import MonkeysPawCore

struct AccountRoutes {
    let accounts: AccountService
    let sessions: SessionService

    func add(to router: Router<ServerRequestContext>) {
        let protected = router.group("/api/v1").add(middleware: BearerMiddleware(sessions: sessions))
        protected.get("/me") { request, context in
            let response = try await accounts.me(context.authenticatedSession())
            return try context.responseEncoder.encode(response, from: request, context: context)
        }
        protected.post("/auth/logout") { request, context in
            try await sessions.logout(context.authenticatedSession())
            return try context.responseEncoder.encode(SyncAPI.EmptyResponse(), from: request, context: context)
        }
        protected.post("/auth/password") { request, context in
            // Decode directly so framework diagnostics cannot log secret-bearing input.
            let body = try await context.requestDecoder.decode(SyncAPI.PasswordChangeRequest.self, from: request, context: context)
            try await accounts.changePassword(body, session: context.authenticatedSession())
            return try context.responseEncoder.encode(SyncAPI.EmptyResponse(), from: request, context: context)
        }
        protected.delete("/me/devices/{id}") { request, context in
            guard let id = context.parameters.get("id") else { throw AccountError.malformedRequest }
            try await sessions.revokeDevice(id: id, session: context.authenticatedSession())
            return try context.responseEncoder.encode(SyncAPI.EmptyResponse(), from: request, context: context)
        }
    }
}
