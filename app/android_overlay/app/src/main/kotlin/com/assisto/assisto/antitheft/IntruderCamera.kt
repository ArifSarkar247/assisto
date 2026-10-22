package com.assisto.assisto.antitheft

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Size
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * b6-antitheft — ONE front-camera intruder photo, no preview UI, plain
 * Camera2 (platform API: no CameraX, no new Gradle dependency, no
 * androidx.startup provider).
 *
 * WHEN it runs: only from the running, user-opted-in AntiTheftService, on its
 * worker thread, after the device-admin receiver reported the owner's chosen
 * number of wrong unlock attempts (onPasswordFailed). Never at launch, never on
 * boot, never on the main thread.
 *
 * WHY it can work on a locked phone: Android 11+ only lets an app use the
 * camera from the background while a foreground service that declared the
 * CAMERA type is running AND was started while the app was visible. The
 * service adds that type only when the owner switched "Intruder photo" on and
 * granted the camera permission (from the open app). If either is missing,
 * [canAttempt] is false and the caller records a photo-less failed_unlock —
 * we never pretend a photo was taken. Vendor ROMs may still refuse the camera
 * (the open fails / times out): that also returns null.
 *
 * Every step is try/catch + timed out; all camera objects are closed in
 * `finally`. A failure here can never crash the service or the lock screen.
 */
object IntruderCamera {

    fun hasFrontCamera(ctx: Context): Boolean = try {
        ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_FRONT)
    } catch (_: Throwable) {
        false
    }

    fun hasPermission(ctx: Context): Boolean = try {
        ctx.checkSelfPermission(android.Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
    } catch (_: Throwable) {
        false
    }

    fun canAttempt(ctx: Context): Boolean = hasFrontCamera(ctx) && hasPermission(ctx)

    private fun frontId(cm: CameraManager): String? {
        for (id in cm.cameraIdList) {
            try {
                val f = cm.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
                if (f == CameraCharacteristics.LENS_FACING_FRONT) return id
            } catch (_: Throwable) {
            }
        }
        return null
    }

    /** Largest JPEG size that fits 1280x960 (keeps the upload well < 2 MB). */
    private fun pickJpeg(sizes: Array<Size>?): Size? {
        if (sizes.isNullOrEmpty()) return null
        val fit = sizes.filter { it.width * it.height <= 1280 * 960 }
        return if (fit.isNotEmpty()) fit.maxByOrNull { it.width * it.height }
        else sizes.minByOrNull { it.width * it.height }
    }

    /** Smallest YUV size >= 320x240 — only used to let auto-exposure settle. */
    private fun pickWarm(sizes: Array<Size>?): Size? {
        if (sizes.isNullOrEmpty()) return null
        val ok = sizes.filter { it.width * it.height >= 320 * 240 }
        return (if (ok.isNotEmpty()) ok else sizes.toList()).minByOrNull { it.width * it.height }
    }

    /**
     * Capture one JPEG. BLOCKING — call from a worker thread only (returns
     * null on the main thread). Returns the JPEG bytes, or null on ANY failure
     * (no permission, no front camera, ROM refused, timeout). Never throws.
     */
    @Suppress("DEPRECATION")
    fun captureJpeg(ctx: Context, timeoutMs: Long = 6000): ByteArray? {
        if (!canAttempt(ctx)) return null
        if (Looper.myLooper() == Looper.getMainLooper()) return null
        val ht = HandlerThread("assisto-intruder-cam")
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        var jpegReader: ImageReader? = null
        var warmReader: ImageReader? = null
        return try {
            ht.start()
            val h = Handler(ht.looper)
            val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
                ?: return null
            val id = frontId(cm) ?: return null
            val chars = cm.getCameraCharacteristics(id)
            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?: return null
            val jSize = pickJpeg(map.getOutputSizes(ImageFormat.JPEG)) ?: return null
            val wSize = pickWarm(map.getOutputSizes(ImageFormat.YUV_420_888))

            val out = AtomicReference<ByteArray?>(null)
            val gotJpeg = CountDownLatch(1)
            jpegReader = ImageReader.newInstance(jSize.width, jSize.height, ImageFormat.JPEG, 2)
            jpegReader.setOnImageAvailableListener({ r ->
                try {
                    val img = r.acquireLatestImage()
                    if (img != null) {
                        try {
                            val buf = img.planes[0].buffer
                            val b = ByteArray(buf.remaining())
                            buf.get(b)
                            out.set(b)
                        } finally {
                            img.close()
                        }
                    }
                } catch (_: Throwable) {
                }
                gotJpeg.countDown()
            }, h)
            if (wSize != null) {
                warmReader = ImageReader.newInstance(
                    wSize.width, wSize.height, ImageFormat.YUV_420_888, 2)
                warmReader.setOnImageAvailableListener({ r ->
                    try { r.acquireLatestImage()?.close() } catch (_: Throwable) {}
                }, h)
            }

            val opened = CountDownLatch(1)
            cm.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(d: CameraDevice) {
                    device = d
                    opened.countDown()
                }
                override fun onDisconnected(d: CameraDevice) {
                    try { d.close() } catch (_: Throwable) {}
                    opened.countDown()
                    gotJpeg.countDown()
                }
                override fun onError(d: CameraDevice, error: Int) {
                    try { d.close() } catch (_: Throwable) {}
                    opened.countDown()
                    gotJpeg.countDown()
                }
            }, h)
            if (!opened.await(timeoutMs, TimeUnit.MILLISECONDS)) return null
            val dev = device ?: return null

            val surfaces = ArrayList<android.view.Surface>()
            surfaces.add(jpegReader.surface)
            warmReader?.let { surfaces.add(it.surface) }
            val configured = CountDownLatch(1)
            dev.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(s: CameraCaptureSession) {
                    session = s
                    configured.countDown()
                }
                override fun onConfigureFailed(s: CameraCaptureSession) {
                    configured.countDown()
                }
            }, h)
            if (!configured.await(timeoutMs, TimeUnit.MILLISECONDS)) return null
            val ses = session ?: return null

            // ~0.9 s of preview frames so auto-exposure / white balance settle
            // (otherwise the first frame is often black or green).
            warmReader?.let { wr ->
                try {
                    val warm = dev.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                    warm.addTarget(wr.surface)
                    warm.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                    ses.setRepeatingRequest(warm.build(), null, h)
                    Thread.sleep(900)
                    ses.stopRepeating()
                } catch (_: Throwable) {
                }
            }

            val still = dev.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
            still.addTarget(jpegReader.surface)
            still.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
            still.set(CaptureRequest.JPEG_QUALITY, 80.toByte())
            try {
                val sensor = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 270
                still.set(CaptureRequest.JPEG_ORIENTATION, sensor)
            } catch (_: Throwable) {
            }
            ses.capture(still.build(), null, h)
            if (!gotJpeg.await(timeoutMs, TimeUnit.MILLISECONDS)) return null
            val b = out.get()
            if (b != null && b.size > 4 && b[0] == 0xFF.toByte() && b[1] == 0xD8.toByte()) b else null
        } catch (_: Throwable) {
            null
        } finally {
            try { session?.close() } catch (_: Throwable) {}
            try { device?.close() } catch (_: Throwable) {}
            try { jpegReader?.close() } catch (_: Throwable) {}
            try { warmReader?.close() } catch (_: Throwable) {}
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) ht.quitSafely()
                else ht.quit()
            } catch (_: Throwable) {
            }
        }
    }
}

/**
 * b6-antitheft — intruder photos are stored ENCRYPTED on the phone while they
 * wait in the store-and-forward queue (AES-256-GCM, see [IntruderCrypto]). The
 * key is a random file in the app sandbox — NOT the Android Keystore (owner
 * rule: Keystore fails/hangs on some ColorOS/MIUI phones). Key and photos live
 * under noBackupFilesDir/assisto_antitheft/, which Android never backs up.
 * A photo is decrypted only in memory, right before the upload; the server
 * keeps it encrypted at rest and shows it only to the owner (+ approved
 * family). Files are deleted as soon as the server accepted them
 * (AntiTheftQueue.ack) or when protection is turned off ([wipe]).
 */
object IntruderVault {
    private const val DIR = "assisto_antitheft"
    private const val PHOTOS = "photos"

    private fun base(ctx: Context): File {
        val c = ctx.applicationContext
        val root = try { c.noBackupFilesDir } catch (_: Throwable) { c.filesDir }
        return File(root, DIR).apply { mkdirs() }
    }

    private fun photos(ctx: Context): File = File(base(ctx), PHOTOS).apply { mkdirs() }

    /** Encrypt [jpeg] to a private file; returns its path or null. */
    fun seal(ctx: Context, cid: String, jpeg: ByteArray): String? = try {
        val blob = IntruderCrypto.sealIn(base(ctx), jpeg)
        if (blob == null) {
            null
        } else {
            val safe = cid.replace(Regex("[^A-Za-z0-9_-]"), "_").take(60)
            val f = File(photos(ctx), "$safe.enc")
            f.writeBytes(blob)
            f.absolutePath
        }
    } catch (_: Throwable) {
        null
    }

    /** Decrypt a sealed file in memory; null if missing/corrupt. */
    fun open(ctx: Context, path: String): ByteArray? = try {
        IntruderCrypto.openIn(base(ctx), File(path).readBytes())
    } catch (_: Throwable) {
        null
    }

    /** Delete every queued photo file (protection turned off). The key stays. */
    fun wipe(ctx: Context) {
        try { photos(ctx).listFiles()?.forEach { it.delete() } } catch (_: Throwable) {}
    }
}
