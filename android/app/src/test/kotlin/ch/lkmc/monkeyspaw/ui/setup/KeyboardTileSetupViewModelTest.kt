package ch.lkmc.monkeyspaw.ui.setup

import androidx.datastore.core.DataStore
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.data.*
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.*
import java.io.IOException
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
internal class KeyboardTileSetupViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private var modelNumber = 0
    private val settings = TestSettings()
    private val host = TestHost()

    @BeforeTest
    fun setMain() { Dispatchers.setMain(dispatcher) }

    @AfterTest
    fun clearModels() {
        models.clear()
        Dispatchers.resetMain()
    }

    @Test
    fun `every enabled and selected true false unknown combination is reread on resume`() = runTest {
        val model = model()
        for (enabled in listOf(false, true, null)) for (selected in listOf(false, true, null)) {
            host.status = KeyboardSetupStatus(enabled, selected)
            model.resumed(host)
            runCurrent()
            assertEquals(enabled, model.state.value.enabled)
            assertEquals(selected, model.state.value.selected)
            assertEquals(KeyboardTileSetupStep.ENABLE_KEYBOARD, model.state.value.step)
            assertTrue(model.state.value.visible)
            assertEquals(0, settings.writes)
        }
        host.statusThrows = true
        model.resumed(host)
        assertNull(model.state.value.enabled)
        assertNull(model.state.value.selected)
    }

    @Test
    fun `launching Settings and picker never completes steps and repeated taps wait for a check`() = runTest {
        val model = start()
        model.enableKeyboard()
        model.enableKeyboard()
        assertEquals(1, host.settingsLaunches)
        model.continueStep()
        runCurrent()
        assertEquals(0, settings.writes)
        host.status = KeyboardSetupStatus(true, false)
        model.resumed(host)
        model.continueStep()
        runCurrent()
        assertEquals(KeyboardTileSetupStep.SELECT_KEYBOARD, model.state.value.step)
        model.selectKeyboard()
        model.selectKeyboard()
        assertEquals(1, host.pickerLaunches)
        assertFalse(model.state.value.canContinue)
        host.status = KeyboardSetupStatus(true, true)
        model.checkStatus()
        assertTrue(model.state.value.canContinue)
        assertEquals(SetupDecision.PENDING, settings.current.value.keyboardTileSetup.selectKeyboard)
    }

    @Test
    fun `continue rechecks current status rather than completing from a stale true`() = runTest {
        host.status = KeyboardSetupStatus(true, true)
        val model = start()
        assertTrue(model.state.value.canContinue)
        host.status = KeyboardSetupStatus(false, false)
        model.continueStep()
        runCurrent()
        assertEquals(0, settings.writes)
        assertFalse(model.state.value.canContinue)
    }

    @Test
    fun `all steps are skippable and fresh or upgraded seed progress is never changed`() = runTest {
        for (seed in SeedProgress.entries) {
            settings.current.value = AndroidSettings(seed)
            val model = start()
            for (step in KeyboardTileSetupStep.entries) {
                assertEquals(step, model.state.value.step)
                model.skip()
                runCurrent()
                assertEquals(seed, settings.current.value.seedProgress)
            }
            assertFalse(model.state.value.visible)
            assertEquals(KeyboardTileSetupProgress(SetupDecision.SKIPPED, SetupDecision.SKIPPED, SetupDecision.SKIPPED),
                settings.current.value.keyboardTileSetup)
            val reopened = start()
            assertFalse(reopened.state.value.visible)
            reopened.resumed(host)
            assertFalse(reopened.state.value.visible)
        }
    }

    @Test
    fun `resolved steps survive a new model and only the pending step is shown`() = runTest {
        val model = start()
        model.skip()
        runCurrent()
        val restarted = start()
        assertEquals(KeyboardTileSetupStep.SELECT_KEYBOARD, restarted.state.value.step)
        assertEquals(1, settings.writes)
        assertEquals(0, host.settingsLaunches)
        assertEquals(0, host.pickerLaunches)
    }

    @Test
    fun `failed save keeps its exact pending skip and retry persists it before advancing`() = runTest {
        val model = start()
        settings.failWrites = true
        model.skip()
        runCurrent()
        assertEquals(KeyboardTileSetupError.SAVE, model.state.value.error)
        assertTrue(model.state.value.pendingSave)
        assertEquals(KeyboardTileSetupStep.ENABLE_KEYBOARD, model.state.value.step)
        assertEquals(KeyboardTileSetupProgress(), settings.current.value.keyboardTileSetup)
        model.resumed(host)
        model.skip()
        model.reopen()
        assertEquals(1, settings.writes)
        settings.failWrites = false
        model.retry()
        model.retry()
        runCurrent()
        assertEquals(SetupDecision.SKIPPED, settings.current.value.keyboardTileSetup.enableKeyboard)
        assertEquals(KeyboardTileSetupStep.SELECT_KEYBOARD, model.state.value.step)
        assertFalse(model.state.value.pendingSave)
    }

    @Test
    fun `failed complete save retains the accepted decision through a later keyboard change`() = runTest {
        host.status = KeyboardSetupStatus(true, true)
        val model = start()
        settings.failWrites = true
        model.continueStep()
        runCurrent()
        host.status = KeyboardSetupStatus(false, false)
        model.resumed(host)
        settings.failWrites = false
        model.retry()
        runCurrent()
        assertEquals(SetupDecision.COMPLETE, settings.current.value.keyboardTileSetup.enableKeyboard)
        assertFalse(checkNotNull(model.state.value.enabled))
    }

    @Test
    fun `pending store publication blocks repeated decisions and resumes do not reset it`() = runTest {
        val model = start()
        val gate = CompletableDeferred<Unit>()
        settings.writeGate = gate
        model.skip()
        runCurrent()
        model.skip()
        model.continueStep()
        model.reopen()
        model.resumed(host)
        assertTrue(model.state.value.saving)
        assertEquals(1, settings.writes)
        gate.complete(Unit)
        runCurrent()
        assertEquals(KeyboardTileSetupStep.SELECT_KEYBOARD, model.state.value.step)
    }

    @Test
    fun `failed settings read cannot silently use defaults or write and can retry`() = runTest {
        settings.failReads = true
        val model = start()
        assertEquals(KeyboardTileSetupError.LOAD, model.state.value.error)
        model.skip()
        model.reopen()
        assertEquals(0, settings.writes)
        settings.failReads = false
        model.retry()
        runCurrent()
        assertTrue(model.state.value.visible)
        assertNull(model.state.value.error)
    }

    @Test
    fun `Settings and picker failures are actionable without blocking skip`() = runTest {
        val model = start()
        host.launchSucceeds = false
        model.enableKeyboard()
        assertEquals(KeyboardTileSetupError.SETTINGS, model.state.value.error)
        assertFalse(model.state.value.externalActionPending)
        model.skip()
        runCurrent()
        host.launchThrows = true
        model.selectKeyboard()
        assertEquals(KeyboardTileSetupError.PICKER, model.state.value.error)
        model.skip()
        runCurrent()
        assertEquals(KeyboardTileSetupStep.ADD_TILE, model.state.value.step)
    }

    @Test
    fun `API 26 to 32 has manual tile instructions and 33 onwards requests on explicit tap only`() = runTest {
        for (api in 26..37) {
            settings.current.value = AndroidSettings()
            host.supportsTileRequest = KeyboardTileSetupApi.canRequestTile(api)
            val model = atTile()
            val before = host.tileCallbacks.size
            if (api < 33) {
                assertEquals(TileSetupState.MANUAL, model.state.value.tile)
                model.addTile()
                assertEquals(before, host.tileCallbacks.size)
                model.continueStep()
                runCurrent()
                assertEquals(SetupDecision.COMPLETE, settings.current.value.keyboardTileSetup.addTile)
            } else {
                assertEquals(TileSetupState.IDLE, model.state.value.tile)
                assertEquals(before, host.tileCallbacks.size)
                model.addTile()
                assertEquals(before + 1, host.tileCallbacks.size)
                model.skip()
                runCurrent()
            }
        }
    }

    @Test
    fun `added and already added results permit completion without writing at callback time`() = runTest {
        for ((result, display) in listOf(TileAddResult.ADDED to TileSetupState.ADDED,
            TileAddResult.ALREADY_ADDED to TileSetupState.ALREADY_ADDED)) {
            settings.current.value = AndroidSettings()
            val model = atTile()
            model.addTile()
            host.tileCallbacks.last()(result)
            assertEquals(display, model.state.value.tile)
            assertTrue(model.state.value.canContinue)
            assertEquals(SetupDecision.PENDING, settings.current.value.keyboardTileSetup.addTile)
            model.continueStep()
            runCurrent()
            assertFalse(model.state.value.visible)
            assertEquals(SetupDecision.COMPLETE, settings.current.value.keyboardTileSetup.addTile)
        }
    }

    @Test
    fun `denied error and throwing tile requests do not mark completion or reprompt on resume`() = runTest {
        for (result in listOf(TileAddResult.DENIED, TileAddResult.ERROR)) {
            settings.current.value = AndroidSettings()
            val model = atTile()
            model.addTile()
            host.tileCallbacks.last()(result)
            val count = host.tileCallbacks.size
            assertFalse(model.state.value.canContinue)
            model.resumed(host)
            assertEquals(count, host.tileCallbacks.size)
            model.continueStep()
            runCurrent()
            assertEquals(SetupDecision.PENDING, settings.current.value.keyboardTileSetup.addTile)
            model.skip()
            runCurrent()
            assertFalse(model.state.value.visible)
        }
        settings.current.value = AndroidSettings()
        val model = atTile()
        host.tileThrows = true
        model.addTile()
        assertEquals(TileSetupState.ERROR, model.state.value.tile)
    }

    @Test
    fun `repeated tile taps produce one request and old or duplicate callbacks cannot replace a newer result`() = runTest {
        val model = atTile()
        model.addTile()
        val first = host.tileCallbacks.single()
        model.addTile()
        assertEquals(1, host.tileCallbacks.size)
        first(TileAddResult.DENIED)
        model.addTile()
        first(TileAddResult.ADDED)
        assertEquals(TileSetupState.REQUESTING, model.state.value.tile)
        host.tileCallbacks.last()(TileAddResult.ALREADY_ADDED)
        host.tileCallbacks.last()(TileAddResult.ERROR)
        assertEquals(TileSetupState.ALREADY_ADDED, model.state.value.tile)
    }

    @Test
    fun `skip retires tile callbacks and Settings reentry rereads disabled keyboards and resets tile status`() = runTest {
        val model = atTile()
        model.addTile()
        val old = host.tileCallbacks.single()
        model.skip()
        runCurrent()
        old(TileAddResult.ADDED)
        assertFalse(model.state.value.visible)
        host.status = KeyboardSetupStatus(false, false)
        model.openSettings()
        model.reopen()
        assertTrue(model.state.value.settingsOpen)
        assertEquals(false, model.state.value.enabled)
        assertEquals(false, model.state.value.selected)
        assertEquals(KeyboardTileSetupStep.ENABLE_KEYBOARD, model.state.value.step)
        repeat(2) { model.skip(); runCurrent() }
        assertEquals(TileSetupState.IDLE, model.state.value.tile)
        model.addTile()
        old(TileAddResult.ADDED)
        assertEquals(TileSetupState.REQUESTING, model.state.value.tile)
        host.tileCallbacks.last()(TileAddResult.DENIED)
        assertEquals(TileSetupState.DENIED, model.state.value.tile)
    }

    @Test
    fun `previous tile success is not presented as current installation after Settings reentry`() = runTest {
        val model = atTile()
        model.addTile()
        host.tileCallbacks.last()(TileAddResult.ADDED)
        model.continueStep()
        runCurrent()
        model.reopen()
        repeat(2) { model.skip(); runCurrent() }
        assertEquals(TileSetupState.IDLE, model.state.value.tile)
        assertFalse(model.state.value.canContinue)
        model.addTile()
        assertEquals(2, host.tileCallbacks.size)
    }

    @Test
    fun `paused launcher cannot issue system actions and resumes with fresh keyboard status`() = runTest {
        host.status = KeyboardSetupStatus(true, true)
        val model = start()
        model.paused()
        model.enableKeyboard()
        model.continueStep()
        assertEquals(0, host.settingsLaunches)
        assertEquals(0, settings.writes)
        host.status = KeyboardSetupStatus(false, false)
        model.resumed(host)
        assertFalse(model.state.value.canContinue)
    }

    @Test
    fun `picker focus return refreshes status and allows another explicit request without resume`() = runTest {
        val model = start()
        model.skip()
        runCurrent()
        model.selectKeyboard()
        assertTrue(model.state.value.externalActionPending)
        host.status = KeyboardSetupStatus(true, true)
        // MainActivity forwards focus regain even when the system picker did not pause it.
        model.checkStatus()
        assertFalse(model.state.value.externalActionPending)
        assertTrue(model.state.value.canContinue)
        model.selectKeyboard()
        assertEquals(2, host.pickerLaunches)
        assertEquals(SetupDecision.PENDING, settings.current.value.keyboardTileSetup.selectKeyboard)
    }

    @Test
    fun `failed save permits Activity back while retaining the pending decision and retry`() = runTest {
        val model = start()
        assertTrue(model.state.value.handlesBack)
        settings.failWrites = true
        model.skip()
        assertTrue(model.state.value.handlesBack)
        runCurrent()
        assertTrue(model.state.value.visible)
        assertTrue(model.state.value.pendingSave)
        assertFalse(model.state.value.handlesBack)
        assertEquals(KeyboardTileSetupError.SAVE, model.state.value.error)
        assertEquals(SetupDecision.PENDING, settings.current.value.keyboardTileSetup.enableKeyboard)
        settings.failWrites = false
        model.retry()
        runCurrent()
        assertEquals(SetupDecision.SKIPPED, settings.current.value.keyboardTileSetup.enableKeyboard)
    }

    @Test
    fun `fresh status clears past launch errors but never hides a pending save failure`() = runTest {
        val model = start()
        host.launchSucceeds = false
        model.enableKeyboard()
        assertEquals(KeyboardTileSetupError.SETTINGS, model.state.value.error)
        model.resumed(host)
        assertNull(model.state.value.error)
        model.skip()
        runCurrent()
        model.selectKeyboard()
        assertEquals(KeyboardTileSetupError.PICKER, model.state.value.error)
        model.checkStatus()
        assertNull(model.state.value.error)
        settings.failWrites = true
        model.skip()
        runCurrent()
        model.resumed(host)
        assertEquals(KeyboardTileSetupError.SAVE, model.state.value.error)
        assertTrue(model.state.value.pendingSave)
    }

    @Test
    fun `clearing the model rejects late tile callbacks without changing UI or settings`() = runTest {
        val model = atTile()
        model.addTile()
        val before = model.state.value
        models.clear()
        host.tileCallbacks.single()(TileAddResult.ADDED)
        assertEquals(before, model.state.value)
        assertEquals(SetupDecision.PENDING, settings.current.value.keyboardTileSetup.addTile)
    }

    private fun model(): KeyboardTileSetupViewModel = KeyboardTileSetupViewModel(AndroidSettingsStore(settings)).also {
        models.put("setup${modelNumber++}", it)
    }

    private fun TestScope.start(): KeyboardTileSetupViewModel = model().also { it.resumed(host); runCurrent() }

    private fun TestScope.atTile(): KeyboardTileSetupViewModel = start().also {
        repeat(2) { _ -> it.skip(); runCurrent() }
        assertEquals(KeyboardTileSetupStep.ADD_TILE, it.state.value.step)
    }

    private class TestSettings : DataStore<AndroidSettings> {
        val current = MutableStateFlow(AndroidSettings(SeedProgress.COMPLETE))
        var failReads = false
        var failWrites = false
        var writes = 0
        var writeGate: CompletableDeferred<Unit>? = null
        override val data = flow {
            if (failReads) throw IOException("private settings error")
            emitAll(current)
        }
        override suspend fun updateData(transform: suspend (AndroidSettings) -> AndroidSettings): AndroidSettings {
            writes++
            writeGate?.await()
            if (failWrites) throw IOException("private settings error")
            return transform(current.value).also { current.value = it }
        }
    }

    private class TestHost : KeyboardTileSetup {
        override var supportsTileRequest = true
        var status = KeyboardSetupStatus(false, false)
        var statusThrows = false
        var launchSucceeds = true
        var launchThrows = false
        var tileThrows = false
        var settingsLaunches = 0
        var pickerLaunches = 0
        val tileCallbacks = mutableListOf<(TileAddResult) -> Unit>()
        override fun keyboardStatus(): KeyboardSetupStatus {
            if (statusThrows) throw IllegalStateException("private IME error")
            return status
        }
        override fun openKeyboardSettings(): Boolean {
            settingsLaunches++
            if (launchThrows) throw IllegalStateException()
            return launchSucceeds
        }
        override fun showKeyboardPicker(): Boolean {
            pickerLaunches++
            if (launchThrows) throw IllegalStateException()
            return launchSucceeds
        }
        override fun requestTile(result: (TileAddResult) -> Unit) {
            if (tileThrows) throw IllegalStateException()
            tileCallbacks += result
        }
    }
}
