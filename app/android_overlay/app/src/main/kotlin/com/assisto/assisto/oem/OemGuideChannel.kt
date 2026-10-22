package com.assisto.assisto.oem

import android.app.Activity
import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * tl1: OEM background guide ("Background & notifications").
 *
 * Channel "com.assisto/oem_guide" (registered from MainActivity inside the
 * usual try/catch; registering a handler is free, NOTHING runs at launch —
 * every lookup happens only when Dart calls, from the guide screen):
 *
 *   info()                 -> Map  manufacturer, brand, model, sdkInt,
 *                                  release, rom (ROM name + version when a
 *                                  known system property exists),
 *                                  batteryOptIgnored (Bool?, API 23+),
 *                                  bgRestricted (Bool?, API 28+)
 *   available({step})      -> String what an "Open" button would open:
 *                                  "oem" (a candidate screen RESOLVES on this
 *                                  phone: resolveActivity + exported check),
 *                                  "details" (only App info resolves),
 *                                  "none" (Dart shows by-hand text, no button)
 *   open({step})           -> String "oem" (the step's own screen opened),
 *                                  "details" (fell back to App info),
 *                                  "none" (nothing could be opened — Dart
 *                                  shows the by-hand text instead)
 *
 * Policy-safe: we never request REQUEST_IGNORE_BATTERY_OPTIMIZATIONS. The
 * "battery_opt" step opens the system LIST (ACTION_IGNORE_BATTERY_OPTIMIZATION
 * _SETTINGS, no permission needed) where the user picks Assisto themselves.
 *
 * Every candidate is tried in order, each start in its own try/catch (a vendor
 * screen can be present but not exported, or throw SecurityException on some
 * ROM builds), so a quirk can only fall through to the next candidate.
 */
object OemGuideChannel {
    private const val NAME = "com.assisto/oem_guide"

    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "info" -> result.success(info(activity))
                    "available" -> {
                        val step = call.argument<String>("step") ?: ""
                        result.success(available(activity, step))
                    }
                    "open" -> {
                        val step = call.argument<String>("step") ?: ""
                        result.success(open(activity, step))
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                // Never crash over a settings helper: report "nothing".
                try {
                    when (call.method) {
                        "available" -> result.success("none")
                        "open" -> result.success("none")
                        else -> result.success(null)
                    }
                } catch (_: Throwable) {
                }
            }
        }
    }

    // ---- device + state ----------------------------------------------------

    private fun prop(key: String): String {
        return try {
            val c = Class.forName("android.os.SystemProperties")
            val m = c.getMethod("get", String::class.java)
            (m.invoke(null, key) as? String)?.trim() ?: ""
        } catch (_: Throwable) {
            ""
        }
    }

    /** Best-effort ROM label; empty when no known property is set. */
    private fun rom(): String {
        val checks = listOf(
            "ro.mi.os.version.name" to "HyperOS",
            "ro.miui.ui.version.name" to "MIUI",
            "ro.build.version.realmeui" to "realme UI",
            "ro.build.version.opporom" to "ColorOS",
            "ro.build.version.oplusrom" to "ColorOS",
            "ro.vivo.os.version" to "Funtouch/OriginOS",
            "ro.oxygen.version" to "OxygenOS",
            "ro.tranos.version" to "XOS/HiOS",
            "ro.os.version.release" to "XOS/HiOS",
        )
        for ((key, label) in checks) {
            val v = prop(key)
            if (v.isNotEmpty()) return "$label $v"
        }
        return try {
            // One UI exposes SEM_PLATFORM_INT on Samsung builds only.
            val f = Build.VERSION::class.java.getDeclaredField("SEM_PLATFORM_INT")
            val n = f.getInt(null) - 90000
            if (n > 0) "One UI ${n / 10000}.${(n % 10000) / 100}" else ""
        } catch (_: Throwable) {
            ""
        }
    }

    private fun info(ctx: Context): Map<String, Any?> {
        var ignored: Boolean? = null
        var restricted: Boolean? = null
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
                ignored = pm?.isIgnoringBatteryOptimizations(ctx.packageName)
            }
        } catch (_: Throwable) {
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                restricted = am?.isBackgroundRestricted
            }
        } catch (_: Throwable) {
        }
        return mapOf(
            "manufacturer" to (Build.MANUFACTURER ?: ""),
            "brand" to (Build.BRAND ?: ""),
            "model" to (Build.MODEL ?: ""),
            "sdkInt" to Build.VERSION.SDK_INT,
            "release" to (Build.VERSION.RELEASE ?: ""),
            "rom" to rom(),
            "batteryOptIgnored" to ignored,
            "bgRestricted" to restricted,
        )
    }

    // ---- candidates ----------------------------------------------------------

    private fun comp(pkg: String, cls: String): Intent =
        Intent().setComponent(ComponentName(pkg, cls))

    private fun appDetails(ctx: Context): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.fromParts("package", ctx.packageName, null))

    private fun family(): String {
        val s = ((Build.MANUFACTURER ?: "") + " " + (Build.BRAND ?: "")).lowercase()
        return when {
            "xiaomi" in s || "redmi" in s || "poco" in s -> "xiaomi"
            "realme" in s || "oppo" in s || "oneplus" in s -> "oppo"
            "vivo" in s || "iqoo" in s -> "vivo"
            "samsung" in s -> "samsung"
            "infinix" in s || "tecno" in s || "itel" in s -> "transsion"
            else -> "other"
        }
    }

    /**
     * Known vendor screens per step, most specific first. Names come from the
     * vendors' own settings apps (widely documented, e.g. dontkillmyapp.com);
     * any that a ROM build lacks simply fails resolveActivity and is skipped.
     */
    fun candidates(ctx: Context, step: String): List<Intent> {
        val f = family()
        val pkg = ctx.packageName
        return when (step) {
            "battery_opt" -> listOf(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            "app_details" -> listOf(appDetails(ctx))
            "autostart" -> when (f) {
                "xiaomi" -> listOf(
                    comp("com.miui.securitycenter",
                        "com.miui.permcenter.autostart.AutoStartManagementActivity"),
                    Intent("miui.intent.action.OP_AUTO_START")
                        .addCategory(Intent.CATEGORY_DEFAULT),
                )
                "oppo" -> listOf(
                    comp("com.coloros.safecenter",
                        "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
                    comp("com.coloros.safecenter",
                        "com.coloros.safecenter.startupapp.StartupAppListActivity"),
                    comp("com.oppo.safe",
                        "com.oppo.safe.permission.startup.StartupAppListActivity"),
                    comp("com.oneplus.security",
                        "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"),
                )
                "vivo" -> listOf(
                    comp("com.vivo.permissionmanager",
                        "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
                    comp("com.iqoo.secure",
                        "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"),
                    comp("com.iqoo.secure",
                        "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
                )
                "transsion" -> listOf(
                    comp("com.transsion.phonemaster",
                        "com.cyin.himgr.autostart.AutoStartActivity"),
                )
                else -> emptyList()
            }
            "oem_battery" -> when (f) {
                "xiaomi" -> listOf(
                    comp("com.miui.powerkeeper",
                        "com.miui.powerkeeper.ui.HiddenAppsConfigActivity")
                        .putExtra("package_name", pkg)
                        .putExtra("package_label", "Assisto"),
                )
                "oppo" -> listOf(
                    comp("com.coloros.oppoguardelf",
                        "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity"),
                    comp("com.coloros.oppoguardelf",
                        "com.coloros.powermanager.fuelgaue.PowerSaverModeActivity"),
                )
                "vivo" -> listOf(
                    comp("com.vivo.abe",
                        "com.vivo.applicationbehaviorengine.ui.ExcessivePowerManagerActivity"),
                    comp("com.iqoo.powersaving",
                        "com.iqoo.powersaving.PowerSavingManagerActivity"),
                )
                "samsung" -> listOf(
                    comp("com.samsung.android.lool",
                        "com.samsung.android.sm.battery.ui.BatteryActivity"),
                    comp("com.samsung.android.sm",
                        "com.samsung.android.sm.battery.ui.BatteryActivity"),
                    comp("com.samsung.android.sm",
                        "com.samsung.android.sm.ui.battery.BatteryActivity"),
                )
                "transsion" -> listOfNotNull(
                    try {
                        ctx.packageManager.getLaunchIntentForPackage("com.transsion.phonemaster")
                    } catch (_: Throwable) {
                        null
                    },
                )
                else -> emptyList()
            }
            else -> emptyList()
        }
    }

    private fun resolves(ctx: Context, i: Intent): Boolean {
        return try {
            val ri = ctx.packageManager.resolveActivity(i, PackageManager.MATCH_DEFAULT_ONLY)
                ?: return false
            val ai = ri.activityInfo ?: return false
            // A vendor activity that exists but is not exported throws on start.
            ai.exported || ai.packageName == ctx.packageName
        } catch (_: Throwable) {
            false
        }
    }

    private fun tryStart(activity: Activity, i: Intent): Boolean {
        return try {
            if (!resolves(activity, i)) return false
            activity.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun open(activity: Activity, step: String): String {
        for (i in candidates(activity, step)) {
            if (tryStart(activity, i)) return if (step == "app_details") "details" else "oem"
        }
        // Fallback: the app's own App info page (Battery / Auto-launch live
        // there on ColorOS 12+, One UI and most near-stock ROMs). Started even
        // if resolveActivity said no (some ROMs hide Settings from package
        // visibility); a throw means "none" and Dart shows the by-hand text.
        return try {
            activity.startActivity(appDetails(activity).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            "details"
        } catch (_: Throwable) {
            "none"
        }
    }

    private fun available(ctx: Context, step: String): String {
        if (step != "app_details" && candidates(ctx, step).any { resolves(ctx, it) }) return "oem"
        return if (resolves(ctx, appDetails(ctx))) "details" else "none"
    }
}
