package com.assisto.assisto.antitheft

import android.content.Context
import android.os.PowerManager

/**
 * antitheft-nine — keep the CPU awake for the few seconds a THEFT moment
 * needs, and never longer.
 *
 * Why: the engine is a foreground service, but a foreground service does not
 * stop a real phone from suspending its CPU when the screen is off. The
 * engine's worker is a plain Handler (uptime clock), so on a sleeping phone:
 *   - the "at_command" wake-up push (a remote alarm / lock / lost mode from
 *     the family) returned at once and the check-in that fetches the command
 *     could be frozen until something else woke the phone;
 *   - a grab detected with the screen off could sleep before the held grab
 *     reached the server (the server escalates only what it has).
 * Now each of those moments holds a PARTIAL wake lock with a hard timeout
 * (Android releases it by itself; we never hold one open-ended). The
 * heartbeat also gets an inexact ELAPSED_REALTIME_WAKEUP alarm backstop in
 * AntiTheftService (no exact-alarm permission needed).
 *
 * WAKE_LOCK is already declared (android.yml), a normal permission — nothing
 * new for Play. Every call is try/catch: it can never crash the engine.
 */
object EngineWake {
    /** a wake-up push: check in, run the command, report its result */
    const val PUSH_MS = 30_000L
    /** a grab: the held grab upload + the "Are you OK?" window + a margin */
    val GRAB_MS: Long = SnatchPolicy.CONFIRM_WINDOW_MS + 15_000L
    /** an alarm-backstopped heartbeat: one check-in */
    const val BEAT_MS = 20_000L
    const val MAX_MS = 60_000L

    @Volatile private var wl: PowerManager.WakeLock? = null

    /** debug counters (AntiTheftService.debugState) */
    @Volatile var holds = 0L
        private set
    @Volatile var heldMs = 0L
        private set

    /** Clamp a requested hold (pure; unit-tested by source guard). */
    fun clamp(ms: Long): Long = ms.coerceIn(1_000L, MAX_MS)

    fun hold(ctx: Context, ms: Long) {
        try {
            val w = wl ?: synchronized(this) {
                wl ?: (ctx.applicationContext.getSystemService(Context.POWER_SERVICE)
                    as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,
                    "assisto:antitheft").also {
                    // counted + timed: every hold releases itself
                    it.setReferenceCounted(true)
                    wl = it
                }
            }
            val t = clamp(ms)
            w.acquire(t)
            holds++
            heldMs += t
        } catch (_: Throwable) {
        }
    }
}
