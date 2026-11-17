package com.assisto.assisto.notiflisten

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * ai-reply-notif — suggested replies inside notifications of chat apps.
 *
 * GATE (lead rule 17 Nov): even when Notification access is already on for
 * callmoney, NOTHING here reads a notification until ALL of these hold:
 *   feature switch from the server (Dart mirrors flag ai_reply_notif) AND the
 *   user agreed on the AI-reply disclosure screen ("ai_consent") AND the
 *   master switch is on AND this chat app is switched on by the user AND a
 *   server token exists. [shouldRead] is that gate; it looks at the package
 *   name + channel only.
 *
 * SENDING: native code NEVER sends a reply on its own. The ONLY call that
 * fires a chat app's reply PendingIntent is [sendFromTap], and the ONLY
 * caller of that is [AiReplyTapReceiver] (a non-exported receiver reached
 * only from the action buttons of our own companion notification = a user
 * tap). A Dart guard test greps for this.
 *
 * PRIVACY: the sender name + the last few lines go to OUR server only to
 * make the replies; nothing is stored on the phone except the companion
 * notification itself. No Accessibility service, no SMS-read permission, no SMS apps.
 */
object AiReplyCore {
    private const val CH = "assisto_ai_reply"
    private const val GROUP = "com.assisto.AI_REPLY"
    private const val NID_BASE = 0x5A00
    private const val NID_SUMMARY = 0x5A00 - 1
    private const val SLOTS = 400
    const val ACTION_TAP = "com.assisto.assisto.AI_REPLY_TAP"
    const val EXTRA_CHOICE = "ar_text"          // the chosen suggestion (null = typed)
    const val EXTRA_TARGET = "ar_target"      // the chat app's reply PendingIntent
    const val EXTRA_KEYS = "ar_keys"          // its RemoteInput result keys
    const val EXTRA_OPEN = "ar_open"          // the chat app's open-chat PendingIntent
    const val EXTRA_NID = "ar_nid"
    const val EXTRA_WHO = "ar_who"
    const val OWN_KEY = "assisto_ai_own"      // our "Write myself" inline box
    private const val MIN_GAP_MS = 2_500L
    private const val HOUR_CAP = 60

    private val io: ExecutorService by lazy { Executors.newSingleThreadExecutor() }
    private val lastText = HashMap<Int, String>()
    private val lastAt = HashMap<Int, Long>()
    private val sentTimes = ArrayDeque<Long>()

    fun prefs(ctx: Context): SharedPreferences = NotifListenCore.prefs(ctx)

    fun masterOn(ctx: Context): Boolean = try {
        val p = prefs(ctx)
        p.getBoolean("ai_on", false) && p.getBoolean("ai_flag", false) &&
            !p.getString("ai_consent", null).isNullOrEmpty()
    } catch (_: Throwable) { false }

    fun enabledApps(ctx: Context): Set<String> = try {
        prefs(ctx).getStringSet("ai_apps", emptySet())?.toSet() ?: emptySet()
    } catch (_: Throwable) { emptySet() }

    /** Package + channel only — no content is read before this says yes. */
    fun shouldRead(ctx: Context, pkg: String, channelId: String?): String? {
        if (!masterOn(ctx)) return null
        val slug = AiReplyAllow.chatSlug(pkg, ctx.packageName, channelId) ?: return null
        if (slug !in enabledApps(ctx)) return null
        if (prefs(ctx).getString("ai_token", null).isNullOrEmpty()) return null
        return slug
    }

    private fun s(ctx: Context, key: String, fallback: String): String {
        val v = prefs(ctx).getString("ais_$key", null)
        return if (v.isNullOrEmpty()) fallback else v
    }

    fun nid(sbnKey: String): Int = NID_BASE + Math.floorMod(sbnKey.hashCode(), SLOTS)

    // ------------------------------------------------------------ extraction
    class Line(val fromMe: Boolean, val sender: String, val text: String)
    class Msg(val sender: String, val text: String, val isGroup: Boolean, val context: List<Line>,
              val reply: Notification.Action, val keys: Array<String>, val open: PendingIntent?)

    /** The chat app's free-form reply action (RemoteInput), or null. */
    fun replyAction(n: Notification): Notification.Action? {
        val acts = n.actions ?: return null
        var best: Notification.Action? = null
        for (a in acts) {
            val ri = a.remoteInputs ?: continue
            if (a.actionIntent == null || ri.isEmpty() || ri.none { it.allowFreeFormInput }) continue
            if (Build.VERSION.SDK_INT >= 28 && a.semanticAction == Notification.Action.SEMANTIC_ACTION_REPLY) return a
            if (best == null) best = a
        }
        return best
    }

    @Suppress("DEPRECATION")
    private fun lines(ex: Bundle): List<Line> {
        val arr: Array<Parcelable> = ex.getParcelableArray(Notification.EXTRA_MESSAGES) ?: return emptyList()
        val out = ArrayList<Line>()
        for (p in arr) {
            val b = p as? Bundle ?: continue
            val text = b.getCharSequence("text")?.toString() ?: continue
            var who: CharSequence? = b.getCharSequence("sender")
            if (who == null && Build.VERSION.SDK_INT >= 28) {
                who = b.getParcelable<android.app.Person>("sender_person")?.name
            }
            out.add(Line(who == null, who?.toString() ?: "", text))
        }
        return out
    }

    /** Reads sender + last text ONLY after [shouldRead] said yes. */
    fun extract(sbn: StatusBarNotification): Msg? {
        val n = sbn.notification ?: return null
        if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return null
        if ((n.flags and Notification.FLAG_ONGOING_EVENT) != 0) return null
        val cat = n.category
        if (cat != null && cat != Notification.CATEGORY_MESSAGE) return null // calls, alarms, system, promo
        val reply = replyAction(n) ?: return null
        val ex = n.extras ?: return null
        val all = lines(ex)
        val title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val isGroup = ex.getBoolean("android.isGroupConversation", false) ||
            ex.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE) != null
        val last = all.lastOrNull()
        val sender: String
        val text: String
        if (last != null) {
            if (last.fromMe) return null // the user already answered
            sender = last.sender.ifEmpty { title }
            text = last.text
        } else {
            sender = title
            text = (ex.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: return null
        }
        val keys = reply.remoteInputs.map { it.resultKey }.toTypedArray()
        return Msg(sender.take(60), text.take(600), isGroup, all.takeLast(6).dropLast(1).map {
            Line(it.fromMe, it.sender.take(60), it.text.take(300))
        }, reply, keys, n.contentIntent)
    }

    // ------------------------------------------------------------ on posted
    fun onPosted(ctx: Context, sbn: StatusBarNotification) {
        val pkg = sbn.packageName ?: return
        shouldRead(ctx, pkg, sbn.notification?.channelId) ?: return // the gate: nothing read before it
        val key = sbn.key ?: return
        val nid = nid(key)
        val msg = extract(sbn) ?: run { cancel(ctx, nid); return } // answered / not a chat message
        if (AiReplyAllow.blockedText(msg.sender, msg.text) != null) { cancel(ctx, nid); return }
        if (msg.context.any { AiReplyAllow.blockedText(null, it.text) == "sos" }) { cancel(ctx, nid); return }
        val now = System.currentTimeMillis()
        synchronized(this) {
            if (lastText[nid] == msg.text) return                      // same message re-posted
            if (now - (lastAt[nid] ?: 0L) < MIN_GAP_MS) return          // a burst: wait for the next
            while (sentTimes.isNotEmpty() && now - sentTimes.first() > 3_600_000L) sentTimes.removeFirst()
            if (sentTimes.size >= HOUR_CAP) return
            sentTimes.addLast(now)
            lastText[nid] = msg.text
            lastAt[nid] = now
            if (lastText.size > SLOTS) { lastText.clear(); lastAt.clear() }
        }
        val app = ctx.applicationContext
        io.execute {
            try {
                val sugg = fetch(app, pkg, msg) ?: return@execute
                post(app, nid, msg, sugg)
            } catch (_: Throwable) {
            }
        }
    }

    fun onRemoved(ctx: Context, sbn: StatusBarNotification) {
        val key = sbn.key ?: return
        val pkg = sbn.packageName ?: return
        if (AiReplyAllow.chatSlug(pkg, ctx.packageName, sbn.notification?.channelId) == null) return
        cancel(ctx, nid(key)) // read / answered in the chat app: our card goes too
    }

    // ------------------------------------------------------------ server
    /** POST <api>/ai/reply/suggest (lane ai-reply-core contract). */
    private fun fetch(ctx: Context, pkg: String, m: Msg): List<String>? {
        val p = prefs(ctx)
        val token = p.getString("ai_token", null) ?: return null
        val base = p.getString("ai_api", null) ?: return null
        val url = (if (base.endsWith("/")) base else "$base/") + "ai/reply/suggest"
        val ctxArr = JSONArray()
        for (l in m.context) ctxArr.put(JSONObject().put("from", if (l.fromMe) "me" else "them").put("text", l.text))
        val body = JSONObject().put("source", "notif").put("app", pkg).put("sender", m.sender)
            .put("text", m.text).put("context", ctxArr).put("lang", "auto") // reply in the language of the message
            .put("is_group", m.isGroup).toString().toByteArray(Charsets.UTF_8)
        var c: HttpURLConnection? = null
        try {
            c = URL(url).openConnection() as HttpURLConnection
            c.requestMethod = "POST"
            c.connectTimeout = 5000
            c.readTimeout = 12000
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            c.setRequestProperty("X-Assisto-AiReply", token)
            c.outputStream.use { it.write(body) }
            val code = c.responseCode
            if (code == 401 || code == 403) { p.edit().remove("ai_token").apply(); return null }
            if (code !in 200..299) return null
            val js = JSONObject(c.inputStream.bufferedReader().use { it.readText() })
            if (!js.optBoolean("ok", false)) {
                if (js.optString("reason") == "no_credits") {
                    // the app (never the notification) offers "unlock with an ad"
                    p.edit().putLong("ai_nocredit_at", System.currentTimeMillis())
                        .putInt("ai_nocredit_n", p.getInt("ai_nocredit_n", 0) + 1).apply()
                }
                return null
            }
            val arr = js.optJSONArray("suggestions") ?: return null
            val out = ArrayList<String>()
            for (i in 0 until arr.length()) AiReplyAllow.cleanSuggestion(arr.optString(i))?.let { out.add(it) }
            return if (out.isEmpty()) null else out.take(3)
        } catch (_: Throwable) {
            return null
        } finally {
            try { c?.disconnect() } catch (_: Throwable) {}
        }
    }

    // ------------------------------------------------------------ companion
    private fun channel(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CH) != null) return
        val ch = NotificationChannel(CH, s(ctx, "channel", "AI reply suggestions"), NotificationManager.IMPORTANCE_LOW)
        ch.setSound(null, null)
        ch.enableVibration(false)
        ch.setShowBadge(false)
        nm.createNotificationChannel(ch)
    }

    private fun icon(ctx: Context): Int {
        val id = try { ctx.resources.getIdentifier("ic_stat_assisto", "drawable", ctx.packageName) } catch (_: Throwable) { 0 }
        return if (id != 0) id else ctx.applicationInfo.icon
    }

    private fun tapIntent(ctx: Context, req: Int, nid: Int, m: Msg, text: String?, mutable: Boolean): PendingIntent {
        val i = Intent(ctx, AiReplyTapReceiver::class.java).setAction("$ACTION_TAP.$req")
            .putExtra(EXTRA_TARGET, m.reply.actionIntent).putExtra(EXTRA_KEYS, m.keys)
            .putExtra(EXTRA_NID, nid).putExtra(EXTRA_WHO, m.sender)
        if (m.open != null) i.putExtra(EXTRA_OPEN, m.open)
        if (text != null) i.putExtra(EXTRA_CHOICE, text)
        val mut = if (mutable && Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE
                  else if (mutable) 0 else PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(ctx, req, i, PendingIntent.FLAG_UPDATE_CURRENT or mut)
    }

    private fun post(ctx: Context, nid: Int, m: Msg, sugg: List<String>) {
        channel(ctx)
        val title = s(ctx, "title", "Reply to %NAME%").replace("%NAME%", m.sender)
        val big = StringBuilder()
        big.append("“").append(m.text.take(140)).append("”\n")
        for (x in sugg) big.append("• ").append(x).append('\n')
        val b = Notification.Builder(ctx, CH)
            .setSmallIcon(icon(ctx))
            .setContentTitle(title)
            .setContentText(sugg.joinToString("  ·  "))
            .setStyle(Notification.BigTextStyle().bigText(big.toString().trim()))
            .setSubText(s(ctx, "sub", "Assisto AI · only you send"))
            .setCategory(Notification.CATEGORY_RECOMMENDATION)
            .setGroup(GROUP)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setTimeoutAfter(2L * 3600 * 1000)
        if (m.open != null) b.setContentIntent(m.open)
        // 2 suggestions as buttons + "Write myself" (Android shows 3 actions)
        sugg.take(2).forEachIndexed { i, x ->
            b.addAction(Notification.Action.Builder(null, x, tapIntent(ctx, nid * 4 + i, nid, m, x, false)).build())
        }
        val own = RemoteInput.Builder(OWN_KEY).setLabel(s(ctx, "own", "Write myself"))
            .setChoices(sugg.toTypedArray<CharSequence>()).setAllowFreeFormInput(true).build()
        b.addAction(Notification.Action.Builder(null, s(ctx, "own", "Write myself"),
            tapIntent(ctx, nid * 4 + 3, nid, m, null, true)).addRemoteInput(own).build())
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        nm.notify(nid, b.build())
        nm.notify(NID_SUMMARY, Notification.Builder(ctx, CH).setSmallIcon(icon(ctx))
            .setContentTitle(s(ctx, "channel", "AI reply suggestions")).setGroup(GROUP)
            .setGroupSummary(true).setOnlyAlertOnce(true).setAutoCancel(true).build())
    }

    /**
     * THE ONLY place a reply leaves the phone into another app. Called ONLY by
     * [AiReplyTapReceiver.onReceive] (a tap on our companion notification).
     * [text] is the suggestion the user tapped or what the user typed.
     */
    fun sendFromTap(ctx: Context, target: PendingIntent, keys: Array<String>, text: String): Boolean {
        val clean = text.trim()
        if (clean.isEmpty() || keys.isEmpty()) return false
        val inputs = keys.map { RemoteInput.Builder(it).build() }.toTypedArray()
        val res = Bundle()
        for (k in keys) res.putCharSequence(k, clean)
        val fill = Intent()
        RemoteInput.addResultsToIntent(inputs, fill, res)
        return try {
            target.send(ctx, 0, fill)
            true
        } catch (_: Throwable) {
            false
        }
    }

    /** After a tap: a short quiet "Sent" (or "Could not send — open chat"). */
    fun afterTap(ctx: Context, nid: Int, who: String, text: String, ok: Boolean, open: PendingIntent?) {
        try {
            channel(ctx)
            val b = Notification.Builder(ctx, CH).setSmallIcon(icon(ctx))
                .setGroup(GROUP).setOnlyAlertOnce(true).setAutoCancel(true)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
            if (ok) {
                b.setContentTitle(s(ctx, "sent", "Sent to %NAME%").replace("%NAME%", who))
                    .setContentText(text).setTimeoutAfter(4000)
            } else {
                b.setContentTitle(s(ctx, "fail", "Could not send. Open the chat to reply."))
                    .setContentText(text).setTimeoutAfter(10L * 60 * 1000)
                if (open != null) b.setContentIntent(open)
            }
            ctx.getSystemService(NotificationManager::class.java)?.notify(nid, b.build())
        } catch (_: Throwable) {
        }
    }

    fun cancel(ctx: Context, nid: Int) {
        try {
            val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
            nm.cancel(nid)
            val left = nm.activeNotifications.count { it.id in NID_BASE until NID_BASE + SLOTS }
            if (left == 0) nm.cancel(NID_SUMMARY)
        } catch (_: Throwable) {
        }
    }

    /** Master off / access revoked / signed out: every card goes, token too. */
    fun cancelAll(ctx: Context) {
        try {
            val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
            for (sb in nm.activeNotifications) {
                if (sb.id == NID_SUMMARY || sb.id in NID_BASE until NID_BASE + SLOTS) nm.cancel(sb.id)
            }
        } catch (_: Throwable) {
        }
        synchronized(this) { lastText.clear(); lastAt.clear() }
    }
}
