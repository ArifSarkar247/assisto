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
 *   detect({model, jpeg, thr})        -> {ok, boxes:[[x1,y1,x2,y2,score]], ms, night}
 *     cctvacc: optional thrNight / nightSpread / nightLuma — a grey (IR) or
 *     dark photo uses thrNight; the same rule + values as the Shop Box
 *     (edge/shopbox/shopbox/night.py), measured on the bitmap scaled for
 *     the model. Without them (older Dart) only `thr` is used.
 *     cctvacc2: optional nightPre ("clahe" | "gamma" | "none") / claheClip /
 *     claheTiles / gammaTarget — a night bitmap is enhanced before the model
 *     with the SAME integer / double maths as night.py enhance().
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
                    val night = NightRule(
                        call.argument<Double>("thrNight")?.toFloat(),
                        (call.argument<Double>("nightSpread") ?: 10.0).toFloat(),
                        (call.argument<Double>("nightLuma") ?: 40.0).toFloat(),
                        call.argument<String>("nightPre") ?: "none",
                        call.argument<Double>("claheClip") ?: 2.0,
                        call.argument<Int>("claheTiles") ?: 8,
                        call.argument<Double>("gammaTarget") ?: 0.45)
                    worker.execute {
                        val out: Map<String, Any?> = try {
                            if (jpeg == null || model.isEmpty()) mapOf("ok" to false, "error" to "args")
                            else detect(model, jpeg, thr, night)
                        } catch (t: Throwable) {
                            mapOf("ok" to false, "error" to t.javaClass.simpleName)
                        }
                        main.post {
                            try { result.success(out) } catch (_: Throwable) {}
                        }
                    }
                }
                // cctvbox: the IP-camera decoder (IpCamDecoder.kt) shares this channel
                else -> {
                    val handled = try {
                        IpCamDecoder.handle(call, result)
                    } catch (t: Throwable) {
                        result.success(mapOf("ok" to false, "error" to t.javaClass.simpleName))
                        true
                    }
                    if (!handled) result.notImplemented()
                }
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

    class NightRule(val thrNight: Float?, val spreadMax: Float, val lumaMax: Float,
                    val pre: String = "none", val clip: Double = 2.0, val tiles: Int = 8,
                    val gammaTarget: Double = 0.45)

    /** cctvacc2: night.py enhance() — new luma Y' (CLAHE or gamma), then each
     *  channel c -> min(255, floor(c * (Y'+1) / (Y+1) + 0.5)). In place. */
    private fun enhanceNight(px: IntArray, w: Int, h: Int, rule: NightRule) {
        if (rule.pre != "clahe" && rule.pre != "gamma") return
        if (w < 1 || h < 1 || px.size < w * h) return
        val n = w * h
        val y = IntArray(n)
        for (i in 0 until n) {
            val c = px[i]
            y[i] = (299 * ((c shr 16) and 0xff) + 587 * ((c shr 8) and 0xff) + 114 * (c and 0xff) + 500) / 1000
        }
        val y2 = if (rule.pre == "clahe") clahe(y, w, h, rule.clip, maxOf(1, rule.tiles))
                 else gammaCurve(y, rule.gammaTarget)
        for (i in 0 until n) {
            val c = px[i]
            val k = (y2[i] + 1.0) / (y[i] + 1.0)
            val r = minOf(255, Math.floor(((c shr 16) and 0xff) * k + 0.5).toInt())
            val g = minOf(255, Math.floor(((c shr 8) and 0xff) * k + 0.5).toInt())
            val b = minOf(255, Math.floor((c and 0xff) * k + 0.5).toInt())
            px[i] = (c and -0x1000000) or (r shl 16) or (g shl 8) or b
        }
    }

    private fun clahe(y: IntArray, w: Int, h: Int, clip: Double, t: Int): IntArray {
        val luts = Array(t * t) { IntArray(256) }
        val hist = LongArray(256)
        for (ty in 0 until t) {
            val y0 = ty * h / t
            val y1 = (ty + 1) * h / t
            for (tx in 0 until t) {
                val x0 = tx * w / t
                val x1 = (tx + 1) * w / t
                val area = maxOf(1, (y1 - y0) * (x1 - x0)).toLong()
                java.util.Arrays.fill(hist, 0L)
                for (yy in y0 until y1) for (xx in x0 until x1) hist[y[yy * w + xx]]++
                val limit = maxOf(1L, (clip * area / 256.0).toLong())
                var excess = 0L
                for (v in 0..255) if (hist[v] > limit) { excess += hist[v] - limit; hist[v] = limit }
                val add = excess / 256
                val rem = (excess % 256).toInt()
                val lut = luts[ty * t + tx]
                var cum = 0L
                for (v in 0..255) {
                    cum += hist[v] + add + (if (v < rem) 1 else 0)
                    lut[v] = minOf(255L, cum * 255 / area).toInt()
                }
            }
        }
        fun axis(n: Int): Triple<IntArray, IntArray, DoubleArray> {
            val i0 = IntArray(n); val i1 = IntArray(n); val a = DoubleArray(n)
            for (i in 0 until n) {
                val pos = (i + 0.5) * t / n - 0.5
                val f = Math.floor(pos).toInt().coerceIn(0, t - 1)
                i0[i] = f
                i1[i] = minOf(f + 1, t - 1)
                a[i] = if (pos < 0) 0.0 else (pos - f).coerceIn(0.0, 1.0)
            }
            return Triple(i0, i1, a)
        }
        val (yi0, yi1, ay) = axis(h)
        val (xi0, xi1, ax) = axis(w)
        val out = IntArray(w * h)
        for (yy in 0 until h) {
            val b = ay[yy]
            val r0 = yi0[yy] * t
            val r1 = yi1[yy] * t
            for (xx in 0 until w) {
                val v = y[yy * w + xx]
                val a = ax[xx]
                val top = (1 - a) * luts[r0 + xi0[xx]][v] + a * luts[r0 + xi1[xx]][v]
                val bot = (1 - a) * luts[r1 + xi0[xx]][v] + a * luts[r1 + xi1[xx]][v]
                out[yy * w + xx] = Math.floor((1 - b) * top + b * bot + 0.5).toInt()
            }
        }
        return out
    }

    private fun gammaCurve(y: IntArray, target: Double): IntArray {
        if (y.isEmpty()) return y
        var sum = 0L
        for (v in y) sum += v
        val m = maxOf(1.0, sum.toDouble() / y.size)
        if (m / 255.0 >= target) return y
        val g = maxOf(0.35, minOf(1.0, Math.log(target) / Math.log(m / 255.0)))
        val lut = IntArray(256) { Math.floor(255.0 * Math.pow(it / 255.0, g) + 0.5).toInt() }
        return IntArray(y.size) { lut[y[it]] }
    }

    /** Grey (IR) or dark: mean max-min channel spread / mean luma (night.py). */
    private fun isNight(px: IntArray, rule: NightRule): Boolean {
        if (px.isEmpty()) return false
        var spread = 0.0
        var luma = 0.0
        for (c in px) {
            val b = c and 0xff
            val g = (c shr 8) and 0xff
            val r = (c shr 16) and 0xff
            spread += (maxOf(r, maxOf(g, b)) - minOf(r, minOf(g, b)))
            luma += 0.114 * b + 0.587 * g + 0.299 * r
        }
        spread /= px.size
        luma /= px.size
        return spread < rule.spreadMax || luma < rule.lumaMax
    }

    private fun detect(model: String, jpeg: ByteArray, thrDay: Float, rule: NightRule): Map<String, Any?> {
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
        val night = rule.thrNight != null && isNight(px, rule)
        val thr = if (night) rule.thrNight!! else thrDay
        if (night) enhanceNight(px, nw, nh, rule)
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
        return mapOf("ok" to true, "boxes" to list, "ms" to (SystemClock.elapsedRealtime() - t0),
            "night" to night)
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
