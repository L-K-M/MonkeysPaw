import AppKit
import Combine
import MonkeysPawCore

/// Mouse selection belongs to the completed click. A drag spends that click
/// without opening its row, so it cannot trigger a draft guard before the drop.
final class LibrarySelectionDeferral {
    private let isButtonDown: () -> Bool
    private let open: (RelativePath) -> Void
    private var pending: RelativePath?
    private var dragged = false

    init(isButtonDown: @escaping () -> Bool, open: @escaping (RelativePath) -> Void) {
        self.isButtonDown = isButtonDown
        self.open = open
    }

    func beginMouseSelection(_ path: RelativePath?) { pending = path; dragged = false }
    func select(_ path: RelativePath) {
        if isButtonDown() { if !dragged { pending = path } }
        else { pending = nil; open(path) }
    }
    func beginDrag() { dragged = true; pending = nil }
    func endMouseSelection() {
        let path = pending
        pending = nil
        if !dragged, let path { open(path) }
        dragged = false
    }
}

final class LibraryPromptListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                         NSMenuDelegate, NSMenuItemValidation {
    let tableView = LibraryPromptTableView()
    private let presentation: LibraryViewState
    private let mainThread: MainThread
    private var rows: [LibraryBrowserRow] = []
    private var showsLastUse = false
    private var subscriptions: [AnyCancellable] = []
    private var synchronizing = false
    private let emptyLabel = LibraryEmptyStateLabel(labelWithString: LibraryStrings.noPrompts)
    private let dropBorder = LibraryDropHighlightView()
    private var contextPath: RelativePath?
    var validateCommand: ((NSMenuItem) -> Bool)?
    private lazy var selectionDeferral = LibrarySelectionDeferral(
        isButtonDown: { NSEvent.pressedMouseButtons & 1 != 0 },
        open: { [weak self] path in self?.presentation.selectPath(path); self?.synchronizeSelection() })

    init(presentation: LibraryViewState, mainThread: MainThread) {
        self.presentation = presentation
        self.mainThread = mainThread
        super.init(nibName: nil, bundle: nil)
        _ = view
        subscriptions.append(presentation.$snapshot.sink { [weak self] state in
            self?.mainThread.run { [weak self] in self?.apply(state) }
        })
        subscriptions.append(presentation.$editorState.sink { [weak self] state in
            guard state.pendingDecision == nil else { return }
            self?.mainThread.run { [weak self] in self?.synchronizeSelection() }
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let container = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        tableView.addTableColumn(NSTableColumn(identifier: .init("Prompt")))
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 46
        tableView.allowsTypeSelect = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(LibraryStrings.prompts)
        tableView.setAccessibilityIdentifier("library-prompts")
        tableView.onReturn = { [weak self] in self?.focusEditor(nil) }
        tableView.onDelete = { [weak self] in self?.requestDelete() }
        tableView.onMouseBegan = { [weak self] row in
            guard let self else { return }
            self.selectionDeferral.beginMouseSelection(self.rows.indices.contains(row) ? self.rows[row].relativePath : nil)
        }
        tableView.onMouseEnded = { [weak self] in
            self?.selectionDeferral.endMouseSelection()
            self?.synchronizeSelection()
        }
        tableView.onDropExit = { [weak self] in self?.dropBorder.isHidden = true }
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        scroll.documentView = tableView
        container.addSubview(scroll)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        container.addSubview(emptyLabel)
        dropBorder.wantsLayer = true
        dropBorder.layer?.borderColor = NSColor.controlAccentColor.cgColor
        dropBorder.layer?.borderWidth = 2
        dropBorder.isHidden = true
        container.addSubview(dropBorder)
        for child in [scroll, dropBorder] {
            child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                child.topAnchor.constraint(equalTo: container.topAnchor),
                child.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -24)
        ])
        view = container
    }

    private func apply(_ state: LibraryBrowserState) {
        synchronizing = true
        defer { synchronizing = false }
        let recentChanged = showsLastUse != (state.selectedSection == .recent)
        showsLastUse = state.selectedSection == .recent
        if rows != state.rows {
            rows = state.rows
            tableView.reloadData()
        } else if recentChanged {
            // A one-row All/Recent switch can keep identical data. Reconfigure
            // existing cells without rebuilding the table or its selection.
            for index in rows.indices {
                (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? LibraryPromptCell)?
                    .configure(rows[index], showsLastUse: showsLastUse)
            }
        }
        synchronizeSelection(state.selection)
        emptyLabel.stringValue = state.filter.isEmpty ? LibraryStrings.noPrompts : LibraryStrings.noResults(state.filter)
        emptyLabel.isHidden = !rows.isEmpty
    }

    func synchronizeSelection() { synchronizeSelection(presentation.snapshot.selection) }

    private func synchronizeSelection(_ selection: LibraryPromptSelection?) {
        let wasSynchronizing = synchronizing
        synchronizing = true
        defer { synchronizing = wasSynchronizing }
        if let index = rows.firstIndex(where: { $0.selection == selection }) {
            if tableView.selectedRow != index { tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        } else { tableView.deselectAll(nil) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard rows.indices.contains(index) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("LibraryPromptCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? LibraryPromptCell) ?? LibraryPromptCell(frame: .zero)
        cell.identifier = identifier
        cell.configure(rows[index], showsLastUse: showsLastUse)
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        rows.indices.contains(row) ? rows[row].title : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizing, rows.indices.contains(tableView.selectedRow) else { return }
        selectionDeferral.select(rows[tableView.selectedRow].relativePath)
    }

    @objc func focusEditor(_ sender: Any?) { presentation.focusEditor() }

    func requestDelete() {
        let item = NSMenuItem(title: LibraryCommandStrings.delete,
            action: #selector(LibraryWindowController.deleteLibraryPrompt(_:)), keyEquivalent: "")
        guard validateCommand?(item) == true else { return }
        presentation.requestFileCommand(.delete)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row), let data = presentation.scopeDragData(for: rows[row].selection,
            epoch: presentation.scopeDragEpoch) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: .init(LibraryViewState.scopeDragTypeIdentifier))
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        selectionDeferral.beginDrag()
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(-1, dropOperation: .on)
        let allowed = presentation.imports?.canImport == true
            && info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        dropBorder.isHidden = !allowed
        return allowed ? .copy : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        dropBorder.isHidden = true
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return presentation.imports?.importURLs(urls) == true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let index = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard rows.indices.contains(index) else { contextPath = nil; return }
        let row = rows[index]
        contextPath = row.relativePath
        if row.relativePath != presentation.editorState.prompt?.relativePath {
            add(LibraryStrings.open, action: #selector(openContextRow(_:)), to: menu)
            add(Strings.showInFinder, action: #selector(revealContextRow(_:)), to: menu)
            return
        }
        add(row.favorite ? LibraryStrings.removeFavorite : LibraryStrings.addFavorite,
            action: #selector(LibraryWindowController.toggleFavorite(_:)), to: menu)
        add(LibraryCommandStrings.rename, action: #selector(LibraryWindowController.renameDocument(_:)), to: menu)
        let move = NSMenuItem(title: LibraryStrings.moveTo, action: nil, keyEquivalent: "")
        let destinations = NSMenu(title: LibraryStrings.moveTo)
        let top = add(LibraryStrings.topLevel, action: #selector(moveContextRow(_:)), to: destinations)
        top.representedObject = ""
        for section in presentation.snapshot.sections {
            guard case .folder(let path) = section.id else { continue }
            let item = add(path.string, action: #selector(moveContextRow(_:)), to: destinations)
            item.representedObject = path.string
        }
        destinations.addItem(.separator())
        add(LibraryStrings.other, action: #selector(LibraryWindowController.moveDocument(_:)), to: destinations)
        move.submenu = destinations
        menu.addItem(move)
        add(LibraryStrings.duplicate, action: #selector(LibraryWindowController.duplicateDocument(_:)), to: menu)
        add(Strings.showInFinder, action: #selector(LibraryWindowController.showInFinder(_:)), to: menu)
        menu.addItem(.separator())
        add(LibraryCommandStrings.delete, action: #selector(LibraryWindowController.deleteLibraryPrompt(_:)), to: menu)
    }

    @discardableResult
    private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        if action == #selector(openContextRow(_:)) || action == #selector(revealContextRow(_:)) || action == #selector(moveContextRow(_:)) {
            item.target = self
        }
        return item
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let gate = NSMenuItem(title: item.title, action: #selector(LibraryWindowController.searchLibrary(_:)), keyEquivalent: "")
        guard validateCommand?(gate) == true, let path = contextPath,
              rows.contains(where: { $0.relativePath == path }) else { return false }
        if item.action == #selector(moveContextRow(_:)) {
            return path == presentation.editorState.prompt?.relativePath && presentation.canRunFileCommand
        }
        return true
    }
    @objc private func openContextRow(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let path = contextPath else { return }
        presentation.selectPath(path)
    }
    @objc private func revealContextRow(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let path = contextPath else { return }
        presentation.revealPrompt(at: path)
    }
    @objc private func moveContextRow(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), contextPath == presentation.editorState.prompt?.relativePath,
              let folder = sender.representedObject as? String else { return }
        presentation.movePrompt(to: folder)
    }
}

final class LibraryPromptTableView: NSTableView {
    var onMouseBegan: ((Int) -> Void)?
    var onMouseEnded: (() -> Void)?
    var onDropExit: (() -> Void)?
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseBegan?(row(at: convert(event.locationInWindow, from: nil)))
        super.mouseDown(with: event)
        onMouseEnded?()
        // Open on release first; an initially empty editor can then receive
        // the double-click focus request for its newly opened prompt.
        if event.clickCount >= 2 { onReturn?() }
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDropExit?()
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        onDropExit?()
    }
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if flags.isEmpty, event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return }
        if flags.isEmpty || flags == .command, event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }
        super.keyDown(with: event)
    }
}

final class LibraryPromptCell: NSTableCellView {
    let titleField = NSTextField(labelWithString: "")
    let detailField = NSTextField(labelWithString: "")
    private let symbols = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)
        detailField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailField.textColor = .secondaryLabelColor
        for field in [titleField, detailField] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
        }
        textField = titleField
        let labels = NSStackView(views: [titleField, detailField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        symbols.spacing = 5
        let content = NSStackView(views: [labels, symbols])
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        symbols.setContentHuggingPriority(.required, for: .horizontal)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(_ row: LibraryBrowserRow, showsLastUse: Bool) {
        titleField.stringValue = row.title
        if showsLastUse, let date = row.lastUsedAt { detailField.stringValue = LibraryStrings.lastUsed(date) }
        else if let description = row.previewLine, !description.isEmpty { detailField.stringValue = description }
        else { detailField.stringValue = ([row.folder.string] + row.tags.map { "#" + $0 }).filter { !$0.isEmpty }.joined(separator: " · ") }
        for view in symbols.arrangedSubviews { symbols.removeArrangedSubview(view); view.removeFromSuperview() }
        if row.favorite { addSymbol("star.fill", color: .systemYellow) }
        if row.isReadOnly { addSymbol("lock.fill", color: .secondaryLabelColor) }
        if !row.canRender { addSymbol("exclamationmark.triangle.fill", color: .systemOrange) }
        if case .group = row.access { addSymbol("person.2", color: .secondaryLabelColor) }
        var parts = [row.title, row.relativePath.string]
        if row.favorite { parts.append(Strings.favorite) }
        if row.isReadOnly { parts.append(LibraryStrings.readOnly) }
        if !row.canRender { parts.append(LibraryStrings.invalid) }
        if showsLastUse, let date = row.lastUsedAt { parts.append(LibraryStrings.lastUsed(date)) }
        setAccessibilityElement(true)
        setAccessibilityLabel(parts.joined(separator: ", "))
    }
    private func addSymbol(_ name: String, color: NSColor) {
        let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = color
        symbols.addArrangedSubview(image)
    }
}

private final class LibraryDropHighlightView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class LibraryEmptyStateLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
