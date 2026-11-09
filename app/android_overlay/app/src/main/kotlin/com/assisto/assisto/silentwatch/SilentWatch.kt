package com.assisto.assisto.silentwatch

import android.app.AlarmManager
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.Sensor
import android.hardware.SensorManager
import android.hardware.TriggerEvent
import android.hardware.TriggerEventListener
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Calendar

/**
 * fcelder — Silent Watch, the elder phone's side (opt-in, set up by a child
 * with the elder's own spoken YES). NO WorkManager, NO service, NO startup
 * ContentProvider, NO new permission: AlarmManager alarms to this app's own
 * explicit receiver (the same approach as the Care Call / reminder alarms),
 * re-armed after a reboot / app update by the receiver itself.
 *
 *   PROBE   every ~15 min inside the elder's day window: is the phone in use
 *           right now (screen on AND unlocked)? was the charger plugged in or
 *           pulled out since the last check? did Assisto run (the Dart side
 *           writes "flutter.sw_dart_activity_ms")? Any of those = a sign of
 *           life, kept ONLY on this phone (8-day log for the 7-day learning).
 *   RING n  at deadline = last sign of life + table[slot] (the table is
 *           computed by the Dart brain from the learned day): an "Are you
 *           OK?" alarm notification with a big I AM OK button; n = 1..4,
 *           5 minutes apart. After "I am going out" (away_until_ms) the
 *           first ring waits until away_until + 30 min (ringAtAway).
 *   ESCALATE after the 4th unanswered ring: ONE POST to the server
 *           (family/silent-watch/alert {token}) — the only thing that ever
 *           leaves the phone. Retried every 5 min (max 12) while offline.
 *   MOTION  TYPE_SIGNIFICANT_MOTION (one-shot, wake-up, needs NO permission
 *           on any API level — unlike the step sensors, which need
 *           ACTIVITY_RECOGNITION on API 29+; owner rule 9 Nov: no new
 *           sensitive permission). Re-armed at every check; a trigger = a
 *           sign of life. LIMIT: since Android 9 one-shot sensors deliver
 *           nothing to an app in the background, so it only helps on
 *           Android 8 or while Assisto runs (app open / anti-theft
 *           foreground service). Missing sensor / any error = skipped.
 *   OK      the button / Easy Home / the app: stop ringing; if the family was
 *           already told, POST family/silent-watch/ok {token}.
 *
 * Everything is crash-guarded: any failure means "do nothing", never a crash.
 * Ring time logic mirrors app/lib/eldercare/silent_watch_brain.dart ringAt.
 */
object SilentWatch {
    const val PREFS = "assisto_silent_watch"
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val DART_KEY = "flutter.sw_dart_activity_ms"
    const val CHANNEL_ID = "assisto_silent_watch"
    private const val NOTIF_ID = 7301
    const val ACTION_PROBE = "com.assisto.assisto.silentwatch.PROBE"
    const val ACTION_RING = "com.assisto.assisto.silentwatch.RING"
    const val ACTION_ESCALATE = "com.assisto.assisto.silentwatch.ESCALATE"
    const val ACTION_OK = "com.assisto.assisto.silentwatch.OK"
    private const val PROBE_MS = 15 * 60 * 1000L
    private const val RING_GAP_MS = 5 * 60 * 1000L
    private const val AWAY_GRACE_MS = 30 * 60 * 1000L
    private const val AWAY_MAX_MS = 6 * 3600 * 1000L
    private const val TOLD_KEEP_MS = 30L * 24 * 3600 * 1000L
    private const val RETRY_MS = 5 * 60 * 1000L
    private const val LOG_KEEP_MS = 8 * 24 * 3600 * 1000L
    private const val LOG_MAX = 3000
    private const val RINGS = 4

    private fun p(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ------------------------------------------------------------ channel
    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "com.assisto/silent_watch").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "arm" -> {
                        @Suppress("UNCHECKED_CAST")
                        val m = (call.arguments as? Map<String, Any?>) ?: emptyMap()
                        result.success(arm(app, m))
                    }
                    "disarm" -> result.success(disarm(app))
                    "noteActivity" -> { record(app, System.currentTimeMillis(), true); result.success(true) }
                    "ok" -> result.success(ok(app))
                    "goingOut" -> result.success(goingOut(app, (call.arguments as? Number)?.toInt() ?: 0))
                    "state" -> result.success(state(app))
                    else -> result.notImplemented()
                }
            } catch (_: Throwable) {
                result.success(null)
            }
        }
    }

    fun arm(ctx: Context, m: Map<String, Any?>): Boolean {
        return try {
            @Suppress("UNCHECKED_CAST")
            val table = (m["table"] as? List<Any?>)?.mapNotNull { (it as? Number)?.toInt() } ?: emptyList()
            if (table.size != 48) return false
            val e = p(ctx).edit()
            e.putBoolean("enabled", m["enabled"] as? Boolean ?: true)
            e.putString("table", table.joinToString(","))
            e.putInt("day_start", (m["day_start"] as? Number)?.toInt() ?: 420)
            e.putInt("day_end", (m["day_end"] as? Number)?.toInt() ?: 1320)
            for (k in listOf("token", "api_base", "title", "body", "ok_label", "told_body", "channel_name")) {
                val v = m[k] as? String
                if (v != null) e.putString(k, v)
            }
            if (p(ctx).getLong("last_ms", 0L) == 0L) e.putLong("last_ms", System.currentTimeMillis())
            e.apply()
            ensureChannel(ctx)
            schedule(ctx)
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun disarm(ctx: Context): Boolean {
        return try {
            p(ctx).edit().putBoolean("enabled", false).putInt("stage", 0).apply()
            for (a in listOf(ACTION_PROBE, ACTION_RING, ACTION_ESCALATE)) cancelAlarm(ctx, a)
            cancelNotif(ctx)
            try {
                val sm = ctx.applicationContext.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
                val sensor = sm?.getDefaultSensor(Sensor.TYPE_SIGNIFICANT_MOTION)
                val l = motionListener
                if (sm != null && sensor != null && l != null) sm.cancelTriggerSensor(l, sensor)
            } catch (_: Throwable) {
            }
            motionListener = null
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun state(ctx: Context): Map<String, Any?> {
        val s = p(ctx)
        return mapOf(
            "enabled" to s.getBoolean("enabled", false),
            "stage" to s.getInt("stage", 0),
            "told" to s.getBoolean("told", false),
            "last_ms" to s.getLong("last_ms", 0L),
            "ring_at_ms" to s.getLong("ring_at_ms", 0L),
            "log" to readLog(ctx).map { it / 60000L },
            "told_log" to readTold(ctx).map { it / 60000L },
            "away_until_ms" to s.getLong("away_until_ms", 0L),
        )
    }

    private fun readTold(ctx: Context): List<Long> = try {
        (p(ctx).getString("told_log", "") ?: "").split(",").mapNotNull { it.toLongOrNull() }
    } catch (_: Throwable) {
        emptyList()
    }

    /** "I am going out" for [minutes] (phone left at home): a sign of life
     *  now, and no "Are you OK?" until then + 30 min. Any later sign of
     *  life (record) ends the pause. */
    fun goingOut(ctx: Context, minutes: Int): Boolean {
        return try {
            val now = System.currentTimeMillis()
            val ms = (minutes.toLong() * 60000L).coerceIn(0L, AWAY_MAX_MS)
            record(ctx, now, true)
            p(ctx).edit().putLong("away_until_ms", now + ms).putLong("away_set_ms", now).apply()
            schedule(ctx)
            true
        } catch (_: Throwable) {
            false
        }
    }

    /** "I am OK" from anywhere: a sign of life + stop the ringing. */
    fun ok(ctx: Context): Boolean {
        return try {
            val told = p(ctx).getBoolean("told", false) || p(ctx).getBoolean("ok_pending", false)
            p(ctx).edit().putInt("stage", 0).putBoolean("told", false).putBoolean("ok_pending", told).apply()
            cancelNotif(ctx)
            cancelAlarm(ctx, ACTION_ESCALATE)
            record(ctx, System.currentTimeMillis(), false)
            if (told) postAsync(ctx, "family/silent-watch/ok", JSONObject()) { ok ->
                if (ok) p(ctx).edit().putBoolean("ok_pending", false).apply()
            }
            true
        } catch (_: Throwable) {
            false
        }
    }

    // ------------------------------------------------------------ signs of life
    private fun readLog(ctx: Context): List<Long> = try {
        (p(ctx).getString("log", "") ?: "").split(",").mapNotNull { it.toLongOrNull() }
    } catch (_: Throwable) {
        emptyList()
    }

    /** One sign of life at [t]. While ringing only an explicit action
     *  ([explicit] = the app was used / I am OK) counts — the ring itself
     *  turns the screen on. */
    fun record(ctx: Context, t: Long, explicit: Boolean) {
        try {
            val s = p(ctx)
            if (!s.getBoolean("enabled", false)) return    // nothing is logged unless opted in
            if (s.getInt("stage", 0) > 0 && !explicit) return
            val wasTold = s.getInt("stage", 0) > 0 && explicit && s.getBoolean("told", false)
            val now = System.currentTimeMillis()
            val log = readLog(ctx).filter { it > now - LOG_KEEP_MS }.toMutableList()
            if (log.isEmpty() || t - log.last() >= 60000L) log.add(t)
            val keep = if (log.size > LOG_MAX) log.subList(log.size - LOG_MAX, log.size) else log
            val e = s.edit().putString("log", keep.joinToString(","))
            if (t > s.getLong("last_ms", 0L)) e.putLong("last_ms", t)
            // back home (or took the phone along): the going-out pause ends
            if (t > s.getLong("away_set_ms", 0L) + 60000L) e.putLong("away_until_ms", 0L)
            if (s.getInt("stage", 0) > 0 && explicit) {
                e.putInt("stage", 0)
                if (s.getBoolean("told", false)) e.putBoolean("ok_pending", true).putBoolean("told", false)
            }
            e.apply()
            if (s.getInt("stage", 0) == 0) cancelNotif(ctx)
            schedule(ctx)
            if (wasTold) postAsync(ctx, "family/silent-watch/ok", JSONObject()) { ok ->
                if (ok) p(ctx).edit().putBoolean("ok_pending", false).apply()
            }
        } catch (_: Throwable) {
        }
    }

    private fun inUseNow(ctx: Context): Boolean = try {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        val km = ctx.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        pm.isInteractive && !km.isKeyguardLocked
    } catch (_: Throwable) {
        false
    }

    private fun pluggedNow(ctx: Context): Int = try {
        val i = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        if ((i?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0) 1 else 0
    } catch (_: Throwable) {
        -1
    }

    private fun dartActivity(ctx: Context): Long = try {
        val fp = ctx.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        when (val v = fp.all[DART_KEY]) {
            is Long -> v
            is Int -> v.toLong()
            is String -> v.toLongOrNull() ?: 0L
            else -> 0L
        }
    } catch (_: Throwable) {
        0L
    }

    /** Look for signs of life right now; true if one was found. */
    fun observe(ctx: Context): Boolean {
        val s = p(ctx)
        val now = System.currentTimeMillis()
        var found = false
        val d = dartActivity(ctx)
        if (d > s.getLong("last_ms", 0L) && d <= now + 60000L) {
            val ringStart = s.getLong("ring_at_ms", 0L)
            val explicit = s.getInt("stage", 0) == 0 || d > ringStart
            record(ctx, d, explicit)
            found = true
        }
        val plug = pluggedNow(ctx)
        val was = s.getInt("plugged", -1)
        // The charger changed some time since the previous check: stamp it at
        // that previous check (the EARLIEST it can have happened), so a
        // charger plugged in at night never looks like a morning sign of life.
        val prevProbe = s.getLong("probe_ms", 0L)
        s.edit().putLong("probe_ms", now).apply()
        if (plug >= 0) {
            s.edit().putInt("plugged", plug).apply()
            if (was >= 0 && plug != was) {
                record(ctx, if (prevProbe in 1 until now) prevProbe else now, false); found = true
            }
        }
        if (s.getInt("stage", 0) == 0 && inUseNow(ctx)) {
            record(ctx, now, false); found = true
        }
        return found
    }

    // ------------------------------------------------------------ motion
    @Volatile private var motionListener: TriggerEventListener? = null

    /** (Re)arm the one-shot significant-motion trigger. Lazy, guarded. */
    fun armMotion(ctx: Context) {
        try {
            if (!p(ctx).getBoolean("enabled", false)) return
            val sm = ctx.applicationContext.getSystemService(Context.SENSOR_SERVICE) as? SensorManager ?: return
            val sensor = sm.getDefaultSensor(Sensor.TYPE_SIGNIFICANT_MOTION) ?: return
            motionListener?.let { try { sm.cancelTriggerSensor(it, sensor) } catch (_: Throwable) {} }
            val app = ctx.applicationContext
            val l = object : TriggerEventListener() {
                override fun onTrigger(event: TriggerEvent?) {
                    try {
                        motionListener = null
                        record(app, System.currentTimeMillis(), false)
                        armMotion(app) // one-shot: ask for the next one
                    } catch (_: Throwable) {
                    }
                }
            }
            if (sm.requestTriggerSensor(l, sensor)) motionListener = l
        } catch (_: Throwable) {
        }
    }

    // ------------------------------------------------------------ timing
    private fun table(ctx: Context): IntArray? = try {
        val t = (p(ctx).getString("table", "") ?: "").split(",").mapNotNull { it.toIntOrNull() }
        if (t.size == 48) t.toIntArray() else null
    } catch (_: Throwable) {
        null
    }

    private fun minuteOfDay(ms: Long): Int {
        val c = Calendar.getInstance()
        c.timeInMillis = ms
        return c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE)
    }

    private fun dayStartMs(ms: Long, addDays: Int, minute: Int): Long {
        val c = Calendar.getInstance()
        c.timeInMillis = ms
        c.set(Calendar.HOUR_OF_DAY, 0); c.set(Calendar.MINUTE, 0)
        c.set(Calendar.SECOND, 0); c.set(Calendar.MILLISECOND, 0)
        c.add(Calendar.DAY_OF_MONTH, addDays)
        c.add(Calendar.MINUTE, minute)
        return c.timeInMillis
    }

    /** Mirror of SilentWatchBrain.ringAt. */
    fun ringAt(last: Long, table: IntArray, dayStart: Int, dayEnd: Int): Long {
        val t = last + table[minuteOfDay(last) / 30] * 60000L
        val m = minuteOfDay(t)
        if (m in dayStart until dayEnd) return t
        return dayStartMs(t, if (m >= dayEnd) 1 else 0, dayStart + 30)
    }

    /** Mirror of SilentWatchBrain.ringAtAway ([ring] = ringAt(last)). */
    fun ringAtAway(ring: Long, awayUntil: Long, dayStart: Int, dayEnd: Int): Long {
        val a = awayUntil + AWAY_GRACE_MS
        if (a <= ring) return ring
        val m = minuteOfDay(a)
        if (m in dayStart until dayEnd) return a
        return dayStartMs(a, if (m >= dayEnd) 1 else 0, dayStart + 30)
    }

    private fun nextProbe(now: Long, dayStart: Int, dayEnd: Int): Long {
        val next = now + PROBE_MS
        val m = minuteOfDay(next)
        if (m in dayStart until dayEnd) return next
        return dayStartMs(next, if (m >= dayEnd) 1 else 0, dayStart)
    }

    /** (Re)arm the next probe and, when not ringing, the first ring. */
    fun schedule(ctx: Context) {
        try {
            val s = p(ctx)
            if (!s.getBoolean("enabled", false)) return
            val tb = table(ctx) ?: return
            val ds = s.getInt("day_start", 420)
            val de = s.getInt("day_end", 1320)
            val now = System.currentTimeMillis()
            setAlarm(ctx, ACTION_PROBE, nextProbe(now, ds, de), false, 0)
            if (motionListener == null) armMotion(ctx)
            if (s.getInt("stage", 0) == 0) {
                var at = ringAt(s.getLong("last_ms", now), tb, ds, de)
                val away = s.getLong("away_until_ms", 0L)
                if (away > 0L) at = ringAtAway(at, away, ds, de)
                if (at < now + 60000L) at = now + 60000L
                s.edit().putLong("ring_at_ms", at).apply()
                setAlarm(ctx, ACTION_RING, at, true, 1)
            }
        } catch (_: Throwable) {
        }
    }

    private fun pi(ctx: Context, action: String, n: Int): PendingIntent {
        val i = Intent(ctx, SilentWatchReceiver::class.java).setAction(action).putExtra("n", n)
        val code = when (action) { ACTION_PROBE -> 7311; ACTION_RING -> 7312; ACTION_ESCALATE -> 7313; else -> 7314 }
        return PendingIntent.getBroadcast(ctx, code, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun setAlarm(ctx: Context, action: String, at: Long, exact: Boolean, n: Int) {
        try {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val canExact = Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()
            if (exact && canExact) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi(ctx, action, n))
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi(ctx, action, n))
            }
        } catch (_: Throwable) {
        }
    }

    private fun cancelAlarm(ctx: Context, action: String) {
        try {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.cancel(pi(ctx, action, 0))
        } catch (_: Throwable) {
        }
    }

    // ------------------------------------------------------------ alarms
    fun onProbe(ctx: Context) {
        val s = p(ctx)
        if (!s.getBoolean("enabled", false)) return
        observe(ctx)
        if (s.getBoolean("ok_pending", false)) {
            postAsync(ctx, "family/silent-watch/ok", JSONObject()) { ok ->
                if (ok) p(ctx).edit().putBoolean("ok_pending", false).apply()
            }
        }
        schedule(ctx)
    }

    fun onRing(ctx: Context, n: Int) {
        val s = p(ctx)
        if (!s.getBoolean("enabled", false)) return
        if (s.getInt("stage", 0) == 0) {
            if (observe(ctx)) return               // alive: record() re-armed
            val due = s.getLong("ring_at_ms", 0L)
            if (due > System.currentTimeMillis() + 60000L) { schedule(ctx); return }
        } else {
            val d = dartActivity(ctx)
            if (d > s.getLong("ring_at_ms", 0L)) { record(ctx, d, true); return }
        }
        s.edit().putInt("stage", n).apply()
        showRing(ctx, n)
        val next = System.currentTimeMillis() + RING_GAP_MS
        if (n < RINGS) setAlarm(ctx, ACTION_RING, next, true, n + 1)
        else setAlarm(ctx, ACTION_ESCALATE, next, true, 0)
    }

    fun onEscalate(ctx: Context, attempt: Int) {
        val s = p(ctx)
        if (!s.getBoolean("enabled", false) || s.getInt("stage", 0) == 0) return
        val d = dartActivity(ctx)
        if (d > s.getLong("ring_at_ms", 0L)) { record(ctx, d, true); return }
        val silentMin = (System.currentTimeMillis() - s.getLong("last_ms", 0L)) / 60000L
        val body = JSONObject().put("kind", "inactivity").put("silent_min", silentMin)
        postAsync(ctx, "family/silent-watch/alert", body) { ok ->
            if (ok) {
                val now = System.currentTimeMillis()
                val told = (readTold(ctx).filter { it > now - TOLD_KEEP_MS } + now).takeLast(50)
                p(ctx).edit().putBoolean("told", true).putString("told_log", told.joinToString(",")).apply()
                showTold(ctx)
            } else if (attempt < 12) {
                setAlarm(ctx, ACTION_ESCALATE, System.currentTimeMillis() + RETRY_MS, true, attempt + 1)
            }
        }
    }

    // ------------------------------------------------------------ network
    private fun postAsync(ctx: Context, path: String, body: JSONObject, done: (Boolean) -> Unit) {
        val app = ctx.applicationContext ?: ctx
        if (android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
            var ok = false
            try { ok = post(app, path, body) } catch (_: Throwable) {}
            try { done(ok) } catch (_: Throwable) {}
            return
        }
        val t = Thread(Runnable {
            var ok = false
            try {
                ok = post(app, path, body)
            } catch (_: Throwable) {
            }
            try { done(ok) } catch (_: Throwable) {}
        }, "assisto-sw")
        t.isDaemon = true
        t.start()
    }

    private fun post(ctx: Context, path: String, body: JSONObject): Boolean {
        val s = p(ctx)
        val token = s.getString("token", "") ?: ""
        var base = s.getString("api_base", "") ?: ""
        if (base.isEmpty()) {
            base = ctx.getSharedPreferences("assisto_native_calls", Context.MODE_PRIVATE)
                .getString("api_base", "") ?: ""
        }
        if (token.isEmpty() || base.isEmpty()) return false
        val url = (if (base.endsWith("/")) base else "$base/") + path
        val bytes = body.put("token", token).toString().toByteArray(Charsets.UTF_8)
        var c: HttpURLConnection? = null
        return try {
            c = URL(url).openConnection() as HttpURLConnection
            c.requestMethod = "POST"
            c.connectTimeout = 8000
            c.readTimeout = 8000
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            c.outputStream.use { it.write(bytes) }
            c.responseCode in 200..299
        } catch (_: Throwable) {
            false
        } finally {
            try { c?.disconnect() } catch (_: Throwable) {}
        }
    }

    // ------------------------------------------------------------ notification
    private fun ensureChannel(ctx: Context) {
        try {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val ch = NotificationChannel(CHANNEL_ID,
                p(ctx).getString("channel_name", "Are you OK?") ?: "Are you OK?",
                NotificationManager.IMPORTANCE_HIGH)
            ch.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            ch.enableVibration(true)
            ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            nm.createNotificationChannel(ch)
        } catch (_: Throwable) {
        }
    }

    private fun smallIcon(ctx: Context): Int {
        val id = try { ctx.resources.getIdentifier("ic_stat_assisto", "drawable", ctx.packageName) } catch (_: Throwable) { 0 }
        return if (id != 0) id else ctx.applicationInfo.icon
    }

    private fun openApp(ctx: Context): PendingIntent? = try {
        val i = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
        i?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (i == null) null else PendingIntent.getActivity(ctx, 7315, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    } catch (_: Throwable) {
        null
    }

    private fun build(ctx: Context, body: String, insistent: Boolean): Notification? {
        return try {
            ensureChannel(ctx)
            val s = p(ctx)
            val okPi = PendingIntent.getBroadcast(ctx, 7316,
                Intent(ctx, SilentWatchReceiver::class.java).setAction(ACTION_OK),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CHANNEL_ID)
                    else @Suppress("DEPRECATION") Notification.Builder(ctx)
            val open = openApp(ctx)
            b.setSmallIcon(smallIcon(ctx))
                .setContentTitle(s.getString("title", "Are you OK?"))
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setCategory(Notification.CATEGORY_ALARM)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setAutoCancel(false)
                .addAction(Notification.Action.Builder(0, s.getString("ok_label", "I am OK"), okPi).build())
            if (open != null) {
                b.setContentIntent(open)
                if (insistent) b.setFullScreenIntent(open, true)
            }
            val n = b.build()
            if (insistent) n.flags = n.flags or Notification.FLAG_INSISTENT
            n
        } catch (_: Throwable) {
            null
        }
    }

    private fun showRing(ctx: Context, n: Int) {
        try {
            val s = p(ctx)
            val note = build(ctx, s.getString("body", "Tap I am OK.") ?: "", true) ?: return
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIF_ID, note)
        } catch (_: Throwable) {
        }
    }

    private fun showTold(ctx: Context) {
        try {
            val s = p(ctx)
            val note = build(ctx, s.getString("told_body", "Your family was told. Tap I am OK.") ?: "", false) ?: return
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIF_ID, note)
        } catch (_: Throwable) {
        }
    }

    private fun cancelNotif(ctx: Context) {
        try {
            (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTIF_ID)
        } catch (_: Throwable) {
        }
    }
}

/** The explicit receiver for Silent Watch alarms, the I AM OK button and
 *  re-arming after a reboot / app update. Work is tiny (prefs + one alarm);
 *  the single network call runs on its own short thread. */
class SilentWatchReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        val ctx = context?.applicationContext ?: return
        val action = intent?.action ?: return
        val n = try { intent.getIntExtra("n", 0) } catch (_: Throwable) { 0 }
        val pending = try { goAsync() } catch (_: Throwable) { null }
        val t = Thread(Runnable {
            try {
                when (action) {
                    SilentWatch.ACTION_PROBE -> SilentWatch.onProbe(ctx)
                    SilentWatch.ACTION_RING -> SilentWatch.onRing(ctx, n.coerceIn(1, 3))
                    SilentWatch.ACTION_ESCALATE -> SilentWatch.onEscalate(ctx, n)
                    SilentWatch.ACTION_OK -> SilentWatch.ok(ctx)
                    Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED,
                    "android.intent.action.QUICKBOOT_POWERON" -> SilentWatch.schedule(ctx)
                }
            } catch (_: Throwable) {
            } finally {
                try { pending?.finish() } catch (_: Throwable) {}
            }
        }, "assisto-sw-rx")
        t.isDaemon = true
        t.start()
    }
}
