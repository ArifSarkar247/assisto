package com.assisto.assisto.calls

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * ring-everywhere: Assisto calls as SELF-MANAGED VoIP calls in Android's
 * Telecom framework (API 26+, MANAGE_OWN_CALLS — a normal install-time
 * permission; no READ_PHONE_STATE / CALL_PHONE).
 *
 * Why: a phone "in a call" (even ringing) is treated as such by the system —
 * Telecom binds our ConnectionService (process kept at foreground priority
 * while it rings), the call shows on Bluetooth headsets / watches / cars, and
 * a cellular call arriving meanwhile is handled as call-waiting.
 *
 * Scope (deliberately small, Android 8-16): Telecom covers the RINGING phase.
 * The ring itself is ALWAYS the IncomingCall notification, posted before
 * Telecom is asked (onShowIncomingCallUi only re-posts it if it is gone), so
 * an OEM whose Telecom refuses self-managed calls (SecurityException,
 * onCreateIncomingConnectionFailed, isIncomingCallPermitted=false) still
 * rings. When the call is answered the Flutter call screen owns audio as it
 * did before (WebRTC + AudioManager); the Telecom connection is then ended
 * (KEEP_ACTIVE_DURING_CALL=false) because Telecom-managed audio routing next
 * to WebRTC's own speaker / Bluetooth switching cannot be verified on real
 * OEM phones from CI. Dart can flip that per call via CallsChannel
 * "telecomActive" once it is proven on devices.
 *
 * Every entry point is try/catch: a Telecom quirk can never crash anything.
 */
object TelecomBridge {
    private const val TAG = "AssistoRing"
    const val EXTRA_CALL_ID = "assisto_call_id"
    const val EXTRA_NAME = "assisto_caller_name"
    const val EXTRA_VIDEO = "assisto_video"
    private const val ACCOUNT_ID = "assisto_calls"

    /** See class doc. */
    const val KEEP_ACTIVE_DURING_CALL = false

    @Volatile
    private var registered = false
    private val conns = ConcurrentHashMap<String, AssistoConnection>()
    private val endedEarly = ConcurrentHashMap<String, Long>()

    private fun handle(ctx: Context) = PhoneAccountHandle(
        ComponentName(ctx, AssistoConnectionService::class.java), ACCOUNT_ID)

    private fun tm(ctx: Context): TelecomManager? =
        ctx.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager

    private fun ensureAccount(ctx: Context): Boolean {
        if (registered) return true
        return try {
            val t = tm(ctx) ?: return false
            val acct = PhoneAccount.builder(handle(ctx), "Assisto")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED or
                    PhoneAccount.CAPABILITY_VIDEO_CALLING or
                    PhoneAccount.CAPABILITY_SUPPORTS_VIDEO_CALLING)
                .build()
            t.registerPhoneAccount(acct)
            registered = true
            true
        } catch (e: Throwable) {
            Log.w(TAG, "telecom account refused: ${e.javaClass.simpleName}")
            false
        }
    }

    /** Ask Telecom for a self-managed incoming call. Never throws. */
    @SuppressLint("MissingPermission")
    @JvmStatic
    fun reportIncoming(ctx: Context, callId: String, name: String, video: Boolean): Boolean {
        return try {
            if (conns.containsKey(callId)) return true
            if (!ensureAccount(ctx)) return false
            val t = tm(ctx) ?: return false
            val h = handle(ctx)
            if (!t.isIncomingCallPermitted(h)) {
                Log.i(TAG, "telecom: incoming not permitted now (another call)")
                return false
            }
            val extras = Bundle()
            extras.putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                Uri.fromParts("assisto", callId, null))
            val inner = Bundle()
            inner.putString(EXTRA_CALL_ID, callId)
            inner.putString(EXTRA_NAME, name)
            inner.putBoolean(EXTRA_VIDEO, video)
            extras.putBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS, inner)
            if (video) {
                extras.putInt(TelecomManager.EXTRA_INCOMING_VIDEO_STATE,
                    VideoProfile.STATE_BIDIRECTIONAL)
            }
            t.addNewIncomingCall(h, extras)
            Log.i(TAG, "telecom: incoming reported")
            true
        } catch (e: Throwable) {
            Log.w(TAG, "telecom refused: ${e.javaClass.simpleName}")
            false
        }
    }

    internal fun attach(callId: String, c: AssistoConnection) {
        if (callId.isEmpty()) return
        val gone = endedEarly.remove(callId)
        conns[callId] = c
        if (gone != null) end(callId)     // cancelled before Telecom bound us
    }

    internal fun detach(callId: String) {
        conns.remove(callId)
    }

    /** The app's call screen took over (answer) — see KEEP_ACTIVE_DURING_CALL. */
    @JvmStatic
    fun answered(callId: String) {
        if (KEEP_ACTIVE_DURING_CALL) active(callId) else end(callId)
    }

    @JvmStatic
    fun active(callId: String): Boolean {
        return try {
            val c = conns[callId] ?: return false
            c.setActive()
            true
        } catch (_: Throwable) {
            false
        }
    }

    /** Ring stopped / call over: disconnect + destroy (idempotent). */
    @JvmStatic
    fun end(callId: String, cause: Int = DisconnectCause.LOCAL): Boolean {
        return try {
            val c = conns.remove(callId)
            if (c == null) {
                endedEarly[callId] = System.currentTimeMillis()
                pruneEarly()
                return false
            }
            c.finish(cause)
            true
        } catch (_: Throwable) {
            false
        }
    }

    @JvmStatic
    fun endAll() {
        for (id in conns.keys.toList()) end(id)
    }

    private fun pruneEarly() {
        val cut = System.currentTimeMillis() - 5 * 60_000L
        try {
            endedEarly.entries.removeIf { it.value < cut }
        } catch (_: Throwable) {
        }
    }
}

/** One self-managed Telecom connection = one ringing Assisto call. */
class AssistoConnection(private val ctx: Context, val callId: String) : Connection() {
    @Volatile
    private var done = false

    init {
        try {
            connectionProperties = PROPERTY_SELF_MANAGED
            audioModeIsVoip = true
        } catch (_: Throwable) {
        }
    }

    internal fun finish(cause: Int) {
        if (done) return
        done = true
        try {
            setDisconnected(DisconnectCause(cause))
        } catch (_: Throwable) {
        }
        try {
            destroy()
        } catch (_: Throwable) {
        }
    }

    override fun onShowIncomingCallUi() {
        try {
            IncomingCall.ensureShown(ctx, callId)
        } catch (_: Throwable) {
        }
    }

    override fun onAnswer() {
        try {
            IncomingCall.answerFromSystem(ctx, callId)
        } catch (_: Throwable) {
        }
        TelecomBridge.answered(callId)
    }

    override fun onAnswer(videoState: Int) {
        onAnswer()
    }

    override fun onReject() {
        TelecomBridge.detach(callId)
        finish(DisconnectCause.REJECTED)
        try {
            IncomingCall.decline(ctx, callId)
        } catch (_: Throwable) {
        }
    }

    /** The system / a headset ended the RINGING call = decline it. */
    override fun onDisconnect() {
        TelecomBridge.detach(callId)
        finish(DisconnectCause.LOCAL)
        try {
            IncomingCall.decline(ctx, callId)
        } catch (_: Throwable) {
        }
    }

    override fun onAbort() {
        TelecomBridge.detach(callId)
        finish(DisconnectCause.CANCELED)
    }
}

/**
 * Bound by Telecom (BIND_TELECOM_CONNECTION_SERVICE) after addNewIncomingCall.
 * Declared by the CI manifest patch; never started by the app itself.
 */
class AssistoConnectionService : ConnectionService() {
    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val inner = try {
            request?.extras?.getBundle(TelecomManager.EXTRA_INCOMING_CALL_EXTRAS)
                ?: request?.extras
        } catch (_: Throwable) {
            null
        }
        val callId = inner?.getString(TelecomBridge.EXTRA_CALL_ID) ?: ""
        val name = inner?.getString(TelecomBridge.EXTRA_NAME) ?: ""
        val video = inner?.getBoolean(TelecomBridge.EXTRA_VIDEO, false) ?: false
        val c = AssistoConnection(applicationContext, callId)
        try {
            c.setAddress(Uri.fromParts("assisto", callId, null),
                TelecomManager.PRESENTATION_ALLOWED)
            if (name.isNotEmpty()) {
                c.setCallerDisplayName(name, TelecomManager.PRESENTATION_ALLOWED)
            }
            c.videoState = if (video) VideoProfile.STATE_BIDIRECTIONAL
            else VideoProfile.STATE_AUDIO_ONLY
            c.setRinging()
        } catch (_: Throwable) {
        }
        TelecomBridge.attach(callId, c)
        return c
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ) {
        // Telecom said no (another call / OEM policy): the notification ring
        // posted before is unaffected.
        Log.i("AssistoRing", "telecom: incoming connection failed -> notification only")
    }
}
