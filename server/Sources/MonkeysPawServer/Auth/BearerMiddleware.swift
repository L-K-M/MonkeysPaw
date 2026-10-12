import Hummingbird
import MonkeysPawCore

struct ServerRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    var session: SessionIdentity?
    var maxUploadSize: Int { SyncAPI.requestEnvelopeMaxBytes }

    init(source: Source) { coreContext = .init(source: source) }

    func authenticatedSession() throws -> SessionIdentity {
        guard let session else { throw AccountError.unauthorized }
        return session
    }
}

struct BearerMiddleware: RouterMiddleware {
    let sessions: SessionService

    func handle(
        _ request: Request, context: ServerRequestContext,
        next: (Request, ServerRequestContext) async throws -> Response
    ) async throws -> Response {
        guard request.headers[values: .authorization].count == 1,
              let header = request.headers[.authorization] else { throw AccountError.unauthorized }
        let parts = header.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "bearer", !parts[1].isEmpty else {
            throw AccountError.unauthorized
        }
        var context = context
        context.session = try await sessions.authenticate(token: String(parts[1]))
        return try await next(request, context)
    }
}
