package ch.lkmc.monkeyspaw.ui.setup

import androidx.lifecycle.ViewModelStore
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.data.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.*
import java.nio.file.Files
import java.time.ZoneId
import kotlin.test.*

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
internal class RememberedValuesViewModelTest : TemporaryFiles() {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()

    @BeforeTest fun setMain() { Dispatchers.setMain(dispatcher) }
    @AfterTest fun clearModels() { models.clear(); Dispatchers.resetMain() }

    @Test fun `confirmation cancels safely and confirmed forget preserves prompts history and held forms`() = runTest {
        val h = harness()
        val before = Files.readAllBytes(libraryDir.resolve("a.md"))
        val held = h.fill.form(h.entry)
        h.model.forget()
        runCurrent()
        assertEquals("remembered", h.fill.form(h.entry).fields.single().prefill)
        h.model.requestForget()
        h.model.cancel()
        h.model.forget()
        runCurrent()
        assertEquals("remembered", h.fill.form(h.entry).fields.single().prefill)
        h.model.requestForget()
        h.model.forget()
        h.model.forget()
        assertEquals(RememberedValuesState.CLEARING, h.model.state.value)
        runCurrent()
        assertEquals(RememberedValuesState.CLEARED, h.model.state.value)
        assertEquals("fallback", h.fill.form(h.entry).fields.single().prefill)
        assertEquals("remembered", held.fields.single().prefill)
        assertContentEquals(before, Files.readAllBytes(libraryDir.resolve("a.md")))
        assertEquals(h.revisions, h.library.history.revisions(h.entry.identity))
    }

    @Test fun `failed forget retains values and explicit retry recovers`() = runTest {
        var fail = false
        val backing = AndroidStateStore(stateDir.toFile())
        val state = object : StateStore by backing {
            override fun writePrivate(bytes: ByteArray, path: String) {
                if (fail) throw StoreError.IOFailure
                backing.writePrivate(bytes, path)
            }
        }
        val h = harness(state)
        fail = true
        h.model.requestForget()
        h.model.forget()
        runCurrent()
        assertEquals(RememberedValuesState.FAILED, h.model.state.value)
        assertEquals("remembered", h.fill.form(h.entry).fields.single().prefill)
        fail = false
        h.model.forget()
        runCurrent()
        assertEquals(RememberedValuesState.CLEARED, h.model.state.value)
        assertEquals("fallback", h.fill.form(h.entry).fields.single().prefill)
    }

    private data class Harness(val model: RememberedValuesViewModel, val fill: FillService,
        val library: LibraryService, val entry: LibraryEntry, val revisions: List<HistoryRevision>)

    private fun harness(state: StateStore = AndroidStateStore(stateDir.toFile())): Harness {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        prompts.prepareRoot()
        val library = library(state, prompts)
        val entry = library.create(PromptCodec.parse("---\nfields:\n  f: {default: fallback}\n---\n{{f}}", "a.md"), "a.md").entry
        val clipboard = object : Clipboard {
            override fun writeText(text: String) { error("Forget must not write the clipboard") }
            override fun readText(completion: (String?) -> Unit) { error("Forget must not read the clipboard") }
        }
        val fill = FillService(library, clipboard) { ZoneId.of("UTC") }
        fill.rememberedOnDelivery(entry.identity, entry.document.effectiveFields, mapOf("f" to "remembered"))
        val model = RememberedValuesViewModel(LibraryRepository(library, EditingService(library), prompts, dispatcher), fill)
        models.put("values", model)
        return Harness(model, fill, library, entry, library.history.revisions(entry.identity))
    }
}
