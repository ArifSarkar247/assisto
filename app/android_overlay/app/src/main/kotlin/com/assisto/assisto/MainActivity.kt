package com.assisto.assisto

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import org.json.JSONObject
import android.os.Vibrator
import android.os.VibratorManager
import android.os.VibrationEffect
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the #80 lost/stolen device-admin MethodChannel.
 *
 * NOTE: this OVERWRITES the default MainActivity that `flutter create`
 * generates (same package/path). The default is an empty
 * `class MainActivity: FlutterActivity()`; everything Flutter needs is still
 * here — we only add configureFlutterEngine to wire one channel.
 *
 * hc1: the base is FlutterFragmentActivity (an androidx FragmentActivity /
 * ComponentActivity). The `health` plugin casts the activity to
 * ComponentActivity to registerForActivityResult (Health Connect permission
 * screen), so on a plain FlutterActivity it failed to attach ("Error
 * registering plugin health"); local_auth likewise answered every
 * authenticate() with "no_fragment_activity".
 * Every override below exists on FlutterFragmentActivity with the same
 * signature; see .phaseB/proposals/hc1.md.
 *
 * Channel: "com.assisto/device_admin"
 *   isAdminActive()            -> Bool
 *   requestAdmin()             -> Bool (launches the system consent screen)
 *   lockNow()                  -> Bool (requires active admin)
 *   startAlarm()               -> Bool (loud alarm-stream sound + vibrate)
 *   stopAlarm()                -> Bool
 *   openAdminSettings()        -> Bool (so the user can DEACTIVATE/uninstall)
 *   adLaunchSuppressed()       -> Bool (admob: last launch/resume was NOT the
 *                                 plain launcher icon; read once, then cleared)
 *
 * Every call that needs admin re-checks isAdminActive() so Dart can never fake
 * a protection that the OS hasn't actually granted.
 */
class MainActivity : FlutterFragmentActivity() {

    private val channelName = "com.assisto/device_admin"
    private var alarmPlayer: MediaPlayer? = null

    private val adminComponent: ComponentName
        get() = ComponentName(this, AssistoDeviceAdminReceiver::class.java)

    private val dpm: DevicePolicyManager
        get() = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager

    // ---- lock screen: ONLY a ringing call may show Assisto on a locked phone.
    // Nothing in the manifest makes the app visible over the keyguard; the
    // permission is granted per launch, when the full-screen intent of a call
    // notification (flutter_local_notifications puts our payload JSON in the
    // "payload" extra) starts or re-enters this activity, and is taken back
    // when the call screen closes (Dart "release") or the app leaves the
    // screen (onStop). SOS alerts ring loudly but need an unlock to open.
    // calls-a: a re-created activity (savedInstanceState) must never answer
    // the original call intent a second time.
    private var restored = false

    override fun onCreate(savedInstanceState: Bundle?) {
        restored = savedInstanceState != null
        // calls-a: a call launch shows over the lock screen from the very
        // first window frame (not after the engine started).
        try {
            if (!restored && com.assisto.assisto.calls.CallLaunch.parse(intent) != null) {
                setOverLockScreen(true)
            }
        } catch (e: Throwable) {
        }
        super.onCreate(savedInstanceState)
        markAdLaunchSource(intent)
        applyLockScreenPolicy(intent)
        applyVoiceLaunch(intent)
    }

    // calls-a: COLD start from a call's Accept / tap / full-screen intent ->
    // the first Flutter route IS the call (or ringing) screen, decided from
    // the intent before any Dart runs (no method-channel call before the
    // first frame). Anything else: Flutter's default (the "route" extra /
    // manifest meta-data; null -> deep link / "/").
    override fun getInitialRoute(): String? {
        if (!restored) {
            try {
                val r = com.assisto.assisto.calls.CallLaunch.initialRoute(intent)
                if (r != null) return r
            } catch (e: Throwable) {
            }
        }
        return try {
            super.getInitialRoute()
        } catch (e: Throwable) {
            null
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        markAdLaunchSource(intent)
        applyLockScreenPolicy(intent)
        applyVoiceLaunch(intent)
        // calls-a: WARM start (Assisto in the background / on the lock
        // screen): hand the call launch to Dart directly, at once.
        try {
            com.assisto.assisto.calls.CallLaunch.deliverWarm(intent)
        } catch (e: Throwable) {
        }
        // c3-msg: conversation shortcut tapped while Assisto is running.
        try {
            com.assisto.assisto.messaging.C3MessagingChannel.onNewIntent(intent)
        } catch (e: Throwable) {
        }
    }

    // c3-msg + c2-calls: results of the phone's sound pickers. Each channel
    // answers true only for its own request code (0xC3 / 0x5a11); everything
    // else goes to super, which on ComponentActivity first dispatches
    // ActivityResultRegistry results (the health plugin's Health Connect
    // permission launcher) and then forwards to plugins via FlutterFragment.
    @Deprecated("Legacy result path kept for the startActivityForResult pickers")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        try {
            if (com.assisto.assisto.messaging.C3MessagingChannel
                    .onActivityResult(this, requestCode, resultCode, data)) return
        } catch (e: Throwable) {
        }
        // c2-calls: the ringtone picker result (request code 0x5a11 only).
        try {
            if (com.assisto.assisto.calls.CallsChannel
                    .onActivityResult(requestCode, resultCode, data)) return
        } catch (e: Throwable) {
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    // Part 3 (a3-voice): an assist / wake launch marks "open Assisto Voice"
    // and, on a locked phone, lets THAT launch show over the keyguard (the
    // voice screen asks to unlock before anything private and releases the
    // lock screen as it closes; onStop releases it too). Runs AFTER the call
    // policy, which clears the flag for every non-call launch.
    private fun applyVoiceLaunch(i: Intent?) {
        try {
            com.assisto.assisto.voice.AssistoVoiceChannel.applyLaunchIntent(this, i)
        } catch (e: Throwable) {
        }
    }

    // ---- admob (owner 25 Oct): NO app-open ad when Assisto was opened by
    // anything but the plain launcher icon — a notification / SOS / safety
    // alert / call (full-screen intent "payload"), an alarm or reminder
    // notification, the home-screen widget ("assisto_src"), a deep link
    // (data URI), a foreground-service button, an assist/voice launch. Dart
    // reads (and clears) the flag through "adLaunchSuppressed" right before
    // it would show an app-open ad. Plain field, no I/O: never slows launch.
    private var adSuppress = false

    private fun markAdLaunchSource(i: Intent?) {
        try {
            if (i == null) return
            val plainLauncher = i.action == Intent.ACTION_MAIN &&
                (i.categories?.contains(Intent.CATEGORY_LAUNCHER) == true) &&
                i.data == null &&
                (i.extras == null || i.extras!!.isEmpty())
            if (!plainLauncher) adSuppress = true
        } catch (e: Throwable) {
            adSuppress = true
        }
    }

    override fun onStop() {
        setOverLockScreen(false)
        super.onStop()
    }

    // ring-everywhere: while Assisto is on screen a call push is NOT drawn
    // natively — the running app shows its in-app incoming screen instead.
    override fun onResume() {
        super.onResume()
        com.assisto.assisto.calls.IncomingCall.appInForeground = true
    }

    override fun onPause() {
        com.assisto.assisto.calls.IncomingCall.appInForeground = false
        super.onPause()
    }

    private fun applyLockScreenPolicy(i: Intent?) {
        // call-reply: the ring's Reply button -> declined natively; the chat
        // it opens never shows over the lock screen, never "answered".
        val replied = try {
            com.assisto.assisto.calls.IncomingCall.onReplyLaunch(this, i)
        } catch (e: Throwable) {
            false
        }
        if (replied) {
            setOverLockScreen(false)
            return
        }
        var callId = ""
        val isCall = try {
            val raw = i?.getStringExtra("payload")
            val js = if (raw != null) JSONObject(raw) else null
            callId = js?.optString("call_id") ?: ""
            js != null && js.optString("kind") == "call"
        } catch (e: Exception) {
            false
        }
        setOverLockScreen(isCall)
        // calls-a: ONLY Accept takes over from the native ring (Telecom marked
        // answered + the ring notification cancelled on the tap). A tap /
        // full-screen launch just SHOWS the ringing screen: the native ring
        // (insistent notification sound + Telecom RINGING) keeps ringing until
        // Accept / Decline / timeout / call_cancel — before calls-a every call
        // launch ended the Telecom ring here, and over the lock screen that
        // left a silent ringing screen.
        if (isCall && callId.isNotEmpty() &&
            i?.getStringExtra("actionId") ==
            com.assisto.assisto.calls.IncomingCall.ACTION_ACCEPT &&
            ((i?.flags ?: 0) and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0) {
            try {
                com.assisto.assisto.calls.TelecomBridge.answered(callId)
            } catch (e: Throwable) {
            }
            try {
                com.assisto.assisto.calls.CallLaunch.answeredHere(applicationContext, callId)
            } catch (e: Throwable) {
            }
        }
    }

    private fun setOverLockScreen(on: Boolean) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(on)
                setTurnScreenOn(on)
            } else {
                @Suppress("DEPRECATION")
                val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                if (on) window.addFlags(flags) else window.clearFlags(flags)
            }
        } catch (e: Exception) {
            // never crash the app over a window flag
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // CCTV Part 4 Shop Box mode: keep-screen-on + charging state. Handler
        // registration only — nothing runs until Dart calls it (lazy).
        try {
            com.assisto.assisto.shopbox.ShopBoxChannel.register(flutterEngine, this)
        } catch (e: Throwable) {
        }
        // v1-vehicle: ELM327 OBD over classic Bluetooth. Registering is free;
        // the adapter is only touched when Dart calls it from the OBD screen.
        try {
            com.assisto.assisto.vehicle.ObdBtChannel.register(flutterEngine, this)
        } catch (e: Throwable) {
        }
        // Part 3 (a3-voice): Assisto Voice channel "com.assisto/voice". Installs
        // a handler only — TTS / camera / wake word are created on first use.
        try {
            com.assisto.assisto.voice.AssistoVoiceChannel.register(
                this, flutterEngine.dartExecutor.binaryMessenger
            )
        } catch (e: Throwable) {
        }
        // c3-msg: message sound picker, bubbles, conversation launch. Handler
        // only — nothing runs until Dart calls it.
        try {
            com.assisto.assisto.messaging.C3MessagingChannel.register(this, flutterEngine)
        } catch (e: Throwable) {
        }
        // c2-calls: "com.assisto/calls" (tones, ringtone + picker, proximity,
        // PiP). Handler only — nothing is created until Dart calls it.
        try {
            com.assisto.assisto.calls.CallsChannel.register(
                this, flutterEngine.dartExecutor.binaryMessenger
            )
        } catch (e: Throwable) {
        }
        // ---- p2-photo ---- Photo Studio: ML Kit faces + ONNX Runtime upscaler
        // ("com.assisto/photo_native") and FLAG_SECURE for free previews
        // ("com.assisto/photo_secure"). Handlers only — ML Kit / ORT are created
        // on the first call from an open Photo Studio, never at launch.
        try {
            com.assisto.assisto.photo.PhotoNativeChannel.register(
                this, flutterEngine.dartExecutor.binaryMessenger
            )
        } catch (e: Throwable) {
        }
        // ---- tl1 ---- OEM background guide ("com.assisto/oem_guide"): device
        // + battery-state lookups and the vendor settings screens. Handler only
        // — nothing is resolved or started until the guide screen calls it.
        try {
            com.assisto.assisto.oem.OemGuideChannel.register(
                this, flutterEngine.dartExecutor.binaryMessenger
            )
        } catch (e: Throwable) {
        }
        // b6-antitheft: Lost/Stolen engine channel "com.assisto/antitheft".
        // Handler registration only — the foreground service starts lazily when
        // Dart calls start() after the user turns protection on (crash-guarded).
        try {
            com.assisto.assisto.antitheft.AntiTheftChannel.register(
                this, flutterEngine.dartExecutor.binaryMessenger
            )
        } catch (e: Throwable) {
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.assisto/lockscreen")
            .setMethodCallHandler { call, result ->
                if (call.method == "release") {
                    setOverLockScreen(false)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAdminActive" -> result.success(dpm.isAdminActive(adminComponent))

                    "requestAdmin" -> {
                        if (dpm.isAdminActive(adminComponent)) {
                            result.success(true)
                        } else {
                            val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                                .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, adminComponent)
                                .putExtra(
                                    DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                                    call.argument<String>("explanation")
                                        ?: "Assisto needs device-admin to lock your phone " +
                                        "if it is lost or stolen."
                                )
                            startActivity(intent)
                            // The user's choice lands on the system screen; Dart
                            // re-polls isAdminActive() on resume (honest state).
                            result.success(false)
                        }
                    }

                    "lockNow" -> {
                        if (!dpm.isAdminActive(adminComponent)) {
                            result.success(false)
                        } else {
                            try {
                                dpm.lockNow()
                                result.success(true)
                            } catch (e: SecurityException) {
                                result.success(false)
                            }
                        }
                    }

                    "startAlarm" -> result.success(startAlarm())
                    "stopAlarm" -> result.success(stopAlarm())

                    // Device model + Android version for the Settings → About
                    // long-press "copy for bug report". Reuses this channel so we
                    // add NO new native plugin (keeps the launch path minimal).
                    "deviceInfo" -> result.success(
                        mapOf(
                            "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
                            "androidRelease" to Build.VERSION.RELEASE,
                            "sdkInt" to Build.VERSION.SDK_INT
                        )
                    )

                    // CI launch-safety probe: returns the "ao_open" intent extra
                    // (a ChatNav route name) so the emulator smoke test can open
                    // one feature screen and exercise its real native plugins.
                    // Null for normal launches — Dart only reads it in debug.
                    "aoSmokeOpen" -> result.success(intent?.getStringExtra("ao_open"))

                    // admob: was this launch / resume from a notification,
                    // call, alarm, widget, deep link...? Read once, then cleared.
                    "adLaunchSuppressed" -> {
                        val v = adSuppress
                        adSuppress = false
                        result.success(v)
                    }

                    // play-fgs: a foreground-service notification button asked
                    // to open one screen (allow-listed in Dart). Read once.
                    "notifOpen" -> {
                        val v = intent?.getStringExtra("assisto_open")
                        intent?.removeExtra("assisto_open")
                        result.success(v)
                    }

                    "openAdminSettings" -> {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_SECURITY_SETTINGS)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun startAlarm(): Boolean {
        return try {
            stopAlarm()
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.setStreamVolume(
                AudioManager.STREAM_ALARM,
                am.getStreamMaxVolume(AudioManager.STREAM_ALARM),
                0
            )
            var uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            if (uri == null) return false
            alarmPlayer = MediaPlayer().apply {
                setDataSource(applicationContext, uri)
                setAudioStreamType(AudioManager.STREAM_ALARM)
                isLooping = true
                prepare()
                start()
            }
            vibrateLoop()
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun stopAlarm(): Boolean {
        return try {
            alarmPlayer?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
            alarmPlayer = null
            true
        } catch (e: Exception) {
            alarmPlayer = null
            true
        }
    }

    private fun vibrateLoop() {
        val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            vm?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
        val pattern = longArrayOf(0, 600, 400)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))
        } else {
            @Suppress("DEPRECATION")
            vibrator?.vibrate(pattern, 0)
        }
    }

    // calls-a: Home / Recents during a live VIDEO call (API 26-30) -> system
    // picture-in-picture; API 31+ auto-enters via setAutoEnterEnabled.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        try {
            com.assisto.assisto.calls.CallsChannel.onUserLeaveHint()
        } catch (e: Throwable) {
        }
    }

    // c2-calls: PiP mode changes go to the calls channel (crash-guarded).
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: android.content.res.Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        try {
            com.assisto.assisto.calls.CallsChannel.onPipChanged(isInPictureInPictureMode)
        } catch (e: Throwable) {
        }
    }

    override fun onDestroy() {
        try {
            com.assisto.assisto.calls.CallsChannel.release()
        } catch (e: Throwable) {
        }
        stopAlarm()
        super.onDestroy()
    }
}
