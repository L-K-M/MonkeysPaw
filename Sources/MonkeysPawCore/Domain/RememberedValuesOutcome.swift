/// The result of an explicit global forget. Failures carry no paths, field
/// values or underlying error bodies; unknown errors become operationFailed.
public enum RememberedValuesOutcome: Equatable, Sendable {
    case forgotten
    case deliveryInFlight
    case fileStoreFailure(FileStoreError)
    case libraryFailure(LibraryError)
}
