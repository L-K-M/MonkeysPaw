import Foundation

/// Shared protocol boundary: never let transport diagnostics or error bodies
/// escape into Assistant outcomes. Clients do not retry failed requests.
enum AssistantHTTP {
    static func send(_ request: HTTPRequest, through transport: HTTPTransporting) async throws -> HTTPResponse {
        do {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            try Task.checkCancellation()
            guard response.body.count <= request.responseByteCap else { throw HTTPTransportError.responseTooLarge }

            switch response.statusCode {
            case 200: return response
            case 401, 403: throw AssistantError.authentication
            case 404: throw AssistantError.modelNotFound
            case 429: throw AssistantError.rateLimited(retryAfter: retryAfter(response.headers))
            case 529: throw AssistantError.overloaded
            default: throw AssistantError.providerFailure(statusCode: response.statusCode)
            }
        } catch let error as AssistantError {
            throw error
        } catch let error as HTTPTransportError {
            throw AssistantError.transport(error)
        } catch is CancellationError {
            throw AssistantError.transport(.cancelled)
        } catch {
            throw AssistantError.transport(.networkFailure)
        }
    }

    private static func retryAfter(_ headers: [String: String]) -> TimeInterval? {
        guard let raw = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) {
            guard let seconds = TimeInterval(value), seconds.isFinite else { return nil }
            return seconds
        }

        // shortcut: IMF-fixdate only; add obsolete date forms if an endpoint needs them.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
