package com.assisto.assisto.calls

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * ring-everywhere: the native ring's DECLINE button (not exported; only our
 * own immutable PendingIntent reaches it). Stops the ring and the Telecom
 * call at once, then tells the server (per-call signature, no Flutter).
 */
class CallActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_DECLINE = "com.assisto.assisto.calls.DECLINE"
        const val EXTRA_CALL_ID = "call_id"
        const val EXTRA_SIG = "sig"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        try {
            if (intent?.action != ACTION_DECLINE) return
            val callId = intent.getStringExtra(EXTRA_CALL_ID) ?: return
            val sig = (intent.getStringExtra(EXTRA_SIG) ?: "")
                .ifEmpty { IncomingCall.sigFor(callId) }
            val ctx = context.applicationContext
            IncomingCall.cancel(ctx, callId)
            val pending = goAsync()
            Thread {
                try {
                    CallAck.post(ctx, callId, sig, "decline")
                } catch (_: Throwable) {
                } finally {
                    try { pending.finish() } catch (_: Throwable) {}
                }
            }.start()
        } catch (_: Throwable) {
        }
    }
}
