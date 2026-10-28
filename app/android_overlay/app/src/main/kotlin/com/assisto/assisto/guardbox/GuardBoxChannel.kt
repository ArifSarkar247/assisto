package com.assisto.assisto.guardbox

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.FloatBuffer
import java.util.concurrent.Executors

/**
 * cashguard — ASSISTO GUARD BOX on-device PERSON detection
 * (channel "com.assisto/guardbox"). Register from
 * MainActivity.configureFlutterEngine (see .phaseB/proposals/cashguard.md).
 *
 * Model: YOLOX-Nano (Megvii, Apache-2.0), the SAME official ONNX file the
 * Shop Box uses (416x416, BGR 0..255, no normalisation), downloaded by Dart
 * on first use and SHA-256-checked BEFORE its path reaches here. Runs on the
 * onnxruntime-android AAR already in the app (Photo Studio).
 *
 *   available()                       -> Bool  (ORT classes present)
 *   detect({model, jpeg, thr})        -> {ok, boxes:[[x1,y1,x2,y2,score]], ms}
 *                                        normalised 0..1, COCO class 0 only
 *   close()                           -> frees the session
 *
 * LAZY + CRASH-GUARDED: nothing is created until the first detect(); every
 * call runs on ONE background thread and answers {ok:false, error} instead of
 * throwing. A Throwable (OOM, missing native lib) never reaches the app.
 */
object GuardBoxChannel {
    private const val NAME = "com.assisto/guardbox"
    private const val SIDE = 416
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var session: ai.onnxruntime.OrtSession? = null
    @Volatile private var sessionKey = ""
    private var grids: FloatArray? = null
    private var strides: FloatArray? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(hasOrt())
                "close" -> {
                    worker.execute {
                        try { session?.close() } catch (_: Throwable) {}
                        session = null
                        sessionKey = ""
                    }
                    result.success(true)
                }
                "detect" -> {
                    val model = call.argument<String>("model") ?: ""
                    val jpeg = call.argument<ByteArray>("jpeg")
                    val thr = (call.argument<Double>("thr") ?: 0.45).toFloat()
                    worker.execute {
                        val out: Map<String, Any?> = try {
                            if (jpeg == null || model.isEmpty()) mapOf("ok" to false, "error" to "args")
                            else detect(model, jpeg, thr)
                        } catch (t: Throwable) {
                            mapOf("ok" to false, "error" to t.javaClass.simpleName)
                        }
                        main.post {
                            try { result.success(out) } catch (_: Throwable) {}
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasOrt(): Boolean = try {
        Class.forName("ai.onnxruntime.OrtEnvironment")
        true
    } catch (_: Throwable) {
        false
    }

    @Synchronized
    private fun sessionFor(model: String): ai.onnxruntime.OrtSession {
        val key = model + "#" + File(model).length()
        session?.let { if (sessionKey == key) return it }
        try { session?.close() } catch (_: Throwable) {}
        val env = ai.onnxruntime.OrtEnvironment.getEnvironment()
        val o = ai.onnxruntime.OrtSession.SessionOptions()
        // an old phone: two threads at most, the UI stays responsive
        o.setIntraOpNumThreads(Runtime.getRuntime().availableProcessors().coerceIn(1, 2))
        val s = env.createSession(model, o)
        session = s
        sessionKey = key
        if (grids == null) makeGrids()
        return s
    }

    private fun makeGrids() {
        val g = ArrayList<Float>()
        val st = ArrayList<Float>()
        for (s in intArrayOf(8, 16, 32)) {
            val n = SIDE / s
            for (y in 0 until n) for (x in 0 until n) {
                g.add(x.toFloat()); g.add(y.toFloat()); st.add(s.toFloat())
            }
        }
        grids = g.toFloatArray()
        strides = st.toFloatArray()
    }

    private fun detect(model: String, jpeg: ByteArray, thr: Float): Map<String, Any?> {
        val t0 = SystemClock.elapsedRealtime()
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return mapOf("ok" to false, "error" to "decode")
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= SIDE && bounds.outHeight / (sample * 2) >= SIDE) sample *= 2
        val src = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size,
            BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return mapOf("ok" to false, "error" to "decode")
        val w = src.width
        val h = src.height
        val r = minOf(SIDE.toFloat() / h, SIDE.toFloat() / w)
        val nw = maxOf(1, Math.round(w * r))
        val nh = maxOf(1, Math.round(h * r))
        val scaled = Bitmap.createScaledBitmap(src, nw, nh, true)
        if (scaled !== src) src.recycle()
        val px = IntArray(nw * nh)
        scaled.getPixels(px, 0, nw, 0, 0, nw, nh)
        scaled.recycle()
        val plane = SIDE * SIDE
        val chw = FloatArray(3 * plane) { 114f }
        for (y in 0 until nh) for (x in 0 until nw) {
            val c = px[y * nw + x]
            val i = y * SIDE + x
            chw[i] = (c and 0xff).toFloat()                     // B
            chw[plane + i] = ((c shr 8) and 0xff).toFloat()     // G
            chw[2 * plane + i] = ((c shr 16) and 0xff).toFloat() // R
        }
        val s = sessionFor(model)
        val env = ai.onnxruntime.OrtEnvironment.getEnvironment()
        val input = s.inputNames.iterator().next()
        val boxes = ArrayList<FloatArray>()
        ai.onnxruntime.OnnxTensor.createTensor(env, FloatBuffer.wrap(chw),
            longArrayOf(1, 3, SIDE.toLong(), SIDE.toLong())).use { x ->
            s.run(mapOf(input to x)).use { res ->
                val t = res.get(0) as ai.onnxruntime.OnnxTensor
                val fb = t.floatBuffer
                val out = FloatArray(fb.remaining())
                fb.get(out)
                val g = grids!!
                val st = strides!!
                val n = out.size / 85
                for (k in 0 until minOf(n, st.size)) {
                    val o = k * 85
                    val score = out[o + 4] * out[o + 5]
                    if (score < thr) continue
                    val cx = (out[o] + g[2 * k]) * st[k]
                    val cy = (out[o + 1] + g[2 * k + 1]) * st[k]
                    val bw = Math.exp(out[o + 2].toDouble()).toFloat() * st[k]
                    val bh = Math.exp(out[o + 3].toDouble()).toFloat() * st[k]
                    boxes.add(floatArrayOf((cx - bw / 2) / r, (cy - bh / 2) / r,
                        (cx + bw / 2) / r, (cy + bh / 2) / r, score))
                }
            }
        }
        val kept = nms(boxes, 0.45f)
        val list = kept.map { b ->
            listOf((b[0] / w).toDouble().coerceIn(0.0, 1.0), (b[1] / h).toDouble().coerceIn(0.0, 1.0),
                (b[2] / w).toDouble().coerceIn(0.0, 1.0), (b[3] / h).toDouble().coerceIn(0.0, 1.0),
                b[4].toDouble())
        }
        return mapOf("ok" to true, "boxes" to list, "ms" to (SystemClock.elapsedRealtime() - t0))
    }

    private fun nms(b: List<FloatArray>, thr: Float): List<FloatArray> {
        val order = b.sortedByDescending { it[4] }.toMutableList()
        val keep = ArrayList<FloatArray>()
        while (order.isNotEmpty() && keep.size < 20) {
            val a = order.removeAt(0)
            keep.add(a)
            order.removeAll { c ->
                val ix = maxOf(0f, minOf(a[2], c[2]) - maxOf(a[0], c[0]))
                val iy = maxOf(0f, minOf(a[3], c[3]) - maxOf(a[1], c[1]))
                val inter = ix * iy
                val ua = (a[2] - a[0]) * (a[3] - a[1]) + (c[2] - c[0]) * (c[3] - c[1]) - inter
                ua > 0 && inter / ua >= thr
            }
        }
        return keep
    }
}
