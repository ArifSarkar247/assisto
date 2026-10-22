package com.assisto.assisto.antitheft

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/**
 * b6-antitheft — ACTION_SHUTDOWN + BOOT_COMPLETED manifest receiver.
 *
 * HONEST LIMITS:
 *   * No app can BLOCK a shutdown. ACTION_SHUTDOWN is a best-effort, very short
 *     window: the system is already tearing down, so we only QUEUE a 'shutdown'
 *     event with the last location (it uploads next time the phone is online).
 *     A forced power-off (hold-button / dead battery) sends no broadcast at
 *     all — that gap is covered by the server's "went dark" alert and by the
 *     phone-maker brand lock the app guides the user to enable.
 *   * BOOT_COMPLETED only RE-ARMS protection if the user had it ON (token in
 *     prefs). It does NOT start anything on a fresh install or when protection
 *     is off, and it is wrapped so a crash here can never block boot. This is
 *     the single allowed boot path, and only because the user opted in.
 *
 * This receiver does NO heavy work and starts nothing at app launch.
 */
class ShutdownReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        val ctx = context ?: return
        try {
            val prefs = ctx.getSharedPreferences(
                "assisto_antitheft_engine", Context.MODE_PRIVATE)
            val token = prefs.getString("token", "") ?: ""
            if (token.isBlank()) return  // protection off → do nothing

            when (intent?.action) {
                Intent.ACTION_SHUTDOWN, "android.intent.action.QUICKBOOT_POWEROFF" -> {
                    // Queue a shutdown event with the last location. We can't
                    // upload reliably mid-shutdown, so it waits in the queue.
                    try {
                        val q = AntiTheftQueue(ctx)
                        val loc = LastLocation.get(ctx)
                        q.add("shutdown-" + System.currentTimeMillis(),
                            "shutdown", System.currentTimeMillis(),
                            loc?.first, loc?.second, null,
                            JSONObject().put("note", "best_effort"))
                    } catch (_: Throwable) {
                    }
                }
                Intent.ACTION_BOOT_COMPLETED,
                "android.intent.action.QUICKBOOT_POWERON" -> {
                    // Re-arm: queue a boot event and restart the service (the
                    // user had protection ON). Fully crash-guarded.
                    try {
                        val q = AntiTheftQueue(ctx)
                        q.add("boot-" + System.currentTimeMillis(), "boot",
                            System.currentTimeMillis(), null, null, null)
                    } catch (_: Throwable) {
                    }
                    try {
                        AntiTheftService.start(
                            ctx, token,
                            prefs.getString("api", "") ?: "",
                            JSONObject(prefs.getString("config", "{}") ?: "{}"),
                            prefs.getString("title", "Assisto protection is on")
                                ?: "Assisto protection is on",
                            prefs.getString("body", "") ?: "")
                    } catch (_: Throwable) {
                    }
                }
            }
        } catch (_: Throwable) {
            // never block shutdown/boot
        }
    }
}
