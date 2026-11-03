package com.assisto.assisto.media

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * viewonce (owner My Circle order 3 Nov, part F) — "com.assisto/video_compress".
 *
 * A picked video is trimmed (when longer than the owner's limit, 3 min by
 * default) and re-encoded ON THE PHONE to H.264 / AAC with its SHORT side
 * at most 720 px (never upscaled) and a bitrate Dart computes so the clip
 * stays under the owner's size cap (25 MB). Uses the media3 Transformer
 * (hardware encoder; same media3 version the in-app player already ships).
 *
 * Lazy + crash-guarded: the handler only registers; nothing is created
 * until Dart calls compress(). One job at a time; cancel() stops it.
 *
 *   compress {src, dst, startMs, endMs (-1 = to the end), shortSide, bitrate}
 *     -> {ok: true, path, size} | error("failed" | "busy" | "cancelled")
 *   progress -> 0..100 (or -1 when unknown)
 *   cancel   -> true
 */
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
object VideoCompressChannel {
    private const val NAME = "com.assisto/video_compress"
    private var current: Transformer? = null
    private var pending: MethodChannel.Result? = null
    private var pendingDst: String = ""

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "compress" -> compress(
                        app,
                        call.argument<String>("src") ?: "",
                        call.argument<String>("dst") ?: "",
                        (call.argument<Number>("startMs") ?: 0).toLong(),
                        (call.argument<Number>("endMs") ?: -1).toLong(),
                        (call.argument<Number>("shortSide") ?: 720).toInt(),
                        (call.argument<Number>("bitrate") ?: 1_000_000).toInt(),
                        result
                    )
                    "progress" -> result.success(progress())
                    "cancel" -> {
                        cancel()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                finish(null)
                result.error("failed", t.message, null)
            }
        }
    }

    /** Short side of the clip as SHOWN (rotation applied), or 0. */
    private fun shortSideOf(src: String): Int {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(src)
            val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            if (w <= 0 || h <= 0) 0 else minOf(w, h)
        } catch (t: Throwable) {
            0
        } finally {
            try {
                r.release()
            } catch (t: Throwable) {
            }
        }
    }

    private fun compress(
        context: Context, src: String, dst: String, startMs: Long, endMs: Long,
        shortSide: Int, bitrate: Int, result: MethodChannel.Result
    ) {
        if (current != null) {
            result.error("busy", "a video is already being prepared", null)
            return
        }
        if (src.isEmpty() || dst.isEmpty() || !File(src).exists()) {
            result.error("failed", "no source", null)
            return
        }
        try {
            File(dst).delete()
        } catch (t: Throwable) {
        }
        val clip = MediaItem.ClippingConfiguration.Builder()
            .setStartPositionMs(maxOf(0L, startMs))
        if (endMs > 0) clip.setEndPositionMs(endMs)
        val item = MediaItem.Builder()
            .setUri(Uri.fromFile(File(src)))
            .setClippingConfiguration(clip.build())
            .build()
        val effects = if (shortSideOf(src) > shortSide) {
            Effects(listOf(), listOf(Presentation.createForShortSide(shortSide)))
        } else {
            Effects.EMPTY
        }
        val edited = EditedMediaItem.Builder(item).setEffects(effects).build()
        val encoders = DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(
                VideoEncoderSettings.Builder().setBitrate(bitrate).build()
            )
            .setEnableFallback(true)
            .build()
        val t = Transformer.Builder(context)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .setEncoderFactory(encoders)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    val f = File(pendingDst)
                    finish(
                        if (f.exists()) mapOf("ok" to true, "path" to f.path, "size" to f.length())
                        else null
                    )
                }

                override fun onError(
                    composition: Composition, exportResult: ExportResult,
                    exportException: ExportException
                ) {
                    finish(null, exportException.errorCodeName)
                }
            })
            .build()
        current = t
        pending = result
        pendingDst = dst
        t.start(edited, dst)
    }

    private fun finish(ok: Map<String, Any>?, why: String = "failed") {
        val r = pending
        pending = null
        current = null
        if (ok == null) {
            try {
                if (pendingDst.isNotEmpty()) File(pendingDst).delete()
            } catch (t: Throwable) {
            }
        }
        try {
            if (ok != null) r?.success(ok) else r?.error("failed", why, null)
        } catch (t: Throwable) {
        }
    }

    private fun progress(): Int {
        val t = current ?: return -1
        return try {
            val h = ProgressHolder()
            if (t.getProgress(h) == Transformer.PROGRESS_STATE_AVAILABLE) h.progress else -1
        } catch (e: Throwable) {
            -1
        }
    }

    private fun cancel() {
        val t = current ?: return
        try {
            t.cancel()
        } catch (e: Throwable) {
        }
        val r = pending
        pending = null
        current = null
        try {
            if (pendingDst.isNotEmpty()) File(pendingDst).delete()
        } catch (e: Throwable) {
        }
        try {
            r?.error("cancelled", "cancelled", null)
        } catch (e: Throwable) {
        }
    }
}
