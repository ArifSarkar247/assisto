package com.assisto.assisto.voice

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.assisto.assisto.MainActivity

/** One-shot "open Assisto Voice" flag shared by the entry points below. */
object VoiceLaunchState {
    @Volatile private var pending = false
    fun mark() { pending = true }
    fun consume(): Boolean {
        val p = pending
        pending = false
        return p
    }
}

/**
 * Part 3 — the "Digital assistant" entry point.
 *
 * Android lists an app under Settings → Default apps → Digital assistant app
 * when it has an activity handling android.intent.action.ASSIST. Long-press
 * home / the assist gesture then starts THIS tiny, Flutter-free, no-UI
 * activity. It only sets a flag and brings MainActivity forward; Dart reads
 * the flag (consumeAssistLaunch) on first frame / resume and opens the
 * full-screen Assisto Voice listening screen.
 *
 * Why not a VoiceInteractionService: declaring one also requires a
 * RecognitionService, and choosing Assisto as assistant would then make that
 * stub the phone's DEFAULT speech recognizer — breaking speech-to-text for
 * Assisto itself and for every other app. The ACTIVITY route has no such side
 * effect, needs no permission, and runs nothing at app launch.
 */
class AssistEntryActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            VoiceLaunchState.mark()
            val i = Intent(this, MainActivity::class.java)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                )
                .putExtra("assisto_voice", true)
            startActivity(i)
        } catch (ignored: Throwable) {
            // Nothing else to do — never crash the assist gesture.
        }
        finish()
    }
}
