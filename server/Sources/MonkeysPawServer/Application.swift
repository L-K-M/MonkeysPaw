import Hummingbird
import Logging

/// The server composition root; health needs no services or database yet (§8.3).
public func buildApplication(configuration: ServerConfiguration) -> some ApplicationProtocol {
    let router = Router()

    router.get("/api/health") { _, _ in
        HealthResponse(status: "ok", version: configuration.version)
    }

    return Application(
        router: router,
        configuration: .init(address: .hostname(configuration.httpHost, port: configuration.httpPort)),
        logger: Logger(label: "monkeyspaw-server")
    )
}

private struct HealthResponse: ResponseCodable {
    let status: String
    let version: String
}
