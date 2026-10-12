/// Sanitized failures from checking or seeding the active library (§11.4).
/// Unknown service errors become operationFailed, never an underlying error body.
public enum SeedFailure: Error, Equatable, Sendable {
    case fileStore(FileStoreError)
    case library(LibraryError)
    case promptWrite(PromptWriteError)
    case identity(ULIDGenerationError)

    init(sanitizing error: Error) {
        switch error {
        case let failure as FileStoreError: self = .fileStore(failure)
        case let failure as LibraryError: self = .library(failure)
        case let failure as PromptWriteError: self = .promptWrite(failure)
        case let failure as ULIDGenerationError: self = .identity(failure)
        default: self = .library(.operationFailed)
        }
    }
}
