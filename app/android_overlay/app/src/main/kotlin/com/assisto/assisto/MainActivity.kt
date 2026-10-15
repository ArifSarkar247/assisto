package com.assisto.assisto

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Vibrator
import android.os.VibratorManager
import android.os.VibrationEffect
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
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
 * Channel: "com.assisto/device_admin"
 *   isAdminActive()            -> Bool
 *   requestAdmin()             -> Bool (launches the system consent screen)
 *   lockNow()                  -> Bool (requires active admin)
 *   startAlarm()               -> Bool (loud alarm-stream sound + vibrate)
 *   stopAlarm()                -> Bool
 *   openAdminSettings()        -> Bool (so the user can DEACTIVATE/uninstall)
 *
 * Every call that needs admin re-checks isAdminActive() so Dart can never fake
 * a protection that the OS hasn't actually granted.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.assisto/device_admin"
    private var alarmPlayer: MediaPlayer? = null

    private val adminComponent: ComponentName
        get() = ComponentName(this, AssistoDeviceAdminReceiver::class.java)

    private val dpm: DevicePolicyManager
        get() = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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

                    // CI launch-safety probe: returns the "ao_open" intent extra
                    // (a ChatNav route name) so the emulator smoke test can open
                    // one feature screen and exercise its real native plugins.
                    // Null for normal launches — Dart only reads it in debug.
                    "aoSmokeOpen" -> result.success(intent?.getStringExtra("ao_open"))

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

    override fun onDestroy() {
        stopAlarm()
        super.onDestroy()
    }
}
