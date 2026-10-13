import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MonkeysPawServer

@main
struct MonkeysPawServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monkeyspaw-server",
        abstract: "Run the Monkey's Paw sync server.",
        subcommands: [Serve.self, Migrate.self, Healthcheck.self],
        defaultSubcommand: Serve.self
    )
}

private struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Serve the HTTP API.")

    mutating func run() async throws {
        let configuration = try ServerConfiguration()
        let bootstrap = BootstrapConfiguration()
        try await ServerDatabase.withMigratedDatabase(configuration: DatabaseConfiguration()) { database in
            try await bootstrapAccounts(database: database, configuration: bootstrap)
            let application = buildApplication(configuration: configuration, database: database)
            try await application.runService()
        }
    }
}

private struct Migrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Apply pending database migrations.")

    mutating func run() async throws {
        do {
            try await ServerDatabase.withMigratedDatabase(configuration: DatabaseConfiguration()) { _ in }
        } catch {
            // Driver errors can contain stored data; report only the operation.
            throw ValidationError("Database initialization or migration failed.")
        }
    }
}

private struct Healthcheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check the local server's health.")

    mutating func run() async throws {
        let configuration: ServerConfiguration
        do {
            configuration = try ServerConfiguration()
        } catch {
            ServerLogging.logger().error("Healthcheck configuration invalid")
            throw ExitCode.failure
        }

        let url = URL(string: "http://127.0.0.1:\(configuration.httpPort)/api/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = ServerLimits.healthcheckTimeout

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw ExitCode.failure
            }
        } catch {
            // Docker needs exit 1 on both HTTP and transport failures; log no body.
            throw ExitCode.failure
        }
    }
}
