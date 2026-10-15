package ch.lkmc.monkeyspaw.ui.account

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.*

internal class AccountBoundaryTest {
    private val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
    private val root = sources.resolve("kotlin/ch/lkmc/monkeyspaw")

    @Test fun `account drafts and passwords have no persistence or diagnostic path`() {
        val forbidden = Regex("\\b(?:SavedStateHandle|rememberSaveable|Parcelable|Serializable|Bundle|Logger|Log|println|printStackTrace|DataStore)\\b")
        for (file in root.resolve("ui/account").walkTopDown().filter { it.extension == "kt" }) {
            // Documentation names the Android Bundle boundary; executable code must not use it.
            val code = file.readText().replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            assertFalse(forbidden.containsMatchIn(code), file.name)
        }
        val screen = root.resolve("ui/account/AccountScreen.kt").readText()
        assertTrue(screen.contains("PasswordVisualTransformation()"))
        assertTrue(screen.contains("KeyboardType.Password, autoCorrectEnabled = false"))
    }

    @Test fun `shared local Library and Fill graph cannot reach the account presentation`() {
        val forbidden = Regex("\\b(?:AccountViewModel|AndroidSyncRepository|SyncWorkScheduler|SyncAccountService|SyncEngine)\\b")
        for (path in listOf("ui/library/LibraryViewModel.kt", "ui/library/LibraryUiState.kt", "ui/library/LibraryScreen.kt",
            "ui/fill/FillViewModel.kt", "ui/fill/FillViewModelFactory.kt", "ime/ImeInputPolicy.kt", "entry/FillRoute.kt")) {
            assertFalse(forbidden.containsMatchIn(root.resolve(path).readText()), path)
        }
    }

    @Test fun `footer copy uses the plan statuses and warnings name the consent boundary`() {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(sources.resolve("res/values/account_strings.xml"))
        val nodes = document.getElementsByTagName("string")
        val strings = (0 until nodes.length).associate {
            val element = nodes.item(it) as org.w3c.dom.Element
            element.getAttribute("name") to element.textContent
        }
        assertEquals("Sign in again", strings["sync_needs_sign_in"])
        assertEquals("offline", strings["sync_offline"])
        assertEquals("sync errors", strings["sync_errors"])
        assertEquals("resyncing…", strings["sync_resyncing"])
        assertTrue(checkNotNull(strings["account_http_warning"]).contains("password, device token and prompts"))
        assertTrue(checkNotNull(strings["account_include_confirm"]).contains("selected files"))
    }
}
