package com.assisto.assisto.train

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Bundle
import android.speech.tts.TextToSpeech
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * train: destination-alarm sound "com.assisto/train_alarm" — the documented
 * siren-style exception (like SOS) allowed by test/audio_route_guard_test.dart:
 *
 *   start(volumeMax: Boolean) -> Boolean   looping alarm tone on STREAM_ALARM /
 *                                          USAGE_ALARM (loud on silent; Android
 *                                          also plays alarms in connected earphones)
 *   speak(text, lang)         -> Boolean   on-device TextToSpeech on USAGE_ALARM
 *                                          (Bangla "bn-BD" when installed, else English)
 *   stop()                    -> Boolean   stops tone + speech and restores volume
 *
 * Lazy: registering the handler is free; MediaPlayer / TextToSpeech are made
 * only on the first start()/speak() from an alarm the user turned on. Every
 * call is crash-guarded and answers false instead of throwing.
 */
object TrainAlarmChannel {
    private const val NAME = "com.assisto/train_alarm"
    private var player: MediaPlayer? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var savedVolume: Int? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(start(app, call.argument<Boolean>("volumeMax") ?: true))
                "speak" -> result.success(
                    speak(app, call.argument<String>("text") ?: "", call.argument<String>("lang") ?: "bn")
                )
                "stop" -> result.success(stop(app))
                else -> result.notImplemented()
            }
        }
    }

    private fun alarmAttrs(): AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    private fun start(app: Context, volumeMax: Boolean): Boolean {
        return try {
            stopTone()
            val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (volumeMax) {
                if (savedVolume == null) savedVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
                am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
            }
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: return false
            player = MediaPlayer().apply {
                setAudioAttributes(alarmAttrs())
                setDataSource(app, uri)
                isLooping = true
                prepare()
                start()
            }
            true
        } catch (e: Throwable) {
            false
        }
    }

    private fun speak(app: Context, text: String, lang: String): Boolean {
        if (text.isBlank()) return false
        return try {
            val t = tts
            if (t != null && ttsReady) {
                say(t, text, lang)
            } else {
                tts = TextToSpeech(app) { status ->
                    ttsReady = status == TextToSpeech.SUCCESS
                    val tt = tts
                    if (ttsReady && tt != null) {
                        try { say(tt, text, lang) } catch (_: Throwable) {}
                    }
                }
            }
            true
        } catch (e: Throwable) {
            false
        }
    }

    private fun say(t: TextToSpeech, text: String, lang: String) {
        t.setAudioAttributes(alarmAttrs())
        val bn = Locale("bn", "BD")
        val ok = lang == "bn" && t.isLanguageAvailable(bn) >= TextToSpeech.LANG_AVAILABLE
        t.language = if (ok) bn else Locale.ENGLISH
        val params = Bundle()
        params.putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_ALARM)
        t.speak(text, TextToSpeech.QUEUE_FLUSH, params, "dest_alarm")
    }

    private fun stopTone() {
        try {
            player?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
        } catch (_: Throwable) {
        }
        player = null
    }

    private fun stop(app: Context): Boolean {
        return try {
            stopTone()
            try { tts?.stop() } catch (_: Throwable) {}
            val v = savedVolume
            if (v != null) {
                val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                am.setStreamVolume(AudioManager.STREAM_ALARM, v, 0)
                savedVolume = null
            }
            true
        } catch (e: Throwable) {
            false
        }
    }
}
