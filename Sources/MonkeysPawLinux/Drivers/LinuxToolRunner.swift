#if os(Linux)
import Foundation
import Glibc
import MonkeysPawCore

/// Small, bounded Process adapter shared by the local command-line drivers.
/// Call on a worker except for the short, synchronous FocusTracker capture.
struct LinuxToolRunner {
    enum ErrorOutput {
        case discard
        // ydotool 0.1.8 writes its help to stderr. Drain it with stdout, never log it.
        case mergeForHelp
    }

    enum TextOutput { case trimmed, verbatim }

    struct Output {
        let status: Int32
        let text: String
    }

    let environment: [String: String]
    private let readOutput: (Int32, UnsafeMutableRawPointer?, Int) -> Int

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         readOutput: @escaping (Int32, UnsafeMutableRawPointer?, Int) -> Int = Glibc.read) {
        self.environment = environment
        self.readOutput = readOutput
    }

    func executable(_ name: String) -> URL? {
        for directory in (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":") where directory.hasPrefix("/") {
            let url = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    func run(
        _ name: String, arguments: [String], timeout: Duration = Limits.linuxToolTimeout,
        errorOutput: ErrorOutput = .discard, acceptedStatuses: Set<Int32> = [0],
        environmentOverrides: [String: String] = [:], input: Data? = nil,
        textOutput: TextOutput = .trimmed
    ) -> Result<Output, PasteFailure> {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        guard let executable = executable(name) else { return .failure(.toolMissing) }

        let process = Process()
        let pipe = Pipe()
        let inputPipe = input.map { _ in Pipe() }
        process.executableURL = executable
        process.arguments = arguments
        // Operator overrides belong to the parent, never unrelated child tools.
        process.environment = environment.merging(environmentOverrides) { _, value in value }
            .filter {
                !($0.key.hasPrefix("MONKEYSPAW_PROVIDER_") && $0.key.hasSuffix("_API_KEY"))
                    && !($0.key.hasPrefix("MONKEYSPAW_DEVICE_") && $0.key.hasSuffix("_TOKEN"))
            }
        process.standardInput = inputPipe?.fileHandleForReading ?? FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = errorOutput == .mergeForHelp ? pipe : FileHandle.nullDevice
        defer {
            try? pipe.fileHandleForReading.close()
            try? inputPipe?.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
        }

        if let inputPipe {
            let descriptor = inputPipe.fileHandleForWriting.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                try? pipe.fileHandleForWriting.close()
                return .failure(.unknown)
            }
        }

        do { try process.run() } catch {
            try? pipe.fileHandleForWriting.close()
            return .failure(.unknown)
        }
        // The parent must not retain the pipe's writer; grandchildren may retain
        // theirs. Nonblocking reads and a deadline handle both cases.
        try? pipe.fileHandleForWriting.close()
        try? inputPipe?.fileHandleForReading.close()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            kill(process.processIdentifier, SIGKILL)
            return .failure(.unknown)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var inputOffset = 0
        var inputClosed = inputPipe == nil
        while true {
            guard clock.now < deadline else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return .failure(.timeout)
            }

            if let input, let inputPipe, !inputClosed {
                if inputOffset == input.count {
                    try? inputPipe.fileHandleForWriting.close()
                    inputClosed = true
                } else {
                    var ready = pollfd(fd: inputPipe.fileHandleForWriting.fileDescriptor,
                        events: Int16(POLLOUT), revents: 0)
                    if poll(&ready, 1, 0) > 0, ready.revents != 0 {
                        // Linux PIPE_BUF-sized writes are atomic on a nonblocking
                        // pipe. Poll and drain stdout between chunks so neither
                        // a full stdin nor a closed reader can bypass the budget.
                        let end = min(inputOffset + Int(PIPE_BUF), input.count)
                        let range = (input.startIndex + inputOffset)..<(input.startIndex + end)
                        guard (try? inputPipe.fileHandleForWriting.write(
                            contentsOf: input.subdata(in: range))) != nil else {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            return .failure(.unknown)
                        }
                        inputOffset = end
                    }
                }
            }

            let count = readOutput(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= Limits.linuxToolOutputCap else {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    return .failure(.unknown)
                }
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno != EAGAIN, errno != EINTR {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return .failure(.unknown)
            }
            if count == 0, !process.isRunning {
                // EAGAIN can race the child's final write and exit. Only EOF
                // proves the pipe is drained, including any inherited writer.
                guard process.terminationReason == .exit,
                      acceptedStatuses.contains(process.terminationStatus),
                      input == nil || inputOffset == input?.count else {
                    return .failure(.unknown)
                }
                let text: String
                switch textOutput {
                case .trimmed:
                    text = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                case .verbatim:
                    guard let value = String(data: data, encoding: .utf8) else { return .failure(.unknown) }
                    text = value
                }
                return .success(Output(status: process.terminationStatus,
                    text: text))
            }

            // Even an EOF pipe must wait for the child with a bounded poll, since
            // a tool can close stdout and then hang. No waitUntilExit or EOF wait.
            Thread.sleep(forTimeInterval: Limits.linuxToolPollInterval.timeInterval)
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
#endif
