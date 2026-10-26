import AppKit
import MonkeysPawCore
import SwiftUI

struct PickerView: View {
    @ObservedObject var presentation: PickerViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation.model.fillModel == nil {
                header.padding(16)
                Divider()
            }
            content.padding(12)
            if !presentation.status.isEmpty {
                Label(presentation.status.replacingOccurrences(of: "\n", with: " · "),
                    systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(presentation.status)
                    .accessibilityLabel(presentation.status)
                    .accessibilityIdentifier("picker-status")
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WishNight())
        .foregroundStyle(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Color.primary : WishCardStyle.primary)
        .tint(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Color.accentColor : WishCardStyle.amber)
        .overlay { WishCardTakeStage(take: presentation.take).allowsHitTesting(false).accessibilityHidden(true) }
        .transaction { if presentation.take.holdsCard { $0.animation = nil; $0.disablesAnimations = true } }
        .onDisappear { presentation.cancelTake() }
        .disabled(presentation.take.holdsCard)
        .allowsHitTesting(!presentation.take.holdsCard)
    }

    @ViewBuilder private var content: some View {
        if presentation.model.fillModel == nil, presentation.model.results.isEmpty {
            PickerEmptyView(presentation: presentation)
        } else {
            HStack(alignment: .top, spacing: 12) {
                if presentation.model.fillModel == nil {
                    PickerResultsView(presentation: presentation)
                        .frame(width: WishCardStyle.resultsWidth)
                        .disabled(presentation.take.holdsCard || presentation.state != .picker)
                }
                ZStack {
                    WishCardSurface(presentation: presentation)
                        .opacity(presentation.proofShown || presentation.take.holdsCard ? 0 : 1)
                        .allowsHitTesting(!presentation.proofShown && !presentation.take.holdsCard)
                        .accessibilityHidden(presentation.proofShown || presentation.take.holdsCard)
                    if presentation.proofShown {
                        ScrollView {
                            Text(presentation.preview).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(WishCardStyle.bodyInk).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading).padding(22)
                        }
                        .background(WishCardStyle.paperTop).clipShape(RoundedRectangle(cornerRadius: 10))
                        .environment(\.colorScheme, .light) // Light scroller on paper, as on the card.
                        .accessibilityIdentifier("wish-proof").accessibilityLabel("Proof")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shadow(color: .black.opacity(0.5), radius: 14, y: 10)
                .shadow(color: WishCardStyle.amber.opacity((presentation.model.fillModel?.warmth ?? 0) * 0.48),
                    radius: CGFloat(16 + (presentation.model.fillModel?.warmth ?? 0) * 18))
                .disabled(presentation.state == .delivering || presentation.take.holdsCard)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
            PickerTextInput(value: presentation.model.query, label: Strings.searchPrompts,
                identifier: "picker-query", kind: nil, wantsFocus: presentation.state == .picker && !presentation.proofShown,
                focusRevision: presentation.focusRevision, onChange: presentation.setQuery,
                font: .preferredFont(forTextStyle: .title2), isBezeled: false,
                style: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .standard : .night)
                .frame(height: 28)
                .disabled(presentation.take.holdsCard)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(Strings.pasteTarget(presentation.pasteTarget))
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                    .help(Strings.pasteTarget(presentation.pasteTarget))
                    .accessibilityIdentifier("picker-target")
                if let syncStatus = presentation.syncStatus {
                    SyncStatusView(presentation: syncStatus)
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            PickerActionsView(presentation: presentation).fixedSize()
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }


}

/// Focus stays in the search field, as in Spotlight, so the list draws its
/// own accent selection instead of a native list's inactive grey.
private struct PickerResultsView: View {
    private struct IndexedResult: Identifiable {
        let position: Int
        let row: PickerResultRow
        var id: Int { position }
    }

    @ObservedObject var presentation: PickerViewState

    var body: some View {
        if presentation.model.results.isEmpty {
            PickerEmptyView(presentation: presentation)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(indexedResults) { result in
                            row(result)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: presentation.model.selectionIndex) { _, position in
                    guard let position else { return }
                    proxy.scrollTo(position)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Strings.promptResults)
        }
    }

    private func row(_ result: IndexedResult) -> some View {
        let selected = result.position == presentation.model.selectionIndex
        return PickerResultView(row: result.row, isSelected: selected)
            .id(result.position)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { activate(result) }
            .onTapGesture { presentation.model.selectResult(at: result.position) }
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { activate(result) }
            .accessibilityIdentifier("picker-result-\(result.position)")
    }

    private func activate(_ result: IndexedResult) {
        presentation.model.selectResult(at: result.position)
        presentation.use(mode: presentation.model.preferredMode)
    }

    private var indexedResults: [IndexedResult] {
        presentation.model.results.enumerated().map { IndexedResult(position: $0.offset, row: $0.element) }
    }
}

private struct PickerResultView: View {
    let row: PickerResultRow
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.favorite ? "star.fill" : "text.alignleft")
                .foregroundStyle(symbolColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(1)
                Text(detail).font(.caption).lineLimit(1)
                    .foregroundStyle(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Color.secondary : WishCardStyle.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Color.primary : WishCardStyle.primary)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? selectionColor : Color.clear))
        .overlay(alignment: .leading) { if isSelected { Capsule().fill(WishCardStyle.amber).frame(width: 3) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((row.favorite ? Strings.favorite + " " : "") + row.title + " " + detail)
    }

    private var selectionColor: Color {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25) : WishCardStyle.amber.opacity(0.18)
    }

    private var symbolColor: Color {
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { return .primary }
        if isSelected || row.favorite { return WishCardStyle.amber }
        return WishCardStyle.secondary
    }

    private var detail: String {
        var parts = [row.folder] + row.tags.map { "#" + $0 }
        if case .group(let group) = row.access { parts.append(group.name) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct PickerEmptyView: View {
    @ObservedObject var presentation: PickerViewState

    var body: some View {
        VStack(spacing: 10) {
            if let noMatches = presentation.model.noMatches {
                Text(noMatches.message)
                Button(Strings.createPrompt(noMatches.query), action: presentation.createNoMatch)
                    .disabled(!presentation.model.libraryAvailable)
                    .accessibilityLabel(noMatches.createLabel)
                Button(Strings.writeWithAssistant) {}
                    .disabled(true)
                    .help(Strings.assistantNotConfigured)
                    .accessibilityLabel(noMatches.writeLabel)
                Text(Strings.assistantNotConfigured).font(.caption).foregroundStyle(.secondary)
                Button(Strings.openLibrary) { presentation.model.openLibrary() }
                    .accessibilityLabel(Strings.openLibrary)
            } else {
                Text(Strings.emptyLibrary)
                Button(Strings.openLibrary) { presentation.model.openLibrary() }
                    .accessibilityLabel(Strings.openLibrary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PickerActionsView: View {
    @ObservedObject var presentation: PickerViewState

    var body: some View {
        HStack(spacing: 8) {
            if let fill = presentation.model.fillModel {
                Button { presentation.perform(.deliver) } label: {
                    keyCap(Strings.deliver, "↩")
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .foregroundStyle(fill.deliverEnabled ? WishCardStyle.color(0x2B1B06) : WishCardStyle.color(0xB9A27A))
                        .background(fill.deliverEnabled ? WishCardStyle.amber : Color.clear)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(WishCardStyle.amber.opacity(0.35), lineWidth: 1))
                }
                    .buttonStyle(.borderless).keyboardShortcut(.defaultAction)
                    .disabled(!fill.builtinsResolved).accessibilityLabel(Strings.deliver)
                    .accessibilityIdentifier("picker-deliver")
                Button { presentation.perform(.copyFilled) } label: { keyCap(Strings.copy, "⌥↩") }
                    .disabled(!fill.builtinsResolved).accessibilityLabel(Strings.copy)
                    .accessibilityIdentifier("picker-copy")
                Button { presentation.perform(.proof) } label: { Text("Proof ⌘P") }
                    .accessibilityLabel("Proof").accessibilityIdentifier("picker-proof")
                    .accessibilityAddTraits(presentation.proofShown ? .isSelected : [])
                Button { presentation.perform(.back) } label: { keyCap(Strings.back, "⎋") }
                    .accessibilityLabel(Strings.back).accessibilityIdentifier("picker-back")
            } else {
                Button { presentation.perform(.paste) } label: { keyCap(Strings.paste, "↩") }
                    .disabled(!presentation.useEnabled).accessibilityLabel(Strings.usePrompt)
                    .accessibilityIdentifier("picker-use")
                Button { presentation.perform(.copy) } label: { keyCap(Strings.copy, "⌥↩") }
                    .disabled(!presentation.useEnabled).accessibilityLabel(Strings.copy)
                    .accessibilityIdentifier("picker-copy")
                Button { presentation.perform(.edit) } label: { keyCap(Strings.edit, "⌘↩") }
                    .disabled(presentation.model.selectionIndex == nil).accessibilityLabel(Strings.edit)
                    .accessibilityIdentifier("picker-edit")
                Button { presentation.perform(.library) } label: { keyCap(Strings.library, "⌘L") }
                    .accessibilityLabel(Strings.library)
                    .accessibilityIdentifier("picker-library")
            }
            moreActions
        }
        .buttonStyle(.borderless)
        .disabled(presentation.state == .delivering || presentation.take.holdsCard)
    }

    private var moreActions: some View {
        Menu {
            if presentation.showsForgetValues {
                Button(Strings.forgetValues, action: presentation.forgetSelectedValues)
                    .disabled(!presentation.canForgetValues)
                    .accessibilityLabel(Strings.forgetValues)
                    .accessibilityIdentifier("picker-forget-values")
            }
            Button(Strings.setup, action: presentation.showSetup)
            Button(Strings.settings, action: presentation.showSettings)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .accessibilityLabel(Strings.pickerMore).accessibilityIdentifier("picker-more")
        .fixedSize()
    }

    private func keyCap(_ title: String, _ keys: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
            Text(keys).foregroundStyle(.secondary)
        }
    }
}
