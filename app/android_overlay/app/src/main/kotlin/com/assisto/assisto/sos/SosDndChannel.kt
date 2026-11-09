package com.assisto.assisto.sos

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * fcsos — SOS alarms that ring through Do Not Disturb, ONLY with the user's
 * permission ("Do Not Disturb access", Settings -> Notifications). Android
 * keeps a channel's "override Do Not Disturb" only when the app that creates
 * the channel holds that access, and a channel's settings are fixed once
 * created — so after the user grants it we create a SECOND SOS channel
 * ("sos_dnd_v1") with bypassDnd + the alarm sound, and Dart draws SOS
 * notifications on it from then on (pref set by Dart). Without the access
 * nothing changes: the old "sos" channel (alarm category + alarm audio) is
 * used, which Android already lets through "Alarms" in priority-only DND.
 *
 * Channel "com.assisto/sos_dnd":
 *   granted()                       -> Bool   NotificationManager.isNotificationPolicyAccessGranted
 *   openSettings()                  -> Bool   ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS
 *   ensureChannel({name, desc})     -> Bool   true when the bypass channel exists WITH bypass
 *
 * Lazy (handler registration only) and crash-guarded: any vendor quirk
 * returns false instead of throwing. Needs the normal (install-time)
 * permission ACCESS_NOTIFICATION_POLICY — no Play declaration.
 */
object SosDndChannel {
    private const val NAME = "com.assisto/sos_dnd"
    const val CHANNEL_ID = "sos_dnd_v1"

    fun register(engine: FlutterEngine, activity: Activity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, NAME)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "granted" -> result.success(granted(activity))
                    "openSettings" -> result.success(openSettings(activity))
                    "ensureChannel" -> result.success(
                        ensureChannel(activity,
                            call.argument<String>("name") ?: "SOS",
                            call.argument<String>("desc") ?: ""))
                    else -> result.notImplemented()
                }
            }
    }

    private fun nm(ctx: Context): NotificationManager? =
        ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    fun granted(ctx: Context): Boolean = try {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            (nm(ctx)?.isNotificationPolicyAccessGranted ?: false)
    } catch (t: Throwable) {
        false
    }

    private fun openSettings(a: Activity): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            a.startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))
            true
        } else false
    } catch (t: Throwable) {
        false
    }

    fun ensureChannel(ctx: Context, name: String, desc: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return granted(ctx)
        return try {
            val m = nm(ctx) ?: return false
            val have = m.getNotificationChannel(CHANNEL_ID)
            if (have != null && have.canBypassDnd()) return true
            if (!granted(ctx)) return false
            // re-create once with the access in place (a channel created
            // without it lost the bypass flag)
            if (have != null) m.deleteNotificationChannel(CHANNEL_ID)
            val ch = NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_HIGH)
            ch.description = desc
            ch.setBypassDnd(true)
            ch.lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            ch.enableVibration(true)
            ch.setSound(
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                    ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build())
            m.createNotificationChannel(ch)
            m.getNotificationChannel(CHANNEL_ID)?.canBypassDnd() ?: false
        } catch (t: Throwable) {
            false
        }
    }
}
