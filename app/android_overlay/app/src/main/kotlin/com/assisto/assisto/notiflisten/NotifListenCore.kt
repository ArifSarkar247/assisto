package com.assisto.assisto.notiflisten

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject

/**
 * callmoney — local state + the two prompt notifications.
 *
 * Everything here stays ON THE PHONE (app-private SharedPreferences): the
 * user's switches, the localized strings Dart hands over (so no UI text lives
 * in Kotlin), and the short money queue (raw text of allow-listed wallet/bank
 * notifications only, max [MAX_Q] items, deleted as soon as the user saves or
 * ignores them). Nothing is sent to any server from native code. Calls are
 * NEVER recorded: no microphone, no audio capture anywhere in this package.
 */
object NotifListenCore {
    const val PREFS = "assisto_notif_listen"
    const val ACTION_OPEN = "com.assisto.assisto.NOTIF_LISTEN_OPEN"
    const val EXTRA_KIND = "nl_kind"      // callnote | money
    const val EXTRA_MODE = "nl_mode"      // voice | type | income | expense | review
    const val EXTRA_SOURCE = "nl_source"  // sim | whatsapp | messenger | wallet slug
    const val EXTRA_ID = "nl_id"          // money queue id
    const val EXTRA_AT = "nl_at"          // event time (ms)
    private const val CH_CALL = "assisto_call_note"
    private const val CH_MONEY = "assisto_money_notif"
    const val CALL_NID = 0x4C10
    private const val MONEY_NID_BASE = 0x4D00
    const val MAX_Q = 40
    private const val MAX_AGE_MS = 30L * 24 * 3600 * 1000
    private const val DEDUPE_MS = 10L * 60 * 1000
    private const val CALL_DEDUPE_MS = 20L * 1000

    fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun callNoteOn(ctx: Context) = prefs(ctx).getBoolean("callnote", false)
    fun moneyOn(ctx: Context) = prefs(ctx).getBoolean("money", false)
    fun anyOn(ctx: Context) = callNoteOn(ctx) || moneyOn(ctx)

    /** smsswitch (owner Play decision 5, 9 Nov): the SERVER switch
     *  money_notif_sms, mirrored here by the app on open / resume / every few
     *  hours. Default ON (today's behaviour). OFF = a notification from the
     *  default SMS app is ignored before its sender or text is read. */
    fun moneySmsOn(ctx: Context) = prefs(ctx).getBoolean("money_sms", true)

    private fun s(ctx: Context, key: String, fallback: String): String {
        val v = prefs(ctx).getString("s_$key", null)
        return if (v.isNullOrEmpty()) fallback else v
    }

    private fun digits(ctx: Context, v: String): String {
        if (prefs(ctx).getString("lang", "bn") != "bn") return v
        val sb = StringBuilder()
        for (c in v) sb.append(if (c in '0'..'9') (0x09E6 + (c - '0')).toChar() else c)
        return sb.toString()
    }

    // ------------------------------------------------------------ money queue
    @Synchronized
    fun queue(ctx: Context): JSONArray = try {
        JSONArray(prefs(ctx).getString("money_q", "[]") ?: "[]")
    } catch (_: Throwable) {
        JSONArray()
    }

    @Synchronized
    private fun saveQueue(ctx: Context, q: JSONArray) {
        prefs(ctx).edit().putString("money_q", q.toString()).apply()
    }

    /** Adds one allow-listed item; returns its id, or -1 when it is a duplicate. */
    @Synchronized
    fun enqueue(ctx: Context, wallet: String, kind: String, title: String, text: String, at: Long): Long {
        val old = queue(ctx)
        val q = JSONArray()
        for (i in 0 until old.length()) {
            val o = old.optJSONObject(i) ?: continue
            if (at - o.optLong("at") > MAX_AGE_MS) continue
            if (o.optString("text") == text && at - o.optLong("at") < DEDUPE_MS) return -1
            q.put(o)
        }
        val id = prefs(ctx).getLong("money_seq", 0) + 1
        prefs(ctx).edit().putLong("money_seq", id).apply()
        q.put(JSONObject().put("id", id).put("wallet", wallet).put("kind", kind)
            .put("title", title.take(80)).put("text", text.take(600)).put("at", at))
        while (q.length() > MAX_Q) q.remove(0)
        saveQueue(ctx, q)
        return id
    }

    @Synchronized
    fun removeIds(ctx: Context, ids: Set<Long>) {
        val old = queue(ctx)
        val q = JSONArray()
        for (i in 0 until old.length()) {
            val o = old.optJSONObject(i) ?: continue
            if (o.optLong("id") in ids) continue
            q.put(o)
        }
        saveQueue(ctx, q)
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        for (id in ids) try { nm.cancel(moneyNid(id)) } catch (_: Throwable) {}
    }

    /** smsswitch: drops every waiting item of one kind ("sms"), prompts too. */
    @Synchronized
    fun dropKind(ctx: Context, kind: String) {
        val ids = HashSet<Long>()
        val q = queue(ctx)
        for (i in 0 until q.length()) q.optJSONObject(i)?.let { if (it.optString("kind") == kind) ids.add(it.optLong("id")) }
        if (ids.isNotEmpty()) removeIds(ctx, ids)
    }

    @Synchronized
    fun clearQueue(ctx: Context) {
        val ids = HashSet<Long>()
        val q = queue(ctx)
        for (i in 0 until q.length()) q.optJSONObject(i)?.let { ids.add(it.optLong("id")) }
        removeIds(ctx, ids)
    }

    private fun moneyNid(id: Long) = MONEY_NID_BASE + (id % 200).toInt()

    // ------------------------------------------------------------ notifications
    private fun channel(ctx: Context, id: String, name: String) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(id) != null) return
        val ch = NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH)
        ch.setSound(null, null)          // a quiet card: no ring, no buzz
        ch.enableVibration(false)
        nm.createNotificationChannel(ch)
    }

    private fun icon(ctx: Context): Int {
        val id = try {
            ctx.resources.getIdentifier("ic_stat_assisto", "drawable", ctx.packageName)
        } catch (_: Throwable) { 0 }
        return if (id != 0) id else ctx.applicationInfo.icon
    }

    private fun open(ctx: Context, req: Int, kind: String, mode: String, source: String,
                     id: Long, at: Long): PendingIntent {
        val i = (try {
            ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
        } catch (_: Throwable) { null } ?: Intent(ctx, com.assisto.assisto.MainActivity::class.java))
            .setAction(ACTION_OPEN)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_KIND, kind).putExtra(EXTRA_MODE, mode)
            .putExtra(EXTRA_SOURCE, source).putExtra(EXTRA_ID, id).putExtra(EXTRA_AT, at)
        return PendingIntent.getActivity(ctx, req, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** "Call ended — anything to remember?" (deduped: one card per call). */
    fun postCallNote(ctx: Context, source: String, at: Long) {
        try {
            if (!callNoteOn(ctx)) return
            val p = prefs(ctx)
            if (at - p.getLong("last_call_at", 0) < CALL_DEDUPE_MS) return
            p.edit().putLong("last_call_at", at).apply()
            channel(ctx, CH_CALL, s(ctx, "chCall", "After-call notes"))
            val app = s(ctx, "src_$source", source)
            val n = Notification.Builder(ctx, CH_CALL)
                .setSmallIcon(icon(ctx))
                .setContentTitle(s(ctx, "callTitle", "Call ended — anything to remember?"))
                .setContentText(s(ctx, "callBody", "%APP% call · speak or type").replace("%APP%", app))
                .setCategory(Notification.CATEGORY_REMINDER)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .setTimeoutAfter(10L * 60 * 1000)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setContentIntent(open(ctx, CALL_NID, "callnote", "type", source, 0, at))
                .addAction(Notification.Action.Builder(null, s(ctx, "callSpeak", "Speak"),
                    open(ctx, CALL_NID + 1, "callnote", "voice", source, 0, at)).build())
                .addAction(Notification.Action.Builder(null, s(ctx, "callType", "Type"),
                    open(ctx, CALL_NID + 2, "callnote", "type", source, 0, at)).build())
                .build()
            ctx.getSystemService(NotificationManager::class.java)?.notify(CALL_NID, n)
        } catch (_: Throwable) {
        }
    }

    /** "bKash ৳500 — save to khata as income or expense?" */
    fun postMoney(ctx: Context, id: Long, wallet: String, amount: String?, at: Long) {
        try {
            if (!moneyOn(ctx)) return
            channel(ctx, CH_MONEY, s(ctx, "chMoney", "Money from notifications"))
            val w = s(ctx, "w_$wallet", wallet)
            val amt = if (amount.isNullOrEmpty()) "" else digits(ctx, amount)
            val title = s(ctx, "moneyTitle", "%WALLET% %AMOUNT% — save to khata?")
                .replace("%WALLET%", w).replace("%AMOUNT%", if (amt.isEmpty()) "" else "৳$amt")
                .replace("  ", " ").trim()
            val auto = prefs(ctx).getBoolean("money_auto", false)
            val body = if (auto) s(ctx, "moneyBodyAuto", "Saved to khata when you open Assisto")
                       else s(ctx, "moneyBody", "Tap to check and save")
            val nid = moneyNid(id)
            val b = Notification.Builder(ctx, CH_MONEY)
                .setSmallIcon(icon(ctx))
                .setContentTitle(title)
                .setContentText(body)
                .setCategory(Notification.CATEGORY_STATUS)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setContentIntent(open(ctx, nid * 4, "money", "review", wallet, id, at))
            if (!auto) {
                b.addAction(Notification.Action.Builder(null, s(ctx, "moneyIncome", "Income"),
                    open(ctx, nid * 4 + 1, "money", "income", wallet, id, at)).build())
                b.addAction(Notification.Action.Builder(null, s(ctx, "moneyExpense", "Expense"),
                    open(ctx, nid * 4 + 2, "money", "expense", wallet, id, at)).build())
            }
            ctx.getSystemService(NotificationManager::class.java)?.notify(nid, b.build())
        } catch (_: Throwable) {
        }
    }

    // gap-callmoney (17 Nov): the native pre-filter used to DROP real payments:
    //  * "Tk. 500", "BDT: 500", "৫০০ টাকা", "500 Tk" had no amount for it (only
    //    "Tk 500" worked), so Bangla bKash/bank alerts never reached the user;
    //  * bank alerts that end with "Never share your PIN/OTP" were taken as OTPs.
    // test/gap_callmoney_test.dart runs THESE regexes (read from this file) on
    // real-format samples, so the native filter and the Dart parser cannot drift.
    /** Amount next to a currency word, either order. Group 1 or 2 = the number. */
    private val AMOUNT_RX = Regex("(?:tk|bdt|taka|৳)\\.?\\s*:?\\s*([\\d,০-৯]+(?:\\.[\\d০-৯]+)?)|([\\d,০-৯]+(?:\\.[\\d০-৯]+)?)\\s*(?:tk\\b|bdt|taka|টাকা|৳)", RegexOption.IGNORE_CASE)

    /** Fee / balance words right before an amount: never the prompt's amount. */
    private val NOT_AMOUNT_RX = Regex("(?:fee|charge|chrg|bal|balance|ফি|চার্জ|ব্যালেন্স)\\s*(?:is)?\\s*[:.]?\\s*(?:tk|bdt|৳)?\\.?\\s*:?\\s*$", RegexOption.IGNORE_CASE)

    private val PROOF_RX = Regex("trx|txn|balance|\\bbal\\b|a/c|account|ব্যালেন্স|হিসাব", RegexOption.IGNORE_CASE)
    private val SECRET_RX = Regex("otp|verification|\\bcode\\b|\\bpin\\b|password|কোড", RegexOption.IGNORE_CASE)

    /** A safety tip ("Never share your PIN/OTP", "কাউকে বলবেন না") is not an OTP. */
    private val WARN_RX = Regex("(?:never|do\\s*not|don't|dont|not\\s+to)\\s+(?:share|disclose|tell|give)|শে(?:য়|য়)ার করবেন না|কাউকে (?:বলবেন|দেবেন|জানাবেন) না", RegexOption.IGNORE_CASE)
    /** ...unless that sentence itself carries a code ("OTP 482913"). */
    private val CODE_GIVEN_RX = Regex("(?:otp|code|pin|কোড)\\D{0,5}[0-9০-৯]{4,8}", RegexOption.IGNORE_CASE)
    private val SENTENCE_RX = Regex("(?<=[.!?])\\s+|।|\\n")

    fun withoutSafetyTips(text: String): String = try {
        text.split(SENTENCE_RX)
            .filterNot { WARN_RX.containsMatchIn(it) && !CODE_GIVEN_RX.containsMatchIn(it) }
            .joinToString(" ")
    } catch (_: Throwable) { text }

    /** Cheap pre-filter: only something that looks like a real transaction
     *  (an amount + a TrxID / balance / account line, never an OTP) is kept. */
    fun looksLikeTxn(text: String): Boolean = try {
        AMOUNT_RX.containsMatchIn(text) && PROOF_RX.containsMatchIn(text) &&
            !SECRET_RX.containsMatchIn(withoutSafetyTips(text))
    } catch (_: Throwable) { false }

    /** A first amount for the prompt only (Dart re-parses everything): never
     *  the fee or the balance; null = the prompt shows no amount. */
    fun amountHint(text: String): String? = try {
        var out: String? = null
        for (m in AMOUNT_RX.findAll(text)) {
            val before = text.substring(maxOf(0, m.range.first - 24), m.range.first)
            if (NOT_AMOUNT_RX.containsMatchIn(before)) continue
            val raw = m.groups[1]?.value ?: m.groups[2]?.value ?: continue
            val sb = StringBuilder()
            for (c in raw) {
                if (c in '০'..'৯') sb.append('0' + (c - '০')) else sb.append(c)
            }
            val v = sb.toString().trimEnd('.', ',')
            if (v.replace(",", "").toDoubleOrNull()?.let { it > 0 } == true) { out = v; break }
        }
        out
    } catch (_: Throwable) { null }
}
