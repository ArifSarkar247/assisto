package com.assisto.assisto.photo

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.FloatBuffer
import java.util.EnumSet
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * p2-photo — Photo Studio native parts. LAZY: registering installs handlers
 * only; ONNX Runtime and ML Kit are created the first time Dart calls them
 * (i.e. only after the user opens Photo Studio). Every call is crash-guarded
 * and answers honestly (ok=false / empty) instead of throwing into Dart.
 *
 * "com.assisto/photo_native"
 *   capabilities()                       -> {upscale: Bool, faces: Bool}
 *   upscale({input, model, out, scale, tile, pad, maxInputLong, targetLong,
 *            faces: [[x,y,w,h] 0..1 …], faceAi: 0.25})
 *        -> {ok, path, w, h, ms, ep, tiles} | {ok:false, error}
 *        progress events to Dart: "upscaleProgress" {done, total}
 *   segment({input, model, side})        -> {ok, mask: ByteArray side*side (0..255,
 *                                            255 = subject), side, ms} | {ok:false, error}
 *        (d1-photo: U2-Net-p background mask for the blur tool, CPU only)
 *   cancel()                              -> null
 *
 * d1-photo: every error answer is a SHORT CODE ("cancelled", "decode",
 * "model_shape", "ort_session: OrtException", "oom", "ort_run: ...") - never a
 * message with a path - so Dart can report it to Owner Admin as-is. The model
 * input shape is checked against the requested tile BEFORE the first tile
 * (the published ONNX has a FIXED 144x144 input; anything else is refused
 * with "model_shape" instead of failing mid-photo).
 *   faces({path})  -> {ok, w, h, faces:[{box:[x,y,w,h] (0..1), points:[x0,y0,…]
 *                     (pixels; LEFT_EYE, RIGHT_EYE, NOSE_BASE, MOUTH_LEFT,
 *                     MOUTH_RIGHT, MOUTH_BOTTOM, LEFT_CHEEK, RIGHT_CHEEK),
 *                     oval:[x0,y0,…] (FACE contour, may be empty)}]}
 *
 * "com.assisto/photo_secure"
 *   enable() / disable() -> Bool  (FLAG_SECURE on this activity's window)
 */
object PhotoNativeChannel {
    private const val NAME = "com.assisto/photo_native"
    private const val SECURE = "com.assisto/photo_secure"
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val cancelled = AtomicBoolean(false)
    private var channel: MethodChannel? = null

    private fun deviceKey(activity: Activity): String = try {
        val id = android.provider.Settings.Secure.getString(
            activity.contentResolver, android.provider.Settings.Secure.ANDROID_ID) ?: ""
        if (id.isEmpty()) "" else {
            val md = java.security.MessageDigest.getInstance("SHA-256")
            md.digest(("assisto:" + id).toByteArray()).joinToString("") { "%02x".format(it) }
        }
    } catch (e: Throwable) {
        ""
    }

    fun register(activity: Activity, messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, NAME)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "capabilities" -> result.success(
                        mapOf("upscale" to hasClass("ai.onnxruntime.OrtEnvironment"),
                              "faces" to hasClass("com.google.mlkit.vision.face.FaceDetection")))
                    "cancel" -> {
                        cancelled.set(true)
                        result.success(null)
                    }
                    // photo-final: stable device key for the server's free
                    // counters — SHA-256 of ANDROID_ID (same after a reinstall
                    // of the same signed app); the raw id never leaves the phone.
                    "deviceKey" -> result.success(deviceKey(activity))
                    "upscale" -> {
                        cancelled.set(false)
                        val args = HashMap<String, Any?>()
                        for (k in listOf("input", "model", "out", "scale", "tile", "pad",
                                         "maxInputLong", "targetLong", "faces", "faceAi")) {
                            args[k] = call.argument<Any>(k)
                        }
                        val ctx = activity.applicationContext
                        worker.execute {
                            val r = try {
                                upscale(ctx, args)
                            } catch (t: OutOfMemoryError) {
                                fail("oom")
                            } catch (t: Throwable) {
                                fail("ort_run: " + t.javaClass.simpleName)
                            }
                            main.post { result.success(r) }
                        }
                    }
                    "segment" -> {
                        cancelled.set(false)
                        val args = HashMap<String, Any?>()
                        for (k in listOf("input", "model", "side")) args[k] = call.argument<Any>(k)
                        worker.execute {
                            val r = try {
                                segment(args)
                            } catch (t: OutOfMemoryError) {
                                fail("oom")
                            } catch (t: Throwable) {
                                fail("seg_run: " + t.javaClass.simpleName)
                            }
                            main.post { result.success(r) }
                        }
                    }
                    "faces" -> {
                        val path = call.argument<String>("path") ?: ""
                        val ctx = activity.applicationContext
                        worker.execute {
                            val r = try {
                                PhotoFaces.detect(ctx, path)
                            } catch (t: Throwable) {
                                mapOf("ok" to false, "error" to (t.message ?: t.javaClass.simpleName))
                            }
                            main.post { result.success(r) }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.success(null)
            }
        }
        // FLAG_SECURE for the free-user Photo Studio previews only (Dart turns
        // it on when the preview opens and off when the user leaves).
        MethodChannel(messenger, SECURE).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "enable" -> activity.runOnUiThread {
                        try {
                            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            result.success(
                                (activity.window.attributes.flags and
                                    WindowManager.LayoutParams.FLAG_SECURE) != 0)
                        } catch (t: Throwable) {
                            result.success(false)
                        }
                    }
                    "disable" -> activity.runOnUiThread {
                        try {
                            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            result.success(true)
                        } catch (t: Throwable) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.success(false)
            }
        }
    }

    private fun hasClass(n: String): Boolean = try {
        Class.forName(n)
        true
    } catch (t: Throwable) {
        false
    }

    private fun progress(done: Int, total: Int) {
        main.post {
            try {
                channel?.invokeMethod("upscaleProgress", mapOf("done" to done, "total" to total))
            } catch (t: Throwable) {
            }
        }
    }

    private fun intArg(a: Map<String, Any?>, k: String, d: Int): Int =
        (a[k] as? Number)?.toInt() ?: d

    /** Decode -> fit to maxInputLong -> tiled Real-ESRGAN -> fit to targetLong -> JPEG. */
    private fun upscale(ctx: Context, a: Map<String, Any?>): Map<String, Any?> {
        val t0 = SystemClock.elapsedRealtime()
        val input = a["input"] as? String ?: return fail("no input")
        val model = a["model"] as? String ?: return fail("no model")
        val outPath = a["out"] as? String ?: return fail("no out")
        val scale = intArg(a, "scale", 4)
        val side = intArg(a, "tile", 144)
        val pad = intArg(a, "pad", 8)
        val tile = side - 2 * pad
        if (tile <= 0) return fail("bad tile")
        val maxInputLong = intArg(a, "maxInputLong", 640).coerceIn(32, 2048)
        val targetLong = intArg(a, "targetLong", 2048).coerceIn(32, 8192)

        // decode with subsampling first (never hold a 50 MP bitmap)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(input, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return fail("decode")
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxInputLong) sample *= 2
        val src = BitmapFactory.decodeFile(input, BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }) ?: return fail("decode")
        val (iw, ih) = UpscaleTiler.inputSize(src.width, src.height, maxInputLong)
        val inBmp = if (iw != src.width || ih != src.height)
            Bitmap.createScaledBitmap(src, iw, ih, true) else src
        val px = IntArray(iw * ih)
        inBmp.getPixels(px, 0, iw, 0, 0, iw, ih)
        if (inBmp !== src) inBmp.recycle()
        src.recycle()
        val faces = ArrayList<DoubleArray>()
        (a["faces"] as? List<*>)?.forEach { f ->
            val v = (f as? List<*>)?.mapNotNull { (it as? Number)?.toDouble() }
            if (v != null && v.size == 4) faces.add(v.toDoubleArray())
        }
        val faceAi = ((a["faceAi"] as? Number)?.toDouble() ?: 0.25).coerceIn(0.0, 1.0)

        val ow = iw * scale
        val oh = ih * scale
        val outPx = IntArray(ow * oh)
        val tiles = UpscaleTiler.plan(iw, ih, tile)
        var runner = try {
            OrtRunner.get(ctx, model, side, false)
        } catch (t: OutOfMemoryError) {
            return fail("oom")
        } catch (t: Throwable) {
            return fail("ort_session: " + t.javaClass.simpleName)
        }
        if (!runner.inputMatches(side)) return fail("model_shape")
        val inBuf = FloatArray(3 * side * side)
        for ((i, t) in tiles.withIndex()) {
            if (cancelled.get()) return fail("cancelled")
            UpscaleTiler.extract(px, iw, ih, t, pad, side, inBuf)
            val o = try {
                runner.run(inBuf)
            } catch (e: Throwable) {
                if (runner.ep == "cpu") throw e
                // NNAPI failed mid-way on this phone: remember, go CPU, redo tile
                OrtRunner.markCpu(ctx, model)
                runner = OrtRunner.get(ctx, model, side, true)
                runner.run(inBuf)
            }
            if (o.size != 3 * side * scale * side * scale) return fail("model_shape")
            UpscaleTiler.place(o, t, pad, side, scale, outPx, ow)
            progress(i + 1, tiles.size)
        }
        // colours from the original + FACE-LOCK (see UpscaleTiler.mergeKeepFaces)
        val small = Bitmap.createBitmap(px, iw, ih, Bitmap.Config.ARGB_8888)
        val baseBmp = Bitmap.createScaledBitmap(small, ow, oh, true)
        small.recycle()
        val basePx = IntArray(ow * oh)
        baseBmp.getPixels(basePx, 0, ow, 0, 0, ow, oh)
        baseBmp.recycle()
        val merged = UpscaleTiler.mergeKeepFaces(outPx, basePx, ow, oh, faces, faceAi)
        var outBmp = Bitmap.createBitmap(merged, ow, oh, Bitmap.Config.ARGB_8888)
        val long = maxOf(ow, oh)
        if (long > targetLong) {
            val f = targetLong.toDouble() / long
            val fw = maxOf(1, Math.round(ow * f).toInt())
            val fh = maxOf(1, Math.round(oh * f).toInt())
            val scaled = Bitmap.createScaledBitmap(outBmp, fw, fh, true)
            outBmp.recycle()
            outBmp = scaled
        }
        val f = File(outPath)
        f.parentFile?.mkdirs()
        FileOutputStream(f).use { outBmp.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        val res = mapOf("ok" to true, "path" to f.absolutePath, "w" to outBmp.width,
            "h" to outBmp.height, "ms" to (SystemClock.elapsedRealtime() - t0),
            "ep" to runner.ep, "tiles" to tiles.size)
        outBmp.recycle()
        return res
    }

    private fun fail(e: String) = mapOf("ok" to false, "error" to e)

    /**
     * d1-photo: U2-Net-p salient-object mask (Apache-2.0 weights, ONNX
     * [1,3,side,side] -> first output [1,1,side,side]). CPU only, one cached
     * session. Pre-processing as in the model's reference code: RGB / 255,
     * ImageNet mean/std; output min-max normalised to 0..255.
     */
    private fun segment(a: Map<String, Any?>): Map<String, Any?> {
        val t0 = SystemClock.elapsedRealtime()
        val input = a["input"] as? String ?: return fail("no input")
        val model = a["model"] as? String ?: return fail("no model")
        val side = intArg(a, "side", 320).coerceIn(64, 1024)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(input, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return fail("decode")
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= side * 2) sample *= 2
        val src = BitmapFactory.decodeFile(input, BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }) ?: return fail("decode")
        val sq = Bitmap.createScaledBitmap(src, side, side, true)
        if (sq !== src) src.recycle()
        val px = IntArray(side * side)
        sq.getPixels(px, 0, side, 0, 0, side, side)
        sq.recycle()
        val plane = side * side
        val chw = FloatArray(3 * plane)
        val mean = floatArrayOf(0.485f, 0.456f, 0.406f)
        val std = floatArrayOf(0.229f, 0.224f, 0.225f)
        for (i in 0 until plane) {
            val c = px[i]
            chw[i] = (((c shr 16) and 0xFF) / 255f - mean[0]) / std[0]
            chw[plane + i] = (((c shr 8) and 0xFF) / 255f - mean[1]) / std[1]
            chw[2 * plane + i] = ((c and 0xFF) / 255f - mean[2]) / std[2]
        }
        if (cancelled.get()) return fail("cancelled")
        val seg = try {
            SegRunner.get(model)
        } catch (t: OutOfMemoryError) {
            return fail("oom")
        } catch (t: Throwable) {
            return fail("ort_session: " + t.javaClass.simpleName)
        }
        if (!seg.inputMatches(side)) return fail("model_shape")
        val out = seg.run(chw, side)
        if (out.size < plane) return fail("model_shape")
        var mi = Float.MAX_VALUE
        var ma = -Float.MAX_VALUE
        for (i in 0 until plane) {
            if (out[i] < mi) mi = out[i]
            if (out[i] > ma) ma = out[i]
        }
        val range = if (ma - mi > 1e-6f) ma - mi else 1f
        val mask = ByteArray(plane)
        for (i in 0 until plane) {
            val v = Math.round((out[i] - mi) / range * 255f).coerceIn(0, 255)
            mask[i] = v.toByte()
        }
        return mapOf("ok" to true, "mask" to mask, "side" to side,
            "ms" to (SystemClock.elapsedRealtime() - t0))
    }
}

/** d1-photo: one CPU session for the background-mask model. */
class SegRunner private constructor(private val session: ai.onnxruntime.OrtSession) {
    private val env = ai.onnxruntime.OrtEnvironment.getEnvironment()
    private val inputName: String = session.inputNames.iterator().next()

    fun inputMatches(side: Int): Boolean = try {
        val info = session.inputInfo[inputName]?.info as? ai.onnxruntime.TensorInfo
        val sh = info?.shape
        sh != null && sh.size == 4 && sh[1] == 3L &&
            (sh[2] == side.toLong() || sh[2] < 0) && (sh[3] == side.toLong() || sh[3] < 0)
    } catch (t: Throwable) {
        false
    }

    fun run(chw: FloatArray, side: Int): FloatArray {
        val shape = longArrayOf(1, 3, side.toLong(), side.toLong())
        ai.onnxruntime.OnnxTensor.createTensor(env, FloatBuffer.wrap(chw), shape).use { x ->
            session.run(mapOf(inputName to x)).use { r ->
                val t = r.get(0) as ai.onnxruntime.OnnxTensor
                val fb = t.floatBuffer
                val out = FloatArray(fb.remaining())
                fb.get(out)
                return out
            }
        }
    }

    fun close() {
        try {
            session.close()
        } catch (t: Throwable) {
        }
    }

    companion object {
        @Volatile private var cached: SegRunner? = null
        @Volatile private var cachedKey = ""

        @Synchronized
        fun get(model: String): SegRunner {
            val key = model + "#" + File(model).length()
            cached?.let { if (cachedKey == key) return it }
            cached?.close()
            val env = ai.onnxruntime.OrtEnvironment.getEnvironment()
            val o = ai.onnxruntime.OrtSession.SessionOptions()
            o.setIntraOpNumThreads(Runtime.getRuntime().availableProcessors().coerceIn(1, 4))
            val r = SegRunner(env.createSession(model, o))
            cached = r
            cachedKey = key
            return r
        }
    }
}

/**
 * One ONNX Runtime session per model file, created on first use. Execution
 * provider: NNAPI (fp16 relaxed) when it loads AND its first tile matches the
 * CPU result; otherwise CPU (XNNPACK when available, else the default CPU EP).
 */
class OrtRunner private constructor(
    private val session: ai.onnxruntime.OrtSession,
    private val side: Int,
    val ep: String,
) {
    private val env = ai.onnxruntime.OrtEnvironment.getEnvironment()
    private val shape = longArrayOf(1, 3, side.toLong(), side.toLong())
    private val inputName: String = try {
        session.inputNames.iterator().next()
    } catch (t: Throwable) {
        "input"
    }

    /** d1-photo: the ONNX input is FIXED (e.g. 1x3x144x144) - check first. */
    fun inputMatches(side: Int): Boolean = try {
        val info = session.inputInfo[inputName]?.info as? ai.onnxruntime.TensorInfo
        val sh = info?.shape
        sh != null && sh.size == 4 && sh[1] == 3L &&
            (sh[2] == side.toLong() || sh[2] < 0) && (sh[3] == side.toLong() || sh[3] < 0)
    } catch (t: Throwable) {
        false
    }

    fun run(chw: FloatArray): FloatArray = run(session, chw)

    private fun run(s: ai.onnxruntime.OrtSession, chw: FloatArray): FloatArray {
        ai.onnxruntime.OnnxTensor.createTensor(env, FloatBuffer.wrap(chw), shape).use { x ->
            s.run(mapOf(inputName to x)).use { r ->
                val t = r.get(0) as ai.onnxruntime.OnnxTensor
                val fb = t.floatBuffer
                val out = FloatArray(fb.remaining())
                fb.get(out)
                return out
            }
        }
    }

    companion object {
        @Volatile private var cached: OrtRunner? = null
        @Volatile private var cachedKey = ""

        private fun verdictKey(model: String) =
            "ep:" + File(model).name + ":" + File(model).length()

        fun markCpu(ctx: Context, model: String) {
            try {
                ctx.getSharedPreferences("photo_studio_native", Context.MODE_PRIVATE)
                    .edit().putString(verdictKey(model), "cpu").apply()
            } catch (t: Throwable) {
            }
        }

        @Synchronized
        fun get(ctx: Context, model: String, side: Int, forceCpu: Boolean): OrtRunner {
            val key = "$model#$side#" + File(model).length() + "#" + forceCpu
            cached?.let { if (cachedKey == key) return it }
            cached?.close()
            val env = ai.onnxruntime.OrtEnvironment.getEnvironment()
            val threads = Runtime.getRuntime().availableProcessors().coerceIn(1, 4)
            fun cpuOpts(): ai.onnxruntime.OrtSession.SessionOptions {
                val o = ai.onnxruntime.OrtSession.SessionOptions()
                o.setIntraOpNumThreads(threads)
                try {
                    o.addXnnpack(mapOf("intra_op_num_threads" to threads.toString()))
                    o.setIntraOpNumThreads(1) // XNNPACK owns the threads
                } catch (t: Throwable) {
                }
                return o
            }
            val prefs = ctx.getSharedPreferences("photo_studio_native", Context.MODE_PRIVATE)
            val verdictKey = verdictKey(model)
            val verdict = prefs.getString(verdictKey, "")
            if (!forceCpu && verdict == "nnapi") {
                try {
                    val o = ai.onnxruntime.OrtSession.SessionOptions()
                    o.addNnapi(EnumSet.of(ai.onnxruntime.providers.NNAPIFlags.USE_FP16))
                    val r = OrtRunner(env.createSession(model, o), side, "nnapi")
                    cached = r
                    cachedKey = key
                    return r
                } catch (t: Throwable) {
                    prefs.edit().putString(verdictKey, "cpu").apply()
                }
            }
            val cpu = env.createSession(model, cpuOpts())
            var chosen = OrtRunner(cpu, side, "cpu")
            // probe NNAPI once per model file; keep it only if it agrees with
            // the CPU result AND is faster on this phone
            if (!forceCpu && verdict == "" && android.os.Build.VERSION.SDK_INT >= 29) {
                try {
                    val o = ai.onnxruntime.OrtSession.SessionOptions()
                    o.addNnapi(EnumSet.of(ai.onnxruntime.providers.NNAPIFlags.USE_FP16))
                    val nn = env.createSession(model, o)
                    val probe = FloatArray(3 * side * side) { i -> ((i * 7919) % 255) / 255f }
                    val t0 = SystemClock.elapsedRealtime()
                    val a = chosen.run(probe)
                    val tCpu = SystemClock.elapsedRealtime() - t0
                    val t1 = SystemClock.elapsedRealtime()
                    val b = OrtRunner(nn, side, "nnapi").run(probe)
                    val tNn = SystemClock.elapsedRealtime() - t1
                    var maxDiff = 0f
                    for (i in a.indices) maxDiff = maxOf(maxDiff, Math.abs(a[i] - b[i]))
                    if (maxDiff < 0.04f && tNn < tCpu) {
                        cpu.close()
                        chosen = OrtRunner(nn, side, "nnapi")
                        prefs.edit().putString(verdictKey, "nnapi").apply()
                    } else {
                        nn.close()
                        prefs.edit().putString(verdictKey, "cpu").apply()
                    }
                } catch (t: Throwable) {
                    prefs.edit().putString(verdictKey, "cpu").apply()
                }
            }
            cached = chosen
            cachedKey = key
            return chosen
        }
    }

    fun close() {
        try {
            session.close()
        } catch (t: Throwable) {
        }
    }
}
