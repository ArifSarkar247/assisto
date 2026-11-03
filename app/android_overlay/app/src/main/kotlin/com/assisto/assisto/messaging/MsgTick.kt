package com.assisto.assisto.messaging

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.SystemClock

/**
 * circlebub (owner 3 Nov, part C) — the soft in-app "tick" when a new
 * message lands in the chat that is OPEN on screen (Assisto's own sound,
 * res/raw/assisto_tick.wav, from tool/sounds/make_msg_sounds.py).
 *
 * Plays as a NOTIFICATION sound (USAGE_NOTIFICATION_COMMUNICATION_INSTANT),
 * so Android mutes it on silent / vibrate / Do Not Disturb by itself. Never
 * changes audio routing or volume (the call route stays with
 * audio/AudioRouteChannel.kt); Dart skips it during calls. At most one tick
 * per 1.2 s. Lazy: nothing here runs at app start. Never throws.
 */
object MsgTick {
    private const val MIN_GAP_MS = 1200L
    @Volatile private var last = 0L
    private var ringtone: Ringtone? = null

    fun play(context: Context): Boolean {
        return try {
            val now = SystemClock.elapsedRealtime()
            if (now - last < MIN_GAP_MS) return false
            val am = context.getSystemService(AudioManager::class.java)
            if (am != null && am.ringerMode != AudioManager.RINGER_MODE_NORMAL) return false
            last = now
            val r = ringtone ?: RingtoneManager.getRingtone(
                context,
                Uri.parse("android.resource://${context.packageName}/raw/assisto_tick")
            )?.also {
                it.audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_COMMUNICATION_INSTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) it.isLooping = false
            }
            ringtone = r
            if (r == null) return false
            if (r.isPlaying) r.stop()
            r.play()
            true
        } catch (t: Throwable) {
            false
        }
    }
}
