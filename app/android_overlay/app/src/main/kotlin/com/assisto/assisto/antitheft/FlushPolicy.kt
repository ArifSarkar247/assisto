package com.assisto.assisto.antitheft

/**
 * antitheft2 (owner 27 Oct: alerts arrived hours late) — PURE rules for WHEN
 * the engine retries its store-and-forward queue. Kotlin mirror of
 * app/lib/services/antitheft_logic.dart FlushPolicy (unit-tested there).
 *
 *   * connectivity back + something queued -> flush after CONNECTIVITY_DELAY_MS
 *   * failed upload + something queued     -> retry 30 s, 60 s, 120 s, 240 s,
 *                                             then every 300 s
 */
object FlushPolicy {
    const val CONNECTIVITY_DELAY_MS = 3_000L
    const val FIRST_RETRY_MS = 30_000L
    const val MAX_RETRY_MS = 300_000L

    fun retryDelayMs(attempt: Int): Long {
        var d = FIRST_RETRY_MS
        var i = 1
        val a = if (attempt < 1) 1 else attempt
        while (i < a && d < MAX_RETRY_MS) { d *= 2; i++ }
        return if (d > MAX_RETRY_MS) MAX_RETRY_MS else d
    }

    fun flushOnConnectivity(connected: Boolean, queued: Int): Boolean =
        connected && queued > 0

    fun scheduleRetry(uploadOk: Boolean, queued: Int): Boolean =
        !uploadOk && queued > 0
}
