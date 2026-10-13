import MonkeysPawCore

enum ImportStrings {
    static let action = "Import…"
    static let chooserTitle = "Import prompts"
    static let choose = "Import"
    static let chooserMessage = "Choose Markdown (.md), Dotprompt (.prompt), Prompty (.prompty) files or folders."
    static let destination = "Import to"
    static let defaultDestination = "Imported"
    static let enumerating = "Finding files to import…"
    static let report = "Import report"
    static let dismiss = "Dismiss report"
    static let selectedFiles = "Selected files"
    static let fileURLsOnly = "Drop local files or folders to import them."
    static let dropReadFailed = "Some dropped items could not be read as local file URLs. Drop those files again."
    static let waitingForRefresh = "The imported prompt is waiting for the library to refresh. Try opening it again."
    static let libraryLost = "Import stopped because the library is unavailable. Completed results remain in the report."

    static func progress(_ progress: ImportProgress?, selection: Int, total: Int) -> String {
        let message: String
        switch progress {
        case .importing(let completed, let count): message = "Processed \(completed) of \(count) files."
        case .enumerating, nil: message = enumerating
        }
        return total > 1 ? "Selection \(selection) of \(total): " + message : message
    }

    static func summary(created: Int, skipped: Int) -> String { "Imported: \(created) · Skipped: \(skipped)" }
    static func created(_ path: String) -> String { "Open " + path }
    static func skipped(_ reason: ImportSkipReason) -> String { "Skipped: " + self.reason(reason) }
    static func failed(_ reason: ImportSkipReason) -> String { "Import failed: " + self.reason(reason) }
    static func preserved(_ keys: [String]) -> String { "Preserved metadata: " + keys.joined(separator: ", ") }

    static func mapping(_ mapping: ImportFieldMapping) -> String {
        let message = "Mapped \(mapping.sourceKey) to \(mapping.fieldName) (\(EditorStrings.fieldKind(mapping.kind)))."
        guard let source = mapping.defaultSource else { return message }
        return message + " Default supplied by \(source)."
    }

    static func loss(_ loss: ImportLoss) -> String {
        switch loss {
        case .frontMatterPresentation: return "Header comments and styling were replaced by canonical formatting."
        }
    }

    static func warning(_ warning: ImportWarning) -> String {
        switch warning {
        case .unsupportedInput(let key): return "Unsupported input preserved as metadata: \(key)."
        case .invalidName(let key): return "Invalid field name preserved as metadata: \(key)."
        case .reservedName(let key): return "Reserved field name preserved as metadata: \(key)."
        case .fieldCollision(let key): return "Existing field kept; source declaration preserved: \(key)."
        case .invalidOptions(let key): return "Invalid choice options preserved as metadata: \(key)."
        case .invalidDefault(let key): return "Invalid default preserved as metadata: \(key)."
        case .invalidDescription(let key): return "Invalid description preserved as metadata: \(key)."
        case .unsupportedTemplate(let format, let offset):
            return "Unsupported \(format.rawValue) template kept literally at body byte \(offset)."
        case .validation(let code):
            switch code {
            case .unusedField: return "A declared field is not used in the body."
            case .invalidPlaceholder: return "An unsupported placeholder was kept as literal text."
            case .unbalancedOpener: return "An unclosed placeholder opener was kept as literal text."
            case .groupPrivateRemoved: return "The personal private flag was removed from group content."
            default: return "Prompt validation warning: \(code.rawValue)."
            }
        case .identityReassigned: return "The source id was already taken; a new prompt id was assigned."
        }
    }

    static func reason(_ reason: ImportSkipReason) -> String {
        switch reason {
        case .unsupportedExtension: return "Use a lowercase .md, .prompt or .prompty extension."
        case .fileTooLarge: return "The source exceeds \(Limits.importFileCapBytes) bytes."
        case .invalidUTF8: return "Encode the source as UTF-8."
        case .invalidPrompt(let codes): return "The source is invalid (\(codes.map(\.rawValue).joined(separator: ", ")))."
        case .unsupportedFormat(let version): return "Prompt format \(version.decimalValue) is newer than supported."
        case .convertedTooLarge: return "The converted prompt exceeds \(Limits.maxPromptBytes) bytes."
        case .invalidPath: return "The source or destination has an invalid or ignored library path."
        case .symbolicLink: return "Symbolic links are not imported."
        case .notRegularFile: return "The source is not a regular file or folder."
        case .duplicateSource: return "This source was already selected."
        case .source(let error):
            switch error {
            case .invalidPath: return self.reason(.invalidPath)
            case .notFound: return "The selected source no longer exists."
            case .notRegularFile: return self.reason(.notRegularFile)
            case .symbolicLink: return self.reason(.symbolicLink)
            case .fileTooLarge: return self.reason(.fileTooLarge)
            case .ioFailure: return "Could not read the source. Check its permissions and try again."
            }
        case .fileStore(let error): return EditorStrings.editingFailure(.fileStore(error))
        case .library(let error): return EditorStrings.editingFailure(.library(error))
        case .identityGeneration, .identityLimitReached: return "Could not assign an unused prompt id. Try again."
        }
    }
}
