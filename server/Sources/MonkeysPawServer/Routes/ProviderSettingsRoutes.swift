import Hummingbird
import MonkeysPawCore

/// §26 S1: authenticated per-account provider-settings synchronization.
struct ProviderSettingsRoutes {
    let settings: ProviderSettingsService
    let sessions: SessionService

    func add(to router: Router<ServerRequestContext>) {
        let protected = router.group("/api/v1").add(middleware: BearerMiddleware(sessions: sessions))
        protected.get("/me/provider-settings") { request, context in
            let response = try await settings.document(session: context.authenticatedSession())
            return try context.responseEncoder.encode(response, from: request, context: context)
        }
        protected.put("/me/provider-settings") { request, context in
            // Decode directly so framework diagnostics cannot log secret-bearing input.
            let body = try await context.requestDecoder.decode(SyncAPI.PutProviderSettingsRequest.self, from: request, context: context)
            let response = try await settings.put(body, session: context.authenticatedSession())
            return try context.responseEncoder.encode(response, from: request, context: context)
        }
    }
}
