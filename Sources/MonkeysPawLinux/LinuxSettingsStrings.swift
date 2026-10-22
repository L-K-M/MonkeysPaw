#if os(Linux)

/// Copy for the Settings window structure itself; per-page copy stays in the
/// page's own strings file.
enum LinuxSettingsStrings {
    static let pageSwitcher = "Settings pages"
    static let library = "Library"
    static let rememberedValues = "Remembered values"
    static let fieldValues = "Field values"
    static let pasting = "Pasting"
    static let status = "Status"
    static let connection = "Connection"
    static let profileDetails = "Profile details"
}
#endif
