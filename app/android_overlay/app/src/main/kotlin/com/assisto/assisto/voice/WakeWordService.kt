package com.assisto.assisto.voice

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.media.ToneGenerator
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import org.json.JSONObject
import java.io.File

/**
 * k1-wake — optional hands-free "Hey Assisto". OFF by default; started ONLY
 * from Settings → Assisto Voice after the prominent disclosure (or, when the
 * user left it on, again when they open Assisto). Never started by native
 * code at app launch, never from boot: Android 14+ forbids a microphone
 * foreground service from BOOT_COMPLETED, so [WakeBootReceiver] only posts a
 * one-tap "Turn on Hey Assisto again" notification.
 *
 * ENGINE: [OwwEngine] — the openWakeWord recipe with OUR OWN model (ONNX
 * Runtime, on-device). Audio is read in 80 ms chunks into a small ring buffer
 * and dropped; nothing is stored or uploaded. Only after a detection does the
 * normal Assisto Voice screen open.
 *
 * AUTO-PAUSE (no extra permissions): battery < 15 % and not charging (resume
 * at ≥ 20 % or when charging); a phone / VoIP / WebRTC call (AudioManager
 * mode IN_CALL / IN_COMMUNICATION / RINGTONE / CALL_SCREENING); another app
 * recording (AudioRecordingCallback, plus our capture being silenced on
 * Android 10+); the user's "Pause 1 h"; and while Assisto Voice listens after
 * a wake. While paused the microphone is RELEASED.
 *
 * The persistent notification is always visible while the service runs, with
 * "Pause 1 h" (or "Resume") and "Turn off".
 */
class WakeWordService : Service() {

    companion object {
        private const val CHANNEL_ID = "assisto_wake"
        private const val NOTIF_ID = 7310
        private const val WAKE_NOTIF_ID = 7311
        const val RESUME_NOTIF_ID = 7312
        private const val ACTION_START = "com.assisto.assisto.voice.WAKE_START"
        private const val ACTION_PAUSE = "com.assisto.assisto.voice.WAKE_PAUSE"
        private const val ACTION_RESUME = "com.assisto.assisto.voice.WAKE_RESUME"
        private const val ACTION_OFF = "com.assisto.assisto.voice.WAKE_OFF"
        private const val PREFS = "assisto_wake"
        const val LOW_BATTERY = 15
        const val RESUME_BATTERY = 20

        // stopped | listening | paused | error
        @Volatile var state: String = "stopped"
        // battery | call | mic_busy | user | wake | fgs_blocked | mic_blocked | engine:<x>
        @Volatile var reason: String = ""
        @Volatile var pausedUntil: Long = 0L

        fun prefs(ctx: Context): SharedPreferences =
            ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun engineBundled(): Boolean = try {
            Class.forName("ai.onnxruntime.OrtEnvironment")
            true
        } catch (ignored: Throwable) {
            false
        }

        fun status(ctx: Context): Map<String, Any?> = mapOf(
            "state" to (if (!engineBundled()) "engine_missing" else state),
            "reason" to reason,
            "pausedUntil" to pausedUntil,
            "wanted" to prefs(ctx).getBoolean("wanted", false),
            "level" to (prefs(ctx).getString("level", "normal") ?: "normal"),
        )

        /**
         * Save the config (JSON from Dart: files, sha256, backend,
         * windowSamples, frames, thresholds, level, texts) and start the
         * foreground service. MUST be called while Assisto is visible
         * (Android's while-in-use microphone rule).
         * Returns "running" | "engine_missing" | "error:<why>".
         */
        fun start(ctx: Context, configJson: String): String {
            if (!engineBundled()) return "engine_missing"
            if (ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) return "error:mic"
            return try {
                val cfg = JSONObject(configJson)
                val files = cfg.getJSONObject("files")
                val sha = cfg.optJSONObject("sha256") ?: JSONObject()
                for (k in files.keys()) {
                    val p = files.getString(k)
                    if (!File(p).isFile) return "error:model_missing"
                    val want = sha.optString(k, "")
                    if (want.isNotEmpty() && !want.equals(OwwEngine.sha256(p), ignoreCase = true)) {
                        return "error:model_hash"
                    }
                }
                prefs(ctx).edit()
                    .putString("config", configJson)
                    .putBoolean("wanted", true)
                    .putString("level", cfg.optString("level", "normal"))
                    .apply()
                cancelResumeNotification(ctx)
                val i = Intent(ctx, WakeWordService::class.java).setAction(ACTION_START)
                ctx.startForegroundService(i) // minSdk 26
                "running"
            } catch (e: Throwable) {
                reason = e.javaClass.simpleName
                "error:start"
            }
        }

        /** "Turn off": stops and forgets the user's choice. */
        fun stop(ctx: Context) {
            try { prefs(ctx).edit().putBoolean("wanted", false).apply() } catch (ignored: Throwable) {}
            try { ctx.stopService(Intent(ctx, WakeWordService::class.java)) } catch (ignored: Throwable) {}
            cancelResumeNotification(ctx)
            state = "stopped"
            reason = ""
        }

        fun pause(ctx: Context, minutes: Int) = send(ctx, ACTION_PAUSE, minutes)
        fun resume(ctx: Context) = send(ctx, ACTION_RESUME, 0)

        private fun send(ctx: Context, action: String, minutes: Int) {
            if (state == "stopped" || state == "error") return
            try {
                ctx.startService(
                    Intent(ctx, WakeWordService::class.java).setAction(action).putExtra("minutes", minutes)
                )
            } catch (ignored: Throwable) {}
        }

        fun cancelResumeNotification(ctx: Context) {
            try {
                ctx.getSystemService(NotificationManager::class.java)?.cancel(RESUME_NOTIF_ID)
            } catch (ignored: Throwable) {}
        }

        /** One-tap "Turn on Hey Assisto again" (after reboot / when blocked). */
        fun postResumeNotification(ctx: Context) {
            try {
                val p = prefs(ctx)
                if (!p.getBoolean("wanted", false)) return
                val t = try {
                    JSONObject(p.getString("config", "{}") ?: "{}").optJSONObject("texts")
                } catch (e: Throwable) { null }
                val title = t?.optString("resumeTitle")?.takeIf { it.isNotEmpty() } ?: "Hey Assisto"
                val body = t?.optString("resumeBody")?.takeIf { it.isNotEmpty() } ?: ""
                val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
                ensureChannel(nm, t?.optString("channel")?.takeIf { it.isNotEmpty() } ?: "Hey Assisto")
                val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
                    ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    ?.putExtra("assisto_wake_resume", true) ?: return
                val pi = PendingIntent.getActivity(
                    ctx, 4, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                nm.notify(
                    RESUME_NOTIF_ID,
                    Notification.Builder(ctx, CHANNEL_ID)
                        .setSmallIcon(ctx.applicationInfo.icon)
                        .setContentTitle(title)
                        .setContentText(body)
                        .setStyle(Notification.BigTextStyle().bigText(body))
                        .setContentIntent(pi)
                        .setAutoCancel(true)
                        .build()
                )
            } catch (ignored: Throwable) {}
        }

        private fun ensureChannel(nm: NotificationManager, name: String) {
            try {
                if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                    nm.createNotificationChannel(
                        NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_LOW)
                    )
                }
            } catch (ignored: Throwable) {}
        }
    }

    private val main = Handler(Looper.getMainLooper())
    @Volatile private var alive = false
    @Volatile private var gen = 0
    @Volatile private var autoReason = ""   // battery | call | mic_busy | ""
    @Volatile private var userPausedUntil = 0L
    @Volatile private var wakeHoldUntil = 0L // elapsedRealtime
    @Volatile private var mySession = -1
    private var audioThread: Thread? = null
    private var texts: JSONObject = JSONObject()
    private var cfg: JSONObject = JSONObject()
    private var recCallback: AudioManager.AudioRecordingCallback? = null
    private var lowBattery = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            when (intent?.action) {
                ACTION_OFF -> {
                    stop(this)
                    stopSelf()
                    return START_NOT_STICKY
                }
                ACTION_PAUSE -> {
                    val min = (intent?.getIntExtra("minutes", 60) ?: 60).coerceIn(1, 24 * 60)
                    userPausedUntil = System.currentTimeMillis() + min * 60_000L
                    scheduleResumeAlarm(userPausedUntil)
                    if (alive) { refresh(); return START_STICKY }
                }
                ACTION_RESUME -> {
                    userPausedUntil = 0L
                    if (alive) { refresh(); return START_STICKY }
                }
            }
            // ACTION_START from Dart, or null = Android restarted a sticky
            // service, or a notification action / alarm reached a dead service.
            val p = prefs(this)
            if (!p.getBoolean("wanted", false)) {
                stopSelf()
                return START_NOT_STICKY
            }
            cfg = JSONObject(p.getString("config", "{}") ?: "{}")
            texts = cfg.optJSONObject("texts") ?: JSONObject()
            try {
                val n = buildNotification()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
                } else {
                    startForeground(NOTIF_ID, n)
                }
            } catch (e: Throwable) {
                // Android 12+/14+: not allowed from the background (sticky
                // restart, alarm). Honest fallback: ask the user with one tap.
                // (class compared by name: it only exists on Android 12+)
                val blocked = e is SecurityException ||
                    e.javaClass.name == "android.app.ForegroundServiceStartNotAllowedException"
                state = "error"
                reason = if (blocked) "fgs_blocked" else e.javaClass.simpleName
                postResumeNotification(this)
                stopSelf()
                return START_NOT_STICKY
            }
            if (!alive) {
                alive = true
                registerMonitors()
                main.post(monitorTick)
            }
            startAudioThread() // (re)start with the new config / sensitivity
            refresh()
        } catch (e: Throwable) {
            state = "error"
            reason = e.javaClass.simpleName
            stopSelf()
            return START_NOT_STICKY
        }
        // Sticky: if Android kills us it may restart us; onStartCommand(null)
        // then either runs (allowed) or posts the one-tap notification.
        return START_STICKY
    }

    // ---- pause logic -------------------------------------------------------------------

    private fun currentPause(): String {
        if (userPausedUntil > System.currentTimeMillis()) return "user"
        if (autoReason.isNotEmpty()) return autoReason
        if (SystemClock.elapsedRealtime() < wakeHoldUntil) return "wake"
        return ""
    }

    private val monitorTick = object : Runnable {
        override fun run() {
            if (!alive) return
            try {
                autoReason = when {
                    batteryLow() -> "battery"
                    inCall() -> "call"
                    otherAppRecording() -> "mic_busy"
                    else -> ""
                }
                if (userPausedUntil != 0L && userPausedUntil <= System.currentTimeMillis()) {
                    userPausedUntil = 0L
                }
                refresh()
            } catch (ignored: Throwable) {}
            main.postDelayed(this, 5000)
        }
    }

    private fun batteryLow(): Boolean {
        val bm = getSystemService(BatteryManager::class.java) ?: return false
        val pct = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        if (pct <= 0 || pct > 100) return false
        val charging = bm.isCharging
        // hysteresis: pause below 15 %, resume at 20 % (or when charging)
        lowBattery = !charging && (if (lowBattery) pct < RESUME_BATTERY else pct < LOW_BATTERY)
        return lowBattery
    }

    private fun inCall(): Boolean {
        val am = getSystemService(AudioManager::class.java) ?: return false
        val m = am.mode
        return m == AudioManager.MODE_IN_CALL || m == AudioManager.MODE_IN_COMMUNICATION ||
            m == AudioManager.MODE_RINGTONE ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && m == AudioManager.MODE_CALL_SCREENING)
    }

    private fun otherAppRecording(): Boolean {
        val am = getSystemService(AudioManager::class.java) ?: return false
        return am.activeRecordingConfigurations.any { isOther(it) }
    }

    private fun isOther(c: AudioRecordingConfiguration): Boolean {
        if (c.clientAudioSessionId != mySession) return true
        // our own capture silenced by Android 10+ because someone else records
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && c.isClientSilenced
    }

    private fun registerMonitors() {
        try {
            val am = getSystemService(AudioManager::class.java) ?: return
            val cb = object : AudioManager.AudioRecordingCallback() {
                override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>?) {
                    try {
                        val busy = configs?.any { isOther(it) } == true
                        if (busy && autoReason.isEmpty()) {
                            autoReason = "mic_busy"
                            refresh()
                        } else if (!busy && autoReason == "mic_busy") {
                            autoReason = ""
                            refresh()
                        }
                    } catch (ignored: Throwable) {}
                }
            }
            am.registerAudioRecordingCallback(cb, main)
            recCallback = cb
        } catch (ignored: Throwable) {}
    }

    /** Push the state to the notification + the static status Dart reads. */
    private fun refresh() {
        if (!alive) return
        val p = currentPause()
        state = if (p.isEmpty()) "listening" else "paused"
        reason = p
        pausedUntil = if (p == "user") userPausedUntil else 0L
        try {
            getSystemService(NotificationManager::class.java)?.notify(NOTIF_ID, buildNotification())
        } catch (ignored: Throwable) {}
    }

    private fun scheduleResumeAlarm(at: Long) {
        try {
            val am = getSystemService(AlarmManager::class.java) ?: return
            val pi = PendingIntent.getService(
                this, 5, Intent(this, WakeWordService::class.java).setAction(ACTION_RESUME),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            // inexact: no SCHEDULE_EXACT_ALARM permission needed
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        } catch (ignored: Throwable) {}
    }

    // ---- audio thread ----------------------------------------------------------------

    private fun startAudioThread() {
        val old = audioThread
        val my = ++gen
        if (old != null) {
            try { old.interrupt(); old.join(1500) } catch (ignored: Throwable) {}
        }
        val c = cfg
        val t = Thread({ audioLoop(my, c) }, "assisto-wake")
        t.priority = Thread.NORM_PRIORITY - 1
        audioThread = t
        t.start()
    }

    private fun audioLoop(my: Int, c: JSONObject) {
        var engine: OwwEngine? = null
        var rec: AudioRecord? = null
        try {
            val files = HashMap<String, String>()
            val fj = c.getJSONObject("files")
            for (k in fj.keys()) files[k] = fj.getString(k)
            val th = c.getJSONObject("thresholds")
            val level = c.optString("level", "normal")
            val threshold = th.optDouble(level, th.optDouble("normal", 0.5)).toFloat()
            engine = OwwEngine(
                c.optString("backend", "e2e"), files,
                c.optInt("windowSamples", 12400), c.optInt("frames", 16)
            )
            val decider = WakeDecider(threshold, WakeDecider.patienceFor(level))
            val buf = ShortArray(OwwEngine.HOP)
            var zeroRunMs = 0L
            while (alive && my == gen) {
                if (currentPause().isNotEmpty()) {
                    if (rec != null) {
                        releaseRec(rec); rec = null; engine.reset(); decider.reset()
                    }
                    Thread.sleep(500)
                    continue
                }
                if (rec == null) {
                    rec = openRec()
                    if (rec == null) { Thread.sleep(2000); continue }
                    zeroRunMs = 0
                }
                val n = rec.read(buf, 0, buf.size)
                if (n <= 0) { Thread.sleep(50); continue }
                // A mic service restarted from the background gets SILENCE on
                // Android 11+ (while-in-use rule): detect it and ask honestly.
                var allZero = true
                for (k in 0 until n) if (buf[k].toInt() != 0) { allZero = false; break }
                zeroRunMs = if (allZero) zeroRunMs + n * 1000L / 16000 else 0
                if (zeroRunMs > 8000) {
                    main.post {
                        state = "error"; reason = "mic_blocked"
                        postResumeNotification(this)
                        alive = false
                        stopSelf()
                    }
                    break
                }
                var fired = false
                engine.push(buf, n) { s ->
                    if (!fired && decider.feed(s, SystemClock.elapsedRealtime())) fired = true
                }
                if (fired) {
                    releaseRec(rec); rec = null
                    engine.reset(); decider.reset()
                    // keep the mic free for the voice screen; the recording
                    // callback keeps us paused while it listens
                    wakeHoldUntil = SystemClock.elapsedRealtime() + 6000
                    main.post { onWake() }
                }
            }
        } catch (e: InterruptedException) {
            // restarting / shutting down
        } catch (e: Throwable) {
            if (my == gen) {
                main.post {
                    state = "error"
                    reason = "engine:" + e.javaClass.simpleName
                    alive = false
                    try { stopSelf() } catch (ignored: Throwable) {}
                }
            }
        } finally {
            if (rec != null) releaseRec(rec)
            try { engine?.close() } catch (ignored: Throwable) {}
        }
    }

    private fun openRec(): AudioRecord? = try {
        val min = AudioRecord.getMinBufferSize(
            16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val r = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION, 16000,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            maxOf(min, OwwEngine.HOP * 2 * 4)
        )
        if (r.state != AudioRecord.STATE_INITIALIZED) {
            r.release()
            null
        } else {
            mySession = r.audioSessionId // before start: the callback must see it as ours
            r.startRecording()
            r
        }
    } catch (e: Throwable) {
        null
    }

    private fun releaseRec(r: AudioRecord) {
        try { r.stop() } catch (ignored: Throwable) {}
        try { r.release() } catch (ignored: Throwable) {}
        mySession = -1
    }

    // ---- on wake ---------------------------------------------------------------------

    private fun onWake() {
        try {
            val tg = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 70)
            tg.startTone(ToneGenerator.TONE_PROP_BEEP2, 160)
            main.postDelayed({ try { tg.release() } catch (ignored: Throwable) {} }, 400)
        } catch (ignored: Throwable) {}
        try {
            val v = getSystemService(Vibrator::class.java)
            if (v?.hasVibrator() == true) {
                v.vibrate(VibrationEffect.createOneShot(60, VibrationEffect.DEFAULT_AMPLITUDE))
            }
        } catch (ignored: Throwable) {}
        // Default assistant → our VoiceInteraction session opens Assisto Voice
        // instantly, from the background and over the lock screen.
        if (AssistoVoiceInteractionService.showFromWake()) return
        try {
            VoiceLaunchState.mark()
            val open = Intent(this, AssistEntryActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            // Works while Assisto is visible. Android blocks background
            // activity starts, so ALSO post a tap-to-talk notification — the
            // honest fallback, never a fake "opened".
            try { startActivity(open) } catch (ignored: Throwable) {}
            val pi = PendingIntent.getActivity(
                this, 1, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            getSystemService(NotificationManager::class.java)?.notify(
                WAKE_NOTIF_ID,
                Notification.Builder(this, CHANNEL_ID)
                    .setSmallIcon(applicationInfo.icon)
                    .setContentTitle("Assisto")
                    .setContentText(texts.optString("tapText", ""))
                    .setContentIntent(pi)
                    .setAutoCancel(true)
                    .setTimeoutAfter(15000)
                    .build()
            )
        } catch (ignored: Throwable) {}
    }

    // ---- notification ------------------------------------------------------------------

    private fun tx(k: String, fb: String) = texts.optString(k, "").ifEmpty { fb }

    private fun buildNotification(): Notification {
        getSystemService(NotificationManager::class.java)?.let { ensureChannel(it, tx("channel", "Hey Assisto")) }
        val p = currentPause()
        val body = when (p) {
            "" -> tx("body", "")
            "user" -> tx("pausedUser", "")
            "battery" -> tx("pausedBattery", "")
            "call" -> tx("pausedCall", "")
            "mic_busy" -> tx("pausedMic", "")
            else -> tx("pausedWake", "")
        }
        val title = if (p.isEmpty()) tx("title", "Hey Assisto") else tx("pausedTitle", "Hey Assisto")
        fun svc(action: String, req: Int) = PendingIntent.getService(
            this, req,
            Intent(this, WakeWordService::class.java).setAction(action).putExtra("minutes", 60),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(
                this, 6, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        val noIcon: android.graphics.drawable.Icon? = null
        val b = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
        if (open != null) b.setContentIntent(open)
        if (p == "user") {
            b.addAction(Notification.Action.Builder(noIcon, tx("resume", "Resume"), svc(ACTION_RESUME, 7)).build())
        } else {
            b.addAction(Notification.Action.Builder(noIcon, tx("pause", "Pause 1 h"), svc(ACTION_PAUSE, 8)).build())
        }
        b.addAction(Notification.Action.Builder(noIcon, tx("off", "Turn off"), svc(ACTION_OFF, 9)).build())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return b.build()
    }

    override fun onDestroy() {
        alive = false
        gen++
        main.removeCallbacksAndMessages(null)
        try { audioThread?.interrupt() } catch (ignored: Throwable) {}
        audioThread = null
        try {
            recCallback?.let {
                getSystemService(AudioManager::class.java)?.unregisterAudioRecordingCallback(it)
            }
        } catch (ignored: Throwable) {}
        if (state != "error") { state = "stopped"; reason = "" }
        super.onDestroy()
    }
}
