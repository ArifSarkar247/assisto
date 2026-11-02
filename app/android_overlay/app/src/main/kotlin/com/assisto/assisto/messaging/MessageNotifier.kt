package com.assisto.assisto.messaging

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import org.json.JSONObject

/**
 * notifs (owner 2 Nov: "My Circle messages show NO notification") — the
 * NATIVE SAFETY NET for message pushes + the ONE native builder of a message
 * notification ([buildMessageNotification]; agent/bubbles extends it).
 *
 * Normal path (unchanged): Dart (FCM background isolate / foreground
 * listener) pulls the ciphertext window, decrypts ON THE DEVICE and draws the
 * MessagingStyle conversation (tag "c3chat:<kind>:<id>").
 *
 * Safety net: AssistoFcmService calls [onMessagePush] for every "message"
 * push. After [CHECK_MS] we look: did Dart draw a notification for that chat
 * since the push arrived, or record the message id in `flutter.c3_push_done`
 * (open chat / already read elsewhere / drawn)? If NEITHER, the Dart isolate
 * never ran (ColorOS / MIUI cold start, crash, secure-storage failure…) and
 * we draw "<sender>: নতুন মেসেজ" ourselves — same tag + id, so a late Dart
 * notification simply replaces it. Reply / Mark as read / tap use
 * flutter_local_notifications' own intent contract, so the existing Dart
 * handlers (handleMsgNotificationAction, _onLocalResponse) run them.
 *
 * Privacy: sender name only when the push allows previews (preview=1), the
 * device switch `c3_msg_hide_content` is off and the chat is not locked
 * (`e_chat_lock_v1`). Never message text (it is end-to-end encrypted).
 * Lazy (only on a push), everything try/catch: never crashes the service.
 * The pure decisions are mirrored in Dart (lib/messaging/msg_fallback.dart)
 * and unit-tested there; keep both in sync.
 */
object MessageNotifier {
    private const val TAG = "AssistoMsgNotif"
    private const val PREFS = "FlutterSharedPreferences"
    const val CHECK_MS = 9_000L

    // flutter_local_notifications v17 intent contract (see IncomingCall.kt)
    private const val FLN_SELECT = "SELECT_NOTIFICATION"
    private const val FLN_ACTION_TAPPED =
        "com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver.ACTION_TAPPED"
    private const val FLN_ACTION_RECEIVER =
        "com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver"
    private const val FLN_ID = "notificationId"
    private const val FLN_TAG = "notificationTag"
    private const val FLN_ACTION_ID = "actionId"
    private const val FLN_CANCEL = "cancelNotification"
    private const val FLN_PAYLOAD = "payload"
    private const val FLN_INPUT = "FlutterLocalNotificationsPluginInputResult"
    private const val ACTION_REPLY = "c3_reply" // kActionReply (Dart)
    private const val ACTION_READ = "c3_read"   // kActionRead (Dart)
    private const val GROUP_KEY = "com.assisto.MESSAGES" // kMsgGroupKey

    /** Everything a message notification shows (no message text: E2E). */
    data class MessageSpec(
        val kind: String,        // member | group
        val chatId: String,
        val title: String,       // sender name or "Assisto"
        val text: String,        // "নতুন মেসেজ" / "New message"
        val lang: String,
        val canReply: Boolean,
    )

    // ------------------------------------------------------------ pure logic
    fun kindOf(d: Map<String, String>) = if (d["chat_kind"] == "group") "group" else "member"
    fun tagFor(kind: String, id: String) = "c3chat:$kind:$id"

    /** Same id as Dart notifIdFor / PushPayload.notificationId. */
    fun notificationId(kind: String, id: String): Int =
        com.assisto.assisto.calls.IncomingCall.stableHash("chat-$kind-$id")

    fun doneContains(raw: String?, messageId: String): Boolean =
        messageId.isNotEmpty() && (raw ?: "").split(",").any { it.trim() == messageId }

    fun lockedChat(raw: String?, key: String): Boolean = try {
        val arr = JSONObject(raw ?: "{}").optJSONArray("c")
        var hit = false
        if (arr != null) for (i in 0 until arr.length()) if (arr.optString(i) == key) hit = true
        hit
    } catch (_: Throwable) {
        false
    }

    /** Mirrors fallbackSpec() in lib/messaging/msg_fallback.dart. */
    fun specFor(d: Map<String, String>, hideContent: Boolean, locked: Boolean): MessageSpec {
        val lang = if (d["lang"] == "en") "en" else "bn"
        val kind = kindOf(d)
        val hidden = hideContent || locked || d["preview"] == "0"
        val name = (d["sender_name"] ?: "").trim()
        val title = if (hidden || name.isEmpty()) "Assisto" else name
        val text = if (lang == "en") "New message" else "নতুন মেসেজ"
        return MessageSpec(kind, (d["chat_id"] ?: "").trim(), title, text, lang, canReply = !locked)
    }

    // ------------------------------------------------------------ safety net
    /** From AssistoFcmService for every data push (FCM thread). */
    fun onMessagePush(context: Context, data: Map<String, String>) {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            if (data["kind"] != "message") return
            val id = (data["chat_id"] ?: "").trim()
            if (id.isEmpty()) return
            val app = context.applicationContext
            val since = System.currentTimeMillis()
            val wl = try {
                (app.getSystemService(Context.POWER_SERVICE) as? PowerManager)
                    ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "assisto:msgnet")
                    ?.apply { acquire(CHECK_MS + 4_000L) }
            } catch (_: Throwable) {
                null
            }
            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    check(app, HashMap(data), since)
                } catch (t: Throwable) {
                    Log.w(TAG, "check skipped: ${t.javaClass.simpleName}")
                } finally {
                    try {
                        if (wl?.isHeld == true) wl.release()
                    } catch (_: Throwable) {
                    }
                }
            }, CHECK_MS)
        } catch (t: Throwable) {
            Log.w(TAG, "schedule skipped: ${t.javaClass.simpleName}")
        }
    }

    private fun check(ctx: Context, d: Map<String, String>, since: Long) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (doneContains(p.getString("flutter.c3_push_done", ""), (d["message_id"] ?: "").trim())) return
        val kind = kindOf(d)
        val id = (d["chat_id"] ?: "").trim()
        val tag = tagFor(kind, id)
        val nid = notificationId(kind, id)
        val drawn = try {
            nm.activeNotifications.any {
                (it.tag == tag || (it.tag.isNullOrEmpty() && it.id == nid)) &&
                    it.postTime >= since - 1_000L
            }
        } catch (_: Throwable) {
            false
        }
        if (drawn) return
        val hide = try {
            p.getBoolean("flutter.c3_msg_hide_content", false)
        } catch (_: Throwable) {
            false
        }
        val locked = lockedChat(p.getString("flutter.e_chat_lock_v1", null), "$kind:$id")
        val spec = specFor(d, hide, locked)
        Log.i(TAG, "Dart drew nothing in ${CHECK_MS}ms — native fallback ($kind)")
        nm.notify(tag, nid, buildMessageNotification(ctx, spec))
    }

    // --------------------------------------------------------------- builder
    /**
     * THE native message notification (agent/bubbles: extend HERE — e.g.
     * add BubbleMetadata on the returned builder output via recoverBuilder,
     * as BubbleHelper.attach already does for Dart-drawn ones).
     */
    fun buildMessageNotification(ctx: Context, s: MessageSpec): Notification {
        val channel = ensureChannel(ctx, s.lang)
        val nid = notificationId(s.kind, s.chatId)
        val tag = tagFor(s.kind, s.chatId)
        val payload = JSONObject()
            .put("kind", "message")
            .put("chat_kind", s.kind)
            .put("chat_id", s.chatId)
            .put("lang", s.lang)
            .put("route", if (s.kind == "group") "circle/group" else "circle/chat")
            .toString()
        val launch = (try {
            ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
        } catch (_: Throwable) {
            null
        } ?: Intent(ctx, com.assisto.assisto.MainActivity::class.java))
            .setAction(FLN_SELECT)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(FLN_ID, nid)
            .putExtra(FLN_PAYLOAD, payload)
        val content = PendingIntent.getActivity(ctx, nid, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val b = Notification.Builder(ctx, channel)
            .setSmallIcon(smallIcon(ctx))
            .setContentTitle(s.title)
            .setContentText(s.text)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setGroup(GROUP_KEY)
            .setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(content)
            .setShowWhen(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val me = Person.Builder().setName(if (s.lang == "en") "You" else "আপনি").setKey("me").build()
                val sender = Person.Builder().setName(s.title).setKey("chat-${s.kind}-${s.chatId}")
                    .setIcon(avatarIcon(ctx)).setImportant(true).build()
                b.setStyle(Notification.MessagingStyle(me)
                    .addMessage(s.text, System.currentTimeMillis(), sender))
            } catch (_: Throwable) {
            }
        }
        if (s.canReply) {
            try {
                b.addAction(actionFor(ctx, nid, tag, payload, ACTION_REPLY,
                    if (s.lang == "en") "Reply" else "উত্তর দিন",
                    RemoteInput.Builder(FLN_INPUT)
                        .setLabel(if (s.lang == "en") "Message" else "মেসেজ লিখুন").build(),
                    cancel = false))
                b.addAction(actionFor(ctx, nid, tag, payload, ACTION_READ,
                    if (s.lang == "en") "Mark as read" else "পড়া হয়েছে", null, cancel = true))
            } catch (_: Throwable) {
            }
        }
        return b.build()
    }

    private fun actionFor(ctx: Context, nid: Int, tag: String, payload: String, actionId: String,
                          label: String, input: RemoteInput?, cancel: Boolean): Notification.Action {
        val i = Intent().setComponent(ComponentName(ctx, FLN_ACTION_RECEIVER))
            .setAction(FLN_ACTION_TAPPED)
            .putExtra(FLN_ID, nid)
            .putExtra(FLN_TAG, tag)
            .putExtra(FLN_ACTION_ID, actionId)
            .putExtra(FLN_CANCEL, cancel)
            .putExtra(FLN_PAYLOAD, payload)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (input != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE
             else PendingIntent.FLAG_IMMUTABLE)
        val pi = PendingIntent.getBroadcast(ctx, nid * 8 + actionId.length, i, flags)
        val a = Notification.Action.Builder(
            Icon.createWithResource(ctx, android.R.drawable.ic_menu_send), label, pi)
        if (input != null) a.addRemoteInput(input)
        return a.build()
    }

    /** The channel Dart's MsgPrefs.channelId() uses (same sound keys). */
    private fun ensureChannel(ctx: Context, lang: String): String {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val uri = try {
            if (p.contains("flutter.snd_msg_uri")) p.getString("flutter.snd_msg_uri", null) else null
        } catch (_: Throwable) {
            null
        }
        val wanted = when {
            uri == null -> "messages"
            uri.isEmpty() -> "messages_silent"
            else -> "messages_" + Integer.toString(
                com.assisto.assisto.calls.IncomingCall.stableHash(uri), 36)
        }
        try {
            if (nm?.getNotificationChannel(wanted) != null) return wanted
            if (nm?.getNotificationChannel("messages") == null) {
                val ch = NotificationChannel("messages",
                    if (lang == "en") "Messages" else "মেসেজ", NotificationManager.IMPORTANCE_HIGH)
                ch.enableVibration(true)
                nm?.createNotificationChannel(ch)
            }
        } catch (_: Throwable) {
        }
        return "messages"
    }

    private fun smallIcon(ctx: Context): Int {
        val id = try {
            ctx.resources.getIdentifier("ic_stat_assisto", "drawable", ctx.packageName)
        } catch (_: Throwable) {
            0
        }
        return if (id != 0) id else ctx.applicationInfo.icon
    }

    private fun avatarIcon(ctx: Context): Icon {
        val res = ctx.resources.getIdentifier("c3_person_avatar", "drawable", ctx.packageName)
        return if (res != 0) Icon.createWithResource(ctx, res)
        else Icon.createWithResource(ctx, android.R.drawable.sym_action_chat)
    }
}
