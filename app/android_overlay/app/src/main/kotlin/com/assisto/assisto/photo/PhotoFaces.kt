package com.assisto.assisto.photo

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceContour
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.face.FaceLandmark
import java.util.concurrent.TimeUnit

/**
 * p2-photo — ML Kit face detection (bundled model, on-device, offline) for
 * the Photo Studio skin mask, FACE-LOCK boxes and the IDENTITY CHECK
 * (landmark geometry before vs after; see app/lib/photo_studio/ps_identity.dart).
 *
 * ML Kit's own startup ContentProvider (MlKitInitProvider) is REMOVED in the
 * manifest (no startup providers — ColorOS launch history); we initialise
 * ML Kit here, on the first face request, inside try/catch.
 */
object PhotoFaces {
    private const val MAX_LONG = 1280
    private var detector: FaceDetector? = null
    private var inited = false

    private val ORDER = intArrayOf(
        FaceLandmark.LEFT_EYE, FaceLandmark.RIGHT_EYE, FaceLandmark.NOSE_BASE,
        FaceLandmark.MOUTH_LEFT, FaceLandmark.MOUTH_RIGHT, FaceLandmark.MOUTH_BOTTOM,
        FaceLandmark.LEFT_CHEEK, FaceLandmark.RIGHT_CHEEK)

    @Synchronized
    private fun detector(ctx: Context): FaceDetector {
        if (!inited) {
            com.google.mlkit.common.MlKit.initialize(ctx.applicationContext)
            inited = true
        }
        detector?.let { return it }
        val opts = FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
            .setContourMode(FaceDetectorOptions.CONTOUR_MODE_ALL)
            .setMinFaceSize(0.08f)
            .build()
        return FaceDetection.getClient(opts).also { detector = it }
    }

    fun detect(ctx: Context, path: String): Map<String, Any?> {
        val b = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, b)
        if (b.outWidth <= 0) return mapOf("ok" to false, "error" to "decode")
        var sample = 1
        while (maxOf(b.outWidth, b.outHeight) / (sample * 2) >= MAX_LONG) sample *= 2
        val bmp = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }) ?: return mapOf("ok" to false, "error" to "decode")
        try {
            val w = bmp.width
            val h = bmp.height
            // points are returned in ORIGINAL pixel units (x sample)
            val k = sample.toDouble()
            val faces = Tasks.await(detector(ctx).process(InputImage.fromBitmap(bmp, 0)),
                20, TimeUnit.SECONDS)
            val out = ArrayList<Map<String, Any?>>()
            for (f in faces) {
                val r = f.boundingBox
                val pts = ArrayList<Double>()
                var complete = true
                for (id in ORDER) {
                    val lm = f.getLandmark(id)
                    if (lm == null) {
                        complete = false
                        break
                    }
                    pts.add(lm.position.x * k)
                    pts.add(lm.position.y * k)
                }
                val oval = ArrayList<Double>()
                f.getContour(FaceContour.FACE)?.points?.forEach {
                    oval.add(it.x * k)
                    oval.add(it.y * k)
                }
                out.add(mapOf(
                    "box" to listOf(r.left.toDouble() / w, r.top.toDouble() / h,
                        r.width().toDouble() / w, r.height().toDouble() / h),
                    "points" to if (complete) pts else ArrayList<Double>(),
                    "oval" to oval,
                ))
            }
            return mapOf("ok" to true, "w" to b.outWidth, "h" to b.outHeight, "faces" to out)
        } finally {
            bmp.recycle()
        }
    }
}
