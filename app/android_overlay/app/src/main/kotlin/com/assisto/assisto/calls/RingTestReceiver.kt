package com.assisto.assisto.calls

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * ring-everywhere CI proof hook (job ring-proof in android.yml) — INERT in
 * every shipped build:
 *   * the manifest entry requires android.permission.DUMP, which only the
 *     adb shell / system hold (no installed app can send it);
 *   * it does nothing unless the app ARMED it: only the CI smoke APK
 *     (--dart-define=ASSISTO_SMOKE=true) writes the "ring_test_armed" flag,
 *     after its first frame (main.dart _maybeSmokeOpen). Store builds never do.
 *
 *   adb shell am broadcast -f 0x20 -a com.assisto.assisto.RING_TEST \
 *       -n com.assisto.assisto/com.assisto.assisto.calls.RingTestReceiver \
 *       --es call_id 990001 --es caller_name "CI Caller"
 * runs EXACTLY the native path an FCM ring push runs (IncomingCall.onCallPush,
 * the app process cold-started by the broadcast like FCM would) and logs
 * RING_TEST shown=<bool>. Extra "cancel"=true dismisses it.
 */
class RingTestReceiver : BroadcastReceiver() {
    companion object {
        const val KEY_ARMED = "ring_test_armed"

        @JvmStatic
        fun arm(ctx: Context) {
            try {
                ctx.getSharedPreferences(CallAck.PREFS, Context.MODE_PRIVATE).edit()
                    .putBoolean(KEY_ARMED, true).apply()
            } catch (_: Throwable) {
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent?) {
        try {
            val ctx = context.applicationContext
            val armed = ctx.getSharedPreferences(CallAck.PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_ARMED, false)
            if (!armed) {
                Log.i("AssistoRing", "RING_TEST ignored (not a smoke build)")
                return
            }
            val callId = intent?.getStringExtra("call_id") ?: "990001"
            if (intent?.getBooleanExtra("cancel", false) == true) {
                IncomingCall.cancel(ctx, callId)
                Log.i("AssistoRing", "RING_TEST cancelled id=$callId")
                return
            }
            val name = intent?.getStringExtra("caller_name") ?: "CI Caller"
            val data = mapOf(
                "kind" to "call", "call_id" to callId, "caller_name" to name,
                "caller_id" to "0", "video" to "false", "lang" to "en",
                "title" to "$name is calling", "body" to "Voice call",
                "channel" to "calls", "route" to "circle/call", "ack_sig" to "",
            )
            val shown = IncomingCall.onCallPush(ctx, data, force = true)
            Log.i("AssistoRing", "RING_TEST shown=$shown id=${IncomingCall.notificationId(callId)}")
        } catch (t: Throwable) {
            Log.w("AssistoRing", "RING_TEST failed: ${t.javaClass.simpleName}")
        }
    }
}
