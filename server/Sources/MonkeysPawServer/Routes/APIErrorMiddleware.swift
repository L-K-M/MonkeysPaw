import Hummingbird
import MonkeysPawCore

struct APIErrorMiddleware: RouterMiddleware {
    func handle(
        _ request: Request, context: ServerRequestContext,
        next: (Request, ServerRequestContext) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch {
            let code: SyncAPI.FailureCode
            switch error {
            case AccountError.unauthorized: code = .unauthorized
            case AccountError.notFound: code = .notFound
            case AccountError.malformedRequest, is DecodingError: code = .malformedRequest
            case let error as any HTTPResponseError where error.status == .contentTooLarge: code = .envelopeTooLarge
            case let error as any HTTPResponseError where error.status == .notFound: code = .notFound
            default: code = .internalError
            }
            var response = try context.responseEncoder.encode(SyncAPI.ErrorResponse.failure(code), from: request, context: context)
            response.status = .init(code: code.httpStatus)
            if code == .unauthorized { response.headers[.wwwAuthenticate] = "Bearer" }
            return response
        }
    }
}
