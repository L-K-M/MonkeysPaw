/// Filters once before forwarding safe diagnostic metadata to every destination.
public struct CompositeLogSink: LogSink {
    private let sinks: [LogSink]
    private let policy: LogLevelPolicy

    public init(sinks: [LogSink], policy: LogLevelPolicy = LogLevelPolicy()) {
        self.sinks = sinks
        self.policy = policy
    }

    public func write(_ level: LogLevel, _ message: String) {
        guard policy.allows(level) else { return }
        for sink in sinks { sink.write(level, message) }
    }
}
