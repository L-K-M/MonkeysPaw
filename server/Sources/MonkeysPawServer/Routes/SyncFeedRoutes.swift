import Hummingbird
import MonkeysPawCore

struct SyncFeedRoutes {
    let feed: SyncFeedService
    let sessions: SessionService

    func add(to router: Router<ServerRequestContext>) {
        let protected = router.group("/api/v1/sync").add(middleware: BearerMiddleware(sessions: sessions))
        protected.post("/pull") { request, context in
            let body = try await context.requestDecoder.decode(SyncAPI.PullRequest.self, from: request, context: context)
            let response = try await feed.pull(request: body, session: context.authenticatedSession())
            return try context.responseEncoder.encode(response, from: request, context: context)
        }
    }
}
