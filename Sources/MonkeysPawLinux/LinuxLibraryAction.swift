#if os(Linux)
enum LinuxLibraryAction: String, CaseIterable {
    case newPrompt = "new-prompt"
    case save, duplicate, revert, rename, move, delete, favorite, edit, preview, source, search
    case sidebar, inspector, fields, history, assistant, review, improve
    case importFiles = "import-files", importFolder = "import-folder", showFiles = "show-files"
    case settings, about, close

    var accelerator: String? {
        switch self {
        case .newPrompt: return "<Control>n"
        case .save: return "<Control>s"
        case .duplicate: return "<Control><Shift>s"
        case .favorite: return "<Control>d"
        case .search: return "<Control>f"
        case .edit: return "<Control>1"
        case .preview: return "<Control>2"
        case .source: return "<Control>3"
        case .sidebar: return "F9"
        case .rename: return "F2"
        case .close: return "<Control>w"
        case .review: return "<Control>r"
        case .improve: return "<Control>i"
        case .settings: return "<Control>comma"
        default: return nil
        }
    }
}
#endif
