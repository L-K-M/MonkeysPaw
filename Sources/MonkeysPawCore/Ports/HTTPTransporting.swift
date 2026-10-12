import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
}

/// Foundation-only data: no URLRequest/HTTPURLResponse or networking imports.
/// An absolute monotonic deadline lets format probes share one action budget.
public struct HTTPRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let url: URL
    public let method: HTTPMethod
    public let headers: [String: String]
    public let body: Data?
    public let requestByteCap: Int
    public let responseByteCap: Int
    public let deadline: ContinuousClock.Instant

    public init(url: URL, method: HTTPMethod, headers: [String: String] = [:], body: Data? = nil,
                requestByteCap: Int = Limits.httpRequestCap, responseByteCap: Int = Limits.responseCap,
                deadline: ContinuousClock.Instant) throws {
        guard requestByteCap > 0, responseByteCap > 0 else { throw HTTPTransportError.invalidRequest }
        guard (body?.count ?? 0) <= requestByteCap else { throw HTTPTransportError.requestTooLarge }

        // Match the adapter's rules before any transport can consume headers.
        let token = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        var names = Set<String>()
        for (name, value) in headers {
            guard !name.isEmpty, name.utf8.allSatisfy(token.contains),
                  names.insert(name.lowercased()).inserted,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw HTTPTransportError.invalidRequest
            }
        }

        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.requestByteCap = requestByteCap
        self.responseByteCap = responseByteCap
        self.deadline = deadline
    }

    public var description: String { "<HTTP request redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["request": description]) }
}

public struct HTTPResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var description: String { "<HTTP response redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["response": description]) }
}

public enum HTTPTransportError: String, Error, Equatable, Sendable {
    case invalidRequest
    case invalidURL
    case insecureURL
    case credentialsInURL
    case redirectRefused
    case requestTooLarge
    case responseTooLarge
    case deadlineExceeded
    case cancelled
    case invalidResponse
    case networkFailure
}

/// One non-streaming request, no redirects or retries. The adapter validates
/// HTTPS except loopback and no userinfo; enforces caps during receipt and the
/// deadline across the entire operation; and propagates Task cancellation to
/// the HTTP task. It throws typed errors without provider bodies. Responses,
/// including errors, remain capped data for the protocol layer to interpret.
/// The portable URLSession adapter belongs to A2 (§19 B1).
public protocol HTTPTransporting: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
