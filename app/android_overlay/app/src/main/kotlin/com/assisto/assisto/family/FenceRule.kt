package com.assisto.assisto.family

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * fcbrain — the on-phone geofence rule (Family Care v3 BRAIN 2), the Kotlin
 * twin of app/lib/family_v3/brain/fc_geofence.dart. SAME constants (the
 * Dart test reads this file and checks them), same decisions:
 *   ENTER  distance <= r + min(acc, 50)              (one fix)
 *   LEAVE  distance >  r + 100 + min(acc, 100)        (two fixes in a row)
 *   a fix worse than 250 m decides nothing; the first fix only learns.
 *   next fix: outside -> edge / 16.7 m/s clamped 60..900 s; inside -> 300 s
 *   (900 s when still).
 * Pure Kotlin + org.json, no Android API, never throws.
 */
object FenceRule {
    const val VMAX_MPS = 16.7
    const val MIN_DELAY_S = 60L
    const val MAX_DELAY_S = 900L
    const val INSIDE_DELAY_S = 300L
    const val STILL_DELAY_S = 900L
    const val LEAVE_MARGIN_M = 100.0
    const val ENTER_ACC_CAP_M = 50.0
    const val LEAVE_ACC_CAP_M = 100.0
    const val MAX_ACC_M = 250.0
    const val NEAR_M = 600.0
    const val STILL_M = 30.0

    data class Fence(val id: Int, val kind: String, val label: String,
                     val lat: Double, val lng: Double, val r: Double)

    data class Event(val kind: String, val fence: Fence, val atMs: Long)

    class State {
        val inside = HashSet<Int>()
        val outStreak = HashMap<Int, Int>()
        var primed = false
        var prevLat = Double.NaN
        var prevLng = Double.NaN
        var still = 0

        fun toJson(): JSONObject = JSONObject().apply {
            put("inside", JSONArray(inside.toList()))
            val s = JSONObject()
            for ((k, v) in outStreak) s.put(k.toString(), v)
            put("streak", s)
            put("primed", primed)
            put("still", still)
            if (!prevLat.isNaN()) { put("plat", prevLat); put("plng", prevLng) }
        }

        companion object {
            fun fromJson(raw: String?): State {
                val st = State()
                try {
                    if (raw.isNullOrBlank()) return st
                    val o = JSONObject(raw)
                    val a = o.optJSONArray("inside")
                    if (a != null) for (i in 0 until a.length()) st.inside.add(a.optInt(i))
                    val s = o.optJSONObject("streak")
                    if (s != null) for (k in s.keys()) st.outStreak[k.toInt()] = s.optInt(k)
                    st.primed = o.optBoolean("primed", false)
                    st.still = o.optInt("still", 0)
                    st.prevLat = o.optDouble("plat", Double.NaN)
                    st.prevLng = o.optDouble("plng", Double.NaN)
                } catch (_: Throwable) {}
                return st
            }
        }
    }

    fun parseFences(raw: String?): List<Fence> {
        val out = ArrayList<Fence>()
        try {
            if (raw.isNullOrBlank()) return out
            val a = JSONArray(raw)
            for (i in 0 until a.length()) {
                val o = a.optJSONObject(i) ?: continue
                if (!o.has("id") || !o.has("lat") || !o.has("lng")) continue
                out.add(Fence(o.optInt("id"), o.optString("kind", "place"),
                    o.optString("label", ""), o.optDouble("lat"), o.optDouble("lng"),
                    o.optDouble("r", 150.0)))
            }
        } catch (_: Throwable) {}
        return out
    }

    fun distanceM(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        val r = 6371000.0
        val p1 = Math.toRadians(lat1)
        val p2 = Math.toRadians(lat2)
        val dp = Math.toRadians(lat2 - lat1)
        val dl = Math.toRadians(lng2 - lng1)
        val a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1.0, sqrt(a)))
    }

    fun step(fences: List<Fence>, st: State, lat: Double, lng: Double, acc: Double,
             atMs: Long): List<Event> {
        val out = ArrayList<Event>()
        if (!st.prevLat.isNaN()) {
            st.still = if (distanceM(st.prevLat, st.prevLng, lat, lng) < STILL_M) st.still + 1 else 0
        }
        st.prevLat = lat
        st.prevLng = lng
        if (acc.isNaN() || acc > MAX_ACC_M) return out
        for (f in fences) {
            val d = distanceM(lat, lng, f.lat, f.lng)
            if (!st.inside.contains(f.id)) {
                if (d <= f.r + min(acc, ENTER_ACC_CAP_M)) {
                    st.inside.add(f.id)
                    st.outStreak[f.id] = 0
                    if (st.primed) out.add(Event("arrive", f, atMs))
                }
            } else {
                if (d > f.r + LEAVE_MARGIN_M + min(acc, LEAVE_ACC_CAP_M)) {
                    val s = (st.outStreak[f.id] ?: 0) + 1
                    st.outStreak[f.id] = s
                    if (s >= 2 || !st.primed) {
                        st.inside.remove(f.id)
                        st.outStreak[f.id] = 0
                        if (st.primed) out.add(Event("leave", f, atMs))
                    }
                } else {
                    st.outStreak[f.id] = 0
                }
            }
        }
        // a fence that was removed on the server is forgotten
        st.inside.retainAll(fences.map { it.id }.toSet())
        st.primed = true
        return out
    }

    fun edgeM(fences: List<Fence>, st: State, lat: Double, lng: Double): Double {
        var best = Double.POSITIVE_INFINITY
        for (f in fences) {
            val d = distanceM(lat, lng, f.lat, f.lng)
            val e = if (st.inside.contains(f.id)) (f.r + LEAVE_MARGIN_M) - d else d - f.r
            best = min(best, max(0.0, e))
        }
        return best
    }

    fun nextDelayS(fences: List<Fence>, st: State, lat: Double, lng: Double): Long {
        if (fences.isEmpty()) return MAX_DELAY_S
        if (st.inside.isNotEmpty()) return if (st.still >= 2) STILL_DELAY_S else INSIDE_DELAY_S
        val s = (edgeM(fences, st, lat, lng) / VMAX_MPS).toLong()
        return s.coerceIn(MIN_DELAY_S, MAX_DELAY_S)
    }

    fun wantPrecise(fences: List<Fence>, st: State, lat: Double, lng: Double): Boolean =
        st.inside.isEmpty() && edgeM(fences, st, lat, lng) < NEAR_M
}
