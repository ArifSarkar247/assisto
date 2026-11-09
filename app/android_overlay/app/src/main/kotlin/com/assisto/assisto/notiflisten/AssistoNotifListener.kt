package com.assisto.assisto.notiflisten

import android.app.Notification
import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.SystemClock
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.telecom.TelecomManager

/**
 * callmoney — Assisto's notification listener (bound by Android only after the
 * user turns on "Notification access" for Assisto; Assisto's own off switch
 * disables this component, so Android stops binding it at once).
 *
 * Order of checks for EVERY notification (cheapest, least-revealing first):
 *  1. both features off -> return (nothing looked at);
 *  2. package not on [NotifAllow] -> return WITHOUT reading any content;
 *  3. calls: only category / ongoing / chronometer / call-type FLAGS are used
 *     (never the caller name or number);
 *  4. money: wallet/bank app -> title + text; default SMS app -> the sender
 *     title first, and the text only when that sender is allow-listed.
 *
 * NEVER records calls: no microphone, no audio capture. Every callback is
 * wrapped in try/catch(Throwable) so a strange notification can never crash
 * Assisto. No WorkManager, no foreground service.
 */
class AssistoNotifListener : NotificationListenerService() {

    private class CallEntry(val source: String, val firstSeen: Long, var answered: Boolean)

    private val calls = HashMap<String, CallEntry>()
    private var modeListener: Any? = null
    private var inCallSince = 0L

    override fun onListenerConnected() {
        try {
            registerAudioMode()
        } catch (_: Throwable) {
        }
    }

    override fun onListenerDisconnected() {
        try {
            unregisterAudioMode()
        } catch (_: Throwable) {
        }
    }

    override fun onDestroy() {
        try {
            unregisterAudioMode()
        } catch (_: Throwable) {
        }
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        try {
            handlePosted(sbn ?: return)
        } catch (_: Throwable) {
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        try {
            handleRemoved(sbn ?: return)
        } catch (_: Throwable) {
        }
    }

    private fun handlePosted(sbn: StatusBarNotification) {
        val ctx: Context = applicationContext
        if (!NotifListenCore.anyOn(ctx)) return
        val pkg = sbn.packageName ?: return
        if (pkg == ctx.packageName) return
        if (NotifListenCore.callNoteOn(ctx)) {
            val src = NotifAllow.callSource(pkg, defaultDialer(ctx))
            if (src != null) {
                trackCall(sbn, src)
                return
            }
        }
        if (NotifListenCore.moneyOn(ctx)) {
            val kind = NotifAllow.moneyPackageKind(pkg, defaultSms(ctx)) ?: return
            readMoney(ctx, sbn, pkg, kind)
        }
        // every other notification: ignored, its content never read
    }

    // ---------------------------------------------------------------- calls
    private fun isCall(n: Notification): Boolean = n.category == Notification.CATEGORY_CALL

    /** Answered / ongoing — from flags only (never title or text). */
    private fun looksOngoing(n: Notification): Boolean {
        val ex = n.extras
        if (Build.VERSION.SDK_INT >= 31 && ex != null && ex.containsKey(Notification.EXTRA_CALL_TYPE)) {
            return ex.getInt(Notification.EXTRA_CALL_TYPE) == 2 // CallStyle.CALL_TYPE_ONGOING
        }
        if (ex != null && ex.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER, false)) return true
        val ongoing = (n.flags and Notification.FLAG_ONGOING_EVENT) != 0
        return ongoing && n.fullScreenIntent == null
    }

    private fun trackCall(sbn: StatusBarNotification, source: String) {
        val n = sbn.notification ?: return
        if (!isCall(n)) return
        val key = sbn.key ?: return
        val now = SystemClock.elapsedRealtime()
        val e = calls[key] ?: CallEntry(source, now, false).also { calls[key] = it }
        if (looksOngoing(n)) e.answered = true
        if (calls.size > 20) calls.clear() // never grows without bound
    }

    private fun handleRemoved(sbn: StatusBarNotification) {
        val key = sbn.key ?: return
        val e = calls.remove(key) ?: return
        val ctx = applicationContext
        if (!NotifListenCore.callNoteOn(ctx)) return
        val dur = SystemClock.elapsedRealtime() - e.firstSeen
        if (e.answered && dur >= MIN_CALL_MS) {
            NotifListenCore.postCallNote(ctx, e.source, System.currentTimeMillis())
        }
    }

    /** Android 12+: SIM calls also via the audio mode (no permission needed). */
    private fun registerAudioMode() {
        if (Build.VERSION.SDK_INT < 31 || modeListener != null) return
        val am = getSystemService(AudioManager::class.java) ?: return
        val l = AudioManager.OnModeChangedListener { mode -> onMode(mode) }
        am.addOnModeChangedListener(mainExecutor, l)
        modeListener = l
    }

    private fun unregisterAudioMode() {
        if (Build.VERSION.SDK_INT < 31) return
        val l = modeListener as? AudioManager.OnModeChangedListener ?: return
        getSystemService(AudioManager::class.java)?.removeOnModeChangedListener(l)
        modeListener = null
    }

    private fun onMode(mode: Int) {
        try {
            val now = SystemClock.elapsedRealtime()
            if (mode == AudioManager.MODE_IN_CALL) {
                if (inCallSince == 0L) inCallSince = now
            } else if (mode == AudioManager.MODE_NORMAL && inCallSince != 0L) {
                val dur = now - inCallSince
                inCallSince = 0L
                if (dur >= MIN_CALL_MS) {
                    NotifListenCore.postCallNote(applicationContext, "sim", System.currentTimeMillis())
                }
            }
        } catch (_: Throwable) {
        }
    }

    // ---------------------------------------------------------------- money
    private fun readMoney(ctx: Context, sbn: StatusBarNotification, pkg: String, kind: String) {
        val n = sbn.notification ?: return
        if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        val ex = n.extras ?: return
        val title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val wallet: String = if (kind == "sms") {
            // the sender decides; a non-allow-listed sender's text is never read
            NotifAllow.smsSenderWallet(title) ?: return
        } else {
            NotifAllow.MONEY_APPS[pkg] ?: return
        }
        val text = (ex.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: ex.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: return
        if (text.isBlank() || !NotifListenCore.looksLikeTxn(text)) return // OTP / promo: dropped, not stored
        val at = System.currentTimeMillis()
        val id = NotifListenCore.enqueue(ctx, wallet, kind, title, text, at)
        if (id > 0) NotifListenCore.postMoney(ctx, id, wallet, NotifListenCore.amountHint(text), at)
    }

    companion object {
        const val MIN_CALL_MS = 8_000L

        fun defaultSms(ctx: Context): String? = try {
            Telephony.Sms.getDefaultSmsPackage(ctx)
        } catch (_: Throwable) { null }

        fun defaultDialer(ctx: Context): String? = try {
            ctx.getSystemService(TelecomManager::class.java)?.defaultDialerPackage
        } catch (_: Throwable) { null }
    }
}
