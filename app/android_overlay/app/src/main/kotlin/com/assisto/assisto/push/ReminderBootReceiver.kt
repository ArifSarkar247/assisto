package com.assisto.assisto.push

import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver
import org.json.JSONArray

/**
 * notif-nine — reminder alarms survive a restart / app update even when
 * Android withholds exact alarms.
 *
 * The BUG (seen on the Android 14 CI emulator, run 44289591521): at
 * BOOT_COMPLETED / MY_PACKAGE_REPLACED the flutter_local_notifications boot
 * receiver re-arms every cached reminder; one cached as EXACT throws
 * ExactAlarmPermissionException when "Alarms & reminders" is off at that
 * moment, and the plugin then DELETES it from its cache ("Exact alarms are
 * not permitted"). So every reminder armed while the permission was on, and
 * revoked since (by the user, an OEM cleaner, Android's unused-app reset),
 * vanished at the next restart or Play update until the app was opened.
 *
 * Now this receiver runs instead of the plugin's (manifest, android.yml):
 * without exact permission it first rewrites the cached schedule modes to
 * their honest INEXACT twins (the reminder still rings, maybe a few minutes
 * late), then hands over to the plugin's own receiver. Everything guarded:
 * any failure still calls the plugin's receiver, exactly as before.
 */
class ReminderBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        try {
            val n = downgradeIfNeeded(context)
            Log.i(TAG, "REM_BOOT action=${intent?.action} downgraded=$n")
        } catch (t: Throwable) {
            Log.w(TAG, "REM_BOOT downgrade skipped: ${t.javaClass.simpleName}")
        }
        try {
            ScheduledNotificationBootReceiver().onReceive(context, intent ?: return)
        } catch (t: Throwable) {
            Log.w(TAG, "REM_BOOT reschedule failed: ${t.javaClass.simpleName}")
        }
    }

    companion object {
        private const val TAG = "AssistoRem"
        private const val PREFS = "scheduled_notifications" // the plugin's store
        private const val KEY = "scheduled_notifications"

        /** Exact -> inexact in the plugin's cache when exact alarms are not
         *  allowed now. Returns how many entries changed. */
        @JvmStatic
        fun downgradeIfNeeded(ctx: Context): Int {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return 0
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return 0
            if (am.canScheduleExactAlarms()) return 0
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val json = p.getString(KEY, null) ?: return 0
            val (out, n) = downgradeJson(json)
            if (n > 0) p.edit().putString(KEY, out).commit()
            return n
        }

        /** PURE: the cache JSON with exact modes made inexact (+ count). */
        @JvmStatic
        fun downgradeJson(json: String): Pair<String, Int> {
            val arr = JSONArray(json)
            var n = 0
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val m = o.opt("scheduleMode")
                val to = when (m) {
                    "exact" -> "inexact"
                    "exactAllowWhileIdle", "alarmClock" -> "inexactAllowWhileIdle"
                    true -> "inexactAllowWhileIdle"   // pre-enum boolean form
                    // no mode = the plugin's legacy default EXACT -> would throw too
                    null -> if (o.has("scheduledDateTime") || o.has("millisecondsSinceEpoch"))
                        "inexactAllowWhileIdle" else null
                    else -> null
                }
                if (to != null) {
                    o.put("scheduleMode", to)
                    n++
                }
            }
            return Pair(if (n > 0) arr.toString() else json, n)
        }
    }
}
