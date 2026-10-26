#if os(Linux)
import CGtk
import MonkeysPawCore

/// GTK renders Core state and forwards intents. Environment callbacks own
/// leave-the-panel actions; this view never opens files or calls services.
final class LinuxPanel: PanelWindow {
    private final class Preedit {
        var isActive = false
    }

    private let window: GTK.Widget
    private var isDestroyed = false
    private weak var picker: PickerModel?
    private weak var boundFill: FillModel?
    private var initialFocus: GTK.Widget?
    private var blurRevision = 0
    private var activationToken: String?
    private var isRendering = false
    private var renderedResults: [PickerResultRow] = []
    private var renderedFocus: Int?
    private let sounds: LinuxFeedbackSounds
    let take: LinuxPawTake
    private var takeRevision = 0
    private var isTaking = false
    /// The take finished and delivery is under way: the live card stays
    /// hidden until the panel hides, so it never flashes back in between.
    private var takeHeld = false
    /// The Escape that cancelled a take may still be held; its repeats must
    /// not then back out of the card.
    private var swallowsEscapeRepeats = false
    private var cardView: LinuxWishCard?
    private var renderedCard: PromptCard?
    /// The shown card is bound to a form. `boundFill` is weak and clears once
    /// a delivered model is released, so it cannot say what is on screen.
    private var cardIsLive = false
    private var renderedFallback: String?
    private var proofShown = false
    private var queryRevealer: GTK.Widget!
    private var resultsRevealer: GTK.Widget!
    private var proofStack: GTK.Widget!
    private var cardHost: GTK.Widget!
    private var transientStatus: String?
    private var queryPreedit: Preedit?
    private var openSettings: (() -> Void)?
    private var syncStatusView: LinuxSyncStatusView?

    private var queryEntry: GTK.Widget!
    private var stack: GTK.Widget!
    private var resultsList: GTK.Widget!
    private var noMatchesBox: GTK.Widget!
    private var noMatchesLabel: GTK.Widget!
    private var createButton: GTK.Widget!
    private var assistantButton: GTK.Widget!
    private var assistantHint: GTK.Widget!
    private var folderButton: GTK.Widget!
    private var preview: GTK.Widget!
    private var hint: GTK.Widget!
    private var status: GTK.Widget!
    private var actions: GTK.Widget!
    private var useButton: GTK.Widget!
    private var copyButton: GTK.Widget!
    private var forgetButton: GTK.Widget!
    private var editButton: GTK.Widget!
    private var libraryButton: GTK.Widget!
    private var proofButton: GTK.Widget!
    private var menuPopover: GTK.Widget?

    var clipboardOwner: GTK.Widget { window }
    var isVisible: Bool { !isDestroyed && gtk_widget_get_visible(window) != 0 }
    var isActiveAndVisible: Bool { isVisible && gtk_window_is_active(mp_window(window)) != 0 }

    init(application: UnsafeMutablePointer<GtkApplication>, sounds: LinuxFeedbackSounds = LinuxFeedbackSounds(),
         pawFrames: LinuxPawFrames = LinuxPawFrames()) {
        self.sounds = sounds
        take = LinuxPawTake(frames: pawFrames)
        take.playCue = { [weak sounds] in sounds?.play($0) }
        window = gtk_application_window_new(application)!
        GTK.hideOnClose(window)
        LinuxStyle.install(on: window)
        WishCardStyle.install(on: window)
        if mp_high_contrast() == 0 { gtk_widget_add_css_class(window, "mp-night") }
        // Transient launcher panel: no titlebar, rounded corners and a theme
        // border drawn by the mp-picker CSS (§24.5).
        gtk_window_set_decorated(mp_window(window), 0)
        gtk_widget_add_css_class(window, "mp-picker")
        gtk_window_set_title(mp_window(window), AppIdentity.displayName)
        gtk_window_set_default_size(mp_window(window),
                                    Int32(Limits.panelSize.width), Int32(Limits.panelSize.height))
        gtk_widget_set_focusable(window, 1)
        GTK.onSignal(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            guard let self else { return }
            // GTK owns the window; its Swift wrapper and queued UI work can outlive it.
            self.cancelTake()
            self.cardView?.retire()
            self.isDestroyed = true
            self.syncStatusView?.retire(.destroyed)
            self.blurRevision += 1
            self.trace("destroy", reason: "native")
        }

        if LinuxPickerTrace.isEnabled {
            for signal in ["show", "hide", "realize", "unrealize", "map", "unmap"] {
                GTK.onSignal(UnsafeMutableRawPointer(window), signal) { [weak self] in
                    guard let self else { return }
                    self.trace("signal", reason: "native", signal: signal)
                    if signal == "realize", let native = gtk_widget_get_native(self.window),
                       let surface = gtk_native_get_surface(native) {
                        GTK.onNotify(UnsafeMutableRawPointer(surface), "mapped") { [weak self] in
                            self?.trace("surface.mapped", reason: "native")
                        }
                    }
                }
            }
        }
        trace("created", reason: "application-window")

        // The window survives library switches. Install its controllers once;
        // they always use the current binding rather than a captured picker.
        GTK.observeKeys(window) { [weak self] key, modifiers, isRepeat in
            self?.keyPressed(key, modifiers: modifiers, isRepeat: isRepeat) ?? false
        }
        GTK.onCloseRequested(window) { [weak self] in
            guard let self, !self.isDestroyed else { return }
            self.trace("dismiss.request", reason: "close-request")
            if let picker = self.picker { picker.dismiss() } else { self.hide() }
        }
        GTK.onNotify(UnsafeMutableRawPointer(window), "is-active") { [weak self] in self?.focusChanged() }
        GTK.onNotify(UnsafeMutableRawPointer(window), "focus-widget") { [weak self] in self?.fieldFocusChanged() }
        GTK.onNotify(UnsafeMutableRawPointer(window), "visible") { [weak self] in
            guard let self, !self.isDestroyed else { return }
            if self.isVisible { self.syncStatusView?.show() }
            else { self.cancelTake(); self.syncStatusView?.suspend() }
        }
        if let settings = gtk_settings_get_default() {
            GTK.onNotify(UnsafeMutableRawPointer(settings), "gtk-theme-name") { [weak self] in
                guard let self, !self.isDestroyed else { return }
                if mp_high_contrast() != 0 { gtk_widget_remove_css_class(self.window, "mp-night") }
                else { gtk_widget_add_css_class(self.window, "mp-night") }
            }
        }
    }

    deinit {
        // GtkApplication may retain the native window after the environment
        // releases this driver. Retire custom children before their Swift
        // owners (and their weak teardown callbacks) disappear.
        if !isDestroyed {
            cancelTake()
            cardView?.retire()
        }
        syncStatusView?.retire(isDestroyed ? .destroyed : .rebind)
    }

    func rebind(picker: PickerModel, session: DesktopSession, openSetup: @escaping () -> Void,
                openSettings: @escaping () -> Void,
                syncStatus: SyncStatusModel? = nil,
                syncNavigation: @escaping (SyncStatusAction) -> Void = { _ in },
                requestedIntent: @escaping (PickerModel.Intent) -> Void,
                createPrompt: @escaping (String) -> Void) {
        guard !isDestroyed else { return }
        cancelTake()
        cardView?.retire()
        cardView = nil
        renderedCard = nil
        cardIsLive = false
        renderedFallback = nil
        proofShown = false
        syncStatusView?.retire()
        self.picker?.onChange = nil
        self.picker = nil
        blurRevision += 1 // Retire a blur timeout queued by the previous view.
        isRendering = true
        gtk_window_set_focus(mp_window(window), nil)
        boundFill = nil
        initialFocus = nil
        renderedResults = []
        renderedFocus = nil
        transientStatus = nil
        queryPreedit = nil
        menuPopover = nil
        gtk_window_set_child(mp_window(window), nil)
        isRendering = false
        self.picker = picker
        trace("rebind", reason: "library-graph")
        self.openSettings = openSettings
        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(content, 12) }

        queryEntry = gtk_search_entry_new()!
        queryPreedit = observePreedit(in: mp_entry_text_delegate(queryEntry))
        gtk_widget_set_name(queryEntry, "picker-query")
        GTK.searchPlaceholder(queryEntry, LinuxStrings.searchPrompts)
        gtk_widget_add_css_class(queryEntry, "mp-picker-search")
        mp_accessible_label(queryEntry, LinuxStrings.searchPrompts)
        initialFocus = queryEntry
        queryRevealer = gtk_revealer_new()!
        // Instant swaps: animating widths reflows the card's sentence every
        // frame. The card's ink-in and sheen carry the arrival instead.
        gtk_revealer_set_transition_type(mp_revealer(queryRevealer), GTK_REVEALER_TRANSITION_TYPE_NONE)
        gtk_revealer_set_reveal_child(mp_revealer(queryRevealer), 1)
        gtk_revealer_set_child(mp_revealer(queryRevealer), queryEntry)
        gtk_box_append(mp_box(content), queryRevealer)
        GTK.onSignal(queryEntry, "changed") { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker,
                  !self.isRendering else { return }
            self.transientStatus = nil
            picker.setQuery(String(cString: mp_entry_text(self.queryEntry)))
        }

        let split = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!
        gtk_widget_set_vexpand(split, 1)
        stack = gtk_stack_new()!
        gtk_widget_set_hexpand(stack, 1)
        let pickerPage = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        resultsList = gtk_list_box_new()!
        gtk_widget_set_name(resultsList, "picker-results")
        gtk_list_box_set_selection_mode(mp_list_box(resultsList), GTK_SELECTION_SINGLE)
        gtk_list_box_set_activate_on_single_click(mp_list_box(resultsList), 0)
        let listScroll = scrolled(resultsList)
        gtk_box_append(mp_box(pickerPage), listScroll)
        GTK.onRow(resultsList, "row-selected") { [weak self, weak picker] position in
            guard let self, !self.isDestroyed, let picker, self.picker === picker,
                  !self.isRendering, let position,
                  picker.selectionIndex != position else { return }
            picker.selectResult(at: position)
        }
        GTK.onRow(resultsList, "row-activated") { [weak self, weak picker] position in
            guard let self, !self.isDestroyed, let picker, self.picker === picker,
                  !self.isRendering, let position else { return }
            picker.selectResult(at: position)
            self.usePreferred()
        }

        noMatchesBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        noMatchesLabel = GTK.label("")
        gtk_box_append(mp_box(noMatchesBox), noMatchesLabel)
        createButton = GTK.button("", { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker,
                  let noMatches = picker.noMatches else { return }
            createPrompt(noMatches.createTitle)
        })
        gtk_box_append(mp_box(noMatchesBox), createButton)
        assistantButton = GTK.button("", {})
        gtk_widget_set_sensitive(assistantButton, 0)
        gtk_widget_set_tooltip_text(assistantButton, LinuxStrings.assistantNotConfigured)
        // Labels are supplied by the Core no-match state during rendering.
        gtk_widget_set_name(assistantButton, "picker-assistant")
        gtk_box_append(mp_box(noMatchesBox), assistantButton)
        assistantHint = GTK.label(LinuxStrings.assistantNotConfigured)
        gtk_box_append(mp_box(noMatchesBox), assistantHint)
        folderButton = GTK.button("", { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            picker.openLibrary()
        })
        gtk_widget_set_name(folderButton, "picker-library")
        gtk_box_append(mp_box(noMatchesBox), folderButton)
        gtk_box_append(mp_box(pickerPage), noMatchesBox)
        gtk_stack_add_named(mp_stack(stack), pickerPage, "picker")

        resultsRevealer = gtk_revealer_new()!
        gtk_revealer_set_transition_type(mp_revealer(resultsRevealer), GTK_REVEALER_TRANSITION_TYPE_NONE)
        gtk_revealer_set_reveal_child(mp_revealer(resultsRevealer), 1)
        gtk_revealer_set_child(mp_revealer(resultsRevealer), stack)
        // A fixed column keeps the panel at its size; titles ellipsize.
        gtk_widget_set_size_request(stack, Int32(WishCardStyle.resultsWidth), -1)
        gtk_box_append(mp_box(split), resultsRevealer)
        proofStack = gtk_stack_new()!
        gtk_widget_set_name(proofStack, "picker-proof-stack")
        gtk_stack_set_hhomogeneous(mp_stack(proofStack), 0)
        gtk_stack_set_vhomogeneous(mp_stack(proofStack), 0)
        gtk_widget_set_hexpand(proofStack, 1)
        gtk_widget_set_vexpand(proofStack, 1)
        // The card scrolls its own text, so the paper, gloss and wick stay put.
        cardHost = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_widget_set_vexpand(cardHost, 1)
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(cardHost, Int32(WishCardStyle.cardGap)) }
        gtk_stack_add_named(mp_stack(proofStack), cardHost, "card")
        preview = gtk_text_view_new()!
        gtk_widget_set_name(preview, "picker-preview")
        mp_accessible_label(preview, LinuxStrings.preview)
        gtk_text_view_set_editable(mp_text_view(preview), 0)
        gtk_text_view_set_cursor_visible(mp_text_view(preview), 0)
        gtk_text_view_set_wrap_mode(mp_text_view(preview), GTK_WRAP_WORD_CHAR)
        let previewScroll = scrolled(preview)
        gtk_widget_set_hexpand(previewScroll, 1)
        gtk_widget_add_css_class(previewScroll, "mp-proof")
        gtk_stack_add_named(mp_stack(proofStack), previewScroll, "proof")
        gtk_stack_set_visible_child_name(mp_stack(proofStack), "card")
        gtk_box_append(mp_box(split), proofStack)
        gtk_box_append(mp_box(content), split)

        status = GTK.label("")
        gtk_widget_set_name(status, "picker-status")
        gtk_box_append(mp_box(content), status)

        // Footer: session/target and sync captions on the left, flat key-hint
        // buttons and the overflow menu on the right (§24.5).
        let footer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        let captions = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        gtk_widget_set_hexpand(captions, 1)
        let sessionLabel = GTK.label(LinuxStrings.pickerSession(session))
        hint = GTK.label(picker.deliveryHint + " · " + LinuxPickerStrings.escapePicker)
        gtk_widget_set_name(hint, "picker-hint")
        gtk_widget_set_tooltip_text(hint, LinuxStrings.pickerHint)
        gtk_widget_set_hexpand(hint, 1)
        gtk_label_set_wrap(mp_label(hint), 0)
        gtk_label_set_ellipsize(mp_label(hint), PANGO_ELLIPSIZE_END)
        for caption in [sessionLabel, hint] {
            gtk_widget_add_css_class(caption, "dim-label")
            gtk_widget_add_css_class(caption, "caption")
        }
        let target = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(mp_box(target), sessionLabel)
        gtk_box_append(mp_box(target), hint)
        gtk_box_append(mp_box(captions), target)
        let syncView = LinuxSyncStatusView(surface: .picker)
        syncStatusView = syncView
        gtk_widget_add_css_class(syncView.widget, "mp-picker-footer-sync")
        syncView.bind(syncStatus, navigate: syncNavigation)
        let bottom = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        gtk_widget_set_hexpand(syncView.widget, 1)
        gtk_box_append(mp_box(footer), captions)
        gtk_box_append(mp_box(bottom), syncView.widget)

        actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        gtk_widget_set_halign(actions, GTK_ALIGN_END)
        gtk_widget_set_valign(actions, GTK_ALIGN_END)
        useButton = GTK.button(LinuxPickerStrings.useHint) { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            self.usePreferred()
        }
        copyButton = GTK.button(LinuxPickerStrings.copyHint) { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            self.use(mode: .copyOnly)
        }
        editButton = GTK.button(LinuxPickerStrings.editHint) { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            picker.editSelected()
        }
        libraryButton = GTK.button(LinuxPickerStrings.libraryHint) { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            picker.openLibrary()
        }
        gtk_widget_set_name(useButton, "picker-use")
        gtk_widget_set_name(copyButton, "picker-copy")
        gtk_widget_set_name(editButton, "picker-edit")
        gtk_widget_set_name(libraryButton, "picker-open-folder")
        mp_accessible_label(copyButton, LinuxStrings.copy)
        mp_accessible_label(editButton, LinuxStrings.edit)
        mp_accessible_label(libraryButton, LinuxStrings.library)
        let menu = gtk_menu_button_new()!
        gtk_widget_set_name(menu, "picker-menu")
        gtk_widget_set_tooltip_text(menu, LinuxPickerStrings.moreActions)
        mp_accessible_label(menu, LinuxPickerStrings.moreActions)
        gtk_menu_button_set_icon_name(mp_menu_button(menu), "view-more-symbolic")
        gtk_menu_button_set_has_frame(mp_menu_button(menu), 0)
        let menuBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        for edge in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                     gtk_widget_set_margin_start, gtk_widget_set_margin_end] { edge(menuBox, 8) }
        forgetButton = menuItem(LinuxStrings.forgetValues, name: "picker-forget-values") {
            [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            self.closeMenu()
            self.transientStatus = nil
            picker.forgetSelectedValues()
        }
        mp_accessible_label(forgetButton, LinuxStrings.forgetValues)
        gtk_box_append(mp_box(menuBox), forgetButton)
        gtk_box_append(mp_box(menuBox), menuItem(LinuxStrings.setup, name: "picker-setup") {
            [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            self.closeMenu()
            openSetup()
        })
        gtk_box_append(mp_box(menuBox), menuItem(LinuxStrings.openSettings, name: "picker-settings") {
            [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            self.closeMenu()
            openSettings()
        })
        let popover = gtk_popover_new()!
        menuPopover = popover
        gtk_popover_set_child(mp_popover(popover), menuBox)
        gtk_menu_button_set_popover(mp_menu_button(menu), popover)
        for button in [useButton!, copyButton!, editButton!, libraryButton!] {
            gtk_widget_add_css_class(button, "flat")
            gtk_box_append(mp_box(actions), button)
        }
        proofButton = GTK.button(LinuxPickerStrings.proofHint) { [weak self] in self?.toggleProof() }
        gtk_widget_set_name(proofButton, "picker-proof")
        gtk_widget_add_css_class(proofButton, "flat")
        gtk_box_append(mp_box(actions), proofButton)
        gtk_box_append(mp_box(actions), menu)
        gtk_box_append(mp_box(bottom), actions)
        gtk_box_append(mp_box(footer), bottom)
        gtk_box_append(mp_box(content), footer)
        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(mp_overlay(overlay), content)
        gtk_overlay_add_overlay(mp_overlay(overlay), take.widget)
        gtk_window_set_child(mp_window(window), overlay)
        if isVisible { syncView.show() }

        picker.onChange = { [weak self, weak picker] in
            guard let self, !self.isDestroyed, let picker, self.picker === picker else { return }
            self.trace("model.changed", reason: "onChange")
            if picker.state == .picker, let intent = picker.takeRequestedIntent() {
                requestedIntent(intent)
                return
            }
            self.render()
        }
        render()
    }

    private func render() {
        guard !isDestroyed, let picker else { return }
        guard picker.state != .closed else { cancelTake(); return }
        if case .done = picker.state { return } // Delivery owns the hide.
        guard !isRendering else { return }
        releaseHeldTake()
        let wasTaking = isTaking
        isRendering = true
        defer {
            isRendering = false
            if wasTaking && !isTaking { restoreEditingFocus() }
        }
        let editing = picker.state != .delivering
        if !editing || (picker.state == .fill && boundFill !== picker.fillModel)
            || (picker.state == .picker && boundFill != nil) {
            // Let native text controls receive focus-out while still enabled.
            // Disabling/hiding their page first loses that event on GTK 4.8.
            gtk_window_set_focus(mp_window(window), nil)
        }
        gtk_widget_set_sensitive(queryEntry, picker.state == .picker && !isTaking ? 1 : 0)
        gtk_widget_set_sensitive(proofStack, editing && !isTaking ? 1 : 0)
        gtk_widget_set_sensitive(stack, editing && !isTaking ? 1 : 0)
        gtk_widget_set_sensitive(actions, editing && !isTaking ? 1 : 0)
        let hasPrompt = picker.fillModel != nil || picker.selectionIndex.map { picker.results.indices.contains($0) } == true
        gtk_widget_set_visible(forgetButton, hasPrompt ? 1 : 0)
        gtk_widget_set_sensitive(forgetButton, editing ? 1 : 0)
        renderStatus(picker)
        guard editing else { return }

        if String(cString: mp_entry_text(queryEntry)) != picker.query { mp_entry_set_text(queryEntry, picker.query) }
        if picker.state == .fill, let fill = picker.fillModel {
            let newForm = boundFill !== fill
            if newForm {
                cancelTake()
                boundFill = fill
                replaceCard(card: fill.card, title: fill.title, folder: fill.folder, fill: fill)
            }
            revealPicker(false)
            cardView?.update()
            switch fill.preview {
            case .rendered(let text): setPreview(text)
            case .blocked(let error, let issues):
                let message = fill.builtinsResolved ? error.description : LinuxStrings.preparingPreview
                setPreview(([message] + issues.map(\.message)).joined(separator: "\n"))
            }
            // The outlined Deliver action stays reachable to explain/focus a
            // blocked blank. The model still gates every actual delivery.
            gtk_widget_set_sensitive(useButton, 1)
            gtk_widget_set_sensitive(copyButton, fill.canCopyOnly ? 1 : 0)
            if let position = fill.focusIndex, let field = cardView?.fieldWidget(at: position),
               newForm || renderedFocus != position {
                initialFocus = field
                gtk_widget_grab_focus(field)
                cardView?.reveal(index: position)
            }
            renderedFocus = fill.focusIndex
        } else {
            let wasFill = boundFill != nil
            boundFill = nil
            renderedFocus = nil
            revealPicker(true)
            renderResults(picker)
            switch picker.selectedPreview {
            case .body(let text): setPreview(text)
            case .issues(let issues): setPreview(issues.map(\.message).joined(separator: "\n"))
            case .renderFailure(let error): setPreview(error.description)
            case .none: setPreview("")
            }
            let fallback: String
            switch picker.selectedPreview {
            case .issues(let issues): fallback = issues.map(\.message).joined(separator: "\n")
            case .renderFailure(let error): fallback = error.description
            case .none: fallback = ""
            case .body(let text): fallback = text
            }
            let row = picker.selectionIndex.flatMap { picker.results.indices.contains($0) ? picker.results[$0] : nil }
            if wasFill || cardIsLive || renderedCard != picker.selectedCard || (picker.selectedCard == nil && renderedFallback != fallback) || cardView == nil {
                cancelTake()
                replaceCard(card: picker.selectedCard, title: row?.title ?? "", folder: row?.folder ?? "", fallback: fallback)
            } else { cardView?.updateHeader(title: row?.title ?? "", folder: row?.folder ?? "") }
            initialFocus = queryEntry
            if wasFill { gtk_widget_grab_focus(queryEntry) }
            let enabled = picker.selectionIndex.map {
                picker.results.indices.contains($0) && picker.results[$0].canRender
            } == true && !picker.isResolvingBuiltins
            gtk_widget_set_sensitive(useButton, enabled ? 1 : 0)
            gtk_widget_set_sensitive(copyButton, enabled ? 1 : 0)
        }
        let inFill = picker.state == .fill
        gtk_button_set_label(mp_button(useButton), inFill ? LinuxPickerStrings.deliverHint : LinuxPickerStrings.useHint)
        if inFill {
            gtk_widget_remove_css_class(useButton, "flat")
            gtk_widget_add_css_class(useButton, "suggested-action")
            gtk_widget_add_css_class(useButton, "mp-deliver")
            if picker.fillModel?.deliverEnabled == true { gtk_widget_add_css_class(useButton, "mp-ready") }
            else { gtk_widget_remove_css_class(useButton, "mp-ready") }
            mp_accessible_label(useButton, LinuxStrings.deliver)
        } else {
            gtk_widget_remove_css_class(useButton, "suggested-action")
            gtk_widget_remove_css_class(useButton, "mp-deliver")
            gtk_widget_remove_css_class(useButton, "mp-ready")
            gtk_widget_add_css_class(useButton, "flat")
            mp_accessible_label(useButton, LinuxStrings.usePrompt)
        }
        gtk_widget_set_visible(editButton, inFill ? 0 : 1)
        gtk_widget_set_sensitive(editButton, picker.selectionIndex == nil ? 0 : 1)
        gtk_widget_set_visible(libraryButton, inFill ? 0 : 1)
        // The picker footer is full; Ctrl+P still toggles the proof there.
        gtk_widget_set_visible(proofButton, inFill ? 1 : 0)
        let deliveryHint = picker.fillModel?.deliveryHint ?? picker.deliveryHint
        gtk_label_set_text(mp_label(hint), deliveryHint + " · " + (inFill ? LinuxPickerStrings.escapeFill : LinuxPickerStrings.escapePicker))
        gtk_widget_set_tooltip_text(hint, inFill ? LinuxStrings.fillHint : LinuxStrings.pickerHint)
        // Replacing a form/selection above can cancel an in-flight take.
        gtk_widget_set_sensitive(queryEntry, !isTaking && !inFill ? 1 : 0)
        for widget in [stack!, proofStack!, actions!] { gtk_widget_set_sensitive(widget, isTaking ? 0 : 1) }
    }

    private func renderStatus(_ picker: PickerModel) {
        var warnings = picker.persistenceWarnings
        for warning in picker.fillModel?.persistenceWarnings ?? [] where !warnings.contains(warning) { warnings.append(warning) }
        var messages = [picker.libraryAvailable ? nil : LinuxStrings.libraryUnavailable,
                        picker.isResolvingBuiltins ? LinuxStrings.resolvingBuiltins : nil].compactMap { $0 }
        if let transientStatus, !messages.contains(transientStatus) { messages.append(transientStatus) }
        messages += warnings.map(LinuxStrings.persistenceWarning)
        if let error = picker.forgetValuesError {
            messages.append(LinuxStrings.forgetValuesError(error, state: picker.state))
        }
        gtk_label_set_text(mp_label(status), messages.joined(separator: "\n"))
        gtk_widget_set_visible(status, messages.isEmpty ? 0 : 1)
    }

    private func renderResults(_ picker: PickerModel) {
        if renderedResults != picker.results {
            while let child = gtk_widget_get_first_child(resultsList) { gtk_list_box_remove(mp_list_box(resultsList), child) }
            renderedResults = picker.results
            for result in picker.results {
                let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
                let icon = gtk_image_new_from_icon_name(
                    result.favorite ? "starred-symbolic" : "text-x-generic-symbolic")!
                if result.favorite { gtk_widget_add_css_class(icon, "mp-favorite") }
                gtk_widget_set_valign(icon, GTK_ALIGN_CENTER)
                gtk_box_append(mp_box(row), icon)
                let text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
                let title = GTK.label(result.title)
                gtk_box_append(mp_box(text), title)
                let subtitle = GTK.label(resultSubtitle(result))
                for css in ["dim-label", "caption"] { gtk_widget_add_css_class(subtitle, css) }
                // One line each: the fixed results column must not grow rows.
                for label in [title, subtitle] {
                    gtk_label_set_wrap(mp_label(label), 0)
                    gtk_label_set_ellipsize(mp_label(label), PANGO_ELLIPSIZE_END)
                }
                gtk_box_append(mp_box(text), subtitle)
                gtk_box_append(mp_box(row), text)
                gtk_list_box_append(mp_list_box(resultsList), row)
            }
        }
        let row = picker.selectionIndex.flatMap { gtk_list_box_get_row_at_index(mp_list_box(resultsList), Int32($0)) }
        gtk_list_box_select_row(mp_list_box(resultsList), row)
        let noMatches = picker.noMatches
        gtk_widget_set_visible(noMatchesBox, picker.results.isEmpty ? 1 : 0)
        gtk_label_set_text(mp_label(noMatchesLabel), noMatches?.message ?? LinuxStrings.emptyLibrary)
        gtk_button_set_label(mp_button(createButton), noMatches?.createLabel ?? "")
        gtk_widget_set_visible(createButton, noMatches == nil ? 0 : 1)
        gtk_widget_set_sensitive(createButton, picker.libraryAvailable ? 1 : 0)
        gtk_button_set_label(mp_button(assistantButton), noMatches?.writeLabel ?? "")
        gtk_widget_set_visible(assistantButton, noMatches == nil ? 0 : 1)
        gtk_widget_set_visible(assistantHint, noMatches == nil ? 0 : 1)
        gtk_button_set_label(mp_button(folderButton), LinuxStrings.library)
    }

    /// folder · #tags · group — the last component names the sync group when
    /// the prompt is group-owned (§24.5).
    private func resultSubtitle(_ result: PickerResultRow) -> String {
        var parts = [result.folder] + result.tags.map { "#" + $0 }
        if case .group(let group) = result.access { parts.append(group.name) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Menu items are real buttons so tests can find and activate them by name.
    private func menuItem(_ title: String, name: String, action: @escaping () -> Void) -> GTK.Widget {
        let button = GTK.button(title, action)
        gtk_widget_set_name(button, name)
        gtk_widget_add_css_class(button, "flat")
        if let label = gtk_button_get_child(mp_button(button)) {
            gtk_widget_set_hexpand(label, 1)
            gtk_label_set_xalign(mp_label(label), 0)
        }
        return button
    }

    private func closeMenu() {
        if let menuPopover { gtk_popover_popdown(mp_popover(menuPopover)) }
    }

    private func replaceCard(card: PromptCard?, title: String, folder: String,
                             fill: FillModel? = nil, fallback: String = "") {
        cardView?.retire()
        while let child = gtk_widget_get_first_child(cardHost) { gtk_box_remove(mp_box(cardHost), child) }
        let view = LinuxWishCard(card: card, title: title, folder: folder, fill: fill, fallback: fallback, sounds: sounds)
        cardView = view
        cardIsLive = fill != nil
        renderedCard = card
        renderedFallback = fallback
        gtk_box_append(mp_box(cardHost), view.widget)
    }

    private func revealPicker(_ visible: Bool) {
        // Visibility, not reveal-child: GTK 4.8 revealers without a slide
        // keep measuring a concealed child at full size.
        gtk_widget_set_visible(queryRevealer, visible ? 1 : 0)
        gtk_widget_set_visible(resultsRevealer, visible ? 1 : 0)
    }

    private func toggleProof() {
        guard !isDestroyed, !isTaking else { return }
        proofShown.toggle()
        gtk_stack_set_visible_child_name(mp_stack(proofStack), proofShown ? "proof" : "card")
        if !proofShown, let index = boundFill?.focusIndex, let field = cardView?.fieldWidget(at: index) {
            gtk_widget_grab_focus(field)
        }
    }

    private func setPreview(_ text: String) { gtk_text_buffer_set_text(gtk_text_view_get_buffer(mp_text_view(preview)), text, -1) }

    private func scrolled(_ child: GTK.Widget) -> GTK.Widget {
        let scroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(mp_scrolled_window(scroll), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(mp_scrolled_window(scroll), child)
        gtk_widget_set_vexpand(scroll, 1)
        return scroll
    }

    private var focusedControl: Int? {
        guard !isDestroyed else { return nil }
        return cardView?.focusedIndex(gtk_window_get_focus(mp_window(window)))
    }

    private func observePreedit(in widget: GTK.Widget?) -> Preedit? {
        guard !isDestroyed, let widget else { return nil }
        let preedit = Preedit()
        GTK.onPreeditChanged(widget) { [weak self] active in
            guard let self, !self.isDestroyed else { return }
            preedit.isActive = active
        }
        return preedit
    }

    private var focusedHasPreedit: Bool {
        guard !isDestroyed, let focus = gtk_window_get_focus(mp_window(window)) else { return false }
        if focus == queryEntry || gtk_widget_is_ancestor(focus, queryEntry) != 0 {
            return queryPreedit?.isActive == true
        }
        return cardView?.hasPreedit(focus) ?? false
    }

    private func fieldFocusChanged() {
        trace("focus.changed", reason: "focus-widget")
        guard !isDestroyed, !isRendering, let position = focusedControl else { return }
        picker?.fillModel?.focusField(at: position)
    }

    private func keyPressed(_ key: UInt32, modifiers: UInt32, isRepeat: Bool) -> Bool {
        // Capture runs before GtkText/GtkTextView's input method. Composition
        // keys must reach the focused native control without picker intents.
        guard !isDestroyed, let picker else { return false }
        if !isRepeat { swallowsEscapeRepeats = false }
        if swallowsEscapeRepeats && key == UInt32(GDK_KEY_Escape) { return true }
        if isTaking || takeHeld {
            guard isTaking else { return true }
            if key == UInt32(GDK_KEY_Escape) {
                cancelTake()
                render()
                restoreEditingFocus()
                swallowsEscapeRepeats = true
            } else if !isRepeat && [UInt32(GDK_KEY_Return), UInt32(GDK_KEY_KP_Enter), UInt32(GDK_KEY_ISO_Enter)].contains(key) {
                take.finish()
            }
            return true
        }
        guard !focusedHasPreedit else { return false }
        // An open overflow menu keeps native navigation: its Escape closes the
        // popover rather than the panel, and arrows select menu items.
        if let menuPopover, gtk_widget_get_visible(menuPopover) != 0 { return false }
        if cardView?.choicePopoverOpen == true { return false }
        let focus = gtk_window_get_focus(mp_window(window))
        if cardView?.handleKey(key, modifiers: modifiers, focus: focus) == true { return true }
        let kind = focusedControl.flatMap { picker.fillModel?.fields[$0].kind }
        guard let intent = LinuxPickerKeys.intent(for: key, modifiers: modifiers, state: picker.state, fieldKind: kind) else { return false }
        if intent == .usePreferred, let focus = gtk_window_get_focus(mp_window(window)), mp_is_button(focus) != 0 {
            return false // Native button activation must keep its own intent.
        }
        switch intent {
        case .moveUp: picker.moveSelection(.up)
        case .moveDown: picker.moveSelection(.down)
        case .use(let mode): use(mode: mode)
        case .usePreferred: usePreferred()
        case .edit: picker.editSelected()
        case .openLibrary: picker.openLibrary()
        case .openSettings: openSettings?()
        case .escape:
            trace("escape.request", reason: "key")
            picker.escape()
        case .focusNext: picker.fillModel?.focusNext()
        case .focusPrevious: picker.fillModel?.focusPrevious()
        case .deliverPreferred: usePreferred()
        case .deliver(let mode): use(mode: mode)
        case .toggleProof: toggleProof()
        }
        return true
    }

    private func usePreferred() {
        guard !isDestroyed, let picker else { return }
        use(mode: picker.state == .fill ? picker.fillModel?.preferredMode ?? picker.preferredMode : picker.preferredMode)
    }

    private func use(mode: DeliveryMode) {
        guard !isDestroyed, !isTaking, let picker else { return }
        if picker.state == .fill, let fill = picker.fillModel {
            guard fill.state == .editing else { return }
            // A pending clipboard read resolves within moments; it is not a
            // blank to point at.
            guard fill.builtinsResolved else { return }
            guard fill.deliverEnabled else { cardView?.nudge(); return }
            startTake { [weak fill] in fill?.deliver(mode: mode) }
        } else if picker.state == .picker {
            guard !picker.isResolvingBuiltins else { return }
            guard let card = picker.selectedCard, !card.hasFields else { picker.use(mode: mode); return }
            startTake { [weak picker] in picker?.use(mode: mode) }
        }
    }

    private func startTake(_ deliver: @escaping () -> Void) {
        guard !isDestroyed, !isTaking, let cardView, let picker else { return }
        guard WishCardMotion.enabled else { deliver(); return }
        if proofShown {
            proofShown = false
            gtk_stack_set_visible_child_name(mp_stack(proofStack), "card")
        }
        isTaking = true
        takeRevision += 1
        let revision = takeRevision
        let state = picker.state
        let fill = picker.fillModel
        let selectedIdentity = picker.selectionIndex.flatMap { picker.results.indices.contains($0) ? picker.results[$0].identity : nil }
        // Native editors must receive focus-out while they are still enabled.
        gtk_window_set_focus(mp_window(window), nil)
        gtk_widget_set_sensitive(actions, 0)
        gtk_widget_set_sensitive(queryEntry, 0)
        gtk_widget_set_sensitive(stack, 0)
        gtk_widget_set_sensitive(proofStack, 0)
        take.play(card: cardView.widget) { [weak self, weak picker] in
            guard let self, !self.isDestroyed, self.isVisible, self.takeRevision == revision else { return }
            let selectionMatches = state != .picker || picker?.selectionIndex.flatMap { index in
                picker?.results.indices.contains(index) == true ? picker?.results[index].identity : nil
            } == selectedIdentity
            guard let picker, self.picker === picker, picker.state == state,
                  picker.fillModel === fill, selectionMatches else {
                self.cancelTake()
                self.render()
                self.restoreEditingFocus()
                return
            }
            self.isTaking = false
            self.takeHeld = true
            deliver()
            self.releaseHeldTake()
            self.render()
            self.restoreEditingFocus()
        }
    }

    private func restoreEditingFocus() {
        guard !isDestroyed, isVisible, !isTaking, let picker else { return }
        let target: GTK.Widget
        switch picker.state {
        case .fill:
            guard let fill = picker.fillModel, fill.state == .editing, let index = fill.focusIndex,
                  let field = cardView?.fieldWidget(at: index) else { return }
            target = field
        case .picker: target = queryEntry
        default: return // Delivery retains its clipboard, hide and focus order.
        }
        initialFocus = target
        gtk_widget_grab_focus(target)
    }

    private func cancelTake() {
        takeRevision += 1
        isTaking = false
        takeHeld = false
        take.cancel()
    }

    /// Brings a held card back only when no delivery is under way, e.g. a
    /// render that turned out blocked leaves the form editing again.
    private func releaseHeldTake() {
        guard takeHeld, let picker else { return }
        let idle: Bool
        switch picker.state {
        case .picker: idle = !picker.isResolvingBuiltins
        case .fill: idle = picker.fillModel?.state == .editing
        default: idle = false
        }
        guard idle else { return }
        takeHeld = false
        take.cancel()
    }

    func showStatus(_ message: String) {
        guard !isDestroyed else { return }
        transientStatus = message
        render()
    }

    private func focusChanged() {
        guard !isDestroyed else { return }
        blurRevision += 1
        let revision = blurRevision
        trace("focus.changed", reason: "is-active")
        guard isVisible, !isActiveAndVisible else { return }
        trace("blur.queued", reason: "inactive")
        GTK.after(Limits.blurHideDelay.timeInterval) { [weak self] in
            self?.trace("blur.fired", reason: "timeout", revision: revision)
            guard let self, !self.isDestroyed, self.blurRevision == revision,
                  self.isVisible, !self.isActiveAndVisible else { return }
            self.trace("dismiss.request", reason: "blur")
            self.picker?.dismiss()
        }
    }

    func cancelPendingBlur() {
        // Retire blur at the open intent: the queued GLib show can run after
        // the old timeout, which would otherwise dismiss the new picker.
        blurRevision += 1
        trace("blur.cancelled", reason: "open-intent")
    }

    func useActivationToken(_ token: String?) { activationToken = token }

    func show() {
        trace("show.request", reason: "delivery.show")
        guard !isDestroyed else { return }
        blurRevision += 1
        if let activationToken {
            gtk_window_set_startup_id(mp_window(window), activationToken)
            self.activationToken = nil
        }
        trace("present.begin", reason: "delivery.show")
        gtk_window_present(mp_window(window))
        trace("present.end", reason: "delivery.show")
        gtk_widget_grab_focus(initialFocus ?? window)
        trace("focus.request", reason: "initial-widget")
    }

    func hideForDelivery() { hide(reason: "delivery") }

    func hide() { hide(reason: "delivery.dismiss") }

    func hide(reason: StaticString) {
        trace("hide.request", reason: reason)
        guard !isDestroyed else { return }
        cancelTake()
        blurRevision += 1
        transientStatus = nil
        gtk_widget_set_visible(window, 0)
        trace("hide.end", reason: reason)
    }

    private func trace(_ event: StaticString, reason: StaticString,
                       signal: String = "none", revision: Int? = nil) {
        guard LinuxPickerTrace.isEnabled else { return }
        guard !isDestroyed else {
            LinuxPickerTrace.record(event, "reason=\(reason) destroyed=true")
            return
        }
        let surface = gtk_widget_get_native(window).flatMap { gtk_native_get_surface($0) }
        let surfaceMapped = surface.map { String(gdk_surface_get_mapped($0) != 0) } ?? "none"
        LinuxPickerTrace.record(event, "reason=\(reason) signal=\(signal) visible=\(isVisible)"
            + " realized=\(gtk_widget_get_realized(window) != 0) mapped=\(gtk_widget_get_mapped(window) != 0)"
            + " surfaceMapped=\(surfaceMapped)"
            + " active=\(gtk_window_is_active(mp_window(window)) != 0)"
            + " state=\(LinuxPickerTrace.pickerState(picker?.state)) blur=\(blurRevision)"
            + " timer=\(revision.map(String.init) ?? "none")")
    }
}
#endif
