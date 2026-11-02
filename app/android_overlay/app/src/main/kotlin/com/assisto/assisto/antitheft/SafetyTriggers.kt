package com.assisto.assisto.antitheft

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import org.json.JSONObject
import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.sqrt

/**
 * sosat — SOS triggers that run INSIDE the already-running, opt-in Always-on
 * protection foreground service (AntiTheftService). No new service, no
 * WorkManager, no ContentProvider, no new permission, nothing at app launch.
 *
 *   * Lock-screen SOS: an "SOS" button on the protection notification.
 *   * Power button x5 (opt-in, default OFF): 5 screen toggles within 4 s.
 *     Both start a 10 s countdown notification with "Cancel"; then the SOS
 *     is queued as an engine event (store-and-forward, original time kept)
 *     and the SERVER rings the family (core/sos_triggers.py).
 *   * EXPERIMENTAL fall detection (opt-in, default OFF): raw accelerometer,
 *     free fall -> impact -> lying still with a new orientation. The phone
 *     asks "Are you OK?" (alarm-channel notification + "I'm OK"); the event
 *     goes to the server at once marked pending, and the SERVER alerts the
 *     family when the window ends without "I'm OK" (even if the phone dies).
 *     Assisto never calls 999 by itself.
 *   * Sensor trace recorder (30 s) for the precision/recall harness.
 *
 * Pure rules mirror app/lib/services/safety_triggers_logic.dart (unit-tested
 * there + measured on labelled traces). Every entry point is crash-guarded.
 */
class SafetyTriggers(private val svc: AntiTheftService, private val bg: Handler) {

    companion object {
        const val PREFS = "assisto_sos_triggers"
        const val ACTION_SOS_ARM = "com.assisto.assisto.antitheft.SOS_ARM"
        const val ACTION_SOS_CANCEL = "com.assisto.assisto.antitheft.SOS_CANCEL"
        const val ACTION_FALL_OK = "com.assisto.assisto.antitheft.FALL_OK"
        const val EXTRA_KIND = "kind"
        const val EXTRA_CID = "cid"
        private const val SOS_CHANNEL = "assisto_sos_trigger"
        private const val FALL_CHANNEL = "assisto_fall_check"
        private const val SOS_NOTIF_ID = 8450
        private const val FALL_NOTIF_ID = 8451
        const val CANCEL_WINDOW_MS = 10_000L

        fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /** From Dart (AntiTheftChannel.setSosTriggers). Never throws. */
        fun save(ctx: Context, m: Map<String, Any?>) {
            try {
                val e = prefs(ctx).edit()
                for ((k, v) in m) {
                    when (v) {
                        is Boolean -> e.putBoolean(k, v)
                        is Int -> e.putInt(k, v)
                        is Long -> e.putInt(k, v.toInt())
                        is String -> e.putString(k, v)
                    }
                }
                e.apply()
            } catch (_: Throwable) {}
        }

        fun lockOn(ctx: Context) = try { prefs(ctx).getBoolean("lock_on", false) } catch (_: Throwable) { false }
        fun powerOn(ctx: Context) = try { prefs(ctx).getBoolean("power_on", false) } catch (_: Throwable) { false }
        fun fallOn(ctx: Context) = try { prefs(ctx).getBoolean("fall_on", false) } catch (_: Throwable) { false }
        fun text(ctx: Context, k: String, d: String) =
            try { prefs(ctx).getString(k, d)?.takeIf { it.isNotBlank() } ?: d } catch (_: Throwable) { d }

        fun clampWindowS(s: Int) = s.coerceIn(30, 600)

        fun action(ctx: Context, label: String, act: String, req: Int, cid: String?): Notification.Action? = try {
            val i = Intent(ctx, AntiTheftService::class.java).setAction(act)
            if (cid != null) i.putExtra(EXTRA_CID, cid)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            Notification.Action.Builder(null as android.graphics.drawable.Icon?, label,
                PendingIntent.getService(ctx, req, i, flags)).build()
        } catch (_: Throwable) { null }

        /** The "SOS" button for the protection notification (lock screen). */
        fun sosAction(ctx: Context): Notification.Action? =
            if (lockOn(ctx)) action(ctx, text(ctx, "sosAction", "SOS"), ACTION_SOS_ARM, 40, null) else null

        /** Path of the newest recorded trace ("" = none yet). */
        fun lastTrace(ctx: Context): String = try {
            prefs(ctx).getString("last_trace", "") ?: ""
        } catch (_: Throwable) { "" }
    }

    // ---- pure rules (mirror of safety_triggers_logic.dart) ---------------

    private object Fall {
        const val G = 9.80665
        const val FREE_FALL_MAX = 0.5 * G
        const val FREE_FALL_MIN_MS = 120L
        const val IMPACT_MIN = 2.5 * G
        const val IMPACT_WITHIN_MS = 800L
        const val SETTLE_MS = 1000L
        const val STILL_MS = 3000L
        const val STILL_TOL = 1.2
        const val STILL_FRACTION = 0.85
        const val ORIENT_CHANGE_DEG = 35.0
        const val COOLDOWN_MS = 60_000L
    }

    private var phase = 0 // 0 idle 1 falling 2 awaitImpact 3 settling 4 still
    private var ffStart = 0L
    private var ffEnd = 0L
    private var impactAt = 0L
    private var fallCooldownUntil = 0L
    private var stillN = 0
    private var stillOk = 0
    private val grav = doubleArrayOf(0.0, 0.0, Fall.G)
    private val before = DoubleArray(3)
    private val after = DoubleArray(3)

    private fun angleDeg(a: DoubleArray, b: DoubleArray): Double {
        val na = sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])
        val nb = sqrt(b[0] * b[0] + b[1] * b[1] + b[2] * b[2])
        if (na < 1e-6 || nb < 1e-6) return 0.0
        val c = ((a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) / (na * nb)).coerceIn(-1.0, 1.0)
        return Math.toDegrees(acos(c))
    }

    private fun fallReset() { phase = 0; stillN = 0; stillOk = 0 }

    /** Returns true exactly once when a fall completes. */
    private fun fallSample(x: Double, y: Double, z: Double, t: Long): Boolean {
        val m = sqrt(x * x + y * y + z * z)
        if (t < fallCooldownUntil) return false
        if (phase == 0) {
            if (abs(m - Fall.G) < 2.0) {
                grav[0] = grav[0] * 0.9 + x * 0.1
                grav[1] = grav[1] * 0.9 + y * 0.1
                grav[2] = grav[2] * 0.9 + z * 0.1
            }
            if (m < Fall.FREE_FALL_MAX) {
                phase = 1; ffStart = t
                before[0] = grav[0]; before[1] = grav[1]; before[2] = grav[2]
            }
            return false
        }
        if (phase == 1) {
            if (m < Fall.FREE_FALL_MAX) return false
            ffEnd = t
            if (ffEnd - ffStart < Fall.FREE_FALL_MIN_MS) { fallReset(); return false }
            phase = 2
        }
        if (phase == 2) {
            if (m >= Fall.IMPACT_MIN) { phase = 3; impactAt = t }
            else if (t - ffEnd > Fall.IMPACT_WITHIN_MS) fallReset()
            return false
        }
        if (phase == 3) {
            if (t - impactAt >= Fall.SETTLE_MS) {
                phase = 4; stillN = 0; stillOk = 0
                after[0] = 0.0; after[1] = 0.0; after[2] = 0.0
            }
            return false
        }
        stillN++
        if (abs(m - Fall.G) <= Fall.STILL_TOL) stillOk++
        after[0] += x; after[1] += y; after[2] += z
        if (t - impactAt < Fall.SETTLE_MS + Fall.STILL_MS) return false
        val still = stillN > 0 && stillOk.toDouble() / stillN >= Fall.STILL_FRACTION
        val turned = angleDeg(before, after) >= Fall.ORIENT_CHANGE_DEG
        fallReset()
        if (still && turned) {
            fallCooldownUntil = t + Fall.COOLDOWN_MS
            return true
        }
        return false
    }

    private val presses = ArrayList<Long>()
    private var powerCooldownUntil = 0L

    // ---- live state --------------------------------------------------------

    @Volatile private var recUntil = 0L
    private var rec: StringBuilder? = null
    private var recMeta: Map<String, String> = emptyMap()
    @Volatile private var pendingKind: String? = null
    private var pendingFallCid: String? = null

    /** Is the raw accelerometer needed now (fall on, or a recording)? */
    fun wantsRaw(): Boolean = fallOn(svc) || System.currentTimeMillis() < recUntil

    /** One RAW accelerometer sample (sensor thread). */
    fun onRawAccel(x: Float, y: Float, z: Float, tMs: Long) {
        try {
            val r = rec
            if (r != null) {
                if (tMs <= recUntil) {
                    r.append(tMs).append(',').append(x).append(',').append(y)
                        .append(',').append(z).append('\n')
                } else {
                    rec = null
                    val text = r.toString()
                    bg.post { writeTrace(text) }
                }
            }
            if (fallOn(svc) && fallSample(x.toDouble(), y.toDouble(), z.toDouble(), tMs)) {
                bg.post { try { onFall(tMs) } catch (_: Throwable) {} }
            }
        } catch (_: Throwable) {}
    }

    /** Screen on/off broadcast (power button). */
    fun onScreenToggle(tMs: Long) {
        try {
            if (!powerOn(svc) || tMs < powerCooldownUntil) return
            presses.add(tMs)
            presses.removeAll { tMs - it > 4000L }
            if (presses.size >= 5) {
                presses.clear()
                powerCooldownUntil = tMs + 60_000L
                bg.post { try { arm("sos_power") } catch (_: Throwable) {} }
            }
        } catch (_: Throwable) {}
    }

    /** Service intents (notification buttons). true = handled. */
    fun handle(i: Intent?): Boolean {
        return try {
            when (i?.action) {
                ACTION_SOS_ARM -> { bg.post { arm(i.getStringExtra(EXTRA_KIND) ?: "sos_lockscreen") }; true }
                ACTION_SOS_CANCEL -> { bg.post { cancelSos() }; true }
                ACTION_FALL_OK -> { bg.post { fallOk(i.getStringExtra(EXTRA_CID)) }; true }
                else -> false
            }
        } catch (_: Throwable) { false }
    }

    // ---- SOS countdown (lock screen / power button) ------------------------

    private val fireSos = Runnable { try { fire() } catch (_: Throwable) {} }

    private fun arm(kind: String) {
        if (pendingKind != null) return
        pendingKind = kind
        val fireAt = System.currentTimeMillis() + CANCEL_WINDOW_MS
        notify(SOS_NOTIF_ID, SOS_CHANNEL,
            text(svc, "sosArmTitle", "SOS in 10 seconds"),
            text(svc, "sosArmBody", "Your family will be alerted with your location. Tap Cancel if this was a mistake."),
            action(text(svc, "sosCancel", "Cancel"), ACTION_SOS_CANCEL, 41, null),
            countdownTo = fireAt, alarm = false)
        bg.removeCallbacks(fireSos)
        bg.postDelayed(fireSos, CANCEL_WINDOW_MS)
    }

    private fun cancelSos() {
        bg.removeCallbacks(fireSos)
        pendingKind = null
        cancel(SOS_NOTIF_ID)
    }

    private fun fire() {
        val kind = pendingKind ?: return
        pendingKind = null
        svc.captureTrigger(kind, JSONObject().put("source", kind), System.currentTimeMillis(),
            "$kind-" + UUID.randomUUID().toString().take(12))
        notify(SOS_NOTIF_ID, SOS_CHANNEL,
            text(svc, "sosSentTitle", "SOS is going to your family"),
            text(svc, "sosSentBody", "It is sent the moment this phone has internet. Open Assisto to see who has seen it."),
            null, countdownTo = 0L, alarm = false)
    }

    // ---- fall ---------------------------------------------------------------

    private val fallClear = Runnable { try { pendingFallCid = null; cancel(FALL_NOTIF_ID) } catch (_: Throwable) {} }

    private fun onFall(tMs: Long) {
        if (pendingFallCid != null) return
        val win = clampWindowS(try { prefs(svc).getInt("fall_window_s", 60) } catch (_: Throwable) { 60 })
        val cid = "fall-" + UUID.randomUUID().toString().take(12)
        pendingFallCid = cid
        svc.captureTrigger("fall", JSONObject().put("confirm", "pending")
            .put("window_s", win).put("experimental", true), tMs, cid)
        notify(FALL_NOTIF_ID, FALL_CHANNEL,
            text(svc, "fallTitle", "Did you fall? Are you OK?"),
            text(svc, "fallBody", "If you don't tap I'm OK, your family will be alerted with your location. Assisto never calls 999 by itself."),
            action(text(svc, "fallOk", "I'm OK"), ACTION_FALL_OK, 42, cid),
            countdownTo = tMs + win * 1000L, alarm = true)
        bg.removeCallbacks(fallClear)
        bg.postDelayed(fallClear, win * 1000L)
    }

    private fun fallOk(cid: String?) {
        val ref = cid ?: pendingFallCid ?: return
        bg.removeCallbacks(fallClear)
        pendingFallCid = null
        cancel(FALL_NOTIF_ID)
        svc.captureTrigger("fall_ok", JSONObject().put("ref", ref), System.currentTimeMillis(),
            "fallok-" + UUID.randomUUID().toString().take(12))
    }

    // ---- trace recorder -------------------------------------------------------

    /** Record [seconds] of raw accelerometer to filesDir/sensor_traces. */
    fun startRecording(seconds: Int, meta: Map<String, String>): Boolean {
        return try {
            recMeta = meta
            rec = StringBuilder(64 * 1024)
            recUntil = System.currentTimeMillis() + seconds.coerceIn(5, 120) * 1000L
            svc.refreshRawSensor()
            true
        } catch (_: Throwable) { false }
    }

    private fun writeTrace(body: String) {
        try {
            val dir = File(svc.filesDir, "sensor_traces").apply { mkdirs() }
            val f = File(dir, "rec-" + System.currentTimeMillis() + ".csv")
            val sb = StringBuilder()
            sb.append("# source=recorded (").append(Build.MANUFACTURER).append(' ')
                .append(Build.MODEL).append(", Android ").append(Build.VERSION.SDK_INT).append(")\n")
            for ((k, v) in recMeta) sb.append("# ").append(k).append('=').append(v.replace('\n', ' ')).append('\n')
            sb.append("t_ms,x,y,z\n")
            // times relative to the first sample (the harness format)
            var t0 = -1L
            for (line in body.lineSequence()) {
                if (line.isBlank()) continue
                val c = line.indexOf(',')
                val t = line.substring(0, c).toLongOrNull() ?: continue
                if (t0 < 0) t0 = t
                sb.append(t - t0).append(line.substring(c)).append('\n')
            }
            f.writeText(sb.toString())
            prefs(svc).edit().putString("last_trace", f.absolutePath).apply()
            svc.refreshRawSensor()
        } catch (_: Throwable) {}
    }

    // ---- notifications ---------------------------------------------------------

    private fun action(label: String, act: String, req: Int, cid: String?): Notification.Action? =
        action(svc, label, act, req, cid)

    private fun notify(id: Int, channel: String, title: String, body: String,
                       act: Notification.Action?, countdownTo: Long, alarm: Boolean) {
        try {
            val nm = svc.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val ch = NotificationChannel(channel, title, NotificationManager.IMPORTANCE_HIGH)
                ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                ch.enableVibration(true)
                ch.vibrationPattern = longArrayOf(0, 600, 300, 600, 300, 600)
                if (alarm) {
                    // the alarm stream via the notification channel only (no
                    // AudioManager mode / speaker calls — audio-route rule)
                    ch.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
                }
                nm.createNotificationChannel(ch)
            }
            val open = svc.packageManager.getLaunchIntentForPackage(svc.packageName)
                ?.putExtra("assisto_open", if (alarm) "fall_check" else "sos_ladder")
                ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val pi = if (open != null) PendingIntent.getActivity(svc, id, open,
                PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)) else null
            val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(svc, channel) else
                @Suppress("DEPRECATION") Notification.Builder(svc)
            b.setSmallIcon(svc.applicationInfo.icon)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setCategory(if (alarm) Notification.CATEGORY_ALARM else Notification.CATEGORY_STATUS)
            if (pi != null) b.setContentIntent(pi)
            if (act != null) b.addAction(act)
            if (countdownTo > 0L) {
                b.setWhen(countdownTo).setShowWhen(true).setUsesChronometer(true)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) b.setChronometerCountDown(true)
                b.setOngoing(true)
            } else {
                b.setAutoCancel(true)
            }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                @Suppress("DEPRECATION")
                b.setPriority(Notification.PRIORITY_MAX).setDefaults(Notification.DEFAULT_ALL)
            }
            nm.notify(id, b.build()) // no POST_NOTIFICATIONS -> dropped (honest UI says so)
        } catch (_: Throwable) {}
    }

    private fun cancel(id: Int) {
        try {
            (svc.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)?.cancel(id)
        } catch (_: Throwable) {}
    }
}
