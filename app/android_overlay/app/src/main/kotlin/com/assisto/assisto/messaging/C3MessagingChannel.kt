package com.assisto.assisto.messaging

import android.app.Activity
import android.app.NotificationManager
import android.content.ContentValues
import android.content.Intent
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import java.io.File
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * c3-msg — "com.assisto/c3_messaging" (UI engines only: MainActivity +
 * BubbleActivity). Handler registration is free; nothing runs until Dart
 * calls. Every method is crash-guarded and answers honestly (false/null).
 *
 *   pickSound({current})   -> {uri, title} | null   phone's own sound picker
 *   bubblesSupported()     -> Bool                   Android 11+
 *   bubblesAllowed()       -> Bool?                  system bubble setting
 *   openBubbleSettings()   -> Bool
 *   takeLaunchChat()       -> "member:12" | null     (bubble / shortcut tap)
 *   inBubble()             -> Bool
 *   removeBubble({chat})   -> null                   drop the shortcut
 *   md1 (My Circle E2E media; all lazy, nothing at launch):
 *   isMetered()            -> Bool?                  mobile data / metered Wi-Fi
 *   pickDocument({max})    -> {path,name,size,mime} | {error,size,name} | null
 *                             phone's own document picker; copied (off the
 *                             main thread) into cacheDir/md1_pick
 *   saveToPhone({path,mime,name}) -> "ok" | "unsupported" (< Android 10) | "error"
 *                             images -> Pictures/Assisto, other -> Download/Assisto
 * Native → Dart: "openChat"(key) when a shortcut/bubble intent arrives while
 * the app is already running.
 */
object C3MessagingChannel {
    private const val NAME = "com.assisto/c3_messaging"
    private const val REQ_SOUND = 0xC3
    private const val REQ_DOC = 0xC4
    private var pendingSound: MethodChannel.Result? = null
    private var pendingDoc: MethodChannel.Result? = null
    private var pendingDocMax: Long = 0L
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null

    fun register(activity: Activity, engine: FlutterEngine, inBubble: Boolean = false) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, NAME)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "pickSound" -> pickSound(activity, call.argument<String>("current"), result)
                    "bubblesSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                    "bubblesAllowed" -> result.success(bubblesAllowed(activity))
                    "openBubbleSettings" -> result.success(openBubbleSettings(activity))
                    "takeLaunchChat" -> {
                        val key = activity.intent?.getStringExtra(BubbleHelper.EXTRA_CHAT)
                        activity.intent?.removeExtra(BubbleHelper.EXTRA_CHAT)
                        result.success(key)
                    }
                    "inBubble" -> result.success(inBubble)
                    "removeBubble" -> {
                        BubbleHelper.removeChat(activity, call.argument<String>("chat") ?: "")
                        result.success(null)
                    }
                    "isMetered" -> result.success(isMetered(activity))
                    "pickDocument" -> pickDocument(
                        activity, (call.argument<Number>("max") ?: 0).toLong(), result)
                    "saveToPhone" -> saveToPhone(
                        activity,
                        call.argument<String>("path") ?: "",
                        call.argument<String>("mime") ?: "application/octet-stream",
                        call.argument<String>("name") ?: "file",
                        result)
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.success(null)
            }
        }
    }

    fun onNewIntent(intent: Intent?) {
        try {
            val key = intent?.getStringExtra(BubbleHelper.EXTRA_CHAT) ?: return
            intent.removeExtra(BubbleHelper.EXTRA_CHAT)
            channel?.invokeMethod("openChat", key)
        } catch (t: Throwable) {
        }
    }

    private fun pickSound(activity: Activity, current: String?, result: MethodChannel.Result) {
        try {
            pendingSound?.success(null)
            pendingSound = result
            val i = Intent(RingtoneManager.ACTION_RINGTONE_PICKER)
                .putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE, RingtoneManager.TYPE_NOTIFICATION)
                .putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
                .putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, false)
                .putExtra(
                    RingtoneManager.EXTRA_RINGTONE_DEFAULT_URI,
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                )
            if (!current.isNullOrEmpty()) {
                i.putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI, Uri.parse(current))
            }
            activity.startActivityForResult(i, REQ_SOUND)
        } catch (t: Throwable) {
            pendingSound = null
            result.success(null)
        }
    }

    // ---- md1 -------------------------------------------------------------

    private fun isMetered(activity: Activity): Boolean? {
        return try {
            val cm = activity.getSystemService(ConnectivityManager::class.java) ?: return null
            cm.isActiveNetworkMetered
        } catch (t: Throwable) {
            null
        }
    }

    private fun pickDocument(activity: Activity, max: Long, result: MethodChannel.Result) {
        try {
            pendingDoc?.success(null)
            pendingDoc = result
            pendingDocMax = max
            val i = Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*")
            activity.startActivityForResult(i, REQ_DOC)
        } catch (t: Throwable) {
            pendingDoc = null
            result.success(null)
        }
    }

    private fun onDocResult(activity: Activity, resultCode: Int, data: Intent?) {
        val r = pendingDoc ?: return
        pendingDoc = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            r.success(null)
            return
        }
        val max = pendingDocMax
        val app = activity.applicationContext
        // Copy OFF the main thread (a 25 MB file must never freeze the UI).
        Thread {
            val out: Map<String, Any?>? = try {
                var name = "file"
                var size = -1L
                app.contentResolver.query(uri, null, null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val si = c.getColumnIndex(OpenableColumns.SIZE)
                        if (ni >= 0) name = c.getString(ni) ?: name
                        if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                    }
                }
                name = name.replace('/', '_').replace('\\', '_')
                val mime = app.contentResolver.getType(uri) ?: "application/octet-stream"
                if (max > 0 && size > max) {
                    mapOf("error" to "too_big", "size" to size, "name" to name)
                } else {
                    val dir = File(app.cacheDir, "md1_pick").apply { mkdirs() }
                    val dst = File(dir, "${System.currentTimeMillis()}.bin")
                    var copied = 0L
                    var tooBig = false
                    app.contentResolver.openInputStream(uri)?.use { input ->
                        dst.outputStream().use { o ->
                            val buf = ByteArray(64 * 1024)
                            while (true) {
                                val n = input.read(buf)
                                if (n < 0) break
                                copied += n
                                if (max > 0 && copied > max) {
                                    tooBig = true
                                    break
                                }
                                o.write(buf, 0, n)
                            }
                        }
                    }
                    if (tooBig) {
                        dst.delete()
                        mapOf("error" to "too_big", "size" to copied, "name" to name)
                    } else {
                        mapOf("path" to dst.absolutePath, "name" to name,
                            "size" to dst.length(), "mime" to mime)
                    }
                }
            } catch (t: Throwable) {
                mapOf("error" to "failed")
            }
            main.post {
                try {
                    r.success(out)
                } catch (t: Throwable) {
                }
            }
        }.start()
    }

    private fun saveToPhone(
        activity: Activity, path: String, mime: String, name: String,
        result: MethodChannel.Result
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success("unsupported") // older phones: Dart offers Share
            return
        }
        val app = activity.applicationContext
        Thread {
            val status = try {
                val src = File(path)
                if (!src.isFile) {
                    "error"
                } else {
                    val image = mime.startsWith("image/")
                    val values = ContentValues().apply {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                        put(MediaStore.MediaColumns.MIME_TYPE, mime)
                        put(MediaStore.MediaColumns.RELATIVE_PATH,
                            (if (image) Environment.DIRECTORY_PICTURES
                             else Environment.DIRECTORY_DOWNLOADS) + "/Assisto")
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                    val coll = if (image)
                        MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                    else
                        MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                    val dst = app.contentResolver.insert(coll, values)
                    if (dst == null) {
                        "error"
                    } else {
                        app.contentResolver.openOutputStream(dst)?.use { o ->
                            src.inputStream().use { it.copyTo(o, 64 * 1024) }
                        }
                        val done = ContentValues().apply {
                            put(MediaStore.MediaColumns.IS_PENDING, 0)
                        }
                        app.contentResolver.update(dst, done, null, null)
                        "ok"
                    }
                }
            } catch (t: Throwable) {
                "error"
            }
            main.post {
                try {
                    result.success(status)
                } catch (t: Throwable) {
                }
            }
        }.start()
    }

    /** MainActivity.onActivityResult forwards here; true = consumed. */
    fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQ_DOC) {
            try {
                onDocResult(activity, resultCode, data)
            } catch (t: Throwable) {
                pendingDoc?.success(null)
                pendingDoc = null
            }
            return true
        }
        if (requestCode != REQ_SOUND) return false
        val r = pendingSound ?: return true
        pendingSound = null
        try {
            if (resultCode != Activity.RESULT_OK) {
                r.success(null)
                return true
            }
            @Suppress("DEPRECATION")
            val uri: Uri? = data?.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
            val def = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            if (uri == null || uri == def || uri == Settings.System.DEFAULT_NOTIFICATION_URI) {
                r.success(mapOf("uri" to "", "title" to ""))
                return true
            }
            val title = try {
                RingtoneManager.getRingtone(activity, uri)?.getTitle(activity) ?: ""
            } catch (t: Throwable) {
                ""
            }
            r.success(mapOf("uri" to uri.toString(), "title" to title))
        } catch (t: Throwable) {
            r.success(null)
        }
        return true
    }

    private fun bubblesAllowed(activity: Activity): Boolean? {
        return try {
            val nm = activity.getSystemService(NotificationManager::class.java) ?: return null
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
                    nm.bubblePreference != NotificationManager.BUBBLE_PREFERENCE_NONE
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> {
                    @Suppress("DEPRECATION")
                    nm.areBubblesAllowed()
                }
                else -> false
            }
        } catch (t: Throwable) {
            null
        }
    }

    private fun openBubbleSettings(activity: Activity): Boolean {
        return try {
            val i = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Intent(Settings.ACTION_APP_NOTIFICATION_BUBBLE_SETTINGS)
            } else {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            }.putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(i)
            true
        } catch (t: Throwable) {
            false
        }
    }
}
