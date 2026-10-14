/// Shared General copy, following SetupStrings. Never interpolate paths or
/// underlying error bodies into diagnostics; the folder has its own UI row.
public enum GeneralSettingsStrings {
    public static func message(for outcome: LibrarySwitchOutcome) -> String? {
        switch outcome {
        case .switched: return nil
        case .settingsNotSaved(let error):
            return "You are using the new library folder for this session, but your choice could not be saved. "
                + settingsError(error)
        case .deliveryInFlight:
            return "Wait until your prompt has been delivered before changing your library folder."
        case .invalidTarget(let reason):
            switch reason {
            case .notAbsolute: return "Choose an absolute path for your library folder."
            case .missing: return "Choose a library folder that exists."
            case .notDirectory: return "Choose a directory for your library."
            case .unreadable: return "Check that you have permission to read your library folder."
            case .symlink: return "Choose your library folder directly instead of a symbolic link."
            case .outsideSandboxHome:
                return "Flatpak supports library folders in your home directory. Choose a home folder directly, "
                    + "or use the native app for a library outside home. Your current library is unchanged."
            case .rejectedByStore:
                return "Your library folder could not be opened safely. Choose another folder or check its permissions."
            }
        case .libraryUnavailable:
            return "Your new library folder is unavailable. Choose another folder, or check that you can read it and restart Monkey's Paw."
        }
    }

    public static func settingsError(_ error: SettingsError) -> String {
        switch error {
        case .futureVersion:
            return "Your settings were saved by a newer version. Update Monkey's Paw to change them."
        case .unsupportedVersion:
            return "Your settings version is unsupported. Restore a supported settings file and restart Monkey's Paw."
        case .corruptFile:
            return "Your settings file could not be read. Restore a valid settings file and restart Monkey's Paw."
        case .readFailed:
            return "Your settings could not be read. Check their permissions and restart Monkey's Paw."
        case .writeFailed:
            return "Your settings could not be saved. Check their permissions and available disk space, then try again."
        case .invalidLibraryFolder:
            return "Choose an absolute path without control characters for your library folder."
        }
    }
}
