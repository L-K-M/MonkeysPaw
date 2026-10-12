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

    init(model: OnboardingModel, activeLibraryPath: String, defaultLibraryPath: String,
         mainThread: MainThread, openSettings: @escaping () -> Void) {
        self.model = model
        state = model.state
        self.activeLibraryPath = activeLibraryPath
        self.defaultLibraryPath = defaultLibraryPath
        self.openSettings = openSettings
        model.onChange = { [weak self] in
            mainThread.run { [weak self] in
                guard let self else { return }
                self.state = self.model.state
                self.onChange?()
            }
        }
    }

    var canChooseFolder: Bool {
        state.step == .libraryFolder && !state.isReadOnly
            && state.libraryStatus != .lostWhileRunning && !isChoosingFolder
    }

    var canOfferSeeds: Bool { state.step == .seedOffer && state.libraryStatus == .available && !state.isReadOnly }

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
    func showSettings() { openSettings() }
    func close() { onClose?() }
}

struct OnboardingView: View {
    @ObservedObject var presentation: OnboardingViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    step
                    ForEach(presentation.messages, id: \.self) { message in
                        Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("onboarding-message")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(Strings.settings, action: presentation.showSettings)
                Spacer()
                if presentation.state.step == .complete {
                    Button(Strings.done, action: presentation.close)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("onboarding-done")
                }
            }
        }
        .padding(24)
    }

    @ViewBuilder private var step: some View {
        switch presentation.state.step {
        case .setup:
            EmptyView() // The existing native Setup window owns this step.
        case .libraryFolder:
            Text(OnboardingStrings.libraryFolderTitle).font(.title2)
            Text(OnboardingStrings.libraryFolderHelp)
            Text(Strings.libraryFolder).font(.headline)
            Text(presentation.activeLibraryPath).textSelection(.enabled)
                .accessibilityLabel(Strings.libraryFolder)
                .accessibilityValue(presentation.activeLibraryPath)
                .accessibilityIdentifier("onboarding-active-folder")
            Text(Strings.defaultFolder).font(.headline)
            Text(presentation.defaultLibraryPath).textSelection(.enabled)
                .accessibilityLabel(Strings.defaultFolder)
                .accessibilityValue(presentation.defaultLibraryPath)
            HStack {
                Button(OnboardingStrings.useDefaultFolder, action: presentation.useDefaultFolder)
                    .disabled(!presentation.canChooseFolder)
                    .accessibilityIdentifier("onboarding-use-default")
                Button(OnboardingStrings.chooseFolder + "…", action: presentation.chooseFolder)
                    .disabled(!presentation.canChooseFolder)
                    .accessibilityIdentifier("onboarding-choose-folder")
            }
        case .seedOffer:
            Text(OnboardingStrings.seedOfferTitle).font(.title2)
            Text(OnboardingStrings.seedOfferHelp)
            HStack {
                Button(OnboardingStrings.acceptSeeds, action: presentation.acceptSeeds)
                    .disabled(!presentation.canOfferSeeds)
                    .accessibilityIdentifier("onboarding-accept-seeds")
                Button(OnboardingStrings.declineSeeds, action: presentation.declineSeeds)
                    .disabled(!presentation.canOfferSeeds)
                    .accessibilityIdentifier("onboarding-decline-seeds")
            }
        case .complete:
            Text(Strings.onboardingTitle).font(.title2)
            if let summary = presentation.state.seedSummary {
                Text(OnboardingStrings.seedSummary(summary))
                    .accessibilityLabel(OnboardingStrings.seedSummary(summary))
                    .accessibilityIdentifier("onboarding-seed-summary")
            } else if presentation.messages.isEmpty {
                Text(Strings.onboardingComplete)
            }
        }
    }
}
