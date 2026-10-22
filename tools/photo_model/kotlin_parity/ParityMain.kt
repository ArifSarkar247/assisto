// p2-photo: desktop-JVM check of UpscaleTiler.kt (the phone's tiling + face-lock
// merge). Compile with kotlinc together with
// app/android_overlay/.../photo/UpscaleTiler.kt (no Android needed):
//   kotlinc UpscaleTiler.kt ParityMain.kt -include-runtime -d parity.jar
//   java -jar parity.jar <fixture dir>     (fixture from make_fixture.py)
// 1. tiling: a fake "model" = nearest x4 of each 144 px tile; the stitched
//    result must equal nearest x4 of the whole photo (seams invisible).
// 2. mergeKeepFaces vs the Python mirror (eval_photos.merge_keep_faces).
import com.assisto.assisto.photo.UpscaleTiler
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

fun readArgb(f: File): Triple<IntArray, Int, Int> {
    val b = ByteBuffer.wrap(f.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
    val w = b.int
    val h = b.int
    val px = IntArray(w * h)
    for (i in 0 until w * h) {
        val r = b.get().toInt() and 0xFF
        val g = b.get().toInt() and 0xFF
        val bl = b.get().toInt() and 0xFF
        b.get()
        px[i] = (0xFF shl 24) or (r shl 16) or (g shl 8) or bl
    }
    return Triple(px, w, h)
}

fun main(args: Array<String>) {
    val dir = File(args[0])
    val (px, w, h) = readArgb(File(dir, "photo.rgba"))
    val side = 144
    val pad = 8
    val scale = 4
    val out = IntArray(w * scale * h * scale)
    val buf = FloatArray(3 * side * side)
    for (t in UpscaleTiler.plan(w, h, side - 2 * pad)) {
        UpscaleTiler.extract(px, w, h, t, pad, side, buf)
        val os = side * scale
        val o = FloatArray(3 * os * os)
        for (c in 0 until 3) for (y in 0 until os) for (x in 0 until os)
            o[c * os * os + y * os + x] = buf[c * side * side + (y / scale) * side + (x / scale)]
        UpscaleTiler.place(o, t, pad, side, scale, out, w * scale)
    }
    var tileErr = 0
    for (y in 0 until h * scale) for (x in 0 until w * scale) {
        if (out[y * w * scale + x] != px[(y / scale) * w + x / scale]) tileErr++
    }
    println("tiling mismatches: $tileErr")
    val (ai, aw, ah) = readArgb(File(dir, "ai.rgba"))
    val (base, _, _) = readArgb(File(dir, "base.rgba"))
    val faces = File(dir, "faces.txt").readLines().filter { it.isNotBlank() }
        .map { l -> l.split(",").map { it.toDouble() }.toDoubleArray() }
    val m = UpscaleTiler.mergeKeepFaces(ai, base, aw, ah, faces, 0.25)
    val (exp, _, _) = readArgb(File(dir, "merged_py.rgba"))
    var maxD = 0
    for (i in m.indices) for (sh in intArrayOf(16, 8, 0)) {
        val d = Math.abs(((m[i] shr sh) and 0xFF) - ((exp[i] shr sh) and 0xFF))
        if (d > maxD) maxD = d
    }
    println("merge max |diff| vs python: $maxD")
    if (tileErr != 0 || maxD > 1) System.exit(1)
}
