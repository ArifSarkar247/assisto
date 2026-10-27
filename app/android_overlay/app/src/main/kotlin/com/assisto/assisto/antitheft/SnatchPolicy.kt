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
)

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
    const val CONFIRM_WINDOW_MS = 60_000L

    fun isNight(hour: Int): Boolean = hour >= NIGHT_START_HOUR || hour < NIGHT_END_HOUR

    fun freshUnlock(c: SnatchContext): Boolean =
        c.unlocked && c.msSinceUnlock != null && c.msSinceUnlock < IN_HAND_MS

    /** The profile a grab NOW must meet, or null = a grab cannot count now. */
    fun profileFor(c: SnatchContext, restBefore: Boolean): SnatchProfile? {
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
