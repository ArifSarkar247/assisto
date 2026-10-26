package com.assisto.assisto.calls

import android.app.Activity
import android.app.NotificationManager
import android.app.PictureInPictureParams
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.MediaStore
import android.provider.Settings
import android.util.Rational
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * c2-calls native bridge. Channel: "com.assisto/calls".
 *
 * LAUNCH SAFETY: register() only installs a handler. AudioTrack, Ringtone,
 * the vibrator, the proximity wake lock and the ringtone picker are created on
 * the FIRST call that needs them; every branch is try/catch and answers with a
 * plain value, so an OEM quirk can never crash the app (Dart shows an honest
 * state instead).
 *
 *   playTone(pcm: ByteArray, rate: Int, loop: Bool)  -> Bool  (generated tones)
 *   stopTone()                                       -> Bool
 *   startRingtone(uri: String?)  -> "ring" | "vibrate" | "silent" | "error"
 *        (phone default ringtone when uri is null; respects ringer mode + DND)
 *   stopRingtone()                                   -> Bool
 *   pickSound(type: "ringtone"|"notification", current: String?)
 *        -> {uri, title} | {uri:null(=silent)} | null (cancelled)
 *   soundTitle(uri: String?)                         -> String
 *   installRingtone(wav: ByteArray, name: String)    -> String? (content uri)
 *   setProximity(on: Bool)                           -> Bool
 *   keepScreenOn(on: Bool)                           -> Bool
 *   pipSupported()                                   -> Bool
 *   enterPip(w: Int, h: Int)                         -> Bool
 *   setAutoPip(on: Bool, w: Int, h: Int)             -> Bool  (b1: Home -> PiP)
 *   watchNetwork(on: Bool)                           -> Bool  (calls-presence)
 *   Dart callback: "pipChanged"(Bool)
 *   Dart callback: "networkChanged"("wifi"|"cellular"|"other"|"lost")
 *        only while watched (one live call); never at registration time
 */
object CallsChannel {
    private const val CHANNEL = "com.assisto/calls"
    private const val REQ_PICK = 0x5a11

    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var track: AudioTrack? = null
    private var ringtone: Ringtone? = null
    private var vibrating = false
    private var proximity: PowerManager.WakeLock? = null
    private var pickResult: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    /// play-fsi: Android 14+ only shows an incoming call FULL-SCREEN when the
    /// user allowed "full screen notifications" for Assisto (Play does not
    /// pre-grant it to us). Below 14 it is always allowed. Without it the call
    /// still rings as a high-priority heads-up notification.
    private fun canFullScreen(): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        val a = activity ?: return true
        return try {
            (a.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .canUseFullScreenIntent()
        } catch (_: Throwable) { true }
    }

    /// ring-everywhere checklist: are notifications on AND is the ringing
    /// call channel not switched off? null = can't tell (no activity yet).
    private fun callChannelOk(): Boolean? {
        val a = activity ?: return null
        return try {
            val nm = a.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (!nm.areNotificationsEnabled()) return false
            val ch = nm.getNotificationChannel("calls") ?: return true // not created yet
            ch.importance != NotificationManager.IMPORTANCE_NONE
        } catch (_: Throwable) { null }
    }

    /// Opens Settings -> Assisto -> "Full screen notifications".
    private fun openFullScreenSettings(): Boolean {
        val a = activity ?: return false
        if (Build.VERSION.SDK_INT < 34) return false
        return try {
            a.startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                Uri.parse("package:" + a.packageName)))
            true
        } catch (_: Throwable) {
            try {   // some OEM builds lack the page: fall back to the app's settings
                a.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:" + a.packageName)))
                true
            } catch (_: Throwable) { false }
        }
    }

    fun register(activity: Activity, messenger: BinaryMessenger) {
        this.activity = activity
        val ch = MethodChannel(messenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "playTone" -> result.success(
                        playTone(
                            call.argument<ByteArray>("pcm"),
                            call.argument<Int>("rate") ?: 16000,
                            call.argument<Boolean>("loop") ?: false
                        )
                    )
                    "stopTone" -> result.success(stopTone())
                    "startRingtone" -> result.success(startRingtone(call.argument<String>("uri")))
                    "stopRingtone" -> result.success(stopRingtone())
                    "pickSound" -> pickSound(
                        call.argument<String>("type") ?: "ringtone",
                        call.argument<String>("current"), result
                    )
                    "soundTitle" -> result.success(soundTitle(call.argument<String>("uri")))
                    "installRingtone" -> result.success(
                        installRingtone(
                            call.argument<ByteArray>("wav"),
                            call.argument<String>("name") ?: "Assisto"
                        )
                    )
                    "setProximity" -> result.success(setProximity(call.argument<Boolean>("on") == true))
                    "keepScreenOn" -> result.success(keepScreenOn(call.argument<Boolean>("on") == true))
                    "pipSupported" -> result.success(pipSupported())
                    // play-fsi: full-screen incoming calls (Android 14+ not pre-granted)
                    "canFullScreen" -> result.success(canFullScreen())
                    "openFullScreenSettings" -> result.success(openFullScreenSettings())
                    "enterPip" -> result.success(
                        enterPip(call.argument<Int>("w") ?: 9, call.argument<Int>("h") ?: 16)
                    )
                    "setAutoPip" -> result.success(
                        setAutoPip(
                            call.argument<Boolean>("on") == true,
                            call.argument<Int>("w") ?: 9,
                            call.argument<Int>("h") ?: 16
                        )
                    )
                    "watchNetwork" -> result.success(watchNetwork(call.argument<Boolean>("on") == true))
                    // ring-everywhere (native ring + Telecom + checklist)
                    "setNativeConfig" -> {
                        val c = ctx()
                        if (c != null) CallAck.setConfig(c, call.argument<String>("api_base"),
                            call.argument<String>("app_version"))
                        result.success(c != null)
                    }
                    "telecomActive" -> result.success(
                        TelecomBridge.active(call.argument<String>("call_id") ?: ""))
                    "telecomEnd" -> result.success(
                        TelecomBridge.end(call.argument<String>("call_id") ?: ""))
                    "cancelRing" -> {
                        val c = ctx()
                        val id = call.argument<String>("call_id") ?: ""
                        if (c != null && id.isNotEmpty()) IncomingCall.cancel(c, id)
                        result.success(c != null)
                    }
                    "callChannelOk" -> result.success(callChannelOk())
                    "deviceFacts" -> result.success(mapOf(
                        "brand" to (Build.BRAND ?: ""),
                        "manufacturer" to (Build.MANUFACTURER ?: ""),
                        "model" to (Build.MODEL ?: ""),
                        "sdk_int" to Build.VERSION.SDK_INT))
                    "armRingTest" -> {
                        val c = ctx()
                        if (c != null) RingTestReceiver.arm(c)
                        result.success(c != null)
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                try { result.success(null) } catch (ignored: Throwable) {}
            }
        }
    }

    // ------------------------------------------------------------ tones
    private fun playTone(pcm: ByteArray?, rate: Int, loop: Boolean): Boolean {
        stopTone()
        if (pcm == null || pcm.isEmpty()) return false
        return try {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val fmt = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(rate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build()
            val t = AudioTrack(attrs, fmt, pcm.size, AudioTrack.MODE_STATIC,
                AudioManager.AUDIO_SESSION_ID_GENERATE)
            t.write(pcm, 0, pcm.size)
            if (loop) t.setLoopPoints(0, pcm.size / 2, -1)
            t.play()
            track = t
            true
        } catch (e: Throwable) {
            track = null
            false
        }
    }

    private fun stopTone(): Boolean {
        try {
            track?.let {
                try { it.stop() } catch (ignored: Throwable) {}
                it.release()
            }
        } catch (ignored: Throwable) {}
        track = null
        return true
    }

    // ------------------------------------------------------------ ringtone
    private fun ctx(): Context? = activity?.applicationContext

    /** Ring like the phone does: silent mode = nothing, vibrate mode =
     *  vibrate only, Do Not Disturb (anything but "all") = silent. */
    private fun startRingtone(uriStr: String?): String {
        stopRingtone()
        val c = ctx() ?: return "error"
        return try {
            val am = c.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val dnd = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                nm.currentInterruptionFilter > NotificationManager.INTERRUPTION_FILTER_ALL
            if (dnd) return "silent"
            when (am.ringerMode) {
                AudioManager.RINGER_MODE_SILENT -> "silent"
                AudioManager.RINGER_MODE_VIBRATE -> {
                    vibrate(c); "vibrate"
                }
                else -> {
                    val uri = if (uriStr.isNullOrEmpty())
                        RingtoneManager.getActualDefaultRingtoneUri(c, RingtoneManager.TYPE_RINGTONE)
                            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                    else Uri.parse(uriStr)
                    val r = RingtoneManager.getRingtone(c, uri)
                    if (r != null) {
                        r.audioAttributes = AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) r.isLooping = true
                        r.play()
                        ringtone = r
                    }
                    vibrate(c)
                    if (r != null) "ring" else "vibrate"
                }
            }
        } catch (e: Throwable) {
            "error"
        }
    }

    private fun vibrator(c: Context): Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (c.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            c.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }

    private fun vibrate(c: Context) {
        try {
            val v = vibrator(c) ?: return
            val pattern = longArrayOf(0, 800, 1200)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(pattern, 0)
            }
            vibrating = true
        } catch (ignored: Throwable) {}
    }

    private fun stopRingtone(): Boolean {
        try { ringtone?.stop() } catch (ignored: Throwable) {}
        ringtone = null
        if (vibrating) {
            try { ctx()?.let { vibrator(it)?.cancel() } } catch (ignored: Throwable) {}
            vibrating = false
        }
        return true
    }

    // ------------------------------------------------------------ picker
    private fun pickSound(type: String, current: String?, result: MethodChannel.Result) {
        val a = activity
        if (a == null) { result.success(null); return }
        try {
            val t = if (type == "notification") RingtoneManager.TYPE_NOTIFICATION
            else RingtoneManager.TYPE_RINGTONE
            val i = Intent(RingtoneManager.ACTION_RINGTONE_PICKER)
                .putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE, t)
                .putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
                .putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, type == "notification")
                .putExtra(RingtoneManager.EXTRA_RINGTONE_DEFAULT_URI,
                    RingtoneManager.getDefaultUri(t))
            if (!current.isNullOrEmpty()) {
                i.putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI, Uri.parse(current))
            }
            try { pickResult?.success(null) } catch (ignored: Throwable) {}
            pickResult = result
            a.startActivityForResult(i, REQ_PICK)
        } catch (e: Throwable) {
            pickResult = null
            result.success(null)
        }
    }

    /** MainActivity forwards onActivityResult here. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_PICK) return false
        val r = pickResult ?: return true
        pickResult = null
        try {
            if (resultCode != Activity.RESULT_OK) { r.success(null); return true }
            @Suppress("DEPRECATION")
            val uri: Uri? = data?.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
            r.success(mapOf("uri" to uri?.toString(), "title" to soundTitle(uri?.toString())))
        } catch (e: Throwable) {
            try { r.success(null) } catch (ignored: Throwable) {}
        }
        return true
    }

    private fun soundTitle(uriStr: String?): String {
        val c = ctx() ?: return ""
        return try {
            val uri = if (uriStr.isNullOrEmpty())
                RingtoneManager.getActualDefaultRingtoneUri(c, RingtoneManager.TYPE_RINGTONE)
            else Uri.parse(uriStr)
            RingtoneManager.getRingtone(c, uri)?.getTitle(c) ?: ""
        } catch (e: Throwable) {
            ""
        }
    }

    /** Android 10+: put our generated WAV in the phone's Ringtones so the
     *  locked-screen ring (a notification channel sound) can use it too. */
    private fun installRingtone(wav: ByteArray?, name: String): String? {
        val c = ctx() ?: return null
        if (wav == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            val resolver = c.contentResolver
            val coll = MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val display = "$name.wav"
            // reuse an earlier install of ours
            resolver.query(coll, arrayOf(MediaStore.Audio.Media._ID),
                "${MediaStore.Audio.Media.DISPLAY_NAME}=?", arrayOf(display), null)?.use { cur ->
                if (cur.moveToFirst()) {
                    val id = cur.getLong(0)
                    return Uri.withAppendedPath(coll, id.toString()).toString()
                }
            }
            val v = ContentValues().apply {
                put(MediaStore.Audio.Media.DISPLAY_NAME, display)
                put(MediaStore.Audio.Media.TITLE, name)
                put(MediaStore.Audio.Media.MIME_TYPE, "audio/wav")
                put(MediaStore.Audio.Media.RELATIVE_PATH, "Ringtones/")
                put(MediaStore.Audio.Media.IS_RINGTONE, 1)
                put(MediaStore.Audio.Media.IS_PENDING, 1)
            }
            val uri = resolver.insert(coll, v) ?: return null
            resolver.openOutputStream(uri)?.use { it.write(wav) }
            v.clear()
            v.put(MediaStore.Audio.Media.IS_PENDING, 0)
            resolver.update(uri, v, null, null)
            uri.toString()
        } catch (e: Throwable) {
            null
        }
    }

    // ------------------------------------------------------------ proximity
    private fun setProximity(on: Boolean): Boolean {
        val c = ctx() ?: return false
        return try {
            if (on) {
                if (proximity?.isHeld == true) return true
                val pm = c.getSystemService(Context.POWER_SERVICE) as PowerManager
                if (!pm.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
                    return false
                }
                val wl = pm.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                    "assisto:call-proximity")
                wl.setReferenceCounted(false)
                wl.acquire(4 * 60 * 60 * 1000L) // safety cap: 4 h
                proximity = wl
            } else {
                proximity?.let { if (it.isHeld) it.release() }
                proximity = null
            }
            true
        } catch (e: Throwable) {
            false
        }
    }

    private fun keepScreenOn(on: Boolean): Boolean {
        val a = activity ?: return false
        return try {
            a.runOnUiThread {
                try {
                    val f = android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                    if (on) a.window.addFlags(f) else a.window.clearFlags(f)
                } catch (ignored: Throwable) {}
            }
            true
        } catch (e: Throwable) {
            false
        }
    }

    // ------------------------------------------------------------ PiP
    private fun pipSupported(): Boolean {
        val a = activity ?: return false
        return try {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                a.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
        } catch (e: Throwable) {
            false
        }
    }

    /** Needs android:supportsPictureInPicture="true" on MainActivity (see
     *  .phaseB/proposals/c2-calls.md); without it the OS throws and we
     *  answer false (no crash). */
    private fun enterPip(w: Int, h: Int): Boolean {
        val a = activity ?: return false
        if (!pipSupported()) return false
        return try {
            val p = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(w.coerceIn(1, 100), h.coerceIn(1, 100)))
                .build()
            a.enterPictureInPictureMode(p)
        } catch (e: Throwable) {
            false
        }
    }

    // b1-calls: auto picture-in-picture while a VIDEO call is live. Dart turns
    // it on only for a connected video call and off again when it ends.
    @Volatile private var autoPip = false
    private var pipW = 9
    private var pipH = 16
    private var leaveHintHooked = false

    /** API 31+: PictureInPictureParams.setAutoEnterEnabled (the home gesture
     *  shrinks the call into PiP). API 26-30: the activity's user-leave-hint
     *  listener (androidx.activity, looked up by reflection so an old
     *  androidx can never break the build or crash) enters PiP on Home.
     *  Every path is guarded; false = not available on this phone. */
    private fun setAutoPip(on: Boolean, w: Int, h: Int): Boolean {
        autoPip = on
        pipW = w.coerceIn(1, 100)
        pipH = h.coerceIn(1, 100)
        val a = activity ?: return false
        if (!pipSupported()) return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                a.setPictureInPictureParams(
                    PictureInPictureParams.Builder()
                        .setAspectRatio(Rational(pipW, pipH))
                        .setAutoEnterEnabled(on)
                        // video content: no seamless resize (no stretched frame)
                        .setSeamlessResizeEnabled(!on)
                        .build()
                )
            } else {
                hookLeaveHint(a)
            }
            true
        } catch (e: Throwable) {
            false
        }
    }

    private fun hookLeaveHint(a: Activity) {
        if (leaveHintHooked) return
        // calls-a: MainActivity forwards onUserLeaveHint itself (no reflection)
        if (a is com.assisto.assisto.MainActivity) return
        try {
            val m = a.javaClass.getMethod("addOnUserLeaveHintListener", Runnable::class.java)
            m.invoke(a, Runnable {
                try {
                    if (autoPip) enterPip(pipW, pipH)
                } catch (ignored: Throwable) {}
            })
            leaveHintHooked = true
        } catch (ignored: Throwable) {}
    }

    // ------------------------------------------------- network switch watch
    // calls-presence: Wi-Fi <-> mobile data during a call. The callback is
    // registered ONLY while a call screen listens (lazy) and every step is
    // guarded; ACCESS_NETWORK_STATE is already declared (no new permission).
    private var netCb: ConnectivityManager.NetworkCallback? = null
    private var lastNet: Network? = null

    private fun netKind(cm: ConnectivityManager, n: Network): String = try {
        val caps = cm.getNetworkCapabilities(n)
        when {
            caps == null -> "other"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            else -> "other"
        }
    } catch (_: Throwable) { "other" }

    private fun emitNet(kind: String) {
        main.post {
            try { channel?.invokeMethod("networkChanged", kind) } catch (ignored: Throwable) {}
        }
    }

    private fun watchNetwork(on: Boolean): Boolean {
        val c = ctx() ?: return false
        return try {
            val cm = c.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            netCb?.let {
                try { cm.unregisterNetworkCallback(it) } catch (ignored: Throwable) {}
            }
            netCb = null
            lastNet = null
            if (!on || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return !on
            lastNet = try { cm.activeNetwork } catch (_: Throwable) { null }
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    try {
                        val prev = lastNet
                        lastNet = network
                        // the first callback reports the CURRENT network: no event
                        if (prev != null && prev != network) emitNet(netKind(cm, network))
                    } catch (ignored: Throwable) {}
                }

                override fun onLost(network: Network) {
                    try {
                        if (network == lastNet) emitNet("lost")
                    } catch (ignored: Throwable) {}
                }
            }
            cm.registerDefaultNetworkCallback(cb)
            netCb = cb
            true
        } catch (e: Throwable) {
            netCb = null
            false
        }
    }

    /** calls-a: a warm call launch (MainActivity.onNewIntent) -> Dart
     *  "callLaunch" {action, call_id, payload}. Dart de-duplicates it against
     *  flutter_local_notifications' copy by call id. */
    fun sendCallLaunch(action: String, callId: String, payload: String) {
        main.post {
            try {
                channel?.invokeMethod("callLaunch", mapOf(
                    "action" to action, "call_id" to callId, "payload" to payload))
            } catch (ignored: Throwable) {}
        }
    }

    /** calls-a: MainActivity.onUserLeaveHint (Home / Recents on API 26-30):
     *  a live video call shrinks into system picture-in-picture. API 31+
     *  uses setAutoEnterEnabled instead (smoother, no flash). */
    fun onUserLeaveHint() {
        try {
            if (autoPip && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enterPip(pipW, pipH)
        } catch (ignored: Throwable) {}
    }

    /** MainActivity forwards onPictureInPictureModeChanged here. */
    fun onPipChanged(inPip: Boolean) {
        main.post {
            try { channel?.invokeMethod("pipChanged", inPip) } catch (ignored: Throwable) {}
        }
    }

    fun release() {
        autoPip = false
        try { watchNetwork(false) } catch (ignored: Throwable) {}
        stopTone()
        stopRingtone()
        setProximity(false)
    }
}
