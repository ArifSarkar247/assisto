package com.assisto.assisto.calls

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONObject

/**
 * ring-everywhere — the NATIVE incoming-call ring (owner 24 Oct: "CALLS MUST
 * RING LIKE WHATSAPP ON EVERY PHONE").
 *
 * WHY: before this, a call push was drawn by Dart in the FCM BACKGROUND
 * ISOLATE (push_notifier.dart). With Assisto closed / swiped away on an
 * aggressive OEM (ColorOS, MIUI, XOS, Funtouch…) that isolate starts late or
 * not at all, so the phone stayed silent. Now AssistoFcmService calls
 * [onCallPush] FIRST, on the FCM service thread, before Flutter is touched:
 *
 *   * one notification per call id: id = FNV-1a 31-bit of "call-<id>" — the
 *     SAME id PushPayload.notificationId computes in Dart, so the Dart
 *     fallback sees it active and draws nothing, and every Dart cancel
 *     (call_cancel, Accept, Decline) removes it;
 *   * Android 12+: Notification.CallStyle.forIncomingCall (system Answer /
 *     Decline buttons, shown as a call); 8-11: a call-category notification
 *     with the same two actions;
 *   * full-screen intent (lock screen / screen off), heads-up over other apps,
 *     category CALL, public on the lock screen, FLAG_INSISTENT ringtone on the
 *     call channel ("calls" or the per-contact ringtone channel Dart created —
 *     the same SharedPreferences keys CallSoundPrefs reads), 45 s timeout;
 *   * the intents use flutter_local_notifications' own contract (action
 *     SELECT_NOTIFICATION / SELECT_FOREGROUND_NOTIFICATION + "notificationId",
 *     "payload", "actionId") so the EXISTING Dart routing opens the incoming
 *     call screen (tap / full-screen) or answers (Answer) — cold start
 *     (getNotificationAppLaunchDetails) and warm (onNewIntent) alike;
 *   * Decline is handled natively (CallActionReceiver -> server ack with the
 *     push's per-call signature), no Flutter needed;
 *   * also reported to Telecom as a self-managed VoIP call (TelecomBridge),
 *     crash-guarded; if Telecom refuses, this notification still rings.
 *
 * App in the FOREGROUND (MainActivity resumed): nothing is drawn here — the
 * running app shows its full in-app incoming screen as before.
 * Everything is try/catch: this can never crash the FCM service.
 */
object IncomingCall {
    private const val TAG = "AssistoRing"

    // flutter_local_notifications intent contract (v17, see class doc)
    private const val FLN_SELECT = "SELECT_NOTIFICATION"
    private const val FLN_SELECT_FG = "SELECT_FOREGROUND_NOTIFICATION"
    private const val FLN_ID = "notificationId"
    private const val FLN_PAYLOAD = "payload"
    private const val FLN_ACTION_ID = "actionId"
    private const val FLN_CANCEL = "cancelNotification"
    const val ACTION_ACCEPT = "accept"   // PushNotifier.actionAccept
    const val ACTION_DECLINE = "decline" // PushNotifier.actionDecline
    const val ACTION_REPLY = "call_reply" // CallReply.action (Dart)

    const val RING_TIMEOUT_MS = 45_000L
    private const val FLAG_INSISTENT = Notification.FLAG_INSISTENT

    /** MainActivity onResume / onPause (same process). */
    @Volatile
    @JvmStatic
    var appInForeground = false

    private val main = Handler(Looper.getMainLooper())

    // call id -> the push data (re-post from Telecom's onShowIncomingCallUi)
    private val live = java.util.concurrent.ConcurrentHashMap<String, Map<String, String>>()
    // call ids already cancelled (a late / resent ring must not ring again)
    private val ended = java.util.concurrent.ConcurrentHashMap<String, Long>()

    // ------------------------------------------------------------ pure logic
    /** FNV-1a 31-bit — identical to PushPayload.stableHash (Dart). */
    @JvmStatic
    fun stableHash(s: String): Int {
        var h = 0x811c9dc5L
        for (b in s.toByteArray(Charsets.UTF_8)) {
            h = h xor (b.toLong() and 0xff)
            h = (h * 0x01000193L) and 0xffffffffL
        }
        return (h and 0x7fffffffL).toInt()
    }

    @JvmStatic
    fun notificationId(callId: String): Int = stableHash("call-$callId")

    /** CallSoundPrefs.channelIdFor (Dart): one channel per ringtone uri. */
    @JvmStatic
    fun channelIdFor(uri: String?): String {
        if (uri.isNullOrEmpty()) return "calls"
        return "calls_" + Integer.toString(stableHash(uri), 36)
    }

    fun isCall(d: Map<String, String>?): Boolean =
        d != null && d["kind"] == "call" && !d["call_id"].isNullOrEmpty()

    fun isCancel(d: Map<String, String>?): Boolean =
        d != null && d["kind"] == "call_cancel" && !d["call_id"].isNullOrEmpty()

    // ------------------------------------------------------------ entry points
    /** A ring push arrived. True = the ring is on screen now (posted or
     *  already showing); false = not drawn here (app open / ended / error). */
    @JvmStatic
    fun onCallPush(ctx: Context, d: Map<String, String>, force: Boolean = false): Boolean {
        return try {
            val callId = d["call_id"] ?: return false
            pruneEnded()
            if (ended.containsKey(callId)) return false
            if (appInForeground && !force) return false
            val nid = notificationId(callId)
            if (isActive(ctx, nid)) return true      // a resend: ring once only
            live[callId] = d
            val ok = post(ctx, d, nid)
            if (ok) {
                main.postDelayed({ timeout(ctx, callId) }, RING_TIMEOUT_MS + 1_000L)
                try {
                    TelecomBridge.reportIncoming(ctx, callId,
                        d["caller_name"] ?: "", d["video"] == "true")
                } catch (t: Throwable) {
                    Log.w(TAG, "telecom skipped: ${t.javaClass.simpleName}")
                }
            }
            ok
        } catch (t: Throwable) {
            Log.w(TAG, "ring failed: ${t.javaClass.simpleName}")
            false
        }
    }

    /** call_cancel push / server says the call is over. */
    @JvmStatic
    fun onCancelPush(ctx: Context, d: Map<String, String>) {
        val callId = d["call_id"] ?: return
        cancel(ctx, callId)
    }

    @JvmStatic
    fun cancel(ctx: Context, callId: String) {
        try {
            ended[callId] = System.currentTimeMillis()
            live.remove(callId)
            nm(ctx)?.cancel(notificationId(callId))
        } catch (_: Throwable) {
        }
        try {
            TelecomBridge.end(callId)
        } catch (_: Throwable) {
        }
    }

    /** Telecom asked us to show the ringing UI (self-managed call). */
    @JvmStatic
    fun ensureShown(ctx: Context, callId: String) {
        try {
            val d = live[callId] ?: return
            val nid = notificationId(callId)
            if (!isActive(ctx, nid)) post(ctx, d, nid)
        } catch (_: Throwable) {
        }
    }

    /** Telecom "answer" (Bluetooth headset / watch / car). Open the call
     *  screen with the Accept action — best effort: Android may not let a
     *  background app start an activity, the notification stays meanwhile. */
    @JvmStatic
    fun answerFromSystem(ctx: Context, callId: String) {
        try {
            val d = live[callId] ?: return
            val i = launchIntent(ctx, FLN_SELECT_FG, notificationId(callId), d)
                .putExtra(FLN_ACTION_ID, ACTION_ACCEPT)
                .putExtra(FLN_CANCEL, true)
            ctx.startActivity(i)
        } catch (t: Throwable) {
            Log.w(TAG, "answer launch refused: ${t.javaClass.simpleName}")
        }
    }

    /** Decline from the notification button or Telecom. */
    @JvmStatic
    fun decline(ctx: Context, callId: String) {
        val sig = live[callId]?.get("ack_sig") ?: ""
        cancel(ctx, callId)
        Thread {
            try {
                CallAck.post(ctx, callId, sig, "decline")
            } catch (_: Throwable) {
            }
        }.start()
    }

    @JvmStatic
    fun sigFor(callId: String): String = live[callId]?.get("ack_sig") ?: ""

    // ------------------------------------------------------------ call-reply
    /** Reply is offered for a 1:1 ring with a known chat (member id); a
     *  payload with a group marker hides it. Mirrors CallReply.canReply. */
    @JvmStatic
    fun canReply(d: Map<String, String>): Boolean {
        return try {
            if (d["chat_kind"] == "group" || !d["group_id"].isNullOrBlank()) return false
            val id = (d["chat_id"] ?: "").trim().toLongOrNull()
            id != null && id > 0
        } catch (_: Throwable) {
            false
        }
    }

    /** MainActivity onCreate / onNewIntent: was this launch the ring's Reply
     *  button (native or Dart-drawn ring, same flutter_local_notifications
     *  contract)? Then decline exactly like Decline (stop ring + Telecom,
     *  signed server ack) and answer true, so the activity does NOT show
     *  over the lock screen and does NOT mark the call answered. Dart then
     *  opens the chat with the quick-reply sheet (it also sends its own
     *  decline event; the server ignores the second one).
     *  Crash-guarded: any failure falls back to a plain decline. */
    @JvmStatic
    fun onReplyLaunch(ctx: Context, i: Intent?): Boolean {
        try {
            if (i == null || i.getStringExtra(FLN_ACTION_ID) != ACTION_REPLY) return false
            // reopened from Recents: the old Reply intent is redelivered —
            // never decline again, just keep it off the lock screen.
            if ((i.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return true
            var callId = ""
            var sig = ""
            try {
                val raw = i.getStringExtra(FLN_PAYLOAD)
                val js = if (raw != null) JSONObject(raw) else null
                callId = js?.optString("call_id") ?: ""
                sig = js?.optString("ack_sig") ?: ""
            } catch (_: Throwable) {
            }
            if (callId.isEmpty()) return true
            val app = ctx.applicationContext
            val s = sig.ifEmpty { sigFor(callId) }
            cancel(app, callId)
            Thread {
                try {
                    CallAck.post(app, callId, s, "decline")
                } catch (_: Throwable) {
                }
            }.start()
            Log.i(TAG, "REPLY_DECLINED")
            return true
        } catch (t: Throwable) {
            Log.w(TAG, "reply launch failed: ${t.javaClass.simpleName}")
            return try {
                val id = JSONObject(i?.getStringExtra(FLN_PAYLOAD) ?: "{}").optString("call_id")
                if (id.isNotEmpty()) decline(ctx.applicationContext, id)
                id.isNotEmpty()
            } catch (_: Throwable) {
                false
            }
        }
    }

    // ------------------------------------------------------------ drawing
    private fun nm(ctx: Context): NotificationManager? =
        ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    private fun isActive(ctx: Context, nid: Int): Boolean = try {
        nm(ctx)?.activeNotifications?.any { it.id == nid && it.tag == null } == true
    } catch (_: Throwable) {
        false
    }

    private fun timeout(ctx: Context, callId: String) {
        if (!live.containsKey(callId)) return
        live.remove(callId)
        try {
            TelecomBridge.end(callId)
        } catch (_: Throwable) {
        }
        // the notification itself times out by setTimeoutAfter
    }

    private fun pruneEnded() {
        val cut = System.currentTimeMillis() - 5 * 60_000L
        try {
            ended.entries.removeIf { it.value < cut }
        } catch (_: Throwable) {
        }
    }

    private fun smallIcon(ctx: Context): Int {
        return try {
            val id = ctx.resources.getIdentifier("ic_stat_assisto", "drawable", ctx.packageName)
            if (id != 0) id else ctx.applicationInfo.icon
        } catch (_: Throwable) {
            ctx.applicationInfo.icon
        }
    }

    /** The ringtone Dart chose (CallSoundPrefs: per contact -> Assisto
     *  melody -> picked) from the shared_preferences file; null = default. */
    private fun ringtoneUri(ctx: Context, chatId: String): String? {
        return try {
            val p = ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            if (chatId.isNotEmpty()) {
                val c = p.getString("flutter.snd_call_contact_$chatId", null)
                if (!c.isNullOrEmpty()) return c
            }
            if (p.getBoolean("flutter.snd_call_signature", false)) {
                val s = p.getString("flutter.snd_call_signature_uri", null)
                if (!s.isNullOrEmpty()) return s
            }
            val u = p.getString("flutter.snd_call_uri", null)
            if (u.isNullOrEmpty()) null else u
        } catch (_: Throwable) {
            null
        }
    }

    private fun ensureChannel(ctx: Context, lang: String, uri: String?): String {
        val m = nm(ctx) ?: return "calls"
        val id = channelIdFor(uri)
        try {
            if (m.getNotificationChannel(id) != null) return id
            val sound = if (uri.isNullOrEmpty())
                android.provider.Settings.System.DEFAULT_RINGTONE_URI else Uri.parse(uri)
            val ch = NotificationChannel(id, if (lang == "en") "Calls" else "কল",
                NotificationManager.IMPORTANCE_HIGH)
            ch.setSound(sound, AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build())
            ch.enableVibration(true)
            ch.vibrationPattern = longArrayOf(0, 800, 1200, 800, 1200)
            ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            m.createNotificationChannel(ch)
            return id
        } catch (_: Throwable) {
        }
        if (id == "calls") return id
        return ensureChannel(ctx, lang, null)
    }

    private fun payloadJson(d: Map<String, String>): String = try {
        JSONObject(d).toString()
    } catch (_: Throwable) {
        "{}"
    }

    private fun launchIntent(ctx: Context, action: String, nid: Int,
                             d: Map<String, String>): Intent {
        val base = try {
            ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
        } catch (_: Throwable) {
            null
        } ?: Intent(ctx, com.assisto.assisto.MainActivity::class.java)
        return base.setAction(action)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(FLN_ID, nid)
            .putExtra(FLN_PAYLOAD, payloadJson(d))
    }

    private fun piFlags(): Int = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

    private fun post(ctx: Context, d: Map<String, String>, nid: Int): Boolean {
        val m = nm(ctx) ?: return false
        val callId = d["call_id"] ?: return false
        val lang = if (d["lang"] == "en") "en" else "bn"
        val video = d["video"] == "true"
        val name = (d["caller_name"] ?: "").ifBlank { "Assisto" }
        val title = (d["title"] ?: "").ifBlank {
            if (lang == "en") (if (video) "Incoming video call" else "Incoming voice call")
            else (if (video) "ভিডিও কল আসছে" else "ভয়েস কল আসছে")
        }
        val body = (d["body"] ?: "").ifBlank {
            if (lang == "en") (if (video) "Video call" else "Voice call")
            else (if (video) "ভিডিও কল" else "ভয়েস কল")
        }
        val channel = ensureChannel(ctx, lang, ringtoneUri(ctx, d["chat_id"] ?: ""))
        val icon = smallIcon(ctx)

        val content = PendingIntent.getActivity(ctx, nid,
            launchIntent(ctx, FLN_SELECT, nid, d), piFlags())
        val answer = PendingIntent.getActivity(ctx, nid * 16 + 1,
            launchIntent(ctx, FLN_SELECT_FG, nid, d)
                .putExtra(FLN_ACTION_ID, ACTION_ACCEPT)
                .putExtra(FLN_CANCEL, true), piFlags())
        val decline = PendingIntent.getBroadcast(ctx, nid * 16 + 2,
            Intent(ctx, CallActionReceiver::class.java)
                .setAction(CallActionReceiver.ACTION_DECLINE)
                .putExtra(CallActionReceiver.EXTRA_CALL_ID, callId)
                .putExtra(CallActionReceiver.EXTRA_SIG, d["ack_sig"] ?: ""),
            piFlags())
        // call-reply: an ACTIVITY intent (Android 12+ forbids starting an
        // activity from a broadcast trampoline). MainActivity declines
        // natively via onReplyLaunch; a locked phone asks to unlock first.
        val reply: PendingIntent? = try {
            if (canReply(d)) PendingIntent.getActivity(ctx, nid * 16 + 3,
                launchIntent(ctx, FLN_SELECT_FG, nid, d)
                    .putExtra(FLN_ACTION_ID, ACTION_REPLY)
                    .putExtra(FLN_CANCEL, true), piFlags()) else null
        } catch (t: Throwable) {
            Log.w(TAG, "reply action skipped: ${t.javaClass.simpleName}")
            null
        }
        val replyLabel = if (lang == "en") "Reply" else "উত্তর লিখুন"

        fun base(): Notification.Builder = Notification.Builder(ctx, channel)
            .setSmallIcon(icon)
            .setContentTitle(title)
            .setContentText(body)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setShowWhen(true)
            .setContentIntent(content)
            .setFullScreenIntent(content, true)
            .setTimeoutAfter(RING_TIMEOUT_MS)

        fun plain(): Notification {
            val declineLabel = if (lang == "en") "Decline" else "কেটে দিন"
            val acceptLabel = if (lang == "en") "Accept" else "ধরুন"
            val b = base()
                .addAction(Notification.Action.Builder(
                    Icon.createWithResource(ctx, icon), declineLabel, decline).build())
            if (reply != null) {
                b.addAction(Notification.Action.Builder(
                    Icon.createWithResource(ctx, icon), replyLabel, reply).build())
            }
            return b.addAction(Notification.Action.Builder(
                    Icon.createWithResource(ctx, icon), acceptLabel, answer).build())
                .build()
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val person = Person.Builder().setName(name).setImportant(true).build()
                val cb = base()
                    .setStyle(Notification.CallStyle.forIncomingCall(person, decline, answer))
                // call-reply: CallStyle shows one extra action between
                // Decline and Answer (max 3 buttons in total).
                if (reply != null) {
                    cb.addAction(Notification.Action.Builder(
                        Icon.createWithResource(ctx, icon), replyLabel, reply).build())
                }
                val n = cb.build()
                n.flags = n.flags or FLAG_INSISTENT
                m.notify(nid, n)
                Log.i(TAG, "RING_SHOWN style=call id=$nid")
                return true
            } catch (t: Throwable) {
                // some OEM builds reject CallStyle -> the plain call notification
                Log.w(TAG, "CallStyle refused: ${t.javaClass.simpleName}")
            }
        }
        return try {
            val n = plain()
            n.flags = n.flags or FLAG_INSISTENT
            m.notify(nid, n)
            Log.i(TAG, "RING_SHOWN style=plain id=$nid")
            true
        } catch (t: Throwable) {
            Log.w(TAG, "ring notify failed: ${t.javaClass.simpleName}")
            false
        }
    }
}
