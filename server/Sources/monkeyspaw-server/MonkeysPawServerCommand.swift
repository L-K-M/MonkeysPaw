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
        subcommands: [Serve.self, Healthcheck.self],
        defaultSubcommand: Serve.self
    )
}

private struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Serve the HTTP API.")

    mutating func run() async throws {
        let configuration = try ServerConfiguration()
        let application = buildApplication(configuration: configuration)

        try await application.runService()
    }
}

private struct Healthcheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check the local server's health.")

    mutating func run() async throws {
        do {
            let configuration = try ServerConfiguration()
            let url = URL(string: "http://127.0.0.1:\(configuration.httpPort)/api/health")!
            var request = URLRequest(url: url)
            request.timeoutInterval = ServerLimits.healthcheckTimeout

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
