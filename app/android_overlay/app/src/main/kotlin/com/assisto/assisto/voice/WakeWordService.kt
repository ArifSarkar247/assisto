package com.assisto.assisto.voice

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.io.File
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Proxy

/**
 * Part 3 — optional "Hey Assisto" wake word. OFF by default; started only from
 * the Assisto Voice settings toggle, never at app launch.
 *
 * ENGINE: Picovoice Porcupine (on-device keyword spotting, ~1% CPU). Audio
 * never leaves the phone. It needs (a) an AccessKey and (b) a "Hey Assisto"
 * keyword file trained in the Picovoice console — both come from the server's
 * Integrations page (key-gated), the keyword file is downloaded on demand.
 *
 * The Porcupine library is called through REFLECTION so this file compiles
 * and the app runs whether or not `ai.picovoice:porcupine-android` is in the
 * Gradle build. Without it, start() honestly answers "engine_missing" and the
 * settings screen says so — nothing is faked.
 *
 * HONESTY: while listening, a persistent notification ("Listening for Hey
 * Assisto", with Stop) is always visible — Android requires it for a
 * microphone foreground service, and it is the right thing to do.
 */
class WakeWordService : Service() {

    companion object {
        private const val CHANNEL_ID = "assisto_wake"
        private const val NOTIF_ID = 7310
        private const val WAKE_NOTIF_ID = 7311
        private const val ACTION_STOP = "com.assisto.assisto.voice.WAKE_STOP"
        private const val PORCUPINE_BUILDER = "ai.picovoice.porcupine.PorcupineManager\$Builder"
        private const val PORCUPINE_CALLBACK = "ai.picovoice.porcupine.PorcupineManagerCallback"

        @Volatile private var running = false
        @Volatile private var lastError: String? = null

        fun engineBundled(): Boolean = try {
            Class.forName(PORCUPINE_BUILDER)
            true
        } catch (ignored: Throwable) {
            false
        }

        fun status(ctx: Context): String = when {
            running -> "running"
            !engineBundled() -> "engine_missing"
            lastError != null -> "error:${lastError}"
            else -> "stopped"
        }

        fun start(
            ctx: Context, accessKey: String, keywordPath: String, sensitivity: Float,
            title: String, body: String, stopLabel: String, tapText: String
        ): String {
            if (!engineBundled()) return "engine_missing"
            if (accessKey.isBlank() || keywordPath.isBlank() || !File(keywordPath).exists()) {
                return "error:config"
            }
            if (ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) return "error:mic"
            return try {
                lastError = null
                val i = Intent(ctx, WakeWordService::class.java)
                    .putExtra("accessKey", accessKey)
                    .putExtra("keywordPath", keywordPath)
                    .putExtra("sensitivity", sensitivity)
                    .putExtra("title", title)
                    .putExtra("body", body)
                    .putExtra("stopLabel", stopLabel)
                    .putExtra("tapText", tapText)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(i)
                } else {
                    ctx.startService(i)
                }
                "running"
            } catch (e: Throwable) {
                lastError = e.javaClass.simpleName
                "error:start"
            }
        }

        fun stop(ctx: Context) {
            try {
                ctx.stopService(Intent(ctx, WakeWordService::class.java))
            } catch (ignored: Throwable) {}
            running = false
        }
    }

    private var manager: Any? = null
    private val main = Handler(Looper.getMainLooper())
    private var lastWake = 0L
    private var tapText = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val title = intent?.getStringExtra("title") ?: "Assisto"
            val body = intent?.getStringExtra("body") ?: ""
            val stopLabel = intent?.getStringExtra("stopLabel") ?: "Stop"
            tapText = intent?.getStringExtra("tapText") ?: ""
            val n = buildNotification(title, body, stopLabel)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIF_ID, n)
            }
            if (manager == null) {
                manager = buildPorcupine(
                    intent?.getStringExtra("accessKey") ?: "",
                    intent?.getStringExtra("keywordPath") ?: "",
                    intent?.getFloatExtra("sensitivity", 0.6f) ?: 0.6f
                )
                manager?.javaClass?.getMethod("start")?.invoke(manager)
            }
            running = manager != null
            if (!running) stopSelf()
        } catch (e: Throwable) {
            lastError = (e.cause ?: e).javaClass.simpleName
            running = false
            stopSelf()
        }
        // Not sticky: if Android kills it, it stays off (no surprise mic use).
        return START_NOT_STICKY
    }

    private fun buildPorcupine(key: String, path: String, sens: Float): Any? {
        val builderCls = Class.forName(PORCUPINE_BUILDER)
        val cbCls = Class.forName(PORCUPINE_CALLBACK)
        var b: Any = builderCls.getConstructor().newInstance()
        b = builderCls.getMethod("setAccessKey", String::class.java).invoke(b, key)!!
        b = builderCls.getMethod("setKeywordPath", String::class.java).invoke(b, path)!!
        b = builderCls.getMethod("setSensitivity", Float::class.javaPrimitiveType).invoke(b, sens)!!
        val handler = InvocationHandler { proxy, method, args ->
            when (method.name) {
                "invoke" -> { main.post { onWake() }; null }
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args?.getOrNull(0)
                "toString" -> "AssistoWakeCallback"
                else -> null
            }
        }
        val cb = Proxy.newProxyInstance(cbCls.classLoader, arrayOf(cbCls), handler)
        return builderCls.getMethod("build", Context::class.java, cbCls)
            .invoke(b, applicationContext, cb)
    }

    private fun onWake() {
        val now = System.currentTimeMillis()
        if (now - lastWake < 3000) return // debounce double triggers
        lastWake = now
        try {
            VoiceLaunchState.mark()
            val open = Intent(this, AssistEntryActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            // Works while Assisto is visible. Android blocks background
            // activity starts on many phones, so ALSO post a tap-to-talk
            // notification — the honest fallback, never a fake "opened".
            try { startActivity(open) } catch (ignored: Throwable) {}
            val pi = PendingIntent.getActivity(
                this, 1, open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val nm = getSystemService(NotificationManager::class.java)
            val b = Notification.Builder(this, CHANNEL_ID) // minSdk 26
            nm?.notify(
                WAKE_NOTIF_ID,
                b.setSmallIcon(applicationInfo.icon)
                    .setContentTitle("Assisto")
                    .setContentText("▶")
                    .setContentIntent(pi)
                    .setAutoCancel(true)
                    .setTimeoutAfter(15000)
                    .build()
            )
        } catch (ignored: Throwable) {}
    }

    private fun buildNotification(title: String, body: String, stopLabel: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm?.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, title, NotificationManager.IMPORTANCE_LOW)
        )
        val stop = PendingIntent.getService(
            this, 2,
            Intent(this, WakeWordService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val b = Notification.Builder(this, CHANNEL_ID) // minSdk 26
        return b.setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    null as android.graphics.drawable.Icon?, stopLabel, stop
                ).build()
            )
            .build()
    }

    override fun onDestroy() {
        try {
            manager?.javaClass?.getMethod("stop")?.invoke(manager)
            manager?.javaClass?.getMethod("delete")?.invoke(manager)
        } catch (ignored: Throwable) {}
        manager = null
        running = false
        super.onDestroy()
    }
}
