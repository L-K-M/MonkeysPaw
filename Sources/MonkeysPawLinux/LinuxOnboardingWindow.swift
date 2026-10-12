#if os(Linux)
import CGtk
import MonkeysPawCore

/// A reusable view over first-run and recovery presentation state.
/// GTK owns the window and children; Swift keeps guarded borrowed pointers.
final class LinuxOnboardingWindow {
    private let window: GTK.Widget
    private let model: OnboardingModel
    private let general: GeneralSettingsModel
    private let chooser: LinuxFolderChoosing
    private var isDestroyed = false
    private var isChoosing = false
    private var chooserRevision = 0

    private var folderPage: GTK.Widget!
    private var seedPage: GTK.Widget!
    private var completePage: GTK.Widget!
    private var libraryPath: GTK.Widget!
    private var libraryDefault: GTK.Widget!
    private var libraryMessage: GTK.Widget!
    private var settingsError: GTK.Widget!
    private var chooseButton: GTK.Widget!
    private var defaultButton: GTK.Widget!
    private var seedSummary: GTK.Widget!
    private var seedFailure: GTK.Widget!
    private var completeMessage: GTK.Widget!
    private var libraryStatus: GTK.Widget!

    private var isVisible: Bool { !isDestroyed && gtk_widget_get_visible(window) != 0 }
    private var isFolderStep: Bool {
        model.state.step == .libraryFolder && !model.state.isReadOnly && !general.state.isReadOnly
    }
    private var canCompleteFolder: Bool { isFolderStep && model.state.libraryStatus != .lostWhileRunning }

    init(application: UnsafeMutablePointer<GtkApplication>, model: OnboardingModel,
         general: GeneralSettingsModel, chooser: LinuxFolderChoosing) {
        self.model = model
        self.general = general
        self.chooser = chooser
        window = gtk_application_window_new(application)!
        GTK.hideOnClose(window)
        gtk_widget_set_name(window, "onboarding-window")
        gtk_window_set_title(mp_window(window), LinuxStrings.onboarding)
        gtk_window_set_default_size(mp_window(window), Int32(Limits.panelSize.width), Int32(Limits.panelSize.height))
        GTK.onSignal(window, "destroy") { [weak self] in
            guard let self else { return }
            self.isDestroyed = true
            self.cancelFolderChoice()
            self.model.onChange = nil
            self.general.onChange = nil
        }
        GTK.onNotify(UnsafeMutableRawPointer(window), "visible") { [weak self] in
            guard let self, !self.isVisible else { return }
            self.cancelFolderChoice()
        }

        let content = pageBox()
        folderPage = libraryFolderPage()
        seedPage = seedOfferPage()
        completePage = completionPage()
        for page in [folderPage!, seedPage!, completePage!] { gtk_box_append(mp_box(content), page) }
        settingsError = namedLabel("onboarding-settings-error", in: content)
        libraryStatus = namedLabel("onboarding-library-status", in: content)
        let close = GTK.button(LinuxStrings.close) { [weak self] in
            guard let self, self.isVisible else { return }
            self.hide()
        }
        gtk_widget_set_name(close, "onboarding-close")
        gtk_box_append(mp_box(content), close)
        let scroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(mp_scrolled_window(scroll), content)
        gtk_window_set_child(mp_window(window), scroll)

        model.onChange = { [weak self] in
            guard let self, !self.isDestroyed else { return }
            // Onboarding can replace the graph without going through General.
            self.general.refresh()
            self.render()
        }
        general.onChange = { [weak self] in self?.render() }
        render()
    }

    deinit {
        if isChoosing { chooser.cancel() }
        model.onChange = nil
        general.onChange = nil
    }

    func show() {
        guard !isDestroyed else { return }
        model.refresh()
        general.refresh()
        render()
        gtk_window_present(mp_window(window))
    }

    func hide() {
        guard !isDestroyed else { return }
        gtk_widget_set_visible(window, 0)
        cancelFolderChoice()
    }

    private func libraryFolderPage() -> GTK.Widget {
        let page = pageBox()
        gtk_box_append(mp_box(page), GTK.label(OnboardingStrings.libraryFolderTitle))
        gtk_box_append(mp_box(page), GTK.label(OnboardingStrings.libraryFolderHelp))
        libraryPath = namedLabel("onboarding-library-path", in: page)
        gtk_label_set_selectable(mp_label(libraryPath), 1)
        gtk_label_set_wrap_mode(mp_label(libraryPath), PANGO_WRAP_WORD_CHAR)
        mp_accessible_label(libraryPath, LinuxStrings.libraryFolder)
        libraryDefault = namedLabel("onboarding-library-default", in: page)

        let buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        defaultButton = GTK.button(OnboardingStrings.useDefaultFolder) { [weak self] in
            guard let self, self.isVisible, self.canCompleteFolder, !self.isChoosing else { return }
            self.model.useDefaultFolder()
        }
        gtk_widget_set_name(defaultButton, "onboarding-use-default")
        chooseButton = GTK.button(OnboardingStrings.chooseFolder + "…") { [weak self] in self?.chooseFolder() }
        gtk_widget_set_name(chooseButton, "onboarding-choose-folder")
        gtk_box_append(mp_box(buttons), defaultButton)
        gtk_box_append(mp_box(buttons), chooseButton)
        gtk_box_append(mp_box(page), buttons)
        libraryMessage = namedLabel("onboarding-library-message", in: page)
        return page
    }

    private func seedOfferPage() -> GTK.Widget {
        let page = pageBox()
        gtk_box_append(mp_box(page), GTK.label(OnboardingStrings.seedOfferTitle))
        gtk_box_append(mp_box(page), GTK.label(OnboardingStrings.seedOfferHelp))
        let buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let accept = GTK.button(OnboardingStrings.acceptSeeds) { [weak self] in
            guard let self, self.isVisible, self.model.state.step == .seedOffer,
                  !self.model.state.isReadOnly else { return }
            self.model.acceptSeeds()
        }
        gtk_widget_set_name(accept, "onboarding-accept-seeds")
        let decline = GTK.button(OnboardingStrings.declineSeeds) { [weak self] in
            guard let self, self.isVisible, self.model.state.step == .seedOffer,
                  !self.model.state.isReadOnly else { return }
            self.model.declineSeeds()
        }
        gtk_widget_set_name(decline, "onboarding-decline-seeds")
        gtk_box_append(mp_box(buttons), accept)
        gtk_box_append(mp_box(buttons), decline)
        gtk_box_append(mp_box(page), buttons)
        return page
    }

    private func completionPage() -> GTK.Widget {
        let page = pageBox()
        seedSummary = namedLabel("onboarding-seed-summary", in: page)
        seedFailure = namedLabel("onboarding-seed-failure", in: page)
        completeMessage = namedLabel("onboarding-complete", in: page)
        return page
    }

    private func render() {
        guard !isDestroyed else { return }
        let state = model.state
        if !canCompleteFolder { cancelFolderChoice() }
        // Setup has its own window. Rendering never presents this one, so
        // suppressed read-only steps cannot reopen onboarding automatically.
        gtk_widget_set_visible(folderPage, isFolderStep ? 1 : 0)
        gtk_widget_set_visible(seedPage, state.step == .seedOffer ? 1 : 0)
        gtk_widget_set_visible(completePage, state.step == .complete ? 1 : 0)
        renderFolder()

        let error = state.settingsError ?? general.state.settingsError
        setMessage(settingsError, error.map(GeneralSettingsStrings.settingsError))
        setMessage(libraryStatus, state.libraryStatus == .lostWhileRunning ? OnboardingStrings.restartForLibrary : nil)
        setMessage(seedSummary, state.seedSummary.map(OnboardingStrings.seedSummary))
        setMessage(seedFailure, state.seedFailure.map(OnboardingStrings.seedFailure))
        let hasResult = state.seedSummary != nil || state.seedFailure != nil
        setMessage(completeMessage, !state.isReadOnly && state.libraryStatus == .available && error == nil && !hasResult
            ? LinuxStrings.onboardingComplete : nil)
    }

    private func renderFolder() {
        guard !isDestroyed else { return }
        let state = general.state
        gtk_label_set_text(mp_label(libraryPath), state.activeLibraryPath)
        gtk_label_set_text(mp_label(libraryDefault), state.isDefaultLibrary
            ? LinuxStrings.defaultLibraryFolder : LinuxStrings.customLibraryFolder)
        setMessage(libraryMessage, model.state.lastSwitchMessage.flatMap(GeneralSettingsStrings.message))
        let canChoose = canCompleteFolder && !isChoosing
        gtk_widget_set_sensitive(defaultButton, canChoose ? 1 : 0)
        gtk_widget_set_sensitive(chooseButton, canChoose ? 1 : 0)
    }

    private func chooseFolder() {
        guard isVisible, canCompleteFolder, !isChoosing else { return }
        isChoosing = true
        chooserRevision += 1
        let revision = chooserRevision
        renderFolder()
        chooser.chooseFolder(parent: window, currentPath: general.state.activeLibraryPath) { [weak self] path in
            // Injected choosers may reply off-thread or retain cancelled replies.
            GTK.onMainLoop { [weak self] in
                guard let self, self.isVisible, self.canCompleteFolder, self.isChoosing,
                      self.chooserRevision == revision else { return }
                self.isChoosing = false
                self.renderFolder()
                if let path { self.model.chooseFolder(path) }
            }
        }
    }

    private func cancelFolderChoice() {
        // The chooser is shared with Settings; retire only our own request.
        guard isChoosing else { return }
        chooserRevision += 1
        isChoosing = false
        chooser.cancel()
        renderFolder()
    }

    private func setMessage(_ label: GTK.Widget, _ text: String?) {
        gtk_label_set_text(mp_label(label), text ?? "")
        gtk_widget_set_visible(label, text?.isEmpty == false ? 1 : 0)
    }

    private func namedLabel(_ name: String, in page: GTK.Widget) -> GTK.Widget {
        let label = GTK.label("")
        gtk_widget_set_name(label, name)
        gtk_box_append(mp_box(page), label)
        return label
    }

    private func pageBox() -> GTK.Widget {
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(box, 12) }
        return box
    }
}
#endif
