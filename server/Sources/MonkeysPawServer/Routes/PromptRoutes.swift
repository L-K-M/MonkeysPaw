import Hummingbird
import MonkeysPawCore

struct PromptRoutes {
    let prompts: PromptService
    let sessions: SessionService

    func add(to router: Router<ServerRequestContext>) {
        let protected = router.group("/api/v1/prompts").add(middleware: BearerMiddleware(sessions: sessions))
        protected.get("/{id}") { request, context in
            guard let id = context.parameters.get("id") else { throw AccountError.malformedRequest }
            let prompt = try await prompts.get(id: id, session: context.authenticatedSession())
            return try context.responseEncoder.encode(prompt, from: request, context: context)
        }
        protected.put("/{id}") { request, context in
            guard let id = context.parameters.get("id") else { throw AccountError.malformedRequest }
            let body = try await context.requestDecoder.decode(SyncAPI.PutPromptRequest.self, from: request, context: context)
            let write = try await prompts.put(id: id, request: body, session: context.authenticatedSession())
            return try context.responseEncoder.encode(write, from: request, context: context)
        }
        protected.delete("/{id}") { request, context in
            let query = request.uri.queryParameters
            guard let id = context.parameters.get("id"), query.count == 1, let value = query["base_rev"],
                  let rev = Int64(value), String(rev) == String(value) else { throw AccountError.malformedRequest }
            let write = try await prompts.delete(id: id, query: .init(baseRev: rev), session: context.authenticatedSession())
            return try context.responseEncoder.encode(write, from: request, context: context)
        }
        protected.post("/{id}/move") { request, context in
            guard let id = context.parameters.get("id") else { throw AccountError.malformedRequest }
            let body = try await context.requestDecoder.decode(SyncAPI.MovePromptRequest.self, from: request, context: context)
            let write = try await prompts.move(id: id, request: body, session: context.authenticatedSession())
            return try context.responseEncoder.encode(write, from: request, context: context)
        }
        protected.get("/{id}/revisions") { request, context in
            guard let id = context.parameters.get("id") else { throw AccountError.malformedRequest }
            let revisions = try await prompts.revisions(id: id, session: context.authenticatedSession())
            return try context.responseEncoder.encode(revisions, from: request, context: context)
        }
        protected.get("/{id}/revisions/{rev}") { request, context in
            guard let id = context.parameters.get("id"), let value = context.parameters.get("rev"),
                  let rev = Int64(value), rev > 0, String(rev) == value else { throw AccountError.malformedRequest }
            let revision = try await prompts.revision(id: id, rev: rev, session: context.authenticatedSession())
            return try context.responseEncoder.encode(revision, from: request, context: context)
        }
    }
}
