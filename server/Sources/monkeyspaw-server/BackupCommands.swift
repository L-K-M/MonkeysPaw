import ArgumentParser
import MonkeysPawServer

struct Backup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create an online SQLite backup at an unoccupied path.")
    @Argument(help: "Destination path; existing files are never overwritten.") var path: String
    @OptionGroup var output: AdminOutput

    mutating func run() async throws {
        let result = try await ServerBackupService(configuration: DatabaseConfiguration()).backup(to: path)
        try output.write(result, text: result.path)
    }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restore a backup while the server is stopped; rotate the database identity.")
    @Argument(help: "Backup path.") var path: String
    @OptionGroup var output: AdminOutput

    mutating func run() async throws {
        let result = try await ServerBackupService(configuration: DatabaseConfiguration()).restore(from: path)
        try output.write(result, text: result.path)
    }
}
