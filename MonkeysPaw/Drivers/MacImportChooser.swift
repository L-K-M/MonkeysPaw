import AppKit
import UniformTypeIdentifiers

enum MacImportChooser {
    static func makePanel(destinations: [String] = [], destination: String = ImportStrings.defaultDestination,
                          selectDestination: @escaping (String) -> Void = { _ in }) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = ImportStrings.chooserTitle
        panel.prompt = ImportStrings.choose
        panel.message = ImportStrings.chooserMessage
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = [UTType.folder] + ["md", "prompt", "prompty"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = false
        if !destinations.isEmpty {
            panel.accessoryView = MacImportDestinationView(destinations: destinations,
                selected: destination, onSelect: selectDestination)
            panel.isAccessoryViewDisclosed = true
        }
        return panel
    }

    static func choose(in window: NSWindow, done: @escaping ([URL]) -> Void) -> (() -> Void) {
        let panel = makePanel()
        panel.beginSheetModal(for: window) { response in done(response == .OK ? panel.urls : []) }
        return { panel.cancel(nil) }
    }

    static func choose(in window: NSWindow, destinations: [String], destination: String,
                       selectDestination: @escaping (String) -> Void,
                       done: @escaping ([URL]) -> Void) -> (() -> Void) {
        let panel = makePanel(destinations: destinations, destination: destination, selectDestination: selectDestination)
        panel.beginSheetModal(for: window) { response in done(response == .OK ? panel.urls : []) }
        return { panel.cancel(nil) }
    }
}

/// Native import options keep destination selection available before the first
/// batch without bringing back a permanent control row in the Library.
private final class MacImportDestinationView: NSView {
    private let onSelect: (String) -> Void
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(destinations: [String], selected: String, onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 32))
        let label = NSTextField(labelWithString: ImportStrings.destination)
        label.frame = NSRect(x: 0, y: 5, width: 90, height: 22)
        popup.frame = NSRect(x: 96, y: 2, width: 260, height: 28)
        for path in destinations {
            popup.addItem(withTitle: path + "/")
            popup.lastItem?.representedObject = path
        }
        if let index = destinations.firstIndex(of: selected) { popup.selectItem(at: index) }
        popup.target = self
        popup.action = #selector(select(_:))
        popup.setAccessibilityLabel(ImportStrings.destination)
        popup.setAccessibilityIdentifier("library-import-destination")
        addSubview(label)
        addSubview(popup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func select(_ sender: NSPopUpButton) {
        guard let path = sender.selectedItem?.representedObject as? String else { return }
        onSelect(path)
    }
}
