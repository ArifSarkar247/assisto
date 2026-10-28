package com.assisto.assisto.diag

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * ops-watch: why did the PREVIOUS process die? (ANR / Java crash / native
 * crash) — read from Android's own ApplicationExitInfo (API 30+), so our
 * crash / ANR rate also counts deaths the Dart reporter could never see.
 *
 * Channel "com.assisto/exit_info" (registered from MainActivity inside the
 * usual try/catch; registering is free — NOTHING runs at launch):
 *
 *   pending()        -> List<Map> exits newer than the last ack: kind
 *                       ("anr" | "exit_crash"), ts (ms), reason, native (Bool),
 *                       importance, description (<=160 chars; the server and
 *                       the Dart side scrub it again). Foreground (user-
 *                       perceived) ANRs only. [] below API 30 / on any error.
 *   ack({ts})        -> Bool  remember the newest reported exit.
 *
 * The lookup is a binder call, so it runs on a background thread and only
 * when Dart asks (lib/diag/exit_info.dart, ~20 s after start, signed-in users
 * only). First use: only the last 7 days are reported. No WorkManager, no
 * ContentProvider, no service.
 */
object ExitInfoChannel {
    private const val NAME = "com.assisto/exit_info"
    private const val PREFS = "assisto_exit_info"
    private const val KEY_ACKED = "acked_ts"
    private const val FIRST_WINDOW_MS = 7L * 24 * 3600 * 1000

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        val main = Handler(Looper.getMainLooper())
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "pending" -> Thread {
                    val out = try {
                        pending(app)
                    } catch (e: Throwable) {
                        emptyList<Map<String, Any>>()
                    }
                    main.post {
                        try {
                            result.success(out)
                        } catch (e: Throwable) {
                        }
                    }
                }.start()
                "ack" -> {
                    val ok = try {
                        val ts = (call.argument<Any>("ts") as? Number)?.toLong() ?: 0L
                        if (ts > 0) {
                            val p = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                            if (ts > p.getLong(KEY_ACKED, 0L)) {
                                p.edit().putLong(KEY_ACKED, ts).apply()
                            }
                        }
                        true
                    } catch (e: Throwable) {
                        false
                    }
                    result.success(ok)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun pending(ctx: Context): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return emptyList()
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val acked = p.getLong(KEY_ACKED, 0L)
        val floor = if (acked > 0) acked else System.currentTimeMillis() - FIRST_WINDOW_MS
        val out = ArrayList<Map<String, Any>>()
        for (info in am.getHistoricalProcessExitReasons(ctx.packageName, 0, 16)) {
            if (info.timestamp <= floor) continue
            val kind = when (info.reason) {
                ApplicationExitInfo.REASON_ANR ->
                    if (info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE) "anr" else null
                ApplicationExitInfo.REASON_CRASH,
                ApplicationExitInfo.REASON_CRASH_NATIVE -> "exit_crash"
                else -> null
            } ?: continue
            out.add(
                mapOf(
                    "kind" to kind,
                    "ts" to info.timestamp,
                    "reason" to info.reason,
                    "native" to (info.reason == ApplicationExitInfo.REASON_CRASH_NATIVE),
                    "importance" to info.importance,
                    "description" to (info.description ?: "").take(160)
                )
            )
            if (out.size >= 8) break
        }
        return out
    }
}
