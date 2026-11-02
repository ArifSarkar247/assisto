package com.assisto.assisto.shopbox

import android.app.Activity
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Shop Box mode helpers (CCTV Part 4, a2-cctv). Registered from
 * MainActivity.configureFlutterEngine (see .phaseB/proposals/a2-cctv.md).
 *
 * Channel "com.assisto/shopbox":
 *   keepScreenOn({on: Bool}) -> Bool   FLAG_KEEP_SCREEN_ON on the activity window
 *                                       (only while Shop Box mode is running)
 *   isCharging()              -> Bool?  from the sticky ACTION_BATTERY_CHANGED
 *                                       broadcast (no permission, no receiver kept)
 *   battery()                 -> {level, charging, temp_c}? (cctvphone: the
 *                                       phone camera's health; same sticky
 *                                       broadcast, temperature in tenths of °C)
 *   dim({on: Bool})           -> Bool   cctvphone: window brightness to the
 *                                       minimum while the phone is a camera
 *                                       (restored to the system value on off)
 *
 * Nothing runs at launch: registering a MethodChannel handler is free; the
 * work only happens when Dart calls a method. Every call is try/catch so a
 * vendor quirk returns false/null instead of crashing the app.
 */
object ShopBoxChannel {
    private const val NAME = "com.assisto/shopbox"

    fun register(engine: FlutterEngine, activity: Activity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, NAME)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepScreenOn" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        try {
                            activity.runOnUiThread {
                                try {
                                    if (on) {
                                        activity.window.addFlags(
                                            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                                    } else {
                                        activity.window.clearFlags(
                                            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                                    }
                                } catch (_: Throwable) {
                                }
                            }
                            result.success(true)
                        } catch (_: Throwable) {
                            result.success(false)
                        }
                    }
                    "isCharging" -> {
                        try {
                            val i: Intent? = activity.applicationContext.registerReceiver(
                                null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                            val status = i?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                            if (status == -1) {
                                result.success(null)
                            } else {
                                result.success(
                                    status == BatteryManager.BATTERY_STATUS_CHARGING ||
                                        status == BatteryManager.BATTERY_STATUS_FULL)
                            }
                        } catch (_: Throwable) {
                            result.success(null)
                        }
                    }
                    "battery" -> {
                        try {
                            val i: Intent? = activity.applicationContext.registerReceiver(
                                null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                            if (i == null) {
                                result.success(null)
                            } else {
                                val lvl = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                                val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                                val st = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                                val plug = i.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1)
                                val temp = i.getIntExtra(BatteryManager.EXTRA_TEMPERATURE,
                                    Int.MIN_VALUE)
                                val out = HashMap<String, Any?>()
                                out["level"] = if (lvl >= 0 && scale > 0) lvl * 100 / scale else null
                                out["charging"] = if (st == -1 && plug == -1) null else
                                    (plug > 0 || st == BatteryManager.BATTERY_STATUS_CHARGING ||
                                        st == BatteryManager.BATTERY_STATUS_FULL)
                                out["temp_c"] = if (temp == Int.MIN_VALUE) null else temp / 10.0
                                result.success(out)
                            }
                        } catch (_: Throwable) {
                            result.success(null)
                        }
                    }
                    "dim" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        try {
                            activity.runOnUiThread {
                                try {
                                    val lp = activity.window.attributes
                                    lp.screenBrightness = if (on) 0.01f else
                                        WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                                    activity.window.attributes = lp
                                } catch (_: Throwable) {
                                }
                            }
                            result.success(true)
                        } catch (_: Throwable) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
