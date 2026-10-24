package com.assisto.assisto.antitheft

/**
 * at-falsealarm — PURE SIM-baseline rules (no Android imports, so the rules
 * are mirrored 1:1 and unit-tested in Dart: app/lib/services/antitheft_logic
 * .dart `SimBaselineRules` + test/at_falsealarm_logic_test.dart).
 *
 * The owner's own SIM must NEVER be reported as a "SIM change". So:
 *   * when protection is switched on (or after a reinstall, or after the
 *     owner's "It was me") the SIM(s) currently in the phone are recorded
 *     silently as the BASELINE;
 *   * a later snapshot is compared to it: "inserted" only for a SIM that is
 *     not in the baseline (and was not already reported), "removed" only when
 *     a baseline SIM that was present last time is gone. Putting the owner's
 *     own baseline SIM back is never an alert.
 *
 * One identity per slot:
 *   ""                   slot empty (ABSENT)
 *   null                 not readable yet (NOT_READY / UNKNOWN / PIN locked /
 *                        card error / no subscription yet) -> skip this round
 *   "s<subId>:<mccmnc>"  API 29+ (subscription id is per physical SIM)
 *   "op:<mccmnc>"        API 26-28 (default SIM operator only — honest limit:
 *                        a swap to another SIM of the SAME operator is not
 *                        visible there, a removal is)
 */
object SimBaseline {
    // android.telephony.TelephonyManager.SIM_STATE_* (stable public ints)
    const val ABSENT = 1
    const val READY = 5
    const val LOADED = 10 // hidden/system on some levels; treated as READY

    /** Identity for one slot. [subIds] null = not available on this API. */
    fun slotIdentity(state: Int, subIds: IntArray?, mccmnc: String?): String? {
        if (state == ABSENT) return ""
        if (state != READY && state != LOADED) return null
        val op = (mccmnc ?: "").trim()
        if (subIds == null) {
            return if (op.isEmpty()) null else "op:$op"
        }
        val sub = subIds.firstOrNull { it >= 0 } ?: return null
        return "s$sub:" + (if (op.isEmpty()) "?" else op)
    }

    /** All slots -> the set of present SIM identities, or null if any slot is
     *  still unreadable (evaluate again later; never guess). */
    fun snapshot(slots: List<String?>): Set<String>? {
        val out = HashSet<String>()
        for (s in slots) {
            if (s == null) return null
            if (s.isNotEmpty()) out.add(s)
        }
        return out
    }

    fun encode(set: Set<String>): String = set.sorted().joinToString(",")

    fun decode(s: String?): Set<String> =
        (s ?: "").split(",").map { it.trim() }.filter { it.isNotEmpty() }.toSet()

    class Verdict(val inserted: Set<String>, val removed: Set<String>) {
        /** "inserted" wins (a foreign SIM is the strong theft signal), then
         *  "removed"; null = nothing to report. */
        val alert: String?
            get() = when {
                inserted.isNotEmpty() -> "inserted"
                removed.isNotEmpty() -> "removed"
                else -> null
            }
    }

    /**
     * [baseline] the owner's SIMs at arming, [lastSeen] the snapshot last
     * evaluated (== baseline right after arming), [current] now. The caller
     * stores [current] as the new lastSeen afterwards.
     */
    fun evaluate(baseline: Set<String>, lastSeen: Set<String>,
                 current: Set<String>): Verdict {
        val inserted = current.filter { it !in baseline && it !in lastSeen }.toSet()
        val removed = baseline.filter { it in lastSeen && it !in current }.toSet()
        return Verdict(inserted, removed)
    }
}
