import AppKit
import Combine
import MonkeysPawCore
import SwiftUI

extension SettingsViewState.Tab {
    var title: String {
        switch self {
        case .general: return Strings.generalTab
        case .shortcuts: return Strings.shortcutsTab
        case .delivery: return DeliverySettingsStrings.title
        case .assistant: return SettingsAssistantStrings.tab
        case .account: return SettingsAccountStrings.tab
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .delivery: return "paperplane"
        case .assistant: return "sparkles"
        case .account: return "person.crop.circle"
        }
    }

    private var idealHeight: CGFloat {
        switch self {
        case .general: return 590
        case .shortcuts: return 550
        case .delivery: return 520
        case .assistant: return 820
        case .account: return 900
        }
    }

    // Grouped forms scroll within tall panes instead of growing off screen.
    var contentSize: NSSize { NSSize(width: 600, height: min(idealHeight, 640)) }
}

/// Retains each pane and its draft while the native toolbar selects it.
final class SettingsTabViewController: NSTabViewController {
    private let presentation: SettingsViewState
    private let mainThread: MainThread
    private var isInstallingPanes = true
    private var bindingObserver: AnyCancellable?

    init(presentation: SettingsViewState, mainThread: MainThread) {
        self.presentation = presentation
        self.mainThread = mainThread
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = []
        canPropagateSelectedChildViewControllerTitle = true

        for pane in SettingsViewState.Tab.allCases {
            let content = NSHostingController(rootView: SettingsView(presentation: presentation, pane: pane))
            content.sizingOptions = []
            content.title = pane.title
            content.preferredContentSize = pane.contentSize
            let item = NSTabViewItem(viewController: content)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            addTabViewItem(item)
        }
        isInstallingPanes = false
        select(presentation.selectedTab)
        presentation.onSelectedTabChange = { [weak self] pane in
            self?.mainThread.run { [weak self] in self?.select(pane) }
        }
        // Composition also publishes when a refused drain restores the graph
        // without changing General's path or outcome.
        bindingObserver = presentation.objectWillChange.sink { [weak self] _ in
            self?.mainThread.run { [weak self] in self?.presentation.account.refreshBinding() }
        }
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidAppear() {
        super.viewDidAppear()
        select(presentation.selectedTab)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        let previous = isViewLoaded ? view.window?.frame : nil
        super.tabView(tabView, didSelect: tabViewItem)
        guard !isInstallingPanes,
              let tabViewItem, let index = tabViewItems.firstIndex(where: { $0 === tabViewItem }),
              let pane = SettingsViewState.Tab(rawValue: index) else { return }
        if presentation.selectedTab != pane { presentation.selectedTab = pane }
        resizeWindow(for: pane, anchoredTo: previous)
    }

    func resizeWindowForSelection() { resizeWindow(for: presentation.selectedTab) }

    private func select(_ pane: SettingsViewState.Tab) {
        if selectedTabViewItemIndex != pane.rawValue { selectedTabViewItemIndex = pane.rawValue }
        resizeWindow(for: pane)
    }

    private func resizeWindow(for pane: SettingsViewState.Tab, anchoredTo previousFrame: NSRect? = nil) {
        title = pane.title
        guard isViewLoaded, let window = view.window else { return }
        window.title = pane.title
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: pane.contentSize)).size
        let previous = previousFrame ?? window.frame
        let frame = NSRect(x: previous.minX, y: previous.maxY - size.height, width: size.width, height: size.height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true,
            animate: window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}
