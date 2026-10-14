package ch.lkmc.monkeyspaw.entry

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import ch.lkmc.monkeyspaw.R

class PromptWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        val views = RemoteViews(context.packageName, R.layout.prompt_widget).apply {
            setOnClickPendingIntent(R.id.insert_prompt, FillRoute(EntrySource.WIDGET).pendingIntent(context))
        }
        for (id in appWidgetIds) appWidgetManager.updateAppWidget(id, views)
    }
}
