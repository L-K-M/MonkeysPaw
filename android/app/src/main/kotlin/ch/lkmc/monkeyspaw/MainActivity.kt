package ch.lkmc.monkeyspaw

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.BackHandler
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ch.lkmc.monkeyspaw.core.AppIdentity
import ch.lkmc.monkeyspaw.data.AndroidKeyboardTileSetup
import ch.lkmc.monkeyspaw.data.ForegroundProfileInstaller
import ch.lkmc.monkeyspaw.data.SyncForegroundOwner
import ch.lkmc.monkeyspaw.ui.account.*
import ch.lkmc.monkeyspaw.entry.FillActivity
import ch.lkmc.monkeyspaw.entry.FillLauncher
import ch.lkmc.monkeyspaw.ui.editor.EditorScreen
import ch.lkmc.monkeyspaw.ui.editor.EditorDecisionDialogs
import ch.lkmc.monkeyspaw.ui.editor.EditorViewModel
import ch.lkmc.monkeyspaw.ui.assistant.WriteScreen
import ch.lkmc.monkeyspaw.ui.assistant.WriteViewModel
import ch.lkmc.monkeyspaw.ui.assistant.ReviewScreen
import ch.lkmc.monkeyspaw.ui.assistant.ReviewViewModel
import ch.lkmc.monkeyspaw.ui.assistant.ReviewDestination
import ch.lkmc.monkeyspaw.ui.assistant.ImproveScreen
import ch.lkmc.monkeyspaw.ui.assistant.ImproveViewModel
import ch.lkmc.monkeyspaw.ui.library.LibraryScreen
import ch.lkmc.monkeyspaw.ui.library.LibrarySelection
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import ch.lkmc.monkeyspaw.ui.settings.AssistantSettingsScreen
import ch.lkmc.monkeyspaw.ui.settings.AssistantSettingsViewModel
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferScreen
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferUiState
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferViewModel
import ch.lkmc.monkeyspaw.ui.setup.KeyboardTileSetupError
import ch.lkmc.monkeyspaw.ui.setup.KeyboardTileSetupScreen
import ch.lkmc.monkeyspaw.ui.setup.KeyboardTileSetupViewModel
import ch.lkmc.monkeyspaw.ui.setup.SettingsScreen
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

/** Launcher-only routes. Entry activities keep their local Library/Fill graph. */
internal enum class MainDestination { LIBRARY, ACCOUNT, SYNC_DETAILS }

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    @Inject internal lateinit var profiles: ForegroundProfileInstaller
    private val seedOffer: SeedOfferViewModel by viewModels()
    private val library: LibraryViewModel by viewModels()
    private val editor: EditorViewModel by viewModels()
    private val setup: KeyboardTileSetupViewModel by viewModels()
    private val keyboardTileSetup by lazy { AndroidKeyboardTileSetup(this) }
    private val assistantSettings: AssistantSettingsViewModel by viewModels()
    private val assistantWrite: WriteViewModel by viewModels()
    private val assistantReview: ReviewViewModel by viewModels()
    private val assistantImprove: ImproveViewModel by viewModels()
    private val account: AccountViewModel by viewModels()
    private var destination by mutableStateOf(MainDestination.LIBRARY)
    private var foreground by mutableStateOf(false)
    private var ownsSync = false
    private val fillLauncher = FillLauncher { path ->
        startActivity(Intent(this, FillActivity::class.java).putExtra(FillActivity.promptPathExtra, path))
    }

    override fun onResume() {
        super.onResume()
        fillLauncher.resumed()
        setup.resumed(keyboardTileSetup)
    }

    override fun onPause() {
        setup.paused()
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // The system picker can return window focus without pausing this Activity.
        if (hasFocus) setup.checkStatus()
    }

    override fun onStart() {
        super.onStart()
        foreground = true
        if (seedOffer.state.value == SeedOfferUiState.Ready) library.refresh() else seedOffer.refresh()
        editor.refresh()
    }

    override fun onStop() {
        foreground = false
        if (ownsSync) account.setForeground(null)
        super.onStop()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        profiles.initialize()
        title = AppIdentity.displayName
        editor.onSelectionChanged = library::selectFromEditor
        assistantWrite.bind(editor)
        assistantReview.bind(editor)
        assistantImprove.bind(editor)
        enableEdgeToEdge()

        setContent {
            MaterialTheme {
                val startup = seedOffer.state.collectAsStateWithLifecycle().value
                val setupState = setup.state.collectAsStateWithLifecycle().value
                val editing = editor.state.collectAsStateWithLifecycle().value
                val assistant = assistantSettings.state.collectAsStateWithLifecycle().value
                val writing = assistantWrite.state.collectAsStateWithLifecycle().value
                val reviewing = assistantReview.state.collectAsStateWithLifecycle().value
                val improving = assistantImprove.state.collectAsStateWithLifecycle().value
                val ready = !setupState.loading && !setupState.visible &&
                    setupState.error != KeyboardTileSetupError.LOAD && !setupState.settingsOpen
                val sync = if (ready && (startup == SeedOfferUiState.Ready || destination != MainDestination.LIBRARY))
                    account.state.collectAsStateWithLifecycle().value else null
                LaunchedEffect(startup, destination, foreground, ready) {
                    if (sync != null) {
                        ownsSync = true
                        account.setForeground(if (!foreground) null
                            else if (destination == MainDestination.ACCOUNT) SyncForegroundOwner.ACCOUNT else SyncForegroundOwner.LIBRARY)
                    } else if (ownsSync) account.setForeground(null)
                }
                BackHandler(enabled = ready && destination != MainDestination.LIBRARY) { navigate(MainDestination.LIBRARY) }
                Scaffold(bottomBar = {
                    if (sync != null && destination == MainDestination.LIBRARY && !editing.isOpen &&
                        !assistant.isOpen && !writing.isOpen && !reviewing.isOpen && !improving.isOpen)
                        SyncFooter(sync.sync, onDetails = { navigate(MainDestination.SYNC_DETAILS) })
                }) { padding ->
                    if (setupState.loading || setupState.visible || setupState.error == KeyboardTileSetupError.LOAD) {
                        KeyboardTileSetupScreen(state = setupState, onEnable = setup::enableKeyboard,
                            onSelect = setup::selectKeyboard, onAddTile = setup::addTile,
                            onCheckStatus = setup::checkStatus, onContinue = setup::continueStep,
                            onSkip = setup::skip, onRetry = setup::retry, modifier = Modifier.padding(padding))
                    } else if (setupState.settingsOpen) {
                        SettingsScreen(onKeyboardTileSetup = setup::reopen, onBack = setup::closeSettings,
                            modifier = Modifier.padding(padding))
                    } else if (destination == MainDestination.ACCOUNT) {
                        AccountScreen(state = checkNotNull(sync), onServer = account::setServer, onUsername = account::setUsername,
                            onPassword = account::setPassword, onDeviceName = account::setDeviceName,
                            onSignIn = account::signIn, onRefresh = account::refresh, onCancel = account::cancel,
                            onBack = { navigate(MainDestination.LIBRARY) }, onTrust = account::setTrust,
                            onRequestSignOut = account::requestSignOut, onSignOut = account::signOut,
                            onRequestRevoke = account::requestRevoke, onRevoke = account::revokeDevice,
                            onSelectHold = account::selectHold, onRequestInclude = account::requestInclude,
                            onInclude = account::includeSelected, onDismissConfirmation = account::dismissConfirmation,
                            onSyncNow = account::syncNow, onSyncDetails = { navigate(MainDestination.SYNC_DETAILS) },
                            onRecover = account::recover, modifier = Modifier.padding(padding))
                    } else if (destination == MainDestination.SYNC_DETAILS) {
                        SyncStatusScreen(state = checkNotNull(sync), onSyncNow = account::syncNow, onAccount = ::openAccount,
                            onBack = { navigate(MainDestination.LIBRARY) }, onRecover = account::recover,
                            modifier = Modifier.padding(padding))
                    } else if (startup == SeedOfferUiState.Ready) {
                        if (improving.isOpen) {
                            ImproveScreen(state = improving, onInstruction = assistantImprove::editInstruction,
                                onEffort = assistantImprove::setEffort, onImprove = assistantImprove::improve,
                                onFeedback = assistantImprove::editFeedback, onRetry = assistantImprove::retryWithFeedback,
                                onShowDiff = assistantImprove::showDiff, onAccept = assistantImprove::accept,
                                onReject = assistantImprove::reject, onCancel = assistantImprove::cancel,
                                onBack = assistantImprove::close, onReload = assistantImprove::reload,
                                onSettings = { assistantImprove.close(); assistantSettings.open() },
                                modifier = Modifier.padding(padding))
                            EditorDecisionDialogs(editing, editor::resolveDecision, editor::resolveConflict)
                        } else if (reviewing.isOpen && reviewing.destination == ReviewDestination.FINDINGS) {
                            ReviewScreen(state = reviewing, onReview = assistantReview::review,
                                onEffort = assistantReview::setEffort, onFinding = assistantReview::toggleFinding,
                                onQuote = assistantReview::showQuote, onFeedback = assistantReview::editFeedback,
                                onImprove = { assistantReview.openImprove(assistantImprove) },
                                onRetry = assistantReview::retryWithFeedback, onCancel = assistantReview::cancel,
                                onBack = assistantReview::close, onReload = assistantReview::reload,
                                onSettings = { assistantReview.close(); assistantSettings.open() },
                                modifier = Modifier.padding(padding))
                            EditorDecisionDialogs(editing, editor::resolveDecision, editor::resolveConflict)
                        } else if (writing.isOpen) {
                            WriteScreen(state = writing, onBrief = assistantWrite::editBrief,
                                onEffort = assistantWrite::setEffort, onWrite = assistantWrite::write,
                                onFeedback = assistantWrite::editFeedback, onRetry = assistantWrite::retryWithFeedback,
                                onShowDiff = assistantWrite::showDiff, onAccept = assistantWrite::accept,
                                onReject = assistantWrite::reject, onCancel = assistantWrite::cancel,
                                onBack = assistantWrite::close, onReload = assistantWrite::reload,
                                onSettings = { assistantWrite.close(); assistantSettings.open() },
                                modifier = Modifier.padding(padding))
                            EditorDecisionDialogs(editing, editor::resolveDecision, editor::resolveConflict)
                        } else if (assistant.isOpen) AssistantSettingsScreen(
                            state = assistant, onBack = assistantSettings::close, onAdd = { assistantSettings.addProfile() },
                            onSelect = assistantSettings::selectProfile, onDelete = assistantSettings::deleteProfile,
                            onRename = assistantSettings::renameProfile, onKind = assistantSettings::setKind,
                            onBaseURL = assistantSettings::setBaseURL, onModelID = assistantSettings::setModelID,
                            onKeyInput = assistantSettings::setKeyInput, onKeepKey = assistantSettings::keepKey,
                            onClearKey = assistantSettings::clearKey, onKeyInputDiscarded = assistantSettings::discardTypedKey,
                            onSave = assistantSettings::save, onRefresh = assistantSettings::refresh,
                            onTest = assistantSettings::testConnection, onCancelTest = assistantSettings::cancelTest,
                            modifier = Modifier.padding(padding),
                        ) else if (editing.isOpen) EditorScreen(
                            state = editing, onEdit = editor::edit, onNewPath = editor::setNewPath,
                            onTab = editor::setTab, onSave = editor::save,
                            onBack = { if (reviewing.isOpen) assistantReview.open() else editor.close() },
                            onReload = editor::reload, onRename = editor::rename, onMove = editor::move,
                            onPrivateCopy = editor::privateCopy,
                            onDelete = editor::delete, onHistory = editor::loadHistory,
                            onRevision = { editor.selectRevision(it.revision) }, onRestore = { editor.restore(it.revision) },
                            onDecision = editor::resolveDecision, onConflict = editor::resolveConflict,
                            onReview = assistantReview::open, onClearQuote = editor::clearReviewQuote,
                            onImprove = { if (reviewing.isOpen) assistantReview.openImprove(assistantImprove) else assistantImprove.open() },
                            modifier = Modifier.padding(padding),
                        ) else LibraryScreen(
                            state = library.state.collectAsStateWithLifecycle().value,
                            onQuery = library::setQuery, onFilter = library::setFilter,
                            onSelect = library::select,
                            onToggleFavorite = library::toggleFavorite, onClearFilters = library::clearFilters,
                            onRefresh = library::refresh, modifier = Modifier.padding(padding),
                            // A row tap delivers (Fill); editing is an explicit action on the selection.
                            onOpen = ::openFill,
                            onEdit = { assistantImprove.close(); assistantReview.close(); editor.open(it) },
                            onCreate = { assistantImprove.close(); assistantReview.close(); editor.createDraft() },
                            onSettings = setup::openSettings,
                            onAccount = ::openAccount,
                            onAssistantSettings = assistantSettings::open,
                            onWrite = { assistantImprove.close(); assistantReview.close(); assistantWrite.open() },
                        )
                    } else {
                        SeedOfferScreen(state = startup, onAccept = seedOffer::accept, onDecline = seedOffer::decline,
                            onRefresh = seedOffer::refresh, modifier = Modifier.padding(padding), onSettings = ::openAccount)
                    }
                }
            }
        }
    }

    internal fun openAccount() = navigate(MainDestination.ACCOUNT)

    private fun navigate(next: MainDestination) {
        if (destination == MainDestination.ACCOUNT && next != destination) account.hide()
        destination = next
    }

    private fun openFill(selection: LibrarySelection) {
        fillLauncher.open(selection.relativePath)
    }
}
