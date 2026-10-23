package ch.lkmc.monkeyspaw.ui.setup

import ch.lkmc.monkeyspaw.data.KeyboardTileSetupApi
import ch.lkmc.monkeyspaw.data.TileAddResult
import java.io.File
import kotlin.test.*

/** Framework calls and Compose need devices; these guards complement the fake-port behavior tests. */
internal class KeyboardTileSetupBoundaryTest {
    private val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
    private val root = sources.resolve("kotlin/ch/lkmc/monkeyspaw")

    @Test
    fun `platform boundaries select the documented IME and tile APIs`() {
        for (api in 26..37) {
            assertEquals(api >= 34, KeyboardTileSetupApi.hasCurrentInputMethodInfo(api))
            assertEquals(api >= 33, KeyboardTileSetupApi.canRequestTile(api))
        }
        assertEquals(TileAddResult.ADDED, KeyboardTileSetupApi.tileResult(2))
        assertEquals(TileAddResult.ALREADY_ADDED, KeyboardTileSetupApi.tileResult(1))
        assertEquals(TileAddResult.DENIED, KeyboardTileSetupApi.tileResult(0))
        for (error in listOf(-1, 3, 1000, 1001, 1002, 1003, 1004, 1005)) {
            assertEquals(TileAddResult.ERROR, KeyboardTileSetupApi.tileResult(error))
        }
    }

    @Test
    fun `driver compares ComponentNames without retaining foreign IDs and reuses the registered tile`() {
        val source = root.resolve("data/AndroidKeyboardTileSetup.kt").readText()
        assertTrue(source.contains("ComponentName(activity, MonkeysPawImeService::class.java)"))
        assertTrue(source.contains("manager?.enabledInputMethodList?.any { it.component == keyboard }"))
        assertTrue(source.contains("if (KeyboardTileSetupApi.hasCurrentInputMethodInfo())"))
        assertTrue(source.contains("manager?.currentInputMethodInfo?.component"))
        assertTrue(source.contains("Settings.Secure.DEFAULT_INPUT_METHOD"))
        assertTrue(source.contains("ComponentName::unflattenFromString"))
        assertTrue(source.contains("current?.let { it == keyboard }"))
        assertTrue(source.contains("Settings.ACTION_INPUT_METHOD_SETTINGS"))
        assertTrue(source.contains("manager.showInputMethodPicker()"))
        assertTrue(source.contains("ComponentName(activity, PromptTileService::class.java)"))
        assertTrue(source.contains("R.string.entry_insert_prompt"))
        assertTrue(source.contains("R.drawable.ic_insert_prompt"))
        assertFalse(Regex("\\b(?:getId|SharedPreferences|DataStore|Logger|Log|HTTP|Gboard|Samsung)\\b").containsMatchIn(source))
    }

    @Test
    fun `setup is launcher only and hands local library choice to the existing seed offer`() {
        val activity = root.resolve("MainActivity.kt").readText()
        assertTrue(activity.contains("setup.resumed(keyboardTileSetup)"))
        assertTrue(activity.contains("setup.paused()"))
        assertTrue(activity.contains("onSettings = setup::openSettings"))
        assertTrue(activity.contains("onKeyboardTileSetup = setup::reopen"))
        assertTrue(activity.contains("SeedOfferScreen(state = startup"))
        val model = root.resolve("ui/setup/KeyboardTileSetupViewModel.kt").readText()
        assertFalse(Regex("\\b(?:SeedInstaller|seedProgress|install|SignIn|Notification|HttpTransport)\\b").containsMatchIn(model))
        for (file in root.resolve("ime").listFiles().orEmpty()) {
            if (file.extension == "kt") assertFalse(file.readText().contains("KeyboardTileSetup"), file.name)
        }
        val library = root.resolve("ui/library/LibraryScreen.kt").readText()
        assertTrue(library.contains("onSettings: (() -> Unit)? = null"))
    }

    @Test
    fun `unresolved settings show loading before any setup title`() {
        val screen = root.resolve("ui/setup/KeyboardTileSetupScreen.kt").readText()
        val loading = screen.indexOf("if (state.loading)")
        val loadingExit = screen.indexOf("return", loading)
        val title = screen.indexOf("PawScreen(stringResource(R.string.design_setup_title)")
        assertTrue(loading >= 0 && loadingExit > loading && title > loadingExit,
            "KeyboardTileSetupScreen must finish the loading branch before rendering the setup title")
    }

    @Test
    fun `launcher refreshes picker status on focus regain and the screen honors failure back state`() {
        val activity = root.resolve("MainActivity.kt").readText()
        assertTrue(activity.contains("override fun onWindowFocusChanged(hasFocus: Boolean)"))
        assertTrue(activity.contains("if (hasFocus) setup.checkStatus()"))
        val screen = root.resolve("ui/setup/KeyboardTileSetupScreen.kt").readText()
        assertTrue(screen.contains("BackHandler(enabled = state.handlesBack)"))
    }
}
