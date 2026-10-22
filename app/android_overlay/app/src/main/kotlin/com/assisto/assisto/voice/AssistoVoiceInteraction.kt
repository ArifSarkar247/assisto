package com.assisto.assisto.voice

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService
import com.assisto.assisto.MainActivity

/**
 * Part 3 — Assisto as the phone's DEFAULT DIGITAL ASSISTANT (VIS path).
 *
 * Why a VoiceInteractionService (re-checked against AOSP for Android 12–14):
 * every assist trigger — long-press POWER ("Hold for assistant"), long-press
 * HOME, the corner-swipe gesture — goes through SystemUI AssistManager.
 * startAssist(). If the ROLE_ASSISTANT holder has an active VIS it calls
 * showSessionForActiveService() → our session window is shown ABOVE THE
 * KEYGUARD. A plain ACTION_ASSIST activity is only start()-ed as a normal
 * activity, which on a locked phone stays hidden behind the lock screen until
 * the user unlocks. "Listen instantly, even from the lock screen" therefore
 * needs this VIS. [AssistEntryActivity] stays as the fallback for OEMs / the
 * VOICE_COMMAND (headset button) path.
 *
 * Nothing here runs Flutter. The session only marks the launch and starts
 * MainActivity with "assisto_voice" (+ "assisto_voice_locked") extras;
 * MainActivity applies showWhenLocked for that one launch
 * ([AssistoVoiceChannel.applyLaunchIntent]) and Dart opens the listening
 * screen. Everything is try/catch-guarded.
 */
class AssistoVoiceInteractionService : VoiceInteractionService() {
    companion object {
        @Volatile var active: AssistoVoiceInteractionService? = null

        /** Wake word → show our session (works from background + lock screen). */
        fun showFromWake(): Boolean {
            val s = active ?: return false
            return try {
                s.showSession(Bundle().apply { putBoolean("wake", true) }, 0)
                true
            } catch (ignored: Throwable) {
                false
            }
        }
    }

    override fun onReady() {
        super.onReady()
        active = this
    }

    override fun onShutdown() {
        if (active === this) active = null
        super.onShutdown()
    }

    /** The keyguard's voice affordance (supportsLaunchVoiceAssistFromKeyguard). */
    override fun onLaunchVoiceAssistFromKeyguard() {
        launchVoiceUi(this, locked = true, starter = null)
    }
}

class AssistoVoiceSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession =
        AssistoVoiceSession(this)
}

class AssistoVoiceSession(context: Context) : VoiceInteractionSession(context) {
    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        try {
            val km = context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            val locked = km?.isKeyguardLocked == true
            launchVoiceUi(context, locked, this)
        } catch (ignored: Throwable) {
        }
        // Our UI is the Flutter screen; the (empty) session window is not needed.
        try { hide() } catch (ignored: Throwable) {}
    }
}

/** Start MainActivity on the Assisto Voice screen. */
internal fun launchVoiceUi(ctx: Context, locked: Boolean, starter: VoiceInteractionSession?) {
    VoiceLaunchState.mark()
    val i = Intent(ctx, MainActivity::class.java)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        .putExtra("assisto_voice", true)
        .putExtra("assisto_voice_locked", locked)
    try {
        if (starter != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Allowed from a shown session even when Assisto is in background.
            starter.startAssistantActivity(i)
        } else {
            ctx.startActivity(i)
        }
    } catch (ignored: Throwable) {
        try { ctx.startActivity(i) } catch (ignored2: Throwable) {}
    }
}
