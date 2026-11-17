package com.assisto.assisto.antitheft

/**
 * grab-guard (owner 25 Oct: "sudden grab" alerts at 01:54 AM while the phone
 * lay by the bed) — PURE decision rules for the snatch detector. Kotlin
 * mirror of app/lib/services/antitheft_logic.dart SnatchContext /
 * SnatchProfile / SnatchPolicy, which are unit-tested there (keep in sync).
 *
 *   * charging                    -> off (the owner plugged it in)
 *   * face-down + lying still     -> off (antitheft2: a drop / toss)
 *   * night on the home Wi-Fi     -> off unless Night guard is ON (antitheft2)
 *   * unlocked < IN_HAND_MS ago   -> off (picked up to use it)
 *   * night 23:00-06:00           -> ONLY a screen-off phone that was lying
 *                                    still, with the NIGHT (strongest) pattern
 *   * day, screen off             -> only if it was lying still
 *                                    (moving in a pocket / bag -> off),
 *                                    NIGHT (strongest) pattern
 *   * day otherwise               -> the DAY pattern
 * A grab = two samples over the grab threshold within DEBOUNCE_MS; after a
 * snatch fired there is a COOLDOWN_MS pause.
 */
data class SnatchContext(
    val charging: Boolean = false,
    val screenOn: Boolean = false,
    val unlocked: Boolean = false,
    /** ms since the last USER_PRESENT (unlock); null = not seen. */
    val msSinceUnlock: Long? = null,
    /** local hour 0-23 */
    val hour: Int = 12,
    /** antitheft2: lying screen-down (gravity on -z) */
    val faceDown: Boolean = false,
    /** antitheft2: on one of the owner's saved home Wi-Fi networks */
    val onHomeWifi: Boolean = false,
    /** antitheft2: "Night guard" ON = keep watching at night at home too */
    val nightGuard: Boolean = false,
) {
    /** flag-antitheft: the owner is using the phone (screen on + unlocked). */
    val inUse: Boolean get() = screenOn && unlocked
}

/**
 * flag-antitheft (17 Nov: 10 live "grab" alerts on one phone, none answered,
 * none followed by any theft sign) — the owner's sensitivity. Mirror of
 * antitheft_logic.dart SnatchSensitivity (unit-tested there).
 *   low    never while unlocked in the hand; only a phone lying still
 *   normal also in the hand (recommended)
 *   high   10 % lower thresholds, looser rhythm (more false alarms)
 */
object SnatchSensitivity {
    const val LOW = "low"
    const val NORMAL = "normal"
    const val HIGH = "high"

    fun clean(s: String?): String = when (s) {
        LOW -> LOW
        HIGH -> HIGH
        else -> NORMAL
    }
    fun grabScale(s: String): Double = if (s == HIGH) 0.9 else 1.0
    fun runScale(s: String): Double = if (s == HIGH) 0.9 else 1.0
    fun inHandCounts(s: String): Boolean = s != LOW
}

/**
 * flag-antitheft: "running away" = a steady rhythm after the grab — the
 * strongest autocorrelation of the mean-removed magnitude at a step period
 * of 200-667 ms. Mirror of antitheft_logic.dart GaitRules.
 */
object GaitRules {
    const val MIN_LAG_MS = 200.0
    const val MAX_LAG_MS = 667.0
    const val MIN_SAMPLES = 60
    const val MAX_SAMPLES = 400

    fun minRhythm(sensitivity: String): Double =
        if (sensitivity == SnatchSensitivity.HIGH) 0.35 else 0.5

    /** Returns (rhythm 0..1, step rate Hz). */
    fun rhythm(m: DoubleArray, n: Int, dtMs: Double): Pair<Double, Double> {
        if (n < MIN_SAMPLES || dtMs <= 0.0) return Pair(0.0, 0.0)
        var mu = 0.0
        for (i in 0 until n) mu += m[i]
        mu /= n
        var v = 0.0
        for (i in 0 until n) { val d = m[i] - mu; v += d * d }
        if (v <= 1e-9) return Pair(0.0, 0.0)
        val lo = maxOf(1, Math.round(MIN_LAG_MS / dtMs).toInt())
        val hi = minOf(n / 2 - 1, Math.round(MAX_LAG_MS / dtMs).toInt())
        var best = 0.0
        var bestLag = 0
        for (lag in lo..hi) {
            var c = 0.0
            var i = 0
            while (i + lag < n) { c += (m[i] - mu) * (m[i + lag] - mu); i++ }
            val r = c / v * n / (n - lag)
            if (r > best) { best = r; bestLag = lag }
        }
        return Pair(best, if (bestLag == 0) 0.0 else 1000.0 / (bestLag * dtMs))
    }
}

/** flag-antitheft: an unlock with the phone's own SECURE lock inside the
 *  "Are you OK?" window = the owner has it -> the held grab is dropped. */
object GrabCancel {
    fun ownerUnlockCancels(grabAtMs: Long, unlockAtMs: Long, deviceSecure: Boolean): Boolean =
        deviceSecure && unlockAtMs > grabAtMs &&
            unlockAtMs - grabAtMs <= SnatchPolicy.CONFIRM_WINDOW_MS
}

data class SnatchProfile(
    val name: String,
    val grabThreshold: Double,
    val runThreshold: Double,
    val followWindowMs: Long,
    val runFraction: Double,
    val lateRunFraction: Double,
    val minFollowSamples: Int,
)

object SnatchPolicy {
    val DAY = SnatchProfile("day", 25.0, 6.0, 3500L, 0.6, 0.5, 15)
    val NIGHT = SnatchProfile("night", 32.0, 7.0, 5000L, 0.7, 0.6, 25)

    const val IN_HAND_MS = 60_000L
    const val NIGHT_START_HOUR = 23
    const val NIGHT_END_HOUR = 6
    const val REST_MAX = 1.2
    const val REST_MS = 3000L
    const val DEBOUNCE_MS = 300L
    const val COOLDOWN_MS = 5 * 60_000L

    /** The owner gets this long to answer "Was this you?" on his own phone
     *  before the grab is sent to the server (and the family). */
    const val CONFIRM_WINDOW_MS = 15_000L // flag-antitheft: was 60 s

    fun isNight(hour: Int): Boolean = hour >= NIGHT_START_HOUR || hour < NIGHT_END_HOUR

    fun freshUnlock(c: SnatchContext): Boolean =
        c.unlocked && c.msSinceUnlock != null && c.msSinceUnlock < IN_HAND_MS

    /** The profile a grab NOW must meet, or null = a grab cannot count now. */
    fun profileFor(
        c: SnatchContext,
        restBefore: Boolean,
        sensitivity: String = SnatchSensitivity.NORMAL,
    ): SnatchProfile? {
        val base = baseProfile(c, restBefore) ?: return null
        val s = SnatchSensitivity.clean(sensitivity)
        if (c.inUse && !restBefore && !SnatchSensitivity.inHandCounts(s)) return null
        if (s == SnatchSensitivity.NORMAL) return base
        return base.copy(
            grabThreshold = base.grabThreshold * SnatchSensitivity.grabScale(s),
            runThreshold = base.runThreshold * SnatchSensitivity.runScale(s),
        )
    }

    private fun baseProfile(c: SnatchContext, restBefore: Boolean): SnatchProfile? {
        if (c.charging) return null
        if (freshUnlock(c)) return null
        // antitheft2 (owner 27 Oct): face-down and still -> a drop / toss
        if (c.faceDown && restBefore) return null
        // antitheft2: night at home (saved Wi-Fi) unless Night guard is ON
        if (homeNight(c)) return null
        if (isNight(c.hour)) {
            if (c.screenOn || !restBefore) return null
            return NIGHT
        }
        if (!c.screenOn) return if (restBefore) NIGHT else null // strongest
        return DAY
    }

    /** antitheft2: night + the owner's home Wi-Fi + Night guard OFF. */
    fun homeNight(c: SnatchContext): Boolean =
        isNight(c.hour) && c.onHomeWifi && !c.nightGuard

    /** Abort an armed grab mid-window (plugged in / unlocked meanwhile). */
    fun abort(c: SnatchContext): Boolean = c.charging || freshUnlock(c)
}
