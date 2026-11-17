package com.assisto.assisto.notiflisten

/**
 * ai-reply-notif — which notifications may EVER get suggested replies.
 *
 * Pure Kotlin (no Android types) so the rules are easy to read and are
 * mirrored + tested by app/lib/notiflisten/ai_reply_notif_rules.dart
 * (a Dart test compares the package lists so they never drift).
 *
 * Order (cheapest, least-revealing first):
 *  1. the package must be one of [CHAT_APPS] AND switched on by the user;
 *  2. it must never be on [BLOCKED_PACKAGES] (banks / MFS / SMS / system);
 *  3. only then are sender + text looked at, and [blockedText] drops OTP,
 *     money / payment and SOS / emergency messages (no suggestions at all).
 * The server runs its own checks on top (lane ai-reply-core).
 */
object AiReplyAllow {
    /** Chat apps the user can switch on (package -> slug). Exact match only. */
    val CHAT_APPS: Map<String, String> = linkedMapOf(
        "com.whatsapp" to "whatsapp",
        "com.whatsapp.w4b" to "whatsapp_business",
        "com.facebook.orca" to "messenger",
        "com.facebook.mlite" to "messenger",
        "org.telegram.messenger" to "telegram",
        "org.telegram.messenger.web" to "telegram",
        "com.imo.android.imoim" to "imo",
        "com.imo.android.imous" to "imo",
        "com.viber.voip" to "viber",
        "org.thoughtcrime.securesms" to "signal",
    )

    /** Assisto's own My Circle chat (our package, our chat channel only). */
    const val MY_CIRCLE = "mycircle"
    val MY_CIRCLE_CHANNELS: Set<String> = setOf("chat_msg_v2", "messages")

    /** Never, whatever the user switched on: banks, MFS, SMS, system, OTP apps. */
    val BLOCKED_PACKAGES: Set<String> = setOf(
        "com.bKash.customerapp", "com.bkash.businessapp", "com.konasl.nagad",
        "com.dbbl.mbs.apps.main", "com.dbbl.nexus.pay", "com.ibbl.cellfin",
        "com.thecitybank.citytouch", "com.upay.android", "com.bracbank.astha",
        "com.ebl.skybanking", "com.mtb.smart", "com.primebank.mybank",
        "com.google.android.apps.messaging", "com.android.mms", "com.android.messaging",
        "com.samsung.android.messaging", "com.oplus.mms", "com.coloros.mms",
        "com.android.systemui", "android", "com.android.phone",
        "com.google.android.gms", "com.android.settings",
    )

    /** Package-name words that always block (a bank app we did not list). */
    private val BLOCKED_WORDS = listOf("bank", "bkash", "nagad", "rocket", "upay", "wallet", "pay", "otp", "mms", "sms")

    fun isBlockedPackage(pkg: String): Boolean {
        if (pkg in BLOCKED_PACKAGES) return true
        if (CHAT_APPS.containsKey(pkg)) return false // exact chat apps win over words
        val p = pkg.lowercase()
        return BLOCKED_WORDS.any { p.contains(it) }
    }

    /** Slug for an allowed chat package, or null (= never read). */
    fun chatSlug(pkg: String, ownPkg: String, channelId: String?): String? {
        if (pkg == ownPkg) return if (channelId != null && channelId in MY_CIRCLE_CHANNELS) MY_CIRCLE else null
        if (isBlockedPackage(pkg)) return null
        return CHAT_APPS[pkg]
    }

    // ------------------------------------------------------------- text checks
    // OTP / verification codes (English + Bangla), with or without digits.
    private val OTP_RX = Regex(
        "\\botp\\b|one[- ]time|verification|verify|passcode|password|\\bpin\\b|\\bcode\\b|" +
            "ওটিপি|কোড|পিন|পাসওয়ার্ড|যাচাই",
        RegexOption.IGNORE_CASE)
    private val CODE_DIGITS_RX = Regex("(?<![\\d০-৯])[\\d০-৯]{4,8}(?![\\d০-৯])")

    // Money / payments / MFS.
    private val MONEY_RX = Regex(
        "৳|\\btk\\b|\\btaka\\b|\\bbdt\\b|টাকা|bkash|bikash|nagad|rocket|upay|send ?money|cash ?out|" +
            "cash ?in|payment|\\bpay\\b|\\bpaid\\b|transfer|loan|\\bdue\\b|account ?(no|number)|a/c|" +
            "trx|txn|balance|বিকাশ|নগদ|রকেট|পেমেন্ট|ধার|লোন|ব্যালেন্স|পাঠাও টাকা|টাকা পাঠা",
        RegexOption.IGNORE_CASE)

    // SOS / emergency / danger.
    private val SOS_RX = Regex(
        "\\bsos\\b|emergency|help me|save me|accident|hospital|ambulance|police|kidnap|" +
            "জরুরি|বাঁচাও|বাচাও|সাহায্য কর|দুর্ঘটনা|হাসপাতাল|অ্যাম্বুলেন্স|পুলিশ|বিপদ",
        RegexOption.IGNORE_CASE)

    /** "otp" | "money" | "sos" when the message must NOT get suggestions, else null. */
    fun blockedText(sender: String?, text: String?): String? {
        val t = (text ?: "").trim()
        if (t.isEmpty()) return "empty"
        val all = "${sender ?: ""}\n$t"
        if (SOS_RX.containsMatchIn(all)) return "sos"
        if (OTP_RX.containsMatchIn(all)) return "otp"
        if (CODE_DIGITS_RX.containsMatchIn(t) && t.length < 200) return "otp"
        if (MONEY_RX.containsMatchIn(all)) return "money"
        return null
    }

    /** Short, single-line, no control characters — safe for a notification action. */
    fun cleanSuggestion(s: String?): String? {
        val v = (s ?: "").replace(Regex("[\\r\\n\\t]+"), " ").trim()
        if (v.isEmpty() || v.length > 120) return null
        return v
    }
}
