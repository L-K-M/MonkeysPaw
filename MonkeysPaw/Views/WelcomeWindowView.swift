import AppKit
import SwiftUI

/// Shared layout for Setup, onboarding and Repeat (§24.5).
struct WelcomeWindowView<Content: View, SecondaryActions: View, DefaultAction: View>: View {
    private let title: String
    private let explanation: String
    private let content: Content
    private let secondaryActions: SecondaryActions
    private let defaultAction: DefaultAction

    init(title: String, explanation: String,
         @ViewBuilder content: () -> Content,
         @ViewBuilder secondaryActions: () -> SecondaryActions,
         @ViewBuilder defaultAction: () -> DefaultAction) {
        self.title = title
        self.explanation = explanation
        self.content = content()
        self.secondaryActions = secondaryActions()
        self.defaultAction = defaultAction()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            bottomBar
        }
        .padding(24)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title)
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            secondaryActions
            Spacer()
            defaultAction
        }
    }
}

/// Symbols accompany status text; colour never carries state alone (§24.5).
enum WelcomeStatusSymbol {
    case ready
    case needsAttention
    case unchecked
}

struct WelcomeStatusRow<Content: View>: View {
    private let symbol: WelcomeStatusSymbol
    private let content: Content

    init(symbol: WelcomeStatusSymbol, @ViewBuilder content: () -> Content) {
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            mark.accessibilityHidden(true)
            content
        }
    }

    @ViewBuilder private var mark: some View {
        switch symbol {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .needsAttention:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .unchecked:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}
