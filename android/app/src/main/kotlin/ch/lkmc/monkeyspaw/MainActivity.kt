package ch.lkmc.monkeyspaw

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ch.lkmc.monkeyspaw.core.AppIdentity
import ch.lkmc.monkeyspaw.data.AndroidKeyboardTileSetup
import ch.lkmc.monkeyspaw.data.ForegroundProfileInstaller
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
        if (seedOffer.state.value == SeedOfferUiState.Ready) library.refresh() else seedOffer.refresh()
        editor.refresh()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        profiles.initialize()
        title = AppIdentity.displayName
        editor.onSelectionChanged = library::selectFromEditor
        assistantWrite.bind(editor)
        assistantReview.bind(editor)
        enableEdgeToEdge()

        setContent {
            MaterialTheme {
                Scaffold { padding ->
                    val startup = seedOffer.state.collectAsStateWithLifecycle().value
                    val setupState = setup.state.collectAsStateWithLifecycle().value
                    if (setupState.loading || setupState.visible || setupState.error == KeyboardTileSetupError.LOAD) {
                        KeyboardTileSetupScreen(state = setupState, onEnable = setup::enableKeyboard,
                            onSelect = setup::selectKeyboard, onAddTile = setup::addTile,
                            onCheckStatus = setup::checkStatus, onContinue = setup::continueStep,
                            onSkip = setup::skip, onRetry = setup::retry, modifier = Modifier.padding(padding))
                    } else if (setupState.settingsOpen) {
                        SettingsScreen(onKeyboardTileSetup = setup::reopen, onBack = setup::closeSettings,
                            modifier = Modifier.padding(padding))
                    } else if (startup == SeedOfferUiState.Ready) {
                        val editing = editor.state.collectAsStateWithLifecycle().value
                        val assistant = assistantSettings.state.collectAsStateWithLifecycle().value
                        val writing = assistantWrite.state.collectAsStateWithLifecycle().value
                        val reviewing = assistantReview.state.collectAsStateWithLifecycle().value
                        if (reviewing.isOpen && reviewing.destination == ReviewDestination.FINDINGS) {
                            ReviewScreen(state = reviewing, onReview = assistantReview::review,
                                onEffort = assistantReview::setEffort, onFinding = assistantReview::toggleFinding,
                                onQuote = assistantReview::showQuote, onFeedback = assistantReview::editFeedback,
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
                            onDelete = editor::delete, onHistory = editor::loadHistory,
                            onRevision = { editor.selectRevision(it.revision) }, onRestore = { editor.restore(it.revision) },
                            onDecision = editor::resolveDecision, onConflict = editor::resolveConflict,
                            onReview = assistantReview::open, onClearQuote = editor::clearReviewQuote,
                            modifier = Modifier.padding(padding),
                        ) else LibraryScreen(
                            state = library.state.collectAsStateWithLifecycle().value,
                            onQuery = library::setQuery, onFilter = library::setFilter,
                            onSelect = library::select,
                            onToggleFavorite = library::toggleFavorite, onClearFilters = library::clearFilters,
                            onRefresh = library::refresh, modifier = Modifier.padding(padding),
                            // A row tap delivers (Fill); editing is an explicit action on the selection.
                            onOpen = ::openFill,
                            onEdit = { assistantReview.close(); editor.open(it) },
                            onCreate = { assistantReview.close(); editor.createDraft() },
                            onSettings = setup::openSettings,
                            onAssistantSettings = assistantSettings::open,
                            onWrite = { assistantReview.close(); assistantWrite.open() },
                        )
                    } else {
                        SeedOfferScreen(state = startup, onAccept = seedOffer::accept, onDecline = seedOffer::decline,
                            onRefresh = seedOffer::refresh, modifier = Modifier.padding(padding))
                    }
                }
            }
        }
    }

    private fun openFill(selection: LibrarySelection) {
        fillLauncher.open(selection.relativePath)
    }
}
