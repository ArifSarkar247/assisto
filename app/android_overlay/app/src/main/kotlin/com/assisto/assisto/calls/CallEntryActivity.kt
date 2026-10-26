package com.assisto.assisto.calls

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager

/**
 * calls-a: the incoming call's Accept button and full-screen / tap intent
 * open THIS invisible activity, which forwards the same intent to
 * MainActivity in the same instant and finishes.
 *
 * WHY: on a locked phone, SystemUI (and MIUI / ColorOS / Funtouch / One UI)
 * decides from the TARGET ACTIVITY'S MANIFEST whether a notification action
 * may open over the lock screen. MainActivity deliberately has no
 * android:showWhenLocked in the manifest (that would show chats and the vault
 * on a locked phone) — so "Accept" on the lock screen first asked to unlock,
 * or opened behind the keyguard, and the call came up late. This activity
 * declares showWhenLocked + turnScreenOn (manifest patch in android.yml),
 * draws nothing (translucent, no history, not in Recents, its own task) and
 * only ever forwards a CALL intent; MainActivity then shows over the lock
 * screen for that one launch, exactly as before (its runtime policy).
 *
 * Not exported: only our own immutable PendingIntents reach it. Every step is
 * try/catch and it always finishes, so it can never get stuck or crash.
 */
class CallEntryActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
            }
        } catch (_: Throwable) {
        }
        try {
            val src = intent
            if (savedInstanceState == null && CallLaunch.parse(src) != null) {
                val fwd = Intent(src)
                    .setClass(this, com.assisto.assisto.MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(fwd)
                Log.i("AssistoCall", "CALL_ENTRY_FORWARD ok")
            }
        } catch (t: Throwable) {
            Log.w("AssistoCall", "call entry forward failed: ${t.javaClass.simpleName}")
        }
        try {
            finish()
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        } catch (_: Throwable) {
        }
    }
}
