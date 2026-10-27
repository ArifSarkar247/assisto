package com.assisto.assisto.antitheft

import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Looper
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * b6-antitheft / antitheft2 — the phone's location for anti-theft alerts.
 *
 * Owner 27 Oct: every alert said "Last location not known". The engine only
 * read the OS's CACHED last-known fix, which is empty on many phones (no
 * other app asked for location recently) — so it never had one. Now:
 *   1. [fresh]  — one short, single location request (fused when the phone
 *                 has it, else GPS / network), with a timeout; used before
 *                 low-battery / offline / grab / SIM events and when the
 *                 cached fix is old;
 *   2. [best]   — the newest cached fix across ALL providers (incl. fused)
 *                 as the fallback;
 *   3. the server keeps the last fix it got and puts it on alerts when the
 *      phone has none ("last seen at <time>, ±<accuracy> m").
 * Each fix carries its accuracy and the time it was taken.
 *
 * Still NO continuous tracking and NO ACCESS_BACKGROUND_LOCATION: the
 * engine is a foreground service of type "location" started from the open
 * app, which Android lets use the while-in-use permission. If the
 * permission is off or location is switched off we send NO location and
 * say so ([status]) — never a fake one.
 *
 * Never call [fresh] on the main thread (it waits up to the timeout).
 */
object LastLocation {
    data class Fix(val lat: Double, val lng: Double, val acc: Float?, val timeMs: Long)

    /** Back-compat: the newest cached fix as (lat, lng). */
    fun get(ctx: Context): Pair<Double, Double>? = best(ctx)?.let { Pair(it.lat, it.lng) }

    /** Newest cached fix across all providers (incl. "fused"), or null. */
    fun best(ctx: Context): Fix? {
        return try {
            if (!hasPermission(ctx)) return null
            val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                ?: return null
            val providers = LinkedHashSet<String>()
            try { providers.addAll(lm.getProviders(true)) } catch (_: Throwable) {}
            providers.add("fused")
            providers.add(LocationManager.GPS_PROVIDER)
            providers.add(LocationManager.NETWORK_PROVIDER)
            providers.add(LocationManager.PASSIVE_PROVIDER)
            var best: Location? = null
            for (p in providers) {
                val loc = try {
                    @Suppress("MissingPermission")
                    lm.getLastKnownLocation(p)
                } catch (_: Throwable) { null }
                if (loc != null && (best == null || loc.time > best!!.time)) best = loc
            }
            best?.let { toFix(it) }
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * One fresh fix, waiting at most [timeoutMs]; falls back to [best].
     * Worker thread only. Never throws.
     */
    fun fresh(ctx: Context, timeoutMs: Long): Fix? {
        val cached = best(ctx)
        return try {
            if (!hasPermission(ctx) || !locationEnabled(ctx)) return cached
            if (Looper.myLooper() == Looper.getMainLooper()) return cached
            val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                ?: return cached
            val provider = pickProvider(lm) ?: return cached
            val out = AtomicReference<Location?>(null)
            val done = CountDownLatch(1)
            if (Build.VERSION.SDK_INT >= 30) {
                val cancel = android.os.CancellationSignal()
                @Suppress("MissingPermission")
                lm.getCurrentLocation(provider, cancel,
                    java.util.concurrent.Executor { r -> r.run() },
                    java.util.function.Consumer<Location?> { loc ->
                        out.set(loc)
                        done.countDown()
                    })
                if (!done.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                    try { cancel.cancel() } catch (_: Throwable) {}
                }
            } else {
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) {
                        out.set(location)
                        done.countDown()
                    }
                    // must be overridden: abstract before Android 10, and a
                    // missing override would crash in the binder callback
                    @Suppress("OVERRIDE_DEPRECATION")
                    override fun onStatusChanged(p: String?, s: Int, e: Bundle?) {}
                    override fun onProviderEnabled(p: String) {}
                    override fun onProviderDisabled(p: String) {}
                }
                @Suppress("MissingPermission", "DEPRECATION")
                lm.requestSingleUpdate(provider, listener, Looper.getMainLooper())
                done.await(timeoutMs, TimeUnit.MILLISECONDS)
                try { lm.removeUpdates(listener) } catch (_: Throwable) {}
            }
            val loc = out.get()
            val f = if (loc != null) toFix(loc) else null
            when {
                f == null -> cached
                cached == null -> f
                f.timeMs >= cached.timeMs -> f
                else -> cached
            }
        } catch (_: Throwable) {
            cached
        }
    }

    /** Honest facts for the app + server: what is missing for a location. */
    fun status(ctx: Context): Map<String, Any?> {
        val m = HashMap<String, Any?>()
        try {
            m["locationPermission"] = hasPermission(ctx)
            m["locationEnabled"] = locationEnabled(ctx)
            m["backgroundLocation"] = if (Build.VERSION.SDK_INT >= 29) {
                ctx.checkSelfPermission("android.permission.ACCESS_BACKGROUND_LOCATION") ==
                    PackageManager.PERMISSION_GRANTED
            } else true
        } catch (_: Throwable) {}
        return m
    }

    private fun pickProvider(lm: LocationManager): String? {
        val enabled = try { lm.getProviders(true) } catch (_: Throwable) { emptyList<String>() }
        for (p in listOf("fused", LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            if (enabled.contains(p)) return p
        }
        return null
    }

    private fun toFix(l: Location): Fix? {
        val lat = l.latitude
        val lng = l.longitude
        if (lat.isNaN() || lng.isNaN()) return null
        return Fix(lat, lng, if (l.hasAccuracy()) l.accuracy else null,
            if (l.time > 0) l.time else System.currentTimeMillis())
    }

    fun locationEnabled(ctx: Context): Boolean {
        return try {
            val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                ?: return false
            if (Build.VERSION.SDK_INT >= 28) lm.isLocationEnabled else
                lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        } catch (_: Throwable) {
            false
        }
    }

    fun hasPermission(ctx: Context): Boolean {
        return try {
            ctx.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED ||
                ctx.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        } catch (_: Throwable) {
            false
        }
    }
}
