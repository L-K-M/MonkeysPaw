package ch.lkmc.monkeyspaw.entry

import android.app.PendingIntent
import android.content.Context
import android.content.Intent

internal enum class EntrySource(val requestCode: Int) {
    LIBRARY(0), TILE(1), SHORTCUT(2), WIDGET(3);

    val action: String get() = "ch.lkmc.monkeyspaw.FILL.$name"
}

internal data class FillRequest(val source: EntrySource, val promptPath: String? = null)

/** Fresh explicit intents carry only the entry action. External entries always start at the picker. */
internal class FillRoute(val source: EntrySource) {
    val targetClass = FillActivity::class.java
    val activityFlags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
    val pendingIntentFlags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT

    fun intent(context: Context): Intent = Intent(context, targetClass)
        .setAction(source.action)
        .setFlags(activityFlags)

    fun pendingIntent(context: Context): PendingIntent = PendingIntent.getActivity(
        context, source.requestCode, intent(context), pendingIntentFlags,
    )

    companion object {
        fun read(intent: Intent): FillRequest = try {
            val action = intent.action
            // The K15 library caller has no action. Do not even unpack extras for external entries.
            val path = if (action == null || action == EntrySource.LIBRARY.action) {
                intent.getStringExtra(FillActivity.promptPathExtra)
            } else null
            sanitize(action, path)
        } catch (_: RuntimeException) {
            FillRequest(EntrySource.LIBRARY)
        }

        fun sanitize(action: String?, promptPath: String?): FillRequest {
            val source = EntrySource.entries.firstOrNull { it.action == action } ?: EntrySource.LIBRARY
            val path = promptPath.takeIf { action == null || action == EntrySource.LIBRARY.action }
            return FillRequest(source, path)
        }
    }
}
