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
    configuration: ServerConfiguration, accounts: AccountService? = nil, sessions: SessionService? = nil,
    admin: AdminUserService? = nil, groups: GroupService? = nil, invites: InviteService? = nil,
    prompts: PromptService? = nil, logger suppliedLogger: Logger? = nil
) -> some ApplicationProtocol {
    let logger = suppliedLogger ?? ServerLogging.logger(level: configuration.logLevel)
    let router = Router(context: ServerRequestContext.self)
    router.add(middleware: APIErrorMiddleware())

    router.get("/api/health") { _, _ in
        HealthResponse(status: "ok", version: configuration.version)
    }

    if let accounts, let sessions {
        LoginRoutes(login: .init(accounts: accounts, sessions: sessions), trustedProxies: configuration.trustedProxies).add(to: router)
        AccountRoutes(accounts: accounts, sessions: sessions).add(to: router)
        AdminUserRoutes(admin: admin ?? .init(accounts: accounts, logger: logger), sessions: sessions).add(to: router)
        GroupRoutes(groups: groups ?? .init(database: accounts.repository.database, clock: accounts.clock), sessions: sessions).add(to: router)
        InviteRoutes(invites: invites ?? .init(accounts: accounts, sessions: sessions, publicURL: configuration.publicURL), sessions: sessions).add(to: router)
        PromptRoutes(prompts: prompts ?? .init(database: accounts.repository.database, clock: accounts.clock), sessions: sessions).add(to: router)
        SyncFeedRoutes(feed: .init(database: accounts.repository.database), sessions: sessions).add(to: router)
    }

    return Application(
        router: router,
        configuration: .init(address: .hostname(configuration.httpHost, port: configuration.httpPort)),
        logger: logger
    )
}

private struct HealthResponse: ResponseCodable {
    let status: String
    let version: String
}
