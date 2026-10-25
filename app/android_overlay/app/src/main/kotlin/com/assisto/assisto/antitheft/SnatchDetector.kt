package com.assisto.assisto.antitheft

/**
 * b6-antitheft / grab-guard — conservative snatch detector (Kotlin mirror of
 * app/lib/services/antitheft_logic.SnatchDetector; the Dart copy is unit-tested
 * so these exact rules have a Kotlin-free test).
 *
 * A snatch = a sudden strong jerk (two samples over the profile's grab
 * threshold within SnatchPolicy.DEBOUNCE_MS) followed by SUSTAINED motion
 * (moving away) through the whole follow window — in both its halves — and
 * only when SnatchPolicy allows a grab at that moment (not charging, not just
 * unlocked, night = screen-off phone lying still only). A pick-up, put-down,
 * bump, in-hand use or charging never fires. Cooldown after a fire.
 */
class SnatchDetector {
    private var profile: SnatchProfile? = null
    private var grabAtMs = 0L
    private var spikeAtMs: Long? = null
    private var spikeRest = false
    private var lastActiveMs: Long? = null
    private var firstMs: Long? = null
    private var cooldownUntil: Long? = null
    private var early = 0
    private var earlyMoving = 0
    private var late = 0
    private var lateMoving = 0

    /** Feed one linear-acceleration magnitude. Returns true exactly once when
     *  a snatch pattern completes. */
    fun onSample(magnitude: Double, tMs: Long, ctx: SnatchContext): Boolean {
        if (firstMs == null) firstMs = tMs
        val restBefore = (tMs - (lastActiveMs ?: firstMs!!)) >= SnatchPolicy.REST_MS
        if (magnitude >= SnatchPolicy.REST_MAX) lastActiveMs = tMs

        val cd = cooldownUntil
        if (cd != null && tMs < cd) return false

        val p = profile
        if (p != null) {
            if (SnatchPolicy.abort(ctx)) { reset(); return false }
            if (tMs - grabAtMs > p.followWindowMs) {
                val total = early + late
                val fired = total >= p.minFollowSamples &&
                    late > 0 &&
                    (earlyMoving + lateMoving).toDouble() / total >= p.runFraction &&
                    lateMoving.toDouble() / late >= p.lateRunFraction
                reset()
                if (fired) cooldownUntil = tMs + SnatchPolicy.COOLDOWN_MS
                return fired
            }
            val moving = magnitude >= p.runThreshold
            if (tMs - grabAtMs <= p.followWindowMs / 2) {
                early++
                if (moving) earlyMoving++
            } else {
                late++
                if (moving) lateMoving++
            }
            return false
        }

        // Not armed: look for a debounced grab (2 strong samples close together).
        val spike = spikeAtMs
        if (spike != null && tMs - spike > SnatchPolicy.DEBOUNCE_MS) spikeAtMs = null
        val first = spikeAtMs == null
        val want = SnatchPolicy.profileFor(ctx, if (first) restBefore else spikeRest)
        if (want == null || magnitude < want.grabThreshold) return false
        if (first) {
            spikeAtMs = tMs
            spikeRest = restBefore
            return false
        }
        profile = want
        grabAtMs = tMs
        spikeAtMs = null
        early = 0; earlyMoving = 0; late = 0; lateMoving = 0
        return false
    }

    fun reset() {
        profile = null
        spikeAtMs = null
        early = 0; earlyMoving = 0; late = 0; lateMoving = 0
    }
}
