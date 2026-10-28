package com.assisto.assisto.antitheft

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import org.json.JSONObject

/**
 * at100 — remote switches sent by the owner or an approved trusted contact
 * THROUGH THE SERVER (security/engine/command). They reach the phone only in
 * the engine's own check-in response (never an SMS, never an open port): a
 * silent high-priority FCM push only WAKES the engine so it checks in now.
 *
 * Kinds (MUST match core/views_at_remote.COMMAND_KINDS):
 *   lost_mode   show the owner's message on the lock screen (+ faster check-ins,
 *               already handled by HeartbeatPolicy via the server's lost_mode)
 *   alarm       loud alarm on the ALARM stream for alarm_s seconds (default 60)
 *   alarm_stop  stop it
 *   lock        DevicePolicyManager.lockNow (only if device admin is active)
 *   message     lock-screen message notification + lock (if admin is active)
 *
 * Honest results ("ok" + a short detail) are queued as a command_result item
 * in the store-and-forward queue, so they reach the server even if the
 * network drops right after. Every step is try/catch: nothing here may crash
 * the engine. No new permissions (VIBRATE + POST_NOTIFICATIONS are already
 * declared; the alarm uses the default alarm tone, no storage access).
 */
object RemoteCommands {
    val KINDS = setOf("lost_mode", "alarm", "alarm_stop", "lock", "message")
    const val DEFAULT_ALARM_S = 60
    const val MAX_ALARM_S = 120
    private const val PREFS = "assisto_antitheft_engine"
    private const val K_DONE = "cmd_done"
    private const val DONE_KEEP = 30
    const val LOST_CHANNEL = "assisto_lost_message"
    const val LOST_NOTIF_ID = 8442
    const val ALARM_CHANNEL = "assisto_remote_alarm"
    const val ALARM_NOTIF_ID = 8443

    // ---- pure rules (mirrored in Dart: RemoteCommandRules) ----------------

    /** Run this command? Known kind and not already run (dedupe ring). */
    fun shouldRun(kind: String, id: Long, done: Set<Long>): Boolean =
        id > 0 && kind in KINDS && id !in done

    fun alarmSeconds(raw: Int): Int =
        if (raw <= 0) DEFAULT_ALARM_S else raw.coerceAtMost(MAX_ALARM_S)

    fun encodeDone(done: List<Long>): String = done.takeLast(DONE_KEEP).joinToString(",")

    fun decodeDone(s: String?): List<Long> =
        (s ?: "").split(",").mapNotNull { it.trim().toLongOrNull() }

    // ---- dedupe ring --------------------------------------------------------

    fun doneSet(ctx: Context): Set<Long> = try {
        decodeDone(ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(K_DONE, "")).toSet()
    } catch (_: Throwable) { emptySet() }

    fun markDone(ctx: Context, id: Long) {
        try {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val l = decodeDone(p.getString(K_DONE, "")).toMutableList()
            l.add(id)
            p.edit().putString(K_DONE, encodeDone(l)).commit()
        } catch (_: Throwable) {}
    }

    // ---- execution ----------------------------------------------------------

    /** Run one command. Returns (ok, detail). Never throws. */
    fun run(ctx: Context, c: JSONObject): Pair<Boolean, String> {
        return try {
            val kind = c.optString("kind", "")
            val title = c.optString("title", "")
            val body = c.optString("body", "")
            when (kind) {
                "alarm" -> {
                    val s = alarmSeconds(c.optInt("alarm_s", DEFAULT_ALARM_S))
                    if (RemoteAlarm.start(ctx, s, title, body, c.optString("stop", "Stop")))
                        Pair(true, "rang_${s}s") else Pair(false, "no_sound")
                }
                "alarm_stop" -> {
                    RemoteAlarm.stop(ctx)
                    Pair(true, "stopped")
                }
                "lock" -> {
                    if (DeviceAdminLock.lockNow(ctx)) Pair(true, "locked")
                    else Pair(false, "no_admin")
                }
                "message", "lost_mode" -> {
                    val shown = if (body.isNotBlank()) showLostMessage(ctx, title, body) else false
                    val locked = if (kind == "message") DeviceAdminLock.lockNow(ctx) else false
                    when {
                        kind == "lost_mode" -> Pair(true,
                            if (shown) "lost_mode_message_shown" else "lost_mode_on")
                        shown && locked -> Pair(true, "shown_and_locked")
                        shown -> Pair(true, "shown_not_locked")
                        else -> Pair(false, "notif_blocked")
                    }
                }
                else -> Pair(false, "unknown_kind")
            }
        } catch (_: Throwable) {
            Pair(false, "error")
        }
    }

    private fun notificationsAllowed(nm: NotificationManager): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) nm.areNotificationsEnabled() else true
    } catch (_: Throwable) { true }

    /** A PUBLIC (shown in full on the lock screen) "This phone is lost"
     *  notification with the owner's message + contact. Ongoing until lost
     *  mode is turned off on the server. */
    fun showLostMessage(ctx: Context, title: String, body: String): Boolean {
        return try {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return false
            if (!notificationsAllowed(nm)) return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                nm.createNotificationChannel(NotificationChannel(
                    LOST_CHANNEL, title.ifBlank { "Lost phone" },
                    NotificationManager.IMPORTANCE_HIGH).apply {
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setShowBadge(false)
                })
            }
            val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(ctx, LOST_CHANNEL) else
                @Suppress("DEPRECATION") Notification.Builder(ctx)
            b.setSmallIcon(ctx.applicationInfo.icon)
                .setContentTitle(title.ifBlank { "This phone is lost" })
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setOngoing(true)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                @Suppress("DEPRECATION")
                b.setPriority(Notification.PRIORITY_MAX)
            }
            nm.notify(LOST_NOTIF_ID, b.build())
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun clearLostMessage(ctx: Context) {
        try {
            (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)
                ?.cancel(LOST_NOTIF_ID)
        } catch (_: Throwable) {}
    }
}

/**
 * at100 — the remote loud alarm. Alarm stream at full volume (restored after),
 * looping default alarm tone, vibration, and a notification with a Stop
 * button (whoever finds the phone may stop it — like Find Hub). Stops by
 * itself after N seconds. Main-thread timer; every call guarded.
 */
object RemoteAlarm {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var player: MediaPlayer? = null
    @Volatile private var savedVolume = -1
    @Volatile private var appCtx: Context? = null
    private val autoStop = Runnable { appCtx?.let { stop(it) } }

    val playing: Boolean get() = player != null

    fun start(ctx: Context, seconds: Int, title: String, body: String, stopLabel: String): Boolean {
        val c = ctx.applicationContext
        stop(c)
        appCtx = c
        return try {
            val am = c.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            try {
                savedVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
                am.setStreamVolume(AudioManager.STREAM_ALARM,
                    am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
            } catch (_: Throwable) { savedVolume = -1 }
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                ?: return false
            val mp = MediaPlayer()
            try {
                mp.setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build())
                mp.setDataSource(c, uri)
                mp.isLooping = true
                mp.prepare()
                mp.start()
            } catch (t: Throwable) {
                try { mp.release() } catch (_: Throwable) {}
                restoreVolume(c)
                return false
            }
            player = mp
            vibrate(c)
            postNotif(c, title, body, stopLabel)
            main.removeCallbacks(autoStop)
            main.postDelayed(autoStop, seconds.coerceIn(5, RemoteCommands.MAX_ALARM_S) * 1000L)
            true
        } catch (_: Throwable) {
            stop(c)
            false
        }
    }

    fun stop(ctx: Context) {
        val c = ctx.applicationContext
        try { main.removeCallbacks(autoStop) } catch (_: Throwable) {}
        val p = player
        player = null
        try { p?.stop() } catch (_: Throwable) {}
        try { p?.release() } catch (_: Throwable) {}
        try {
            (c.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator)?.cancel()
        } catch (_: Throwable) {}
        restoreVolume(c)
        try {
            (c.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)
                ?.cancel(RemoteCommands.ALARM_NOTIF_ID)
        } catch (_: Throwable) {}
    }

    private fun restoreVolume(c: Context) {
        try {
            if (savedVolume >= 0) {
                (c.getSystemService(Context.AUDIO_SERVICE) as AudioManager)
                    .setStreamVolume(AudioManager.STREAM_ALARM, savedVolume, 0)
            }
        } catch (_: Throwable) {}
        savedVolume = -1
    }

    @Suppress("DEPRECATION")
    private fun vibrate(c: Context) {
        try {
            val v = c.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
            val pattern = longArrayOf(0, 800, 400)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                v.vibrate(pattern, 0)
            }
        } catch (_: Throwable) {}
    }

    private fun postNotif(c: Context, title: String, body: String, stopLabel: String) {
        try {
            val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                nm.createNotificationChannel(NotificationChannel(
                    RemoteCommands.ALARM_CHANNEL, title.ifBlank { "Alarm" },
                    NotificationManager.IMPORTANCE_HIGH).apply {
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setSound(null, null) // the MediaPlayer is the sound
                })
            }
            val stopIntent = Intent(c, AntiTheftService::class.java)
                .setAction(AntiTheftService.ACTION_ALARM_STOP)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            val stopPi = PendingIntent.getService(c, 12, stopIntent, flags)
            val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(c, RemoteCommands.ALARM_CHANNEL) else
                @Suppress("DEPRECATION") Notification.Builder(c)
            b.setSmallIcon(c.applicationInfo.icon)
                .setContentTitle(title.ifBlank { "Assisto alarm" })
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setOngoing(true)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(Notification.Action.Builder(
                    null as android.graphics.drawable.Icon?,
                    stopLabel.ifBlank { "Stop" }, stopPi).build())
            nm.notify(RemoteCommands.ALARM_NOTIF_ID, b.build())
        } catch (_: Throwable) {}
    }
}
