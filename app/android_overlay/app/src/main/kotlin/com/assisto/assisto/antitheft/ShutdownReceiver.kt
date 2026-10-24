package com.assisto.assisto.antitheft

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/**
 * b6-antitheft — ACTION_SHUTDOWN + BOOT_COMPLETED + MY_PACKAGE_REPLACED
 * manifest receiver.
 *
 * HONEST LIMITS:
 *   * No app can BLOCK a shutdown. ACTION_SHUTDOWN is a best-effort, very short
 *     window: the system is already tearing down, so we only QUEUE a 'shutdown'
 *     event with the last location (it uploads next time the phone is online).
 *     A forced power-off (hold-button / dead battery) sends no broadcast at
 *     all — that gap is covered by the server's "went dark" alert and by the
 *     phone-maker brand lock the app guides the user to enable.
 *   * BOOT_COMPLETED queues a 'boot' event if the user had protection ON
 *     (token in prefs).
 *
 * at-heartbeat (owner 24 Oct): a Play update kills the foreground service and
 * nothing brought it back, so the family was told the phone "stopped checking
 * in" while the owner was using it. Now, while protection is ON:
 *   * MY_PACKAGE_REPLACED (app updated) and BOOT_COMPLETED restart the engine
 *     where Android allows it from the background (RestartPolicy: Android 8-13
 *     yes; Android 14+ only with background location, else a quiet "tap to
 *     resume" notification) — without the camera type and WITHOUT re-recording
 *     the SIM baseline;
 *   * the engine also comes back on every app open (AntiTheftChannel.resume).
 *   LOCKED_BOOT_COMPLETED is deliberately NOT used: it needs a direct-boot-
 *   aware receiver, but the engine's prefs/queue live in credential-encrypted
 *   storage that is unreadable before the first unlock, and waking the whole
 *   Flutter app process in direct-boot mode is not safe. BOOT_COMPLETED
 *   arrives right after the first unlock.
 *
 * Everything is try/catch: a failure here never blocks shutdown/boot/update.
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
                    // at-heartbeat: bring the engine back where allowed.
                    try {
                        AntiTheftService.restartFromBackground(ctx, RestartPolicy.BOOT)
                    } catch (_: Throwable) {
                    }
                }
                Intent.ACTION_MY_PACKAGE_REPLACED -> {
                    // The app was just updated: the update killed the engine.
                    try {
                        AntiTheftService.restartFromBackground(ctx, RestartPolicy.UPDATE)
                    } catch (_: Throwable) {
                    }
                }
            }
        } catch (_: Throwable) {
            // never block shutdown/boot/update
        }
    }
}
