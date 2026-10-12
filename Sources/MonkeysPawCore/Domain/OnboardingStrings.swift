/// Shared first-run and recovery copy. Diagnostics never include paths or
/// underlying error bodies; native views may show the folder in its own row.
public enum OnboardingStrings {
    public static let libraryFolderTitle = "Choose your library folder"
    public static let libraryFolderHelp = "Use the default folder or choose a folder for your prompts."
    public static let useDefaultFolder = "Use Default Folder"
    public static let chooseFolder = "Choose Folder"
    public static let seedOfferTitle = "Add starter prompts to your library?"
    public static let seedOfferHelp = "You can add starter prompts to your empty library or start with your own."
    public static let acceptSeeds = "Add Starter Prompts"
    public static let declineSeeds = "Skip Starter Prompts"
    public static let libraryAvailableMenu = "Open Library"
    public static let libraryUnavailableMenu = "Library unavailable"
    public static let libraryUnavailableNotificationTitle = "Library unavailable"
    public static let libraryUnavailableNotificationBody =
        "Your library could not be opened. Choose a readable library folder in Settings."
    public static let restartForLibrary = "Your library is unavailable. Restart Monkey's Paw to restore it."

    public static func seedSummary(_ summary: SeedSummary) -> String {
        let added = summary.seededCount == 1 ? "starter prompt" : "starter prompts"
        let skipped = summary.skippedExistingCount == 1 ? "occupied destination" : "occupied destinations"
        return "You added \(summary.seededCount) \(added) and skipped \(summary.skippedExistingCount) \(skipped)."
    }

    public static func seedFailure(_ failure: SeedFailure) -> String {
        switch failure {
        case .fileStore:
            return "Your starter prompts could not be read or saved. Check your library permissions and available disk space."
        case .library:
            return "Your starter prompts could not be added safely. Any prompts already added have been kept."
        case .promptWrite:
            return "Your starter prompts could not be prepared for saving. Any prompts already added have been kept."
        case .identity:
            return "Your starter prompts could not be assigned identifiers. Any prompts already added have been kept."
        }
    }
}
