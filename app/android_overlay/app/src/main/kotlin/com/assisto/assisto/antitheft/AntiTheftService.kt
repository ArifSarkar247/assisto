package com.assisto.assisto.antitheft

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
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.net.ConnectivityManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import kotlin.math.sqrt

/**
 * b6-antitheft — the opt-in, always-on Lost/Stolen foreground service.
 *
 * NOTHING here runs at app launch, on boot, or via any ContentProvider. It is
 * started ONLY from Dart (AntiTheftChannel.start) after the user turned
 * protection on and the server returned a scoped engine token. It stops when
 * the user turns protection off. A permanent notification is shown the whole
 * time it runs (Android requires it for a foreground service, and it is the
 * honest thing to do).
 *
 * Responsibilities (all crash-guarded — a failure never takes the app down):
 *   * battery-aware heartbeat loop (HeartbeatPolicy) with the last location;
 *   * a conservative accelerometer snatch detector (sudden grab + run);
 *   * runtime receivers for airplane mode, connectivity, battery, SIM/phone
 *     state (on Android 8+ most implicit broadcasts reach only runtime-
 *     registered receivers, so we register them HERE while running);
 *   * a store-and-forward queue (AntiTheftQueue, SQLite) with dedupe; events
 *     captured offline are delivered with their ORIGINAL timestamps when
 *     connectivity returns.
 *
 * Honest limits: no app can block airplane mode or power-off. We detect them
 * and send the last location + time; brand locks (Samsung/Google) are the real
 * power-off defence and the app guides the user to enable them.
 */
class AntiTheftService : Service(), SensorEventListener {

    companion object {
        private const val CHANNEL_ID = "assisto_protection"
        private const val NOTIF_ID = 8440
        const val ACTION_START = "com.assisto.assisto.antitheft.START"
        const val ACTION_STOP = "com.assisto.assisto.antitheft.STOP"
        const val ACTION_FLUSH = "com.assisto.assisto.antitheft.FLUSH"
        const val ACTION_SNATCH = "com.assisto.assisto.antitheft.SNATCH" // internal

        @Volatile var running = false
            private set

        private const val PREFS = "assisto_antitheft_engine"

        fun start(ctx: Context, token: String, apiBase: String,
                  config: JSONObject, title: String, body: String): Boolean {
            return try {
                ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .putString("token", token)
                    .putString("api", apiBase)
                    .putString("config", config.toString())
                    .putString("title", title)
                    .putString("body", body)
                    .apply()
                val i = Intent(ctx, AntiTheftService::class.java).setAction(ACTION_START)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(i)
                } else {
                    ctx.startService(i)
                }
                true
            } catch (_: Throwable) {
                false
            }
        }

        fun stop(ctx: Context) {
            try {
                ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
                ctx.stopService(Intent(ctx, AntiTheftService::class.java))
            } catch (_: Throwable) {
            }
            running = false
        }

        fun flush(ctx: Context) {
            try {
                val i = Intent(ctx, AntiTheftService::class.java).setAction(ACTION_FLUSH)
                ctx.startService(i)
            } catch (_: Throwable) {
            }
        }
    }

    private lateinit var worker: HandlerThread
    private lateinit var bg: Handler
    private val main = Handler(Looper.getMainLooper())
    private var queue: AntiTheftQueue? = null

    private var token = ""
    private var apiBase = ""
    private var notifTitle = "Assisto protection is on"
    private var notifBody = ""
    private var snatchLock = false
    private var intruderPhoto = true

    private var sensorMgr: SensorManager? = null
    private val snatch = SnatchDetector()
    private var lastSimReceiver: BroadcastReceiver? = null
    private var sysReceiver: BroadcastReceiver? = null

    private val heartbeatTick = object : Runnable {
        override fun run() {
            try { doHeartbeat() } catch (_: Throwable) {}
            val interval = currentIntervalMin()
            bg.postDelayed(this, interval * 60_000L)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            if (intent?.action == ACTION_STOP) {
                stopSelf()
                return START_NOT_STICKY
            }
            ensureForeground()
            loadPrefs()
            if (token.isBlank()) {
                stopSelf()
                return START_NOT_STICKY
            }
            if (!running) {
                startWorker()
                registerReceivers()
                startSnatch()
                running = true
            }
            // Any start/flush intent kicks an immediate check-in + queue drain.
            bg.post { try { doHeartbeat() } catch (_: Throwable) {} }
            if (intent?.action == ACTION_SNATCH) {
                bg.post { onSnatchDetected() }
            }
        } catch (_: Throwable) {
            stopSelf()
        }
        // START_STICKY so the OS tries to bring protection back if it was
        // killed WHILE enabled (the token is in prefs). If the user turned it
        // off, prefs are cleared and onStartCommand stops immediately.
        return START_STICKY
    }

    private fun startWorker() {
        worker = HandlerThread("assisto-antitheft").apply { start() }
        bg = Handler(worker.looper)
        queue = AntiTheftQueue(this)
        bg.post(heartbeatTick)
    }

    // ---- foreground notification ------------------------------------------

    private fun ensureForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID, "Lost/Stolen protection",
                NotificationManager.IMPORTANCE_LOW
            ).apply { setShowBadge(false) }
            nm.createNotificationChannel(ch)
        }
        val tap = packageManager.getLaunchIntentForPackage(packageName)
        val pi = if (tap != null) PendingIntent.getActivity(
            this, 0, tap,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_IMMUTABLE else 0
        ) else null
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL_ID) else
            @Suppress("DEPRECATION") Notification.Builder(this)
        val n = builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(notifTitle)
            .setContentText(notifBody)
            .setOngoing(true)
            .also { if (pi != null) it.setContentIntent(pi) }
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            } else {
                startForeground(NOTIF_ID, n)
            }
        } catch (_: Throwable) {
            try { startForeground(NOTIF_ID, n) } catch (_: Throwable) {}
        }
    }

    private fun loadPrefs() {
        val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        token = p.getString("token", "") ?: ""
        apiBase = p.getString("api", "") ?: ""
        notifTitle = p.getString("title", notifTitle) ?: notifTitle
        notifBody = p.getString("body", notifBody) ?: notifBody
        try {
            val cfg = JSONObject(p.getString("config", "{}") ?: "{}")
            snatchLock = cfg.optBoolean("snatch_lock", false)
            intruderPhoto = cfg.optBoolean("intruder_photo", true)
        } catch (_: Throwable) {
        }
    }

    // ---- heartbeat + uploader ---------------------------------------------

    private fun batteryPct(): Int? = try {
        val bm = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)?.takeIf { it in 0..100 }
    } catch (_: Throwable) { null }

    private fun charging(): Boolean = try {
        val i = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val s = i?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        s == BatteryManager.BATTERY_STATUS_CHARGING || s == BatteryManager.BATTERY_STATUS_FULL
    } catch (_: Throwable) { false }

    private fun lostMode(): Boolean =
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("lost_mode", false)

    private fun currentIntervalMin(): Int =
        HeartbeatPolicy.intervalMin(batteryPct(), charging(), lostMode())

    private fun networkKind(): String = try {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        @Suppress("DEPRECATION")
        val ni = cm?.activeNetworkInfo
        when {
            ni == null || !ni.isConnected -> "none"
            ni.type == ConnectivityManager.TYPE_WIFI -> "wifi"
            else -> "mobile"
        }
    } catch (_: Throwable) { "none" }

    private fun doHeartbeat() {
        val item = JSONObject()
            .put("id", "hb-" + System.currentTimeMillis())
            .put("kind", "heartbeat")
            .put("at", System.currentTimeMillis())
            .put("battery", batteryPct() ?: JSONObject.NULL)
            .put("network", networkKind())
        LastLocation.get(applicationContext)?.let {
            item.put("lat", it.first).put("lng", it.second)
        }
        val items = JSONArray().put(item)
        // append any queued offline events (oldest-first), then upload.
        queue?.batchJson(99)?.let { q ->
            for (i in 0 until q.length()) items.put(q.get(i))
        }
        uploadIngest(items)
    }

    /** Queue an event; try to send immediately, keep it on failure. */
    private fun capture(kind: String, data: JSONObject = JSONObject()) {
        val cid = "$kind-" + UUID.randomUUID().toString().take(12)
        val loc = LastLocation.get(applicationContext)
        queue?.add(cid, kind, System.currentTimeMillis(),
            loc?.first, loc?.second, batteryPct(), data)
        bg.post { try { doHeartbeat() } catch (_: Throwable) {} }
    }

    private fun uploadIngest(items: JSONArray) {
        if (token.isBlank() || apiBase.isBlank() || items.length() == 0) return
        val body = JSONObject()
            .put("sent_at", nowIso())
            .put("items", items)
        val resp = postJson("/security/engine/ingest", body) ?: return
        // 401 engine_revoked -> protection was turned off / token rotated: stop.
        if (resp.optBoolean("stop", false)) {
            stop(applicationContext)
            return
        }
        val done = HashSet<String>()
        fun collect(key: String) {
            val a = resp.optJSONArray(key) ?: return
            for (i in 0 until a.length()) done.add(a.optString(i))
        }
        collect("accepted"); collect("duplicate")
        queue?.ack(done)
        // reflect server's lost_mode back into prefs for the interval policy
        try {
            getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putBoolean("lost_mode", resp.optBoolean("lost_mode", false)).apply()
        } catch (_: Throwable) {}
    }

    private fun nowIso(): String {
        return try {
            val sdf = java.text.SimpleDateFormat(
                "yyyy-MM-dd'T'HH:mm:ss'Z'", java.util.Locale.US)
            sdf.timeZone = java.util.TimeZone.getTimeZone("UTC")
            sdf.format(java.util.Date())
        } catch (_: Throwable) { "" }
    }

    private fun postJson(path: String, body: JSONObject): JSONObject? {
        var conn: HttpURLConnection? = null
        return try {
            val url = URL(apiBase.trimEnd('/') + path)
            conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 10000
                readTimeout = 15000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("X-Assisto-Engine", token)
            }
            conn.outputStream.use { os: OutputStream ->
                os.write(body.toString().toByteArray(Charsets.UTF_8))
            }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
            JSONObject(text)
        } catch (_: Throwable) {
            null
        } finally {
            try { conn?.disconnect() } catch (_: Throwable) {}
        }
    }

    // ---- snatch detector ---------------------------------------------------

    private fun startSnatch() {
        try {
            sensorMgr = getSystemService(Context.SENSOR_SERVICE) as? SensorManager
            val s = sensorMgr?.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
                ?: sensorMgr?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
            if (s != null) {
                sensorMgr?.registerListener(this, s, SensorManager.SENSOR_DELAY_GAME)
            }
        } catch (_: Throwable) {
        }
    }

    override fun onSensorChanged(event: SensorEvent?) {
        try {
            if (event == null) return
            var x = event.values[0]; var y = event.values[1]; var z = event.values[2]
            // For a raw accelerometer, remove ~gravity so magnitude ~0 at rest.
            if (event.sensor.type == Sensor.TYPE_ACCELEROMETER) {
                val m = sqrt((x * x + y * y + z * z).toDouble())
                val mag = Math.abs(m - SensorManager.GRAVITY_EARTH)
                if (snatch.onSample(mag, System.currentTimeMillis(), screenUnlocked())) {
                    onSnatchDetected()
                }
                return
            }
            val mag = sqrt((x * x + y * y + z * z).toDouble())
            if (snatch.onSample(mag, System.currentTimeMillis(), screenUnlocked())) {
                onSnatchDetected()
            }
        } catch (_: Throwable) {
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun screenUnlocked(): Boolean = try {
        val km = getSystemService(Context.KEYGUARD_SERVICE)
                as? android.app.KeyguardManager
        km != null && !km.isKeyguardLocked
    } catch (_: Throwable) { true }

    private fun onSnatchDetected() {
        try {
            val data = JSONObject().put("locked", snatchLock)
            // optional instant lock via the existing device admin (honest: only
            // if admin is active; we never claim a lock we didn't do).
            if (snatchLock) {
                val locked = DeviceAdminLock.lockNow(applicationContext)
                data.put("locked", locked)
            }
            capture("snatch", data)
        } catch (_: Throwable) {
        }
    }

    // ---- runtime receivers (airplane / connectivity / battery / SIM) -------

    private fun registerReceivers() {
        try {
            val f = IntentFilter().apply {
                addAction(Intent.ACTION_AIRPLANE_MODE_CHANGED)
                addAction("android.intent.action.SIM_STATE_CHANGED")
                addAction(Intent.ACTION_BATTERY_LOW)
                @Suppress("DEPRECATION")
                addAction(ConnectivityManager.CONNECTIVITY_ACTION)
            }
            sysReceiver = object : BroadcastReceiver() {
                override fun onReceive(c: Context?, i: Intent?) {
                    try { onSystemEvent(i) } catch (_: Throwable) {}
                }
            }
            registerReceiver(sysReceiver, f)
        } catch (_: Throwable) {
        }
    }

    private var lastSimState = ""

    private fun onSystemEvent(i: Intent?) {
        when (i?.action) {
            Intent.ACTION_AIRPLANE_MODE_CHANGED -> {
                val on = i.getBooleanExtra("state", false)
                if (on) capture("offline", JSONObject().put("reason", "airplane"))
            }
            Intent.ACTION_BATTERY_LOW ->
                capture("low_battery", JSONObject().put("battery", batteryPct() ?: -1))
            "android.intent.action.SIM_STATE_CHANGED" -> {
                val state = i.getStringExtra("ss") ?: ""
                if (state.isNotEmpty() && state != lastSimState &&
                    (state == "ABSENT" || state == "LOADED" || state == "READY")) {
                    lastSimState = state
                    val data = JSONObject()
                        .put("state", if (state == "ABSENT") "removed" else "inserted")
                    SimInfo.carrier(applicationContext)?.let { data.put("carrier", it) }
                    capture("sim_change", data)
                }
            }
            else -> {
                if (networkKind() == "none") {
                    capture("offline", JSONObject().put("reason", "no_network"))
                }
            }
        }
    }

    override fun onDestroy() {
        running = false
        try { sensorMgr?.unregisterListener(this) } catch (_: Throwable) {}
        try { sysReceiver?.let { unregisterReceiver(it) } } catch (_: Throwable) {}
        try { if (this::bg.isInitialized) bg.removeCallbacksAndMessages(null) } catch (_: Throwable) {}
        try { if (this::worker.isInitialized) worker.quitSafely() } catch (_: Throwable) {}
        super.onDestroy()
    }
}
