import AppKit
import MonkeysPawCore
import SwiftUI

struct WishCardView: View {
    @ObservedObject var presentation: PickerViewState
    @State private var sheenPosition: CGFloat = -1

    private var fill: FillModel? { presentation.model.fillModel }
    private var card: PromptCard? { fill?.card ?? presentation.model.selectedCard }
    private var row: PickerResultRow? {
        let picker = presentation.model
        guard let index = picker.selectionIndex, picker.results.indices.contains(index) else { return nil }
        return picker.results[index]
    }
    private var title: String { fill?.title ?? row?.title ?? "" }
    private var folder: String { fill?.folder ?? row?.folder ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        WishCardFlowLayout {
                            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                                runView(run, width: geometry.size.width)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        // Keeps a field at a line's edge, and its caret, inside the clip.
                        .padding(.horizontal, WishCardStyle.fieldOverhang)
                        .padding(.bottom, 18)
                    }
                    .onChange(of: fill?.focusIndex) { _, index in reveal(index, with: proxy) }
                    .onChange(of: presentation.focusRevision) { _, _ in reveal(fill?.focusIndex, with: proxy) }
                }
            }
            if fill != nil {
                Text(presentation.gloss).font(.custom("Palatino", size: 12)).italic()
                    .foregroundStyle(presentation.nudgeIndex == nil ? WishCardStyle.folderInk : WishCardStyle.errorInk)
                    .lineLimit(1).truncationMode(.tail).help(presentation.gloss)
                    .accessibilityLabel(presentation.gloss)
                    .accessibilityIdentifier("wish-gloss")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    .overlay(alignment: .top) { Rectangle().fill(WishCardStyle.brassRim.opacity(0.25)).frame(height: 0.5) }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(WishCardStyle.brassRim.opacity(0.3))
                    Capsule().fill(LinearGradient(colors: [WishCardStyle.focusInk, WishCardStyle.brassTop],
                        startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * CGFloat(fill?.warmth ?? 0))
                }
            }.frame(height: 3).accessibilityHidden(true)
        }
        .padding(.horizontal, WishCardStyle.paperInset).padding(.top, 18).padding(.bottom, 14)
        .background(LinearGradient(colors: [WishCardStyle.paperTop, WishCardStyle.paperBottom],
            startPoint: .top, endPoint: .bottom))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(WishCardStyle.brassRim.opacity(0.25), lineWidth: 1))
        .overlay {
            if !presentation.reduceMotion() {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, .white.opacity(0.45), WishCardStyle.brassTop.opacity(0.15), .clear],
                        startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.35, height: geometry.size.height * 2)
                        .rotationEffect(.degrees(22))
                        .offset(x: geometry.size.width * sheenPosition, y: -geometry.size.height / 2)
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("wish-card")
        .disabled(presentation.state == .delivering || presentation.take.holdsCard || presentation.proofShown)
        .onChange(of: presentation.sheenRevision) { _, _ in
            guard !presentation.reduceMotion() else { return }
            sheenPosition = -1
            let revision = presentation.sheenRevision
            DispatchQueue.main.async {
                guard presentation.sheenRevision == revision, !presentation.reduceMotion() else { return }
                withAnimation(.easeOut(duration: WishCardStyle.sheen)) { sheenPosition = 1.5 }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(1.6)
                .foregroundStyle(WishCardStyle.titleInk).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Circle().fill(LinearGradient(colors: [WishCardStyle.brassTop, WishCardStyle.brassBottom],
                startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().stroke(WishCardStyle.brassRim, lineWidth: 1))
                .frame(width: 12, height: 12).accessibilityHidden(true)
            Text(folder.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(1.6)
                .foregroundStyle(WishCardStyle.folderInk).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 140, alignment: .trailing).help(folder)
        }
    }

    private func reveal(_ index: Int?, with proxy: ScrollViewProxy) {
        guard let index else { return }
        proxy.scrollTo("wish-blank-\(index)", anchor: .center)
    }

    private var runs: [WishCardRun] {
        guard let card else { return WishCardRun.literal(presentation.preview) }
        return card.segments.flatMap { segment in
            if case .text(let text) = segment { return WishCardRun.literal(text) }
            return [.segment(segment)]
        }
    }

    @ViewBuilder private func runView(_ run: WishCardRun, width: CGFloat) -> some View {
        switch run {
        case .newline:
            Color.clear.frame(width: 0, height: 0).layoutValue(key: WishBreak.self, value: true)
        case .text(let text, let markup):
            Text(text).font(markup ? .system(size: 11, design: .monospaced)
                : .custom(WishCardStyle.serif.fontName, fixedSize: 15))
                .foregroundStyle(markup ? WishCardStyle.tagInk : (card == nil ? WishCardStyle.errorInk : WishCardStyle.bodyInk))
                .fixedSize(horizontal: false, vertical: true)
        case .segment(.builtin(.clipboard)):
            WishCardSlip(content: presentation.clipboardSlip)
                .equatable().layoutValue(key: WishWide.self, value: true)
        case .segment(.builtin(let name)):
            Text((fill?.builtinText(name) ?? name.rawValue).uppercased())
                .font(.system(size: 11, weight: .bold)).tracking(1)
                .foregroundStyle(WishCardStyle.stamp).padding(.horizontal, 5).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(WishCardStyle.stamp, lineWidth: 1.5))
                .rotationEffect(.degrees(-2))
        case .segment(.field(let name, let label, let kind, let occurrence)):
            if let fill, let index = fill.fields.firstIndex(where: { $0.name == name }) {
                if occurrence == 0 {
                    WishCardSlot(presentation: presentation, model: fill, field: fill.fields[index], position: index,
                        lineWidth: width, wantsFocus: fill.state == .editing && fill.focusIndex == index && !presentation.proofShown)
                        .id("wish-blank-\(index)").layoutValue(key: WishWide.self, value: kind == .multiline)
                } else {
                    let field = fill.fields[index]
                    Button {
                        if presentation.model.fillModel === fill { presentation.focusField(at: index) }
                    } label: {
                        Text(field.value.isEmpty ? label : field.value)
                            .font(.custom(WishCardStyle.fieldFont(field.provenance).fontName, fixedSize: 15))
                            .foregroundStyle(Color(nsColor: WishCardStyle.ink(field.provenance,
                                phase: presentation.inkPhase(name))))
                            .overlay(alignment: .bottom) { Rectangle().fill(WishCardStyle.blankRule).frame(height: 0.5) }
                    }
                    .buttonStyle(.borderless).focusable(false)
                    .accessibilityLabel(label).accessibilityValue(field.value).accessibilityHint(Text(field.description ?? "")).help(field.description ?? "")
                }
            } else {
                Text(label.uppercased())
                    .font(kind == .multiline ? .system(size: 12, design: .monospaced) : .system(size: 11, weight: .semibold))
                    .foregroundStyle(WishCardStyle.folderInk)
                    .frame(maxWidth: kind == .multiline ? .infinity : nil, alignment: .leading)
                    .padding(.horizontal, kind == .multiline ? 10 : 3).padding(.vertical, kind == .multiline ? 7 : 3)
                    .background(kind == .multiline ? WishCardStyle.well : Color.clear)
                    .overlay(alignment: .bottom) { Rectangle().fill(WishCardStyle.blankRule).frame(height: 1) }
                    .accessibilityLabel(label)
                    .layoutValue(key: WishWide.self, value: kind == .multiline)
            }
        case .segment(.text(let text)):
            Text(text)
        }
    }
}

private enum WishCardRun {
    case text(String, Bool), newline, segment(PromptCard.Segment)

    static func literal(_ text: String) -> [Self] {
        var result: [Self] = []
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }.map(String.init)
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(.newline) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let markup = trimmed.hasPrefix("<") && trimmed.hasSuffix(">")
                && trimmed.dropFirst().dropLast().allSatisfy { $0.isLetter || $0.isNumber || "/_-".contains($0) }
            var run = ""
            var wasSpace: Bool?
            for character in line {
                let space = character.isWhitespace
                if let prior = wasSpace, prior != space { result.append(.text(run, markup)); run = "" }
                run.append(character)
                wasSpace = space
            }
            if !run.isEmpty { result.append(.text(run, markup)) }
        }
        return result
    }
}

private struct WishCardSlot: View {
    @ObservedObject var presentation: PickerViewState
    let model: FillModel
    let field: FillFieldState
    let position: Int
    let lineWidth: CGFloat
    let wantsFocus: Bool
    @State private var appeared = false
    @State private var shake: CGFloat = 0

    private var phase: WishInkPhase { presentation.inkPhase(field.name) }
    private var width: CGFloat {
        if field.kind == .multiline { return lineWidth }
        let label = field.kind == .choice ? field.options.first { $0.value == field.value }?.label ?? field.value : field.value
        let measured = WishCardStyle.slotWidth(value: label, label: field.label,
            font: WishCardStyle.fieldFont(field.provenance), lineWidth: lineWidth)
        return min(lineWidth, measured + (field.kind == .choice ? 26 : 0))
    }

    var body: some View {
        // The flow layout proposes the scroll content's width, which a legacy
        // scroller narrows. Slots shrink to it rather than overflow under the bar.
        control.frame(minWidth: 0, idealWidth: width, maxWidth: field.kind == .multiline ? .infinity : width)
            .background(wantsFocus ? WishCardStyle.amber.opacity(0.12) : Color.clear)
            .overlay(alignment: .bottom) {
                if field.kind != .multiline {
                    Rectangle().fill(wantsFocus ? WishCardStyle.focusInk : WishCardStyle.blankRule)
                        .frame(height: wantsFocus ? 2 : 1)
                }
            }
            .alignmentGuide(.firstTextBaseline) { _ in field.kind == .multiline ? 22 : 18 }
            .opacity(appeared || presentation.reduceMotion() ? 1 : 0)
            .offset(x: shake)
            .onAppear {
                if presentation.reduceMotion() { appeared = true }
                else {
                    withAnimation(.easeOut(duration: WishCardStyle.ink).delay(Double(position) * WishCardStyle.stagger)) { appeared = true }
                }
            }
            .onChange(of: presentation.nudgeRevision) { _, _ in nudge() }
    }

    @ViewBuilder private var control: some View {
        switch field.kind {
        case .text:
            PickerTextInput(value: field.value, label: field.label, identifier: "fill-field-" + field.name,
                wantsFocus: wantsFocus, focusRevision: presentation.focusRevision, onChange: change,
                onFocus: focus, font: WishCardStyle.fieldFont(field.provenance), isBezeled: false,
                resetRevision: presentation.inputResetRevision, style: .paper(field.provenance, phase), fieldHelp: field.description)
                .frame(height: 26)
        case .multiline:
            PickerMultilineInput(value: field.value, label: field.label, identifier: "fill-field-" + field.name,
                wantsFocus: wantsFocus, focusRevision: presentation.focusRevision, onChange: change, onFocus: focus,
                resetRevision: presentation.inputResetRevision, style: .paper(field.provenance, phase), fieldHelp: field.description)
                .frame(height: min(170, max(48, CGFloat(field.value.components(separatedBy: "\n").count) * 16 + 18)))
                .background(WishCardStyle.well).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if field.value.isEmpty {
                        Text(field.label + (field.optional ? " (optional)" : ""))
                            .font(.system(size: 12, design: .monospaced)).italic()
                            .foregroundStyle(WishCardStyle.folderInk).padding(7).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(wantsFocus ? WishCardStyle.focusInk : Color.clear, lineWidth: 1.5))
        case .choice:
            WishCardChoiceInput(field: field, wantsFocus: wantsFocus, focusRevision: presentation.focusRevision,
                phase: phase, reduceMotion: presentation.reduceMotion, onChange: change, onFocus: focus).frame(height: 26)
        }
    }

    private func change(_ value: String) {
        guard presentation.model.fillModel === model else { return }
        presentation.setValue(value, field: field)
    }

    private func focus() {
        guard presentation.model.fillModel === model else { return }
        model.focusField(at: position)
    }

    private func nudge() {
        guard presentation.nudgeIndex == position, !presentation.reduceMotion() else { return }
        let revision = presentation.nudgeRevision
        for step in 0...6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * WishCardStyle.nudge / 6) {
                guard presentation.nudgeRevision == revision, presentation.nudgeIndex == position,
                      !presentation.take.holdsCard else { shake = 0; return }
                shake = step == 6 ? 0 : (step.isMultiple(of: 2) ? -6 : 6)
            }
        }
    }
}
