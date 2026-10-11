import Foundation

/// A shared Foundation-only platform driver for private, bounded diagnostics.
/// Callers obey LogSink's safe-metadata contract, including at debug level.
public final class FileLogSink: LogSink, @unchecked Sendable {
    // The lock covers the formatter, rotation and every partial stream write.
    private let lock = NSLock()
    private let directory: URL
    private let file: URL
    private let formatter: ISO8601DateFormatter
    private let now: () -> Date
    private let failureLog: StandardErrorLog
    private var failed = false

    public convenience init(dataDirectory: URL) {
        self.init(dataDirectory: dataDirectory, now: Date.init, failureLog: StandardErrorLog())
    }

    // Deterministic timestamps and isolated stderr capture for portable tests.
    init(dataDirectory: URL, now: @escaping () -> Date, failureLog: StandardErrorLog) {
        directory = dataDirectory.appendingPathComponent("logs", isDirectory: true)
        file = directory.appendingPathComponent("monkeyspaw.log")
        formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.now = now
        self.failureLog = failureLog
    }

    public func write(_ level: LogLevel, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { return }

        do {
            let bytes = record(level, message)
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])

            if let size = try fileSize(file), size > Limits.logFileMaxBytes - bytes.count {
                try rotate()
            }
            if try fileSize(file) == nil {
                guard manager.createFile(atPath: file.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else {
                    throw FileLogError.unavailable
                }
            }
            try append(bytes)
        } catch {
            // Do not expose a path or an underlying filesystem error body.
            failed = true
            failureLog.write(.warning, "File logging unavailable; continuing with other log sinks")
        }
    }

    private func record(_ level: LogLevel, _ message: String) -> Data {
        let header = "\(formatter.string(from: now())) \(level.rawValue): "
        let message = message.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        if header.utf8.count + message.utf8.count + 1 <= Limits.logFileMaxBytes {
            return Data("\(header)\(message)\n".utf8)
        }

        let suffix = " [truncated]\n"
        let budget = Limits.logFileMaxBytes - header.utf8.count - suffix.utf8.count
        let utf8 = message.utf8
        var end = utf8.index(utf8.startIndex, offsetBy: budget)
        // Exclude a partial scalar rather than replacing it with extra UTF-8 bytes.
        while end > utf8.startIndex && utf8[end] & 0xc0 == 0x80 {
            end = utf8.index(before: end)
        }
        return Data(header.utf8) + Data(utf8[..<end]) + Data(suffix.utf8)
    }

    private func fileSize(_ url: URL) throws -> Int? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else {
                throw FileLogError.unavailable
            }
            return size.intValue
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            return nil
        }
    }

    private func archive(_ number: Int) -> URL {
        directory.appendingPathComponent("monkeyspaw.log.\(number)")
    }

    private func rotate() throws {
        let manager = FileManager.default
        let oldest = archive(Limits.logFileKeep - 1)
        if try fileSize(oldest) != nil { try manager.removeItem(at: oldest) }
        for number in stride(from: Limits.logFileKeep - 2, through: 1, by: -1) {
            let source = archive(number)
            if try fileSize(source) != nil { try manager.moveItem(at: source, to: archive(number + 1)) }
        }
        try manager.moveItem(at: file, to: archive(1))
    }

    private func append(_ bytes: Data) throws {
        guard let stream = OutputStream(toFileAtPath: file.path, append: true) else {
            throw FileLogError.unavailable
        }
        stream.open()
        defer { stream.close() }

        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < buffer.count {
                let written = stream.write(base.advanced(by: offset), maxLength: buffer.count - offset)
                guard written > 0 else { throw FileLogError.unavailable }
                offset += written
            }
        }
    }
}

private enum FileLogError: Error {
    case unavailable
}
