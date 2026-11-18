package com.assisto.assisto.shopbox

import android.app.Activity
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.view.WindowManager
import java.io.ByteArrayOutputStream
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Shop Box mode helpers (CCTV Part 4, a2-cctv). Registered from
 * MainActivity.configureFlutterEngine (see .phaseB/proposals/a2-cctv.md).
 *
 * Channel "com.assisto/shopbox":
 *   keepScreenOn({on: Bool}) -> Bool   FLAG_KEEP_SCREEN_ON on the activity window
 *                                       (only while Shop Box mode is running)
 *   isCharging()              -> Bool?  from the sticky ACTION_BATTERY_CHANGED
 *                                       broadcast (no permission, no receiver kept)
 *   battery()                 -> {level, charging, temp_c}? (cctvphone: the
 *                                       phone camera's health; same sticky
 *                                       broadcast, temperature in tenths of °C)
 *   dim({on: Bool})           -> Bool   cctvphone: window brightness to the
 *                                       minimum while the phone is a camera
 *                                       (restored to the system value on off)
 *   clipFrames({path, count, width, quality, fromMs?, toMs?}) -> List<ByteArray>
 *                                       cctvplay: small JPEG frames evenly
 *                                       spread over a clip THIS app recorded
 *                                       (MediaMetadataRetriever, framework API,
 *                                       no permission) on a background thread;
 *                                       [] on any failure
 *   freeBytes()               -> Long?  cctvplay: free space of the app's own
 *                                       storage (StatFs) for the recording guard
 *   guardbox-play (PhoneCamService, camera foreground service — only after
 *   the user pressed Start; see that file):
 *   camSvcStart({title, body, stop}) -> Bool, camSvcStop() -> Bool,
 *   camSvcPing() -> Bool, camSvcState() -> {running, listed, foreground, ...},
 *   bgCamOpen() -> Bool, bgCamClose() -> Bool,
 *   bgFrame() -> {y, w, h, stride, rot, ts, n}?, bgJpeg({quality}) -> ByteArray?
 *   Dart is told "camSvcStopTapped" when the notification's Stop was tapped.
 *
 * Nothing runs at launch: registering a MethodChannel handler is free; the
 * work only happens when Dart calls a method. Every call is try/catch so a
 * vendor quirk returns false/null instead of crashing the app.
 */
object ShopBoxChannel {
    private const val NAME = "com.assisto/shopbox"

    fun register(engine: FlutterEngine, activity: Activity) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, NAME)
        // guardbox-play: Stop in the camera notification -> the open screen
        // ends its run too (same honest state everywhere)
        PhoneCamService.onStopTapped = {
            try { ch.invokeMethod("camSvcStopTapped", null) } catch (_: Throwable) {}
        }
        ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    // ---- guardbox-play ---- camera foreground service (PhoneCamService)
                    "camSvcStart" -> {
                        val ok = try {
                            PhoneCamService.start(activity.applicationContext,
                                call.argument<String>("title") ?: "",
                                call.argument<String>("body") ?: "",
                                call.argument<String>("stop") ?: "")
                        } catch (_: Throwable) { false }
                        result.success(ok)
                    }
                    "camSvcStop" -> result.success(
                        try { PhoneCamService.stop(activity.applicationContext) } catch (_: Throwable) { false })
                    "camSvcPing" -> { PhoneCamService.ping(); result.success(PhoneCamService.running) }
                    "camSvcState" -> result.success(
                        try { PhoneCamService.isRunning(activity.applicationContext) } catch (_: Throwable) { null })
                    "bgCamOpen" -> {
                        val main = Handler(Looper.getMainLooper())
                        try {
                            Thread {
                                val ok = try { PhoneCamService.bgOpen() } catch (_: Throwable) { false }
                                main.post { try { result.success(ok) } catch (_: Throwable) {} }
                            }.apply { name = "assisto-pc-open"; isDaemon = true }.start()
                        } catch (_: Throwable) { result.success(false) }
                    }
                    "bgCamClose" -> result.success(PhoneCamService.bgClose())
                    "bgFrame" -> result.success(
                        try { PhoneCamService.frame() } catch (_: Throwable) { null })
                    "bgJpeg" -> {
                        val q = (call.argument<Int>("quality") ?: 80).coerceIn(40, 95)
                        val main = Handler(Looper.getMainLooper())
                        try {
                            Thread {
                                val b = try { PhoneCamService.jpeg(q) } catch (_: Throwable) { null }
                                main.post { try { result.success(b) } catch (_: Throwable) {} }
                            }.apply { name = "assisto-pc-jpeg"; isDaemon = true }.start()
                        } catch (_: Throwable) { result.success(null) }
                    }
                    // ---- /guardbox-play ----
                    "keepScreenOn" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        try {
                            activity.runOnUiThread {
                                try {
                                    if (on) {
                                        activity.window.addFlags(
                                            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                                    } else {
                                        activity.window.clearFlags(
                                            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                                    }
                                } catch (_: Throwable) {
                                }
                            }
                            result.success(true)
                        } catch (_: Throwable) {
                            result.success(false)
                        }
                    }
                    "isCharging" -> {
                        try {
                            val i: Intent? = activity.applicationContext.registerReceiver(
                                null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                            val status = i?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                            if (status == -1) {
                                result.success(null)
                            } else {
                                result.success(
                                    status == BatteryManager.BATTERY_STATUS_CHARGING ||
                                        status == BatteryManager.BATTERY_STATUS_FULL)
                            }
                        } catch (_: Throwable) {
                            result.success(null)
                        }
                    }
                    "battery" -> {
                        try {
                            val i: Intent? = activity.applicationContext.registerReceiver(
                                null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                            if (i == null) {
                                result.success(null)
                            } else {
                                val lvl = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                                val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                                val st = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                                val plug = i.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1)
                                val temp = i.getIntExtra(BatteryManager.EXTRA_TEMPERATURE,
                                    Int.MIN_VALUE)
                                val out = HashMap<String, Any?>()
                                out["level"] = if (lvl >= 0 && scale > 0) lvl * 100 / scale else null
                                out["charging"] = if (st == -1 && plug == -1) null else
                                    (plug > 0 || st == BatteryManager.BATTERY_STATUS_CHARGING ||
                                        st == BatteryManager.BATTERY_STATUS_FULL)
                                out["temp_c"] = if (temp == Int.MIN_VALUE) null else temp / 10.0
                                result.success(out)
                            }
                        } catch (_: Throwable) {
                            result.success(null)
                        }
                    }
                    "dim" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        try {
                            activity.runOnUiThread {
                                try {
                                    val lp = activity.window.attributes
                                    lp.screenBrightness = if (on) 0.01f else
                                        WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                                    activity.window.attributes = lp
                                } catch (_: Throwable) {
                                }
                            }
                            result.success(true)
                        } catch (_: Throwable) {
                            result.success(false)
                        }
                    }
                    "clipFrames" -> {
                        val path = call.argument<String>("path") ?: ""
                        val count = (call.argument<Int>("count") ?: 15).coerceIn(1, 40)
                        val width = (call.argument<Int>("width") ?: 320).coerceIn(96, 960)
                        val quality = (call.argument<Int>("quality") ?: 55).coerceIn(30, 90)
                        val fromMs = (call.argument<Number>("fromMs")?.toLong() ?: 0L).coerceAtLeast(0L)
                        val toMs = call.argument<Number>("toMs")?.toLong() ?: -1L
                        val main = Handler(Looper.getMainLooper())
                        try {
                            Thread {
                                val out = try {
                                    clipFrames(path, count, width, quality, fromMs, toMs)
                                } catch (_: Throwable) {
                                    ArrayList<ByteArray>()
                                }
                                main.post {
                                    try {
                                        result.success(out)
                                    } catch (_: Throwable) {
                                    }
                                }
                            }.apply { name = "assisto-clipframes"; isDaemon = true }.start()
                        } catch (_: Throwable) {
                            result.success(ArrayList<ByteArray>())
                        }
                    }
                    "freeBytes" -> {
                        try {
                            val st = StatFs(activity.applicationContext.filesDir.absolutePath)
                            result.success(st.availableBlocksLong * st.blockSizeLong)
                        } catch (_: Throwable) {
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** cctvplay: [count] JPEG frames spread evenly over the clip, each scaled
     *  to [width] px wide. One bitmap in memory at a time (old 2 GB phones). */
    private fun clipFrames(path: String, count: Int, width: Int, quality: Int,
                           fromMs: Long = 0L, toMs: Long = -1L): ArrayList<ByteArray> {
        val out = ArrayList<ByteArray>()
        if (path.isEmpty()) return out
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(path)
            val durMs = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            if (durMs <= 0L) return out
            val a = fromMs.coerceAtMost(durMs)
            val b = if (toMs in 1..durMs) toMs else durMs
            val span = (b - a).coerceAtLeast(1L)
            for (i in 0 until count) {
                val tUs = (a * 1000L) + (span * 1000L * (2 * i + 1)) / (2L * count)
                var bmp: Bitmap? = null
                var scaled: Bitmap? = null
                try {
                    bmp = r.getFrameAtTime(tUs, MediaMetadataRetriever.OPTION_CLOSEST)
                    if (bmp == null) continue
                    val h = (bmp.height.toLong() * width / bmp.width.coerceAtLeast(1)).toInt()
                        .coerceAtLeast(1)
                    scaled = if (bmp.width > width) Bitmap.createScaledBitmap(bmp, width, h, true)
                        else bmp
                    val bos = ByteArrayOutputStream()
                    scaled.compress(Bitmap.CompressFormat.JPEG, quality, bos)
                    out.add(bos.toByteArray())
                } catch (_: Throwable) {
                } finally {
                    try {
                        if (scaled != null && scaled !== bmp) scaled.recycle()
                        bmp?.recycle()
                    } catch (_: Throwable) {
                    }
                }
            }
        } catch (_: Throwable) {
        } finally {
            try {
                r.release()
            } catch (_: Throwable) {
            }
        }
        return out
    }
}
