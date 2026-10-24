package com.assisto.assisto.antitheft

/**
 * b6-antitheft — conservative snatch detector (Kotlin mirror of
 * app/lib/services/antitheft_logic.SnatchDetector; the Dart copy is unit-tested
 * so these exact thresholds have a Kotlin-free test).
 *
 * A snatch = a sudden strong jerk (a grab) immediately followed by sustained
 * motion (running away) WHILE the phone is unlocked. BOTH halves are required
 * so an ordinary drop, bump, or putting the phone down does NOT fire — false
 * theft alarms destroy trust, so the bar is deliberately high.
 */
class SnatchDetector {
    companion object {
        const val GRAB_THRESHOLD = 25.0        // m/s^2 (~2.5g), gravity removed
        const val RUN_THRESHOLD = 6.0
        const val FOLLOW_WINDOW_MS = 2500L
        const val RUN_SAMPLE_FRACTION = 0.6
    }

    private var grabAtMs: Long? = null
    private var followSamples = 0
    private var movingSamples = 0

    /** Feed one linear-acceleration magnitude. Returns true exactly once when a
     *  snatch pattern completes. */
    fun onSample(magnitude: Double, tMs: Long, unlocked: Boolean): Boolean {
        if (!unlocked) { reset(); return false }
        val grab = grabAtMs
        if (grab == null) {
            if (magnitude >= GRAB_THRESHOLD) {
                grabAtMs = tMs; followSamples = 0; movingSamples = 0
            }
            return false
        }
        if (tMs - grab > FOLLOW_WINDOW_MS) {
            val fired = followSamples > 0 &&
                movingSamples.toDouble() / followSamples >= RUN_SAMPLE_FRACTION
            reset()
            return fired
        }
        followSamples++
        if (magnitude >= RUN_THRESHOLD) movingSamples++
        return false
    }

    fun reset() { grabAtMs = null; followSamples = 0; movingSamples = 0 }
}
