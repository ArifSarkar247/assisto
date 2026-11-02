package com.assisto.assisto.calls

import android.app.Activity
import android.app.AppOpsManager
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Process
import android.provider.Settings
import android.util.Rational

/**
 * callpip (owner phone test 2 Nov): picture-in-picture + "leave the app"
 * for a live call. EXECUTES ONLY — every decision (when to auto-enter, the
 * window's shape, which buttons, the background-camera pause) is made in
 * Dart (app/lib/calls/call_pip.dart, tested in CI). Lazy: nothing is
 * created until Dart asks; every path is crash-guarded (false = not
 * possible on this phone). No SYSTEM_ALERT_WINDOW.
 */
object CallPip {
    private const val ACTION_PIP = "com.assisto.assisto.CALL_PIP_ACTION"
    private const val EXTRA_ID = "id"
    private const val EXTRA_TOKEN = "token"
    const val EXTRA_RETURN = "assisto_call_return"
    private const val ACTION_RETURN = "com.assisto.assisto.CALL_RETURN"
    private const val REQ_PIP_BASE = 0x5a30
    private const val REQ_RETURN = 0x5a22
    private const val REQ_END = 0x5a23

    @Volatile var autoOn = false
        private set
    var w = 9
        private set
    var h = 16
        private set
    private var actions: List<Map<String, Any?>> = emptyList()
    private var receiver: BroadcastReceiver? = null
    private var receiverCtx: Context? = null
    private val token: String = java.util.UUID.randomUUID().toString()

    /** Dart callback for a PiP button: "mute" | "camera" | "end". */
    var onAction: ((String) -> Unit)? = null

    fun supported(a: Activity?): Boolean {
        if (a == null) return false
        return try {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                a.packageManager.hasSystemFeature(
                    android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE)
        } catch (e: Throwable) {
            false
        }
    }

    private fun drawable(c: Context, name: String): Int = try {
        c.resources.getIdentifier(name, "drawable", c.packageName)
    } catch (e: Throwable) {
        0
    }

    private fun iconFor(id: String, on: Boolean): String = when (id) {
        "mute" -> if (on) "ic_pip_mic_off" else "ic_pip_mic"
        "camera" -> if (on) "ic_pip_videocam" else "ic_pip_videocam_off"
        else -> "ic_pip_call_end"
    }

    private fun remoteActions(a: Activity): List<RemoteAction> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return emptyList()
        val out = ArrayList<RemoteAction>()
        val max = try { a.maxNumPictureInPictureActions } catch (e: Throwable) { 3 }
        for ((i, m) in actions.withIndex()) {
            if (out.size >= max) break
            try {
                val id = m["id"] as? String ?: continue
                val on = m["on"] == true
                val label = (m["label"] as? String)?.takeIf { it.isNotBlank() } ?: id
                val res = drawable(a, iconFor(id, on))
                val icon = if (res != 0) Icon.createWithResource(a, res)
                    else Icon.createWithResource(a, a.applicationInfo.icon)
                val intent = Intent(ACTION_PIP).setPackage(a.packageName)
                    .putExtra(EXTRA_ID, id).putExtra(EXTRA_TOKEN, token)
                val pi = PendingIntent.getBroadcast(a, REQ_PIP_BASE + i, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                out.add(RemoteAction(icon, label, label, pi))
            } catch (ignored: Throwable) {}
        }
        return out
    }

    private fun params(a: Activity, auto: Boolean): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val b = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(w.coerceIn(1, 100), h.coerceIn(1, 100)))
        try { b.setActions(remoteActions(a)) } catch (ignored: Throwable) {}
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                b.setAutoEnterEnabled(auto)
                // video content: no seamless resize (no stretched frame)
                b.setSeamlessResizeEnabled(!auto)
            } catch (ignored: Throwable) {}
        }
        return b.build()
    }

    private fun listen(a: Activity, on: Boolean) {
        try {
            if (!on) {
                receiver?.let { r -> try { receiverCtx?.unregisterReceiver(r) } catch (ignored: Throwable) {} }
                receiver = null
                receiverCtx = null
                return
            }
            if (receiver != null) return
            val r = object : BroadcastReceiver() {
                override fun onReceive(c: Context?, i: Intent?) {
                    try {
                        if (i?.getStringExtra(EXTRA_TOKEN) != token) return
                        val id = i.getStringExtra(EXTRA_ID) ?: return
                        onAction?.invoke(id)
                    } catch (ignored: Throwable) {}
                }
            }
            val app = a.applicationContext
            val f = IntentFilter(ACTION_PIP)
            if (Build.VERSION.SDK_INT >= 33) {
                app.registerReceiver(r, f, Context.RECEIVER_NOT_EXPORTED)
            } else {
                app.registerReceiver(r, f)
            }
            receiver = r
            receiverCtx = app
        } catch (ignored: Throwable) {}
    }

    /** Dart: the live call's PiP state (auto-enter, shape, buttons). */
    fun set(a: Activity?, on: Boolean, ww: Int, hh: Int, acts: List<Map<String, Any?>>?): Boolean {
        autoOn = on
        w = ww.coerceIn(1, 100)
        h = hh.coerceIn(1, 100)
        actions = acts ?: emptyList()
        if (a == null || !supported(a)) return false
        listen(a, on)
        return try {
            val p = params(a, on) ?: return false
            a.setPictureInPictureParams(p) // also updates an open PiP window
            true
        } catch (e: Throwable) {
            false
        }
    }

    fun enter(a: Activity?): Boolean {
        if (a == null || !supported(a)) return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && a.isInPictureInPictureMode) return true
            val p = params(a, autoOn) ?: return false
            a.enterPictureInPictureMode(p)
        } catch (e: Throwable) {
            false
        }
    }

    /** Home / Recents on API 26-30 (31+ auto-enters via the params). */
    fun onUserLeaveHint(a: Activity?) {
        try {
            if (autoOn && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enter(a)
        } catch (ignored: Throwable) {}
    }

    /** Back on Assisto's last screen during a call: PiP for a live video
     *  call, else to the background. NEVER finish() — that would end the
     *  Flutter engine and the call with it. */
    fun leaveApp(a: Activity?, pip: Boolean): Boolean {
        if (a == null) return false
        if (pip && enter(a)) return true
        return try {
            a.moveTaskToBack(true)
        } catch (e: Throwable) {
            false
        }
    }

    /** The ongoing-call foreground notification (flutter_foreground_task's,
     *  same id) re-posted with "Return to call" (an ACTIVITY PendingIntent —
     *  Android 12+ blocks starting an activity from a broadcast) and "End
     *  call" (the plugin's own button broadcast -> the Dart hang-up). */
    fun decorateOngoing(c: Context?, args: Map<String, Any?>): Boolean {
        if (c == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val id = (args["id"] as? Int) ?: return false
            val channel = args["channel"] as? String ?: return false
            val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(channel) == null) return false
            val launch = c.packageManager.getLaunchIntentForPackage(c.packageName) ?: return false
            // same pattern as the proven warm call tap (IncomingCall.launchIntent):
            // the launcher intent with OUR action -> the running MainActivity
            // gets onNewIntent (never a second activity / engine)
            launch.setAction(ACTION_RETURN)
            launch.putExtra(EXTRA_RETURN, true)
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val ret = PendingIntent.getActivity(c, REQ_RETURN, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            // flutter_foreground_task's button broadcast (its receiver runs
            // inside the service and forwards the id to the Dart task handler)
            val endIntent = Intent("onNotificationButtonPressed").setPackage(c.packageName)
                .putExtra("intentData", args["endId"] as? String ?: "call_hangup")
            val end = PendingIntent.getBroadcast(c, REQ_END, endIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            var small = drawable(c, "ic_stat_assisto")
            if (small == 0) small = c.applicationInfo.icon
            val b = Notification.Builder(c, channel)
                .setSmallIcon(small)
                .setContentTitle(args["title"] as? String ?: "")
                .setContentText(args["text"] as? String ?: "")
                .setContentIntent(ret)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_CALL)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(Notification.Action.Builder(null, args["return"] as? String ?: "Return", ret).build())
                .addAction(Notification.Action.Builder(null, args["end"] as? String ?: "End", end).build())
            val since = (args["since"] as? Number)?.toLong()
            if (since != null && since > 0) {
                b.setWhen(since).setShowWhen(true).setUsesChronometer(true)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
            nm.notify(id, b.build())
            true
        } catch (e: Throwable) {
            false
        }
    }

    /** Is picture-in-picture switched ON for Assisto (Settings -> Special
     *  app access -> Picture-in-picture; some OEMs ship it off)? null = this
     *  phone has no PiP at all (Android Go) or it can't tell. */
    fun allowed(a: Activity?): Boolean? {
        if (a == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        if (!supported(a)) return null
        return try {
            val ops = a.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val op = "android:picture_in_picture"
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ops.unsafeCheckOpNoThrow(op, Process.myUid(), a.packageName)
            } else {
                @Suppress("DEPRECATION")
                ops.checkOpNoThrow(op, Process.myUid(), a.packageName)
            }
            mode != AppOpsManager.MODE_IGNORED && mode != AppOpsManager.MODE_ERRORED
        } catch (e: Throwable) {
            null
        }
    }

    /** Opens Assisto's picture-in-picture switch (else the app's settings). */
    fun openSettings(a: Activity?): Boolean {
        if (a == null) return false
        val uri = Uri.parse("package:" + a.packageName)
        for (action in listOf("android.settings.PICTURE_IN_PICTURE_SETTINGS",
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS)) {
            try {
                a.startActivity(Intent(action, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (ignored: Throwable) {}
        }
        return false
    }

    /** "Return to call" tapped (MainActivity.onNewIntent). */
    fun isReturn(i: Intent?): Boolean = try {
        i?.action == ACTION_RETURN || i?.getBooleanExtra(EXTRA_RETURN, false) == true
    } catch (e: Throwable) {
        false
    }

    fun release() {
        autoOn = false
        actions = emptyList()
        onAction = null
        try {
            receiver?.let { r -> receiverCtx?.unregisterReceiver(r) }
        } catch (ignored: Throwable) {}
        receiver = null
        receiverCtx = null
    }
}
