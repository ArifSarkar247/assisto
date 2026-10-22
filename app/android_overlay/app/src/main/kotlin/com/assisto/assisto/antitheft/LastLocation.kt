package com.assisto.assisto.antitheft

import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build

/**
 * b6-antitheft — best-effort LAST-KNOWN location, foreground-only.
 *
 * We deliberately do NOT request continuous background GPS (ACCESS_BACKGROUND_
 * LOCATION) or run a location request loop: that is heavy, battery-hungry, and
 * triggers Play's background-location policy review. Instead, each heartbeat
 * reads the cached last-known fix the OS already has (updated whenever any app,
 * including Assisto's own foreground screens, used location). If there is no
 * cached fix we honestly send no location rather than a fake one.
 */
object LastLocation {
    fun get(ctx: Context): Pair<Double, Double>? {
        return try {
            if (!hasPermission(ctx)) return null
            val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                ?: return null
            val providers = try { lm.getProviders(true) } catch (_: Throwable) { emptyList<String>() }
            var best: android.location.Location? = null
            for (p in providers) {
                val loc = try {
                    @Suppress("MissingPermission")
                    lm.getLastKnownLocation(p)
                } catch (_: Throwable) { null }
                if (loc != null && (best == null || loc.time > best!!.time)) best = loc
            }
            best?.let { Pair(it.latitude, it.longitude) }
        } catch (_: Throwable) {
            null
        }
    }

    private fun hasPermission(ctx: Context): Boolean {
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
