package ch.lkmc.monkeyspaw.entry

import android.app.PendingIntent
import android.content.Intent
import kotlin.test.*

/** Test the intent policy without constructing Android's stub Intent/PendingIntent on the JVM. */
internal class FillRouteTest {
    @Test
    fun `every external route targets only FillActivity with reusable immutable activity tokens`() {
        for (source in listOf(EntrySource.TILE, EntrySource.SHORTCUT, EntrySource.WIDGET)) {
            val route = FillRoute(source)
            assertEquals("ch.lkmc.monkeyspaw.entry.FillActivity", route.targetClass.name)
            assertEquals(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP, route.activityFlags)
            assertEquals(PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT, route.pendingIntentFlags)
            assertEquals(0, route.pendingIntentFlags and PendingIntent.FLAG_MUTABLE)
            assertEquals(0, route.pendingIntentFlags and PendingIntent.FLAG_ONE_SHOT)
            assertEquals(0, route.activityFlags and (Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK or
                Intent.FLAG_ACTIVITY_NEW_DOCUMENT))
        }
    }

    @Test
    fun `sources have distinct token identities and repeated invocation has stable identity`() {
        assertEquals(EntrySource.entries.size, EntrySource.entries.map { it.action }.toSet().size)
        assertEquals(EntrySource.entries.size, EntrySource.entries.map { it.requestCode }.toSet().size)
        for (source in EntrySource.entries) {
            val first = FillRoute(source)
            val repeated = FillRoute(source)
            assertEquals(first.targetClass, repeated.targetClass)
            assertEquals(first.source.action, repeated.source.action)
            assertEquals(first.source.requestCode, repeated.source.requestCode)
            assertEquals(first.activityFlags, repeated.activityFlags)
            assertEquals(first.pendingIntentFlags, repeated.pendingIntentFlags)
        }
    }

    @Test
    fun `external and unknown actions discard supplied paths and always request a picker`() {
        for (source in listOf(EntrySource.TILE, EntrySource.SHORTCUT, EntrySource.WIDGET)) {
            assertEquals(FillRequest(source), FillRoute.sanitize(source.action, "secret.md"))
        }
        for (action in listOf("", "android.intent.action.SEND", "android.intent.action.PROCESS_TEXT",
            "ch.lkmc.monkeyspaw.FILL.tile", "ch.lkmc.monkeyspaw.FILL.TILE.extra")) {
            assertEquals(FillRequest(EntrySource.LIBRARY), FillRoute.sanitize(action, "secret.md"))
        }
    }

    @Test
    fun `K15 library activation preserves its exact path for Core to reload and validate`() {
        val path = "Cafe\u0301/Prompt.md"
        assertEquals(FillRequest(EntrySource.LIBRARY, path), FillRoute.sanitize(null, path))
        assertEquals(FillRequest(EntrySource.LIBRARY, path), FillRoute.sanitize(EntrySource.LIBRARY.action, path))
        assertEquals(FillRequest(EntrySource.LIBRARY), FillRoute.sanitize(null, null))
    }
}
