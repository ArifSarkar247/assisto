// ps1-photo — export sinks that need Android APIs (proposal §N4). Registered in
// MainActivity.configureFlutterEngine. Each call is invoked ONLY after the
// Dart export gate returned an unlock token; this file never decides access.
// Lazy, try/caught, no startup work.
//
//   saveToGallery(bytes, name) -> MediaStore Pictures/Assisto (API 29+ scoped,
//                                 no storage permission needed)
//   setWallpaper(bytes, which) -> WallpaperManager (needs SET_WALLPAPER, a
//                                 normal install-time permission)
//   copyImage(bytes, name)     -> MediaStore item + ClipData URI on the clipboard
package com.assisto.assisto

import android.app.WallpaperManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

object PhotoExportChannel {
    private const val CHANNEL = "com.assisto/photo_export"
    private val io = Executors.newSingleThreadExecutor()

    fun register(ctx: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val bytes = call.argument<ByteArray>("bytes")
                val name = call.argument<String>("name") ?: "assisto.png"
                if (bytes == null) {
                    result.success(false); return@setMethodCallHandler
                }
                io.execute {
                    val ok = try {
                        when (call.method) {
                            "saveToGallery" -> insert(ctx, bytes, name) != null
                            "copyImage" -> {
                                val uri = insert(ctx, bytes, name)
                                if (uri != null) {
                                    val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                    cm.setPrimaryClip(ClipData.newUri(ctx.contentResolver, "Assisto photo", uri))
                                    true
                                } else false
                            }
                            "setWallpaper" -> {
                                val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                                if (bmp == null) false else {
                                    val which = when (call.argument<String>("which")) {
                                        "lock" -> WallpaperManager.FLAG_LOCK
                                        "both" -> WallpaperManager.FLAG_SYSTEM or WallpaperManager.FLAG_LOCK
                                        else -> WallpaperManager.FLAG_SYSTEM
                                    }
                                    WallpaperManager.getInstance(ctx).setBitmap(bmp, null, true, which)
                                    true
                                }
                            }
                            else -> false
                        }
                    } catch (e: Exception) {
                        false
                    }
                    android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(ok) }
                }
            }
    }

    private fun insert(ctx: Context, bytes: ByteArray, name: String): Uri? {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            if (Build.VERSION.SDK_INT >= 29) {
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Assisto")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }
        val r = ctx.contentResolver
        val uri = r.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return null
        r.openOutputStream(uri)?.use { it.write(bytes) } ?: return null
        if (Build.VERSION.SDK_INT >= 29) {
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            r.update(uri, values, null, null)
        }
        return uri
    }
}
