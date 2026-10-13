import Hummingbird
import Logging
import MonkeysPawCore

struct APIErrorMiddleware: RouterMiddleware {
    func handle(
        _ request: Request, context: ServerRequestContext,
        next: (Request, ServerRequestContext) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as PromptError {
            context.logger.debug("API request failed", metadata: [
                "status": .string(String(error.response.httpStatus)), "method": .string(request.method.rawValue)
            ])
            var response = try context.responseEncoder.encode(error.response, from: request, context: context)
            response.status = .init(code: error.response.httpStatus)
            return response
        } catch {
            let code: SyncAPI.FailureCode
            var retryAfter: SyncAPI.RetryAfter?
            var unexpectedType: String?
            switch error {
            case LoginError.rateLimited(let retry):
                code = .rateLimited
                retryAfter = retry
            case AccountError.unauthorized: code = .unauthorized
            case AccountError.forbidden: code = .forbidden
            case AccountError.notFound: code = .notFound
            case AccountError.malformedRequest, is DecodingError: code = .malformedRequest
            case let error as any HTTPResponseError where error.status == .contentTooLarge: code = .envelopeTooLarge
            case let error as any HTTPResponseError where error.status == .notFound: code = .notFound
            default:
                // Error descriptions can contain credentials, paths or SQL;
                // only the type name is logged.
                unexpectedType = String(describing: type(of: error))
                code = .internalError
            }
            // One entry per failed request: error level for unexpected errors.
            var metadata: Logger.Metadata = [
                "code": .string(code.rawValue), "status": .string(String(code.httpStatus)), "method": .string(request.method.rawValue)
            ]
            if let unexpectedType { metadata["error_type"] = .string(unexpectedType) }
            context.logger.log(level: code == .internalError ? .error : .debug, "API request failed", metadata: metadata)
            var response = try context.responseEncoder.encode(SyncAPI.ErrorResponse.failure(code), from: request, context: context)
            response.status = .init(code: code.httpStatus)
            if code == .unauthorized { response.headers[.wwwAuthenticate] = "Bearer" }
            if let retryAfter { response.headers[.retryAfter] = retryAfter.headerValue }
            return response
        }
    }
}
