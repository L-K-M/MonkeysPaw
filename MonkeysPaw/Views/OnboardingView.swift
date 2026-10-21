import MonkeysPawCore
import SwiftUI

/// Owns onboarding's view hook; composition supplies paths after graph changes.
final class OnboardingViewState: ObservableObject {
    @Published private(set) var state: OnboardingModel.State
    @Published private(set) var activeLibraryPath: String
    @Published private(set) var defaultLibraryPath: String
    @Published var isChoosingFolder = false
    let model: OnboardingModel
    var onChange: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onClose: (() -> Void)?
    private let openSettings: () -> Void
    private let openInvite: () -> Void

    init(model: OnboardingModel, activeLibraryPath: String, defaultLibraryPath: String,
         mainThread: MainThread, openSettings: @escaping () -> Void, openInvite: @escaping () -> Void = {}) {
        self.model = model
        state = model.state
        self.activeLibraryPath = activeLibraryPath
        self.defaultLibraryPath = defaultLibraryPath
        self.openSettings = openSettings
        self.openInvite = openInvite
        model.onChange = { [weak self] in
            mainThread.run { [weak self] in
                guard let self else { return }
                let previousStep = self.state.step
                self.state = self.model.state
                self.onChange?()
                if previousStep == .tour && self.state.step == .complete { self.onClose?() }
            }
        }
    }

    var canChooseFolder: Bool {
        state.step == .libraryFolder && !state.isReadOnly
            && state.libraryStatus != .lostWhileRunning && !isChoosingFolder
    }

    var canOfferSeeds: Bool { state.step == .seedOffer && state.libraryStatus == .available && !state.isReadOnly }
    var canCompleteTour: Bool { state.step == .tour && state.libraryStatus == .available && !state.isReadOnly }

    var messages: [String] {
        var messages = SettingsViewState.generalMessages(for: state.lastSwitchMessage,
            switchMessage: state.lastSwitchMessage.flatMap(GeneralSettingsStrings.message),
            settingsError: state.settingsError)
        if state.libraryStatus == .lostWhileRunning { messages.append(OnboardingStrings.restartForLibrary) }
        if let failure = state.seedFailure { messages.append(OnboardingStrings.seedFailure(failure)) }
        return messages
    }

    func updateLibraryPaths(active: String, default defaultPath: String) {
        activeLibraryPath = active
        defaultLibraryPath = defaultPath
    }

    func chooseFolder() { if canChooseFolder { onChooseFolder?() } }
    func useDefaultFolder() { if canChooseFolder { model.useDefaultFolder() } }
    func acceptSeeds() { if canOfferSeeds { model.acceptSeeds() } }
    func declineSeeds() { if canOfferSeeds { model.declineSeeds() } }
    func completeTour() { if canCompleteTour { model.completeTour() } }
    func showSettings() { openSettings() }
    func showInvite() { openInvite() }
    func close() {
        if state.step == .tour { completeTour() }
        else { onClose?() }
    }
}

struct OnboardingView: View {
    @ObservedObject var presentation: OnboardingViewState

    var body: some View {
        WelcomeWindowView(title: Strings.onboardingTitle, explanation: WelcomeStrings.onboardingExplanation) {
            step
            inviteButton
            messages
        } secondaryActions: {
            secondaryButtons
        } defaultAction: {
            primaryButton
        }
    }

    private var inviteButton: some View {
        Button(SettingsInviteStrings.title, action: presentation.showInvite)
            .accessibilityIdentifier("onboarding-invite")
    }

    private var messages: some View {
        ForEach(presentation.messages, id: \.self) { message in
            WelcomeStatusRow(symbol: .needsAttention) {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding-message")
            }
        }
    }

    @ViewBuilder private var secondaryButtons: some View {
        if presentation.state.step != .tour {
            Button(Strings.settings, action: presentation.showSettings)
        }
        if presentation.state.step == .libraryFolder {
            Button(OnboardingStrings.chooseFolder + "…", action: presentation.chooseFolder)
                .disabled(!presentation.canChooseFolder)
                .accessibilityIdentifier("onboarding-choose-folder")
        } else if presentation.state.step == .seedOffer {
            Button(OnboardingStrings.declineSeeds, action: presentation.declineSeeds)
                .disabled(!presentation.canOfferSeeds)
                .accessibilityIdentifier("onboarding-decline-seeds")
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch presentation.state.step {
        case .libraryFolder:
            Button(OnboardingStrings.useDefaultFolder, action: presentation.useDefaultFolder)
                .disabled(!presentation.canChooseFolder)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-use-default")
        case .seedOffer:
            Button(OnboardingStrings.acceptSeeds, action: presentation.acceptSeeds)
                .disabled(!presentation.canOfferSeeds)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-accept-seeds")
        case .tour:
            Button(OnboardingStrings.completeTour, action: presentation.completeTour)
                .disabled(!presentation.canCompleteTour)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-done")
        case .complete:
            Button(Strings.done, action: presentation.close)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-done")
        case .setup: EmptyView()
        }
    }

    @ViewBuilder private var step: some View {
        switch presentation.state.step {
        case .setup:
            EmptyView() // The existing native Setup window owns this step.
        case .libraryFolder:
            libraryFolderStep
        case .seedOffer:
            seedOfferStep
        case .tour:
            tourStep
        case .complete:
            completeStep
        }
    }

    private var libraryFolderStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            WelcomeStatusRow(symbol: librarySymbol) {
                Text(OnboardingStrings.libraryFolderTitle).font(.headline)
            }
            Text(OnboardingStrings.libraryFolderHelp)
            LabeledContent(Strings.libraryFolder) {
                Text(presentation.activeLibraryPath)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(presentation.activeLibraryPath)
                    .accessibilityLabel(Strings.libraryFolder)
                    .accessibilityValue(presentation.activeLibraryPath)
                    .accessibilityIdentifier("onboarding-active-folder")
            }
            LabeledContent(Strings.defaultFolder) {
                Text(presentation.defaultLibraryPath)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(presentation.defaultLibraryPath)
                    .accessibilityLabel(Strings.defaultFolder)
                    .accessibilityValue(presentation.defaultLibraryPath)
            }
        }
    }

    private var seedOfferStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            WelcomeStatusRow(symbol: .unchecked) {
                Text(OnboardingStrings.seedOfferTitle).font(.headline)
            }
            Text(OnboardingStrings.seedOfferHelp)
        }
    }

    private var tourStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            WelcomeStatusRow(symbol: librarySymbol) {
                Text(OnboardingStrings.tourTitle).font(.headline)
                    .accessibilityIdentifier("onboarding-tour-title")
            }
            Text(OnboardingStrings.tourHelp).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding-tour-help")
            seedResult
        }
    }

    @ViewBuilder private var completeStep: some View {
        if presentation.state.seedSummary != nil {
            seedResult
        } else if presentation.messages.isEmpty {
            WelcomeStatusRow(symbol: .ready) { Text(Strings.onboardingComplete) }
        }
    }

    @ViewBuilder private var seedResult: some View {
        if let summary = presentation.state.seedSummary {
            WelcomeStatusRow(symbol: .ready) {
                Text(OnboardingStrings.seedSummary(summary))
                    .accessibilityLabel(OnboardingStrings.seedSummary(summary))
                    .accessibilityIdentifier("onboarding-seed-summary")
            }
        }
    }

    private var librarySymbol: WelcomeStatusSymbol {
        presentation.state.libraryStatus == .available ? .ready : .needsAttention
    }
}
