package com.assisto.assisto.notiflisten

import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * ai-reply-notif — the USER'S TAP on our companion notification ("a reply
 * button" or "Write myself" + typed text). Non-exported: only our own
 * notification action PendingIntents reach it. This is the ONLY caller of
 * [AiReplyCore.sendFromTap] (guard test: ai_reply_notif_test.dart).
 */
class AiReplyTapReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        try {
            val ctx = context?.applicationContext ?: return
            val i = intent ?: return
            if (i.action?.startsWith(AiReplyCore.ACTION_TAP) != true) return
            val nid = i.getIntExtra(AiReplyCore.EXTRA_NID, 0)
            val who = i.getStringExtra(AiReplyCore.EXTRA_WHO) ?: ""
            val open = pi(i, AiReplyCore.EXTRA_OPEN)
            // switched off / access revoked since the card was shown: never send
            if (!AiReplyCore.masterOn(ctx) || !NotifListenChannel.granted(ctx)) {
                AiReplyCore.cancelAll(ctx)
                return
            }
            val typed = RemoteInput.getResultsFromIntent(i)?.getCharSequence(AiReplyCore.OWN_KEY)?.toString()
            val text = (typed ?: i.getStringExtra(AiReplyCore.EXTRA_CHOICE) ?: "").trim()
            val target = pi(i, AiReplyCore.EXTRA_TARGET)
            val keys = i.getStringArrayExtra(AiReplyCore.EXTRA_KEYS) ?: emptyArray()
            if (text.isEmpty() || target == null) {
                AiReplyCore.afterTap(ctx, nid, who, text, false, open)
                return
            }
            val ok = AiReplyCore.sendFromTap(ctx, target, keys, text)
            AiReplyCore.afterTap(ctx, nid, who, text, ok, open)
        } catch (_: Throwable) {
        }
    }

    @Suppress("DEPRECATION")
    private fun pi(i: Intent, key: String): PendingIntent? = try {
        i.getParcelableExtra<PendingIntent>(key)
    } catch (_: Throwable) { null }
}
