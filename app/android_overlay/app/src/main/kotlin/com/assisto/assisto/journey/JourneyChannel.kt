package com.assisto.assisto.journey

import android.content.Context
import android.os.BatteryManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * journey100: Safe Journey helper channel "com.assisto/journey".
 *
 *   batteryLevel() -> Int?   0..100 from BatteryManager (no permission, no
 *                            receiver kept), null when the phone won't say.
 *
 * Registered from MainActivity inside the usual try/catch; registering a
 * handler is free and NOTHING runs at launch.
 */
object JourneyChannel {
    private const val NAME = "com.assisto/journey"

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "batteryLevel" -> {
                    var level: Int? = null
                    try {
                        val bm = app.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
                        val v = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                        if (v != null && v in 0..100) level = v
                    } catch (_: Throwable) {
                        level = null
                    }
                    result.success(level)
                }
                else -> result.notImplemented()
            }
        }
    }
}
