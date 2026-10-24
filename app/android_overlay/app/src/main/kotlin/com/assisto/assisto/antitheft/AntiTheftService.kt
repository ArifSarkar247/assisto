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
        // Re-read config + re-declare the foreground types. Sent ONLY from the
        // open app (AntiTheftChannel.configure), so adding the CAMERA type is
        // allowed (Android 11+/14 while-in-use rule).
        const val ACTION_RECONFIG = "com.assisto.assisto.antitheft.RECONFIG"

        @Volatile var running = false
            private set

        // The live service (null when not running). Used by the device-admin
        // receiver to ask for an intruder photo without starting anything.
        @Volatile private var instance: AntiTheftService? = null

        private const val PREFS = "assisto_antitheft_engine"

        private fun hasLocationPerm(ctx: Context): Boolean = try {
            ctx.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED ||
                ctx.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        } catch (_: Throwable) { false }

        fun start(ctx: Context, token: String, apiBase: String,
                  config: JSONObject, title: String, body: String,
                  offLabel: String = "Turn off"): Boolean {
            // Android 14+: startForeground() with a location/camera type throws
            // without that permission, and a startForegroundService() that
            // never reaches startForeground() kills the process. So we refuse
            // to start (false -> the UI shows the honest "not running" state)
            // unless at least one declared type is actually allowed.
            if (Build.VERSION.SDK_INT >= 34 && !hasLocationPerm(ctx) &&
                !(config.optBoolean("intruder_photo", false) && IntruderCamera.canAttempt(ctx))) {
                return false
            }
            return try {
                ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .putString("token", token)
                    .putString("api", apiBase)
                    .putString("config", config.toString())
                    .putString("title", title)
                    .putString("body", body)
                    .putString("offLabel", offLabel)
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
                // protection off: queued intruder photos are deleted on the phone
                IntruderVault.wipe(ctx)
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

        /** Owner changed settings in the open app: store + re-declare types. */
        fun configure(ctx: Context, config: JSONObject): Boolean {
            return try {
                val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                if ((p.getString("token", "") ?: "").isBlank()) return false
                p.edit().putString("config", config.toString()).apply()
                ctx.startService(
                    Intent(ctx, AntiTheftService::class.java).setAction(ACTION_RECONFIG))
                true
            } catch (_: Throwable) {
                false
            }
        }

        /**
         * Device-admin onPasswordFailed: the failed_unlock event is already
         * queued by the receiver. If the engine is running, it decides (on its
         * worker thread) whether this attempt reached the owner's threshold
         * and takes ONE intruder photo. Never starts the service, never throws.
         */
        fun onFailedUnlock(ctx: Context, count: Int) {
            try {
                val svc = instance
                if (svc != null && running) {
                    svc.postFailedUnlock(count)
                } else {
                    flush(ctx)
                }
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
    private var offLabel = "Turn off"
    private var snatchLock = false
    private var intruderPhoto = false   // opt-in (server default is off too)
    private var failThreshold = 3
    // Foreground-service types actually granted by startForeground (-1 = not
    // foreground yet). The camera is used only if CAMERA is in here (API 30+).
    private var fgTypes = -1
    private var lastPhotoAt = 0L

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
            loadPrefs()
            // startForeground() only when needed: on the first start, or when
            // the open app (START / RECONFIG) asks to re-declare the types.
            // Never re-declared from a background flush (Android 14 would
            // reject a camera/location type from the background).
            if (fgTypes == -1 || intent?.action == ACTION_START ||
                intent?.action == ACTION_RECONFIG) {
                ensureForeground()
            }
            if (token.isBlank()) {
                stopSelf()
                return START_NOT_STICKY
            }
            if (!running) {
                startWorker()
                registerReceivers()
                startSnatch()
                instance = this
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

    private fun wantedTypes(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0
        var t = 0
        if (hasLocationPerm(this)) t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && intruderPhoto &&
            IntruderCamera.canAttempt(this)) {
            t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        }
        return t
    }

    /// play-fgs: the notification's "Turn off" button. It opens Assisto on the
    /// protection screen, where the owner switches protection off in the app —
    /// not a one-tap stop in the shade, which a thief holding the phone could
    /// use to disable the protection.
    private fun offAction(): Notification.Action? = try {
        val open = packageManager.getLaunchIntentForPackage(packageName)
            ?.putExtra("assisto_open", "antitheft_off")
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (open == null) null else {
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            val p = PendingIntent.getActivity(this, 7, open, flags)
            Notification.Action.Builder(
                null as android.graphics.drawable.Icon?, offLabel, p).build()
        }
    } catch (_: Throwable) { null }

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
            .also { b -> offAction()?.let { b.addAction(it) } }
            .build()
        val want = wantedTypes()
        // Try the full set, then without the camera, then (pre-Android-14
        // only, where types are not permission-checked) the manifest default.
        val attempts = ArrayList<Int>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && want != 0) {
            attempts.add(want)
            val noCam = want and ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA.inv()
            if (noCam != want && noCam != 0) attempts.add(noCam)
        }
        for (t in attempts) {
            try {
                startForeground(NOTIF_ID, n, t)
                fgTypes = t
                return
            } catch (_: Throwable) {
            }
        }
        if (Build.VERSION.SDK_INT < 34) {
            try {
                startForeground(NOTIF_ID, n)
                fgTypes = 0
            } catch (_: Throwable) {
            }
        }
    }

    /** Can the camera be used right now from this service? */
    private fun cameraReady(): Boolean {
        if (fgTypes == -1 || !IntruderCamera.canAttempt(this)) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return (fgTypes and ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA) != 0
        }
        return true // API 26-29: a foreground service counts as foreground
    }

    private fun loadPrefs() {
        val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        token = p.getString("token", "") ?: ""
        apiBase = p.getString("api", "") ?: ""
        notifTitle = p.getString("title", notifTitle) ?: notifTitle
        notifBody = p.getString("body", notifBody) ?: notifBody
        offLabel = p.getString("offLabel", offLabel) ?: offLabel
        try {
            val cfg = JSONObject(p.getString("config", "{}") ?: "{}")
            snatchLock = cfg.optBoolean("snatch_lock", false)
            intruderPhoto = cfg.optBoolean("intruder_photo", false)
            failThreshold = cfg.optInt("failed_unlock_threshold", 3).coerceIn(2, 10)
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
        if (running) uploadPhotos()
    }

    // ---- intruder photo -----------------------------------------------------

    internal fun postFailedUnlock(count: Int) {
        try {
            if (!this::bg.isInitialized) return
            bg.post {
                try { onFailedUnlockBg(count) } catch (_: Throwable) {}
                try { doHeartbeat() } catch (_: Throwable) {}
            }
        } catch (_: Throwable) {
        }
    }

    /** Worker thread. One photo per streak (>= threshold, 60 s apart). */
    private fun onFailedUnlockBg(count: Int) {
        if (!intruderPhoto || count < failThreshold) return
        if (!cameraReady()) return // the photo-less failed_unlock is already queued
        val now = System.currentTimeMillis()
        if (now - lastPhotoAt < 60_000L) return
        lastPhotoAt = now
        val jpeg = IntruderCamera.captureJpeg(applicationContext) ?: return
        val cid = "intr-" + UUID.randomUUID().toString().take(12)
        val path = IntruderVault.seal(applicationContext, cid, jpeg) ?: return
        val loc = LastLocation.get(applicationContext)
        queue?.add(cid, "intruder_photo", now, loc?.first, loc?.second, batteryPct(),
            JSONObject().put("count", count), path)
    }

    /** Upload up to 3 queued (encrypted) photos; keep them on a network error. */
    private fun uploadPhotos() {
        if (token.isBlank() || apiBase.isBlank()) return
        for (n in 0 until 3) {
            val row = queue?.nextPhotoRow() ?: return
            val path = row.photo ?: return
            val bytes = IntruderVault.open(applicationContext, path)
            if (bytes == null) { // unreadable (key lost / corrupt) -> drop it
                queue?.ack(listOf(row.cid))
                continue
            }
            val code = postPhoto(row, bytes)
            when {
                code in 200..299 -> queue?.ack(listOf(row.cid))
                code == 401 -> { stop(applicationContext); return }
                // 400 bad / 403 owner switched it off / 413 too big: permanent
                code == 400 || code == 403 || code == 413 -> queue?.ack(listOf(row.cid))
                else -> return // offline / 429 / 5xx: retry on a later heartbeat
            }
        }
    }

    private fun postPhoto(row: AntiTheftQueue.Row, jpeg: ByteArray): Int {
        var conn: HttpURLConnection? = null
        return try {
            val boundary = "assisto" + UUID.randomUUID().toString().replace("-", "")
            val url = URL(apiBase.trimEnd('/') + "/security/engine/photo")
            conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 10000
                readTimeout = 20000
                doOutput = true
                setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
                setRequestProperty("X-Assisto-Engine", token)
            }
            conn.outputStream.use { os: OutputStream ->
                fun field(name: String, value: String) {
                    os.write(("--$boundary\r\nContent-Disposition: form-data; name=\"$name\"" +
                        "\r\n\r\n$value\r\n").toByteArray(Charsets.UTF_8))
                }
                field("id", row.cid)
                field("at", row.at.toString())
                field("sent_at", nowIso())
                row.lat?.let { field("lat", it.toString()) }
                row.lng?.let { field("lng", it.toString()) }
                row.battery?.let { field("battery", it.toString()) }
                field("data", row.data)
                os.write(("--$boundary\r\nContent-Disposition: form-data; name=\"file\"; " +
                    "filename=\"intruder.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
                    .toByteArray(Charsets.UTF_8))
                os.write(jpeg)
                os.write("\r\n--$boundary--\r\n".toByteArray(Charsets.UTF_8))
            }
            conn.responseCode
        } catch (_: Throwable) {
            -1
        } finally {
            try { conn?.disconnect() } catch (_: Throwable) {}
        }
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
        if (instance === this) instance = null
        try { sensorMgr?.unregisterListener(this) } catch (_: Throwable) {}
        try { sysReceiver?.let { unregisterReceiver(it) } } catch (_: Throwable) {}
        try { if (this::bg.isInitialized) bg.removeCallbacksAndMessages(null) } catch (_: Throwable) {}
        try { if (this::worker.isInitialized) worker.quitSafely() } catch (_: Throwable) {}
        super.onDestroy()
    }
}
