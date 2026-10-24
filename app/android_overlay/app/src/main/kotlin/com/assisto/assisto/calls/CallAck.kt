package com.assisto.assisto.calls

import android.content.Context
import android.os.Build
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * ring-everywhere: the NATIVE ack to the server (no Flutter, no account
 * token). POST <api>/circle/calls/<id>/ack {sig, stage, brand, model, sdk}
 *   stage "delivered" (push arrived, app open — Dart rings in-app),
 *         "ringing"   (this native ring is on screen -> caller sees Ringing),
 *         "decline"   (Decline button / Telecom reject).
 * `sig` is the per-call HMAC the server put in the ring push (core/call_ack).
 * The API base is stored by Dart at app start (CallsChannel
 * "setNativeConfig"); a phone can only hold a push token after Dart ran, so
 * it is always there when a ring arrives.
 *
 * Runs on the caller's thread (the FCM service thread / a worker thread),
 * never the main thread. 2 tries, 4 s timeouts. Never throws.
 * If the server answers that the call already ENDED (a late / stale push),
 * the ring is cancelled at once.
 */
object CallAck {
    private const val TAG = "AssistoRing"
    const val PREFS = "assisto_native_calls"
    const val KEY_API = "api_base"           // e.g. https://api.x/api/v1/
    const val KEY_APP = "app_version"

    @JvmStatic
    fun setConfig(ctx: Context, apiBase: String?, appVersion: String?) {
        try {
            val e = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            if (!apiBase.isNullOrEmpty()) e.putString(KEY_API, apiBase)
            if (!appVersion.isNullOrEmpty()) e.putString(KEY_APP, appVersion)
            e.apply()
        } catch (_: Throwable) {
        }
    }

    private fun apiBase(ctx: Context): String? = try {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_API, null)
    } catch (_: Throwable) {
        null
    }

    /** Blocking. Returns the server's JSON answer or null. */
    @JvmStatic
    fun post(ctx: Context, callId: String, sig: String, stage: String): JSONObject? {
        if (callId.isEmpty() || sig.isEmpty()) return null
        val base = apiBase(ctx) ?: return null
        val url = (if (base.endsWith("/")) base else "$base/") + "circle/calls/$callId/ack"
        val body = JSONObject()
            .put("sig", sig)
            .put("stage", stage)
            .put("brand", (Build.BRAND ?: "").take(32))
            .put("model", (Build.MODEL ?: "").take(48))
            .put("sdk", Build.VERSION.SDK_INT)
            .toString().toByteArray(Charsets.UTF_8)
        for (attempt in 0 until 2) {
            var c: HttpURLConnection? = null
            try {
                c = URL(url).openConnection() as HttpURLConnection
                c.requestMethod = "POST"
                c.connectTimeout = 4000
                c.readTimeout = 4000
                c.doOutput = true
                c.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                c.outputStream.use { it.write(body) }
                val code = c.responseCode
                if (code in 200..299) {
                    val txt = c.inputStream.bufferedReader().use { it.readText() }
                    val js = try { JSONObject(txt) } catch (_: Throwable) { null }
                    Log.i(TAG, "ACK_OK stage=$stage")
                    if (js != null && js.optBoolean("ended", false) && stage != "decline") {
                        IncomingCall.cancel(ctx, callId)
                    }
                    return js
                }
                if (code in 400..499) return null      // gone / not ours: final
            } catch (t: Throwable) {
                Log.w(TAG, "ack failed: ${t.javaClass.simpleName}")
            } finally {
                try { c?.disconnect() } catch (_: Throwable) {}
            }
            try { Thread.sleep(800) } catch (_: Throwable) {}
        }
        return null
    }

    /** From the FCM service thread right after the ring decision. */
    @JvmStatic
    fun afterPush(ctx: Context, d: Map<String, String>, shown: Boolean) {
        try {
            post(ctx, d["call_id"] ?: "", d["ack_sig"] ?: "",
                if (shown) "ringing" else "delivered")
        } catch (_: Throwable) {
        }
    }
}
