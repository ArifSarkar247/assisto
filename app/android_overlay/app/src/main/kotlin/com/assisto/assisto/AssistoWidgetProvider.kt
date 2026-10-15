package com.assisto.assisto

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * #196 Home-screen widget — native AppWidgetProvider.
 *
 * Renders the snapshot the Flutter side pushes via the `home_widget` package
 * (keys written into [HomeWidgetPlugin]'s SharedPreferences):
 *   widget_title       next reminder title       (may be empty)
 *   widget_subtitle    next reminder "when"       (may be empty)
 *   widget_count       today's reminder count     (e.g. "3")
 *   widget_empty_title localised "no reminders"
 *   widget_empty_body  localised hint
 *   widget_count_label localised "today" label
 *
 * NO hard-coded user-facing copy lives here — every string is supplied by the
 * app (already localised bn/en). Tapping anywhere opens the app's launch
 * activity. Everything is defensive: missing keys fall back to empty / "0".
 */
class AssistoWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val prefs = HomeWidgetPlugin.getData(context)

        val title = prefs.getString("widget_title", "") ?: ""
        val subtitle = prefs.getString("widget_subtitle", "") ?: ""
        val count = prefs.getString("widget_count", "0") ?: "0"
        val emptyTitle = prefs.getString("widget_empty_title", "") ?: ""
        val emptyBody = prefs.getString("widget_empty_body", "") ?: ""
        val countLabel = prefs.getString("widget_count_label", "") ?: ""

        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.assisto_widget)

            if (title.isBlank()) {
                // Empty / caught-up state.
                views.setTextViewText(R.id.widget_title, emptyTitle)
                views.setTextViewText(R.id.widget_subtitle, emptyBody)
            } else {
                views.setTextViewText(R.id.widget_title, title)
                views.setTextViewText(R.id.widget_subtitle, subtitle)
            }

            // "today: N" — label supplied by the app so no literal here.
            val countText = if (countLabel.isBlank()) count else "$countLabel: $count"
            views.setTextViewText(R.id.widget_count, countText)

            // Tap anywhere → open the app's launcher activity.
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launch != null) {
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                val pending = PendingIntent.getActivity(context, 0, launch, flags)
                views.setOnClickPendingIntent(R.id.widget_root, pending)
            }

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
