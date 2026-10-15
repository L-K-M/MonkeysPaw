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
import ch.lkmc.monkeyspaw.entry.FillActivity
import ch.lkmc.monkeyspaw.entry.FillLauncher
import ch.lkmc.monkeyspaw.ui.editor.EditorScreen
import ch.lkmc.monkeyspaw.ui.editor.EditorViewModel
import ch.lkmc.monkeyspaw.ui.library.LibraryScreen
import ch.lkmc.monkeyspaw.ui.library.LibrarySelection
import ch.lkmc.monkeyspaw.ui.library.LibraryViewModel
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferScreen
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferUiState
import ch.lkmc.monkeyspaw.ui.locallibrary.SeedOfferViewModel
import ch.lkmc.monkeyspaw.ui.setup.KeyboardTileSetupError
import ch.lkmc.monkeyspaw.ui.setup.KeyboardTileSetupScreen
import ch.lkmc.monkeyspaw.ui.setup.KeyboardTileSetupViewModel
import ch.lkmc.monkeyspaw.ui.setup.SettingsScreen
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    private val seedOffer: SeedOfferViewModel by viewModels()
    private val library: LibraryViewModel by viewModels()
    private val editor: EditorViewModel by viewModels()
    private val setup: KeyboardTileSetupViewModel by viewModels()
    private val keyboardTileSetup by lazy { AndroidKeyboardTileSetup(this) }
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
        title = AppIdentity.displayName
        editor.onSelectionChanged = library::selectFromEditor
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
                        if (editing.isOpen) EditorScreen(
                            state = editing, onEdit = editor::edit, onNewPath = editor::setNewPath,
                            onTab = editor::setTab, onSave = editor::save, onBack = editor::close,
                            onReload = editor::reload, onRename = editor::rename, onMove = editor::move,
                            onDelete = editor::delete, onHistory = editor::loadHistory,
                            onRevision = { editor.selectRevision(it.revision) }, onRestore = { editor.restore(it.revision) },
                            onDecision = editor::resolveDecision, onConflict = editor::resolveConflict,
                            modifier = Modifier.padding(padding),
                        ) else LibraryScreen(
                            state = library.state.collectAsStateWithLifecycle().value,
                            onQuery = library::setQuery, onFilter = library::setFilter,
                            onSelect = library::select,
                            onToggleFavorite = library::toggleFavorite, onClearFilters = library::clearFilters,
                            onRefresh = library::refresh, modifier = Modifier.padding(padding),
                            // A row tap delivers (Fill); editing is an explicit action on the selection.
                            onOpen = ::openFill,
                            onEdit = { editor.open(it) },
                            onCreate = { editor.createDraft() },
                            onSettings = setup::openSettings,
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
