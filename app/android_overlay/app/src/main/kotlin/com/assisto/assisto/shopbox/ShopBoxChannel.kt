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
                    else -> result.notImplemented()
                }
            }
    }
}
