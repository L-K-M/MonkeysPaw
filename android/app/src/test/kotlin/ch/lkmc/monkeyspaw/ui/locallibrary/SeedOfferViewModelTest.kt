package ch.lkmc.monkeyspaw.ui.locallibrary

import androidx.datastore.core.DataStore
import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.ports.PromptStore
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.services.EditingService
import ch.lkmc.monkeyspaw.data.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import java.io.File
import java.io.IOException
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
internal class SeedOfferViewModelTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    private val settings = TestSettings()

    @BeforeTest
    fun setMain() { Dispatchers.setMain(dispatcher) }

    @AfterTest
    fun clearModels() {
        models.clear()
        Dispatchers.resetMain()
    }

    @Test
    fun `offer and decline render explicit states and a new model respects the decision`() = runTest {
        val model = model()
        assertEquals(SeedOfferUiState.Loading, model.state.value)
        model.refresh()
        runCurrent()
        assertEquals(SeedOfferUiState.Offer, model.state.value)
        model.decline()
        assertEquals(SeedOfferUiState.Loading, model.state.value)
        runCurrent()
        assertEquals(SeedOfferUiState.Ready, model.state.value)
        assertEquals(SeedProgress.DECLINED, settings.data.value.seedProgress)
        models.clear()
        val reopened = model()
        reopened.refresh()
        runCurrent()
        assertEquals(SeedOfferUiState.Ready, reopened.state.value)
        assertTrue(reopened.libraryState.value.snapshot.prompts.isEmpty())
    }

    @Test
    fun `duplicate accepts decline and foreground refresh during install cannot interrupt the decision`() = runTest {
        lateinit var model: SeedOfferViewModel
        var creates = 0
        model = model { prompts -> object : PromptStore by prompts {
            override fun create(bytes: ByteArray, path: String) {
                creates += 1
                assertEquals(SeedOfferUiState.Installing, model.state.value)
                model.accept()
                model.decline()
                model.refresh()
                prompts.create(bytes, path)
            }
        } }
        model.refresh()
        runCurrent()
        model.accept()
        model.accept()
        assertEquals(SeedOfferUiState.Installing, model.state.value)
        runCurrent()
        assertEquals(SeedOfferUiState.Ready, model.state.value)
        assertEquals(10, creates)
        assertEquals(10, model.libraryState.value.snapshot.prompts.size)
        assertEquals(SeedProgress.COMPLETE, settings.data.value.seedProgress)
    }

    @Test
    fun `partial failure is visible and continuation and a new model never offer missing seeds`() = runTest {
        var creates = 0
        val model = model { prompts -> object : PromptStore by prompts {
            override fun create(bytes: ByteArray, path: String) {
                if (++creates == 2) throw StoreError.IOFailure
                prompts.create(bytes, path)
            }
        } }
        model.refresh()
        runCurrent()
        model.accept()
        runCurrent()
        assertEquals(SeedOfferUiState.Failed(SeedSummary(1)), model.state.value)
        assertEquals(1, model.libraryState.value.snapshot.prompts.size)
        model.refresh()
        runCurrent()
        assertEquals(SeedOfferUiState.Ready, model.state.value)
        models.clear()
        val reopened = model()
        reopened.refresh()
        runCurrent()
        assertEquals(SeedOfferUiState.Ready, reopened.state.value)
        assertEquals(1, reopened.libraryState.value.snapshot.prompts.size)
        assertEquals(2, creates)
    }

    @Test
    fun `failed progress write shows failure preserves the offer and creates nothing`() = runTest {
        val model = model()
        model.refresh()
        runCurrent()
        settings.failWrites = true
        model.accept()
        runCurrent()
        assertEquals(SeedOfferUiState.Failed(SeedSummary()), model.state.value)
        assertTrue(model.libraryState.value.snapshot.prompts.isEmpty())
        assertEquals(SeedProgress.NOT_OFFERED, settings.data.value.seedProgress)
        settings.failWrites = false
        model.refresh()
        runCurrent()
        assertEquals(SeedOfferUiState.Offer, model.state.value)
        settings.failWrites = true
        model.decline()
        runCurrent()
        assertEquals(SeedOfferUiState.Failed(), model.state.value)
        assertEquals(SeedProgress.NOT_OFFERED, settings.data.value.seedProgress)
    }

    private fun model(wrap: (AndroidPromptStore) -> PromptStore = { it }): SeedOfferViewModel {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        val library = library(prompts = wrap(prompts))
        val repository = LibraryRepository(library, EditingService(library), prompts, dispatcher)
        val assets = File(checkNotNull(System.getProperty("monkeyspaw.seedAssets")))
        val installer = SeedInstaller(repository, AndroidSettingsStore(settings), AndroidSeedCatalog { assets.resolve(it).readBytes() }, dispatcher)
        return SeedOfferViewModel(installer, repository).also { models.put("seeds", it) }
    }

    private class TestSettings : DataStore<AndroidSettings> {
        override val data = MutableStateFlow(AndroidSettings())
        var failWrites = false

        override suspend fun updateData(transform: suspend (t: AndroidSettings) -> AndroidSettings): AndroidSettings {
            if (failWrites) throw IOException("SECRET progress file")
            return transform(data.value).also { data.value = it }
        }
    }
}
