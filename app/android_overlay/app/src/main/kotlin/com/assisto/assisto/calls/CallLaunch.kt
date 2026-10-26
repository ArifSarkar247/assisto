package com.assisto.assisto.calls

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.util.Log
import org.json.JSONObject
import java.net.URLEncoder

/**
 * calls-a (owner 27 Oct: "Accept must open the in-call screen directly").
 *
 * WHY: before this, an Accept / full-screen launch reached Dart only through
 * flutter_local_notifications' launch details, which Dart reads ~2-7 s AFTER
 * the first frame (Notifications.init + PushService.start are deferred by
 * the startup-safety rules) and only after AppState finished its network
 * sync. So the phone drew the HOME first, then pushed the call screen with a
 * zoom transition while the ringing notification and a second (in-app)
 * ringing screen were still coming and going — the "home flash" and the
 * half-drawn "Call ended" frame.
 *
 * NOW the launch intent itself decides the FIRST Flutter route:
 *   * cold start: MainActivity.getInitialRoute() returns [initialRoute]
 *     ("/assisto_call?a=accept|open&id=<call>&p=<payload>"), which the
 *     engine hands to Dart before any Dart code runs (no method-channel call
 *     before the first frame — the launch-safety rule holds). The first frame
 *     IS the call screen (Accept) or the ringing screen (tap / full-screen).
 *   * warm start (activity alive): MainActivity.onNewIntent -> [deliverWarm]
 *     -> "callLaunch" on com.assisto/calls, so Dart opens the call at once
 *     even before PushService is up (flutter_local_notifications' copy that
 *     arrives later is de-duplicated in Dart by call id).
 *   * Accept also stops the ring at once ([answeredHere]): no ringtone
 *     playing on for seconds after the tap.
 *
 * Pure parsing + guarded side effects: every entry point is try/catch and a
 * failure simply means "not a call launch" (the old path still works).
 */
object CallLaunch {
    private const val TAG = "AssistoCall"
    const val ROUTE = "/assisto_call"
    const val ACTION_ACCEPT = "accept"
    const val ACTION_OPEN = "open"

    /** One parsed call launch. */
    data class Launch(val action: String, val callId: String, val payload: String)

    /** The launch this intent asks for, or null (not a call / Reply /
     *  Decline / re-opened from Recents / already handled). */
    @JvmStatic
    fun parse(i: Intent?): Launch? {
        return try {
            if (i == null) return null
            // Recents re-delivers the ORIGINAL intent: never answer again
            if ((i.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
            val raw = i.getStringExtra("payload") ?: return null
            val js = JSONObject(raw)
            if (js.optString("kind") != "call") return null
            val callId = js.optString("call_id")
            if (callId.isEmpty()) return null
            val action = when (i.getStringExtra("actionId")) {
                null, "" -> ACTION_OPEN
                IncomingCall.ACTION_ACCEPT -> ACTION_ACCEPT
                else -> return null // Reply / Decline: never the call screen
            }
            Launch(action, callId, raw)
        } catch (t: Throwable) {
            null
        }
    }

    private fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")

    /** Dart parses this in CallLaunch.parseRoute (lib/calls/call_launch.dart).
     *  Everything is URL-encoded, so the route has exactly one "/" segment
     *  and the Navigator builds [home, call] — home never paints. */
    @JvmStatic
    fun route(l: Launch): String =
        ROUTE + "?a=" + l.action + "&id=" + enc(l.callId) + "&p=" + enc(l.payload)

    /** MainActivity.getInitialRoute (cold start). */
    @JvmStatic
    fun initialRoute(i: Intent?): String? {
        return try {
            val l = parse(i) ?: return null
            Log.i(TAG, "CALL_LAUNCH cold action=${l.action} id=${l.callId}")
            route(l)
        } catch (t: Throwable) {
            null
        }
    }

    /** MainActivity.onNewIntent (warm start): straight to Dart. */
    @JvmStatic
    fun deliverWarm(i: Intent?): Launch? {
        return try {
            val l = parse(i) ?: return null
            Log.i(TAG, "CALL_LAUNCH warm action=${l.action} id=${l.callId}")
            CallsChannel.sendCallLaunch(l.action, l.callId, l.payload)
            l
        } catch (t: Throwable) {
            null
        }
    }

    /** Accept tapped: the ring stops NOW (the FLAG_INSISTENT notification
     *  sound + heads-up), a re-sent ring push for this call never rings
     *  again. Telecom is marked answered by MainActivity as before. */
    @JvmStatic
    fun answeredHere(ctx: Context, callId: String) {
        try {
            IncomingCall.markAnswered(callId)
            (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)
                ?.cancel(IncomingCall.notificationId(callId))
        } catch (_: Throwable) {
        }
    }
}
