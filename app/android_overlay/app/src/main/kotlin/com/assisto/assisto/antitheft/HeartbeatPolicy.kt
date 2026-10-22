package com.assisto.assisto.antitheft

/**
 * b6-antitheft — battery-aware heartbeat interval.
 *
 * MUST match core/logic/antitheft.heartbeat_interval_min (Python) and
 * app/lib/services/antitheft_logic.heartbeatIntervalMin (Dart). The server
 * bases its "went dark" threshold on the interval, so a low-battery phone that
 * checks in less often is NOT mistaken for a stolen one.
 */
object HeartbeatPolicy {
    const val CHARGING = 10
    const val NORMAL = 15
    const val LOW = 30
    const val CRITICAL = 60
    const val LOST = 5

    fun intervalMin(batteryPct: Int?, charging: Boolean, lostMode: Boolean): Int {
        if (charging) return if (lostMode) LOST else CHARGING
        if (batteryPct != null && batteryPct <= 15) return CRITICAL // critical wins
        if (lostMode) return LOST
        if (batteryPct != null && batteryPct <= 30) return LOW
        return NORMAL
    }
}
