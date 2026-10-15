package ch.lkmc.monkeyspaw.ime

import androidx.lifecycle.Lifecycle.Event.*
import java.io.File
import kotlin.test.*

/** Exercises production transitions with fake framework effects; Compose attachment needs a device. */
internal class ImeLifecycleTest {
    private val sources = File(checkNotNull(System.getProperty("monkeyspaw.appSources")))
        .resolve("kotlin/ch/lkmc/monkeyspaw/ime")

    @Test fun `created root starts and resumes only when shown and pauses and stops on hide`() {
        val events = mutableListOf<Any>()
        val lifecycle = ImeViewLifecycle({ events += it }, { events += "clear" }, { events += "dispose" })
        assertEquals(listOf<Any>(ON_CREATE), events)
        lifecycle.hide()
        lifecycle.show()
        lifecycle.show()
        lifecycle.hide()
        lifecycle.hide()
        lifecycle.show()
        assertEquals(listOf<Any>(ON_CREATE, ON_START, ON_RESUME, ON_PAUSE, ON_STOP, ON_START, ON_RESUME), events)
    }

    @Test fun `destroy shown owner stops destroys clears and disposes exactly once`() {
        val events = mutableListOf<Any>()
        val lifecycle = ImeViewLifecycle({ events += it }, { events += "clear" }, { events += "dispose" })
        lifecycle.show()
        lifecycle.destroy()
        lifecycle.destroy()
        lifecycle.hide()
        lifecycle.show()
        assertEquals(listOf<Any>(ON_CREATE, ON_START, ON_RESUME, ON_PAUSE, ON_STOP, ON_DESTROY, "clear", "dispose"), events)
    }

    @Test fun `never shown root destroys directly from created and releases its store and composition`() {
        val events = mutableListOf<Any>()
        val lifecycle = ImeViewLifecycle({ events += it }, { events += "clear" }, { events += "dispose" })
        lifecycle.destroy()
        assertEquals(listOf<Any>(ON_CREATE, ON_DESTROY, "clear", "dispose"), events)
    }

    @Test fun `owner attaches and restores null before create and all trees precede content and attachment`() {
        assertOwnerWiring(sources.resolve("ImeViewOwners.kt").readText(), sources.resolve("MonkeysPawImeService.kt").readText())
    }

    @Test fun `owner wiring guard rejects missing attach restore install or content`() {
        val owners = sources.resolve("ImeViewOwners.kt").readText()
        val service = sources.resolve("MonkeysPawImeService.kt").readText()
        for (step in listOf("savedState.performAttach()", "savedState.performRestore(null)")) {
            assertFailsWith<AssertionError>(step) { assertOwnerWiring(owners.replace(step, ""), service) }
        }
        assertFailsWith<AssertionError>("owners.install(view)") {
            assertOwnerWiring(owners, service.replace("owners.install(view)", ""))
        }
        val withoutContent = service.removeRange(service.indexOf("        view.setContent {"), service.indexOf("        return view"))
        assertFailsWith<AssertionError>("view.setContent") { assertOwnerWiring(owners, withoutContent) }
    }

    private fun assertOwnerWiring(owners: String, service: String) {
        assertBefore(owners, "savedState.performAttach()", "savedState.performRestore(null)")
        assertBefore(owners, "savedState.performRestore(null)", "transitions = ImeViewLifecycle")
        for (owner in listOf("Lifecycle", "ViewModelStore", "SavedStateRegistry")) {
            assertTrue(owners.contains("view.setViewTree${owner}Owner(this)"))
        }
        assertFalse(Regex("\\b(?:performSave|SavedStateHandle|rememberSaveable)\\b").containsMatchIn(owners))
        assertBefore(service, "owners.install(view)", "view.setContent")
        assertBefore(service, "view.setContent", "return view")
        assertTrue(service.contains("ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed"))
        assertTrue(service.contains("ImeViewOwners(view::disposeComposition)"))
        assertTrue(service.contains("view.setParentCompositionContext(view.createLifecycleAwareWindowRecomposer(lifecycle = owners.lifecycle))"))
        assertFalse(service.contains("hiltViewModel"))
        for ((callback, effect) in listOf("onWindowHidden" to "sessions.hide()", "onUnbindInput" to "sessions.unbind()",
            "onFinishInput" to "sessions.finishInput()", "onDestroy" to "sessions.destroy()")) {
            assertTrue(service.substringAfter("override fun $callback(").substringBefore("\n    }").contains(effect))
        }
    }

    private fun assertBefore(source: String, first: String, next: String) {
        val position = source.indexOf(first)
        assertTrue(position >= 0 && source.indexOf(next) > position, "$first must precede $next")
    }
}
