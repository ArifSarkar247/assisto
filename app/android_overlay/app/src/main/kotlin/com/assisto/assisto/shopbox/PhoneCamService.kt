package com.assisto.assisto.shopbox

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.Image
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * guardbox-play — "this phone is a camera" keeps watching with the screen
 * OFF (or Assisto in the background). A foreground service of type CAMERA
 * (Play policy: ongoing, user-visible camera use the user started):
 *
 *  * started ONLY from the open Phone-camera screen after the user pressed
 *    Start and Android granted the camera (ShopBoxChannel "camSvcStart");
 *    never at launch, never at boot, no receiver, no WorkManager, not sticky;
 *  * a permanent notification the whole time ("This phone is working as a
 *    camera") with a Stop button that ends it at once;
 *  * while the app is VISIBLE the camera belongs to the screen (Flutter
 *    camera plugin). When the app goes to the background the screen hands
 *    the camera to THIS service ("bgCamOpen"): Camera2 + one small
 *    ImageReader (about 640x480 YUV), no recording, no sound; Dart pulls the
 *    newest frame ("bgFrame", ~3 per second) for the same motion check and
 *    an alert photo ("bgJpeg") only on motion;
 *  * a watchdog: if the app's Dart side stops pinging (process kept but the
 *    screen engine gone) or the task is swiped away, the service stops by
 *    itself — never a camera running that nothing is reading.
 * Every call is try/catch: a vendor camera quirk returns false/null.
 */
class PhoneCamService : Service() {

    companion object {
        private const val CHANNEL_ID = "assisto_phonecam"
        private const val NOTIF_ID = 47310
        const val ACTION_START = "com.assisto.phonecam.START"
        const val ACTION_STOP = "com.assisto.phonecam.STOP"
        const val ACTION_STOP_TAP = "com.assisto.phonecam.STOP_TAP"
        private const val PING_TIMEOUT_MS = 120_000L
        private const val FRAME_EVERY_MS = 300L

        @Volatile var running = false
        @Volatile private var inst: PhoneCamService? = null
        @Volatile private var lastPingMs = 0L
        /** start() asked and no stop() since (a Stop racing the start wins). */
        @Volatile private var wanted = false

        /** Called on the main thread when the user tapped Stop in the notification. */
        @Volatile var onStopTapped: (() -> Unit)? = null

        fun hasCameraPerm(ctx: Context): Boolean = try {
            ctx.checkSelfPermission(android.Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        } catch (_: Throwable) { false }

        /** From the OPEN app only (the user pressed Start). false = not started. */
        fun start(ctx: Context, title: String, body: String, stop: String): Boolean {
            if (!hasCameraPerm(ctx)) return false
            return try {
                ctx.getSharedPreferences("phonecam_svc", Context.MODE_PRIVATE).edit()
                    .putString("title", title).putString("body", body).putString("stop", stop)
                    .apply()
                lastPingMs = SystemClock.elapsedRealtime()
                wanted = true
                val i = Intent(ctx, PhoneCamService::class.java).setAction(ACTION_START)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i)
                else ctx.startService(i)
                // the service reaches startForeground() on the main looper;
                // the caller re-checks [isRunning] for the honest state
                true
            } catch (_: Throwable) { false }
        }

        /** Same process: stop the running instance directly (no startService
         *  from the background). A start still on its way is stopped too. */
        fun stop(ctx: Context): Boolean = try {
            wanted = false
            val s = inst
            if (s != null) {
                s.stopNow()
            } else if (running) {
                ctx.startService(Intent(ctx, PhoneCamService::class.java).setAction(ACTION_STOP))
            }
            running = false
            true
        } catch (_: Throwable) { false }

        fun ping() { lastPingMs = SystemClock.elapsedRealtime() }

        /** Our own service as Android lists it (running + foreground). */
        fun isRunning(ctx: Context): Map<String, Any?> {
            val m = HashMap<String, Any?>()
            m["flag"] = running
            m["camera_open"] = inst?.device != null
            try {
                val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                @Suppress("DEPRECATION")
                val rs = am.getRunningServices(200).firstOrNull {
                    it.service.className == PhoneCamService::class.java.name
                }
                m["listed"] = rs != null
                m["foreground"] = rs?.foreground == true
            } catch (_: Throwable) {
                m["listed"] = null
            }
            m["running"] = running && (m["listed"] != false)
            return m
        }

        /** Hand the camera to the service (the app went to the background). */
        fun bgOpen(timeoutMs: Long = 6000): Boolean {
            val s = inst ?: return false
            return try { s.openCamera(timeoutMs) } catch (_: Throwable) { false }
        }

        fun bgClose(): Boolean = try { inst?.closeCamera(); true } catch (_: Throwable) { false }

        /** The newest frame: luma plane (stride = w) + size + sensor rotation. */
        fun frame(): Map<String, Any?>? {
            val s = inst ?: return null
            ping()
            val f = s.latest ?: return null
            val m = HashMap<String, Any?>()
            m["y"] = f.nv21.copyOfRange(0, f.w * f.h)
            m["w"] = f.w
            m["h"] = f.h
            m["stride"] = f.w
            m["rot"] = s.sensorRot
            m["ts"] = f.ts
            m["n"] = s.frames
            return m
        }

        /** The newest frame as an upright JPEG (the alert photo). */
        fun jpeg(quality: Int = 80): ByteArray? {
            val s = inst ?: return null
            val f = s.latest ?: return null
            return try {
                val bos = ByteArrayOutputStream()
                YuvImage(f.nv21, ImageFormat.NV21, f.w, f.h, null)
                    .compressToJpeg(Rect(0, 0, f.w, f.h), quality, bos)
                val raw = bos.toByteArray()
                if (s.sensorRot % 360 == 0) raw else rotate(raw, s.sensorRot, quality) ?: raw
            } catch (_: Throwable) { null }
        }

        private fun rotate(jpeg: ByteArray, deg: Int, quality: Int): ByteArray? {
            var b: Bitmap? = null
            var r: Bitmap? = null
            return try {
                b = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return null
                r = Bitmap.createBitmap(b, 0, 0, b.width, b.height,
                    Matrix().apply { postRotate(deg.toFloat()) }, true)
                val bos = ByteArrayOutputStream()
                r.compress(Bitmap.CompressFormat.JPEG, quality, bos)
                bos.toByteArray()
            } catch (_: Throwable) { null } finally {
                try { if (r != null && r !== b) r.recycle() } catch (_: Throwable) {}
                try { b?.recycle() } catch (_: Throwable) {}
            }
        }

        /** YUV_420_888 -> NV21 (any row / pixel stride). */
        fun toNv21(img: Image): ByteArray {
            val w = img.width
            val h = img.height
            val out = ByteArray(w * h * 3 / 2)
            val y = img.planes[0]
            val yb = y.buffer
            val ys = y.rowStride
            var o = 0
            for (r in 0 until h) {
                yb.position(r * ys)
                yb.get(out, o, w)
                o += w
            }
            val u = img.planes[1]
            val v = img.planes[2]
            val ub = u.buffer
            val vb = v.buffer
            val rs = v.rowStride
            val ps = v.pixelStride
            for (r in 0 until h / 2) {
                for (c in 0 until w / 2) {
                    val i = r * rs + c * ps
                    out[o++] = vb.get(i)
                    out[o++] = ub.get(r * u.rowStride + c * u.pixelStride)
                }
            }
            return out
        }
    }

    private class Frame(val nv21: ByteArray, val w: Int, val h: Int, val ts: Long)

    private var worker: HandlerThread? = null
    private var bg: Handler? = null
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    @Volatile private var latest: Frame? = null
    @Volatile private var sensorRot = 0
    @Volatile private var frames = 0L
    private var lastKeptMs = 0L

    private val watchdog = object : Runnable {
        override fun run() {
            if (!running) return
            if (SystemClock.elapsedRealtime() - lastPingMs > PING_TIMEOUT_MS) {
                stopNow()
                return
            }
            main.postDelayed(this, 30_000L)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            when (intent?.action) {
                ACTION_STOP -> { stopNow(); return START_NOT_STICKY }
                ACTION_STOP_TAP -> {
                    wanted = false
                    stopNow()
                    try { onStopTapped?.invoke() } catch (_: Throwable) {}
                    return START_NOT_STICKY
                }
            }
            // startForegroundService() MUST reach startForeground() first
            if (!wanted || !hasCameraPerm(this) || intent?.action != ACTION_START) {
                try { foreground() } catch (_: Throwable) {}
                stopNow()
                return START_NOT_STICKY
            }
            foreground()
            inst = this
            running = true
            main.removeCallbacks(watchdog)
            main.postDelayed(watchdog, 30_000L)
        } catch (_: Throwable) {
            stopNow()
        }
        return START_NOT_STICKY // a killed camera never comes back by itself
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // the user swiped Assisto away: the screen that reads frames is gone
        wanted = false
        stopNow()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        try { closeCamera() } catch (_: Throwable) {}
        running = false
        if (inst === this) inst = null
        main.removeCallbacks(watchdog)
        try { worker?.quitSafely() } catch (_: Throwable) {}
        super.onDestroy()
    }

    private fun stopNow() {
        try { closeCamera() } catch (_: Throwable) {}
        running = false
        if (inst === this) inst = null
        main.removeCallbacks(watchdog)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
            else @Suppress("DEPRECATION") stopForeground(true)
        } catch (_: Throwable) {}
        try { stopSelf() } catch (_: Throwable) {}
    }

    private fun foreground() {
        val p = getSharedPreferences("phonecam_svc", Context.MODE_PRIVATE)
        val title = p.getString("title", null) ?: "This phone is working as a camera"
        val body = p.getString("body", null) ?: "Assisto is watching for movement. Tap Stop to end."
        val stop = p.getString("stop", null) ?: "Stop"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(
                CHANNEL_ID, title, NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        }
        val imm = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val tap = packageManager.getLaunchIntentForPackage(packageName)
        val open = if (tap != null) PendingIntent.getActivity(this, 0, tap, imm) else null
        val stopPi = PendingIntent.getService(this, 1,
            Intent(this, PhoneCamService::class.java).setAction(ACTION_STOP_TAP), imm)
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        @Suppress("DEPRECATION")
        val n = b.setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(0, stop, stopPi).build())
            .also { if (open != null) it.setContentIntent(open) }
            .also { if (Build.VERSION.SDK_INT >= 31) it.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE) }
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    private fun handler(): Handler {
        bg?.let { return it }
        val t = HandlerThread("assisto-phonecam").apply { start() }
        worker = t
        return Handler(t.looper).also { bg = it }
    }

    @SuppressLint("MissingPermission") // checked: hasCameraPerm
    private fun openCamera(timeoutMs: Long): Boolean {
        if (!running || !hasCameraPerm(this)) return false
        if (device != null && session != null) return true
        closeCamera()
        val cm = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val ids = cm.cameraIdList
        if (ids.isEmpty()) return false
        val id = ids.firstOrNull {
            cm.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_BACK
        } ?: ids[0]
        val ch = cm.getCameraCharacteristics(id)
        sensorRot = ch.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        val sizes = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?.getOutputSizes(ImageFormat.YUV_420_888)?.toList().orEmpty()
        // the smallest size at least 640 wide (old phones: small + cheap)
        val size = sizes.filter { it.width >= 640 && it.width <= 1280 }
            .minByOrNull { it.width * it.height }
            ?: sizes.minByOrNull { kotlin.math.abs(it.width - 640) } ?: return false
        val h = handler()
        val r = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
        r.setOnImageAvailableListener({ rd ->
            var img: Image? = null
            try {
                img = rd.acquireLatestImage() ?: return@setOnImageAvailableListener
                val now = SystemClock.elapsedRealtime()
                if (now - lastKeptMs >= FRAME_EVERY_MS) {
                    lastKeptMs = now
                    latest = Frame(toNv21(img), img.width, img.height, System.currentTimeMillis())
                    frames++
                }
            } catch (_: Throwable) {
            } finally {
                try { img?.close() } catch (_: Throwable) {}
            }
        }, h)
        reader = r
        val ok = booleanArrayOf(false)
        val done = CountDownLatch(1)
        cm.openCamera(id, object : CameraDevice.StateCallback() {
            override fun onOpened(d: CameraDevice) {
                device = d
                try {
                    @Suppress("DEPRECATION")
                    d.createCaptureSession(listOf(r.surface), object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(s: CameraCaptureSession) {
                            try {
                                session = s
                                val req = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                                    addTarget(r.surface)
                                    set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                                }
                                s.setRepeatingRequest(req.build(), null, h)
                                ok[0] = true
                            } catch (_: Throwable) {}
                            done.countDown()
                        }
                        override fun onConfigureFailed(s: CameraCaptureSession) { done.countDown() }
                    }, h)
                } catch (_: Throwable) { done.countDown() }
            }
            override fun onDisconnected(d: CameraDevice) {
                try { d.close() } catch (_: Throwable) {}
                if (device === d) device = null
                done.countDown()
            }
            override fun onError(d: CameraDevice, error: Int) {
                try { d.close() } catch (_: Throwable) {}
                if (device === d) device = null
                done.countDown()
            }
        }, h)
        done.await(timeoutMs, TimeUnit.MILLISECONDS)
        if (!ok[0]) closeCamera()
        return ok[0]
    }

    private fun closeCamera() {
        try { session?.close() } catch (_: Throwable) {}
        session = null
        try { device?.close() } catch (_: Throwable) {}
        device = null
        try { reader?.close() } catch (_: Throwable) {}
        reader = null
        latest = null
    }
}
