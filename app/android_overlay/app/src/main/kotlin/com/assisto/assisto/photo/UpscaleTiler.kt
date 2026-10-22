package com.assisto.assisto.photo

/**
 * p2-photo — pure tiling logic for the on-device Real-ESRGAN upscaler.
 * No Android import, so it is unit-checked on a desktop JVM
 * (tools/photo_model/kotlin_parity) against the Python evaluation
 * (tools/photo_model/eval_photos.py uses the SAME tiling).
 *
 * The ONNX model has a STATIC input [1,3,T,T] (T = tile + 2*pad, default
 * 144 = 128 + 2*8) because NNAPI only accelerates static shapes. Every tile is
 * cut with `pad` pixels of context on each side (mirror-reflected at the
 * photo border), and only the centre `tile x tile` part of each output (x scale)
 * is kept, so tile seams are invisible.
 */
object UpscaleTiler {
    data class Tile(val x0: Int, val y0: Int, val w: Int, val h: Int)

    /** Tiles covering a w×h image, each at most `tile` px (valid area). */
    fun plan(w: Int, h: Int, tile: Int): List<Tile> {
        val out = ArrayList<Tile>()
        var y = 0
        while (y < h) {
            val th = minOf(tile, h - y)
            var x = 0
            while (x < w) {
                val tw = minOf(tile, w - x)
                out.add(Tile(x, y, tw, th))
                x += tile
            }
            y += tile
        }
        return out
    }

    /** Mirror-reflect index into [0, n) (works for any offset). */
    fun reflect(i: Int, n: Int): Int {
        if (n <= 1) return 0
        val period = 2 * (n - 1)
        var k = i % period
        if (k < 0) k += period
        return if (k < n) k else period - k
    }

    /**
     * Cut tile `t` (+pad context) from ARGB `px` (w×h) into planar RGB 0..1
     * of size side×side, side = tile + 2*pad. Positions beyond the tile's
     * valid area (small photos / last row/column) are reflected too.
     */
    fun extract(px: IntArray, w: Int, h: Int, t: Tile, pad: Int, side: Int, dst: FloatArray) {
        val plane = side * side
        for (yy in 0 until side) {
            val sy = reflect(t.y0 - pad + yy, h)
            for (xx in 0 until side) {
                val sx = reflect(t.x0 - pad + xx, w)
                val c = px[sy * w + sx]
                val o = yy * side + xx
                dst[o] = ((c shr 16) and 0xFF) / 255f
                dst[plane + o] = ((c shr 8) and 0xFF) / 255f
                dst[2 * plane + o] = (c and 0xFF) / 255f
            }
        }
    }

    /**
     * Write the valid centre of a model output (planar RGB 0..1, side*scale
     * square) for tile `t` into the ARGB output (w*scale × h*scale).
     */
    fun place(out: FloatArray, t: Tile, pad: Int, side: Int, scale: Int,
              dst: IntArray, dstW: Int) {
        val os = side * scale
        val plane = os * os
        val offY = pad * scale
        val offX = pad * scale
        for (yy in 0 until t.h * scale) {
            val oy = offY + yy
            val dy = t.y0 * scale + yy
            for (xx in 0 until t.w * scale) {
                val o = oy * os + offX + xx
                val r = to8(out[o])
                val g = to8(out[plane + o])
                val b = to8(out[2 * plane + o])
                dst[dy * dstW + t.x0 * scale + xx] =
                    (0xFF shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
    }

    fun to8(v: Float): Int {
        val q = Math.round(v * 255f)
        return if (q < 0) 0 else if (q > 255) 255 else q
    }

    /**
     * FACE-LOCK for the AI step + colour keeping. `ai` is the model output,
     * `base` the original scaled to the same size (bilinear). The result
     * keeps `base`'s colours everywhere (only LUMINANCE detail comes from the
     * model, so skin tone / eye colour never change) and, inside each face
     * ellipse, only `faceAi` (e.g. 0.25) of the AI detail — a general
     * super-resolution model repaints small eyes/skin, so faces stay the
     * person's own pixels. `faces` = [x, y, w, h] normalised 0..1.
     * Same maths as tools/photo_model/eval_photos.py `merge_keep_faces`.
     */
    fun mergeKeepFaces(ai: IntArray, base: IntArray, w: Int, h: Int,
                       faces: List<DoubleArray>, faceAi: Double): IntArray {
        val out = IntArray(w * h)
        for (y in 0 until h) {
            for (x in 0 until w) {
                var wt = 1.0
                for (f in faces) {
                    val cx = (f[0] + f[2] / 2) * w
                    val cy = (f[1] + f[3] / 2) * h
                    val rx = f[2] * w * 0.62
                    val ry = f[3] * h * 0.72
                    if (rx < 1 || ry < 1) continue
                    val dx = (x + 0.5 - cx) / rx
                    val dy = (y + 0.5 - cy) / ry
                    val d = Math.sqrt(dx * dx + dy * dy)
                    var t = (d - 0.75) / 0.25
                    if (t < 0) t = 0.0 else if (t > 1) t = 1.0
                    val s = t * t * (3 - 2 * t)
                    val v = faceAi + (1 - faceAi) * s
                    if (v < wt) wt = v
                }
                val i = y * w + x
                val a = ai[i]
                val b = base[i]
                val ya = 0.299 * ((a shr 16) and 0xFF) + 0.587 * ((a shr 8) and 0xFF) + 0.114 * (a and 0xFF)
                val br = (b shr 16) and 0xFF
                val bg = (b shr 8) and 0xFF
                val bb = b and 0xFF
                val yb = 0.299 * br + 0.587 * bg + 0.114 * bb
                val dY = (ya - yb) * wt
                out[i] = (0xFF shl 24) or (clamp8(br + dY) shl 16) or
                    (clamp8(bg + dY) shl 8) or clamp8(bb + dY)
            }
        }
        return out
    }

    fun clamp8(v: Double): Int {
        val q = Math.round(v).toInt()
        return if (q < 0) 0 else if (q > 255) 255 else q
    }

    /**
     * Input size for the model: long edge = min(original, maxInputLong).
     * Returns (w, h) keeping the aspect ratio, each ≥ 1.
     */
    fun inputSize(w: Int, h: Int, maxInputLong: Int): Pair<Int, Int> {
        val long = maxOf(w, h)
        if (long <= maxInputLong) return Pair(w, h)
        val f = maxInputLong.toDouble() / long
        return Pair(maxOf(1, Math.round(w * f).toInt()), maxOf(1, Math.round(h * f).toInt()))
    }
}
