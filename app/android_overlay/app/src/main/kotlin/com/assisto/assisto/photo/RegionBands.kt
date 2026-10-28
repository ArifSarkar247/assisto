package com.assisto.assisto.photo

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.ColorSpace
import android.graphics.Matrix
import android.graphics.Rect
import android.media.ExifInterface
import android.os.Build
import java.io.FileOutputStream
import java.nio.ByteBuffer

/**
 * photoperf2 — Photo Studio export: decode a big photo in horizontal BANDS
 * (Android BitmapRegionDecoder) so the 12 MP RGBA image never exists in full
 * (it was decoded whole on the Dart side: 48 MB, then copied for the worker
 * isolates). Dart asks for output rows [top, bottom) and gets them as raw
 * RGBA (8 bit, sRGB) in a temp file that the export worker isolate reads.
 *
 * LAZY + crash-guarded like the rest of PhotoNativeChannel: nothing is
 * created until Dart calls regionOpen; every failure is a short error code
 * and Dart falls back to the old whole-image decode.
 *
 * EXIF orientation is applied (Flutter's decoder applies it too, so the band
 * rows match the proxy the edit was made on): 90/180/270 rotate each band;
 * mirrored orientations are refused ("orientation") -> Dart falls back.
 */
object RegionBands {
    private class Src(val dec: BitmapRegionDecoder, val rot: Int, val rawW: Int, val rawH: Int) {
        var buf: ByteBuffer? = null
        val w get() = if (rot == 90 || rot == 270) rawH else rawW
        val h get() = if (rot == 90 || rot == 270) rawW else rawH
    }

    private val open = HashMap<Int, Src>()
    private var next = 1

    private fun fail(e: String) = mapOf("ok" to false, "error" to e)

    private fun rotationOf(path: String): Int? {
        val o = try {
            ExifInterface(path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (t: Throwable) {
            ExifInterface.ORIENTATION_NORMAL // no / unreadable EXIF (PNG): as stored
        }
        return when (o) {
            ExifInterface.ORIENTATION_UNDEFINED, ExifInterface.ORIENTATION_NORMAL -> 0
            ExifInterface.ORIENTATION_ROTATE_90 -> 90
            ExifInterface.ORIENTATION_ROTATE_180 -> 180
            ExifInterface.ORIENTATION_ROTATE_270 -> 270
            else -> null // mirrored: not handled here
        }
    }

    /** -> {ok, handle, w, h (as displayed, orientation applied), rot} */
    fun open(path: String): Map<String, Any?> {
        val rot = rotationOf(path) ?: return fail("orientation")
        val dec: BitmapRegionDecoder? = if (Build.VERSION.SDK_INT >= 31) {
            BitmapRegionDecoder.newInstance(path)
        } else {
            @Suppress("DEPRECATION")
            BitmapRegionDecoder.newInstance(path, false)
        }
        if (dec == null) return fail("open")
        val s = Src(dec, rot, dec.width, dec.height)
        if (s.rawW <= 0 || s.rawH <= 0) {
            dec.recycle()
            return fail("size")
        }
        val id = synchronized(this) {
            val i = next++
            open[i] = s
            i
        }
        return mapOf("ok" to true, "handle" to id, "w" to s.w, "h" to s.h, "rot" to rot)
    }

    /** Output rows [top, bottom) -> raw RGBA at [out]. -> {ok, w, rows} */
    fun band(handle: Int, top: Int, bottom: Int, out: String): Map<String, Any?> {
        val s = synchronized(this) { open[handle] } ?: return fail("handle")
        val w = s.w
        if (top < 0 || bottom > s.h || top >= bottom) return fail("range")
        val rect = when (s.rot) {
            0 -> Rect(0, top, s.rawW, bottom)
            180 -> Rect(0, s.rawH - bottom, s.rawW, s.rawH - top)
            90 -> Rect(top, 0, bottom, s.rawH)          // output row y = source column y
            else -> Rect(s.rawW - bottom, 0, s.rawW - top, s.rawH) // 270
        }
        val opts = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            // same colours as Flutter's decoder (it draws in sRGB)
            inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
        }
        var bmp = s.dec.decodeRegion(rect, opts) ?: return fail("decode")
        try {
            if (s.rot != 0) {
                val m = Matrix().apply { postRotate(s.rot.toFloat()) }
                val r = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, false)
                if (r !== bmp) bmp.recycle()
                bmp = r
            }
            val rows = bottom - top
            if (bmp.config != Bitmap.Config.ARGB_8888 || bmp.width != w || bmp.height != rows ||
                bmp.rowBytes != w * 4 || bmp.hasAlpha()) {
                // alpha would come premultiplied here: the old path keeps it exact
                return fail("format")
            }
            val need = w * 4 * rows
            val old = s.buf
            val buf: ByteBuffer = if (old != null && old.capacity() >= need) old else {
                s.buf = null // let the old one go first
                ByteBuffer.allocateDirect(need).also { s.buf = it }
            }
            buf.clear()
            buf.limit(need)
            bmp.copyPixelsToBuffer(buf) // ARGB_8888 = R, G, B, A bytes in memory
            buf.flip()
            FileOutputStream(out).use { fo ->
                val ch = fo.channel
                while (buf.hasRemaining()) ch.write(buf)
            }
            return mapOf("ok" to true, "w" to w, "rows" to rows)
        } finally {
            bmp.recycle()
        }
    }

    fun close(handle: Int) {
        val s = synchronized(this) { open.remove(handle) } ?: return
        try {
            s.dec.recycle()
        } catch (t: Throwable) {
        }
        s.buf = null
    }

    fun closeAll() {
        val all = synchronized(this) { open.keys.toList() }
        for (k in all) close(k)
    }
}
