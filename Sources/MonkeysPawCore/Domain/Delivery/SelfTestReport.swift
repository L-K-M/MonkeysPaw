public enum SelfTestStatus: Equatable, Codable, Sendable {
    case pasted
    case sentButNotReceived
    case failed(PasteFailure)
}

public struct SelfTestResult: Equatable, Codable, Sendable {
    public let backend: PasteBackend
    public let status: SelfTestStatus

    public init(backend: PasteBackend, status: SelfTestStatus) {
        self.backend = backend
        self.status = status
    }
}

public struct SelfTestReport: Equatable, Codable, Sendable {
    public let session: DesktopSession
    public let results: [SelfTestResult]

    public init(session: DesktopSession, results: [SelfTestResult]) {
        self.session = session
        self.results = results
    }
}
