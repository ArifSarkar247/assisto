package com.assisto.assisto.calls

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * circle-screenshare — the foreground service Android needs while the screen
 * is shared in a My Circle video call (MediaProjection). Declared in the CI
 * manifest patch with foregroundServiceType="mediaProjection" + the normal
 * (install-time) permission FOREGROUND_SERVICE_MEDIA_PROJECTION.
 *
 * Lifecycle (driven by ScreenShareChannel, from Dart):
 *   1. Share screen -> our consent sheet -> Continue,
 *   2. the SYSTEM consent dialog (flutter_webrtc requestCapturePermission),
 *   3. ONLY after the user allowed it: this service starts and calls
 *      startForeground with the mediaProjection type (Android 14 throws if
 *      there is no consent yet — caught, Dart is told "false"),
 *   4. then getDisplayMedia creates the projection; the call sends it,
 *   5. Stop (call screen, this notification's Stop, the call ending, or
 *      Android ending the projection — status-bar chip, screen lock) stops
 *      the capture first and this service last.
 * Started with startService while Assisto is in front (the user just tapped
 * Continue), so a refused startForeground can never become the "did not
 * call startForeground in time" crash. Never started at launch, never
 * restarts itself (START_NOT_STICKY).
 *
 * Android ending the projection: flutter_webrtc's MediaProjection callback
 * does nothing, so this service watches its own virtual display
 * ("WebRTC_ScreenCapture", visible to the app that made it). Seen once, then
 * gone for 2 s (a rotation re-creates it within milliseconds) = ended ->
 * Dart gets stopRequested("system") and the call goes back to the camera.
 */
class ScreenShareService : Service() {

    private val main = Handler(Looper.getMainLooper())
    private var seenDisplay = false
    private var missingTicks = 0
    private var ticks = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // the notification's "Stop sharing": Dart stops the capture and
            // then this service (ScreenShareChannel.stop)
            try {
                ScreenShareChannel.onStopRequested("user")
            } catch (_: Throwable) {
            }
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Sharing your screen"
        val body = intent?.getStringExtra(EXTRA_BODY) ?: ""
        val stop = intent?.getStringExtra(EXTRA_STOP) ?: "Stop sharing"
        return try {
            val n = buildNotification(this, title, body, stop)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIF_ID, n,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            } else {
                startForeground(NOTIF_ID, n)
            }
            running = true
            startWatch()
            START_NOT_STICKY
        } catch (t: Throwable) {
            // e.g. no consent yet on Android 14 -> refuse, never crash
            running = false
            lastError = t.javaClass.simpleName
            try {
                stopSelf()
            } catch (_: Throwable) {
            }
            START_NOT_STICKY
        }
    }

    private val watch = object : Runnable {
        override fun run() {
            if (!running) return
            try {
                val dm = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
                val there = dm.displays.any { it.name == CAPTURE_DISPLAY }
                ticks++
                if (there) {
                    seenDisplay = true
                    missingTicks = 0
                } else if (seenDisplay) {
                    missingTicks++
                    if (missingTicks >= 4) { // 4 x 500 ms
                        seenDisplay = false
                        ScreenShareChannel.onStopRequested("system")
                        return
                    }
                } else if (ticks > 120) {
                    // never saw it in 60 s (an OEM names it differently):
                    // stop watching rather than guess
                    return
                }
            } catch (_: Throwable) {
                return
            }
            main.postDelayed(this, 500)
        }
    }

    private fun startWatch() {
        seenDisplay = false
        missingTicks = 0
        ticks = 0
        main.removeCallbacks(watch)
        main.postDelayed(watch, 500)
    }

    override fun onDestroy() {
        running = false
        main.removeCallbacks(watch)
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // the app was swiped away: no sharing without the call
        try {
            stopSelf()
        } catch (_: Throwable) {
        }
        super.onTaskRemoved(rootIntent)
    }

    companion object {
        const val CHANNEL_ID = "assisto_screen_share"
        const val NOTIF_ID = 47120
        const val ACTION_START = "com.assisto.assisto.SCREEN_SHARE_START"
        const val ACTION_STOP = "com.assisto.assisto.SCREEN_SHARE_STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_STOP = "stop"

        /** flutter_webrtc OrientationAwareScreenCapturer's display name. */
        const val CAPTURE_DISPLAY = "WebRTC_ScreenCapture"

        @Volatile
        var running = false

        @Volatile
        var lastError = ""

        private fun buildNotification(ctx: Context, title: String, body: String,
                                      stop: String): Notification {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                nm.createNotificationChannel(NotificationChannel(
                    CHANNEL_ID, stop, NotificationManager.IMPORTANCE_LOW
                ).apply { setShowBadge(false) })
            }
            val immutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_IMMUTABLE else 0
            val stopPi = PendingIntent.getService(
                ctx, 47121,
                Intent(ctx, ScreenShareService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or immutable)
            val tap = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            val tapPi = if (tap != null) PendingIntent.getActivity(
                ctx, 47122, tap, PendingIntent.FLAG_UPDATE_CURRENT or immutable) else null
            val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(ctx, CHANNEL_ID) else
                @Suppress("DEPRECATION") Notification.Builder(ctx)
            b.setSmallIcon(ctx.applicationInfo.icon)
                .setContentTitle(title)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_CALL)
            if (body.isNotBlank()) b.setContentText(body)
            if (tapPi != null) b.setContentIntent(tapPi)
            @Suppress("DEPRECATION")
            b.addAction(Notification.Action.Builder(0, stop, stopPi).build())
            return b.build()
        }

        /** Start the service (AFTER the user's MediaProjection consent). */
        fun start(ctx: Context, title: String, body: String, stop: String): Boolean {
            return try {
                lastError = ""
                val i = Intent(ctx, ScreenShareService::class.java)
                    .setAction(ACTION_START)
                    .putExtra(EXTRA_TITLE, title)
                    .putExtra(EXTRA_BODY, body)
                    .putExtra(EXTRA_STOP, stop)
                try {
                    // Assisto is in front (the user just allowed sharing)
                    ctx.startService(i)
                } catch (_: IllegalStateException) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        ctx.startForegroundService(i)
                    } else {
                        throw IllegalStateException("background")
                    }
                }
                true
            } catch (t: Throwable) {
                lastError = t.javaClass.simpleName
                false
            }
        }

        fun stop(ctx: Context) {
            try {
                ctx.stopService(Intent(ctx, ScreenShareService::class.java))
            } catch (_: Throwable) {
            }
            running = false
        }
    }
}
