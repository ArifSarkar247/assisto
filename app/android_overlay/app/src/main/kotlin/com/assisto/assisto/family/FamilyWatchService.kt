package com.assisto.assisto.family

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import com.assisto.assisto.antitheft.LastLocation
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * fcbrain — Family Care v3 BRAIN 2 + 3: the opt-in "family arrival watch".
 *
 * Started ONLY from the open app (FamilyWatchChannel.start) after the member
 * switched "tell my family when I arrive" on, on their OWN phone, and the
 * server handed back a SCOPED token (it can only post this member's pings).
 * Never at launch, no WorkManager, no ContentProvider, no
 * background-location permission: a foreground service of type "location"
 * started from the open app keeps the while-in-use permission. A permanent,
 * low-importance notification says it is on the whole time (no hidden
 * tracking). Re-started on every app open while on (START_STICKY too).
 *
 * How it saves battery (zero Google cost — framework LocationManager only):
 *  * FenceRule decides when the next fix is needed: far from every place it
 *    sleeps until we could reach the nearest fence at 60 km/h (max 15 min),
 *    a cheap NETWORK fix; within 600 m of a fence a precise GPS fix every
 *    60 s; inside a place every 5 min (15 min when still);
 *  * PASSIVE fixes other apps already took are used for free.
 * What it sends: only "arrived / left <place>" events (no coordinates), a
 * heartbeat every 30 min (battery, charging, network, background limits so
 * the family card can say WHY it is gray), and at 15 % battery the last
 * location ONCE (re-armed by charging). Events are queued and sent when the
 * network is back. Every failure is swallowed — it can never crash the app.
 */
class FamilyWatchService : Service() {

    companion object {
        const val PREFS = "fc_watch"
        private const val CHANNEL_ID = "assisto_family_watch"
        private const val NOTIF_ID = 47331
        private const val ACTION_START = "com.assisto.family.WATCH_START"
        private const val ACTION_STOP = "com.assisto.family.WATCH_STOP"
        private const val HEARTBEAT_MS = 30L * 60 * 1000
        private const val MAX_QUEUE = 50
        private const val PRECISE_TIMEOUT_MS = 20_000L

        @Volatile var running = false

        private fun hasLocationPerm(ctx: Context): Boolean = try {
            ctx.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED ||
                ctx.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        } catch (_: Throwable) { false }

        /** From the OPEN app only. false = not started (honest UI state). */
        fun start(ctx: Context, token: String, api: String, fences: String,
                  title: String, body: String): Boolean {
            if (!hasLocationPerm(ctx)) return false
            return try {
                val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val ed = p.edit()
                    .putString("token", token).putString("api", api)
                    .putString("title", title).putString("body", body)
                if (p.getString("fences", "") != fences) {
                    // new places: learn where we are again, never a false "arrived"
                    ed.putString("fences", fences).remove("state")
                }
                ed.apply()
                val i = Intent(ctx, FamilyWatchService::class.java).setAction(ACTION_START)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i)
                else ctx.startService(i)
                true
            } catch (_: Throwable) { false }
        }

        fun stop(ctx: Context) {
            try {
                ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .remove("token").remove("state").remove("queue").apply()
                ctx.startService(Intent(ctx, FamilyWatchService::class.java).setAction(ACTION_STOP))
            } catch (_: Throwable) {}
        }

        fun isOn(ctx: Context): Boolean = try {
            !ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("token", "").isNullOrBlank()
        } catch (_: Throwable) { false }

        /** Device facts for the family card (no permission needed). */
        fun device(ctx: Context): Map<String, Any?> {
            val m = HashMap<String, Any?>()
            try {
                val b = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                val lvl = b?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                val sc = b?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                if (lvl >= 0 && sc > 0) m["battery"] = (lvl * 100 / sc)
                val st = b?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                m["charging"] = st == BatteryManager.BATTERY_STATUS_CHARGING ||
                    st == BatteryManager.BATTERY_STATUS_FULL
            } catch (_: Throwable) {}
            m["net"] = netType(ctx)
            m["bg_restricted"] = bgRestricted(ctx)
            try {
                val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
                if (pm != null && Build.VERSION.SDK_INT >= 23) {
                    m["battery_optimised"] = !pm.isIgnoringBatteryOptimizations(ctx.packageName)
                }
            } catch (_: Throwable) {}
            return m
        }

        fun netType(ctx: Context): String = try {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            val caps = if (Build.VERSION.SDK_INT >= 23) cm?.getNetworkCapabilities(cm.activeNetwork) else null
            when {
                caps == null -> "none"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cell"
                else -> "wifi"
            }
        } catch (_: Throwable) { "" }

        fun bgRestricted(ctx: Context): Boolean = try {
            Build.VERSION.SDK_INT >= 28 &&
                (ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).isBackgroundRestricted
        } catch (_: Throwable) { false }

        /** Today's own counters (the on-phone battery report). */
        fun counters(ctx: Context): Map<String, Any?> {
            val m = HashMap<String, Any?>()
            try {
                val raw = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("counters", "")
                if (!raw.isNullOrBlank()) {
                    val o = JSONObject(raw)
                    for (k in o.keys()) m[k] = o.opt(k)
                }
            } catch (_: Throwable) {}
            m["running"] = running
            return m
        }
    }

    private lateinit var worker: HandlerThread
    private lateinit var bg: Handler
    private var lm: LocationManager? = null
    private var fences: List<FenceRule.Fence> = emptyList()
    private var state = FenceRule.State()
    private var token = ""
    private var api = ""
    private var curProvider = ""
    private var curDelayS = -1L
    private var lastPingMs = 0L
    private var lastBattery: Int? = null
    private var lastCharging = false
    private var lowArmed = true
    private var battReceiver: BroadcastReceiver? = null

    private val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            bg.post { onFix(location, if (location.provider == LocationManager.GPS_PROVIDER) "gps" else "net") }
        }
        @Suppress("OVERRIDE_DEPRECATION")
        override fun onStatusChanged(p: String?, s: Int, e: Bundle?) {}
        override fun onProviderEnabled(p: String) {}
        override fun onProviderDisabled(p: String) {}
    }
    private val passive = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            bg.post { onFix(location, "passive") }
        }
        @Suppress("OVERRIDE_DEPRECATION")
        override fun onStatusChanged(p: String?, s: Int, e: Bundle?) {}
        override fun onProviderEnabled(p: String) {}
        override fun onProviderDisabled(p: String) {}
    }
    private val heartbeat = object : Runnable {
        override fun run() {
            try {
                if (System.currentTimeMillis() - lastPingMs >= HEARTBEAT_MS - 60_000) ping()
            } catch (_: Throwable) {}
            bg.postDelayed(this, HEARTBEAT_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            if (intent?.action == ACTION_STOP) {
                stopSelf()
                return START_NOT_STICKY
            }
            loadPrefs()
            // startForegroundService() MUST reach startForeground() before
            // any stopSelf(), or Android kills the process — so declare
            // first, then decide (a sticky restart has no intent).
            val fg = hasLocationPerm(this) && try { ensureForeground(); true } catch (_: Throwable) { false }
            // not allowed from here (e.g. a background sticky restart on
            // Android 14 without while-in-use): stop; the next app open
            // starts it again (FamilyWatchChannel.resume).
            if (token.isBlank() || !fg) {
                stopSelf()
                return START_NOT_STICKY
            }
            if (!running) {
                worker = HandlerThread("assisto-family-watch").apply { start() }
                bg = Handler(worker.looper)
                lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                registerBattery()
                running = true
                bg.post {
                    try {
                        LastLocation.best(this)?.let {
                            onFixRaw(it.lat, it.lng, (it.acc ?: 999f).toDouble(), it.timeMs, "cached")
                        }
                    } catch (_: Throwable) {}
                    reschedule(force = true)
                    try { ping() } catch (_: Throwable) {}
                }
                bg.postDelayed(heartbeat, HEARTBEAT_MS)
            } else {
                bg.post { reschedule(force = true); try { ping() } catch (_: Throwable) {} }
            }
        } catch (_: Throwable) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        try { lm?.removeUpdates(listener) } catch (_: Throwable) {}
        try { lm?.removeUpdates(passive) } catch (_: Throwable) {}
        try { battReceiver?.let { unregisterReceiver(it) } } catch (_: Throwable) {}
        try { bg.removeCallbacksAndMessages(null) } catch (_: Throwable) {}
        try { worker.quitSafely() } catch (_: Throwable) {}
        super.onDestroy()
    }

    private fun loadPrefs() {
        val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        token = p.getString("token", "") ?: ""
        api = p.getString("api", "") ?: ""
        fences = FenceRule.parseFences(p.getString("fences", ""))
        state = FenceRule.State.fromJson(p.getString("state", ""))
        lowArmed = p.getBoolean("lowArmed", true)
    }

    private fun saveState() {
        try {
            getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("state", state.toJson().toString())
                .putBoolean("lowArmed", lowArmed).apply()
        } catch (_: Throwable) {}
    }

    private fun ensureForeground() {
        val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(
                CHANNEL_ID, p.getString("title", "Family arrival news") ?: "Family arrival news",
                NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        }
        val tap = packageManager.getLaunchIntentForPackage(packageName)
        val pi = if (tap != null) PendingIntent.getActivity(this, 0, tap,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        else null
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = b.setSmallIcon(applicationInfo.icon)
            .setContentTitle(p.getString("title", "Family arrival news is on"))
            .setContentText(p.getString("body", "Your family is told when you reach a saved place."))
            .setOngoing(true)
            .also { if (pi != null) it.setContentIntent(pi) }
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    private fun registerBattery() {
        try {
            val r = object : BroadcastReceiver() {
                override fun onReceive(c: Context?, i: Intent?) {
                    try {
                        val lvl = i?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                        val sc = i?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                        if (lvl < 0 || sc <= 0) return
                        val pct = lvl * 100 / sc
                        val st = i?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                        val chg = st == BatteryManager.BATTERY_STATUS_CHARGING ||
                            st == BatteryManager.BATTERY_STATUS_FULL
                        if (pct == lastBattery && chg == lastCharging) return
                        lastBattery = pct
                        lastCharging = chg
                        bg.post { onBattery(pct, chg) }
                    } catch (_: Throwable) {}
                }
            }
            registerReceiver(r, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            battReceiver = r
        } catch (_: Throwable) {}
    }

    /** 15 %: share the last location ONCE per discharge (FcLowBattery twin). */
    private fun onBattery(pct: Int, charging: Boolean) {
        if (charging || pct >= 30) {
            if (!lowArmed) { lowArmed = true; saveState() }
            return
        }
        if (pct <= 15 && lowArmed) {
            lowArmed = false
            saveState()
            val f = try { LastLocation.fresh(this, PRECISE_TIMEOUT_MS) } catch (_: Throwable) { null }
            val e = JSONObject().put("id", "fwb-${System.currentTimeMillis()}")
                .put("kind", "battery_low").put("at", iso(System.currentTimeMillis()))
            if (f != null) {
                e.put("lat", f.lat).put("lng", f.lng)
                f.acc?.let { e.put("acc", it.toInt()) }
            }
            enqueue(e)
            ping()
        }
    }

    private fun onFix(l: Location, src: String) {
        onFixRaw(l.latitude, l.longitude, if (l.hasAccuracy()) l.accuracy.toDouble() else 999.0,
            if (l.time > 0) l.time else System.currentTimeMillis(), src)
        reschedule(force = false)
    }

    private fun onFixRaw(lat: Double, lng: Double, acc: Double, atMs: Long, src: String) {
        if (lat.isNaN() || lng.isNaN()) return
        count(src)
        val evs = FenceRule.step(fences, state, lat, lng, acc, atMs)
        saveState()
        if (evs.isEmpty()) {
            if (System.currentTimeMillis() - lastPingMs >= HEARTBEAT_MS) ping()
            return
        }
        val now = System.currentTimeMillis()
        for (ev in evs) {
            enqueue(JSONObject()
                .put("id", "fw-$atMs-${ev.fence.id}-${ev.kind}")
                .put("kind", ev.kind).put("at", iso(now))
                // the fix that proved it = the best estimate of the crossing
                .put("crossed_at", iso(atMs))
                .put("place_id", ev.fence.id).put("place_kind", ev.fence.kind)
                .put("place_label", ev.fence.label))
        }
        ping()
    }

    /** (Re)register location updates for what FenceRule wants next. */
    private fun reschedule(force: Boolean) {
        val m = lm ?: return
        try {
            val lat = state.prevLat
            val lng = state.prevLng
            val delayS = if (lat.isNaN()) FenceRule.MIN_DELAY_S
                else FenceRule.nextDelayS(fences, state, lat, lng)
            val precise = !lat.isNaN() && FenceRule.wantPrecise(fences, state, lat, lng)
            val enabled = try { m.getProviders(true) } catch (_: Throwable) { emptyList<String>() }
            val prov = when {
                precise && enabled.contains(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
                enabled.contains(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
                enabled.contains(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
                else -> ""
            }
            if (!force && prov == curProvider && delayS == curDelayS) return
            try { m.removeUpdates(listener) } catch (_: Throwable) {}
            curProvider = prov
            curDelayS = delayS
            if (prov.isNotEmpty()) {
                @Suppress("MissingPermission")
                m.requestLocationUpdates(prov, delayS * 1000, 0f, listener, worker.looper)
            }
            if (force) {
                try { m.removeUpdates(passive) } catch (_: Throwable) {}
                if (enabled.contains(LocationManager.PASSIVE_PROVIDER)) {
                    @Suppress("MissingPermission")
                    m.requestLocationUpdates(LocationManager.PASSIVE_PROVIDER, 30_000L, 0f,
                        passive, worker.looper)
                }
            }
        } catch (_: Throwable) {}
    }

    private fun enqueue(e: JSONObject) {
        try {
            val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val q = try { JSONArray(p.getString("queue", "[]")) } catch (_: Throwable) { JSONArray() }
            q.put(e)
            val out = JSONArray()
            val start = if (q.length() > MAX_QUEUE) q.length() - MAX_QUEUE else 0
            for (i in start until q.length()) out.put(q.get(i))
            p.edit().putString("queue", out.toString()).apply()
        } catch (_: Throwable) {}
    }

    /** POST the queue + device facts. Worker thread only. */
    private fun ping() {
        if (token.isBlank() || api.isBlank()) return
        val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val q = try { JSONArray(p.getString("queue", "[]")) } catch (_: Throwable) { JSONArray() }
        val dev = device(this)
        val tz = TimeZone.getDefault()
        val body = JSONObject()
            .put("events", q).put("watch_on", true).put("interval_s", 3600)
            .put("tz", tz.id).put("tz_offset_min", tz.getOffset(System.currentTimeMillis()) / 60000)
        for ((k, v) in dev) if (v != null && k != "battery_optimised") body.put(k, v)
        var conn: HttpURLConnection? = null
        try {
            conn = (URL(api.trimEnd('/') + "/family/brain/watch-ping").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 15_000
                readTimeout = 15_000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("X-Fc-Watch", token)
            }
            conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            if (code in 200..299) {
                lastPingMs = System.currentTimeMillis()
                count("pings")
                val sent = HashSet<String>()
                for (i in 0 until q.length()) sent.add(q.optJSONObject(i)?.optString("id") ?: "")
                val now = try { JSONArray(p.getString("queue", "[]")) } catch (_: Throwable) { JSONArray() }
                val keep = JSONArray()
                for (i in 0 until now.length()) {
                    val o = now.optJSONObject(i) ?: continue
                    if (!sent.contains(o.optString("id"))) keep.put(o)
                }
                val ed = p.edit().putString("queue", keep.toString())
                try {
                    val resp = conn.inputStream.bufferedReader().use { it.readText() }
                    val f = JSONObject(resp).optJSONArray("fences")
                    if (f != null && f.toString() != p.getString("fences", "")) {
                        ed.putString("fences", f.toString())
                        fences = FenceRule.parseFences(f.toString())
                    }
                } catch (_: Throwable) {}
                ed.apply()
            } else if (code == 401) {
                // switched off on the server (or elsewhere): stop honestly
                p.edit().remove("token").remove("queue").remove("state").apply()
                token = ""
                stopSelf()
            }
        } catch (_: Throwable) {
            // offline: the queue stays; the next fix / heartbeat retries
        } finally {
            try { conn?.disconnect() } catch (_: Throwable) {}
        }
    }

    private fun count(key: String) {
        try {
            val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val day = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
            val o = try { JSONObject(p.getString("counters", "{}")) } catch (_: Throwable) { JSONObject() }
            val c = if (o.optString("day") == day) o else JSONObject().put("day", day)
                .put("since", System.currentTimeMillis())
            c.put(key, c.optInt(key, 0) + 1)
            p.edit().putString("counters", c.toString()).apply()
        } catch (_: Throwable) {}
    }

    private fun iso(ms: Long): String {
        val f = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
        f.timeZone = TimeZone.getTimeZone("UTC")
        return f.format(Date(ms))
    }
}
