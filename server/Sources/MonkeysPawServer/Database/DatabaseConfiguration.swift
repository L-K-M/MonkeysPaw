import Foundation

public struct DatabaseConfiguration: Sendable {
    let dataDirectory: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let configured = environment["MONKEYSPAW_DATA_DIR"]
        let path = configured.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        } ?? ServerLimits.defaultDataDirectory
        dataDirectory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    var databasePath: String {
        dataDirectory.appendingPathComponent(ServerLimits.databaseFilename).path
    }
}
