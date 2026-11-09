package com.assisto.assisto.guardbox

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * cctvbox — GUARD BOX video decoder: an old phone pulls an IP camera's RTSP
 * stream (pure Dart, lib/ipcam/rtsp_client.dart) and hands each H.264 / H.265
 * access unit here. The phone's own MediaCodec decoder (hardware when the
 * phone has one) turns them into pictures; on request ("decGrab") the NEXT
 * decoded picture comes back as a small grey frame (motion check) + a JPEG
 * (person check, alert photo, live view).
 *
 * Methods on the existing channel "com.assisto/guardbox" (routed from
 * GuardBoxChannel, so no MainActivity change):
 *   decAvailable                         -> Bool
 *   decOpen({mime, csd:[bytes], w, h})   -> {ok, codec?, error?}
 *   decFeed({data, pts})                 -> {ok, decoded, error?}
 *   decGrab({gw, maxW, q, timeoutMs})    -> {ok, jpeg, gray, gw, gh, w, h, error?}
 *   decClose                             -> true
 *
 * LAZY + CRASH-GUARDED: nothing exists until decOpen (from an open Guard Box
 * screen, flag guard_box_mode). ONE background thread owns the codec; every
 * call answers {ok:false, error} instead of throwing — a codec failure, an
 * OOM or a missing decoder never reaches the app. ByteBuffer output (no
 * Surface, no GPU), so it also works on 2 GB phones and the emulator.
 */
object IpCamDecoder {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var codec: MediaCodec? = null
    private var codecName = ""
    private val info = MediaCodec.BufferInfo()
    private var outFmt: MediaFormat? = null
    private var decoded = 0L
    private var grab: Grab? = null

    private class Grab(val result: MethodChannel.Result, val gw: Int, val maxW: Int, val q: Int)

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "decAvailable" -> result.success(true)
            "decOpen" -> {
                val mime = call.argument<String>("mime") ?: "video/avc"
                val csd = call.argument<List<ByteArray>>("csd") ?: emptyList()
                val w = call.argument<Int>("w") ?: 1280
                val h = call.argument<Int>("h") ?: 720
                run(result) { open(mime, csd, w, h) }
            }
            "decFeed" -> {
                val data = call.argument<ByteArray>("data")
                val pts = (call.argument<Number>("pts") ?: 0).toLong()
                run(result) { if (data == null) err("args") else feed(data, pts) }
            }
            "decGrab" -> {
                val gw = (call.argument<Int>("gw") ?: 160).coerceIn(32, 640)
                val maxW = (call.argument<Int>("maxW") ?: 640).coerceIn(64, 1920)
                val q = (call.argument<Int>("q") ?: 70).coerceIn(30, 95)
                val timeoutMs = (call.argument<Int>("timeoutMs") ?: 3000).coerceIn(200, 15000)
                val g = Grab(result, gw, maxW, q)
                worker.execute {
                    try {
                        grab?.let { reply(it.result, err("replaced")) }
                        grab = g
                        codec?.let { drain(it) }
                    } catch (t: Throwable) {
                        if (grab === g) grab = null
                        reply(result, err(t.javaClass.simpleName))
                    }
                }
                main.postDelayed({
                    worker.execute {
                        if (grab === g) {
                            grab = null
                            reply(result, err("timeout"))
                        }
                    }
                }, timeoutMs.toLong())
            }
            "decClose" -> run(result) { closeCodec(); mapOf("ok" to true) }
            else -> return false
        }
        return true
    }

    private fun run(result: MethodChannel.Result, body: () -> Map<String, Any?>) {
        worker.execute {
            val out = try {
                body()
            } catch (t: Throwable) {
                // a broken codec is dropped; Dart reopens it on the next key picture
                if (t !is OutOfMemoryError) closeCodec()
                err(t.javaClass.simpleName)
            }
            reply(result, out)
        }
    }

    private fun reply(result: MethodChannel.Result, out: Map<String, Any?>) {
        main.post {
            try {
                result.success(out)
            } catch (_: Throwable) {
            }
        }
    }

    private fun err(e: String): Map<String, Any?> = mapOf("ok" to false, "error" to e)

    private fun open(mime: String, csd: List<ByteArray>, w: Int, h: Int): Map<String, Any?> {
        closeCodec()
        val fmt = MediaFormat.createVideoFormat(mime, w.coerceIn(64, 3840), h.coerceIn(64, 2160))
        val sc = byteArrayOf(0, 0, 0, 1)
        if (mime == "video/avc" && csd.size >= 2) {
            fmt.setByteBuffer("csd-0", ByteBuffer.wrap(sc + csd[0]))
            fmt.setByteBuffer("csd-1", ByteBuffer.wrap(sc + csd[1]))
        } else if (csd.isNotEmpty()) {
            val all = ByteArrayOutputStream()
            for (p in csd) { all.write(sc); all.write(p) }
            fmt.setByteBuffer("csd-0", ByteBuffer.wrap(all.toByteArray()))
        }
        fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
        fmt.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1 shl 20)
        if (Build.VERSION.SDK_INT >= 30) {
            try { fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1) } catch (_: Throwable) {}
        }
        val c = MediaCodec.createDecoderByType(mime)
        try {
            c.configure(fmt, null, null, 0)
            c.start()
        } catch (t: Throwable) {
            try { c.release() } catch (_: Throwable) {}
            throw t
        }
        codec = c
        codecName = try { c.name } catch (_: Throwable) { "" }
        outFmt = null
        decoded = 0
        return mapOf("ok" to true, "codec" to codecName)
    }

    private fun feed(data: ByteArray, pts: Long): Map<String, Any?> {
        val c = codec ?: return err("closed")
        var idx = c.dequeueInputBuffer(20_000)
        if (idx < 0) {
            drain(c)
            idx = c.dequeueInputBuffer(60_000)
        }
        if (idx < 0) return mapOf("ok" to false, "error" to "busy", "decoded" to decoded)
        val buf = c.getInputBuffer(idx) ?: return err("nobuf")
        buf.clear()
        if (data.size > buf.capacity()) {
            c.queueInputBuffer(idx, 0, 0, pts, 0)
            return err("too_big")
        }
        buf.put(data)
        c.queueInputBuffer(idx, 0, data.size, pts, 0)
        drain(c)
        return mapOf("ok" to true, "decoded" to decoded)
    }

    private fun drain(c: MediaCodec) {
        while (true) {
            val o = c.dequeueOutputBuffer(info, 0)
            when {
                o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> outFmt = c.outputFormat
                o >= 0 -> {
                    decoded++
                    val g = grab
                    if (g != null && info.size > 0) {
                        grab = null
                        val out = try { picture(c, o, g) } catch (t: Throwable) { err(t.javaClass.simpleName) }
                        reply(g.result, out)
                    }
                    c.releaseOutputBuffer(o, false)
                }
                else -> return // TRY_AGAIN_LATER / BUFFERS_CHANGED
            }
        }
    }

    /** One decoded picture -> NV21 at <= maxW wide -> JPEG + a small grey frame. */
    private fun picture(c: MediaCodec, idx: Int, g: Grab): Map<String, Any?> {
        val img: Image? = try { c.getOutputImage(idx) } catch (_: Throwable) { null }
        val src: Yuv = if (img != null) {
            try { Yuv.fromImage(img) } finally { img.close() }
        } else {
            Yuv.fromBuffer(c.getOutputBuffer(idx) ?: return err("nobuf"), outFmt ?: c.outputFormat)
                ?: return err("colorfmt")
        }
        val w = src.w
        val h = src.h
        val s = minOf(1.0, g.maxW.toDouble() / w)
        val tw = maxOf(2, ((w * s).toInt()) and 0x7ffffffe)
        val th = maxOf(2, ((h * s).toInt()) and 0x7ffffffe)
        val nv21 = src.toNv21(tw, th)
        val jpeg = ByteArrayOutputStream(tw * th / 4)
        YuvImage(nv21, ImageFormat.NV21, tw, th, null).compressToJpeg(Rect(0, 0, tw, th), g.q, jpeg)
        val gw = minOf(g.gw, tw)
        val gh = maxOf(1, th * gw / tw)
        val gray = ByteArray(gw * gh)
        for (y in 0 until gh) {
            val sy = y * th / gh
            for (x in 0 until gw) gray[y * gw + x] = nv21[sy * tw + x * tw / gw]
        }
        return mapOf("ok" to true, "jpeg" to jpeg.toByteArray(), "gray" to gray, "gw" to gw, "gh" to gh,
            "w" to w, "h" to h, "decoded" to decoded, "codec" to codecName)
    }

    /** A YUV 4:2:0 picture as three planes with strides (cropped). */
    private class Yuv(
        val w: Int, val h: Int,
        val y: ByteArray, val yRow: Int, val yPix: Int, val yOff: Int,
        val u: ByteArray, val v: ByteArray, val cRow: Int, val cPix: Int, val uOff: Int, val vOff: Int,
    ) {
        fun toNv21(tw: Int, th: Int): ByteArray {
            val out = ByteArray(tw * th * 3 / 2)
            for (ty in 0 until th) {
                val sy = ty * h / th
                val row = yOff + sy * yRow
                for (tx in 0 until tw) out[ty * tw + tx] = y[row + (tx * w / tw) * yPix]
            }
            var o = tw * th
            for (ty in 0 until th / 2) {
                val sy = (ty * 2 * h / th) / 2
                for (tx in 0 until tw / 2) {
                    val sx = (tx * 2 * w / tw) / 2
                    val ci = sy * cRow + sx * cPix
                    out[o++] = v[vOff + ci]
                    out[o++] = u[uOff + ci]
                }
            }
            return out
        }

        companion object {
            private fun bytes(b: ByteBuffer): ByteArray {
                val d = b.duplicate()
                d.rewind()
                val a = ByteArray(d.remaining())
                d.get(a)
                return a
            }

            fun fromImage(img: Image): Yuv {
                val cr = img.cropRect
                val p = img.planes
                val cx = cr.left
                val cy = cr.top
                val yRow = p[0].rowStride
                val yPix = p[0].pixelStride
                val cRow = p[1].rowStride
                val cPix = p[1].pixelStride
                return Yuv(cr.width(), cr.height(),
                    bytes(p[0].buffer), yRow, yPix, cy * yRow + cx * yPix,
                    bytes(p[1].buffer), bytes(p[2].buffer), cRow, cPix,
                    (cy / 2) * cRow + (cx / 2) * cPix, (cy / 2) * p[2].rowStride + (cx / 2) * p[2].pixelStride)
            }

            /** Old decoders without getOutputImage: planar (19) or semi-planar (21). */
            fun fromBuffer(b: ByteBuffer, f: MediaFormat): Yuv? {
                fun int(k: String, d: Int) = try { if (f.containsKey(k)) f.getInteger(k) else d } catch (_: Throwable) { d }
                val width = int(MediaFormat.KEY_WIDTH, 0)
                val height = int(MediaFormat.KEY_HEIGHT, 0)
                if (width <= 0 || height <= 0) return null
                val stride = maxOf(width, int("stride", width))
                val slice = maxOf(height, int("slice-height", height))
                val left = int("crop-left", 0)
                val top = int("crop-top", 0)
                val right = int("crop-right", width - 1)
                val bottom = int("crop-bottom", height - 1)
                val w = right - left + 1
                val h = bottom - top + 1
                val all = bytes(b)
                val ySize = stride * slice
                return when (int(MediaFormat.KEY_COLOR_FORMAT, 0)) {
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar -> {
                        val cRow = stride / 2
                        val cSize = cRow * (slice / 2)
                        if (all.size < ySize + 2 * cSize) return null
                        val off = (top / 2) * cRow + left / 2
                        Yuv(w, h, all, stride, 1, top * stride + left,
                            all, all, cRow, 1, ySize + off, ySize + cSize + off)
                    }
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar -> {
                        if (all.size < ySize + stride * (slice / 2) - 1) return null
                        val off = (top / 2) * stride + (left / 2) * 2
                        Yuv(w, h, all, stride, 1, top * stride + left,
                            all, all, stride, 2, ySize + off, ySize + off + 1)
                    }
                    else -> null
                }
            }
        }
    }

    private fun closeCodec() {
        val c = codec
        codec = null
        outFmt = null
        grab?.let { reply(it.result, err("closed")) }
        grab = null
        if (c != null) {
            try { c.stop() } catch (_: Throwable) {}
            try { c.release() } catch (_: Throwable) {}
        }
    }
}
