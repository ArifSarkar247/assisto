package com.assisto.assisto.notiflisten

/**
 * callmoney — the ONLY notifications Assisto's listener may look at.
 *
 * Mirrors app/lib/notiflisten/notif_allow_list.dart (a Dart test compares the
 * two lists, so they never drift). Decisions here use ONLY the posting package
 * name, the notification category/flags and (for the default SMS app) the
 * sender title. Message TEXT is read only after [moneySource] said yes.
 */
object NotifAllow {
    /** Wallet + bank apps: package -> wallet slug. Exact match only. */
    val MONEY_APPS: Map<String, String> = mapOf(
        "com.bKash.customerapp" to "bkash",
        "com.konasl.nagad" to "nagad",
        "com.dbbl.mbs.apps.main" to "rocket",
        "com.dbbl.nexus.pay" to "bank",
        "com.ibbl.cellfin" to "bank",
        "com.thecitybank.citytouch" to "bank",
    )

    /** SMS sender ids (upper-case, no spaces/dots/dashes) -> wallet slug. */
    val MONEY_SMS_SENDERS: Map<String, String> = mapOf(
        "BKASH" to "bkash", "16247" to "bkash",
        "NAGAD" to "nagad", "16167" to "nagad",
        "ROCKET" to "rocket", "DBBL" to "rocket", "16216" to "rocket",
        "UPAY" to "upay",
        "BRACBANK" to "bank", "CITYBANK" to "bank", "EBL" to "bank", "IBBL" to "bank",
        "MTB" to "bank", "PRIMEBANK" to "bank", "SCB" to "bank", "UCB" to "bank",
        "SONALIBANK" to "bank", "JANATABANK" to "bank", "AGRANIBANK" to "bank",
        "PUBALIBANK" to "bank", "BANKASIA" to "bank", "DHAKABANK" to "bank",
        "ONEBANK" to "bank", "NCCBANK" to "bank", "SIBL" to "bank", "FSIBL" to "bank",
        "AIBL" to "bank", "TRUSTBANK" to "bank", "JAMUNABANK" to "bank",
        "MERCANTILE" to "bank", "SEBL" to "bank", "ABBANK" to "bank",
    )

    /** WhatsApp / Messenger call notifications: package -> call source. */
    val VOIP_CALL_APPS: Map<String, String> = mapOf(
        "com.whatsapp" to "whatsapp",
        "com.whatsapp.w4b" to "whatsapp",
        "com.facebook.orca" to "messenger",
        "com.facebook.mlite" to "messenger",
    )

    /** Phone (SIM) in-call UIs, on top of the phone's default dialer. */
    val DIALER_APPS: Set<String> = setOf(
        "com.google.android.dialer", "com.android.dialer", "com.android.incallui",
        "com.samsung.android.incallui", "com.samsung.android.dialer",
        "com.android.server.telecom", "com.oplus.dialer", "com.coloros.dialer",
        "com.oplus.incallui", "com.transsion.dialer",
    )

    fun normSender(title: String?): String {
        val t = (title ?: "").trim()
        if (t.isEmpty() || t.contains(' ')) return ""   // saved contact names have spaces
        return t.uppercase().replace("-", "").replace("_", "").replace(".", "")
    }

    /** Wallet slug for an SMS sender title, or null (= never read the text). */
    fun smsSenderWallet(title: String?): String? {
        val n = normSender(title)
        if (n.isEmpty()) return null
        return MONEY_SMS_SENDERS[n]
    }

    /** "sim" / "whatsapp" / "messenger" or null (= not a call we track). */
    fun callSource(pkg: String, defaultDialer: String?): String? {
        VOIP_CALL_APPS[pkg]?.let { return it }
        if (pkg == defaultDialer || pkg in DIALER_APPS) return "sim"
        return null
    }

    /** Is this package one whose notifications MAY be read for money? */
    fun moneyPackageKind(pkg: String, defaultSms: String?): String? {
        if (MONEY_APPS.containsKey(pkg)) return "app"
        if (defaultSms != null && pkg == defaultSms) return "sms"
        return null
    }
}
