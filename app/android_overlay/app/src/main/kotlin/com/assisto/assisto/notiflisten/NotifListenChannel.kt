package com.assisto.assisto.notiflisten

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.service.notification.NotificationListenerService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * callmoney — "com.assisto/notif_listen". Handler only: nothing runs at
 * launch; every method is crash-guarded and answers a safe default.
 */
object NotifListenChannel {
    private const val NAME = "com.assisto/notif_listen"

    fun component(ctx: Context) = ComponentName(ctx, AssistoNotifListener::class.java)

    fun granted(ctx: Context): Boolean = try {
        val flat = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners") ?: ""
        val me = component(ctx)
        flat.split(':').any { ComponentName.unflattenFromString(it)?.let { c -> c == me } == true }
    } catch (_: Throwable) {
        false
    }

    /** The in-app off switch: a disabled component is never bound by Android. */
    private fun setComponentOn(ctx: Context, on: Boolean) {
        val state = if (on) PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
                    else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        ctx.packageManager.setComponentEnabledSetting(component(ctx), state, PackageManager.DONT_KILL_APP)
        if (on && Build.VERSION.SDK_INT >= 24 && granted(ctx)) {
            try { NotificationListenerService.requestRebind(component(ctx)) } catch (_: Throwable) {}
        }
    }

    private fun openSettings(activity: Activity) {
        val detail = if (Build.VERSION.SDK_INT >= 30) Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
            .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, component(activity).flattenToString())
            else null
        for (i in listOfNotNull(detail, Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))) {
            try {
                activity.startActivity(i)
                return
            } catch (_: Throwable) {
            }
        }
    }

    private fun takeLaunch(activity: Activity): Map<String, Any?>? {
        val i = activity.intent ?: return null
        if (i.action != NotifListenCore.ACTION_OPEN) return null
        val out = mapOf(
            "kind" to i.getStringExtra(NotifListenCore.EXTRA_KIND),
            "mode" to i.getStringExtra(NotifListenCore.EXTRA_MODE),
            "source" to i.getStringExtra(NotifListenCore.EXTRA_SOURCE),
            "id" to i.getLongExtra(NotifListenCore.EXTRA_ID, 0L),
            "at" to i.getLongExtra(NotifListenCore.EXTRA_AT, 0L),
        )
        i.action = null // consumed: a resume never re-opens the same card
        if (out["kind"] == "callnote") {
            try {
                activity.getSystemService(android.app.NotificationManager::class.java)
                    ?.cancel(NotifListenCore.CALL_NID)
            } catch (_: Throwable) {}
        }
        return out
    }

    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            try {
                val ctx = activity.applicationContext
                when (call.method) {
                    "status" -> result.success(mapOf(
                        "granted" to granted(ctx),
                        "sdk" to Build.VERSION.SDK_INT,
                        "callnote" to NotifListenCore.callNoteOn(ctx),
                        "money" to NotifListenCore.moneyOn(ctx),
                        "moneyAuto" to NotifListenCore.prefs(ctx).getBoolean("money_auto", false),
                    ))
                    "openAccessSettings" -> { openSettings(activity); result.success(true) }
                    "setConfig" -> {
                        val e = NotifListenCore.prefs(ctx).edit()
                        val cn = call.argument<Boolean>("callnote") == true
                        val mo = call.argument<Boolean>("money") == true
                        e.putBoolean("callnote", cn).putBoolean("money", mo)
                            .putBoolean("money_auto", call.argument<Boolean>("moneyAuto") == true)
                            .putString("lang", call.argument<String>("lang") ?: "bn")
                        val strings = call.argument<Map<String, Any?>>("strings") ?: emptyMap()
                        for ((k, v) in strings) if (v is String) e.putString("s_$k", v)
                        e.apply()
                        if (!mo) NotifListenCore.clearQueue(ctx)
                        try { setComponentOn(ctx, cn || mo) } catch (_: Throwable) {}
                        result.success(true)
                    }
                    "takeMoneyQueue" -> {
                        val q = NotifListenCore.queue(ctx)
                        val out = ArrayList<Map<String, Any?>>()
                        for (k in 0 until q.length()) {
                            val o = q.optJSONObject(k) ?: continue
                            out.add(mapOf("id" to o.optLong("id"), "wallet" to o.optString("wallet"),
                                "kind" to o.optString("kind"), "title" to o.optString("title"),
                                "text" to o.optString("text"), "at" to o.optLong("at")))
                        }
                        result.success(out)
                    }
                    "moneyDone" -> {
                        val ids = (call.argument<List<Any?>>("ids") ?: emptyList())
                            .mapNotNull { (it as? Number)?.toLong() }.toSet()
                        NotifListenCore.removeIds(ctx, ids)
                        result.success(true)
                    }
                    "takeLaunch" -> result.success(takeLaunch(activity))
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                try { result.success(null) } catch (_: Throwable) {}
            }
        }
    }
}
