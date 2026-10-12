/// UI-thread presentation for native chooser/drop paths. The service owns
/// asynchronous work and MainThread delivery; views only render this state.
public final class ImportModel {
    public struct State: Equatable, Sendable {
        public let isImporting: Bool
        public let progress: ImportProgress?
        public let report: ImportReport?
    }

    public private(set) var state = State(isImporting: false, progress: nil, report: nil)
    public var onChange: ((State) -> Void)?
    private let service: ImportService
    private var active = true

    public init(service: ImportService) { self.service = service }

    public func importFiles(at paths: [String], into subfolder: String = "Imported") {
        start(.files(paths), into: subfolder)
    }

    public func importFolder(at path: String, into subfolder: String = "Imported") {
        start(.folder(path), into: subfolder)
    }

    /// Composition retires this model with its library graph. Late progress or
    /// completion cannot revive the view, and queued files are not imported.
    public func deactivate() {
        active = false
        onChange = nil
        service.deactivate()
    }

    private func start(_ request: ImportRequest, into subfolder: String) {
        guard active, !state.isImporting else { return }
        state = State(isImporting: true, progress: .enumerating, report: nil)
        onChange?(state)
        guard active else { return }
        service.import(request, into: subfolder, progress: { [weak self] progress in
            guard let self, self.active else { return }
            self.state = State(isImporting: true, progress: progress, report: nil)
            self.onChange?(self.state)
        }, completion: { [weak self] report in
            guard let self, self.active else { return }
            self.state = State(isImporting: false, progress: nil, report: report)
            self.onChange?(self.state)
        })
    }
}
