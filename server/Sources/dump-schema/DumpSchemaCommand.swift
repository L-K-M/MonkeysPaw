import Foundation
import MonkeysPawServer

@main
struct DumpSchemaCommand {
    static func main() {
        guard CommandLine.arguments.count == 2, !CommandLine.arguments[1].isEmpty else {
            FileHandle.standardError.write(Data("Usage: dump-schema <output-dir>\n".utf8))
            exit(64)
        }

        do {
            try SchemaRenderer.write(to: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        } catch {
            FileHandle.standardError.write(Data("dump-schema: could not write schemas: \(error)\n".utf8))
            exit(1)
        }
    }
}
