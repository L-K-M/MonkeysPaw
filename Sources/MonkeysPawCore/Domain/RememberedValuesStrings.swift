/// Shared Settings copy. Diagnostics never interpolate paths, prompt content,
/// field values or underlying error bodies.
public enum RememberedValuesStrings {
    public static let forgetAll = "Forget all values"
    public static let confirmationTitle = "Forget all values?"
    public static let confirmationMessage =
        "You will clear all your remembered values and the values you have entered this session. This cannot be undone."
    public static let cancel = "Cancel"

    public static func message(for outcome: RememberedValuesOutcome) -> String {
        switch outcome {
        case .forgotten:
            return "You have cleared all your remembered values."
        case .deliveryInFlight:
            return "Wait until your prompt has been delivered, then try forgetting your values again."
        case .fileStoreFailure:
            return "Your remembered values could not be cleared. Check your permissions and available disk space, then try again."
        case .libraryFailure:
            return "Your remembered values could not be cleared. Try again."
        }
    }
}
