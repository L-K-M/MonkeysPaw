import Foundation
import MonkeysPawCore

enum LibraryFileCommand: Equatable { case rename, move, delete }

/// Binds a native form to the prompt that was open when it was requested.
struct LibraryFileCommandRequest: Equatable {
    let id = UUID()
    let command: LibraryFileCommand
    let prompt: LibraryPromptSelection
    let folders: [String]

    var filename: String {
        let path = prompt.relativePath.string
        guard let slash = path.unicodeScalars.lastIndex(of: "/") else { return path }
        return String(path[path.unicodeScalars.index(after: slash)...])
    }

    var folder: String {
        let path = prompt.relativePath.string
        guard let slash = path.unicodeScalars.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    var title: String {
        switch command {
        case .rename: return LibraryCommandStrings.renameTitle
        case .move: return LibraryCommandStrings.moveTitle
        case .delete: return LibraryCommandStrings.deleteTitle(prompt.relativePath.string)
        }
    }

    var message: String {
        switch command {
        case .rename: return LibraryCommandStrings.renameHint
        case .move: return LibraryCommandStrings.moveHint
        case .delete: return LibraryCommandStrings.deleteHint(prompt.relativePath.string)
        }
    }

    var responses: [LibraryEditorResponse] {
        switch command {
        case .rename: return [.rename(filename), .cancelFileCommand]
        case .move: return [.move(folder), .cancelFileCommand]
        case .delete: return [.cancelFileCommand, .delete]
        }
    }
}
