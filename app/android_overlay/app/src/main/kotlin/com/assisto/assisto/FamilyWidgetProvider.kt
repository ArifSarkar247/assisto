package com.assisto.assisto

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONObject

/**
 * fcscreen (Family Care v3, owner order 9 Nov 10:50) — the Family home-screen
 * widget: up to 6 family avatars with a coloured dot each (green OK, amber
 * check, red SOS, gray no news) and ONE line for the most important alert.
 * Tap anywhere opens the Family screen (extra assisto_open=family).
 *
 * Battery: no periodic update (updatePeriodMillis=0), no WorkManager, no
 * service. The app writes `fc_widget_json` (HomeWidget prefs) after each
 * Family load. ZERO FALSE GREEN: each member carries `fu` (fresh-until, epoch
 * ms); at render time a green/amber member whose `fu` has passed is drawn
 * GRAY with the app's pre-localised "No news from NAME" line, and ONE
 * inexact, non-wakeup alarm (AlarmManager.RTC) re-renders at the next `fu`.
 * Every step is try/catch: a bad snapshot shows the empty state, never a crash.
 */
class FamilyWidgetProvider : AppWidgetProvider() {

    companion object {
        const val ACTION_TICK = "com.assisto.assisto.FC_WIDGET_TICK"
        private val SLOT = intArrayOf(R.id.fc_m0, R.id.fc_m1, R.id.fc_m2, R.id.fc_m3, R.id.fc_m4, R.id.fc_m5)
        private val AV = intArrayOf(R.id.fc_a0, R.id.fc_a1, R.id.fc_a2, R.id.fc_a3, R.id.fc_a4, R.id.fc_a5)
        private val DOT = intArrayOf(R.id.fc_d0, R.id.fc_d1, R.id.fc_d2, R.id.fc_d3, R.id.fc_d4, R.id.fc_d5)
        private val NAME = intArrayOf(R.id.fc_n0, R.id.fc_n1, R.id.fc_n2, R.id.fc_n3, R.id.fc_n4, R.id.fc_n5)

        private fun color(state: String): Int = when (state) {
            "ok" -> 0xFF22C58B.toInt()
            "check" -> 0xFFE0A500.toInt()
            "sos" -> 0xFFE0485A.toInt()
            else -> 0xFF8A94A6.toInt()
        }

        /** Re-check one member with the phone clock (mirror of fcRecheck). */
        fun stateNow(state: String, freshUntil: Long, now: Long): String =
            if ((state == "ok" || state == "check") && (freshUntil <= 0L || now > freshUntil)) "stale" else state

        fun renderAll(context: Context) {
            try {
                val mgr = AppWidgetManager.getInstance(context)
                val ids = mgr.getAppWidgetIds(ComponentName(context, FamilyWidgetProvider::class.java))
                if (ids.isNotEmpty()) render(context, mgr, ids)
            } catch (e: Throwable) {
                // never crash a launcher
            }
        }

        private fun render(context: Context, mgr: AppWidgetManager, ids: IntArray) {
            val now = System.currentTimeMillis()
            var snap: JSONObject? = null
            try {
                val raw = HomeWidgetPlugin.getData(context).getString("fc_widget_json", "") ?: ""
                if (raw.isNotBlank()) snap = JSONObject(raw)
            } catch (e: Throwable) {
                snap = null
            }
            var nextTick = Long.MAX_VALUE
            for (id in ids) {
                val v = RemoteViews(context.packageName, R.layout.fc_family_widget)
                if (snap == null) {
                    v.setTextViewText(R.id.fc_title, "")
                    v.setTextViewText(R.id.fc_asof, "")
                    v.setTextViewText(R.id.fc_line, "")
                    for (i in SLOT.indices) v.setViewVisibility(SLOT[i], View.GONE)
                } else {
                    v.setTextViewText(R.id.fc_title, snap.optString("title"))
                    v.setTextViewText(R.id.fc_asof, snap.optString("as_of"))
                    val members = snap.optJSONArray("members")
                    var line = snap.optString("line")
                    val lineState = snap.optString("line_state")
                    var lineRank = when (lineState) { "sos" -> 0; "check" -> 1; "stale" -> 2; else -> 3 }
                    val n = members?.length() ?: 0
                    for (i in SLOT.indices) {
                        if (members == null || i >= n) {
                            v.setViewVisibility(SLOT[i], View.GONE)
                            continue
                        }
                        val m = members.optJSONObject(i) ?: continue
                        val fu = m.optLong("fu", 0L)
                        val sent = m.optString("s")
                        val st = stateNow(sent, fu, now)
                        if (st != sent && st == "stale") {
                            // the app said OK / check; time has run out -> gray + say so
                            if (lineRank > 2 || (lineRank == 1 && m.optBoolean("line_owner"))) {
                                line = m.optString("g", line)
                                lineRank = 2
                            }
                        } else if ((sent == "ok" || sent == "check") && fu > now && fu < nextTick) {
                            nextTick = fu
                        }
                        v.setViewVisibility(SLOT[i], View.VISIBLE)
                        v.setTextViewText(AV[i], m.optString("i"))
                        v.setTextViewText(NAME[i], m.optString("n"))
                        v.setInt(DOT[i], "setColorFilter", color(st))
                        v.setContentDescription(SLOT[i], m.optString("n") + ": " + m.optString("w_$st"))
                    }
                    v.setTextViewText(R.id.fc_line, line)
                }
                val open = context.packageManager.getLaunchIntentForPackage(context.packageName)
                if (open != null) {
                    open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    open.putExtra("assisto_src", "widget")
                    open.putExtra("assisto_open", "family")
                    val pi = PendingIntent.getActivity(context, 7301, open,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                    v.setOnClickPendingIntent(R.id.fc_root, pi)
                }
                mgr.updateAppWidget(id, v)
            }
            scheduleTick(context, if (nextTick == Long.MAX_VALUE) 0L else nextTick + 1000L)
        }

        /** One inexact, NON-wakeup alarm: fires when the phone is awake anyway. */
        private fun scheduleTick(context: Context, at: Long) {
            try {
                val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
                val i = Intent(context, FamilyWidgetProvider::class.java).setAction(ACTION_TICK)
                val pi = PendingIntent.getBroadcast(context, 7302, i,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                am.cancel(pi)
                if (at > 0L) am.set(AlarmManager.RTC, at, pi)
            } catch (e: Throwable) {
                // no alarm: the next app open refreshes the widget
            }
        }
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        try {
            render(context, appWidgetManager, appWidgetIds)
        } catch (e: Throwable) {
            // never crash a launcher
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_TICK) renderAll(context)
    }

    override fun onDisabled(context: Context) {
        scheduleTick(context, 0L)
    }
}
