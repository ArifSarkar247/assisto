package com.assisto.assisto.antitheft

/**
 * b6-antitheft / grab-guard — conservative snatch detector (Kotlin mirror of
 * app/lib/services/antitheft_logic.SnatchDetector; the Dart copy is unit-tested
 * so these exact rules have a Kotlin-free test).
 *
 * A snatch = a sudden strong jerk (two samples over the profile's grab
 * threshold within SnatchPolicy.DEBOUNCE_MS) followed by SUSTAINED motion
 * (moving away) through the whole follow window — in all three thirds —
 * with a steady running rhythm (GaitRules, flag-antitheft), and
 * only when SnatchPolicy allows a grab at that moment (not charging, not just
 * unlocked, night = screen-off phone lying still only). A pick-up, put-down,
 * bump, in-hand use or charging never fires. Cooldown after a fire.
 */
class SnatchDetector {
    /** flag-antitheft: the owner's sensitivity (SnatchSensitivity). */
    @Volatile var sensitivity: String = SnatchSensitivity.NORMAL
        set(v) { field = SnatchSensitivity.clean(v) }

    private var profile: SnatchProfile? = null
    private var grabAtMs = 0L
    private var spikeAtMs: Long? = null
    private var spikeRest = false
    private var lastActiveMs: Long? = null
    private var firstMs: Long? = null
    private var cooldownUntil: Long? = null
    // flag-antitheft: thirds of the follow window, magnitudes for the rhythm
    private val n = IntArray(3)
    private val moving = IntArray(3)
    private val buf = DoubleArray(GaitRules.MAX_SAMPLES)
    private var bufN = 0
    private var lastT = 0L
    private var grabPeak = 0.0
    private var sum = 0.0
    private var inUse = false

    /** Motion numbers of the last FIRED pattern (no location, no audio). */
    var lastFeatures: Map<String, Any> = emptyMap()
        private set

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
                val fired = verdict(p)
                reset()
                if (fired) cooldownUntil = tMs + SnatchPolicy.COOLDOWN_MS
                return fired
            }
            val third = minOf(2L, maxOf(0L, (tMs - grabAtMs) * 3 / (p.followWindowMs + 1))).toInt()
            n[third]++
            if (magnitude >= p.runThreshold) moving[third]++
            sum += magnitude
            if (bufN < GaitRules.MAX_SAMPLES) { buf[bufN++] = magnitude; lastT = tMs }
            return false
        }

        // Not armed: look for a debounced grab (2 strong samples close together).
        val spike = spikeAtMs
        if (spike != null && tMs - spike > SnatchPolicy.DEBOUNCE_MS) spikeAtMs = null
        val first = spikeAtMs == null
        val want = SnatchPolicy.profileFor(ctx, if (first) restBefore else spikeRest, sensitivity)
        if (want == null || magnitude < want.grabThreshold) return false
        if (first) {
            spikeAtMs = tMs
            spikeRest = restBefore
            grabPeak = magnitude
            return false
        }
        val peak = maxOf(grabPeak, magnitude)
        reset()
        profile = want
        grabAtMs = tMs
        grabPeak = peak
        inUse = ctx.inUse
        return false
    }

    private fun verdict(p: SnatchProfile): Boolean {
        val total = n[0] + n[1] + n[2]
        if (total < p.minFollowSamples || n[2] == 0) return false
        val mv = moving[0] + moving[1] + moving[2]
        val thirds = DoubleArray(3) { if (n[it] == 0) 0.0 else moving[it].toDouble() / n[it] }
        val sustained = mv.toDouble() / total >= p.runFraction &&
            thirds.all { it >= p.lateRunFraction }
        if (!sustained) return false
        val dt = if (bufN > 1) (lastT - grabAtMs).toDouble() / bufN else 0.0
        val (rhythm, hz) = GaitRules.rhythm(buf, bufN, dt)
        if (rhythm < GaitRules.minRhythm(sensitivity)) return false
        fun r2(v: Double) = Math.round(v * 100) / 100.0
        lastFeatures = mapOf(
            "v" to 3, "profile" to p.name, "sens" to sensitivity, "in_use" to inUse,
            "peak" to r2(grabPeak), "moving" to r2(mv.toDouble() / total),
            "thirds" to thirds.map { r2(it) }, "rhythm" to r2(rhythm),
            "step_hz" to r2(hz), "mean" to r2(sum / total),
        )
        return true
    }

    fun reset() {
        profile = null
        spikeAtMs = null
        for (i in 0..2) { n[i] = 0; moving[i] = 0 }
        bufN = 0
        lastT = 0L
        grabPeak = 0.0
        sum = 0.0
        inUse = false
    }
}
