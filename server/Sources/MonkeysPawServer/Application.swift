import Hummingbird
import Logging

/// Health-only composition is also used by the liveness tests.
public func buildApplication(configuration: ServerConfiguration) -> some ApplicationProtocol {
    makeApplication(configuration: configuration)
}

public func buildApplication(configuration: ServerConfiguration, database: ServerDatabase) -> some ApplicationProtocol {
    makeApplication(configuration: configuration, accounts: AccountService(database: database),
                    sessions: SessionService(database: database))
}

func makeApplication(
    configuration: ServerConfiguration, accounts: AccountService? = nil, sessions: SessionService? = nil
) -> some ApplicationProtocol {
    let router = Router(context: ServerRequestContext.self)
    router.add(middleware: APIErrorMiddleware())

    router.get("/api/health") { _, _ in
        HealthResponse(status: "ok", version: configuration.version)
    }

    if let accounts, let sessions {
        AccountRoutes(accounts: accounts, sessions: sessions).add(to: router)
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
