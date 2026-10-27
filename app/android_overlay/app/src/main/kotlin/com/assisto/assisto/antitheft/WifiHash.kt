package com.assisto.assisto.antitheft

import android.content.Context
import android.net.wifi.WifiManager
import java.security.MessageDigest

/**
 * antitheft2 — the CURRENT Wi-Fi network as a one-way hash (never the name).
 *
 * Used only for the owner's "home Wi-Fi at night" grab rule. Honest limit:
 * Android hides the Wi-Fi name from apps without the location permission
 * (and with location switched off) — then this returns null and the rule
 * simply does not apply. No new permission is requested for it.
 * Must match the server/app: sha256("assisto-wifi:" + ssid) as lowercase hex.
 */
object WifiHash {
    fun current(ctx: Context): String? {
        return try {
            val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE)
                as? WifiManager ?: return null
            @Suppress("DEPRECATION")
            val raw = wm.connectionInfo?.ssid ?: return null
            val ssid = raw.trim().removePrefix("\"").removeSuffix("\"")
            if (ssid.isBlank() || ssid == "<unknown ssid>" || ssid == "0x") return null
            hash(ssid)
        } catch (_: Throwable) {
            null
        }
    }

    fun hash(ssid: String): String {
        val md = MessageDigest.getInstance("SHA-256")
        val d = md.digest(("assisto-wifi:" + ssid).toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(d.size * 2)
        for (b in d) sb.append(String.format("%02x", b.toInt() and 0xff))
        return sb.toString()
    }
}
