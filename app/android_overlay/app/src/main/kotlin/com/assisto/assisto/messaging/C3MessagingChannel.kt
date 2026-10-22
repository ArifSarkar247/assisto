package com.assisto.assisto.messaging

import android.app.Activity
import android.app.NotificationManager
import android.content.Intent
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
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
 * Native → Dart: "openChat"(key) when a shortcut/bubble intent arrives while
 * the app is already running.
 */
object C3MessagingChannel {
    private const val NAME = "com.assisto/c3_messaging"
    private const val REQ_SOUND = 0xC3
    private var pendingSound: MethodChannel.Result? = null
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

    /** MainActivity.onActivityResult forwards here; true = consumed. */
    fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?): Boolean {
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
