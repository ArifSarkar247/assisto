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
 *   * BOOT_COMPLETED only QUEUES a 'boot' event if the user had protection ON
 *     (token in prefs). It never starts a service (see below), so nothing
 *     runs on boot; protection resumes when the owner next opens Assisto.
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
                    // Queue a boot event (the user had protection ON).
                    try {
                        val q = AntiTheftQueue(ctx)
                        q.add("boot-" + System.currentTimeMillis(), "boot",
                            System.currentTimeMillis(), null, null, null)
                    } catch (_: Throwable) {
                    }
                    // We deliberately do NOT start the foreground service from
                    // BOOT_COMPLETED: on Android 14+ a location-type FGS started
                    // from the background can throw in startForeground, and a
                    // missed startForeground kills the whole process. The boot
                    // event waits in the queue; protection resumes (and the
                    // queue uploads) the next time the owner opens Assisto.
                }
            }
        } catch (_: Throwable) {
            // never block shutdown/boot
        }
    }
}
