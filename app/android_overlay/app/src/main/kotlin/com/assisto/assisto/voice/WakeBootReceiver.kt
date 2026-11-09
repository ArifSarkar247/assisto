package com.assisto.assisto.voice

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * k1-wake — after a reboot (or an app update) the wake-word service is NOT
 * running, and Android 14+ forbids starting a microphone foreground service
 * from BOOT_COMPLETED (older versions silence the mic for background starts
 * anyway). So we never touch the microphone here: if the user had
 * "Hey Assisto" on, we only post ONE notification — "Turn on Hey Assisto
 * again" — and a tap opens Assisto, which restarts it in the foreground.
 * Cheap (one SharedPreferences read), crash-guarded, nothing else runs.
 */
class WakeBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        try {
            val a = intent?.action ?: return
            if (a != Intent.ACTION_BOOT_COMPLETED && a != Intent.ACTION_MY_PACKAGE_REPLACED &&
                a != "android.intent.action.QUICKBOOT_POWERON") return
            if (!WakeWordService.prefs(context).getBoolean("wanted", false)) return
            WakeWordService.postResumeNotification(context)
        } catch (ignored: Throwable) {
        }
    }
}
